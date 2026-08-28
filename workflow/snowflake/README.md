# Sales Analytics Pipeline — Snowflake Layer (Bronze + Silver + Gold)

Scaffolding for Layers 2-4 of the pipeline (S3 -> Bronze -> Silver -> Gold),
per the Solution Design Document Sections 4.2-4.4 and 6.2-6.4. Deploys via
GitHub Actions using Snowflake's native Workload Identity Federation (OIDC) —
no static Snowflake credentials stored anywhere, same principle as the AWS
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
                              locally-tested Python heuristic. Returns NULL
                              on NULL input rather than crashing — see
                              Lessons section, this was a real deploy failure.
    002_silver_schema.sql    Permanent Silver tables (schema only)
    003_tasks_and_monitoring.sql
                              Stored procedures (SP_BRONZE_LOAD,
                              SP_BRONZE_RECONCILE, SP_SILVER_PROCESS) holding
                              the actual daily logic, plus thin Task wrappers
                              that CALL each one. See Lessons section for why
                              logic lives in procedures, not directly in
                              Task bodies.
  gold/
    001_gold_dimension_fact.sql
                              DIM_USERS (with IS_INTERNAL flag) and
                              FACT_LEAD_FUNNEL (resolves cf_XXXX keys against
                              CUSTOM_ACTIVITY_FIELDS)
    002_kpi_views.sql         The 5 KPI views from the Snowflake PDF's Gold
                              layer — all plain VIEWs, no Task/procedure
                              needed since they query Silver live
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
4. `silver/003_tasks_and_monitoring.sql` — stored procedures + Tasks, then resumes them
5. `gold/001_gold_dimension_fact.sql` — DIM_USERS, FACT_LEAD_FUNNEL
6. `gold/002_kpi_views.sql` — the 5 KPI views

This order matters for two different reasons depending on the step:
- Steps 1-4: Tasks/procedures reference the UDF and tables from earlier
  steps, so those must exist first (a schema/object dependency, resolved
  at deploy time).
- Steps 4-5: **this is not just an object dependency** — see "Deploying a
  procedure does not run it" below, the most important lesson from this
  layer's first real deploy.

## What this does NOT include yet

- Export layer (COPY INTO flat files) — Solution Design Doc Section 4.5.
- Reporting layer (Streamlit / Tableau) — Section 5, tool selection decided,
  not yet implemented.
- The 7-consecutive-day production simulation run required by the
  requirements doc, Section 5 — not started; should follow validation
  against Avirup's reference report snapshot.

## Lessons from the first deploy

Six real issues surfaced getting Bronze through Gold actually working, in
addition to the four already documented for the AWS extraction layer
(immutable OIDC subject claims, missing IAM permissions, the
manual-vs-automatic deploy rule, byte-size vs. row-count batching).
Documented here so none of these need rediscovering.

**1. `snow sql -f` splits files into separate statements on semicolons —
multi-statement Task bodies break.** A `BEGIN...END` block containing
internal semicolons (e.g. three `COPY INTO` statements) gets chopped at
the *first* internal semicolon, well before its own `END;` — confirmed
via an actual failed deploy (`syntax error, unexpected EOF`). Fix: move
multi-statement logic into a stored procedure with its body wrapped in
`$$...$$` (dollar-quoting protects internal semicolons from the splitter
the same way it already protects the repair UDF's Python body), and make
the Task itself a single `CALL procedure_name();` — nothing left for the
splitter to break.

**2. Task's `ERROR_INTEGRATION` only accepts `QUEUE`-type notification
integrations (AWS SNS / GCP Pub/Sub / Azure Event Grid) — `EMAIL` and
`WEBHOOK` are not supported there**, confirmed directly from Snowflake's
own docs after a failed deploy ("Integration ... is not a valid
notification integration for UserTasks"). Standing up a full SNS topic +
IAM trust just for Task-level alerting would have been a meaningful scope
increase for what's really just "email on failure." Fix: no
`ERROR_INTEGRATION` on the Tasks at all — each stored procedure catches
its own exceptions (`EXCEPTION WHEN OTHER THEN`), sends an email via
`SYSTEM$SEND_EMAIL` (the same `EMAIL`-type integration, used the way it's
actually supported), then `RAISE;`s with no arguments to re-throw — so
`TASK_HISTORY` still correctly shows the run as `FAILED`, not silently
`SUCCEEDED` after just emailing about its own failure.

**3. Snowflake CLI's connection flag is `--connection`, not
`--connection-name` — and even that's wrong for OIDC.** The OIDC setup
action exports raw environment variables (`SNOWFLAKE_TOKEN`,
`SNOWFLAKE_AUTHENTICATOR=WORKLOAD_IDENTITY`, etc.) rather than writing a
named connection profile into `config.toml`. The correct flag for that
setup is `--temporary-connection`, which tells the CLI to build a
connection from environment variables directly — confirmed only after
two separate failed attempts with the wrong flag names.

**4. The repair UDF crashes the entire calling statement on NULL
input, not just that row.** `REPAIR_JSON_QUOTES` originally assumed its
input was always a non-null string; when some rows' `PAYLOAD:JSON_OBJECT`
evaluated to `NULL` (a real, confirmed data inconsistency — not every row
has this key), the Python function hit `len(None)` and raised a hard
exception. Critically, **a Python exception inside a UDF aborts the whole
calling SQL statement**, not just that one row — which defeated the
`WHERE TRY_PARSE_JSON(...) IS NOT NULL` / quarantine design entirely,
since the UDF never got the chance to return anything for `TRY_PARSE_JSON`
to evaluate. Fix: `if raw_text is None: return None` as the first line of
the function — `TRY_PARSE_JSON(NULL)` correctly returns `NULL`, which then
flows into the existing quarantine logic as designed.

**5. Deploying a procedure's definition does not run it — a distinction
that cost several redeploy cycles.** `CREATE OR REPLACE PROCEDURE
SP_SILVER_PROCESS()` only updates *what the procedure will do* the next
time something calls it. It does not execute the body. Since
`gold/001_gold_dimension_fact.sql`'s `FACT_LEAD_FUNNEL` view references
`SILVER.CUSTOM_ACTIVITY_FIELDS` — a table that only gets created *inside*
`SP_SILVER_PROCESS`'s body — the Gold deploy step failed with "Object ...
does not exist" every time, even after the procedure itself deployed
successfully, until the procedure was actually **called**:
```sql
USE ROLE SALES_ANALYTICS_DEPLOY_ROLE;
CALL SALES_ANALYTICS_PIPELINE.SILVER.SP_BRONZE_LOAD();
CALL SALES_ANALYTICS_PIPELINE.SILVER.SP_SILVER_PROCESS();
```
This has to happen manually once (or wait for the daily Task schedule)
before Gold can deploy for the first time on a fresh account. After that
first run, Gold's views work fine on every subsequent deploy since the
table already exists.

**6. `GET_DDL` is the fastest way to confirm what Snowflake actually has
deployed, vs. what you assume is deployed.** When a fix appeared not to
take effect, `SELECT GET_DDL('PROCEDURE', 'SALES_ANALYTICS_PIPELINE.SILVER.SP_BRONZE_LOAD()');`
showed the *actual* stored procedure body — which revealed the real cause
(the PR had been opened but never merged, so the fix was sitting in a
branch, not deployed) faster than re-reading logs or guessing. Worth
reaching for this whenever a fix "should have" worked but the same error
keeps recurring.

**Also worth noting:** the `validate` job's SQL syntax checker went
through three rounds of false positives (parenthesized activity-type
names like `'5) Strategy Call'`, an apostrophe inside a `-- comment`, and
`''`-escaped apostrophes inside a string body) before being replaced with
a `sqlparse`-based checker instead of continuing to patch a hand-rolled
quote-tracking state machine. If a future PR's `validate` step fails on a
paren-balance check that looks obviously wrong, check whether the checker
itself needs adjusting before assuming the SQL is broken.