{{
  config(
    materialized='view',
  )
}}

-- Snowflake dialect. Translated from the Redshift model by SnowConvert AI (scai)
-- off the dbt-compiled SQL. Redshift-only configs (bind) dropped; body verbatim
-- from scai output, with hardcoded table refs repointed to source()/ref().

with
  conversations_conversation as (
    select * from {{ source('roverdb', 'conversations_conversation') }}
  )
  , stays_stay as (
    select * from {{ source('roverdb', 'stays_stay') }}
  )
select
  cc.id as conversation_id
  , need_id
  , ss.id as stay_id
from
  conversations_conversation cc
  left join
      stays_stay ss on
    ss.conversation_id = cc.id
where
  cc.id in (

    21173770,
    21156486,
    21155962,
    21155882,
    7464178,
    22045745,
    22090119,
    22046244,
    22045705,
    22045187,
    22045712,
    22045751,
    22046263,
    22045728,
    22045451,
    22045770,
    31138482,
    31138483

  )
