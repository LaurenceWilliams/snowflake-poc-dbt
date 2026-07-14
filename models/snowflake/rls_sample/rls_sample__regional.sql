{{
    config(
        materialized='table',
        post_hook=["{{ apply_row_access_policy('country') }}"],
        tags=['test'],
    )
}}

-- Row-level security (RLS) demo. The country_row_access policy filters rows by
-- the querying role's entitlements in entitlements__country_access:
--   * DATA_PLATFORM                -> all rows (full-access escape hatch)
--   * POC USERS - SNOWFLAKE-OKTA   -> US + CA rows only (per the mapping table)
--   * any other role               -> no rows
-- Run `dbt run-operation setup_row_access_policy` ONCE (after seeding) so the
-- policy exists before this model attaches it.
select *
from {{ ref('example__regional') }}
