-- ============================================================================
-- Sales Analytics Pipeline — Silver Layer Schema
-- Solution Design Doc Section 4.3
-- ============================================================================
-- Permanent table structures only, deployed via CI on every merge.
-- Transient rebuild logic (CUSTOM_ACTIVITIES_TRANSIENT, CUSTOM_ACTIVITY_FIELDS,
-- LEAD_ACTIVITIES_PROCESSED_TRANSIENT) and MERGE statements live in Task
-- bodies (silver/004_tasks_and_monitoring.sql) since those re-run daily,
-- not once at deploy time.

USE DATABASE SALES_ANALYTICS_PIPELINE;
USE SCHEMA SILVER;

-- Quarantine table (Section 6.3) — rows that fail repair/PARSE_JSON land
-- here instead of silently disappearing.
CREATE TABLE IF NOT EXISTS PARSE_FAILURES (
    SOURCE_TABLE  STRING,
    RAW_PAYLOAD   STRING,
    INSERT_DATE   TIMESTAMP_NTZ,
    ERROR_DETAIL  STRING,
    FAILED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Dedup key: lead_id + activity_id, keep latest by activity_at,
-- MD5_HASH change detection, INSERT_DATE/UPDATE_DATE for auditability
-- (requirements doc Section 4.1).
CREATE TABLE IF NOT EXISTS LEAD_ACTIVITIES_PROCESSED (
    LEAD_ID      STRING,
    ACTIVITY_ID  STRING,
    FULL_RECORD  VARIANT,
    ACTIVITY_AT  TIMESTAMP_NTZ,
    MD5_HASH     STRING,
    INSERT_DATE  TIMESTAMP_NTZ,
    UPDATE_DATE  TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS CLOSE_CRM_USERS_PROCESSED (
    USER_ID      STRING,
    EMAIL        STRING,
    FIRST_NAME   STRING,
    LAST_NAME    STRING,
    ROLE         STRING,
    STATUS       STRING,
    MD5_HASH     STRING,
    INSERT_DATE  TIMESTAMP_NTZ,
    UPDATE_DATE  TIMESTAMP_NTZ
);

-- Row-count reconciliation log (Section 6.2)
CREATE TABLE IF NOT EXISTS BRONZE.BRONZE_LOAD_RECONCILIATION (
    CHECK_TIME     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    TABLE_NAME     STRING,
    FILES_STAGED   NUMBER,
    ROWS_LOADED    NUMBER,
    ROWS_PARSED    NUMBER,
    ERRORS_SEEN    NUMBER
);
