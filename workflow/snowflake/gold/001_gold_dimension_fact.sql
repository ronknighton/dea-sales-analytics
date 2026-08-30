-- ============================================================================
-- Sales Analytics Pipeline — Gold Layer: Dimension + Fact
-- Solution Design Doc Section 4.4
-- ============================================================================
-- All Gold objects are VIEWs, not tables — they query Silver live, so
-- there's no daily rebuild/Task needed for this file the way Bronze/
-- Silver required. Deployed via CI like everything else.

USE DATABASE SALES_ANALYTICS_PIPELINE;
USE SCHEMA GOLD;

-- ----------------------------------------------------------------------------
-- DIM_USERS — IS_INTERNAL flag is a working assumption (Open Item #5),
-- not SME-confirmed. Kept queryable rather than filtering rows out here,
-- so the assumption can be reversed later without touching this view —
-- only the KPI views below that filter WHERE NOT IS_INTERNAL would need
-- updating.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW DIM_USERS AS
SELECT
    USER_ID,
    EMAIL,
    FIRST_NAME,
    LAST_NAME,
    FIRST_NAME || ' ' || LAST_NAME AS FULL_NAME,
    ROLE,
    STATUS,
    CASE
        WHEN EMAIL ILIKE '%dataengineeracademy.com'
          OR EMAIL ILIKE '%dataengineeracadmy.com'
          OR EMAIL ILIKE '%datanengineeracademy.com'
        THEN TRUE ELSE FALSE
    END AS IS_INTERNAL
FROM SILVER.CLOSE_CRM_USERS_PROCESSED;

-- ----------------------------------------------------------------------------
-- FACT_LEAD_FUNNEL — resolves every custom.cf_XXXX key on a lead
-- activity against the CUSTOM_ACTIVITY_FIELDS dictionary (Silver),
-- producing one row per (activity, field) with the field's real name
-- and owning activity type attached.
--
-- CORRECTED after a real production bug: custom.cf_XXXX are FLAT
-- top-level keys on FULL_RECORD, with a literal period in the key name
-- (e.g. "custom.cf_3JFRKeLpnUvmsOsVG478u5iAQZ5i5dPmvKbIkYLUaaH") — NOT
-- nested under a "custom" object as originally assumed. The original
-- version (OBJECT_KEYS(lap.FULL_RECORD:custom)) always evaluated to
-- NULL, since no record anywhere has a nested "custom" key, making this
-- view empty for every deploy regardless of how much real data existed
-- upstream. This matches the requirements doc's own Phase 3 language
-- ("extracting keys containing %custom.%" — a LIKE-style wildcard,
-- describing a flat prefix, not a nested path) which was correct all
-- along and simply not followed in the original implementation.
--
-- Also now filters to _type = 'CustomActivity' — confirmed necessary,
-- not just assumed, after finding SMS/Call/Email/Note/Meeting/Created/
-- LeadMerge records (91% of LEAD_ACTIVITIES_PROCESSED in production
-- data) have no custom.* keys at all and would otherwise contribute
-- nothing but wasted FLATTEN work.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW FACT_LEAD_FUNNEL AS
SELECT
    lap.LEAD_ID,
    lap.ACTIVITY_ID,
    lap.ACTIVITY_AT,
    caf.CUSTOM_ACTIVITY_TYPE_NAME,
    caf.FIELD_NAME,
    lap.FULL_RECORD[k.value::string]::string AS OUTCOME_VALUE,
    lap.FULL_RECORD:user_id::string AS RECORD_USER_ID
FROM SILVER.LEAD_ACTIVITIES_PROCESSED lap,
     LATERAL FLATTEN(input => OBJECT_KEYS(lap.FULL_RECORD)) k
JOIN SILVER.CUSTOM_ACTIVITY_FIELDS caf
    ON k.value::string = 'custom.' || caf.FIELD_ID
WHERE lap.FULL_RECORD:_type::string = 'CustomActivity';