# Sales Analytics Pipeline — Known Gaps & Proposed Fixes

Status as of 2026-10-04. Snowflake trial ends 2026-10-05, so the items below are
documented rather than applied. Final report exports were captured 2026-10-04
~17:03 UTC from the live views (Inbound, Outbound, Closer, Objections).

## 1. Where validation stands

| Area | Status |
|---|---|
| Pipeline (extraction → Bronze → Silver → Gold → Streamlit) | Built; 7 consecutive successful daily runs confirmed in `TASK_HISTORY` |
| Structural bugs found against live data | 8 found and fixed (section 3) |
| Inbound / Outbound report definitions | Aligned to the SME's reference: his rate columns reproduce row-for-row (show = taken/booked, set = set/taken, strategy-taken = taken/set, dial-to-set = set/total dials) |
| Closer report attendance logic | **Known gap** (section 4.1) — fix specified, not applied |
| Objections "Wasn't Looking" category | **Known gap** (section 4.2) — fix specified, not applied |
| Absolute-count reconciliation with the SME's files | **Not achievable** from this dataset (section 4.5) |

## 2. Corrections to earlier statements

Two claims made earlier in this validation were wrong and are withdrawn:

- *"The Closer field is blank at the source on ~half of strategy calls."* Wrong. Cause was a
  join bug (section 3, item 6): after the fix, 238 of 238 strategy calls (Sept 1–11) have a Closer.
- *"My Sept 1–11 total (428) matches the SME's 426."* A coincidence. With ~35 calls/day some cutoff
  date lands within a few of almost any target, and the 428 was itself inflated by the same bug.

## 3. Bugs found and fixed during validation

1. Lambda wrote rows without the `{payload, insert_date}` wrapper Bronze expected (all-NULL Bronze content).
2. `FORCE = TRUE` reload resurrected stale pre-fix S3 files (doubled row counts).
3. `CUSTOM_ACTIVITY_FIELDS` was never deduplicated (52x inflation).
4. `FACT_LEAD_FUNNEL` assumed `custom.cf_XXXX` fields were nested; they are flat keys with a literal period.
5. `LEAD_ACTIVITIES_PROCESSED` MERGE keyed on `activity_id`, which does not exist (the field is `id`) — dedup never matched.
6. **`FACT_LEAD_FUNNEL` joined to the field catalog on field id only.** Fields shared across activity types
   (Setter on 7 types, Avatar on 6) caused every activity to be labeled as every type owning any of its
   fields. Fixed by also matching `custom_activity_type_id` (21 of 21 type ids matched the catalog).
   This single bug explained: identical per-type counts for shared fields, 37 of 45 "triage" rows with no
   outcome, 23 "sales" among 44 "triage" calls, and the ~48% "blank Closer" rate.
7. `SALES_DETAILS` fanned out joins (79% blank stub rows; leads with multiple records). Now one row per lead.
8. Streamlit averaged pre-computed percentages (98.7% vs correctly pooled 87.8%).

Report definitions for Inbound and Outbound were also rewritten to the SME's reference (see `003_report_views.sql`)
and `TOTAL_OFFER` / `OFFER_RATE`, omitted in the first pass despite being documented, were added.

## 4. Known gaps and the fix to apply

### 4.1 Strategy-call attendance is misclassified (affects Closer, Inbound, Outbound)

Two defects in `STRATEGY_CALL_ACTIVITIES` / `ALL_STRATEGIES_DETAILS`:

- **Follow-up calls record their outcome in a different field** (`Follow Up Call Outcome`); the view reads only
  `Strategy Call Outcome`, so follow-up calls have no outcome and fall into "attended".
- **Attendance is defined by exclusion**, and `Reschedule` is missing from the exclusion list.

Real outcome values, all-time distinct activities (this is the complete population: 1,312 + 274 = 1,586 =
the Closer export's total `CALL_BOOKED`):

| Strategy Call Outcome | n | Class | | Follow Up Call Outcome | n | Class |
|---|---|---|---|---|---|---|
| 4. No Show | 487 | not attended | | 3. No Show | 102 | not attended |
| 1. Follow Up | 458 | attended | | 1. Follow Up | 69 | attended |
| 5. Reschedule | 163 | not attended* | | 4. Reschedule | 53 | not attended* |
| 2. Admin Cancel | 82 | cancel | | 2. Cancel- No Longer Interested | 36 | cancel |
| 3. Cancel- Not Interested | 53 | cancel | | 5. Sale | 7 | attended |
| 6. Sale | 37 | attended | | 7. Cancel- Nurture | 6 | cancel |
| 8. Cancel- Nurture | 21 | cancel | | 6. Lost | 1 | attended |
| 7. Lost | 11 | attended | | | | |

\* Reschedule is not in the requirements doc's lists; treating it as not-attended is an assumption to confirm.

**Impact, verified by arithmetic:** the Closer report currently shows 943 "shows". The correct count is
506 + 77 = **583**. The 360 difference is 163 strategy-field reschedules plus 197 follow-up calls
(no-show/reschedule/cancel) that never happened. Corrected all-time rates: show 36.8%, no-show 37.1%,
reschedule 13.6%, cancel 12.5% (sums to 100%). The SME's September reference shows show 34.7% and no-show
35.7%; ours currently reads show 55.2% / no-show 36.8%.

**Fix (`002_kpi_views.sql`):**

```sql
-- STRATEGY_CALL_ACTIVITIES: read the follow-up field as well
COALESCE(
    MAX(CASE WHEN FIELD_NAME = 'Strategy Call Outcome'  THEN OUTCOME_VALUE END),
    MAX(CASE WHEN FIELD_NAME = 'Follow Up Call Outcome' THEN OUTCOME_VALUE END)
) AS STRATEGY_CALL_OUTCOME,

-- ALL_STRATEGIES_DETAILS: explicit classification instead of exclusion
CASE
  WHEN STRATEGY_CALL_OUTCOME IN ('1. Follow Up','6. Sale','5. Sale','7. Lost','6. Lost')
       THEN 'ATTENDED'
  WHEN STRATEGY_CALL_OUTCOME IN ('4. No Show','3. No Show','5. Reschedule','4. Reschedule',
       '2. Admin Cancel','3. Cancel- Not Interested','2. Cancel- No Longer Interested',
       '8. Cancel- Nurture','7. Cancel- Nurture')
       THEN 'NOT_ATTENDED'
  ELSE 'PENDING'
END AS STATUS
```

**Fix (`003_report_views.sql`, `CLOSER_REPORT`)** — count both numbering schemes:

```sql
ADMIN_CANCEL         : STRATEGY_CALL_OUTCOME = '2. Admin Cancel'
CANCEL_NURTURE       : IN ('8. Cancel- Nurture','7. Cancel- Nurture')
CANCEL_NOT_INTEREST  : IN ('3. Cancel- Not Interested','2. Cancel- No Longer Interested')
NO_SHOW              : IN ('4. No Show','3. No Show')
LOST                 : IN ('7. Lost','6. Lost')
SALE                 : IN ('6. Sale','5. Sale')
```

Inbound/Outbound read `STATUS`, so they correct automatically.

### 4.2 Objections: "Wasn't Looking For What We Offered" never matches

`OBJECTIONS_FACED_REPORT` matched the pattern `%not looking%`; the real option text is
`Wasn't Looking For What We Offered`. Result: 0.0% of 1,353 calls versus 5.5% in the SME's file.

**Fix:** `OBJECTION_RAW ILIKE '%looking%' AS IS_NOT_LOOKING`. Related, unfixed: the field also contains
`"No Show"` as a value (162 occurrences), which is not one of the 12 categories (counts toward total calls
only), and a second field named `Objection faced` exists that the report does not read.

### 4.3 Triage follow-up outcome field (to verify)

`INBOUND_STRATEGIES_BOOKED` reads only `Triage Call Outcome` for both triage types. If
`4) Triage Call Follow Up` records its outcome in `Follow Up Call Outcome` (as the strategy follow-up does),
those rows are undercounted as "taken". Verify with a distinct-values query on that field for type 4, then
apply the same COALESCE pattern.

### 4.4 Outbound dial volume cannot be reproduced

The SME's reference reports 22,236 dials on Sept 2. Our dataset holds ~819 raw outbound `Call` activities for
that day, and `TOTAL_OUTBOUND_CALLS` counts logged prospecting activities (1,477 all-time). The SME advised
ignoring pick-up / quality metrics; the dial denominator for dial-to-set needs his guidance on source.

### 4.5 The SME's totals are ~3.5–4x larger than this dataset

Closer: 426 (his file, exported ~Sept 7 per filename timestamps) vs 125 here through Sept 7.
Inbound booked on Sept 2: 31 vs 8. Two independent reports show the same factor, consistent with his
source being a larger dataset. Absolute reconciliation is therefore not meaningful; **compare rates only.**

### 4.6 Staff accounts

Every Setter and Closer in the data is a `dataengineeracademy.com` account. The `IS_INTERNAL` filter was
removed from all report views (flag retained on `DIM_USERS`). Needs SME confirmation that staff activity is
the intended simulated sales team.

## 5. Closed items

- `LEAD_ROUTE` / `leads_raw`: SME said to ignore; `leads_raw` stays out of scope.
- Export Layer: SME confirmed not required (Streamlit reads Gold views directly).

## 6. Questions for the SME

1. Where do **Reschedule** outcomes land in the Closer report? His admin-cancel rate (14.3%) is far above
   Admin Cancel alone (1.8% here), while reschedules are ~13.6% of calls.
2. Are staff (`dataengineeracademy.com`) accounts the intended sales team, or should they be excluded?
3. What is the source of "dials" (raw dialer volume?), and is our dataset a subset of the system his
   QuickSight reports use?
4. Approval to apply the fixes in 4.1–4.3, or is documentation sufficient?
