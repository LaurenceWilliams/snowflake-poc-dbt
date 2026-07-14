{{
    config(
        materialized='table',
        tags=['test'],
    )
}}

select *
from {{ ref('example__testing') }}