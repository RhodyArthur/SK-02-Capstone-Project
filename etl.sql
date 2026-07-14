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
-- Staging table assumed:
--   stg_member(member_id, name, date_of_birth, gender, plan_id, state, zip_code)
-- Tracked attributes: plan_id, state, zip_code
 
BEGIN;
 
-- Step 1: Close (expire) current rows whose tracked attributes changed
UPDATE dim_member dm
SET effective_end = CURRENT_DATE - 1,
    is_current     = FALSE
FROM stg_member sm
WHERE dm.member_id = sm.member_id
  AND dm.is_current = TRUE
  AND (
        dm.plan_id  IS DISTINCT FROM sm.plan_id
     OR dm.state    IS DISTINCT FROM sm.state
     OR dm.zip_code IS DISTINCT FROM sm.zip_code
  );
 
-- Step 2: Insert new current rows — brand-new members, and members just expired above
INSERT INTO dim_member (
    member_id, name, date_of_birth, gender,
    plan_id, state, zip_code,
    effective_start, effective_end, is_current
)
SELECT
    sm.member_id, sm.name, sm.date_of_birth, sm.gender,
    sm.plan_id, sm.state, sm.zip_code,
    CURRENT_DATE, '9999-12-31', TRUE
FROM stg_member sm
WHERE NOT EXISTS (
    -- brand-new member: no row for them exists at all
    SELECT 1 FROM dim_member dm
    WHERE dm.member_id = sm.member_id
)
OR EXISTS (
    -- existing member we just expired above: re-insert their new current version
    SELECT 1 FROM dim_member dm
    WHERE dm.member_id = sm.member_id
      AND dm.is_current = FALSE
      AND dm.effective_end = CURRENT_DATE - 1
);
 
COMMIT;
 
-- Verification: confirm no member has more than one is_current = TRUE row.
-- A healthy load returns zero rows.
SELECT member_id, COUNT(*) AS current_row_count
FROM dim_member
WHERE is_current = TRUE
GROUP BY member_id
HAVING COUNT(*) > 1;


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