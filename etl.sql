-- ============================================================
-- Deliverable 3: ETL SQL
-- MedInsure Healthcare Claims Data Warehouse
-- ============================================================
-- Sections (filled in incrementally):
--   1. dim_date population (GENERATE_SERIES, 2020-2030)
--   2. dim_member — SCD Type 2 close-then-insert + verification query
--   3. dim_provider — SCD Type 2 close-then-insert + verification query
--   4. dim_diagnosis / dim_procedure — Type 1 UPSERT
--   5. fact_claim — incremental load, high-water mark, SCD-aware key lookups,
--      dead-letter handling
--   6. fact_claim_line — dependent load after fact_claim
-- ============================================================


-- ============================================================
-- 1. dim_date population
-- ============================================================

INSERT INTO dim_date (
    date_sk, full_date, day_of_week, day_of_month,
    month_name, month_number, quarter, year, is_weekend
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INT       AS date_sk,
    d                                  AS full_date,
    TO_CHAR(d, 'Day')                  AS day_of_week,
    EXTRACT(DAY FROM d)::SMALLINT      AS day_of_month,
    TO_CHAR(d, 'Month')                AS month_name,
    EXTRACT(MONTH FROM d)::SMALLINT    AS month_number,
    EXTRACT(QUARTER FROM d)::SMALLINT  AS quarter,
    EXTRACT(YEAR FROM d)::SMALLINT     AS year,
    (EXTRACT(ISODOW FROM d) IN (6, 7)) AS is_weekend
FROM GENERATE_SERIES(
        '2020-01-01'::DATE,
        '2030-12-31'::DATE,
        INTERVAL '1 day'
     ) AS d;


-- ============================================================
-- 2. dim_member (SCD Type 2)
-- ============================================================
-- (to be filled in)


-- ============================================================
-- 3. dim_provider (SCD Type 2)
-- ============================================================
-- (to be filled in)


-- ============================================================
-- 4. dim_diagnosis / dim_procedure (Type 1 UPSERT)
-- ============================================================
-- (to be filled in)


-- ============================================================
-- 5. fact_claim (incremental load)
-- ============================================================
-- (to be filled in)


-- ============================================================
-- 6. fact_claim_line (dependent load)
-- ============================================================
-- (to be filled in)