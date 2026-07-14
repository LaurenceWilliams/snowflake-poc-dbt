# snowflake-poc-dbt

Two-target dbt benchmark harness for the Snowflake PoC. One project, one set of
sources, **two engines** — chosen per `--target`:

- `snowflake` (dbt-snowflake)
- `redshift_serverless` (dbt-redshift)

Addresses several success criteria from `.claude/docs/snowflake-poc-evaluation.md`
(SC-01, SC-06a, SC-06b, SC-05c). Per-criterion notes and findings live in
**[EVALUATION.md](EVALUATION.md)**; this README covers how to set up and run the harness.

## Dialect split

The same query in two dialects lives in two folders; only one is enabled per run
(via `+enabled: "{{ target.type == ... }}"` in `dbt_project.yml`):

```
models/
  redshift/   <model>.sql   # native Redshift  (enabled when --target redshift_serverless)
  snowflake/  <model>.sql   # native Snowflake (enabled when --target snowflake)
  sources.yml               # shared
```

Same filename in both folders → same `run_results` node id → trivial timing
pairing. The Snowflake file is **derived** from the Redshift one — primarily via
SnowConvert AI (`scai`, see [Translating with scai](#translating-redshift--snowflake-with-snowconvert-ai-scai)),
with `bin/sqlglot_poc.py` as a fallback transpiler. Never hand-edit the two
independently (they'd drift and the benchmark would compare different queries);
re-run the translation and re-templatize instead.

## Setup

```bash
cd snowflake-poc-dbt
uv sync                       # creates .venv with dbt-core + both adapters + sqlglot
cp .env.example .env          # fill in credentials
set -a; source .env; set +a

# Prove connectivity to BOTH engines from this machine:
uv run dbt debug --profiles-dir . --target snowflake
uv run dbt debug --profiles-dir . --target redshift_serverless
```

## Workflow

1. Name the 3–4 benchmark models; copy each from `rover-dbt` into `models/redshift/`
   and **neutralize**: strip `dist`/`sort`/`tags`/grant `post_hook`s, repoint
   `ref()` → `source()`.
2. Translate each to `models/snowflake/` with **SnowConvert AI** — see
   [Translating with scai](#translating-redshift--snowflake-with-snowconvert-ai-scai)
   below. Log every divergence (that's the SC-06a finding).
3. Add the upstream tables to `models/sources.yml`.
4. Parity (SC-01): activate the check — `mv analyses/parity_check.sql.tmpl analyses/parity_check.sql`
   (it ships as `.tmpl` so the empty project parses). Then `uv run dbt compile --select parity_check`
   per target, run the compiled SQL on each, compare.
5. Serial timing (SC-06b): `uv run python bench/run_bench.py --models model_a model_b --runs 6`
6. Concurrency (SC-06b): `uv run python bench/run_concurrency.py --target redshift_serverless --models model_a --concurrency 8`
   (then again with `--target snowflake`) and compare degradation.

## Translating Redshift → Snowflake with SnowConvert AI (scai)

`scai` is Snowflake's grammar-based migration converter. It produces a faithful,
auditable dialect translation — but it parses **raw SQL/DDL, not dbt Jinja**. Feed
it a `.sql` file with `{{ ... }}` in it and it hits the `{{` on line 1, comments out
the **entire file** with `SSC-EWI-0001 UNRECOGNIZED TOKEN`, and still reports
"0 issues" (misleading). So the path is always: **dbt-compile to pure SQL → scai →
re-templatize back into a dbt model.**

### One-time setup

```bash
brew install --cask snowflakedb/snowconvert-ai/snowconvert-ai   # needs `brew trust` + sudo
scai terms accept
# scai requires a DEFAULT Snowflake connection even just to init/convert:
snow connection set-default POC          # POC = our browser-OAuth connection
chmod 0600 ~/.snowflake/connections.toml # scai refuses world-readable creds
scai connection list                     # confirm POC shows Is Default? = True
```

### Per-iteration steps

```bash
# 1. Produce compiled (pure-SQL) versions of the Redshift models.
#    dbt renders all Jinja — loops unrolled, ref()/source() resolved to db.schema.table.
uv run dbt run --target redshift_serverless --profiles-dir .   # (or `dbt compile`)
#    Compiled output lands in:
#    target/compiled/snowflake_poc/models/redshift/<model>.sql

# 2. Stage the compiled SQL into a scai input dir (sc_migration/ is gitignored).
rm -rf sc_migration && mkdir -p sc_migration/input
cp target/compiled/snowflake_poc/models/redshift/*.sql sc_migration/input/

# 3. Init a Redshift project + convert. --code-already-split is REQUIRED:
#    each compiled file is exactly one object (one model = one SELECT), so there is
#    nothing to "arrange". Without it scai errors ADD0010 demanding -- <sc-table> tags.
cd sc_migration
scai init poc_convert -l Redshift -i ./input -c POC --code-already-split --json
cd poc_convert
scai code convert --json
#    Converted output: sc_migration/poc_convert/snowflake/<model>.sql
```

`--json` prints one machine-readable envelope (`{"success":true,"result":{...}}`)
— handy for scripting and for reading the issue counts.

### Reading the results

- **`ewi.total: 0`** = clean translation (Errors/Warnings/Issues). This is the number
  that matters.
- **`SSC-FDM-0007 MISSING DEPENDENT OBJECTS`** = **benign.** scai just couldn't find the
  source tables in its catalog (we never ran `scai code extract` against a live DB).
  Those tables exist in real Snowflake; ignore the marker.
- Skim the diff `source/<model>.sql` vs `snowflake/<model>.sql` and record every
  substantive change for the SC-06a writeup. Changes seen on our models:
  | Redshift | Snowflake | Why |
  |---|---|---|
  | `first_value(... ignore nulls)` | `first_value(...) ... IGNORE NULLS` | `IGNORE NULLS` moves **outside** the parens (the one real fix) |
  | `sd.start` | `sd."start"` | reserved word, quoted |
  | `in ('x', 'y')` | `in (RTRIM('x'), RTRIM('y'))` | Redshift CHAR trailing-space-trim emulation; harmless on VARCHAR |
  | `getdate()`, `::timestamp` | unchanged | already valid in Snowflake |

### Re-templatizing scai output into a dbt model

scai output is raw SQL with hardcoded `db.schema.table` refs. To turn it back into a
benchmark-ready dbt model in `models/snowflake/`:

1. Drop the leading `SSC-FDM-*` comment line(s).
2. Add a Snowflake-appropriate `{{ config(...) }}` — keep `materialized`, **drop
   Redshift-only `dist`/`sort`/`bind`** (dbt-snowflake doesn't use them).
3. Repoint refs: `reporting.roverdb.<t>` → `{{ source('roverdb', '<t>') }}`;
   `reporting.<dev_schema>.<model>` → `{{ ref('<model>') }}`.
4. Leave the translated body **verbatim otherwise** (incl. the `RTRIM()` wraps) so the
   benchmark measures real, unmodified SnowConvert output.
5. Validate without a warehouse round-trip:
   `uv run dbt parse --profiles-dir . --target snowflake` (3 models, N sources, no errors).

## Methodology guardrails (baked in)

- **Result caches disabled** both sides via pre-hooks (`USE_CACHED_RESULT=FALSE`
  on SF; `enable_result_cache_for_session off` on RS) so repeat runs hit compute.
- **Cold vs warm**: run #1 dropped as cold; warm = mean/median/p95 of the rest.
- **Cost parity**: pick an SF warehouse size and RS serverless RPU of comparable
  $/hr and document both — the 25% number is only meaningful per-dollar.
