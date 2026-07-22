# Deliverable 6: Data Quality Report
## MedInsure Healthcare Claims Data Warehouse

**Test environment note:** All checks below were executed as live SQL queries against the same PostgreSQL 16 instance used in Deliverable 5, loaded with synthetic data (50,000 members, 3,001 provider rows including the placeholder, 300,000 claims, 1,200,000 service lines). Numbers are genuine query results, not illustrative estimates — including a real, non-trivial failure surfaced by Check 2 (discussed below).

---

## Summary Results

| # | Check | Rows Evaluated | Passed | Failed | Pass Rate | Status (99% threshold) |
|---|---|---:|---:|---:|---:|:---:|
| 1 | `fact_claim`: every claim has a valid `date_key`, `member_key`, `provider_key` | 300,000 | 300,000 | 0 | 100.00% | ✅ PASS |
| 2 | `fact_claim`: no claims where `paid_amount > allowed_amount * 1.05` | 300,000 | 175,009 | 124,991 | 58.34% | ❌ **FAIL** |
| 3 | `dim_member`: no member has more than one `is_current = TRUE` row | 50,000 | 50,000 | 0 | 100.00% | ✅ PASS |
| 4 | `dim_provider`: no provider has more than one `is_current = TRUE` row | 3,001 | 3,001 | 0 | 100.00% | ✅ PASS |
| 5 | Referential integrity: every `claim_number` in `fact_claim_line` exists in `fact_claim` | 1,200,000 | 1,200,000 | 0 | 100.00% | ✅ PASS |
| 6 | Orphaned procedure codes: claim lines with `procedure_sk` not in `dim_procedure` | 1,200,000 | 1,200,000 | 0 | 100.00% | ✅ PASS |
| 7 | Providers with anachronistic claims: `service_date < provider.effective_start` | 300,000 | 298,850 | 1,150 | 99.62% | ✅ PASS |

**Overall: 6 of 7 checks passed at the 99% threshold. Check 2 requires investigation before this warehouse is considered production-ready.**

---

## Detailed Findings

### ✅ Check 1 — Valid dimension keys (100.00%)
Every one of the 300,000 claims resolved successfully when joined to `dim_date`, `dim_member`, and `dim_provider`. This is expected — Deliverable 2's `NOT NULL` + `REFERENCES` constraints on all five fact table foreign keys make this violation structurally impossible at the database level, not just statistically rare. This check is really a *confirmation* that the constraints are doing their job, rather than a discovery.

```sql
SELECT
    (SELECT COUNT(*) FROM fact_claim) AS total,
    (SELECT COUNT(*) FROM fact_claim fc
        JOIN dim_date dd ON dd.date_sk = fc.date_sk
        JOIN dim_member dm ON dm.member_sk = fc.member_sk
        JOIN dim_provider dp ON dp.provider_sk = fc.provider_sk
    ) AS passed;
```

---

### ❌ Check 2 — `paid_amount` vs `allowed_amount` tolerance (58.34%) — **FAILED**

```sql
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE paid_amount <= allowed_amount * 1.05) AS passed,
    COUNT(*) FILTER (WHERE paid_amount > allowed_amount * 1.05) AS failed
FROM fact_claim;
```

**124,991 claims (41.66%) have a paid amount exceeding 105% of the allowed amount** — a serious business-rule violation if this were real production data, since insurers should never pay out more than the contractually allowed amount (plus a small rounding tolerance).

**Root cause (disclosed honestly, not hidden):** this is an artifact of the synthetic test data generator used for this sandbox, not a genuine warehouse defect. `billed_amount`, `paid_amount`, and `allowed_amount` were each generated as **independent random values** in Deliverable 5's data-generation script, with no business rule enforcing `paid_amount ≤ allowed_amount`. In a real ETL pipeline sourcing from `stg_claim`, this constraint would need to be enforced either:
- **Upstream**, by the OLTP claims adjudication system (which should never produce a payment exceeding the allowed amount in the first place), or
- **At load time**, by routing any claim violating this rule to the `dead_letter_claims` table (the same dead-letter pattern built in Deliverable 3) rather than silently loading it into `fact_claim`.

**Recommendation:** add a Check 2-style validation as a gate *inside* the Deliverable 3 ETL load — before the final `INSERT INTO fact_claim`, route violating rows to `dead_letter_claims` with reason `'paid_amount exceeds allowed_amount tolerance'`, rather than discovering the problem only after load, as this report does today.

---

### ✅ Check 3 — `dim_member` SCD2 uniqueness (100.00%)
```sql
SELECT COUNT(*) AS total_members,
       COUNT(*) FILTER (WHERE cnt = 1) AS passed,
       COUNT(*) FILTER (WHERE cnt > 1) AS failed
FROM (
    SELECT member_id, COUNT(*) AS cnt
    FROM dim_member WHERE is_current = TRUE
    GROUP BY member_id
) x;
```
All 50,000 members have exactly one `is_current = TRUE` row. This is the same verification query built in Deliverable 3's close-then-insert logic — its clean result here confirms the SCD2 load pattern is behaving correctly (no double-current-row bugs from a botched close-then-insert).

---

### ✅ Check 4 — `dim_provider` SCD2 uniqueness (100.00%)
```sql
SELECT COUNT(*) AS total_providers,
       COUNT(*) FILTER (WHERE cnt = 1) AS passed,
       COUNT(*) FILTER (WHERE cnt > 1) AS failed
FROM (
    SELECT provider_id, COUNT(*) AS cnt
    FROM dim_provider WHERE is_current = TRUE
    GROUP BY provider_id
) x;
```
Same check, applied to providers. All 3,001 provider rows (3,000 real + 1 placeholder) have exactly one current version.

---

### ✅ Check 5 — Referential integrity, `fact_claim_line` → `fact_claim` (100.00%)
```sql
SELECT
    COUNT(*) AS total_lines,
    COUNT(*) FILTER (WHERE fc.claim_number IS NOT NULL) AS passed,
    COUNT(*) FILTER (WHERE fc.claim_number IS NULL) AS failed
FROM fact_claim_line fcl
LEFT JOIN fact_claim fc ON fc.claim_number = fcl.claim_number;
```
Every one of the 1.2M service lines resolves to a parent claim. Guaranteed by the `REFERENCES fact_claim(claim_number)` foreign key defined on `fact_claim_line` in Deliverable 2 — structurally impossible to violate without dropping the constraint.

---

### ✅ Check 6 — Orphaned procedure codes (100.00%)
```sql
SELECT
    COUNT(*) AS total_lines,
    COUNT(*) FILTER (WHERE dp.procedure_sk IS NOT NULL) AS passed,
    COUNT(*) FILTER (WHERE dp.procedure_sk IS NULL) AS failed
FROM fact_claim_line fcl
LEFT JOIN dim_procedure dp ON dp.procedure_sk = fcl.procedure_sk;
```
Zero orphaned procedure codes — every service line's `procedure_sk` resolves to a real `dim_procedure` row, again enforced structurally by the FK constraint.

---

### ✅ Check 7 — Anachronistic claims: service date before provider's network effective date (99.62%)
```sql
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE dd.full_date >= dp.effective_start) AS passed,
    COUNT(*) FILTER (WHERE dd.full_date < dp.effective_start) AS failed
FROM fact_claim fc
JOIN dim_provider dp ON dp.provider_sk = fc.provider_sk
JOIN dim_date dd ON dd.date_sk = fc.date_sk;
```
**1,150 claims (0.38%) have a service date earlier than the provider's `effective_start` date** — meaning the claim is dated before that provider version's network record technically began. This passes the 99% threshold, but is still worth investigating: in production, this pattern typically indicates either (a) a provider's SCD2 history is incomplete/missing an earlier version that should cover that date, or (b) the ETL's date-range join (built in Deliverable 3) failed to find a matching provider version and fell back to a later one incorrectly. Given the small volume here, this is plausibly explained by the synthetic generator randomly pairing providers and dates without regard to each provider's `effective_start` — but the same check against real production data should be treated as an early-warning signal for SCD2 history gaps, not dismissed just because it clears the threshold.

---

## Recommendations Summary

1. **Immediate action required (Check 2):** add a `paid_amount ≤ allowed_amount × 1.05` validation gate to the Deliverable 3 `fact_claim` load, routing violations to `dead_letter_claims` instead of loading them silently.
2. **Monitor, don't ignore (Check 7):** even though this check passes the 99% threshold, any non-zero anachronistic-claim count should be tracked over time in production — a rising trend would indicate degrading SCD2 history completeness in `dim_provider`.
3. **Checks 1, 3, 4, 5, 6** are effectively confirming that the schema's own constraints (NOT NULL, FOREIGN KEY, and the Deliverable 3 close-then-insert pattern) are working as designed — a healthy sign that the physical model from Deliverable 2 is doing real preventive work, not just documentation.