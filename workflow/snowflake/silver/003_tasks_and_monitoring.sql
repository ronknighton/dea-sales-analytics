-- ============================================================================
-- Sales Analytics Pipeline — Orchestration & Monitoring
-- Solution Design Doc Sections 4.2, 4.3, 6.2, 6.4
-- ============================================================================
-- Daily Task chain: Bronze COPY INTO -> row-count reconciliation ->
-- Silver rebuild/MERGE, each with failure notifications.
--
-- IMPORTANT: multi-statement logic lives in stored procedures (body
-- wrapped in $$...$$), not directly in Task bodies as BEGIN...END blocks.
-- snow sql -f splits files into separate statements on semicolons, and
-- a BEGIN...END block containing internal semicolons (e.g. multiple
-- COPY INTO statements) gets chopped at the first internal semicolon,
-- well before its own END; — confirmed by an actual failed deploy
-- (syntax error, unexpected EOF) before this file was restructured this
-- way. $$...$$ dollar-quoting protects the body's internal semicolons
-- from the splitter, the same protection silver/001_repair_udf.sql
-- already relies on for its Python UDF body.
--
-- Root task runs 30 minutes after the extraction Lambda's 08:00 EST
-- schedule, as a buffer rather than an explicit completion signal.

USE DATABASE SALES_ANALYTICS_PIPELINE;
USE SCHEMA SILVER;

-- ----------------------------------------------------------------------------
-- Procedure: Bronze COPY INTO for all three tables
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_BRONZE_LOAD()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    COPY INTO BRONZE.LEAD_ACTIVITIES_RAW (PAYLOAD, INSERT_DATE)
    FROM (
        SELECT $1:payload, $1:insert_date::timestamp_ntz
        FROM @BRONZE.SALES_ANALYTICS_RAW_STAGE/lead_activites_raw/
    )
    FILE_FORMAT = (TYPE = JSON)
    ON_ERROR = 'CONTINUE';

    COPY INTO BRONZE.CUSTOM_ACTIVITIES_RAW (PAYLOAD, INSERT_DATE)
    FROM (
        SELECT $1:payload, $1:insert_date::timestamp_ntz
        FROM @BRONZE.SALES_ANALYTICS_RAW_STAGE/custom_activites_raw/
    )
    FILE_FORMAT = (TYPE = JSON)
    ON_ERROR = 'CONTINUE';

    COPY INTO BRONZE.CLOSE_CRM_USERS_RAW (PAYLOAD, INSERT_DATE)
    FROM (
        SELECT $1:payload, $1:insert_date::timestamp_ntz
        FROM @BRONZE.SALES_ANALYTICS_RAW_STAGE/close_crm_users_raw/
    )
    FILE_FORMAT = (TYPE = JSON)
    ON_ERROR = 'CONTINUE';

    RETURN 'Bronze load complete';
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: row-count reconciliation (Section 6.2)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_BRONZE_RECONCILE()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    error_rate FLOAT;
BEGIN
    INSERT INTO BRONZE.BRONZE_LOAD_RECONCILIATION (TABLE_NAME, FILES_STAGED, ROWS_LOADED, ROWS_PARSED, ERRORS_SEEN)
    SELECT TABLE_NAME, COUNT(DISTINCT FILE_NAME), SUM(ROW_COUNT), SUM(ROW_PARSED), SUM(ERROR_COUNT)
    FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'SALES_ANALYTICS_PIPELINE.BRONZE.LEAD_ACTIVITIES_RAW',
        START_TIME => DATEADD(HOUR, -2, CURRENT_TIMESTAMP())
    ))
    GROUP BY TABLE_NAME;

    INSERT INTO BRONZE.BRONZE_LOAD_RECONCILIATION (TABLE_NAME, FILES_STAGED, ROWS_LOADED, ROWS_PARSED, ERRORS_SEEN)
    SELECT TABLE_NAME, COUNT(DISTINCT FILE_NAME), SUM(ROW_COUNT), SUM(ROW_PARSED), SUM(ERROR_COUNT)
    FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'SALES_ANALYTICS_PIPELINE.BRONZE.CUSTOM_ACTIVITIES_RAW',
        START_TIME => DATEADD(HOUR, -2, CURRENT_TIMESTAMP())
    ))
    GROUP BY TABLE_NAME;

    INSERT INTO BRONZE.BRONZE_LOAD_RECONCILIATION (TABLE_NAME, FILES_STAGED, ROWS_LOADED, ROWS_PARSED, ERRORS_SEEN)
    SELECT TABLE_NAME, COUNT(DISTINCT FILE_NAME), SUM(ROW_COUNT), SUM(ROW_PARSED), SUM(ERROR_COUNT)
    FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'SALES_ANALYTICS_PIPELINE.BRONZE.CLOSE_CRM_USERS_RAW',
        START_TIME => DATEADD(HOUR, -2, CURRENT_TIMESTAMP())
    ))
    GROUP BY TABLE_NAME;

    -- Alert if error rate exceeds 1% of rows loaded in this run.
    -- Threshold is a starting point, not empirically validated yet.
    error_rate := (
        SELECT COALESCE(SUM(ERRORS_SEEN) / NULLIF(SUM(ROWS_LOADED), 0), 0)
        FROM BRONZE.BRONZE_LOAD_RECONCILIATION
        WHERE CHECK_TIME >= DATEADD(MINUTE, -10, CURRENT_TIMESTAMP())
    );

    IF (error_rate > 0.01) THEN
        CALL SYSTEM$SEND_EMAIL(
            'SALES_ANALYTICS_TASK_FAILURE_NOTIFY',
            'ronknighton@yahoo.com',
            'Sales Analytics Pipeline: Bronze load error rate exceeded threshold',
            'Bronze COPY INTO error rate exceeded 1% in the last reconciliation check. See BRONZE.BRONZE_LOAD_RECONCILIATION for details.'
        );
    END IF;

    RETURN 'Reconciliation complete, error_rate=' || error_rate::string;
END;
$$;

-- ----------------------------------------------------------------------------
-- Procedure: Silver processing — rebuild transient tables, dimension,
-- and MERGE into processed tables (Section 4.3)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_SILVER_PROCESS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- custom_activites_raw: repair -> PARSE_JSON -> FLATTEN
    CREATE OR REPLACE TABLE CUSTOM_ACTIVITIES_TRANSIENT AS
    SELECT
        BRONZE.INSERT_DATE AS insert_date,
        TRY_PARSE_JSON(REPAIR_JSON_QUOTES(BRONZE.PAYLOAD:JSON_OBJECT::string)) AS parsed
    FROM BRONZE.CUSTOM_ACTIVITIES_RAW BRONZE
    WHERE TRY_PARSE_JSON(REPAIR_JSON_QUOTES(BRONZE.PAYLOAD:JSON_OBJECT::string)) IS NOT NULL;

    INSERT INTO PARSE_FAILURES (SOURCE_TABLE, RAW_PAYLOAD, INSERT_DATE, ERROR_DETAIL)
    SELECT 'custom_activites_raw', BRONZE.PAYLOAD:JSON_OBJECT::string, BRONZE.INSERT_DATE,
           'TRY_PARSE_JSON returned NULL after repair'
    FROM BRONZE.CUSTOM_ACTIVITIES_RAW BRONZE
    WHERE TRY_PARSE_JSON(REPAIR_JSON_QUOTES(BRONZE.PAYLOAD:JSON_OBJECT::string)) IS NULL;

    -- NEW dimension (not in original Snowflake PDF): cf_XXXX -> field_name
    -- -> owning activity type.
    CREATE OR REPLACE TABLE CUSTOM_ACTIVITY_FIELDS AS
    SELECT
        act.value:id::string AS custom_activity_type_id,
        act.value:name::string AS custom_activity_type_name,
        act.value:is_archived::boolean AS is_archived,
        fld.value:id::string AS field_id,
        fld.value:name::string AS field_name,
        fld.value:type::string AS field_type
    FROM CUSTOM_ACTIVITIES_TRANSIENT,
         LATERAL FLATTEN(input => parsed:data) act,
         LATERAL FLATTEN(input => act.value:fields) fld;

    -- close_crm_users_raw: repair -> PARSE_JSON -> FLATTEN -> MERGE
    CREATE OR REPLACE TABLE CLOSE_CRM_USERS_TRANSIENT AS
    SELECT
        BRONZE.INSERT_DATE AS insert_date,
        TRY_PARSE_JSON(REPAIR_JSON_QUOTES(BRONZE.PAYLOAD:JSON_OBJECT::string)) AS parsed
    FROM BRONZE.CLOSE_CRM_USERS_RAW BRONZE
    WHERE TRY_PARSE_JSON(REPAIR_JSON_QUOTES(BRONZE.PAYLOAD:JSON_OBJECT::string)) IS NOT NULL;

    INSERT INTO PARSE_FAILURES (SOURCE_TABLE, RAW_PAYLOAD, INSERT_DATE, ERROR_DETAIL)
    SELECT 'close_crm_users_raw', BRONZE.PAYLOAD:JSON_OBJECT::string, BRONZE.INSERT_DATE,
           'TRY_PARSE_JSON returned NULL after repair'
    FROM BRONZE.CLOSE_CRM_USERS_RAW BRONZE
    WHERE TRY_PARSE_JSON(REPAIR_JSON_QUOTES(BRONZE.PAYLOAD:JSON_OBJECT::string)) IS NULL;

    MERGE INTO CLOSE_CRM_USERS_PROCESSED AS tgt
    USING (
        SELECT
            u.value:id::string AS user_id, u.value:email::string AS email,
            u.value:first_name::string AS first_name, u.value:last_name::string AS last_name,
            u.value:role::string AS role, u.value:status::string AS status,
            MD5(u.value::string) AS md5_hash, insert_date
        FROM CLOSE_CRM_USERS_TRANSIENT,
             LATERAL FLATTEN(input => parsed:data) u
        QUALIFY ROW_NUMBER() OVER (PARTITION BY u.value:id ORDER BY insert_date DESC) = 1
    ) AS src
    ON tgt.user_id = src.user_id
    WHEN MATCHED AND tgt.md5_hash != src.md5_hash THEN
        UPDATE SET tgt.email = src.email, tgt.first_name = src.first_name,
                   tgt.last_name = src.last_name, tgt.role = src.role,
                   tgt.status = src.status, tgt.md5_hash = src.md5_hash,
                   tgt.update_date = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN
        INSERT (user_id, email, first_name, last_name, role, status, md5_hash, insert_date, update_date)
        VALUES (src.user_id, src.email, src.first_name, src.last_name, src.role, src.status, src.md5_hash, src.insert_date, CURRENT_TIMESTAMP());

    -- lead_activites_raw: already valid jsonb, flatten directly, then MERGE
    CREATE OR REPLACE TABLE LEAD_ACTIVITIES_PROCESSED_TRANSIENT AS
    SELECT f.value AS activity_record, BRONZE.INSERT_DATE AS insert_date
    FROM BRONZE.LEAD_ACTIVITIES_RAW BRONZE,
         LATERAL FLATTEN(input => BRONZE.PAYLOAD:data) f;

    MERGE INTO LEAD_ACTIVITIES_PROCESSED AS tgt
    USING (
        SELECT
            activity_record:activity_id::string AS activity_id,
            activity_record:lead_id::string AS lead_id,
            activity_record AS full_record,
            activity_record:activity_at::timestamp_ntz AS activity_at,
            MD5(activity_record::string) AS md5_hash, insert_date
        FROM LEAD_ACTIVITIES_PROCESSED_TRANSIENT
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY activity_record:lead_id, activity_record:activity_id
            ORDER BY activity_record:activity_at::timestamp_ntz DESC
        ) = 1
    ) AS src
    ON tgt.lead_id = src.lead_id AND tgt.activity_id = src.activity_id
    WHEN MATCHED AND tgt.md5_hash != src.md5_hash THEN
        UPDATE SET tgt.full_record = src.full_record, tgt.md5_hash = src.md5_hash,
                   tgt.update_date = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN
        INSERT (lead_id, activity_id, full_record, activity_at, md5_hash, insert_date, update_date)
        VALUES (src.lead_id, src.activity_id, src.full_record, src.activity_at, src.md5_hash, src.insert_date, CURRENT_TIMESTAMP());

    RETURN 'Silver processing complete';
END;
$$;

-- ----------------------------------------------------------------------------
-- Tasks — each body is now a single CALL statement, immune to the
-- semicolon-splitting problem entirely since there's nothing internal
-- left to split.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TASK BRONZE_LOAD_TASK
    WAREHOUSE = SALES_ANALYTICS_WH
    SCHEDULE = 'USING CRON 30 13 * * * UTC'  -- 13:30 UTC = 08:30 EST
    ERROR_INTEGRATION = SALES_ANALYTICS_TASK_FAILURE_NOTIFY
AS
CALL SP_BRONZE_LOAD();

CREATE OR REPLACE TASK BRONZE_RECONCILIATION_TASK
    WAREHOUSE = SALES_ANALYTICS_WH
    AFTER BRONZE_LOAD_TASK
    ERROR_INTEGRATION = SALES_ANALYTICS_TASK_FAILURE_NOTIFY
AS
CALL SP_BRONZE_RECONCILE();

CREATE OR REPLACE TASK SILVER_PROCESS_TASK
    WAREHOUSE = SALES_ANALYTICS_WH
    AFTER BRONZE_RECONCILIATION_TASK
    ERROR_INTEGRATION = SALES_ANALYTICS_TASK_FAILURE_NOTIFY
AS
CALL SP_SILVER_PROCESS();

-- ----------------------------------------------------------------------------
-- Resume tasks — created SUSPENDED by default. Must resume in reverse
-- dependency order (leaf/child tasks before their parent).
-- ----------------------------------------------------------------------------
ALTER TASK SILVER_PROCESS_TASK RESUME;
ALTER TASK BRONZE_RECONCILIATION_TASK RESUME;
ALTER TASK BRONZE_LOAD_TASK RESUME;