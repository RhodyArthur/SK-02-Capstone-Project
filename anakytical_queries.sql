-- ============================================================
-- Deliverable 4: Analytical Queries
-- MedInsure Healthcare Claims Data Warehouse
-- ============================================================
-- All queries run against the warehouse schema (fact_claim, fact_claim_line,
-- and dimension tables) — not the source OLTP tables.
-- ============================================================


-- ============================================================
-- Q1. Top 20 providers by total paid amount, with YoY comparison
-- ============================================================
-- Business question: "Which 20 providers generated the most paid claims
-- spend in the most recent year, and how does that compare to the prior year?"
-- Answers the Provider Performance Report requirement directly.
-- The warehouse makes this possible because fact_claim + dim_provider (SCD2)
-- let us aggregate paid amounts per provider per year in seconds, instead of
-- the 6-hour OLTP query the Claims Analytics team currently runs.
-- NOTE: grouped by provider_id (not provider_sk) to merge a provider's SCD2
-- versions into one true total — grouping by provider_sk alone would silently
-- fragment one provider's spend across multiple rows and could knock a truly
-- top-ranked provider out of the Top 20.

WITH provider_yearly AS (
    SELECT
        dp.provider_id,
        MAX(dp.provider_name) AS provider_name,
        dd.year,
        SUM(fc.paid_amount) AS total_paid_amount
    FROM fact_claim fc
    JOIN dim_provider dp ON dp.provider_sk = fc.provider_sk
    JOIN dim_date dd     ON dd.date_sk = fc.date_sk
    GROUP BY dp.provider_id, dd.year
),
provider_yoy AS (
    SELECT
        provider_id,
        provider_name,
        year,
        total_paid_amount,
        LAG(total_paid_amount) OVER (PARTITION BY provider_id ORDER BY year) AS prior_year_paid
    FROM provider_yearly
)
SELECT *
FROM provider_yoy
WHERE year = (SELECT MAX(year) FROM provider_yearly)
ORDER BY total_paid_amount DESC
LIMIT 20;


-- ============================================================
-- Q2. Claims paid by ICD-10 diagnosis category, ranked by spend
-- ============================================================
-- Business question: "Which diagnosis categories drive the most claims
-- spend, ranked highest to lowest?" Directly answers Finance's "what did we
-- pay per diagnosis category last quarter" question, which currently takes
-- 3 days of manual work against the OLTP system.
-- The warehouse makes this possible because dim_diagnosis pre-aggregates
-- ICD-10 codes into their category hierarchy, so a single GROUP BY replaces
-- what would otherwise require manual ICD-10 category lookups against a
-- 12,000-row reference table on every run.

WITH claims_paid AS (
    SELECT dg.category, SUM(fc.paid_amount) AS total_spend
    FROM fact_claim fc
    JOIN dim_diagnosis dg ON dg.diagnosis_sk = fc.diagnosis_sk
    GROUP BY dg.category
),
ranked_spend AS (
    SELECT
        category,
        total_spend,
        RANK() OVER (ORDER BY total_spend DESC) AS spend_rank
    FROM claims_paid
)
SELECT *
FROM ranked_spend
ORDER BY spend_rank;


-- ============================================================
-- Q3. Member utilization rate by plan type and month (claims per 1,000 members)
-- ============================================================
-- Business question: "How does claims utilization vary by plan type over
-- time, normalized per 1,000 members?" Powers the Member Utilization
-- Dashboard, which currently crashes the OLTP database twice a week under
-- query load.
-- The warehouse makes this possible because dim_plan and dim_date let this
-- aggregate across millions of fact_claim rows without touching the live
-- transactional system at all.
-- NOTE: distinct member counts use dim_member.member_id, not member_sk —
-- since dim_member is SCD Type 2, the same real member could carry multiple
-- member_sk values if their record versioned mid-month; counting by
-- member_sk risks treating one person as two "distinct members."
 
WITH claims_with_count AS (
    SELECT
        pl.plan_type,
        dd.year,
        dd.month_number,
        COUNT(*) OVER (PARTITION BY pl.plan_type, dd.year, dd.month_number) AS claims_count
    FROM fact_claim fc
    JOIN dim_plan pl ON pl.plan_sk = fc.plan_sk
    JOIN dim_date dd ON dd.date_sk = fc.date_sk
),
distinct_member_count AS (
    SELECT
        pl.plan_type,
        dd.year,
        dd.month_number,
        COUNT(DISTINCT dm.member_id) AS distinct_members
    FROM fact_claim fc
    JOIN dim_plan pl   ON pl.plan_sk = fc.plan_sk
    JOIN dim_date dd   ON dd.date_sk = fc.date_sk
    JOIN dim_member dm ON dm.member_sk = fc.member_sk
    GROUP BY pl.plan_type, dd.year, dd.month_number
)
SELECT DISTINCT
    cc.plan_type,
    cc.year,
    cc.month_number,
    cc.claims_count,
    mc.distinct_members,
    ROUND((cc.claims_count::NUMERIC / mc.distinct_members) * 1000, 2) AS claims_per_1000_members
FROM claims_with_count cc
JOIN distinct_member_count mc
  ON cc.plan_type = mc.plan_type
 AND cc.year = mc.year
 AND cc.month_number = mc.month_number
ORDER BY cc.year, cc.month_number, cc.plan_type;


-- ============================================================
-- Q4. Denied claims analysis: denial rate by provider specialty and claim type
-- ============================================================
-- Business question: "Which provider specialties and claim types have the
-- highest denial rates?" Helps Claims Analytics identify problem areas for
-- contract negotiation and process improvement.
-- The warehouse makes this possible because claim_status and claim_type are
-- captured once per claim on fact_claim, so denial rate can be computed with
-- a single GROUP BY instead of joining back to OLTP transaction logs.
-- NOTE: grouping by specialty (the attribute itself, not provider_sk or
-- provider_id) is safe here even though dim_provider is SCD2 — multiple
-- providers or SCD2 versions sharing the same specialty value correctly
-- combine, since specialty is the analysis dimension, not an identifier
-- being fragmented.
 
WITH claim_counts AS (
    SELECT
        dp.specialty,
        fc.claim_type,
        COUNT(*) AS total_claims,
        COUNT(*) FILTER (WHERE fc.claim_status = 'Denied') AS denied_claims
    FROM fact_claim fc
    JOIN dim_provider dp ON dp.provider_sk = fc.provider_sk
    GROUP BY dp.specialty, fc.claim_type
)
SELECT
    specialty,
    claim_type,
    total_claims,
    denied_claims,
    ROUND((denied_claims::NUMERIC / total_claims), 2) AS denial_rate
FROM claim_counts
ORDER BY denial_rate DESC;


-- ============================================================
-- Q5. Out-of-network cost comparison: paid amount per member per year
-- ============================================================
-- Business question: "How much more does a member pay when they see an
-- out-of-network provider, compared to in-network, per year?" Supports
-- member education and network adequacy analysis.
-- The warehouse makes this possible because fact_claim.provider_sk was
-- already resolved at ETL load time using a date-range join against the
-- provider's SCD2 network_status history — so this query gets the
-- historically-correct in/out-of-network status "for free," just by joining
-- on provider_sk directly, with no need to redo any date-range logic here.
 
SELECT
    dm.member_id,
    dd.year,
    SUM(CASE WHEN dp.network_status = 'In-Network'     THEN fc.paid_amount ELSE 0 END) AS in_network_paid,
    SUM(CASE WHEN dp.network_status = 'Out-of-Network' THEN fc.paid_amount ELSE 0 END) AS out_of_network_paid
FROM fact_claim fc
JOIN dim_provider dp ON dp.provider_sk = fc.provider_sk
JOIN dim_member dm   ON dm.member_sk = fc.member_sk
JOIN dim_date dd     ON dd.date_sk = fc.date_sk
GROUP BY dm.member_id, dd.year
ORDER BY dm.member_id, dd.year;


-- ============================================================
-- Q6. Monthly claims volume trend with 3-month moving average
-- ============================================================
-- Business question: "Is claims volume trending up, down, or steady over
-- time, smoothed to reduce month-to-month noise?" Supports capacity
-- planning and staffing decisions for the Claims Analytics team.
-- The warehouse makes this possible because dim_date provides a clean,
-- pre-built year/month grouping key, so trend analysis across millions of
-- claims requires only a GROUP BY + window function, not custom date-bucket
-- logic recomputed against the OLTP claims table every time.
 
WITH monthly_total_claims AS (
    SELECT
        dd.year,
        dd.month_number,
        COUNT(*) AS claim_count
    FROM fact_claim fc
    JOIN dim_date dd ON dd.date_sk = fc.date_sk
    GROUP BY dd.year, dd.month_number
)
SELECT
    year,
    month_number,
    claim_count,
    AVG(claim_count) OVER (
        ORDER BY year, month_number
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS moving_avg_3mo
FROM monthly_total_claims
ORDER BY year, month_number;


-- ============================================================
-- Q7. Member cohort analysis: claims frequency in first 12 months after enrollment
-- ============================================================
-- Business question: "Do members who enrolled in different years use claims
-- differently during their first 12 months?" Supports underwriting and
-- forecasting for new member cohorts.
-- The warehouse makes this possible because dim_member's SCD Type 2 history
-- lets us identify each member's true original enrollment date (the
-- earliest effective_start), even though the OLTP system only retains 18
-- months of plan history and could not answer this for older cohorts at all.
 
WITH member_enrollment AS (
    SELECT
        member_id,
        MIN(effective_start) AS enrollment_date
    FROM dim_member
    GROUP BY member_id
),
claims_in_first_year AS (
    SELECT
        dm.member_id,
        dd.full_date,
        fc.claim_number,
        me.enrollment_date
    FROM fact_claim fc
    JOIN dim_member dm        ON dm.member_sk = fc.member_sk
    JOIN member_enrollment me ON me.member_id = dm.member_id
    JOIN dim_date dd          ON dd.date_sk = fc.date_sk
    WHERE dd.full_date BETWEEN me.enrollment_date AND me.enrollment_date + INTERVAL '12 months'
),
member_claim_counts AS (
    SELECT
        member_id,
        enrollment_date,
        COUNT(claim_number) AS claims_in_first_12mo
    FROM claims_in_first_year
    GROUP BY member_id, enrollment_date
)
SELECT
    EXTRACT(YEAR FROM enrollment_date) AS cohort_year,
    AVG(claims_in_first_12mo) AS avg_claims_per_member,
    COUNT(member_id) AS cohort_size
FROM member_claim_counts
GROUP BY cohort_year
ORDER BY cohort_year;


-- ============================================================
-- Q8. Running cumulative paid amount by provider YTD, flagging $1M crossings
-- ============================================================
-- Business question: "As the year progresses, which providers are
-- approaching or have crossed $1M in paid claims?" Supports the monthly
-- contract review process referenced in the Provider Performance Report.
-- The warehouse makes this possible because fact_claim + dim_date give a
-- clean, indexed join path for a running total across millions of claims,
-- computed in one pass instead of repeated OLTP aggregation queries.
-- NOTE: PARTITION BY includes dd.year (not just provider_id) so the running
-- total genuinely resets each calendar year — a true "year-to-date" total,
-- not an all-time cumulative sum.
 
WITH provider_running_total AS (
    SELECT
        dp.provider_id,
        fc.claim_number,
        dd.full_date,
        dd.year,
        fc.paid_amount,
        SUM(fc.paid_amount) OVER (
            PARTITION BY dp.provider_id, dd.year
            ORDER BY dd.full_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_paid_ytd
    FROM fact_claim fc
    JOIN dim_provider dp ON dp.provider_sk = fc.provider_sk
    JOIN dim_date dd     ON dd.date_sk = fc.date_sk
)
SELECT
    provider_id,
    claim_number,
    full_date,
    year,
    paid_amount,
    cumulative_paid_ytd,
    CASE WHEN cumulative_paid_ytd >= 1000000 THEN TRUE ELSE FALSE END AS crossed_1m_flag
FROM provider_running_total
ORDER BY provider_id, year, full_date;
 