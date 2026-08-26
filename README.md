# Sales Analytics Pipeline — Extraction Layer (AWS)

Scaffolding for Layer 1 of the pipeline (Postgres -> S3), per the Solution
Design Document Section 4.1. Deploys via GitHub Actions using OIDC — no
static AWS credentials stored anywhere.

## Structure

```
lambda/
  extract_handler.py   Extraction logic (pg8000, incremental via SSM checkpoint)
  requirements.txt      pg8000 only — no compiled dependencies
infrastructure/
  template.yaml          CloudFormation: Lambda, IAM roles, EventBridge
                          schedule, SSM checkpoints, Secrets Manager,
                          CloudWatch alarm + SNS
.github/workflows/
  deploy-aws.yml          validate on PR, deploy on merge to main
```

## One-time manual setup (before the first GitHub Actions run)

These steps can't be automated by the workflow itself — they're what let
the workflow authenticate and know what to deploy.

1. **Confirm the existing GitHub OIDC provider.** This AWS account already
   has one registered (from the Global Partners capstone) at
   `arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`.
   Do not create a new one — `template.yaml`'s `GitHubActionsDeployRole`
   references it as a parameter.

2. **Update the repo restriction in `template.yaml`.** Find
   `token.actions.githubusercontent.com:sub` under `GitHubActionsDeployRole`
   and set it to your actual repo, in GitHub's **immutable subject-claim
   format** (see "Lessons from the first deploy" below for why this
   matters): `repo:OWNER@OWNER-ID/REPO@REPO-ID:*`. Get the numeric IDs with:
   ```powershell
   Invoke-RestMethod -Uri "https://api.github.com/users/<owner>" | Select-Object id
   Invoke-RestMethod -Uri "https://api.github.com/repos/<owner>/<repo>" | Select-Object id
   ```
   The plain `repo:<owner>/<repo>:*` format (name-only, no IDs) will fail
   silently with `Not authorized to perform sts:AssumeRoleWithWebIdentity`
   for any repo created after July 15, 2026.

3. **Bootstrap the deploy role manually, once.** The workflow needs
   `sales-analytics-pipeline-github-deploy-role` to exist before it can
   use it to deploy the rest of the stack (a chicken-and-egg problem on
   first deploy only). Either deploy `template.yaml` once by hand
   (`aws cloudformation deploy ...` from your own machine, with your own
   credentials) to create everything including the deploy role, or split
   the OIDC role into its own bootstrap template deployed first. First
   option is simpler for a project this size.

4. **Set GitHub Actions repository secrets** (Settings -> Secrets and
   variables -> Actions):
   - `AWS_ACCOUNT_ID`
   - `DB_HOST` (bare hostname, no `http://` prefix or trailing slash —
     see Solution Design Doc note on the requirements doc's malformed
     connection string)
   - `DB_PASSWORD`
   - `S3_BUCKET_NAME`
   - `ALERT_EMAIL` (for the CloudWatch failure alarm's SNS subscription)

5. **Confirm the SNS email subscription.** After the first deploy, check
   the inbox for `ALERT_EMAIL` — AWS sends a subscription confirmation
   email that must be clicked, or failure alarms won't actually deliver.

## Lessons from the first deploy

Four issues surfaced during the actual first deploy that aren't obvious
from reading the template alone. Documented here so they don't need to
be rediscovered.

**1. GitHub's immutable OIDC subject-claim format (rolled out ~July 2026).**
Repos created after July 15, 2026 automatically get subject claims in the
format `repo:OWNER@OWNER-ID/REPO@REPO-ID:ref:refs/heads/BRANCH`, not the
older `repo:OWNER/REPO:*`. A trust policy written with the old
name-only format fails with `Not authorized to perform
sts:AssumeRoleWithWebIdentity` and gives no hint that the format itself
is the problem. Confirm which format a given repo uses via:
```powershell
gh api repos/<owner>/<repo>/actions/oidc/customization/sub
```
(requires GitHub CLI + `gh auth login`; the plain `Invoke-RestMethod`
calls in step 2 above work without auth for getting the raw IDs, but
don't confirm which format is actually in effect).

**2. `GitHubActionsDeployRole` needs more than `lambda:UpdateFunctionCode`.**
Any Lambda property change beyond just the code — `Timeout`, `MemorySize`,
etc. — requires `lambda:UpdateFunctionConfiguration` too. And because the
template's `ExtractionLambda` resource references its execution role via
`!GetAtt ExtractionLambdaRole.Arn`, CloudFormation re-resolves that
reference on *any* update to the Lambda resource, requiring `iam:GetRole`
on that specific role — even when the role itself isn't changing. Both
are already included in the current template's `GitHubActionsDeployRole`
policy; noted here because the error messages for each are easy to
mistake for something else while debugging.

**3. Any change to `GitHubActionsDeployRole`'s own trust policy or
permissions must be deployed manually, never through GitHub Actions.**
This is a hard IAM self-reference limit, not a one-off bug: the role
can't grant itself new permissions via a deploy it makes using its
*current* (insufficient) permissions. Pushing such a change to `main` and
letting the workflow attempt it just reproduces the same failure the fix
was meant to solve. Deploy directly from a local machine with broader
credentials instead, then let subsequent *pure code* changes (no IAM/
config changes) flow through GitHub Actions normally.

**4. `extract_handler.py`'s batching is byte-size-based, not row-count-based
— on purpose, after row-count batching failed in practice.** An earlier
version batched by a fixed row count (5,000 rows/batch) and still hit
`Runtime.OutOfMemory` on the first-run historical backfill, even at
1024MB. Individual row sizes for these tables vary enough (per the
source requirements doc, some rows may hold a full day's activity list
per lead, not a single activity) that row count alone isn't a safe proxy
for memory usage. The current version accumulates serialized rows into a
buffer and flushes to a new S3 file once the buffer hits ~4MB, keeping
memory bounded regardless of how large any individual row turns out to
be. Empirically validated: peak memory usage was 221MB extracting 17,174
rows from `close_crm_users_raw` (the largest table by volume in the first
run) — Lambda memory was subsequently right-sized from an initial 3008MB
safety-margin guess down to 512MB based on this real observed peak.



- Silver/Gold layer (Snowflake side) — separate deploy path, per the
  GitHub Actions + Snowflake CLI discussion (Layer 3/4 scaffolding).
- Row-count reconciliation and `silver.parse_failures` (Solution Design
  Doc Sections 6.2/6.3) — those live in Snowflake, not this AWS stack.
- `leads_raw` extraction — intentionally excluded pending Open Item #2
  resolution. Adding it later is a one-line change to the `TABLES` list
  in `extract_handler.py` plus a matching SSM checkpoint parameter in
  `template.yaml`.

## Local testing before first deploy

`extract_handler.py` reads its config entirely from environment variables
and Secrets Manager / SSM at runtime — there's no local `.env` file to
create. To test the query logic against the real Postgres instance before
wiring up Lambda, run the extraction logic directly with `boto3`
credentials configured locally (same account, same role permissions the
Lambda will eventually have) rather than deploying first and debugging
in CloudWatch Logs.