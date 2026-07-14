# Deliverable 1: Dimensional Model Design
## MedInsure Healthcare Claims Data Warehouse

---

## 1. Grain Declarations

| Fact Table | Grain |
|---|---|
| `fact_claim` | One row per claim, submitted for one member visit/encounter (header level). |
| `fact_claim_line` | One row per service line, within one claim. |

Both grains are declared at the most atomic level available in the source system. `fact_claim_line` is a strict child of `fact_claim` — one claim (2M rows) explodes into an average of ~3.75 service lines each (7.5M rows), matching the source `claim_lines` table exactly.

---

## 2. Fact Table Type Classification

| Fact Table | Type | Justification |
|---|---|---|
| `fact_claim` | **Transaction** | Each claim represents a single, discrete event — submitted once at the time of a visit/encounter. It is not a recurring state snapshot, and it is not a multi-stage process collapsed into one evolving row. |
| `fact_claim_line` | **Transaction** | Each service line is written once, at claim submission time, and is never revisited or updated through subsequent stages. The 1-to-many relationship with `fact_claim` (multiple lines per claim) is a grain decision, not evidence of an accumulating process. |

---

## 3. Dimension List — SCD Type Decisions

| Dimension | Source Table(s) | SCD Type | Justification |
|---|---|---|---|
| `dim_member` | `members`, `member_plan_history` | **Type 2** | Compliance requires 3 years of member plan-change history for regulatory audits, but the OLTP system only retains 18 months. `member_plan_history` is not a separate dimension table — it feeds the versioned rows inside `dim_member` (`effective_date` / `expiration_date` / `is_current`), preserving history the source system cannot. |
| `dim_provider` | `providers`, `provider_network_history` | **Type 2** | Network status (in-network / out-of-network) changes over time, and claims must reflect the provider's status **at the time the claim was paid**, not their current status — otherwise the Provider Performance Report (used for monthly contract reviews) would misrepresent historical network compliance. `provider_network_history` feeds versioned rows inside `dim_provider`, same pattern as member plan history. |
| `dim_diagnosis` | `diagnosis_codes` | **Type 1** | ICD-10 codes are a stable, standardized reference list. Corrections to descriptions/categories are rare and can be safely overwritten with no need for historical tracking. |
| `dim_procedure` | `procedure_codes` | **Type 1** | CPT codes are a stable, standardized reference list — same reasoning as diagnosis codes. |
| `dim_plan` | `plan_types` | **Type 1** | Small (8-row), static reference list (HMO/PPO/EPO/HDHF). No historical tracking required. |
| `dim_date` | *(generated)* | **Type 1** | Day-level grain. Day-level detail can always be rolled up to month/quarter/year for reporting (e.g., "spend per diagnosis category last quarter"), but a coarser dimension could never be drilled back down to a specific day if compliance or audit needs arise later. Follows the general rule: always pick the most atomic grain available for the time dimension. |

---

## 4. Conformed Dimensions

A conformed dimension is built once, with a stable structure and meaning, so that multiple fact tables can join to it and produce consistent, comparable results.

The following dimensions are identified as conformed, reusable by a future `fact_pharmacy` table:

- **`dim_member`** — A pharmacy claim (prescription fill) is still tied to a specific insured member; "total spend per member" must mean the same thing whether it comes from medical or pharmacy claims.
- **`dim_diagnosis`** — Prescriptions are frequently written against a specific diagnosis (e.g., insulin for a diabetes diagnosis). Sharing `dim_diagnosis` allows consistent diagnosis-category analysis across both medical and pharmacy spend.
- **`dim_plan`** *(secondary candidate)* — A member's plan type applies uniformly regardless of whether they are filing a medical or pharmacy claim.

---

## 5. Degenerate Dimensions

| Degenerate Attribute | Lives On | Justification |
|---|---|---|
| `claim_number` | `fact_claim`, `fact_claim_line` | Pure identifier tying claim (and its child service lines) together. Nothing further describes the claim number itself — no separate `dim_claim` table needed. |
| `line_number` | `fact_claim_line` | Distinguishes individual service lines within the same claim (mirrors the `order_number` + `line_number` pattern from retail line-item grain). Combined with `claim_number`, uniquely identifies each row at `fact_claim_line`'s grain. |

---

## 6. Summary — Dimension SCD Type Quick Reference

| Type 1 (Overwrite) | Type 2 (Track History) |
|---|---|
| `dim_diagnosis` | `dim_member` |
| `dim_procedure` | `dim_provider` |
| `dim_plan` | |
| `dim_date` | |