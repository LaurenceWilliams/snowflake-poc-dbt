-- Connectivity smoke test for the GitHub Actions -> Snowflake key-pair auth path
-- (Option 2). A green build proves CI can authenticate non-interactively, take a
-- warehouse, and write a table — with no IP allowlist / VPC networking.
--
-- Pinned to the github_ci database in config() so CI writes land in a dedicated
-- database, isolated from personal/PoC data. The workflow creates this database
-- (via the create_ci_database run-operation) before this model builds.
{{ config(
    database='github_ci',
    materialized='table'
) }}

select

    'github-actions'    as ran_from,
    current_user()      as sf_user,
    current_role()      as sf_role,
    current_warehouse() as sf_warehouse,
    current_database()  as sf_database,
    current_timestamp() as ran_at
