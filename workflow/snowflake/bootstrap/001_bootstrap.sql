-- ============================================================================
-- Sales Analytics Pipeline — Snowflake Bootstrap
-- ============================================================================
-- Run this ONCE, manually, from a session already authenticated as
-- ACCOUNTADMIN (e.g. via Snowsight worksheet or `snow sql` with your own
-- credentials). This cannot be run through GitHub Actions — same
-- chicken-and-egg reasoning as the AWS GitHubActionsDeployRole bootstrap:
-- the CI service user being created here doesn't exist yet, so nothing
-- CI-driven can create it.
--
-- After this runs successfully, all Bronze/Silver DDL deploys via
-- GitHub Actions using the service user + role created here.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Database and schemas
-- ----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS SALES_ANALYTICS_PIPELINE;
CREATE SCHEMA IF NOT EXISTS SALES_ANALYTICS_PIPELINE.BRONZE;
CREATE SCHEMA IF NOT EXISTS SALES_ANALYTICS_PIPELINE.SILVER;
CREATE SCHEMA IF NOT EXISTS SALES_ANALYTICS_PIPELINE.GOLD;

-- ----------------------------------------------------------------------------
-- 2. Warehouse (small, since this is a once-daily batch pipeline)
-- ----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS SALES_ANALYTICS_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

-- ----------------------------------------------------------------------------
-- 3. Deployment role — least privilege, scoped to this pipeline's objects
-- ----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS SALES_ANALYTICS_DEPLOY_ROLE;

GRANT USAGE ON DATABASE SALES_ANALYTICS_PIPELINE TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT USAGE ON SCHEMA SALES_ANALYTICS_PIPELINE.BRONZE TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT USAGE ON SCHEMA SALES_ANALYTICS_PIPELINE.SILVER TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT USAGE ON SCHEMA SALES_ANALYTICS_PIPELINE.GOLD TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;

GRANT CREATE TABLE ON SCHEMA SALES_ANALYTICS_PIPELINE.BRONZE TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT CREATE TABLE ON SCHEMA SALES_ANALYTICS_PIPELINE.SILVER TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT CREATE VIEW ON SCHEMA SALES_ANALYTICS_PIPELINE.GOLD TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT CREATE FUNCTION ON SCHEMA SALES_ANALYTICS_PIPELINE.SILVER TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT CREATE PROCEDURE ON SCHEMA SALES_ANALYTICS_PIPELINE.SILVER TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
-- Added after initial bootstrap: stored procedures (SP_BRONZE_LOAD,
-- SP_BRONZE_RECONCILE, SP_SILVER_PROCESS) were introduced later to work
-- around snow sql -f's semicolon-based statement splitting breaking
-- multi-statement Task bodies. Anyone rebuilding this account from
-- scratch needs this grant from the start; anyone who already ran the
-- original bootstrap needs to run just this one line manually.
GRANT CREATE STAGE ON SCHEMA SALES_ANALYTICS_PIPELINE.BRONZE TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT CREATE TASK ON SCHEMA SALES_ANALYTICS_PIPELINE.SILVER TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT CREATE TASK ON SCHEMA SALES_ANALYTICS_PIPELINE.GOLD TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;

GRANT USAGE ON WAREHOUSE SALES_ANALYTICS_WH TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;

-- ----------------------------------------------------------------------------
-- 4. Service user for GitHub Actions — Workload Identity Federation (OIDC)
-- ----------------------------------------------------------------------------
-- IMPORTANT: unlike AWS IAM trust policies (which support wildcard StringLike
-- matches), Snowflake WIF requires an EXACT match on the subject claim — no
-- wildcards. This means SUBJECT must include the specific branch ref, not
-- just the repo. Using the immutable subject-claim format (see AWS extraction
-- layer README for background on why this format is now required).
--
-- Replace the SUBJECT value below with your actual owner-ID/repo-ID/branch
-- combination before running. Get owner/repo IDs via:
--   Invoke-RestMethod -Uri "https://api.github.com/users/<owner>" | Select-Object id
--   Invoke-RestMethod -Uri "https://api.github.com/repos/<owner>/<repo>" | Select-Object id
--
-- If you deploy from multiple branches (e.g. a separate release branch),
-- you need a separate service user per branch — WIF's exact-match
-- requirement doesn't allow one user to trust multiple refs via wildcard.

CREATE USER IF NOT EXISTS SVC_GITHUB_SALES_ANALYTICS
    TYPE = SERVICE
    WORKLOAD_IDENTITY = (
        TYPE = OIDC
        ISSUER = 'https://token.actions.githubusercontent.com'
        SUBJECT = 'repo:ronknighton@28845975/dea-sales-analytics@1345365015:ref:refs/heads/main'
    )
    DEFAULT_ROLE = SALES_ANALYTICS_DEPLOY_ROLE
    DEFAULT_WAREHOUSE = SALES_ANALYTICS_WH;

GRANT ROLE SALES_ANALYTICS_DEPLOY_ROLE TO USER SVC_GITHUB_SALES_ANALYTICS;

-- ----------------------------------------------------------------------------
-- 5. Storage Integration — trust relationship to the S3 raw/ bucket
-- ----------------------------------------------------------------------------
-- This is a TWO-STEP process across Snowflake and AWS, same shape as the
-- AWS side's OIDC bootstrap: Snowflake generates an external ID and IAM
-- user ARN here, which must then be added to the S3 bucket's IAM policy
-- on the AWS side before the stage can actually read anything. Neither
-- side can complete this alone.

CREATE STORAGE INTEGRATION IF NOT EXISTS SALES_ANALYTICS_RAW_INTEGRATION
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::022868553110:role/sales-analytics-snowflake-stage-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://dea-sales-analytics-project/raw/');

-- After running the above, run this and copy the output —
-- STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID — into the AWS IAM
-- role's trust policy (arn:...:role/sales-analytics-snowflake-stage-role,
-- which does NOT exist yet and must be created on the AWS side using
-- these exact values, not before):
DESC STORAGE INTEGRATION SALES_ANALYTICS_RAW_INTEGRATION;

GRANT USAGE ON INTEGRATION SALES_ANALYTICS_RAW_INTEGRATION TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;

-- ----------------------------------------------------------------------------
-- 6. Notification integration — for Snowflake Task failure alerts
-- (Solution Design Doc Section 6.4)
-- ----------------------------------------------------------------------------
-- Requires ACCOUNTADMIN (or a role with CREATE INTEGRATION) to create.
-- Update ALLOWED_RECIPIENTS to your actual alert email before running —
-- same address used for the AWS-side SNS subscription is a reasonable
-- default so failures from either layer land in one inbox.
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS SALES_ANALYTICS_TASK_FAILURE_NOTIFY
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('ronknighton@yahoo.com');

GRANT USAGE ON INTEGRATION SALES_ANALYTICS_TASK_FAILURE_NOTIFY TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE SALES_ANALYTICS_DEPLOY_ROLE;