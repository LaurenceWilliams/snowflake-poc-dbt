{{
  config(
    materialized='view',
    bind=False,
  )
}}

-- Thin view over the Spectrum external table: proves a dbt model can read the
-- same Glue-backed Iceberg table Snowflake reads. bind=False is required --
-- Redshift views over external tables must be late-binding.
-- No _fivetran_deleted filter: file-upload tables (keyed by _line) have no
-- soft-delete column -- Glue/Iceberg schema is _line, _fivetran_synced + data.
select *
from {{ source('ft_data_platform_uploads', 'test') }}
