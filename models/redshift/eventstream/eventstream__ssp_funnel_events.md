{% docs eventstream__ssp_funnel_events__description %}
This model consolidates funnel events related to the Sitter Self Promotion (SSP) feature, captured across web and mobile platforms. It aggregates key user interactions — such as Promo Hub views, share actions, link copy actions, and Sitter Profile Views — by `provider_id` and `date_event`. 
{% enddocs %}

{% docs eventstream__ssp_funnel_events__provider_id %}
Unique identifier for the user performing the interaction. This may come directly from event metadata or be inferred via the `utm_term` using a lookup to resolve OPKs to person IDs.
{% enddocs %}

{% docs eventstream__ssp_funnel_events__date_event %}
The event date (truncated to day), used to group and aggregate user interactions chronologically.
{% enddocs %}

{% docs eventstream__ssp_funnel_events__views_web %}
Number of times the user viewed the referral sharing experience within the web (Promo hub). Includes mp_page_view on referral/SSP page categories and the ssp-page-load event.
{% enddocs %}

{% docs eventstream__ssp_funnel_events__views_mobile %}
Number of times the user viewed the referral sharing experience within the mobile app (Promo hub). Includes ssp-page-load, referrals-link-component-load (flowSource ssp/empm), and native-referral-share-experience-view events.
{% enddocs %}

{% docs eventstream__ssp_funnel_events__shares_web %}
Number of times the sitter clicked the share button after visiting the Promo hub on the web. This typically indicates intent to share, even if the share action wasn’t completed.
{% enddocs %}

{% docs eventstream__ssp_funnel_events__shares_mobile %}
Number of times the sitter clicked the share button after visiting the Promo hub on the mobile app. Includes native-referral-share-click and referrals-link-share-link-click/channel-click (flowSource empm/ssp). This typically indicates intent to share, even if the share action wasn’t completed.
{% enddocs %}

{% docs eventstream__ssp_funnel_events__copied_web %}
Number of times the user copied their referral link on the web interface on a given day. This only includes events tracked after the new promotion hub is launched (2025-03-24)
{% enddocs %}

{% docs eventstream__ssp_funnel_events__copied_mobile %}
Number of times the user copied their referral link through the mobile app on a given day. Includes referral-share-link-copied and referrals-link-copy-link-click (flowSource empm/ssp).
{% enddocs %}

{% docs eventstream__ssp_funnel_events__profile_view_web %}
Count of profile views initiated via shared links containing the specific UTM campaign tied to the SSP rollout (`utm_campaign=977262825`). This tracks user traffic driven by SSP sharing activity on the web.
{% enddocs %}