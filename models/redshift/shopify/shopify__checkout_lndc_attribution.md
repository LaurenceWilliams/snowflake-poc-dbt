{% docs shopify__checkout_lndc_attribution__description %}
This model uses only eventstream data to identify records where a user navigates to a checkout URL on the Rover store.  This is relatively hardcoded currently, as our only indicator of an eventstream checkout is a url structure.  

In case the user navigated to the same checkout page multiple times, we take the first record as the initial checkout.  For each checkout, we find the eventstream event that most recently had UTM parameters within 1 day.  If no utms are present, we take the direct attribution at point of checkout.  

This model uses a last non direct click (LNDC) attribution methodology, which matches all other attribution models at Rover.  The attribution window is 1 day.  Some orders in Shopify do not exist in the eventstream, due to ad blockers and cookie tracking issues.  
{% enddocs %}


{% docs shopify__checkout_lndc_attribution__attribution_timestamp %}
This is the timestamp of the most recent utm-containing eventstream event, if present.  If there are no utm containing events (direct), this will match the checkout timestamp.  

In most cases (95%+) this matches the checkout timestamp.  This is because the utm parameters persist through the session and most purchases happen in the same session as the initial click.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__checkout_timestamp %}
This is the first timestamp the user landed on the checkout page for this given order.  If one user has multiple checkouts, there will be multiple rows with different checkout timestamps.  Each checkout url is unique to an order.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__client_current_url %}
This is the checkout url, including utm parameters if present at checkout.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__client_referrer %}
This is the referring column for the attribution event.  For example, a user from a google search might have "Google" as a client_referrer
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__distinct_id %}
The internal opk for a user, which is cookie based.  There can be multiple disitnct_ids for any one user. All sessionized attribution uses this value.  If a customer resets their cookies, the distinct_id is also reset.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__id %}
An MD5 hash of the distinct id and the checkout url.  Tested for uniqueness.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__utm_campaign %}
The utm parameter which can be tied to a campaign for the attribution event selected.  This is one of five utm parameters.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__utm_campaign_email_join %}
An edited utm parameter which can be tied to a campaign for the attribution event selected.  For any utm_campaign that starts with "rover.", as is the standard for responsys, this trims the first 6 characters out.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__utm_content %}
The utm parameter which can be tied to a campaign for the attribution event selected.  This is one of five utm parameters.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__utm_medium %}
The utm parameter which can be tied to a campaign for the attribution event selected.  This is one of five utm parameters.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__utm_source %}
The utm parameter which can be tied to a campaign for the attribution event selected.  This is one of five utm parameters.
{% enddocs %}

{% docs shopify__checkout_lndc_attribution__utm_term %}
The utm parameter which can be tied to a campaign for the attribution event selected.  This is one of five utm parameters.
{% enddocs %}
