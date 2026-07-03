-- Copied from rover-dbt models/shopify/shopify__checkout_lndc_attribution.sql and
-- neutralized for the benchmark: tags + grant hooks stripped; materialized=
-- 'incremental' + unique_key dropped so the folder-level `+materialized: table`
-- applies (we time the full CTAS). dist/sort kept — real Redshift physical tuning.
-- The is_incremental() blocks are left in place: they render to nothing under
-- table materialization, so the compiled SQL is the full-refresh query.
{{
  config(
    dist='id',
    sort=['checkout_timestamp'],
  )
}}

WITH

eventstream_web AS (
  SELECT * FROM {{ source('eventstream', 'web') }}
)

, eventstream_web_limited AS (
  -- First we pull the evenstream values that we need for this attribution, using the incremental
  -- model magic to make the daily run go much more quickly.
  SELECT
  distinct_id
  , utm_source
  , utm_medium
  , utm_campaign
  , utm_term
  , utm_content
  , metadata_timestamp
  , metadata_uuid
  , client_current_url
  , client_referrer
  , CASE WHEN utm_source IS NOT NULL OR
              utm_medium IS NOT NULL OR
              utm_campaign IS NOT NULL OR
              utm_term IS NOT NULL OR
              utm_content IS NOT NULL
         THEN 1
         ELSE 0
         END AS nondirect_flag
  FROM eventstream_web
  WHERE event_name = 'mp_page_view' AND
        -- below timestamp is 1 day before the first date a purhcase occurred (2020-02-13 @ 7 PM PST)
        -- this ensures we gather all data at least 1 day before the first purchase
        metadata_timestamp >= '2020-02-12'

        {% if is_incremental() %}

          -- this filter will only be applied on an incremental run
          -- the incremental run pulls the last 10 days and the full
          -- refresh pulls all history since the store was created
        AND metadata_timestamp >= getdate() - 10

        {% endif %}
)

, checkout_events_pre_window AS (
  -- As of July 2021, 6 unique cases exist where two different distinct_ids referenced the same client_current_url.
  -- As cookies can be reset, we want to find the details of the first time anyone landed on that checkout page.
  -- We will use a row_number window for this.
  SELECT
  distinct_id
  , client_current_url
  , metadata_timestamp AS checkout_timestamp
  , ROW_NUMBER() OVER (PARTITION BY client_current_url ORDER BY metadata_timestamp ASC) AS row_number_selection
  FROM eventstream_web_limited
  WHERE client_current_url LIKE '%store.rover.com/8681553999/checkouts/%' -- This is the checkout URL structure
)

, checkout_events AS (
  -- This finds the first instance from the above pre-window CTE
  SELECT
  distinct_id
  , client_current_url
  , checkout_timestamp
  FROM checkout_events_pre_window
  WHERE row_number_selection = 1
)

, joined_checkout_events AS (
  -- Now we can join the checkout events to all eventstream visits that happened within 1 day.
  -- To be sure we have at least 24 hours of data, we only want to grab the last 9 days of checkouts
  -- since we have 10 days of eventsream data to reference.
  SELECT
  checkout.distinct_id
  , checkout.client_current_url
  , checkout.checkout_timestamp
  , eventstream_web_limited.utm_source
  , eventstream_web_limited.utm_medium
  , eventstream_web_limited.utm_campaign
  , eventstream_web_limited.utm_term
  , eventstream_web_limited.utm_content
  , eventstream_web_limited.metadata_timestamp AS attribution_timestamp
  , eventstream_web_limited.client_referrer
  , eventstream_web_limited.nondirect_flag
  , ROW_NUMBER() OVER (PARTITION BY checkout.distinct_id, checkout.client_current_url -- these are unique to an order
                       ORDER BY eventstream_web_limited.nondirect_flag DESC, -- We prioritze nondirect clicks first, even if they are not the most recent
                                eventstream_web_limited.metadata_timestamp DESC, -- For all records we join, we want the most recent within the nondirect flag
                                eventstream_web_limited.metadata_uuid DESC -- Ties on metadata_timestamp happen super rarely, so have a tiebreaker for consistency
                      ) AS priority_row_number
  FROM checkout_events checkout
  LEFT JOIN eventstream_web_limited
  ON checkout.distinct_id = eventstream_web_limited.distinct_id AND
     checkout.checkout_timestamp >= eventstream_web_limited.metadata_timestamp AND
     checkout.checkout_timestamp < eventstream_web_limited.metadata_timestamp + 1

  {% if is_incremental() %}

   -- this filter will only be applied on an incremental run
   -- the incremental run pulls the last 9 days of checkouts
   WHERE checkout.checkout_timestamp >= getdate() - 9

   {% endif %}
)

SELECT
distinct_id
, client_current_url
, {{ hpst('checkout_timestamp') }} AS checkout_timestamp
, {{ hpst('attribution_timestamp') }} AS attribution_timestamp
, COALESCE(utm_source, '') AS utm_source
, COALESCE(utm_medium, '') AS utm_medium
, COALESCE(utm_campaign, '') AS utm_campaign
, COALESCE(utm_term, '') AS utm_term
, COALESCE(utm_content, '') AS utm_content
, CASE WHEN utm_campaign ilike '%rover.%'
       THEN REPLACE(utm_campaign, 'rover.', '')
       ELSE COALESCE(utm_campaign, '')
       END AS utm_campaign_email_join
, client_referrer
, MD5(distinct_id::VARCHAR || client_current_url::VARCHAR) AS id
FROM joined_checkout_events
WHERE priority_row_number = 1
