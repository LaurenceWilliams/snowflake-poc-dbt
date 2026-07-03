/*
Copied from rover-dbt (macros/modeling_general/hpst.sql) for the PoC benchmark.
Only the base hpst() macro is needed here (shopify__checkout_lndc_attribution).

Note: rover-dbt's original file warns "these only work in Redshift", but
CONVERT_TIMEZONE('America/Los_Angeles', <ts>) is valid, identical syntax on
Snowflake too — so the SAME macro serves both targets.
*/

{% macro hpst(utc_timestamp) %}
  convert_timezone('America/Los_Angeles', {{ utc_timestamp }})
{% endmacro %}
