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
-- Staging table assumed:
--   stg_provider(provider_id, provider_name, specialty, network_status)
-- Tracked attributes: network_status, specialty
 
BEGIN;
 
-- Step 1: Close (expire) current rows whose tracked attributes changed
UPDATE dim_provider dp
SET effective_end = CURRENT_DATE - 1,
    is_current     = FALSE
FROM stg_provider sp
WHERE dp.provider_id = sp.provider_id
  AND dp.is_current = TRUE
  AND (
        dp.network_status IS DISTINCT FROM sp.network_status
     OR dp.specialty       IS DISTINCT FROM sp.specialty
  );
 
-- Step 2: Insert new current rows — brand-new providers, and providers just expired above
-- NOTE: effective_start has no table DEFAULT (unlike effective_end/is_current),
-- so it must always be supplied explicitly here.
INSERT INTO dim_provider (
    provider_id, provider_name, specialty, network_status,
    effective_start, effective_end, is_current
)
SELECT
    sp.provider_id, sp.provider_name, sp.specialty, sp.network_status,
    CURRENT_DATE, '9999-12-31', TRUE
FROM stg_provider sp
WHERE NOT EXISTS (
    SELECT 1 FROM dim_provider dp WHERE dp.provider_id = sp.provider_id
)
OR EXISTS (
    SELECT 1 FROM dim_provider dp
    WHERE dp.provider_id = sp.provider_id
      AND dp.is_current = FALSE
      AND dp.effective_end = CURRENT_DATE - 1
);
 
COMMIT;
 
-- Verification: confirm no provider has more than one is_current = TRUE row.
-- A healthy load returns zero rows.
SELECT provider_id, COUNT(*) AS current_row_count
FROM dim_provider
WHERE is_current = TRUE
GROUP BY provider_id
HAVING COUNT(*) > 1;


-- ============================================================
-- 4. dim_diagnosis / dim_procedure (Type 1 UPSERT)
-- ============================================================
-- Staging tables assumed:
--   stg_diagnosis(icd10_code, description, category)
--   stg_procedure(cpt_code, description, category)
 
INSERT INTO dim_diagnosis (icd10_code, description, category)
SELECT icd10_code, description, category
FROM stg_diagnosis
ON CONFLICT (icd10_code)
DO UPDATE SET
    description = EXCLUDED.description,
    category    = EXCLUDED.category;
 
INSERT INTO dim_procedure (cpt_code, description, category)
SELECT cpt_code, description, category
FROM stg_procedure
ON CONFLICT (cpt_code)
DO UPDATE SET
    description = EXCLUDED.description,
    category    = EXCLUDED.category;
 


-- ============================================================
-- 5. fact_claim (incremental load)
-- ============================================================
-- Staging table assumed:
--   stg_claim(claim_number, member_id, provider_id, icd10_code, plan_id,
--             service_date, processed_date, billed_amount, paid_amount, allowed_amount)
--
-- Dead-letter table (captures rows that fail SCD-aware dimension lookups,
-- so the pipeline never silently drops data and never hard-fails on bad rows):
CREATE TABLE dead_letter_claims (
    claim_number   VARCHAR(20),           -- nullable: dead-letter must never itself reject data
    member_id      VARCHAR(20),
    provider_id    VARCHAR(20),
    reason         TEXT        NOT NULL,  -- always required: we always know why we're logging this
    failed_time    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
);
 
BEGIN;
 
-- Step 1: Log claims whose member cannot be resolved for their service_date
INSERT INTO dead_letter_claims (claim_number, member_id, provider_id, reason)
SELECT
    sc.claim_number,
    sc.member_id,
    sc.provider_id,
    'Member not found in dim_member for service_date'
FROM stg_claim sc
WHERE sc.processed_date > (SELECT last_loaded_timestamp FROM etl_control WHERE table_name = 'fact_claim')
  AND NOT EXISTS (
        SELECT 1 FROM dim_member dm
        WHERE dm.member_id = sc.member_id
          AND sc.service_date BETWEEN dm.effective_start AND dm.effective_end
      );
 
-- Step 2: Log claims whose provider cannot be resolved for their service_date
INSERT INTO dead_letter_claims (claim_number, member_id, provider_id, reason)
SELECT
    sc.claim_number,
    sc.member_id,
    sc.provider_id,
    'Provider not found in dim_provider for service_date'
FROM stg_claim sc
WHERE sc.processed_date > (SELECT last_loaded_timestamp FROM etl_control WHERE table_name = 'fact_claim')
  AND NOT EXISTS (
        SELECT 1 FROM dim_provider dp
        WHERE dp.provider_id = sc.provider_id
          AND sc.service_date BETWEEN dp.effective_start AND dp.effective_end
      );
 
-- Step 3: Load fact_claim — only rows that successfully resolve on every dimension.
-- Claims that failed the member/provider lookups above are naturally excluded here
-- via the INNER JOINs (they were already captured in the dead-letter table instead).
INSERT INTO fact_claim (
    claim_number, billed_amount, paid_amount, allowed_amount,
    member_sk, provider_sk, diagnosis_sk, plan_sk, date_sk
)
SELECT
    sc.claim_number,
    sc.billed_amount,
    sc.paid_amount,
    sc.allowed_amount,
    dm.member_sk,
    dp.provider_sk,
    dg.diagnosis_sk,
    pl.plan_sk,
    dd.date_sk
FROM stg_claim sc
JOIN dim_member dm
  ON dm.member_id = sc.member_id
 AND sc.service_date BETWEEN dm.effective_start AND dm.effective_end
JOIN dim_provider dp
  ON dp.provider_id = sc.provider_id
 AND sc.service_date BETWEEN dp.effective_start AND dp.effective_end
JOIN dim_diagnosis dg
  ON dg.icd10_code = sc.icd10_code
JOIN dim_plan pl
  ON pl.plan_id = sc.plan_id
JOIN dim_date dd
  ON dd.date_sk = TO_CHAR(sc.service_date, 'YYYYMMDD')::INT
WHERE sc.processed_date > (SELECT last_loaded_timestamp FROM etl_control WHERE table_name = 'fact_claim');
 
-- Step 4: Advance the watermark to the max processed_date actually loaded in this batch

UPDATE etl_control
SET last_loaded_timestamp = (
    SELECT MAX(processed_date)
    FROM stg_claim
    WHERE processed_date > (
        SELECT last_loaded_timestamp FROM etl_control WHERE table_name = 'fact_claim'
    )
)
WHERE table_name = 'fact_claim';
 
COMMIT;
 
 
-- ============================================================
-- 6. fact_claim_line (dependent load)
-- ============================================================
-- Staging table assumed:
--   stg_claim_line(claim_number, line_number, cpt_code, units,
--                  line_billed_amount, line_paid_amount)
 
INSERT INTO fact_claim_line (
    claim_number, line_number, procedure_sk,
    units, line_billed_amount, line_paid_amount
)
SELECT
    scl.claim_number,
    scl.line_number,
    dp.procedure_sk,
    scl.units,
    scl.line_billed_amount,
    scl.line_paid_amount
FROM stg_claim_line scl
JOIN fact_claim fc      ON scl.claim_number = fc.claim_number
JOIN dim_procedure dp   ON scl.cpt_code = dp.cpt_code;