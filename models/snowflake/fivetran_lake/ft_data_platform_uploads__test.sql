{{ config(materialized='view') }}

-- Thin view over the Iceberg source: proves a dbt model can ref() a
-- Glue-backed Iceberg table like any other Snowflake table.
-- No _fivetran_deleted filter: file-upload tables (keyed by _line) have no
-- soft-delete column -- Glue/Iceberg schema is _line, _fivetran_synced + data.
select *
from {{ source('ft_data_platform_uploads', 'test') }}
