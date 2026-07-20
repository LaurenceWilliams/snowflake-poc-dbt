# Snowflake PoC — Evaluation Criteria Notes

Working notes on the success criteria this project addresses. The master
definitions live in [`.claude/docs/snowflake-poc-evaluation.md`](.claude/docs/snowflake-poc-evaluation.md);
this file records **what `snowflake-poc-dbt` does for each criterion and what we found**.
For how to set up and run the harness, see [`README.md`](README.md).

## Criteria at a glance

| Criterion | What this project does |
|---|---|
| **SC-01** Replicate Redshift objects | `analyses/parity_check.sql` validates row-count + checksum parity between engines (data is already loaded both sides). |
| **SC-06a** Convert Redshift SQL / dbt to Snowflake | SnowConvert AI (`scai`) via dbt-compile → convert → re-templatize, with `bin/sqlglot_poc.py` as a fallback transpiler. Full how-to in the README's *Translating with scai* section. |
| **SC-06b** Compare query runtimes | `bench/run_bench.py` (serial) + `bench/run_concurrency.py` (the real bottleneck) measure runtime and test the ≥25%-faster threshold. |
| **SC-05c** Data protection policies | Column & tag-based dynamic masking, plus entitlement-driven row access policies (RLS), with metadata queries to verify enforcement. See below. |
| **SC-05d** OAuth local/Codespaces connection (no password) | Passwordless, role-based dev auth: `externalbrowser` (SSO) for local, key pair for headless/Codespaces. `profiles.yml` targets `snowflake` + `snowflake_keypair`. See below. |
| **SC-05e** GitHub connection with Snowflake | CI workflow (`.github/workflows/snowflake-ci.yml`) runs a dbt smoke test against Snowflake on every relevant push. Blocked on SRE adding this repo to the Custom-4 runner group. See below. |

---

## SC-05c — Data protection policies

**Question (from the master doc):** Can we monitor query execution to confirm
policies are applied? Is there a "run-as" to check whether user A can access a
table/schema? Is there a dbt package that helps?

### What Rover does today (Redshift), for context

Rover's current Dynamic Data Masking lives in `rover-dagster` at
`code_locations/data_tools/dbt_project/macros/dynamic_data_masking/`. It is an
**allowlist per ACG group** (`meta.ddm_allowed_columns` → every column *not*
listed is masked to `NULL`), attached **per user** because Redshift cannot
`ATTACH MASKING POLICY ... TO GROUP`. The macro even resolves group membership
and applies cross-group precedence to avoid over-masking. That complexity is a
Redshift *workaround*, not an inherent requirement.

Snowflake masking is **role-based and centralized** (`CURRENT_ROLE()` /
`IS_ROLE_IN_SESSION()`), so one policy object replaces the per-user machinery —
the same simplification story as the exec summary's "+copy_grants replaces the
whole grant pipeline".

### The shared policy

Both approaches enforce the **same** masking policy,
`macros/create_masking_policy_encrypt_pii.sql`:

| Caller role | Sees |
|---|---|
| `DATA_PLATFORM` | raw value |
| `POC USERS - SNOWFLAKE-OKTA` | `SHA2(val)` (hashed) |
| anyone else | `**********` |

### Two approaches compared

| | Column-based | Tag-based |
|---|---|---|
| Model | `models/snowflake/ddm_sample/ddm_sample__test_model.sql` | `…/ddm_sample__test_model_tagged.sql` |
| Column config | `meta.masking_policy: encrypt_pii` (names the **policy**) | `meta.pii_tag: EMAIL` (names the **classification**) |
| How the policy attaches | `dbt_snow_mask` runs `ALTER … MODIFY COLUMN … SET MASKING POLICY` per column | policy is bound **once** to a tag; columns just carry the tag |
| Author macros | `dbt_snow_mask.apply_masking_policy` (post-hook, folder-level in `dbt_project.yml`) | `setup_pii_tag` (one-time) + `apply_tag_based_masking` (post-hook) |
| Best for | small, stable set of sensitive columns | many columns / many tables — governance at scale |

Both read the **same seed**, so any difference in `SELECT` output between the two
models is purely the masking mechanism — a clean A/B.

### Key findings

1. **`dbt_snow_mask` (v0.2.9) has no native tag-based support.** Its only path is
   per-column `SET MASKING POLICY` (`apply_masking_policy_list_for_models.sql`).
   Tag-based masking had to be authored with custom macros
   (`setup_pii_tag`, `apply_tag_based_masking`).
2. **Governance objects must be centralized, not co-located with tables.** Models
   fan out into per-domain schemas (`generate_schema_name` splits on `__`), so the
   policy + tag are pinned to one governance schema via
   `var('pii_governance_schema', target.schema)` and referenced fully-qualified.
   The tagged *column* stays in the model's schema; only the *tag reference* is
   cross-schema.
3. **Attachments are re-derived every build.** `CREATE OR REPLACE TABLE/VIEW`
   builds a new object and drops column masking attachments *and* column tags —
   the same physics as Redshift's `CREATE OR REPLACE VIEW` dropping DDM
   attachments. So both approaches re-apply column-level metadata in a post-hook
   on every run. What persists independently: the **policy object** and the
   **tag→policy binding** (an account-level object).
4. **`ACCESS_HISTORY` is a Snowflake-only capability.** Per-query evidence that a
   policy fired (`policies_referenced`) has no Redshift equivalent — this is the
   direct answer to SC-05c's "monitor query execution to ensure policy
   application".
5. **No true non-admin "run-as".** The practical equivalent is `USE ROLE
   <persona>` then `SELECT` — which becomes the persona × column test matrix.

### How to run the comparison

```bash
# One-time governance setup (creates policy + tag, binds policy→tag):
uv run dbt run-operation setup_pii_tag --profiles-dir . --target snowflake
#   re-bind to a different policy later with: --args '{force: true}'

# Build both models:
uv run dbt run --profiles-dir . --target snowflake \
  --select ddm_sample__test_model ddm_sample__test_model_tagged
```

Then the A/B: `USE ROLE <persona>` and `SELECT email FROM …` against each model —
identical masked output (raw / `SHA2` / `**********`), two different mechanisms.

### Verification queries

Two metadata layers: **`INFORMATION_SCHEMA`** table functions are real-time but
per-object; **`SNOWFLAKE.ACCOUNT_USAGE`** views are account-wide but lag up to ~2h.

**Which policy is on each column, and *how* it got there** (the A/B — `TAG_NAME`
is `NULL` for a direct attach, populated when it arrived via a tag):

```sql
select 'column-based' as approach,
       ref_column_name, policy_name, policy_kind, tag_database, tag_schema, tag_name
from table(information_schema.policy_references(
     ref_entity_name => current_database() || '.DDM_SAMPLE.TEST_MODEL',
     ref_entity_domain => 'TABLE'))
union all
select 'tag-based',
       ref_column_name, policy_name, policy_kind, tag_database, tag_schema, tag_name
from table(information_schema.policy_references(
     ref_entity_name => current_database() || '.DDM_SAMPLE.TEST_MODEL_TAGGED',
     ref_entity_domain => 'TABLE'));
```


### Row access policies (RLS)

Masking hides *columns*; a row access policy (RAP) hides *rows*. Rows where the
policy returns false silently disappear from results **and counts/aggregates** —
no error — which is what makes RLS the right tool for regional/tenant isolation.

**Pattern used:** policy + **entitlement mapping table**. The policy body is
generic; *who-sees-what* lives as data, changeable without touching DDL.

| Piece | Location |
|---|---|
| Demo model (filtered on `country`) | `models/snowflake/rls_sample/rls_sample__regional.sql` |
| Row data | `seeds/example/example__regional.csv` (US/GB/CA/DE) |
| Entitlement mapping (`role_name → country`) | `seeds/entitlements/entitlements__country_access.csv` |
| Create/update the policy (one-time) | `macros/setup_row_access_policy.sql` |
| Attach it each build (post-hook) | `macros/apply_row_access_policy.sql` |

The policy grants `DATA_PLATFORM` all rows (escape hatch); `POC USERS -
SNOWFLAKE-OKTA` sees only US + CA per the mapping; any other role sees nothing.
Same lifecycle as masking: `CREATE OR REPLACE` drops the attachment, so the
post-hook re-attaches every build; the policy object + mapping table persist.

**How to run** (note the order — seed first, the policy body references the
mapping table and Snowflake validates it at `SET BODY`):

```bash
uv run dbt seed --profiles-dir . --target snowflake \
  --select example__regional entitlements__country_access
uv run dbt run-operation setup_row_access_policy --profiles-dir . --target snowflake
uv run dbt run --profiles-dir . --target snowflake --select rls_sample__regional
```

**The A/B (verified 2026-07-14):** `USE ROLE DATA_PLATFORM` → 6 rows; `USE ROLE
"POC USERS - SNOWFLAKE-OKTA"` → 3 rows (US + CA); any other role → 0 rows —
observed output matched expectations end-to-end (seed → setup → build → query).
Change access by editing the mapping seed and re-seeding — no policy DDL change.

**Verify the attachment** (real-time):

```sql
select ref_column_name, policy_name, policy_kind
from table(information_schema.policy_references(
     ref_entity_name => current_database() || '.RLS_SAMPLE.REGIONAL',
     ref_entity_domain => 'TABLE'))
where policy_kind = 'ROW_ACCESS_POLICY';
```

**Finding:** editing the predicate is done with `ALTER ROW ACCESS POLICY … SET
BODY`, which works even while the policy is attached (`CREATE OR REPLACE` does
not) — so `setup_row_access_policy` is safe to re-run to push predicate changes.

### Policy types to scope (recommendation)

| Policy | Scope | Rover mapping |
|---|---|---|
| Dynamic masking (column) | **Core** — done | Direct analog of current Redshift DDM |
| Tag-based masking | **Core** — done | Tag once, policy auto-propagates — replaces per-column YAML at scale |
| Row access policies (RLS) | **Core** — done | Regional/team row filtering Redshift can't do well; entitlement-table driven |
| Projection / aggregation policies | Note only | Out of scope for this PoC |

---

## SC-05d — OAuth local / Codespaces connection (no password)

**Question (from the master doc):** Establish a passwordless, role-based
connection to Snowflake for development — run dbt models locally and from
Codespaces without storing a password.

### Passwordless methods available

| Method | dbt config | Interactive? | Local | Codespaces |
|---|---|---|---|---|
| **Browser SSO** (OKTA) | `authenticator: externalbrowser` | yes (browser) | ✅ `snowflake` target | ⚠ callback must reach a browser (port-forwarding) |
| **Key pair (JWT)** | `private_key_path` | no | ✅ `snowflake_keypair` target | ✅ headless |
| **OAuth token** | `authenticator: oauth` + `token` | depends on IdP | ✅ | ✅ |
| Password | `password` | no | avoid | avoid |

> Note on "OAuth": the `externalbrowser` authenticator triggers the IdP's
> browser SSO flow (OAuth or SAML depending on the OKTA integration). The PoC's
> Snowflake CLI (`snow`) connection is configured for OAuth authorization-code
> (`OAUTH_AUTHORIZATION_CODE`). For a *pure* token-based OAuth in dbt, use
> `authenticator: oauth` + `token` instead of `externalbrowser`.

### Local — VERIFIED

The `snowflake` target uses `authenticator: externalbrowser` — browser SSO, **no
password**. All of this session's local dbt work (masking + RLS models and
`run-operation`s) authenticated this way: a browser login, then `dbt run` /
`dbt run-operation` against Snowflake with no secret in the profile.

### Codespaces — approach

`externalbrowser` opens a `http://localhost:<port>` callback for the SSO
redirect. Locally the browser and callback share a machine, so it just works. In
a **remote Codespace** the callback port must be reachable by a browser:

- Rely on VS Code's automatic **port forwarding** so the codespace's localhost
  callback opens in your local browser; **or**
- Use the **key pair** target (`snowflake_keypair`) — no browser at all, so it
  sidesteps the callback entirely. Mount the private key as a Codespaces secret.
  This is the most robust headless dev path.

### Recommendation

- **Local dev:** `externalbrowser` (browser SSO) — already working, no secrets stored.
- **Codespaces dev:** key pair (private key as a Codespaces secret) as the
  headless default; `externalbrowser` also works if port-forwarding is set up.
- **Never** the `password` path for development.

### Related config

- `profiles.yml`: `snowflake` (externalbrowser) · `snowflake_keypair` (key pair).
- `.env.example`: `SF_PRIVATE_KEY_PATH`, `SF_PRIVATE_KEY_PASSPHRASE`.
- Key pair setup (generate keys, `ALTER USER … SET RSA_PUBLIC_KEY` needs
  USERADMIN) is documented in `.env.example`.

---

## SC-05e — GitHub connection with Snowflake

**Question (from the master doc):** Connect GitHub with Snowflake. Run dbt from
a GitHub Action.

### What was built

`.github/workflows/snowflake-ci.yml` defines a `dbt-smoke-test` job that:

1. Installs dbt + adapters via `uv sync`.
2. Runs `dbt deps` and `dbt debug` to verify the Snowflake connection.
3. Runs `dbt run --select test__test_model --target snowflake_ci` as a
   smoke test against the `github_ci` database (`poc_bench` schema).

The job triggers on `workflow_dispatch` and on pushes that touch
`models/snowflake/test/**`, `profiles.yml`, or the workflow file itself.

### Authentication and service account

The workflow authenticates as a dedicated service user (`svc_github_ci`) with
role `ci_dbt_role` using password auth — the only headless option that doesn't
require a private key mounted as a secret at the GitHub org level. Three repo
secrets drive the connection: `SF_ACCOUNT`, `SF_WAREHOUSE`, `SF_PASSWORD`.
Non-sensitive values (user, role, database, schema) are literals in the
workflow so there is less per-repo secret configuration.

### Network policy

Snowflake rejects connections from IPs not on an allowlist. A network policy
was created and scoped to `svc_github_ci`:

```sql
CREATE NETWORK POLICY allow_github_custom4
  ALLOWED_IP_LIST = ('<custom-4-cidr-1>/28', '<custom-4-cidr-2>/28', '<custom-4-additional-ip>/32');

ALTER USER svc_github_ci SET NETWORK_POLICY = allow_github_custom4;
```

The two `/28` blocks are the documented Custom-4 runner egress ranges (ask SRE
for the exact CIDRs). The `/32` was identified from an initial failed run that
used a different runner — confirmed with SRE as also belonging to the Custom-4
pool.

Scoping the policy to the service user (rather than `ALTER ACCOUNT`) means
other Snowflake users are unaffected if the runner IPs ever need updating.

### Blocker — Custom-4 runner group access (SRE action required)

The workflow uses `runs-on: Custom-4`. GitHub self-hosted runner groups have
per-repo allowlists; `snowflake-poc-dbt` was never added to the Custom-4
group. As a result the job queues indefinitely — GitHub finds the label but no
runner in the group picks it up.

**Required:** SRE to add `roverdotcom/snowflake-poc-dbt` to the Custom-4 runner
group's allowed repositories (GitHub org Settings → Actions → Runner groups →
Custom-4 → Repository access).

Once that is done the queued run should start immediately, or re-trigger via
`workflow_dispatch`.

### Why Custom-4 and not `ubuntu-latest`

The aws-* GitHub-hosted runners (which egress from static IPs) are scoped to
the `web` repo only. `ubuntu-latest` egresses from GitHub's published but very
large and dynamic IP ranges — not practical to allowlist in Snowflake's network
policy. Custom-4 is the only runner with stable, known egress IPs available to
repos outside `web`.
