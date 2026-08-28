-- ============================================================================
-- Sales Analytics Pipeline — Silver Layer: JSON Repair UDF
-- Solution Design Doc Section 4.3
-- ============================================================================
-- Ported directly from the Python heuristic developed and tested locally
-- against real sample data before being written here. Applies only to
-- custom_activites_raw and close_crm_users_raw — lead_activites_raw's
-- payload is already valid nested jsonb and skips this step entirely.

USE DATABASE SALES_ANALYTICS_PIPELINE;
USE SCHEMA SILVER;

CREATE OR REPLACE FUNCTION REPAIR_JSON_QUOTES(RAW_TEXT STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = 3.11
HANDLER = 'repair'
COMMENT = 'Repairs single-quote-instead-of-double-quote JSON malformation where the delimiter collides with literal apostrophes in free text (e.g. "Prospect''s Name"). Heuristic: inside a string, a single quote closes the string only if, after skipping whitespace, the next character is one of , } ] : or end-of-string — otherwise treated as a literal apostrophe. Known limitation: prose fields using single quotes as scare-quotes around other words are genuinely ambiguous and may parse with shifted boundaries; this does not affect short structured values (outcome codes, names, ids). Confirmed via a real deploy failure: some rows have a NULL PAYLOAD:JSON_OBJECT value (structural inconsistency in source data, not universal per row) — function returns NULL on NULL input rather than crashing, since a Python exception inside a UDF aborts the entire calling statement rather than just that row, defeating the quarantine design in SP_SILVER_PROCESS.'
AS
$$
def repair(raw_text):
    if raw_text is None:
        return None
    result = []
    in_string = False
    i, n = 0, len(raw_text)
    while i < n:
        ch = raw_text[i]
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
                while j < n and raw_text[j] in ' \t\n\r':
                    j += 1
                next_char = raw_text[j] if j < n else ''
                if next_char in (',', '}', ']', ':') or next_char == '':
                    in_string = False
                    result.append('"')
                else:
                    result.append("'")
                i += 1
            elif ch == '"':
                result.append('\\"')
                i += 1
            elif ch == '\\':
                result.append(ch)
                i += 1
            else:
                result.append(ch)
                i += 1
    return ''.join(result)
$$;