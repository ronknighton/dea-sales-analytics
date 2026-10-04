-- ============================================================================
-- Sales Analytics Pipeline — Gold Layer: Report-Level Aggregations
-- Requirements Doc Section 6 (Business KPIs & Final Reports)
-- ============================================================================
-- These four views compute the actual report-level metrics Section 6
-- describes (Show Rate, Offer Rate, cancellation breakdowns, objection
-- percentages, etc.), built on top of the five Gold views already
-- deployed. They serve Streamlit directly now; if the Export Layer
-- question resolves to "yes, still required," these views are exactly
-- what COPY INTO would unload — no duplicated aggregation logic needed
-- either way.
--
-- FLAGGED AS FIRST-PASS, more so than the KPI views underneath them:
-- these involve genuine multi-stage funnel joins (triage -> strategy
-- call -> sale, matched by lead_id and sequenced by date) that have not
-- been validated against Avirup's reference report snapshot. Treat as
-- a solid starting point to compare against real numbers, not settled
-- logic.

USE DATABASE SALES_ANALYTICS_PIPELINE;
USE SCHEMA GOLD;

-- ----------------------------------------------------------------------------
-- INBOUND_SETTER_REPORT — Requirements Doc Section 6.1
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW INBOUND_SETTER_REPORT AS
-- DEFINITIONS CORRECTED against the SME's own reference report. His rate
-- columns reproduce exactly (checked row by row on his Sept 2 file) as:
--   show rate           = triage taken / triage booked
--   set rate            = strategy calls set / triage TAKEN (not booked)
--   strategy taken      = a SUBSET of set (taken / set), never larger
--   offer rate          = offered / strategy taken
-- "Taken" is a TRIAGE-level concept (Requirements 3.1.1 and the Lead B
-- example: a triage No Show is booked but not taken). The first version
-- derived it from later strategy-call attendance, which produced
-- ~99% show rates and "taken" counts larger than "booked".
-- One row per (date, setter, lead) before aggregating, so a lead with
-- several triage activities cannot inflate sums.
WITH triage_base AS (
    SELECT
        LEAD_ID,
        TRIAGE_CALL_DATE::date AS TRIAGE_DATE,
        SETTER_CLOSER_EMAIL AS SETTER,
        IFF(STRATEGY_CALL_BOOKED, 1, 0) AS IS_SET,
        IFF(TRIAGE_CALL_OUTCOME IS NOT NULL
            AND TRIAGE_CALL_OUTCOME NOT IN ('6. No Show', '7. Reschedule', '8. Cancel'), 1, 0) AS IS_TAKEN
    FROM INBOUND_STRATEGIES_BOOKED
),
strategy_per_lead AS (
    SELECT
        LEAD_ID,
        MAX(IFF(STATUS = 'ATTENDED', 1, 0)) AS ATTENDED,
        MAX(IFF(STATUS = 'ATTENDED' AND OFFER_PRESENTED = 'Yes', 1, 0)) AS OFFERED
    FROM ALL_STRATEGIES_DETAILS
    GROUP BY LEAD_ID
),
per_lead AS (
    SELECT
        t.TRIAGE_DATE, t.SETTER, t.LEAD_ID,
        MAX(t.IS_TAKEN) AS IS_TAKEN,
        MAX(t.IS_SET) AS IS_SET,
        MAX(COALESCE(s.ATTENDED, 0)) AS ATTENDED,
        MAX(COALESCE(s.OFFERED, 0)) AS OFFERED,
        MAX(TRY_CAST(sd.CONTRACTED_VALUE AS FLOAT)) AS CONTRACT_VALUE
    FROM triage_base t
    LEFT JOIN strategy_per_lead s ON s.LEAD_ID = t.LEAD_ID
    LEFT JOIN SALES_DETAILS sd ON sd.LEAD_ID = t.LEAD_ID
    GROUP BY t.TRIAGE_DATE, t.SETTER, t.LEAD_ID
)
SELECT
    TRIAGE_DATE,
    SETTER,
    COUNT(*) AS INBOUND_BOOKED,
    SUM(IS_TAKEN) AS INBOUND_TAKEN,
    ROUND(SUM(IS_TAKEN) / NULLIF(COUNT(*), 0) * 100, 1) AS SHOW_RATE,
    ROUND(SUM(IS_SET) / NULLIF(SUM(IS_TAKEN), 0) * 100, 1) AS TRIAGE_SET_RATE,
    SUM(IS_SET) AS STRATEGY_CALL_BOOKED,
    SUM(IFF(IS_SET = 1 AND ATTENDED = 1, 1, 0)) AS STRATEGY_CALL_TAKEN,
    ROUND(SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND OFFERED = 1, 1, 0))
        / NULLIF(SUM(IFF(IS_SET = 1 AND ATTENDED = 1, 1, 0)), 0) * 100, 1) AS OFFER_RATE,
    SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, 1, 0)) AS TOTAL_SALES,
    ROUND(SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, 1, 0))
        / NULLIF(SUM(IFF(IS_SET = 1 AND ATTENDED = 1, 1, 0)), 0) * 100, 1) AS SALE_RATE,
    ROUND(SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, CONTRACT_VALUE, 0))
        / NULLIF(SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, 1, 0)), 0), 2) AS AVERAGE_ORDER_VALUE
FROM per_lead
GROUP BY TRIAGE_DATE, SETTER;

-- ----------------------------------------------------------------------------
-- OUTBOUND_SETTER_REPORT — Requirements Doc Section 6.2
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW OUTBOUND_SETTER_REPORT AS
-- DEFINITIONS CORRECTED against the SME's reference report (his rate
-- columns reproduce exactly): dial-to-set = set / TOTAL DIALS (not
-- distinct leads); set-to-show = shown / set; offer rate = offered /
-- shown. Shown, offered and sold are all restricted to leads that were
-- actually SET, so each stage is a subset of the one before it.
-- TOTAL_OFFER added: listed in the PDF's export columns, omitted in the
-- first version. NOTE: "calls" here are logged prospecting activities;
-- the SME's dial counts (e.g. 22,236 on Sept 2) are raw dialer volume
-- far beyond the ~819 raw outbound calls in this dataset for that day,
-- so absolute dial figures cannot be reproduced from this source.
WITH dials_base AS (
    SELECT
        LEAD_ID,
        ACTIVITY_LOG_DATE::date AS DIAL_DATE,
        SETTER_CLOSER_EMAIL AS SETTER,
        IFF(STATUS = 'SET', 1, 0) AS IS_SET
    FROM OUTBOUND_PROSPECT_DIALS
),
strategy_per_lead AS (
    SELECT
        LEAD_ID,
        MAX(IFF(STATUS = 'ATTENDED', 1, 0)) AS ATTENDED,
        MAX(IFF(STATUS = 'ATTENDED' AND OFFER_PRESENTED = 'Yes', 1, 0)) AS OFFERED
    FROM ALL_STRATEGIES_DETAILS
    GROUP BY LEAD_ID
),
per_lead AS (
    SELECT
        d.DIAL_DATE, d.SETTER, d.LEAD_ID,
        COUNT(*) AS CALLS,
        MAX(d.IS_SET) AS IS_SET,
        MAX(COALESCE(s.ATTENDED, 0)) AS ATTENDED,
        MAX(COALESCE(s.OFFERED, 0)) AS OFFERED,
        MAX(TRY_CAST(sd.CONTRACTED_VALUE AS FLOAT)) AS CONTRACT_VALUE
    FROM dials_base d
    LEFT JOIN strategy_per_lead s ON s.LEAD_ID = d.LEAD_ID
    LEFT JOIN SALES_DETAILS sd ON sd.LEAD_ID = d.LEAD_ID
    GROUP BY d.DIAL_DATE, d.SETTER, d.LEAD_ID
)
SELECT
    DIAL_DATE,
    SETTER,
    SUM(CALLS) AS TOTAL_OUTBOUND_CALLS,
    COUNT(*) AS TOTAL_LEADS_TOUCHED,
    SUM(IS_SET) AS OUTBOUND_SET,
    SUM(IFF(IS_SET = 1 AND ATTENDED = 1, 1, 0)) AS TOTAL_CLOSER_SHOW,
    SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND OFFERED = 1, 1, 0)) AS TOTAL_OFFER,
    SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, 1, 0)) AS TOTAL_SALE,
    ROUND(SUM(IS_SET) / NULLIF(SUM(CALLS), 0) * 100, 1) AS DIAL_TO_SET_RATE,
    ROUND(SUM(IFF(IS_SET = 1 AND ATTENDED = 1, 1, 0)) / NULLIF(SUM(IS_SET), 0) * 100, 1) AS SET_TO_SHOW_RATE,
    ROUND(SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, 1, 0))
        / NULLIF(SUM(IFF(IS_SET = 1 AND ATTENDED = 1, 1, 0)), 0) * 100, 1) AS SHOW_TO_SALE_RATE,
    SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, CONTRACT_VALUE, 0)) AS TOTAL_REVENUE,
    ROUND(SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, CONTRACT_VALUE, 0))
        / NULLIF(SUM(IFF(IS_SET = 1 AND ATTENDED = 1 AND CONTRACT_VALUE IS NOT NULL, 1, 0)), 0), 2) AS AVERAGE_ORDER_VALUE
FROM per_lead
GROUP BY DIAL_DATE, SETTER;

-- ----------------------------------------------------------------------------
-- CLOSER_REPORT — Requirements Doc Section 6.3
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW CLOSER_REPORT AS
SELECT
    asd.CLOSER_NAME,
    DATE_TRUNC('month', DATE_OF_STRATEGY_CALL)::date AS CALL_YEAR_MONTH,
    COUNT(*) AS CALL_BOOKED,
    COUNT(CASE WHEN STRATEGY_CALL_OUTCOME = '2. Admin Cancel' THEN 1 END) AS ADMIN_CANCEL,
    COUNT(CASE WHEN STRATEGY_CALL_OUTCOME = '8. Cancel- Nurture' THEN 1 END) AS CANCEL_NURTURE,
    COUNT(CASE WHEN STRATEGY_CALL_OUTCOME = '3. Cancel- Not Interested' THEN 1 END) AS CANCEL_NOT_INTEREST,
    COUNT(CASE WHEN STRATEGY_CALL_OUTCOME IN ('2. Admin Cancel', '8. Cancel- Nurture', '3. Cancel- Not Interested') THEN 1 END) AS TOTAL_CANCEL,
    COUNT(CASE WHEN STRATEGY_CALL_OUTCOME = '4. No Show' THEN 1 END) AS NO_SHOW,
    COUNT(CASE WHEN STATUS = 'ATTENDED' THEN 1 END) AS STRTGY_CALL_SHW,
    COUNT(CASE WHEN STRATEGY_CALL_OUTCOME = '7. Lost' THEN 1 END) AS LOST,
    COUNT(CASE WHEN CUSTOM_ACTIVITY IN ('5. Sale', '6. Sale') THEN 1 END) AS SALE,
    ROUND(AVG(NULLIF(TRY_CAST(sd.CONTRACTED_VALUE AS FLOAT), 0)), 2) AS AVG_VALUE,
    SUM(TRY_CAST(sd.CASH_COLLECTED AS FLOAT)) AS CASH_COLLECTED
FROM ALL_STRATEGIES_DETAILS asd
LEFT JOIN SALES_DETAILS sd ON sd.LEAD_ID = asd.LEAD_ID
GROUP BY asd.CLOSER_NAME, CALL_YEAR_MONTH;

-- ----------------------------------------------------------------------------
-- OBJECTIONS_FACED_REPORT — Requirements Doc Section 6.4
-- ----------------------------------------------------------------------------
-- Sourced from the 'Objections Faced?' field on Strategy Call activities
-- (confirmed real field from raw data inspection — accepts_multiple_values,
-- type: choices). Category matching below assumes the field's option
-- values contain these category names as substrings — NOT yet confirmed
-- against real OUTCOME_VALUE data for this specific field. This is the
-- single least-validated piece of the Gold layer; check real values here
-- first if this report's numbers look wrong.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW OBJECTIONS_FACED_REPORT AS
WITH objections AS (
    SELECT
        f.LEAD_ID,
        f.ACTIVITY_ID,
        f.ACTIVITY_AT,
        closer.FULL_NAME AS CLOSER_NAME,
        f.OUTCOME_VALUE AS OBJECTION_RAW
    FROM FACT_LEAD_FUNNEL f
    LEFT JOIN STRATEGY_CALL_ACTIVITIES sc ON sc.LEAD_ID = f.LEAD_ID AND sc.ACTIVITY_ID = f.ACTIVITY_ID
    LEFT JOIN DIM_USERS closer ON closer.USER_ID = sc.CLOSER_USER_ID
    WHERE f.FIELD_NAME = 'Objections Faced?'
),
categorized AS (
    SELECT
        LEAD_ID, ACTIVITY_ID, ACTIVITY_AT, CLOSER_NAME,
        OBJECTION_RAW ILIKE '%money%' AS IS_MONEY,
        OBJECTION_RAW ILIKE '%fear%' AS IS_FEAR,
        OBJECTION_RAW ILIKE '%hung up%' AS IS_HUNG_UP,
        OBJECTION_RAW ILIKE '%logistical%' AS IS_LOGISTICAL,
        OBJECTION_RAW ILIKE '%no objection%' AS IS_NO_OBJ,
        OBJECTION_RAW ILIKE '%other coach%' AS IS_OTHER_COACHES,
        OBJECTION_RAW ILIKE '%partner%' AS IS_PARTNER,
        OBJECTION_RAW ILIKE '%think%' AS IS_THINK_ABT_IT,
        OBJECTION_RAW ILIKE '%time%' AS IS_TIME,
        OBJECTION_RAW ILIKE '%trust%' AS IS_TRUST,
        OBJECTION_RAW ILIKE '%value%' AS IS_VALUE,
        OBJECTION_RAW ILIKE '%not looking%' AS IS_NOT_LOOKING
    FROM objections
)
SELECT
    CLOSER_NAME,
    ACTIVITY_AT::date AS ACTIVITY_DATE,
    COUNT(DISTINCT ACTIVITY_ID) AS TOTAL_CALLS,
    COUNT(CASE WHEN IS_MONEY THEN 1 END) AS MONEY_COUNT,
    COUNT(CASE WHEN IS_FEAR THEN 1 END) AS FEAR_COUNT,
    COUNT(CASE WHEN IS_HUNG_UP THEN 1 END) AS HUNG_UP_COUNT,
    COUNT(CASE WHEN IS_LOGISTICAL THEN 1 END) AS LOGISTICAL_COUNT,
    COUNT(CASE WHEN IS_NO_OBJ THEN 1 END) AS NO_OBJ_COUNT,
    COUNT(CASE WHEN IS_OTHER_COACHES THEN 1 END) AS OTHER_COACHES_COUNT,
    COUNT(CASE WHEN IS_PARTNER THEN 1 END) AS PARTNER_COUNT,
    COUNT(CASE WHEN IS_THINK_ABT_IT THEN 1 END) AS THINK_ABT_IT_COUNT,
    COUNT(CASE WHEN IS_TIME THEN 1 END) AS TIME_COUNT,
    COUNT(CASE WHEN IS_TRUST THEN 1 END) AS TRUST_COUNT,
    COUNT(CASE WHEN IS_VALUE THEN 1 END) AS VALUE_COUNT,
    COUNT(CASE WHEN IS_NOT_LOOKING THEN 1 END) AS NOT_LOOKING_COUNT
FROM categorized
GROUP BY CLOSER_NAME, ACTIVITY_DATE;