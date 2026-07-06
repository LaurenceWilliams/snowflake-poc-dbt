{% macro create_masking_policy_encrypt_pii(node_database,node_schema) %}

    CREATE MASKING POLICY IF NOT EXISTS {{node_database}}.{{node_schema}}.encrypt_pii AS (val string) 
        RETURNS string ->
            CASE WHEN CURRENT_ROLE() IN ('DATA_PLATFORM') THEN val 
                WHEN CURRENT_ROLE() IN ('POC USERS - SNOWFLAKE-OKTA') THEN SHA2(val)
            ELSE '**********'
            END

{% endmacro %}