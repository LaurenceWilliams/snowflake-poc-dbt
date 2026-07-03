{{
  config(
    materialized='view',
  )
}}

-- Snowflake dialect. Translated from the Redshift model by SnowConvert AI (scai)
-- off the dbt-compiled SQL. Redshift-only configs (dist='all', bind) dropped;
-- body verbatim from scai output, refs repointed to source().

with
  stays_stay as (
    select * from {{ source('roverdb', 'stays_stay') }}
  )
  , conversations_conversation as (
    select * from {{ source('roverdb', 'conversations_conversation') }}
  )
  , conversations_request as (
    select * from {{ source('roverdb', 'conversations_request') }}
  )
  , conversations_requestdate as (
    select * from {{ source('roverdb', 'conversations_requestdate') }}
  )

  , all_requests as (
  select distinct
    ss.id as stay_id
    , cr.conversation_id
    , cr.status as request_status
    /* Get the most recent request date record associated with the conversation. Request dates represent units. Requests with no corresponding request date will represent requests with zero units. */
    , case
      when LAST_VALUE(crd.id) over (partition by cr.conversation_id, cr.status order by cr.added rows between unbounded preceding and unbounded following) is not null
        then 1
      else 0
      end as unit_added
  from
    stays_stay ss
  left join
      conversations_conversation cc on cc.id = ss.conversation_id
  left join
      conversations_request cr  on cc.id = cr.conversation_id
  left join
      conversations_requestdate crd on crd.object_id = cr.id
    and crd.content_type_id = 336 -- only Object IDs with content_type_id = 336 are request IDs
  where
    cc.recurring_billing_relationship_id IS NOT NULL
    and ss.status != 'cancelled'
    and ss.added >= '2024-08-08' -- Only include stay added after the recurring skipped weeks feature was tested or launched
  )
  , zero_unit_stays as (
  SELECT
    stay_id
    , conversation_id
    ,
    MAX(case when request_status = 'sentinel' then unit_added END) AS sentinel_unit_added
    ,
    MAX(case when request_status = 'accepted' then unit_added END)  AS accepted_unit_added
  FROM
    all_requests
  group by
    1,2
  /* Stay IDs that were initially created with zero units and remain at zero units will have their most recent sentinel request record and accepted request record have no units. */
  having sentinel_unit_added = 0 and accepted_unit_added = 0
  )

SELECT DISTINCT
  stay_id
  , conversation_id
FROM
    zero_unit_stays
