{#
    One-time governance setup for TAG-BASED masking (run manually):

        dbt run-operation setup_pii_tag --target snowflake

    This is the whole point of the tag-based approach: the policy is bound ONCE,
    centrally, to a tag object. After this, ANY column that carries the tag
    inherits encrypt_pii -- no per-column SET MASKING POLICY needed.

    Idempotent: policy + tag use IF NOT EXISTS; the tag->policy binding is only
    applied if the tag has no masking policy yet (re-binding the same policy
    errors in Snowflake, so we check first). The tag->policy binding is a
    PERSISTENT account-level object -- once set it survives across dbt runs, so
    on repeat invocations this macro correctly reports "already bound" and no-ops.

    Pass force=true to re-bind (UNSET then SET), e.g. to point the tag at a
    different policy:
        dbt run-operation setup_pii_tag --args '{force: true}' --target snowflake
#}
{% macro setup_pii_tag(tag_name='pii_category', force=false) %}

    {%- if target.type != 'snowflake' -%}
        {{ log("setup_pii_tag: skipped (target is not snowflake)", info=true) }}
        {{ return('') }}
    {%- endif -%}

    {# Governance objects (policy + tag) live in ONE central schema, not next to
       each model. Models fan out into per-domain schemas (generate_schema_name
       splits on '__'), so the tag MUST be pinned to a fixed schema that the
       per-build post-hook references identically. Defaults to target.schema. #}
    {%- set db     = target.database -%}
    {%- set schema = var('pii_governance_schema', target.schema) -%}

    {# 0. Ensure the governance schema exists (models may never create it). #}
    {%- do run_query("create schema if not exists " ~ db ~ "." ~ schema) -%}

    {# 1. Ensure the masking policy exists (reuse the project's policy macro). #}
    {%- do run_query(create_masking_policy_encrypt_pii(db, schema)) -%}

    {# 2. Ensure the governance tag exists. #}
    {%- do run_query("create tag if not exists " ~ db ~ "." ~ schema ~ "." ~ tag_name) -%}

    {# 3. Bind the policy to the tag -- only if not already bound. #}
    {%- set check %}
        select count(*) as n
        from table({{ db }}.information_schema.policy_references(
            ref_entity_name   => '{{ db }}.{{ schema }}.{{ tag_name }}',
            ref_entity_domain => 'TAG'
        ))
    {%- endset -%}
    {%- set already_bound = run_query(check).columns[0].values()[0] | int > 0 -%}

    {%- if already_bound and not force -%}
        {{ log("setup_pii_tag: " ~ tag_name ~ " already bound to a masking policy -- skipping bind (pass force=true to re-bind)", info=true) }}
    {%- else -%}
        {%- if already_bound and force -%}
            {%- do run_query(
                "alter tag " ~ db ~ "." ~ schema ~ "." ~ tag_name
                ~ " unset masking policy " ~ db ~ "." ~ schema ~ ".encrypt_pii"
            ) -%}
            {{ log("setup_pii_tag: force -- unset existing policy on tag " ~ tag_name, info=true) }}
        {%- endif -%}
        {%- do run_query(
            "alter tag " ~ db ~ "." ~ schema ~ "." ~ tag_name
            ~ " set masking policy " ~ db ~ "." ~ schema ~ ".encrypt_pii"
        ) -%}
        {{ log("setup_pii_tag: bound encrypt_pii to tag " ~ tag_name, info=true) }}
    {%- endif -%}

{% endmacro %}
