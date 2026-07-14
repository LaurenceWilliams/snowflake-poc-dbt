{{
    config(
        materialized='table',
        post_hook=["{{ apply_tag_based_masking() }}"],
        tags=['test'],
    )
}}

-- Tag-based DDM counterpart to ddm_sample__test_model (same seed, same rows).
-- The ONLY difference is how the encrypt_pii policy reaches the email column:
--   * ddm_sample__test_model        -> per-column  SET MASKING POLICY   (dbt_snow_mask)
--   * ddm_sample__test_model_tagged -> via a TAG bound to the policy     (apply_tag_based_masking)
-- Run `dbt run-operation setup_pii_tag` ONCE before building this model so the
-- tag exists and is bound to encrypt_pii.
select *
from {{ ref('example__testing') }}
