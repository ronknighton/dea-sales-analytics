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
-- and owning activity type attached. This is the mechanism that
-- resolved the outcome-value duplication found during requirements
-- analysis: '3. No Show' and '4. No Show' aren't duplicates, they're
-- values from two different fields (Follow Up Call Outcome vs. Strategy
-- Call Outcome) that happen to share label text — this view keeps that
-- distinction visible instead of flattening it away.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW FACT_LEAD_FUNNEL AS
SELECT
    lap.LEAD_ID,
    lap.ACTIVITY_ID,
    lap.ACTIVITY_AT,
    caf.CUSTOM_ACTIVITY_TYPE_NAME,
    caf.FIELD_NAME,
    lap.FULL_RECORD:custom[caf.FIELD_ID]::string AS OUTCOME_VALUE,
    lap.FULL_RECORD:user_id::string AS RECORD_USER_ID
FROM SILVER.LEAD_ACTIVITIES_PROCESSED lap,
     LATERAL FLATTEN(input => OBJECT_KEYS(lap.FULL_RECORD:custom)) k
JOIN SILVER.CUSTOM_ACTIVITY_FIELDS caf
    ON caf.FIELD_ID = k.value::string;
