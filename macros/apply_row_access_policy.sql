{#
    Per-build post-hook: attach the row access policy to a model's filter column.

    Why a post-hook? `create or replace table/view` drops row access policy
    attachments on every rebuild (same lifecycle as masking attachments/tags), so
    the attachment must be re-applied each run. The policy object + mapping table
    persist (see setup_row_access_policy).

    A table can hold only ONE row access policy, and it is dropped on rebuild, so
    a plain ADD after the CREATE OR REPLACE is clean. (For incremental models that
    persist across runs, a DROP-if-attached guard would be needed first.)

    Usage: post_hook="{{ apply_row_access_policy('country') }}"
#}
{% macro apply_row_access_policy(on_column, policy_name='country_row_access') %}

    {%- if target.type != 'snowflake' -%}{{ return('') }}{%- endif -%}
    {%- if target.schema.startswith('dbt_') -%}{{ return('') }}{%- endif -%}
    {%- if not execute -%}{{ return('') }}{%- endif -%}

    {# Table/view lives in the model's fanned-out schema... #}
    {%- set db     = model.database -%}
    {%- set schema = model.schema -%}
    {%- set alias  = model.alias -%}
    {%- set materialization = 'view' if model.config.get('materialized') == 'view' else 'table' -%}

    {# ...but the policy object lives in the central governance schema. #}
    {%- set gov = var('pii_governance_schema', target.schema) -%}

    {{ log(modules.datetime.datetime.now().strftime("%H:%M:%S") ~ " | adding row access policy " ~ db ~ "." ~ gov ~ "." ~ policy_name ~ " on " ~ db ~ "." ~ schema ~ "." ~ alias ~ " (" ~ on_column ~ ")", info=True) }}

    {%- set query %}
        alter {{ materialization }} {{ db }}.{{ schema }}.{{ alias }}
        add row access policy {{ db }}.{{ gov }}.{{ policy_name }} on ({{ on_column }})
    {%- endset -%}
    {%- do run_query(query) -%}

{% endmacro %}
