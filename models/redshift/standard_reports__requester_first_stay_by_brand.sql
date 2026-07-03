{{
  config(
    dist='requester_id',
    sort=['requester_id'],
  )
}}

{% set brand_launches = brand_launches() %}

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
        from stays_stay ss join conversations_conversation cc on cc.id = ss.conversation_id
      where (
        ss.added >= '2016-08-01'
        or ss.status <> 'pendingpay'
      )
      and ss.status <> 'cancel'
      and cc.service_type in (
        'overnight-boarding'
        , 'overnight-traveling'
        , 'drop-in'
        , 'dog-walking'
        , 'doggy-day-care'
        , 'on-demand-grooming'
        , 'dog-training'
      )
      union
      select ss.id, cc.requester_id, cc.brand, min(sd.start::timestamp) as reported_at_timestamp
        from stays_stay ss join conversations_conversation cc on cc.id = ss.conversation_id
        join service_delivery_servicedelivery sd on sd.conversation_id = cc.id
        where
      sd.start is not null
      and sd.start < getdate()
      and cc.service_type in (
        'on-demand-dog-walking'
        , 'on-demand-drop-in'
      )
      group by 1,2,3
  )

select distinct
  bf.requester_id
  , min(bf.reported_at_timestamp) over (partition by bf.requester_id) as first_stay_added
  , min(case when iir.object_id is null then bf.reported_at_timestamp
             {% for bl in brand_launches if bl.import_source_names is not none and bl.start <= modules.datetime.date.today().strftime('%Y-%m-%d') %}
             when iir.source_name in ({% for src in bl.import_source_names %}'{{ src }}'{% if not loop.last %}, {% endif %}{% endfor %}) then bf.reported_at_timestamp
             {% endfor %}
        end)
             over (partition by bf.requester_id) as first_stay_added_any_brand
  {% for bl in brand_launches %}
  , min(case when
      {% if bl.import_source_names is none %}
        iir.object_id is null and coalesce(bf.brand, 'rover') = '{{ bl.brand }}'
      {% else %}
        iir.source_name in ({% for src in bl.import_source_names %}'{{ src }}'{% if not loop.last %}, {% endif %}{% endfor %})
        or coalesce(bf.brand, 'rover') = '{{ bl.brand }}'
      {% endif %}
      then bf.reported_at_timestamp end)
      over (partition by bf.requester_id) as first_stay_added_{{ bl.brand }}
  {% if bl.import_source_names is not none %}
  , min(case when iir.source_name is null and coalesce(bf.brand, 'rover') = '{{ bl.brand }}'
      then bf.reported_at_timestamp end)
      over (partition by bf.requester_id) as first_stay_added_{{ bl.brand }}_after_migration
  {% endif %}
  {% endfor %}
  , min(case when iir.source_name = 'dogbuddy' then bf.reported_at_timestamp end)
             over (partition by bf.requester_id) as first_stay_added_dogbuddy
  , min(case when iir.source_name = 'dogvacay' then bf.reported_at_timestamp end)
             over (partition by bf.requester_id) as first_stay_added_dogvacay
  , min(case when iir.source_name = 'gudog' then bf.reported_at_timestamp end)
             over (partition by bf.requester_id) as first_stay_added_gudog

  , first_value(bf.id) over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id
  , first_value(case when iir.object_id is null then bf.id
                     {% for bl in brand_launches if bl.import_source_names is not none and bl.start <= modules.datetime.date.today().strftime('%Y-%m-%d') %}
                     when iir.source_name in ({% for src in bl.import_source_names %}'{{ src }}'{% if not loop.last %}, {% endif %}{% endfor %}) then bf.id
                     {% endfor %}
                     end ignore nulls)
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_any_brand
  {% for bl in brand_launches %}
  , first_value(case when
      {% if bl.import_source_names is none %}
        iir.object_id is null and coalesce(bf.brand, 'rover') = '{{ bl.brand }}'
      {% else %}
        iir.source_name in ({% for src in bl.import_source_names %}'{{ src }}'{% if not loop.last %}, {% endif %}{% endfor %})
        or coalesce(bf.brand, 'rover') = '{{ bl.brand }}'
      {% endif %}
      then bf.id end ignore nulls)
      over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as first_stay_id_{{ bl.brand }}
  {% if bl.import_source_names is not none %}
  , first_value(case when iir.source_name is null and coalesce(bf.brand, 'rover') = '{{ bl.brand }}'
      then bf.id end ignore nulls)
      over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as first_stay_id_{{ bl.brand }}_after_migration
  {% endif %}
  {% endfor %}
  , first_value(case when iir.source_name = 'dogbuddy' then bf.id end ignore nulls)
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_dogbuddy
  , first_value(case when iir.source_name = 'dogvacay' then bf.id end ignore nulls)
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_dogvacay
  , first_value(case when iir.source_name = 'gudog' then bf.id end ignore nulls)
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_gudog
  , first_value(case when iir.object_id is null then bf.id end ignore nulls)
                     over (partition by bf.requester_id order by bf.reported_at_timestamp, bf.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING )  as first_stay_id_non_imported
from bookings_filtered bf
left join imports_importedrecord_stay iir on iir.object_id = bf.id
left join bookings_zero_units bzu on bzu.stay_id = bf.id
left join conversation_exclusion_list cel on cel.stay_id = bf.id
where
  cel.stay_id is null
  and bzu.stay_id is null
