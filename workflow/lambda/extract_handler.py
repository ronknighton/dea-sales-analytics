"""
Sales Analytics Pipeline — Postgres to S3 Extraction Lambda
=============================================================
Runs on a daily EventBridge Scheduler trigger. For each of the three
confirmed source tables (sales_raw schema — see Solution Design Doc
Open Item #1 for the schema justification), pulls rows newer than the
last successful checkpoint, batches them to a single NDJSON file per
table, writes to S3 raw/, and advances the checkpoint only after a
successful write.

Deliberately does NOT touch leads_raw (Open Item #2 — assumed out of
scope) and does NOT attempt any JSON repair here — raw/ stays an
untouched mirror of the source; repair happens in Silver.

Uses pg8000 (pure Python, no compiled extension) instead of psycopg2
to avoid needing a Lambda Layer built for the Linux runtime.
"""

import json
import os
from datetime import datetime, timezone

import boto3
import pg8000.native

# ---------------------------------------------------------------------------
# Configuration — populated from environment variables set by CloudFormation
# ---------------------------------------------------------------------------
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
S3_BUCKET = os.environ["S3_BUCKET"]
SCHEMA = os.environ.get("SOURCE_SCHEMA", "sales_raw")
SSM_CHECKPOINT_PREFIX = os.environ.get("SSM_CHECKPOINT_PREFIX", "/sales-analytics-pipeline/checkpoints")

# Tables confirmed in scope — see Solution Design Doc Section 2.1.
# leads_raw is intentionally excluded (Open Item #2).
TABLES = ["lead_activites_raw", "custom_activites_raw", "close_crm_users_raw"]

# Default checkpoint used on first run for a table with no prior checkpoint.
EPOCH_DEFAULT = "1970-01-01 00:00:00"

secrets_client = boto3.client("secretsmanager")
ssm_client = boto3.client("ssm")
s3_client = boto3.client("s3")


def get_db_credentials():
    """Fetch Postgres connection details from Secrets Manager. Credentials
    are never logged, hardcoded, or written anywhere other than the live
    connection object."""
    response = secrets_client.get_secret_value(SecretId=DB_SECRET_ARN)
    return json.loads(response["SecretString"])


def get_checkpoint(table: str) -> str:
    """Read the last successfully-extracted insert_date for a table.
    Returns EPOCH_DEFAULT if no checkpoint exists yet (first run)."""
    param_name = f"{SSM_CHECKPOINT_PREFIX}/{table}"
    try:
        response = ssm_client.get_parameter(Name=param_name)
        return response["Parameter"]["Value"]
    except ssm_client.exceptions.ParameterNotFound:
        return EPOCH_DEFAULT


def set_checkpoint(table: str, new_checkpoint: str):
    """Advance the checkpoint. Only called after a successful S3 write for
    that table's batch, so a failed write never silently loses rows."""
    param_name = f"{SSM_CHECKPOINT_PREFIX}/{table}"
    ssm_client.put_parameter(
        Name=param_name,
        Value=new_checkpoint,
        Type="String",
        Overwrite=True,
    )


DB_FETCH_PAGE_SIZE = 100       # rows per DB round-trip — kept small since
                                 # per-row size for this table is unknown/variable
S3_BATCH_SIZE_BYTES = 4 * 1024 * 1024  # 4 MB — flush to S3 once a batch reaches this size


def extract_table(conn, table: str) -> dict:
    """Query one table for rows newer than its checkpoint, in fixed-size
    DB pages, accumulating serialized rows into a buffer that flushes to
    its own S3 file once it reaches S3_BATCH_SIZE_BYTES. Byte-size-based
    batching (not row-count-based) because individual row sizes for this
    table appear to vary unpredictably — the requirements doc describes
    each row potentially holding a full day's activity list per lead, not
    one activity per row, so a fixed row count cannot reliably bound
    memory usage. A prior row-count-based version (5000 rows/batch) still
    hit Runtime.OutOfMemory at 1024MB, confirming row count alone isn't
    a safe proxy for memory here.

    Raises on any failure rather than swallowing errors, so a failed
    extraction shows up as a Lambda error (triggers the CloudWatch alarm
    per Solution Design Doc Section 6.1) instead of failing silently.

    The checkpoint only advances after ALL batches for this table succeed."""
    checkpoint = get_checkpoint(table)

    run_timestamp = datetime.now(timezone.utc)
    dt_partition = run_timestamp.strftime("%Y-%m-%d")
    file_timestamp = run_timestamp.strftime("%Y%m%d_%H%M%S")

    total_rows = 0
    latest_insert_date = checkpoint
    batch_num = 0
    s3_keys = []
    offset = 0

    current_batch_lines = []
    current_batch_bytes = 0

    def flush_batch():
        nonlocal batch_num, current_batch_lines, current_batch_bytes
        if not current_batch_lines:
            return
        ndjson_body = "\n".join(current_batch_lines)
        s3_key = f"raw/{table}/dt={dt_partition}/{table}_{file_timestamp}_batch{batch_num:04d}.json"
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=s3_key,
            Body=ndjson_body.encode("utf-8"),
            ContentType="application/x-ndjson",
        )
        s3_keys.append(s3_key)
        print(f"  {table} batch {batch_num}: {len(current_batch_lines)} rows, "
              f"{current_batch_bytes / 1024 / 1024:.2f} MB -> {s3_key}", flush=True)
        batch_num += 1
        current_batch_lines = []
        current_batch_bytes = 0

    while True:
        rows = conn.run(
            f"SELECT raw_data, insert_date FROM {SCHEMA}.{table} "
            f"WHERE insert_date > :checkpoint ORDER BY insert_date "
            f"LIMIT :limit OFFSET :offset",
            checkpoint=checkpoint, limit=DB_FETCH_PAGE_SIZE, offset=offset,
        )

        if not rows:
            break

        print(f"  {table}: fetched DB page at offset {offset}, {len(rows)} rows", flush=True)

        for raw_data, insert_date in rows:
            line = json.dumps(raw_data)
            current_batch_lines.append(line)
            current_batch_bytes += len(line.encode("utf-8"))

            insert_date_str = insert_date.isoformat(sep=" ")
            if insert_date_str > latest_insert_date:
                latest_insert_date = insert_date_str

            if current_batch_bytes >= S3_BATCH_SIZE_BYTES:
                flush_batch()

        total_rows += len(rows)

        if len(rows) < DB_FETCH_PAGE_SIZE:
            break  # last page was partial — no more rows to fetch

        offset += DB_FETCH_PAGE_SIZE

    flush_batch()  # write out whatever's left under the size threshold

    if total_rows == 0:
        return {"table": table, "rows_extracted": 0, "checkpoint_advanced": False}

    set_checkpoint(table, latest_insert_date)

    return {
        "table": table,
        "rows_extracted": total_rows,
        "batches": batch_num,
        "checkpoint_advanced": True,
        "new_checkpoint": latest_insert_date,
        "s3_keys": s3_keys,
    }


def handler(event, context):
    """Lambda entry point. Extracts all three confirmed tables in one
    invocation. If any table fails, the exception propagates so the whole
    invocation is marked FAILED (not partially-successful-but-silent)."""
    creds = get_db_credentials()

    conn = pg8000.native.Connection(
        user=creds["username"],
        password=creds["password"],
        host=creds["host"],
        port=int(creds.get("port", 5432)),
        database=creds["dbname"],
    )

    try:
        results = []
        for table in TABLES:
            result = extract_table(conn, table)
            results.append(result)
            print(f"Extracted {table}: {result}")

        return {
            "statusCode": 200,
            "body": json.dumps({"results": results}),
        }
    finally:
        conn.close()