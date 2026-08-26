"""
Sales Analytics Pipeline — JSON repair + targeted source analysis
====================================================================
Connects to the DEA Postgres instance, pulls raw rows, repairs the
single-quote-instead-of-double-quote malformation inside the JSON_OBJECT
string field, and runs three targeted investigations:

  1. Full custom activity type catalog (name + is_archived) from
     custom_activites_raw — ground truth for what activity types exist.
  2. Outcome-value scan across lead_activites_raw — finds every string
     value matching a "N. Label" / "N) Label" pattern, to settle whether
     '3. No Show' and '4. No Show' (etc.) are both real or a doc artifact.
  3. Email domain check on close_crm_users_raw — hypothesis test for
     what DEA_INTERNAL_NAME/EMAIL might be derived from.

Usage:
    pip install psycopg2-binary --break-system-packages
    python3 repair_and_analyze.py

You'll be prompted for the DB password interactively (not stored/hardcoded).
Results print to the terminal AND get written to analysis_results.txt in
the same folder you run this from, so you can easily copy/paste or send
the file back without manually selecting terminal output.

Defaults to the sales_raw schema, since profiling evidence (fathom_recordings_raw,
matching row-count patterns) strongly suggests that's the correct schema for
this project rather than "raw" as the requirements doc states — change
SCHEMA below if that's contradicted by SME confirmation.
"""

import getpass
import json
import re
import sys
from collections import Counter

import psycopg2

OUTPUT_FILE = "analysis_results.txt"


class Tee:
    """Writes to both stdout and a file simultaneously, so you see progress
    live in the terminal AND get a clean file to copy/paste or send back."""
    def __init__(self, filename):
        self.terminal = sys.stdout
        self.log = open(filename, "w", encoding="utf-8")

    def write(self, message):
        self.terminal.write(message)
        self.log.write(message)

    def flush(self):
        self.terminal.flush()
        self.log.flush()

    def close(self):
        self.log.close()


# ---------------------------------------------------------------------------
# Connection settings
# ---------------------------------------------------------------------------
DB_HOST = "dea.cgyi97rb4alr.us-east-1.rds.amazonaws.com"
DB_PORT = 5432
DB_NAME = "dea_analytics_dev"
DB_USER = "student_user"
SCHEMA = "sales_raw"  # change to "raw" to compare against the other schema


# ---------------------------------------------------------------------------
# JSON repair (single-quote -> double-quote, apostrophe-aware)
# ---------------------------------------------------------------------------
def repair_malformed_json(raw: str) -> str:
    """
    Repairs JSON-like strings where double quotes were replaced with single
    quotes, colliding with literal apostrophes in text values.

    Heuristic: inside a string, a single quote closes the string only if,
    after skipping whitespace, the next character is one of , } ] : or
    end-of-string. Otherwise it's treated as a literal apostrophe.

    Known limitation: prose fields using single quotes as scare-quotes
    around other words are genuinely ambiguous and may parse with shifted
    boundaries. This does not affect short structured values (outcome
    codes, names, ids) which is what this script targets.
    """
    result = []
    in_string = False
    i, n = 0, len(raw)
    while i < n:
        ch = raw[i]
        if not in_string:
            if ch == "'":
                in_string = True
                result.append('"')
            else:
                result.append(ch)
            i += 1
        else:
            if ch == "'":
                j = i + 1
                while j < n and raw[j] in " \t\n\r":
                    j += 1
                next_char = raw[j] if j < n else ""
                if next_char in (",", "}", "]", ":") or next_char == "":
                    in_string = False
                    result.append('"')
                else:
                    result.append("'")
                i += 1
            elif ch == '"':
                result.append('\\"')
                i += 1
            elif ch == "\\":
                result.append(ch)
                i += 1
            else:
                result.append(ch)
                i += 1
    return "".join(result)


_debug_failures_shown = 0
MAX_DEBUG_FAILURES = 3


def parse_row(raw_data: dict, debug: bool = False):
    """raw_data is the outer jsonb column. Two structures have been observed
    in this schema:
      - {INSERT_DATE, JSON_OBJECT}: JSON_OBJECT is a malformed single-quoted
        string that needs repair (custom_activites_raw, close_crm_users_raw).
      - {data: [...]}: already clean, valid nested jsonb, no repair needed
        (lead_activites_raw, as discovered 2026-08-25).
    Returns a Python dict, or None if neither structure matches / parsing
    fails, with debug diagnostics printed for the first few failures."""
    global _debug_failures_shown

    if "JSON_OBJECT" in raw_data:
        inner = raw_data["JSON_OBJECT"]
        repaired = repair_malformed_json(inner)
        try:
            return json.loads(repaired)
        except json.JSONDecodeError as e:
            if debug and _debug_failures_shown < MAX_DEBUG_FAILURES:
                _debug_failures_shown += 1
                start = max(0, e.pos - 80)
                end = min(len(repaired), e.pos + 80)
                print(f"\n  [DEBUG] Parse failure #{_debug_failures_shown}: {e}")
                print(f"  [DEBUG] Repaired string around error position (char {e.pos}):")
                print(f"    ...{repaired[start:end]}...")
            return None

    elif "data" in raw_data:
        # Already valid jsonb -- no repair needed
        return raw_data

    else:
        if debug and _debug_failures_shown < MAX_DEBUG_FAILURES:
            print(f"  [DEBUG] Unrecognized raw_data structure. Keys: {list(raw_data.keys())}")
            _debug_failures_shown += 1
        return None


# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------
def connect():
    try:
        password = getpass.getpass(f"Password for {DB_USER}@{DB_HOST}: ")
    except Exception:
        # Some terminals (e.g. certain PowerShell hosts) don't support
        # hidden input. Fall back to a visible prompt rather than hanging.
        print("[NOTE] Hidden password input not supported in this terminal.")
        print("       Falling back to visible input -- password WILL show on screen.")
        password = input(f"Password for {DB_USER}@{DB_HOST}: ")
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=password,
    )


def fetch_all_rows(conn, table: str, limit: int = None):
    """Fetch raw_data from a table, optionally limited. Returns list of dicts."""
    query = f"SELECT raw_data FROM {SCHEMA}.{table} ORDER BY (raw_data->>'INSERT_DATE') DESC"
    if limit:
        query += f" LIMIT {limit}"
    with conn.cursor() as cur:
        cur.execute(query)
        rows = cur.fetchall()
    return [r[0] for r in rows]


# ---------------------------------------------------------------------------
# Analysis 1: Custom activity catalog
# ---------------------------------------------------------------------------
def analyze_custom_activities(conn):
    print("\n" + "=" * 70)
    print("1. CUSTOM ACTIVITY CATALOG (sales_raw.custom_activites_raw)")
    print("=" * 70)
    raw_rows = fetch_all_rows(conn, "custom_activites_raw", limit=1)  # latest snapshot only
    if not raw_rows:
        print("  No rows found.")
        return
    parsed = parse_row(raw_rows[0])
    if parsed is None:
        print("  Failed to parse latest row.")
        return
    activities = parsed.get("data", [])
    print(f"  Found {len(activities)} activity type definitions:\n")
    for act in sorted(activities, key=lambda a: a.get("name", "")):
        archived = " [ARCHIVED]" if act.get("is_archived") else ""
        print(f"    - {act.get('name')}{archived}")


# ---------------------------------------------------------------------------
# Analysis 2: Outcome value scan (Open Item #3)
# ---------------------------------------------------------------------------
OUTCOME_PATTERN = re.compile(r"^\s*\d+[).]\s*.+")


def find_outcome_like_values(obj, results: Counter, key_path: str = ""):
    """Recursively walk a parsed structure, collecting string values that
    match the 'N. Label' or 'N) Label' outcome-code pattern, tagged with
    the key they were found under."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            find_outcome_like_values(v, results, key_path=f"{key_path}.{k}" if key_path else k)
    elif isinstance(obj, list):
        for item in obj:
            find_outcome_like_values(item, results, key_path=key_path)
    elif isinstance(obj, str):
        if OUTCOME_PATTERN.match(obj):
            results[(key_path, obj)] += 1


def analyze_outcome_duplication(conn, sample_size: int = 500):
    print("\n" + "=" * 70)
    print(f"2. OUTCOME VALUE SCAN (sales_raw.lead_activites_raw, last {sample_size} rows)")
    print("=" * 70)
    raw_rows = fetch_all_rows(conn, "lead_activites_raw", limit=sample_size)
    print(f"  Parsing {len(raw_rows)} rows...")
    results = Counter()
    parse_failures = 0
    for idx, raw in enumerate(raw_rows):
        parsed = parse_row(raw, debug=(idx < 10))  # debug the first 10 attempts
        if parsed is None:
            parse_failures += 1
            continue
        find_outcome_like_values(parsed, results)

    if parse_failures:
        print(f"  [WARN] {parse_failures} row(s) failed to parse.")

    print(f"\n  Distinct outcome-like values found (key_path -> value -> count):\n")
    for (key_path, value), count in sorted(results.items(), key=lambda x: -x[1]):
        print(f"    [{key_path}] '{value}'  (x{count})")

    # Highlight anything matching the specific duplication question
    print("\n  --- Checking specifically for No Show / Cancel-Nurture variants ---")
    for (key_path, value), count in results.items():
        if "no show" in value.lower() or "cancel" in value.lower():
            print(f"    [{key_path}] '{value}'  (x{count})")


# ---------------------------------------------------------------------------
# Analysis 3: DEA_INTERNAL hypothesis (Open Item #5)
# ---------------------------------------------------------------------------
def analyze_internal_users(conn, sample_size: int = 200):
    print("\n" + "=" * 70)
    print(f"3. USER EMAIL DOMAIN CHECK (sales_raw.close_crm_users_raw, last {sample_size} rows)")
    print("=" * 70)
    raw_rows = fetch_all_rows(conn, "close_crm_users_raw", limit=sample_size)
    domains = Counter()
    roles = Counter()
    for raw in raw_rows:
        parsed = parse_row(raw)
        if parsed is None:
            continue
        for user in parsed.get("data", []):
            email = user.get("email", "")
            if "@" in email:
                domain = email.split("@")[-1].lower()
                domains[domain] += 1
            role = user.get("role")
            if role:
                roles[role] += 1

    print("\n  Email domains found:")
    for domain, count in domains.most_common():
        print(f"    {domain}: {count}")

    print("\n  Roles found:")
    for role, count in roles.most_common():
        print(f"    {role}: {count}")

    print("\n  If one domain stands out as clearly 'internal' (e.g. matches DEA's")
    print("  own domain rather than a customer/business domain), that's your")
    print("  candidate source field for DEA_INTERNAL_NAME/EMAIL. If all users")
    print("  share one domain or nothing stands out, this likely isn't")
    print("  derivable from Postgres alone -- take that back to the SME.")


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    tee = Tee(OUTPUT_FILE)
    sys.stdout = tee
    try:
        conn = connect()
        try:
            analyze_custom_activities(conn)
            analyze_outcome_duplication(conn, sample_size=500)
            analyze_internal_users(conn, sample_size=200)
        finally:
            conn.close()
    finally:
        sys.stdout = tee.terminal
        tee.close()
        print(f"\nResults also written to: {OUTPUT_FILE}")