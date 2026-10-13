{#
    Registers a dbt source's Glue-catalogued Iceberg tables (Fivetran Managed
    Data Lake, DEV-157656) on the current target. Run manually after adding
    tables to the source yml:

        dbt run-operation setup_iceberg_sources --args '{source_name: ft_data_platform_uploads}' --profiles-dir . --target snowflake
        dbt run-operation setup_iceberg_sources --args '{source_name: ft_data_platform_uploads}' --profiles-dir . --target redshift

    Metadata only on both engines -- data stays in S3, nothing is copied.

    Reads each source table's config.meta (source-level meta is inherited):
      catalog_namespace                             -- required, the Glue database
      snowflake: external_volume, catalog           -- required
                 catalog_table_name                 -- default: table name lowercased
                 auto_refresh                       -- default: true
      redshift:  iam_role                           -- required, a role attached to the cluster
#}
{% macro setup_iceberg_sources(source_name) %}

    {%- set nodes = graph.sources.values() | selectattr('source_name', 'equalto', source_name) | list -%}
    {%- if nodes | length == 0 -%}
        {{ exceptions.raise_compiler_error("setup_iceberg_sources: no enabled source named '" ~ source_name ~ "'") }}
    {%- endif -%}

    {%- if target.type == 'snowflake' -%}
        {{ _setup_iceberg_sources_snowflake(nodes) }}
    {%- elif target.type == 'redshift' -%}
        {{ _setup_iceberg_sources_redshift(nodes) }}
    {%- else -%}
        {{ exceptions.raise_compiler_error("setup_iceberg_sources: unsupported target type '" ~ target.type ~ "'") }}
    {%- endif -%}

{% endmacro %}


{#- Snowflake: one Iceberg table per source table. AUTO_REFRESH moves the
    pointer as Fivetran commits (polled every REFRESH_INTERVAL_SECONDS on the
    catalog integration, 300s). -#}
{% macro _setup_iceberg_sources_snowflake(nodes) %}

    {%- for node in nodes -%}
        {%- set meta = node.config.meta -%}
        {%- set relation = node.database ~ '.' ~ node.schema ~ '.' ~ node.identifier -%}
        {%- set auto_refresh = meta.get('auto_refresh', true) -%}

        {%- do run_query("create schema if not exists " ~ node.database ~ "." ~ node.schema) -%}

        {#- Always replace: the table is only a pointer (data stays in S3/Glue),
            so every run re-applies the yml settings and re-points a broken table.
            COPY GRANTS keeps privileges -- undocumented for Glue-catalog Iceberg
            tables but verified 2026-10-13. Replace still resets table history
            (streams go stale) and drops policies/tags. -#}
        {%- set ddl %}
            create or replace iceberg table {{ relation }}
              external_volume    = '{{ meta.external_volume }}'
              catalog            = '{{ meta.catalog }}'
              catalog_namespace  = '{{ meta.catalog_namespace }}'
              catalog_table_name = '{{ meta.get("catalog_table_name", node.name | lower) }}'
              auto_refresh       = {{ auto_refresh }}
              copy grants
        {%- endset -%}
        {%- do run_query(ddl) -%}
        {{ log("setup_iceberg_sources: replaced " ~ relation, info=true) }}
    {%- endfor -%}

{% endmacro %}


{#- Redshift: one Spectrum external schema per Glue database -- every Glue
    table shows up in it on its own, so there's no per-table DDL and no
    refresh (Spectrum reads the current Iceberg metadata at query time).
    IF NOT EXISTS rather than DROP/CREATE: the schema has no settings that
    drift per table, and dropping it would drop its grants. -#}
{% macro _setup_iceberg_sources_redshift(nodes) %}

    {%- set schemas = {} -%}
    {%- for node in nodes -%}
        {%- do schemas.update({node.schema: node.config.meta}) -%}
    {%- endfor -%}

    {%- for schema, meta in schemas.items() -%}
        {%- set check_sql = "select databasename from svv_external_schemas where schemaname = '" ~ schema ~ "'" -%}

        {#- Only create when missing: CREATE EXTERNAL SCHEMA needs CREATE on the
            database, which dev users usually lack -- an admin can pre-create
            the schema and grant USAGE, and this macro then just verifies it. -#}
        {%- if run_query(check_sql).rows | length == 0 -%}
            {%- set ddl %}
                create external schema if not exists {{ schema }}
                from data catalog
                database '{{ meta.catalog_namespace }}'
                region 'us-west-2'
                iam_role '{{ meta.iam_role }}'
            {%- endset -%}
            {%- do run_query(ddl) -%}
            {%- do run_query("commit") -%}
        {%- endif -%}

        {#- IF NOT EXISTS is a silent no-op when a regular schema already has
            this name -- fail loudly instead of reading the wrong thing. -#}
        {%- set check = run_query(check_sql) -%}
        {%- if check.rows | length == 0 -%}
            {{ exceptions.raise_compiler_error("setup_iceberg_sources: '" ~ schema ~ "' exists but is not an external schema") }}
        {%- elif check.rows[0][0] != meta.catalog_namespace -%}
            {{ exceptions.raise_compiler_error("setup_iceberg_sources: '" ~ schema ~ "' points at Glue database '" ~ check.rows[0][0] ~ "', expected '" ~ meta.catalog_namespace ~ "'") }}
        {%- endif -%}
        {{ log("setup_iceberg_sources: ensured external schema " ~ schema ~ " -> glue:" ~ meta.catalog_namespace, info=true) }}
    {%- endfor -%}

{% endmacro %}
