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
-- (to be filled in)


-- ============================================================
-- Q6. Monthly claims volume trend with 3-month moving average
-- ============================================================
-- (to be filled in)


-- ============================================================
-- Q7. Member cohort analysis: claims frequency in first 12 months after enrollment
-- ============================================================
-- (to be filled in)


-- ============================================================
-- Q8. Running cumulative paid amount by provider YTD, flagging $1M crossings
-- ============================================================
-- (to be filled in)