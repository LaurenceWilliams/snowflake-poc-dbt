{#
    Per-build post-hook for TAG-BASED masking.

    Why a post-hook (not one-time)? `create or replace table` DROPS column tags
    on every rebuild -- the same reason Rover's Redshift DDM re-attaches on every
    `create or replace view`. So column *classification* must be re-applied each
    build, while the tag->policy *binding* is one-time (see setup_pii_tag).

    dbt_snow_mask (v0.2.9) has NO tag-based path, so this is a small custom macro.
    It reads meta.pii_tag off each column and tags that column; the encrypt_pii
    policy then applies automatically via the tag binding.
#}
{% macro apply_tag_based_masking(meta_key='pii_tag', tag_name='pii_category') %}

    {%- if target.type != 'snowflake' -%}{{ return('') }}{%- endif -%}
    {%- if target.schema.startswith('dbt_') -%}{{ return('') }}{%- endif -%}
    {%- if not execute -%}{{ return('') }}{%- endif -%}

    {# The table/column lives in the model's (fanned-out) schema... #}
    {%- set db     = model.database -%}
    {%- set schema = model.schema -%}
    {%- set alias  = model.alias -%}
    {%- set materialization = 'view' if model.config.get('materialized') == 'view' else 'table' -%}

    {# ...but the TAG object lives in the central governance schema, referenced
       fully-qualified. Must match where setup_pii_tag created it. #}
    {%- set tag_schema = var('pii_governance_schema', target.schema) -%}

    {%- for col_name, col in model.columns.items() -%}
        {%- set classification = col.get('meta', {}).get(meta_key) -%}
        {%- if classification -%}
            {{ log(modules.datetime.datetime.now().strftime("%H:%M:%S") ~ " | tagging column " ~ db ~ "." ~ schema ~ "." ~ alias ~ "." ~ col_name ~ " with " ~ db ~ "." ~ tag_schema ~ "." ~ tag_name ~ " = '" ~ classification ~ "' (policy applies via tag binding)", info=True) }}
            {%- set query %}
                alter {{ materialization }} {{ db }}.{{ schema }}.{{ alias }}
                modify column {{ col_name }}
                set tag {{ db }}.{{ tag_schema }}.{{ tag_name }} = '{{ classification }}'
            {%- endset -%}
            {%- do run_query(query) -%}
        {%- endif -%}
    {%- endfor -%}

{% endmacro %}
