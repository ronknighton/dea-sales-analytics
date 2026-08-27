# Sales Analytics Pipeline — Snowflake Layer (Bronze + Silver)

Scaffolding for Layers 2-3 of the pipeline (S3 -> Bronze -> Silver), per the
Solution Design Document Sections 4.2-4.3 and 6.2-6.4. Deploys via GitHub
Actions using Snowflake's native Workload Identity Federation (OIDC) — no
static Snowflake credentials stored anywhere, same principle as the AWS
extraction layer's IAM OIDC setup, but a genuinely different mechanism
under the hood (see "Snowflake WIF vs. AWS IAM OIDC" below).

## Structure

```
snowflake/
  bootstrap/
    001_bootstrap.sql        Run ONCE manually (ACCOUNTADMIN) — database,
                              warehouse, deploy role, service user, storage
                              integration, notification integration
  bronze/
    001_bronze_schema.sql    External stage + 3 Bronze tables (schema only)
  silver/
    001_repair_udf.sql       Apostrophe-aware JSON repair, ported from the
                              locally-tested Python heuristic
    002_silver_schema.sql    Permanent Silver tables (schema only)
    003_tasks_and_monitoring.sql
                              Daily Task chain: Bronze COPY INTO -> row-count
                              reconciliation -> Silver rebuild/MERGE, each
                              with failure email notifications
.github/workflows/
  deploy-snowflake.yml       validate on PR, deploy on merge to main
```

**Why schema and daily-logic are split into separate files:** `001_bronze_schema.sql`
and `002_silver_schema.sql` define structure — safe to redeploy on every merge,
since `CREATE TABLE IF NOT EXISTS` is a no-op if nothing changed. The actual
daily-recurring behavior (COPY INTO, transient table rebuilds, MERGE
statements) lives inside the Task bodies in `003_tasks_and_monitoring.sql` —
`CREATE OR REPLACE TASK` only redefines *what will run* on the schedule, it
doesn't execute anything itself at deploy time.

## One-time manual setup

Run `snowflake/bootstrap/001_bootstrap.sql` **manually**, once, from a
session authenticated as ACCOUNTADMIN (Snowsight worksheet, or `snow sql`
with your own credentials) — not through GitHub Actions. Same bootstrap
problem as the AWS side: the service user and role this script creates
don't exist yet, so nothing CI-driven can create them.

Before running it:

1. **Fill in the OIDC `SUBJECT` value** with your actual GitHub owner ID,
   repo ID, and branch — see "Snowflake WIF vs. AWS IAM OIDC" below for why
   this can't be a wildcard.
2. **Fill in `STORAGE_AWS_ROLE_ARN`** with a role ARN that doesn't exist yet
   (e.g. `arn:aws:iam::<account-id>:role/sales-analytics-snowflake-stage-role`)
   — this is intentional. Run the bootstrap script's `CREATE STORAGE INTEGRATION`
   and `DESC STORAGE INTEGRATION` statements first, copy the generated
   `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID` values from the
   output, and only then create that IAM role on the AWS side with a trust
   policy referencing those exact values. Two-way trust, same shape as the
   GitHub OIDC provider trust — neither side can complete alone.
3. **Set `ALLOWED_RECIPIENTS`** on the notification integration to your
   actual alert email.

## Snowflake WIF vs. AWS IAM OIDC — a real difference, not just syntax

Both use OIDC, but they behave differently in one way that matters:

- **AWS IAM** trust policies support `StringLike` wildcard matching
  (`repo:owner/repo:*`), so one role can trust any branch/workflow in a repo.
- **Snowflake WIF requires an exact match** on the subject claim — no
  wildcards. The service user's `SUBJECT` must match the *specific* branch
  ref, e.g. `repo:OWNER@OWNER-ID/REPO@REPO-ID:ref:refs/heads/main`. Deploying
  from a second branch requires a second service user.

Combined with GitHub's own immutable subject-claim format (see the AWS
extraction layer README for the full story — repos created after July 15,
2026 embed numeric owner/repo IDs, not just names), this means the
`SUBJECT` value has two separate correctness requirements stacked on top
of each other: the right ID-based format, AND an exact branch match. Get
the IDs the same way as the AWS side:
```powershell
Invoke-RestMethod -Uri "https://api.github.com/users/<owner>" | Select-Object id
Invoke-RestMethod -Uri "https://api.github.com/repos/<owner>/<repo>" | Select-Object id
```

## Deploy order

GitHub Actions runs these in sequence on every merge to `main`:
1. `bronze/001_bronze_schema.sql` — stage + Bronze tables
2. `silver/001_repair_udf.sql` — repair function (safe to redeploy if logic changes)
3. `silver/002_silver_schema.sql` — permanent Silver tables
4. `silver/003_tasks_and_monitoring.sql` — Task definitions, then resumes them

This order matters: Tasks reference the UDF and tables from steps 1-3, so
they must exist first.

## What this does NOT include yet

- Gold layer (dimensions, fact_lead_funnel, KPI views) — not yet built as
  deployable SQL, though the design is documented in Solution Design Doc
  Section 4.4.
- Export layer (COPY INTO flat files) — Section 4.5, same status as Gold.
- Reporting layer (Streamlit / Tableau) — Section 5, tool selection pending
  final SME confirmation.
