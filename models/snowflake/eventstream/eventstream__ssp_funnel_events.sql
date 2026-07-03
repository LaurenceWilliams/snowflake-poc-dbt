-- Snowflake dialect. Translated from the Redshift model by SnowConvert AI (scai)
-- off the dbt-compiled SQL. Redshift-only configs (dist/sort) dropped; folder-level
-- `+materialized: table` applies. Body verbatim from scai output, refs repointed to
-- source(). scai changes: `view` quoted (Snowflake reserved word), IN-list literals
-- wrapped in RTRIM() (CHAR trailing-space emulation, harmless), JSON_EXTRACT_PATH_TEXT
-- path rewritten via ARRAY_TO_STRING (reduces to the same 'flowSource' string),
-- `ESCAPE '\\'` appended to ilike, trailing semicolon + SSC-FDM marker + BOM stripped.
-- One EWI resolved by hand: SSC-EWI-0073 flagged TRY_CAST for functional-equivalence
-- review — Redshift and Snowflake TRY_CAST both take a VARCHAR and return NULL on a
-- failed cast, so the markers were removed and TRY_CAST kept verbatim.

WITH
  WEB AS (
    SELECT * FROM
      {{ source('eventstream', 'web') }}
  )
  , MOBILE AS (
    SELECT * FROM
      {{ source('eventstream', 'mobile') }}
  ),
  person_opk2id_lookup AS (
    SELECT * FROM
      {{ source('util', 'person_opk2id_lookup') }}
  )

, WEB_EVENTS AS (
  SELECT
    person_id
    , common_id
    ,
    DATE_TRUNC('day', metadata_timestamp) as date_event
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
    AND client_current_url ilike '%utm_campaign=977262825%' ESCAPE '\\'
  )
, SSP_WEB_EVENTS AS (
  SELECT
    person_id
    , date_event
    ,
    SUM(CASE WHEN event_name = 'mp_page_view' AND page_category = 'provider-profile:share-your-profile' THEN 1
               WHEN event_name = 'mp_page_view' AND page_category = 'referrals' THEN 1
               WHEN event_name = 'ssp-page-load' THEN 1
               ELSE 0 END) AS "view"
    ,
    SUM(CASE WHEN event_name = 'outbound-link-click' AND page_category IN (RTRIM('referrals'), RTRIM('provider-profile:promote-craigslist'), RTRIM('provider-profile:share-your-profile'))
          THEN 1
               WHEN event_name IN (RTRIM('referrals-link-share-link-click'), RTRIM('referrals-link-share-link-channel-click'))
        and page_category = 'referrals' THEN 1
               ELSE 0 END) AS share
    ,
    SUM(CASE WHEN event_name = 'referrals-link-copy-link-click' AND page_category = 'referrals' THEN 1 ELSE 0 END) AS copied
  FROM
    WEB_EVENTS
  WHERE TRUE
    AND (
      page_category IN (RTRIM('provider-profile:share-your-profile'), RTRIM('referrals'), RTRIM('provider-profile:account-profile'), RTRIM('provider-profile:promote-craigslist'))
      OR event_name = 'ssp-page-load'
    )
  GROUP BY 1, 2
  )
, SSP_MOBILE_EVENTS AS (
  SELECT
    person_id
    ,
    DATE_TRUNC('day', metadata_timestamp) as date_event
    ,
    SUM(CASE WHEN event_name = 'ssp-page-load' THEN 1
               WHEN event_name = 'referrals-link-component-load' AND JSON_EXTRACT_PATH_TEXT(properties, ARRAY_TO_STRING(['flowSource'], '.')) IN (RTRIM('ssp'), RTRIM('empm'))
          THEN 1
               WHEN event_name = 'native-referral-share-experience-view' THEN 1
               ELSE 0 END) AS "view"
    ,
    SUM(CASE WHEN event_name in (RTRIM('native-referral-share-click'))
          THEN 1
               WHEN event_name in (RTRIM('referrals-link-share-link-click'), RTRIM('referrals-link-share-link-channel-click'))
               AND JSON_EXTRACT_PATH_TEXT(properties, ARRAY_TO_STRING(['flowSource'], '.')) IN (RTRIM('empm'), RTRIM('ssp'))
          THEN 1
               ELSE 0 END) AS share
    ,
    SUM(CASE WHEN event_name in (RTRIM('referral-share-link-copied'))
          THEN 1
               WHEN event_name in (RTRIM('referrals-link-copy-link-click'))
               AND JSON_EXTRACT_PATH_TEXT(properties, ARRAY_TO_STRING(['flowSource'], '.')) IN (RTRIM('empm'), RTRIM('ssp'))
          THEN 1
               ELSE 0 END) AS copied
  FROM
    MOBILE
  WHERE TRUE
    AND event_name IN (RTRIM('native-referral-share-experience-view'), RTRIM('native-referral-share-click'), RTRIM('referrals-link-share-link-click'), RTRIM('referrals-link-share-link-channel-click'), RTRIM('referral-share-link-copied'), RTRIM('referrals-link-copy-link-click'), RTRIM('ssp-page-load'), RTRIM('referrals-link-component-load'))
    AND metadata_timestamp >= '2024-04-01'::timestamp
  GROUP BY 1, 2
  )
, ALL_USERS AS (
  SELECT person_id, date_event FROM
    PROFILE_VIEW_EVENTS
    WHERE person_id IS NOT NULL
    UNION
  SELECT person_id, date_event FROM
    SSP_WEB_EVENTS
    UNION
  SELECT person_id, date_event FROM
    SSP_MOBILE_EVENTS
  )
SELECT
  AU.person_id AS provider_id
  , AU.date_event
  ,
  COALESCE(SWE."view", 0) AS views_web
  ,
  COALESCE(SME."view", 0) AS views_mobile
  ,
  COALESCE(SWE.share, 0) AS shares_web
  ,
  COALESCE(SME.share, 0) AS shares_mobile
  ,
  COALESCE(SWE.copied, 0) AS copied_web
  ,
  COALESCE(SME.copied, 0) AS copied_mobile
  ,
  COUNT(DISTINCT PVE.profile_view) AS profile_view_web
FROM
  ALL_USERS AU
LEFT JOIN
    SSP_WEB_EVENTS SWE ON AU.person_id = SWE.person_id AND AU.date_event = SWE.date_event
LEFT JOIN
    SSP_MOBILE_EVENTS SME ON AU.person_id = SME.person_id AND AU.date_event = SME.date_event
LEFT JOIN
    PROFILE_VIEW_EVENTS PVE ON AU.person_id = PVE.person_id AND AU.date_event = PVE.date_event
WHERE 1=1

GROUP BY
  1,2,3,4,5,6,7,8
HAVING
  views_web + views_mobile + shares_web + shares_mobile + copied_web + copied_mobile + profile_view_web > 0
