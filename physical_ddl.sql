-- ============================================================
-- Deliverable 2: Physical DDL
-- MedInsure Healthcare Claims Data Warehouse
-- ============================================================
-- Order of execution:
--   1. Dimension tables (Type 1 reference dims first, then SCD2 dims, then dim_date)
--   2. Placeholder "Not Applicable" rows for nullable-in-practice dimension FKs
--   3. Fact tables
--   4. Indexes on all fact table foreign keys
-- ============================================================


-- ============================================================
-- 1. DIMENSION TABLES
-- ============================================================

-- ---------- dim_plan (Type 1) ----------
CREATE TABLE dim_plan (
    plan_sk       SERIAL PRIMARY KEY,
    plan_id       VARCHAR(20)   NOT NULL,      -- natural key from plan_types source table
    plan_type     VARCHAR(10)   NOT NULL,      -- HMO, PPO, EPO, HDHP
    deductible    DECIMAL(10,2) NOT NULL,
    oop_max       DECIMAL(10,2) NOT NULL
);

-- ---------- dim_diagnosis (Type 1) ----------
CREATE TABLE dim_diagnosis (
    diagnosis_sk   SERIAL PRIMARY KEY,
    icd10_code     VARCHAR(10)  NOT NULL UNIQUE,  -- UNIQUE required for ON CONFLICT upserts
    description    TEXT         NOT NULL,   -- free text, no practical length cap needed
    category       VARCHAR(100) NOT NULL    -- ICD-10 category hierarchy grouping
);
 
-- ---------- dim_procedure (Type 1) ----------
CREATE TABLE dim_procedure (
    procedure_sk   SERIAL PRIMARY KEY,
    cpt_code       VARCHAR(5)   NOT NULL UNIQUE,  -- UNIQUE required for ON CONFLICT upserts
    description    TEXT         NOT NULL,
    category       VARCHAR(100) NOT NULL
);

-- ---------- dim_member (Type 2 — tracks plan/demographic changes) ----------
-- NOTE: plan_id here represents the member's *plan enrollment* as a tracked
-- demographic attribute of the member (their history of plan changes).
-- This is distinct from fact_claim.plan_sk -> dim_plan, which records which
-- plan actually applied to a specific claim. Both can coexist without
-- snowflaking: dim_member.plan_id is descriptive history, not a join path.
CREATE TABLE dim_member (
    member_sk         SERIAL PRIMARY KEY,
    member_id         VARCHAR(20)  NOT NULL,     -- natural key from members source table
    name              VARCHAR(100) NOT NULL,
    date_of_birth     DATE         NOT NULL,
    gender            VARCHAR(10)  NOT NULL,
    plan_id           VARCHAR(20)  NOT NULL,     -- tracked: member's enrolled plan (SCD2)
    state             VARCHAR(2)   NOT NULL,     -- tracked: member's home state (SCD2)
    zip_code          VARCHAR(10)  NOT NULL,     -- tracked: member's zip code (SCD2)
    effective_start   DATE         NOT NULL,
    effective_end     DATE         NOT NULL DEFAULT '9999-12-31',  -- placeholder for "still current"
    is_current        BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---------- dim_provider (Type 2 — tracks network status changes) ----------
CREATE TABLE dim_provider (
    provider_sk       SERIAL PRIMARY KEY,
    provider_id       VARCHAR(20)  NOT NULL,      -- natural key from providers source table
    provider_name     VARCHAR(100) NOT NULL,
    specialty         VARCHAR(100) NOT NULL,
    network_status    VARCHAR(20)  NOT NULL,      -- 'In-Network' / 'Out-of-Network'
    effective_start   DATE         NOT NULL,
    effective_end     DATE         NOT NULL DEFAULT '9999-12-31',
    is_current        BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---------- dim_date (Type 1 — day-level grain, calendar year only, no fiscal calendar) ----------
CREATE TABLE dim_date (
    date_sk         INT         PRIMARY KEY,      -- YYYYMMDD integer, e.g. 20260713 (assigned deliberately, NOT auto-generated)
    full_date       DATE        NOT NULL,
    day_of_week     VARCHAR(10) NOT NULL,          -- 'Monday', 'Tuesday', etc.
    day_of_month    SMALLINT    NOT NULL,          -- 1-31
    month_name      VARCHAR(15) NOT NULL,          -- 'January', for display
    month_number    SMALLINT    NOT NULL,          -- 1-12, for correct sorting/filtering
    quarter         SMALLINT    NOT NULL,          -- 1-4
    year            SMALLINT    NOT NULL,
    is_weekend      BOOLEAN     NOT NULL
);

-- Populate dim_date using GENERATE_SERIES (2020-01-01 through 2030-12-31)
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
-- 2. "NOT APPLICABLE" PLACEHOLDER ROWS
-- ============================================================
-- Inserted so that fact table FKs can always resolve to a real dimension row
-- (surrogate key -1), instead of allowing NULL, which would silently drop
-- rows from INNER JOIN-based reports.

INSERT INTO dim_diagnosis (diagnosis_sk, icd10_code, description, category)
VALUES (-1, 'N/A', 'Not Applicable', 'N/A');

INSERT INTO dim_provider (
    provider_sk, provider_id, provider_name, specialty,
    network_status, effective_start, effective_end, is_current
)
VALUES (-1, 'N/A', 'N/A', 'N/A', 'N/A', '1900-01-01', '9999-12-31', TRUE);


-- ============================================================
-- 3. FACT TABLES
-- ============================================================

-- ---------- fact_claim ----------
-- Grain: one row per claim, submitted for one member visit/encounter.
-- Type: Transaction fact table.
CREATE TABLE fact_claim (
    -- degenerate dimension serves as the primary key — no separate surrogate
    -- claim_id needed, since claim_number already uniquely identifies one claim
    claim_number      VARCHAR(20)   PRIMARY KEY,

    -- foreign keys to dimensions (all NOT NULL — every claim must resolve to
    -- something, even if that something is the -1 "Not Applicable" placeholder row)
    member_sk         INT           NOT NULL REFERENCES dim_member(member_sk),
    provider_sk       INT           NOT NULL REFERENCES dim_provider(provider_sk),
    diagnosis_sk      INT           NOT NULL REFERENCES dim_diagnosis(diagnosis_sk),
    plan_sk           INT           NOT NULL REFERENCES dim_plan(plan_sk),
    date_sk           INT           NOT NULL REFERENCES dim_date(date_sk),

    -- measures: NOT NULL, using 0 as a real value rather than NULL meaning "unknown"
    billed_amount     DECIMAL(10,2) NOT NULL,
    paid_amount       DECIMAL(10,2) NOT NULL,
    allowed_amount    DECIMAL(10,2) NOT NULL
);

-- ---------- fact_claim_line ----------
-- Grain: one row per service line, within one claim.
-- Type: Transaction fact table (multiple rows per claim reflect grain, not process stages).
CREATE TABLE fact_claim_line (
    -- composite primary key: claim_number ties back to the parent claim,
    -- line_number (degenerate dimension) distinguishes lines within that claim
    claim_number         VARCHAR(20)   NOT NULL REFERENCES fact_claim(claim_number),
    line_number          SMALLINT      NOT NULL,

    -- foreign key to the line-specific dimension
    procedure_sk         INT           NOT NULL REFERENCES dim_procedure(procedure_sk),

    -- measures
    units                SMALLINT      NOT NULL,
    line_billed_amount   DECIMAL(10,2) NOT NULL,
    line_paid_amount     DECIMAL(10,2) NOT NULL,

    PRIMARY KEY (claim_number, line_number)
);


-- ============================================================
-- 4. INDEXES ON FACT TABLE FOREIGN KEYS
-- ============================================================

-- fact_claim
CREATE INDEX idx_claims_date       ON fact_claim(date_sk);
CREATE INDEX idx_claims_member     ON fact_claim(member_sk);
CREATE INDEX idx_claims_provider   ON fact_claim(provider_sk);
CREATE INDEX idx_claims_diagnosis  ON fact_claim(diagnosis_sk);
CREATE INDEX idx_claims_plan       ON fact_claim(plan_sk);

-- fact_claim_line
CREATE INDEX idx_claims_claim_number ON fact_claim_line(claim_number);
CREATE INDEX idx_claims_procedure    ON fact_claim_line(procedure_sk);