{{
  config(
    materialized='table',
  )
}}

-- Snowflake dialect. Translated from the Redshift model by SnowConvert AI (scai)
-- off the dbt-compiled SQL (brand_launches loop already unrolled at compile time).
-- Redshift-only configs (dist/sort) dropped; body verbatim from scai output,
-- refs repointed to source()/ref(). scai's substantive changes: IGNORE NULLS moved
-- outside first_value(), "start" quoted, IN-list literals wrapped in RTRIM().

with
  stays_stay as (
    select * from {{ source('roverdb', 'stays_stay') }}
  )
  , conversations_conversation as (
    select * from {{ source('roverdb', 'conversations_conversation') }}
  )
  , service_delivery_servicedelivery as (
    select * from {{ source('roverdb', 'service_delivery_servicedelivery') }}
  )
  , conversation_exclusion_list as (
    select * from {{ ref('standard_reports__conversation_exclusion_list') }}
  )
  , bookings_zero_units as (
    select * from {{ ref('standard_reports__bookings_zero_units') }}
  )
  , imports_importedrecord_stay as (
    select * from {{ source('roverdb', 'imports_importedrecord') }}
    where content_type_id = '371'
  )
  , bookings_filtered as (
      select ss.id, cc.requester_id, cc.brand, ss.added as reported_at_timestamp
        from
      stays_stay ss join
        conversations_conversation cc on cc.id = ss.conversation_id
      where (
        ss.added >= '2016-08-01'
        or ss.status <> 'pendingpay'
      )
      and ss.status <> 'cancel'
      and cc.service_type in (RTRIM(
      'overnight-boarding'), RTRIM('overnight-traveling'), RTRIM('drop-in'), RTRIM('dog-walking'), RTRIM('doggy-day-care'), RTRIM('on-demand-grooming'), RTRIM('dog-training'))
      union
      select ss.id, cc.requester_id, cc.brand,
      MIN(sd."start" ::timestamp) as reported_at_timestamp
        from
      stays_stay ss join
        conversations_conversation cc on cc.id = ss.conversation_id
        join
        service_delivery_servicedelivery sd on sd.conversation_id = cc.id
        where
      sd."start" is not null
      and sd."start" < GETDATE()
      and cc.service_type in (RTRIM(
      'on-demand-dog-walking'), RTRIM('on-demand-drop-in'))
      group by 1,2,3
  )

select distinct
  bf.requester_id
  ,
    MIN(bf.reported_at_timestamp) over (partition by bf.requester_id) as first_stay_added
  ,
    MIN(case when iir.object_id is null then bf.reported_at_timestamp

             when iir.source_name in (RTRIM('catinaflat_eu'), RTRIM('catinaflat_na'))
        then bf.reported_at_timestamp

        end)
             over (partition by bf.requester_id) as first_stay_added_any_brand

  ,
    MIN(case when

        iir.object_id is null and RTRIM(COALESCE(bf.brand, 'rover')) = RTRIM( 'rover')

      then bf.reported_at_timestamp end)
      over (partition by bf.requester_id) as first_stay_added_rover


  ,
    MIN(case when

        iir.source_name in (RTRIM('catinaflat_eu'), RTRIM('catinaflat_na'))
        or RTRIM(COALESCE(bf.brand, 'rover')) = RTRIM( 'catinaflat')

      then bf.reported_at_timestamp end)
      over (partition by bf.requester_id) as first_stay_added_catinaflat

  ,
    MIN(case when iir.source_name is null and RTRIM(COALESCE(bf.brand, 'rover')) = RTRIM( 'catinaflat')
      then bf.reported_at_timestamp end)
      over (partition by bf.requester_id) as first_stay_added_catinaflat_after_migration


  ,
    MIN(case when iir.source_name = 'dogbuddy' then bf.reported_at_timestamp end)
             over (partition by bf.requester_id) as first_stay_added_dogbuddy
  ,
    MIN(case when iir.source_name = 'dogvacay' then bf.reported_at_timestamp end)
             over (partition by bf.requester_id) as first_stay_added_dogvacay
  ,
    MIN(case when iir.source_name = 'gudog' then bf.reported_at_timestamp end)
             over (partition by bf.requester_id) as first_stay_added_gudog

  ,
    FIRST_VALUE(bf.id) over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id
  , first_value(case when iir.object_id is null then bf.id

                           when iir.source_name in (RTRIM('catinaflat_eu'), RTRIM('catinaflat_na'))
        then bf.id

                           end)
    IGNORE NULLS
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_any_brand

  , first_value(case when

              iir.object_id is null and RTRIM(COALESCE(bf.brand, 'rover')) = RTRIM( 'rover')

            then bf.id end)
    IGNORE NULLS
      over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as first_stay_id_rover


  , first_value(case when

              iir.source_name in (RTRIM('catinaflat_eu'), RTRIM('catinaflat_na'))
              or RTRIM(COALESCE(bf.brand, 'rover')) = RTRIM( 'catinaflat')

            then bf.id end)
    IGNORE NULLS
      over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as first_stay_id_catinaflat

  , first_value(case when iir.source_name is null and RTRIM(COALESCE(bf.brand, 'rover')) = RTRIM( 'catinaflat')
              then bf.id end)
    IGNORE NULLS
      over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as first_stay_id_catinaflat_after_migration


  , first_value(case when iir.source_name = 'dogbuddy' then bf.id end)
    IGNORE NULLS
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_dogbuddy
  , first_value(case when iir.source_name = 'dogvacay' then bf.id end)
    IGNORE NULLS
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_dogvacay
  , first_value(case when iir.source_name = 'gudog' then bf.id end)
    IGNORE NULLS
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_gudog
  , first_value(case when iir.object_id is null then bf.id end)
    IGNORE NULLS
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_non_imported
from
    bookings_filtered bf
left join
      imports_importedrecord_stay iir on iir.object_id = bf.id
left join
      bookings_zero_units bzu on bzu.stay_id = bf.id
left join
      conversation_exclusion_list cel on cel.stay_id = bf.id
where
  cel.stay_id is null
  and bzu.stay_id is null
