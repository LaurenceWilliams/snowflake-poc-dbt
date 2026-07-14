{#
    One-time governance setup for ROW ACCESS (RLS) -- run manually after seeding:

        dbt run-operation setup_row_access_policy --profiles-dir . --target snowflake

    Creates a row access policy in the central governance schema, driven by the
    entitlements__country_access mapping table (role_name -> country). The policy
    body checks whether CURRENT_ROLE() is mapped to the row's country;
    full_access_role bypasses the filter entirely.

    Idempotent AND updatable: CREATE ... IF NOT EXISTS establishes the object
    (default-deny), then ALTER ... SET BODY always re-applies the current
    predicate -- so editing this macro and re-running updates the live policy,
    even while it's attached to tables (SET BODY works on in-use policies;
    CREATE OR REPLACE would not).

    Prereq: `dbt seed` must have built entitlements.country_access first -- the
    policy body references it and Snowflake validates the reference at SET BODY.
#}
{% macro setup_row_access_policy(policy_name='country_row_access', full_access_role='DATA_PLATFORM') %}

    {%- if target.type != 'snowflake' -%}
        {{ log("setup_row_access_policy: skipped (target is not snowflake)", info=true) }}
        {{ return('') }}
    {%- endif -%}

    {%- set db  = target.database -%}
    {%- set gov = var('pii_governance_schema', target.schema) -%}
    {%- set ent_schema = 'entitlements' -%}
    {%- set ent_table  = 'country_access' -%}

    {# Ensure the governance schema exists (shared with the masking setup). #}
    {%- do run_query("create schema if not exists " ~ db ~ "." ~ gov) -%}

    {# Establish the policy object with a safe default-deny body. #}
    {%- do run_query(
        "create row access policy if not exists " ~ db ~ "." ~ gov ~ "." ~ policy_name
        ~ " as (country string) returns boolean -> false"
    ) -%}

    {# Always (re)apply the real predicate -- idempotent and picks up edits. #}
    {%- set body %}
        alter row access policy {{ db }}.{{ gov }}.{{ policy_name }} set body ->
            current_role() = '{{ full_access_role }}'
            or exists (
                select 1
                from {{ db }}.{{ ent_schema }}.{{ ent_table }} ca
                where ca.role_name = current_role()
                  and ca.country = country
            )
    {%- endset -%}
    {%- do run_query(body) -%}

    {{ log("setup_row_access_policy: ensured " ~ policy_name ~ " in " ~ db ~ "." ~ gov ~ " (mapping: " ~ db ~ "." ~ ent_schema ~ "." ~ ent_table ~ ")", info=true) }}

{% endmacro %}
