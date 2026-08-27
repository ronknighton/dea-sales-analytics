-- ============================================================================
-- Sales Analytics Pipeline — Bronze Layer Schema
-- Solution Design Doc Section 4.2
-- ============================================================================
-- Schema definition only — stage and table structure. Deployed via
-- GitHub Actions on every merge to main. The actual daily COPY INTO
-- execution lives in silver/004_tasks_and_monitoring.sql as a Task body,
-- not here — this file defines structure, Tasks define recurring behavior.

USE DATABASE SALES_ANALYTICS_PIPELINE;
USE SCHEMA BRONZE;

CREATE STAGE IF NOT EXISTS SALES_ANALYTICS_RAW_STAGE
    STORAGE_INTEGRATION = SALES_ANALYTICS_RAW_INTEGRATION
    URL = 's3://dea-sales-analytics-project/raw/'
    FILE_FORMAT = (TYPE = JSON);

-- Structure varies by table (Solution Design Doc 4.2): lead_activites_raw's
-- payload is already valid nested jsonb; custom_activites_raw and
-- close_crm_users_raw carry a malformed single-quoted string that Silver
-- repairs. Bronze mirrors whatever structure genuinely arrives from
-- extraction rather than forcing a uniform shape.

CREATE TABLE IF NOT EXISTS LEAD_ACTIVITIES_RAW (
    PAYLOAD     VARIANT,
    INSERT_DATE TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS CUSTOM_ACTIVITIES_RAW (
    PAYLOAD     VARIANT,
    INSERT_DATE TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS CLOSE_CRM_USERS_RAW (
    PAYLOAD     VARIANT,
    INSERT_DATE TIMESTAMP_NTZ
);
