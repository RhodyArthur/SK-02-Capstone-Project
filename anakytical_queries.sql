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
-- Q3. Member utilization rate by plan type and month (claims per 1,000 members)
-- ============================================================
-- (to be filled in)


-- ============================================================
-- Q4. Denied claims analysis: denial rate by provider specialty and claim type
-- ============================================================
-- (to be filled in)


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