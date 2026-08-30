-- ============================================================================
-- Sales Analytics Pipeline — Gold Layer: KPI Views
-- Solution Design Doc Section 4.4, Requirements Doc Section 3 (business
-- hierarchy) and Section 6 (report definitions)
-- ============================================================================
-- Each view pivots FACT_LEAD_FUNNEL's one-row-per-(activity,field) shape
-- into one-row-per-activity using MAX(CASE WHEN FIELD_NAME = ...), since
-- an activity's Setter, Closer, Outcome, etc. all need to appear as
-- separate columns on the same row for these reports.
--
-- Field names used below (Setter, Closer, Strategy Call Outcome, Offer
-- Presented, Contract Value, Cash Collected, Program) are confirmed real
-- field names from direct inspection of the raw custom_activites_raw
-- data — not guessed.
--
-- FLAGGED AS FIRST-PASS: business logic here (which outcome values count
-- as "booked" vs "not attended", exact column-to-report mapping) follows
-- Section 3 of the requirements doc as closely as possible, but has not
-- yet been validated against Avirup's reference report snapshot (Open
-- Item / Next Step from Solution Design Doc Section 10). Treat these as
-- a solid first pass to validate against real numbers once that
-- snapshot is available, not as SME-confirmed final logic.
--
-- IS_INTERNAL FILTER TEMPORARILY REMOVED (2026-08-30): direct data
-- investigation found every single Setter/Closer in the current dataset
-- resolves to a dataengineeracademy.com account — filtering WHERE NOT
-- IS_INTERNAL zeroed out every report entirely, with no non-internal
-- activity to show. This looks like a training/cohort-simulation dataset
-- rather than one with a real external sales team, but that's an
-- inference, not confirmed. The IS_INTERNAL flag itself remains intact
-- on DIM_USERS (see 001_gold_dimension_fact.sql) — only the downstream
-- filter was removed here, so it can be reinstated in any specific view
-- once the SME clarifies whether DEA staff activity is meant to BE the
-- simulated sales team for this dataset, or should be excluded the way
-- Open Item #5 originally assumed.

USE DATABASE SALES_ANALYTICS_PIPELINE;
USE SCHEMA GOLD;

-- ----------------------------------------------------------------------------
-- Shared building block: one row per Strategy Call activity, all its
-- fields pivoted into columns. Both ALL_STRATEGIES_DETAILS and
-- SALES_DETAILS need this shape, so it's factored out as a view rather
-- than duplicated.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW STRATEGY_CALL_ACTIVITIES AS
SELECT
    LEAD_ID,
    ACTIVITY_ID,
    ACTIVITY_AT,
    MAX(CASE WHEN FIELD_NAME = 'Setter' THEN OUTCOME_VALUE END) AS SETTER_USER_ID,
    MAX(CASE WHEN FIELD_NAME = 'Closer' THEN OUTCOME_VALUE END) AS CLOSER_USER_ID,
    MAX(CASE WHEN FIELD_NAME = 'Strategy Call Outcome' THEN OUTCOME_VALUE END) AS STRATEGY_CALL_OUTCOME,
    MAX(CASE WHEN FIELD_NAME = 'Offer Presented' THEN OUTCOME_VALUE END) AS OFFER_PRESENTED,
    MAX(CASE WHEN FIELD_NAME = 'Contract Value' THEN OUTCOME_VALUE END) AS CONTRACT_VALUE
FROM FACT_LEAD_FUNNEL
WHERE CUSTOM_ACTIVITY_TYPE_NAME IN ('5) Strategy Call', '6) Strategy Call Follow Up')
GROUP BY LEAD_ID, ACTIVITY_ID, ACTIVITY_AT;

-- ----------------------------------------------------------------------------
-- INBOUND_STRATEGIES_BOOKED — Requirements Doc Section 3.1.1
-- Triage Call Outcome = '1. Strategy Call Scheduled' is the positive
-- inbound qualification signal.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW INBOUND_STRATEGIES_BOOKED AS
WITH triage AS (
    SELECT
        LEAD_ID, ACTIVITY_ID, ACTIVITY_AT,
        MAX(CASE WHEN FIELD_NAME = 'Setter' THEN OUTCOME_VALUE END) AS SETTER_USER_ID,
        MAX(CASE WHEN FIELD_NAME = 'Triage Call Outcome' THEN OUTCOME_VALUE END) AS TRIAGE_CALL_OUTCOME
    FROM FACT_LEAD_FUNNEL
    WHERE CUSTOM_ACTIVITY_TYPE_NAME IN ('3) Triage Call', '4) Triage Call Follow Up')
    GROUP BY LEAD_ID, ACTIVITY_ID, ACTIVITY_AT
)
SELECT
    t.LEAD_ID,
    t.ACTIVITY_AT AS ACTIVITY_LOG_DATE,
    u.EMAIL AS SETTER_CLOSER_EMAIL,
    u.FULL_NAME AS SETTER_CLOSER_NAME,
    t.TRIAGE_CALL_OUTCOME,
    t.ACTIVITY_AT AS TRIAGE_CALL_DATE,
    (t.TRIAGE_CALL_OUTCOME = '1. Strategy Call Scheduled') AS STRATEGY_CALL_BOOKED,
    DATE_TRUNC('week', t.ACTIVITY_AT)::date AS SC_YEAR_WEEK
FROM triage t
LEFT JOIN DIM_USERS u ON u.USER_ID = t.SETTER_USER_ID;

-- ----------------------------------------------------------------------------
-- OUTBOUND_STRATEGIES_BOOKED — Requirements Doc Section 3.1.2
-- Prospecting Call Outcome = '2. Strategy Call Scheduled'
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW OUTBOUND_STRATEGIES_BOOKED AS
WITH prospecting AS (
    SELECT
        LEAD_ID, ACTIVITY_ID, ACTIVITY_AT,
        MAX(CASE WHEN FIELD_NAME = 'Setter' THEN OUTCOME_VALUE END) AS SETTER_USER_ID,
        MAX(CASE WHEN FIELD_NAME = 'Prospecting Call Outcome' THEN OUTCOME_VALUE END) AS PROSPECTING_CALL_OUTCOME
    FROM FACT_LEAD_FUNNEL
    WHERE CUSTOM_ACTIVITY_TYPE_NAME IN ('1) Prospecting Activity', '2) Prospecting Follow Up')
    GROUP BY LEAD_ID, ACTIVITY_ID, ACTIVITY_AT
)
SELECT
    p.LEAD_ID,
    p.ACTIVITY_AT AS ACTIVITY_LOG_DATE,
    u.EMAIL AS SETTER_CLOSER_EMAIL,
    u.FULL_NAME AS SETTER_CLOSER_NAME,
    p.ACTIVITY_AT AS PROSPECT_CALL_DATE,
    (p.PROSPECTING_CALL_OUTCOME = '2. Strategy Call Scheduled') AS STRATEGY_CALL_BOOKED,
    DATE_TRUNC('week', p.ACTIVITY_AT)::date AS SC_YEAR_WEEK
FROM prospecting p
LEFT JOIN DIM_USERS u ON u.USER_ID = p.SETTER_USER_ID;

-- ----------------------------------------------------------------------------
-- ALL_STRATEGIES_DETAILS — every Strategy Call, attendance per Section
-- 3.2.2's exclusion rules, scoped correctly to the Strategy Call Outcome
-- field specifically (not the flat cross-field list the requirements
-- doc's exclusion set implied before this was resolved).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW ALL_STRATEGIES_DETAILS AS
SELECT
    sc.LEAD_ID,
    sc.ACTIVITY_AT AS ACTIVITY_LOG_DATE,
    sc.STRATEGY_CALL_OUTCOME AS CUSTOM_ACTIVITY,
    CASE
        WHEN sc.STRATEGY_CALL_OUTCOME IN ('4. No Show', '3. Cancel- Not Interested', '2. Admin Cancel', '8. Cancel- Nurture')
        THEN 'NOT_ATTENDED'
        ELSE 'ATTENDED'
    END AS STATUS,
    closer.EMAIL AS CLOSER_EMAIL,
    closer.FULL_NAME AS CLOSER_NAME,
    sc.STRATEGY_CALL_OUTCOME,
    sc.ACTIVITY_AT AS DATE_OF_STRATEGY_CALL,
    sc.OFFER_PRESENTED,
    setter.EMAIL AS SETTER,
    setter.FULL_NAME AS SETTER_NAME
FROM STRATEGY_CALL_ACTIVITIES sc
LEFT JOIN DIM_USERS setter ON setter.USER_ID = sc.SETTER_USER_ID
LEFT JOIN DIM_USERS closer ON closer.USER_ID = sc.CLOSER_USER_ID;

-- ----------------------------------------------------------------------------
-- SALES_DETAILS — Requirements Doc Section 3.4. Sourced from New Sale
-- activity type, not Strategy Call, per Section 3.4's own distinction
-- (a sale is a downstream activity from an attended Strategy Call, not
-- the Strategy Call record itself).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW SALES_DETAILS AS
WITH sales AS (
    SELECT
        LEAD_ID, ACTIVITY_ID, ACTIVITY_AT,
        MAX(CASE WHEN FIELD_NAME = 'Setter' THEN OUTCOME_VALUE END) AS SETTER_USER_ID,
        MAX(CASE WHEN FIELD_NAME = 'Closer' THEN OUTCOME_VALUE END) AS CLOSER_USER_ID,
        MAX(CASE WHEN FIELD_NAME = 'Sales Type' THEN OUTCOME_VALUE END) AS SALE_STATUS,
        MAX(CASE WHEN FIELD_NAME = 'Contract Value' THEN OUTCOME_VALUE END) AS CONTRACTED_VALUE,
        MAX(CASE WHEN FIELD_NAME = 'Cash Collected' THEN OUTCOME_VALUE END) AS CASH_COLLECTED,
        MAX(CASE WHEN FIELD_NAME = 'Program' THEN OUTCOME_VALUE END) AS PROGRAM,
        MAX(CASE WHEN FIELD_NAME = 'Date of Sale' THEN OUTCOME_VALUE END) AS DATE_OF_SALE
    FROM FACT_LEAD_FUNNEL
    WHERE CUSTOM_ACTIVITY_TYPE_NAME IN ('7) New Sale', '8) New Sale [Custom Payment Plan]')
    GROUP BY LEAD_ID, ACTIVITY_ID, ACTIVITY_AT
)
SELECT
    s.LEAD_ID,
    s.ACTIVITY_AT,
    s.SALE_STATUS,
    setter.EMAIL AS SETTER_EMAIL,
    setter.FULL_NAME AS SETTER_NAME,
    closer.EMAIL AS CLOSER_EMAIL,
    closer.FULL_NAME AS CLOSER_NAME,
    s.CONTRACTED_VALUE,
    s.DATE_OF_SALE,
    s.PROGRAM,
    s.CASH_COLLECTED
FROM sales s
LEFT JOIN DIM_USERS setter ON setter.USER_ID = s.SETTER_USER_ID
LEFT JOIN DIM_USERS closer ON closer.USER_ID = s.CLOSER_USER_ID;

-- ----------------------------------------------------------------------------
-- OUTBOUND_PROSPECT_DIALS — Requirements Doc Section 6.2, top-of-funnel
-- outbound dial volume (Lead G pattern: dial-only, no downstream booking)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW OUTBOUND_PROSPECT_DIALS AS
WITH prospecting AS (
    SELECT
        LEAD_ID, ACTIVITY_ID, ACTIVITY_AT,
        MAX(CASE WHEN FIELD_NAME = 'Setter' THEN OUTCOME_VALUE END) AS SETTER_USER_ID,
        MAX(CASE WHEN FIELD_NAME = 'Prospecting Call Outcome' THEN OUTCOME_VALUE END) AS PROSPECTING_CALL_OUTCOME
    FROM FACT_LEAD_FUNNEL
    WHERE CUSTOM_ACTIVITY_TYPE_NAME IN ('1) Prospecting Activity', '2) Prospecting Follow Up')
    GROUP BY LEAD_ID, ACTIVITY_ID, ACTIVITY_AT
)
SELECT
    p.LEAD_ID,
    p.ACTIVITY_AT AS ACTIVITY_LOG_DATE,
    DATE_TRUNC('week', p.ACTIVITY_AT)::date AS PROSPECT_YEAR_WEEK,
    '1) Prospecting Activity' AS CUSTOM_ACTIVITY,
    CASE WHEN p.PROSPECTING_CALL_OUTCOME = '2. Strategy Call Scheduled' THEN 'SET' ELSE 'DIAL_ONLY' END AS STATUS,
    p.PROSPECTING_CALL_OUTCOME AS CUSTOM_ACTIVITY_OUTCOME_NAME,
    p.PROSPECTING_CALL_OUTCOME AS CUSTOM_ACTIVITY_OUTCOME,
    u.EMAIL AS SETTER_CLOSER_EMAIL,
    u.FULL_NAME AS SETTER_CLOSER_NAME
FROM prospecting p
LEFT JOIN DIM_USERS u ON u.USER_ID = p.SETTER_USER_ID;