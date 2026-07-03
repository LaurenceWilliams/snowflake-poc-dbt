-- Copied from rover-dbt models/eventstream/eventstream__ssp_funnel_events.sql and
-- neutralized for the benchmark: tags stripped; materialized='incremental' dropped
-- so the folder-level `+materialized: table` applies (we time the full CTAS).
-- dist/sort kept — real Redshift physical tuning. The is_incremental() block is
-- left in place: it renders to nothing under table materialization.
{{
  config(
    dist='provider_id',
    sort=['date_event', 'provider_id'],
  )
}}



WITH
  WEB AS (
    SELECT * FROM {{ source('eventstream', 'web')}}
  )
  , MOBILE AS (
    SELECT * FROM {{ source('eventstream', 'mobile')}}
  ),
  person_opk2id_lookup AS (
    SELECT * FROM {{ source('util','person_opk2id_lookup')}}
  )


, WEB_EVENTS AS (
  SELECT
    person_id
    , common_id
    , DATE_TRUNC ('day', metadata_timestamp) as date_event
    , event_name
    , page_category
    , utm_term
    , client_current_url
  FROM
    WEB
  WHERE TRUE
    AND metadata_timestamp >= '2024-04-01'::timestamp
    AND (is_bot = FALSE OR is_bot IS NULL)
)
, PROFILE_VIEW_EVENTS AS (
  SELECT DISTINCT
    CASE
        WHEN POL.person_id IS NOT NULL THEN POL.person_id
        WHEN TRY_CAST(utm_term AS BIGINT) IS NOT NULL THEN TRY_CAST(utm_term AS BIGINT)
    ELSE NULL END AS person_id
    , date_event
    , common_id AS profile_view
    , client_current_url
  FROM
    WEB_EVENTS W
  LEFT JOIN
    person_opk2id_lookup POL ON W.utm_term = POL.person_opk
  WHERE TRUE
    AND event_name = 'mp_page_view'
    AND client_current_url ilike '%utm_campaign=977262825%'
)
, SSP_WEB_EVENTS AS (
  SELECT
    person_id
    , date_event
    , SUM(CASE WHEN event_name = 'mp_page_view' AND page_category = 'provider-profile:share-your-profile' THEN 1
               WHEN event_name = 'mp_page_view' AND page_category = 'referrals' THEN 1
               WHEN event_name = 'ssp-page-load' THEN 1
               ELSE 0 END) AS view
    , SUM(CASE WHEN event_name = 'outbound-link-click' AND page_category IN ('referrals','provider-profile:promote-craigslist','provider-profile:share-your-profile') THEN 1
               WHEN event_name IN ('referrals-link-share-link-click','referrals-link-share-link-channel-click') and page_category = 'referrals' THEN 1
               ELSE 0 END) AS share
    , SUM(CASE WHEN event_name = 'referrals-link-copy-link-click' AND page_category = 'referrals' THEN 1 ELSE 0 END) AS copied
  FROM
    WEB_EVENTS
  WHERE TRUE
    AND (
      page_category IN
        ('provider-profile:share-your-profile'
        , 'referrals'
        , 'provider-profile:account-profile'
        , 'provider-profile:promote-craigslist')
      OR event_name = 'ssp-page-load'
    )
  GROUP BY 1, 2
)
, SSP_MOBILE_EVENTS AS (
  SELECT
    person_id
    , DATE_TRUNC ('day', metadata_timestamp) as date_event
    , SUM(CASE WHEN event_name = 'ssp-page-load' THEN 1
               WHEN event_name = 'referrals-link-component-load' AND JSON_EXTRACT_PATH_TEXT(properties,'flowSource') IN ('ssp','empm') THEN 1
               WHEN event_name = 'native-referral-share-experience-view' THEN 1
               ELSE 0 END) AS view
    , SUM(CASE WHEN event_name in ('native-referral-share-click') THEN 1
               WHEN event_name in ('referrals-link-share-link-click','referrals-link-share-link-channel-click')
               AND JSON_EXTRACT_PATH_TEXT(properties,'flowSource') IN ('empm','ssp') THEN 1
               ELSE 0 END) AS share
    , SUM(CASE WHEN event_name in ('referral-share-link-copied') THEN 1
               WHEN event_name in ('referrals-link-copy-link-click')
               AND JSON_EXTRACT_PATH_TEXT(properties,'flowSource') IN ('empm','ssp') THEN 1
               ELSE 0 END) AS copied
  FROM
    MOBILE
  WHERE TRUE
    AND event_name IN
      ('native-referral-share-experience-view'
      , 'native-referral-share-click'
      , 'referrals-link-share-link-click'
      , 'referrals-link-share-link-channel-click'
      , 'referral-share-link-copied'
      , 'referrals-link-copy-link-click'
      , 'ssp-page-load'
      , 'referrals-link-component-load')
    AND metadata_timestamp >= '2024-04-01'::timestamp
  GROUP BY 1, 2
)
, ALL_USERS AS (
  SELECT person_id, date_event FROM PROFILE_VIEW_EVENTS WHERE person_id IS NOT NULL
    UNION
  SELECT person_id, date_event FROM SSP_WEB_EVENTS
    UNION
  SELECT person_id, date_event FROM SSP_MOBILE_EVENTS
)
SELECT
  AU.person_id AS provider_id
  , AU.date_event
  , COALESCE(SWE.view, 0) AS views_web
  , COALESCE(SME.view, 0) AS views_mobile
  , COALESCE(SWE.share, 0) AS shares_web
  , COALESCE(SME.share, 0) AS shares_mobile
  , COALESCE(SWE.copied, 0) AS copied_web
  , COALESCE(SME.copied, 0) AS copied_mobile
  , COUNT(DISTINCT PVE.profile_view) AS profile_view_web
FROM
  ALL_USERS AU
LEFT JOIN
  SSP_WEB_EVENTS SWE ON AU.person_id = SWE.person_id AND AU.date_event = SWE.date_event
LEFT JOIN
  SSP_MOBILE_EVENTS SME ON AU.person_id = SME.person_id AND AU.date_event = SME.date_event
LEFT JOIN
  PROFILE_VIEW_EVENTS PVE ON AU.person_id = PVE.person_id AND AU.date_event = PVE.date_event
WHERE 1=1
  {% if is_incremental() %}
  AND AU.date_event >= (SELECT MAX(date_event) FROM {{ this }} WHERE date_event <= CURRENT_TIMESTAMP)
  {% endif %}
GROUP BY
  1,2,3,4,5,6,7,8
HAVING
  views_web + views_mobile + shares_web + shares_mobile + copied_web + copied_mobile + profile_view_web > 0
