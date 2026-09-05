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

## Status

- **Export layer — RESOLVED, not required.** SME confirmed directly: "if
  within snowflake then I think you can use the tables and query
  directly." Streamlit reads Gold views natively, so the COPY INTO flat-file
  unloads (Solution Design Doc Section 4.5) were built but are not part of
  the active pipeline. SQL remains in `snowflake/gold/` if a future
  external tool ever needs it.
- **Reporting layer — LIVE.** Streamlit in Snowflake (`SALES_ANALYTICS_DASHBOARD`)
  deployed via `snow streamlit deploy`, all four reports rendering against
  real Gold-layer data.
- **7-consecutive-day production simulation — CONFIRMED COMPLETE.**
  Verified via `INFORMATION_SCHEMA.TASK_HISTORY` (not inferred from elapsed
  time): all three pipeline Tasks show `SUCCEEDED` across 7 consecutive
  calendar days, correct dependency order each day, no failures or gaps.
- **Still open:** business-logic validation against the SME's reference
  report snapshot — pending a response to a specific date/month request
  (see Solution Design Doc Section 13, Next Steps).

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

## Lessons from production validation

The six issues above were about getting a deploy to succeed at all. Once
real, full-volume data started flowing through the successfully-deployed
pipeline, a second, more serious category of bug surfaced: the pipeline
ran without error while silently producing wrong or empty results. Each
of these was caught by checking row counts and displayed numbers against
expectations, not by any error message — worth internalizing as a
pattern, not just fixing individually.

**7. Bronze's `COPY INTO` expected a `{payload, insert_date}` wrapper the
Lambda never actually produced.** `extract_handler.py` wrote each row's
`raw_data` content directly to S3 with no wrapper; Bronze's `COPY INTO`
statements did `SELECT $1:payload, $1:insert_date::timestamp_ntz`. Since
no staged file had a top-level `payload` key, this resolved to `NULL` for
*every row in every table* — and `COPY INTO` does not reject `NULL`
results, so row counts looked completely normal while content was empty.
Confirmed via `PARSE_FAILURES` landing at exactly 100% of two tables'
row counts, and `LEAD_ACTIVITIES_PROCESSED` sitting at 0 despite
thousands of real Bronze rows. Fixed on the Lambda side (wrapping output
to match the contract Bronze had always expected), not the Bronze side —
Bronze's design was correct, the Lambda just never fulfilled it.

**8. `FORCE = TRUE` reloads every file matching the stage path, not just
"already-loaded" ones — including stale pre-fix files.** Remediating #7
required force-reloading the newly-corrected files, which silently
resurrected older, pre-fix files still sitting in earlier S3 date
partitions, roughly doubling row counts and reintroducing the exact
`NULL`-payload problem. Fix: delete stale S3 partitions *before*
truncate + force-reload, not after.

**9. A table with no dedup logic will eventually break, even if it works
fine at first.** `CUSTOM_ACTIVITY_FIELDS` rebuilt from the full catalog on
every run with no deduplication — fine when there was only one snapshot's
worth of data, silently broken (52x row inflation: 7,025 rows for 134
distinct fields) once real daily volume accumulated. Fixed by
deduplicating on the `(field_id, activity_type_id)` **pair**, not
`field_id` alone — some fields are legitimately shared across multiple
activity types (e.g. "Closer" on both Strategy Call and its Follow Up),
and collapsing to one row per `field_id` would have silently erased that.

**10. The single most consequential bug in this project: a foundational
key-structure assumption was wrong from the original design, and nothing
caught it until real volume existed.** `FACT_LEAD_FUNNEL` assumed
`custom.cf_XXXX` fields lived nested under a `custom` object key. Direct
inspection of real activity records showed these are **flat top-level
keys with a literal period in the key name** (e.g.
`"custom.cf_3JFRKeLp..."`) — there is no nested object anywhere in the
data. The original requirements doc had this right all along ("extracting
keys containing `%custom.%`" — a `LIKE`-style wildcard describing a flat
prefix, not a nested path); the implementation just didn't follow it.
This meant the view returned zero rows since its original design,
regardless of how much valid data existed upstream — confirmed via
`OBJECT_KEYS(NULL)` silently producing zero `LATERAL FLATTEN` rows rather
than an error. Also newly enforced while fixing this: filtering to
`_type = 'CustomActivity'` only, confirmed necessary after finding the
other six activity types (SMS, Call, Email, Note, Meeting, Created,
LeadMerge — 91% of all lead activities) carry no `custom.*` keys at all.

**11. `NULL = NULL` is never `TRUE` in SQL — and a `MERGE` match
condition built on a wrong key name fails this way silently, forever.**
`LEAD_ACTIVITIES_PROCESSED`'s `MERGE` extracted
`activity_record:activity_id`, but real records have no such key — the
actual field is just `"id"`. Since the match condition was
`tgt.activity_id = src.activity_id`, and both sides were always `NULL`,
this `MERGE` had never matched a single row since the pipeline first went
live. Every daily Postgres snapshot re-inserted the same recurring
activities as brand-new rows instead of updating existing ones — the
exact "same activity reappears across multiple days" problem the
requirements doc's Section 4.1 dedup requirement exists to solve, quietly
defeated by one wrong field name. After truncating and rebuilding with the
correct `activity_record:id`, total row count and distinct `activity_id`
count landed on the identical figure (70,918) — the confirmation that
dedup was finally working.

**12. A dashboard can display a wrong number even when the underlying
data and SQL are both correct.** Streamlit's summary metrics computed
`df['SHOW_RATE'].mean()` — an unweighted average of already-computed
daily percentages. This distorts toward small-volume days: a single-lead
100%-show day counts the same as a fifty-lead day at 80%. Confirmed
directly: this showed a 98.7% show rate against a correctly pooled rate
of 87.8% on identical data. Fixed by computing pooled rates from summed
numerators and denominators (`SUM(taken) / SUM(booked)`) rather than
averaging pre-computed percentages — applied to every rate-based metric
and trend chart in the app, not just the one caught first.
