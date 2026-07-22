# Deliverable 5: Performance Optimization Report
## MedInsure Healthcare Claims Data Warehouse

**Test environment note:** All `EXPLAIN ANALYZE` output in this report was captured against a live PostgreSQL 16 instance running the actual Deliverable 2 schema, loaded with synthetic data at a reduced scale (50,000 members, 3,000 providers, 300,000 claims, 1.2M service lines spanning 2023–2026) — large enough to produce genuine planner behavior (parallel workers, disk-spilled sorts, index-only scans) rather than hypothetical numbers.

---

## 1. Index Strategy

### Indexes created

| Table | Index | Columns | Type | Query it supports |
|---|---|---|---|---|
| `fact_claim` | `fact_claim_pkey` | `claim_number` | B-tree (unique) | Primary key lookups; also serves as the join target from `fact_claim_line` (dependency check during Deliverable 3's line load). |
| `fact_claim` | `idx_claims_date` | `date_sk` | B-tree | Q3, Q6, Q8 — every time-based rollup (monthly trend, YTD cumulative, utilization by month) filters/joins on `date_sk`. Confirmed via `EXPLAIN ANALYZE` on Q6: this index alone satisfied the query as an **Index Only Scan**, meaning Postgres never touched the underlying `fact_claim` heap at all for that column. |
| `fact_claim` | `idx_claims_provider` | `provider_sk` | B-tree | Q1, Q4, Q5, Q8 — every provider-level rollup (top providers, denial rate by specialty, network cost comparison, YTD by provider) joins on `provider_sk`. |
| `fact_claim` | `idx_claims_member` | `member_sk` | B-tree | Q3, Q5, Q7 — member-level utilization, cost comparison, and cohort analysis all join on `member_sk`. |
| `fact_claim` | `idx_claims_diagnosis` | `diagnosis_sk` | B-tree | Q2 — diagnosis-category spend ranking joins on `diagnosis_sk`. |
| `fact_claim` | `idx_claims_plan` | `plan_sk` | B-tree | Q3 — utilization rate by plan type joins on `plan_sk`. |
| `fact_claim_line` | `fact_claim_line_pkey` | `claim_number, line_number` | B-tree (unique, composite) | Enforces the grain (one row per service line per claim) and supports point lookups of a specific line. |
| `fact_claim_line` | `idx_claims_claim_number` | `claim_number` | B-tree | Supports the header→line load-ordering join in Deliverable 3, and any query rolling service lines back up to their parent claim. |
| `fact_claim_line` | `idx_claims_procedure` | `procedure_sk` | B-tree | Supports procedure-level rollups (e.g., "spend by CPT category") joining `fact_claim_line` to `dim_procedure`. |

All indexes above are plain single-column B-tree indexes — the standard default for foreign key columns, per the "index every FK" rule established in Module D. None are covering indexes in the formal sense (`INCLUDE` clause), though `idx_claims_date` incidentally behaves like one for Q6, since the query only ever needs `date_sk` from `fact_claim` itself (see execution plan analysis below).

### Indexes deliberately NOT created

**A composite index on `(provider_sk, date_sk)` on `fact_claim`.**
Considered for Q1 and Q8, both of which filter/partition by provider *and* date together. Decided against it for now because:
- The two existing single-column indexes (`idx_claims_provider`, `idx_claims_date`) already let Postgres choose either access path independently, and Postgres's hash-join planner handled both Q1 and Q8 efficiently without it (see plans below — neither chose a nested-loop-per-provider pattern that a composite index would specifically accelerate).
- `fact_claim` is the highest-write-volume table in the warehouse (2M claims/year in production). Every additional index adds write overhead to every incremental load. A composite index here would only pay off if profiling later shows the planner struggling with provider+date filtering specifically — premature to add it now on a hunch.
- **Trade-off summary:** marginal, unconfirmed read benefit vs. guaranteed write overhead on the highest-volume table in the schema. Deferred until real query patterns justify it.

**An index on `claim_status` / `claim_type` (used in Q4's denial analysis).**
Not indexed because both columns have very low cardinality (`claim_status` has 3 values; `claim_type` has 3 values). A B-tree index on a low-cardinality column typically isn't selective enough for the planner to prefer it over a sequential scan — Postgres would just ignore it in most cases, making it pure write overhead with no read benefit. If denial-rate queries become a frequent, performance-critical workload, a **partial index** (e.g., `WHERE claim_status = 'Denied'`) would be a better fit than a plain index on the whole column.

**An index on `dim_provider.network_status` / `dim_member.state`.**
Same low-cardinality reasoning — these are attribute-level filters on small-to-medium dimension tables (3,000 and 50,000 rows respectively in this test; 15,000 and 500,000 in production), where a full scan of the dimension table is already fast. Indexing here would add write overhead to SCD2 dimension loads for negligible read benefit.

---

## 2. Execution Plan Analysis

### Query #1 — Top 20 providers by total paid amount, with YoY comparison

```
 Limit  (cost=38350.68..38350.73 rows=20 width=156) (actual time=886.123..886.340 rows=20 loops=1)
   CTE provider_yearly
     ->  Finalize GroupAggregate  (cost=20413.74..31247.37 rows=33011 width=74) (actual time=670.669..858.924 rows=12000 loops=1)
           Group Key: dp.provider_id, dd.year
           ->  Gather Merge  (cost=20413.74..30009.46 rows=66022 width=74) (actual time=670.624..833.044 rows=35910 loops=1)
                 Workers Planned: 2
                 Workers Launched: 2
                 ->  Partial GroupAggregate  (cost=19413.72..21388.86 rows=33011 width=74) (actual time=654.034..710.027 rows=11970 loops=3)
                       Group Key: dp.provider_id, dd.year
                       ->  Sort  (cost=19413.72..19726.22 rows=125000 width=29) (actual time=654.010..678.611 rows=100000 loops=3)
                             Sort Key: dp.provider_id, dd.year
                             Sort Method: external merge  Disk: 4168kB
                             Worker 0:  Sort Method: external merge  Disk: 4216kB
                             Worker 1:  Sort Method: external merge  Disk: 3968kB
                             ->  Hash Join  (cost=226.93..5838.99 rows=125000 width=29) (actual time=10.589..258.037 rows=100000 loops=3)
                                   Hash Cond: (fc.date_sk = dd.date_sk)
                                   ->  Hash Join  (cost=102.52..5386.11 rows=125000 width=31) (actual time=5.730..185.540 rows=100000 loops=3)
                                         Hash Cond: (fc.provider_sk = dp.provider_sk)
                                         ->  Parallel Seq Scan on fact_claim fc  (cost=0.00..4955.00 rows=125000 width=14) (actual time=0.011..35.404 rows=100000 loops=3)
                                         ->  Hash  (cost=65.01..65.01 rows=3001 width=25) (actual time=5.665..5.667 rows=3001 loops=3)
                                               Buckets: 4096  Batches: 1  Memory Usage: 208kB
                                               ->  Seq Scan on dim_provider dp  (cost=0.00..65.01 rows=3001 width=25) (actual time=0.023..4.842 rows=3001 loops=3)
                                   ->  Hash  (cost=74.18..74.18 rows=4018 width=6) (actual time=4.795..4.796 rows=4018 loops=3)
                                         Buckets: 4096  Batches: 1  Memory Usage: 189kB
                                         ->  Seq Scan on dim_date dd  (cost=0.00..74.18 rows=4018 width=6) (actual time=0.022..1.107 rows=4018 loops=3)
   InitPlan 2 (returns $2)
     ->  Aggregate  (cost=742.75..742.76 rows=1 width=2) (actual time=7.867..7.868 rows=1 loops=1)
           ->  CTE Scan on provider_yearly provider_yearly_1  (cost=0.00..660.22 rows=33011 width=2) (actual time=0.001..0.866 rows=12000 loops=1)
   ->  Sort  (cost=6360.55..6360.96 rows=165 width=156) (actual time=886.121..886.122 rows=20 loops=1)
         Sort Key: provider_yoy.total_paid_amount DESC
         Sort Method: top-N heapsort  Memory: 27kB
         ->  Subquery Scan on provider_yoy  (cost=5283.30..6356.16 rows=165 width=156) (actual time=876.614..885.051 rows=3000 loops=1)
               Filter: (provider_yoy.year = $2)
               Rows Removed by Filter: 9000
               ->  WindowAgg  (cost=5283.30..5943.52 rows=33011 width=156) (actual time=868.729..876.535 rows=12000 loops=1)
                     ->  Sort  (cost=5283.30..5365.83 rows=33011 width=124) (actual time=868.716..869.431 rows=12000 loops=1)
                           Sort Key: provider_yearly.provider_id, provider_yearly.year
                           Sort Method: quicksort  Memory: 1103kB
                           ->  CTE Scan on provider_yearly  (cost=0.00..660.22 rows=33011 width=124) (actual time=670.674..864.806 rows=12000 loops=1)
 Planning Time: 2.232 ms
 Execution Time: 890.114 ms
```

**Plain English interpretation:** Postgres scans all of `fact_claim` in parallel across 2 worker processes, joining each claim to its provider and date, then sorts and groups those 300,000 rows down to 12,000 provider/year totals (3,000 providers × 4 years). That grouped result is scanned twice more — once to find the most recent year, and once to compute the year-over-year `LAG()` comparison — before the final sort picks the top 20 by paid amount. The whole thing runs in about 890ms, which is fast for a report replacing a 6-hour OLTP query, but the plan isn't as tight as it could be.

**Most expensive node:** the **`Sort` beneath each `Partial GroupAggregate`** (one per parallel worker), which took roughly 654–679ms and explicitly spilled to disk (`Sort Method: external merge Disk: ~4MB`). This happens because each worker has to fully sort its share of 100,000 joined rows by `provider_id, year` before it can group them, and the default `work_mem` wasn't large enough to do that sort in memory. This single node accounts for the large majority of the query's total runtime. Increasing `work_mem` for this session/workload (or adding a composite index on `(provider_sk, date_sk)` to let Postgres avoid a full re-sort) would be the direct fix if this report is run frequently.

---

### Query #6 — Monthly claims volume trend with 3-month moving average

```
 WindowAgg  (cost=6330.67..6367.08 rows=132 width=44) (actual time=129.651..134.571 rows=42 loops=1)
   ->  Finalize GroupAggregate  (cost=6330.67..6364.77 rows=132 width=12) (actual time=129.632..134.520 rows=42 loops=1)
         Group Key: dd.year, dd.month_number
         ->  Gather Merge  (cost=6330.67..6361.47 rows=264 width=12) (actual time=129.625..134.500 rows=78 loops=1)
               Workers Planned: 2
               Workers Launched: 2
               ->  Sort  (cost=5330.64..5330.97 rows=132 width=12) (actual time=121.675..121.680 rows=26 loops=3)
                     Sort Key: dd.year, dd.month_number
                     Sort Method: quicksort  Memory: 26kB
                     ->  Partial HashAggregate  (cost=5324.67..5325.99 rows=132 width=12) (actual time=121.634..121.642 rows=26 loops=3)
                           Group Key: dd.year, dd.month_number
                           Batches: 1  Memory Usage: 40kB
                           ->  Hash Join  (cost=124.70..4387.17 rows=125000 width=4) (actual time=7.190..80.055 rows=100000 loops=3)
                                 Hash Cond: (fc.date_sk = dd.date_sk)
                                 ->  Parallel Index Only Scan using idx_claims_date on fact_claim fc  (cost=0.30..3934.30 rows=125000 width=4) (actual time=0.037..25.187 rows=100000 loops=3)
                                       Heap Fetches: 0
                                 ->  Hash  (cost=74.18..74.18 rows=4018 width=8) (actual time=7.098..7.099 rows=4018 loops=3)
                                       Buckets: 4096  Batches: 1  Memory Usage: 189kB
                                       ->  Seq Scan on dim_date dd  (cost=0.00..74.18 rows=4018 width=8) (actual time=0.011..3.551 rows=4018 loops=3)
 Planning Time: 0.916 ms
 Execution Time: 134.928 ms
```

**Plain English interpretation:** this query is noticeably lighter than Q1. Because the query only ever needs `fact_claim.date_sk` (not any other column from that table), Postgres satisfies it with an **Index Only Scan** on `idx_claims_date` — it never has to open the actual `fact_claim` table rows at all (`Heap Fetches: 0`). Two parallel workers each hash-join their share of claims to `dim_date`, partially aggregate into year/month counts, and the leader process merges those partial results before computing the final 3-month moving average with the window function. Total runtime is about 135ms — roughly 6.5x faster than Q1, mostly because there's no expensive disk-spilled sort here; the grouping only produces 42 final rows (3.5 years of months), so it comfortably fits in memory as a hash aggregate instead.

**Most expensive node:** the **`Hash Join`** joining `fact_claim` to `dim_date`, which accounts for the majority of the per-worker elapsed time (about 73ms of each worker's ~80ms). This is expected and appropriate — it's doing the core work of the query (matching all 300,000 claims to their calendar month) — and it's already using the cheapest available access path (an index-only scan feeding the join), so there isn't an obvious further optimization here without changing the query's fundamental shape.

---

## 3. Materialized View

### Before (querying base tables directly)

See Q6's plan above: **Execution Time: 134.928 ms**, requiring a full parallel scan-and-join of `fact_claim` against `dim_date` every single time the monthly trend report is requested.

### After (materialized view)

```sql
CREATE MATERIALIZED VIEW mv_monthly_claims_summary AS
SELECT
    dd.year,
    dd.month_number,
    COUNT(*) AS claim_count,
    AVG(COUNT(*)) OVER (
        ORDER BY dd.year, dd.month_number
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS moving_avg_3mo
FROM fact_claim fc
JOIN dim_date dd ON dd.date_sk = fc.date_sk
GROUP BY dd.year, dd.month_number;

-- Required for REFRESH ... CONCURRENTLY (needs a way to diff old vs new rows without locking)
CREATE UNIQUE INDEX ON mv_monthly_claims_summary (year, month_number);
```

```
EXPLAIN ANALYZE
SELECT * FROM mv_monthly_claims_summary ORDER BY year, month_number;

 Sort  (cost=2.55..2.66 rows=42 width=44) (actual time=0.052..0.055 rows=42 loops=1)
   Sort Key: year, month_number
   Sort Method: quicksort  Memory: 27kB
   ->  Seq Scan on mv_monthly_claims_summary  (cost=0.00..1.42 rows=42 width=44) (actual time=0.008..0.012 rows=42 loops=1)
 Planning Time: 0.351 ms
 Execution Time: 0.081 ms
```

**Result: 134.928 ms → 0.081 ms — roughly 1,600x faster.** The materialized view stores the pre-computed 42-row result physically, so reading it is a trivial sequential scan of a tiny table, instead of re-scanning and re-joining 300,000+ claim rows every time a dashboard loads.

### Refresh schedule recommendation

**Recommendation: nightly refresh, run immediately after the nightly incremental `fact_claim` load completes (Deliverable 3's watermark-based ETL job), using `REFRESH MATERIALIZED VIEW CONCURRENTLY`.**

Justification:
- The underlying data (`fact_claim`) is itself only updated once per incremental load cycle (nightly, per Deliverable 3's design) — refreshing the materialized view more often than the source data actually changes would be pure wasted work with zero freshness benefit.
- `CONCURRENTLY` (enabled by the unique index above) avoids locking the view during refresh, so the Member Utilization Dashboard and Provider Performance Report can keep reading the *previous* night's snapshot uninterrupted while the new one builds in the background — directly addressing the "dashboard crashes the OLTP database twice a week under query load" pain point, since reads against the materialized view never compete with the refresh itself.
- A monthly trend report does not need intraday freshness — nobody making a staffing or capacity-planning decision needs data more current than "as of last night's load." Nightly cadence matches the actual decision-making timescale this report serves.