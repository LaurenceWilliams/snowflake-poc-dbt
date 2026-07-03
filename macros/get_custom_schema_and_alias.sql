/*
Adapted for the Snowflake PoC from rover-dbt's schema/alias macro
(orig. maintainer: Brandyn Lee <brandyn@rover.com>).

Purpose: keep the SAME logical model routing to sensible relations on both engines,
splitting the '__' name into schema + table on Snowflake, and — because Snowflake
stores unquoted identifiers in UPPERCASE — emitting DATABASE / SCHEMA / ALIAS in
uppercase there so dbt's relation names match what Snowflake actually creates.

  model: standard_reports__bookings_zero_units
    --target redshift_serverless  ->  <target.schema>.standard_reports__bookings_zero_units
                                      (e.g. dbt_laurence_williams.* — Redshift dev is single-schema,
                                       so the FULL model name is the table to avoid collisions)
    --target snowflake            ->  <TARGET.DATABASE>.STANDARD_REPORTS.BOOKINGS_ZERO_UNITS
                                      (Snowflake fans out into per-domain schemas: the '__' prefix
                                       becomes the schema, the suffix the table; all UPPERCASED)

Database is left to dbt's default (target.database), i.e. the Snowflake default DB.
*/

{% macro generate_database_name(custom_database_name=none, node=none) -%}
    {%- set database = custom_database_name if custom_database_name is not none else target.database -%}
    {%- if target.type == 'snowflake' -%}
        {{ database | trim | upper }}
    {%- else -%}
        {{ database | trim }}
    {%- endif -%}
{%- endmacro %}


{% macro generate_schema_name(custom_schema_name=none, node=none) -%}

    {#- Snowflake: fan models out into per-domain schemas within the default DB.
        Schema = the model-name prefix before '__'
        (standard_reports__bookings_zero_units -> schema 'standard_reports').
        An explicit +schema config wins; a model with no '__' prefix falls back
        to target.schema. Emitted UPPERCASE. dbt auto-creates the schema. -#}
    {%- if target.type == 'snowflake' -%}
        {%- if custom_schema_name is not none -%}
            {%- set schema = custom_schema_name | trim -%}
        {%- elif node is not none and '__' in node.name -%}
            {%- set schema = node.name.split('__')[0] | trim -%}
        {%- else -%}
            {%- set schema = target.schema | trim -%}
        {%- endif -%}
        {{ schema | upper }}

    {#- Redshift dev: everything lands in the one target schema (e.g.
        dbt_laurence_williams), mirroring rover-dbt's single-schema dev setup. -#}
    {%- else -%}
        {{ target.schema }}
    {%- endif -%}

{%- endmacro %}


{% macro generate_alias_name(custom_alias_name=none, node=none) -%}

    {#- Snowflake: the schema carries the '__' prefix, so the table is just the
        suffix (standard_reports__bookings_zero_units -> bookings_zero_units).
        Split on the FIRST '__' so names like a__b__c keep 'b__c' as the alias.
        An explicit +alias config wins; no '__' falls back to the full name.
        Emitted UPPERCASE. -#}
    {%- if target.type == 'snowflake' -%}
        {%- if custom_alias_name is not none -%}
            {%- set alias = custom_alias_name | trim -%}
        {%- elif node is not none and '__' in node.name -%}
            {%- set alias = node.name.split('__', 1)[1] | trim -%}
        {%- else -%}
            {%- set alias = node.name -%}
        {%- endif -%}
        {{ alias | upper }}

    {#- Redshift (single schema): full model name as the table identifier
        (an explicit +alias config still wins). -#}
    {%- elif custom_alias_name is not none -%}
        {{ custom_alias_name | trim }}
    {%- else -%}
        {{ node.name }}
    {%- endif -%}

{%- endmacro %}
