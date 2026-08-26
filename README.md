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
   `token.actions.githubusercontent.com:sub: repo:<org>/<repo>:*` under
   `GitHubActionsDeployRole` and replace `<org>/<repo>` with the actual
   GitHub org/repo this lives in, before the first deploy.

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

## What this does NOT include yet

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