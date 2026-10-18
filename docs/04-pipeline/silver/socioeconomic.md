# Socioeconomic Silver — Implementation and Evidence

Owner: Virna Pomendia
Last updated: 2026-10-15

## 1. Scope

Transform the validated Socioeconomic Bronze datasets into four separate Silver tables following Jemma's latest Socioeconomic Silver Guide v1.2.

| Silver table | Grain | Expected rows (reference) |
|---|---|---|
| `socioeconomic_poverty_silver` | Area × year | 322 |
| `socioeconomic_health_expenditure_share_silver` | Financing agent × year | 128 |
| `socioeconomic_health_expenditure_per_capita_silver` | Year | 8 |
| `socioeconomic_child_mortality_silver` | Characteristic group × characteristic × survey year | 60 |

Expected row counts are reference values, not execution results from this branch.

PSGC Silver belongs to the Geography domain.

## 2. Working Environment

- Repository: `FTW-Dengue-rous/philippine-public-health-platform`
- Development branch: `feature/socioeconomic-silver`
- Pull-request target: `dev`
- Local development: VSCode and PowerShell
- Target execution environment: Databricks

## 3. Files

- `config/sources_socioeconomic.yaml` — Bronze source configuration
- `src/03_silver/socioeconomic/socioeconomic_poverty_silver_pattern.sql` — locally tested Poverty transformation reference
- `src/05_quality/dq_utils.py` — shared data-quality framework
- `docs/evidence/socioeconomic_silver.md` — implementation decisions and test evidence

## 4. Implementation Decisions

### D01 — Reuse existing Bronze ingestion

**Decision:** Read from `public_health.bronze.socioeconomic_psa_poverty_bronze`.

**Reason:** This is the configured Bronze table used by current Socioeconomic ingestion. Older standalone Poverty Bronze SQL files follow a different structure and will not be reused.

### D02 — Preserve source meaning and lineage

**Decision:** Keep source sheet, row number, file version, load identifiers, statistical measures, and relevant source flags.

**Reason:** Silver must remain traceable to Bronze without losing information needed for auditing.

### D03 — Use a reviewed geographic mapping

**Decision:** Do not invent PSGC codes. The Poverty reference depends on a reviewed 108-row area map. Coordinate geographic definitions with the Geography domain.

**Reason:** Source areas include national, regional, provincial, and NCR-specific geographic units. Their coverage is not automatically comparable.

### D04 — Validate before publishing

**Decision:** Require successful input validation, numeric parsing, row classification, source reconciliation, and uniqueness checks before publishing the target Silver table.

**Reason:** Prevent incomplete or incorrect transformations from replacing valid Silver data.

### D05 — Reuse shared quality infrastructure

**Decision:** Integrate Silver QC with the existing `DQRun` framework and agreed S-series checks. Avoid changing shared quality tables without team approval.

**Reason:** Maintain consistent QC reporting across domains.

## 5. Current Status

- [x] Bronze ingestion previously completed
- [x] Bronze QC previously completed
- [x] Created Silver working branch
- [x] Reviewed Poverty Silver SQL reference
- [x] Confirmed current Bronze configuration and QC conventions
- [x] Created Socioeconomic Silver documentation
- [ ] Resolve reviewed Poverty area mapping
- [ ] Implement guarded Poverty Silver publishing
- [ ] Integrate Silver QC and lineage accounting
- [ ] Execute and validate in Databricks
- [ ] Implement remaining three Silver transformations
- [ ] Prepare PR targeting `dev`

## 6. Test Evidence

No Silver execution has been performed on this branch yet.

The provided Poverty SQL reference reports a previous local Spark test of 322 rows and zero failed validation gates. This result must be independently reproduced before claiming the implementation passes.

## 7. Open Dependencies

1. Reviewed Poverty area mapping and alignment with Geography.
2. Confirmation of the shared build-input and row-disposition contract, including target table schemas.
3. Databricks execution and Silver QC results.

## 8. Change Log

**2026-10-08 — Initial preparation**

- Created `feature/socioeconomic-silver` from `origin/dev`.
- Created the Socioeconomic Silver working directory.
- Saved the Poverty Silver SQL reference.
- Reviewed repository Silver and documentation conventions.
- Established implementation decisions and documented unresolved dependencies.
## 9. Health Expenditure Share Silver — Preparation (2026-10-08)

### Scope and files

- Source: `public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze`; source key `psa_health_expenditure_share_national_annual`.
- Config: `config/sources_socioeconomic.yaml` (PSA Statistical Yearbook 2025, Table 9.26).
- Working SQL: `src/03_silver/socioeconomic/socioeconomic_health_expenditure_share_silver.sql` (draft v3).
- Planned Silver table: `public_health.silver.socioeconomic_health_expenditure_share_silver`.
- Grain: one distinct financing-agent path per year (2016–2023). Candidate count: 16 agent rows × 8 years = 128 cells.

### Source evidence and row classification

A read-only Databricks SQL query of the Bronze source returned 18 physical rows at positions 5, 7–21, 23 and 25. The 16 substantive financing-agent rows are 5 and 7–21; position 23 is the `a/` footnote and 25 is a source credit. These two metadata/text rows must be explicitly recorded as intentionally filtered, not interpreted as financing agents. These are observed Bronze facts; the 128 candidate Silver rows are **expected**, not yet an executed result.

Source controls observed: 2023 `Households` share = 44.4%; `Total Current Health Expenditure` = 100.0%. Source `a/` means share below 0.05%, and is represented as a nonnumeric missing amount with an explicit status and retained raw text, **not** an imputed zero.

### Transformation and engineering decisions

1. Preserve source physical order (`_source_row_num`) and distinguish parent/child rows; parent names are carried forward using a window ordered by physical row number. Preserve the top-level parent and, when indentation signals deeper nesting, a subgroup (e.g., General Government > Central Government > Department of Health).
2. Preserve distinct hierarchy paths as `financing_agent` so that identical labels under different parents do not collide. Never sum a parent share together with its child/subagent breakdown: the source is hierarchical and overlapping.
3. Unpivot eight annual share columns into a long-form 2016–2023 dataset, with numeric parsing, `share_status`, source value, original source-column name and Bronze lineage.
4. Validate source row counts/classification, duplicate and missing physical positions, file-version consistency, hierarchy completeness, parsing and range constraints, target grain and PSA national controls before publication. SQL draft v3 adds these safeguards; none have been executed or passed yet.
5. The SQL produces temporary views only; it contains **no Delta production-table write**. Execution requires a single fail-on-error SQL session. Shared lineage disposition/build-input ledgers and `DQRun` Silver QC are still pending team-contract alignment.

### Execution environments, actions and status

- **Databricks SQL Editor (read-only):** inspected `_source_row_num`, `agent_level1`, `agent_level2`, `share_2023` for the configured Bronze `_source_key`; evidence above confirmed the source structure, without writing to tables.
- **Local VSCode Terminal (PowerShell, read-only):** inspected YAML, reviewed v1/v2 SQL, confirmed draft-v3 file header. Used `Copy-Item` to replace the working SQL with the downloaded v3 file. No Spark transformation executed against Bronze and no Delta target written.
- **Local development environment:** created project `.venv` (Python 3.14.7), installed PySpark 4.2.0 and confirmed Java 17. Local Spark launched successfully and returned `SELECT 1 = 1`, but produced Windows process-cleanup warnings; this smoke test does **not** validate the Silver transformation. Avoid unnecessary repeated local Spark startup.

### Outstanding actions

- Execute draft-v3 temporary-view SQL using a controlled session and review all validation-gate results, output grain/values, and hierarchy. Do not claim PASS before actual execution.
- Confirm Bronze-to-Silver row disposition and build-input lineage with team contract; integrate shared `DQRun` QC and guarded publication.
- Poverty Silver remains blocked on the reviewed 108-row area map and shared lineage/QC publication requirements. Do not invent PSGC mappings.
- Keep work on `feature/socioeconomic-silver`; open PR against `dev` when ready, with reviewer auto-assignment unchanged.


## 10. Health Expenditure Share Silver — Databricks Validation Evidence (2026-10-08)

### Execution and scope

- Environment: Databricks SQL Editor, existing SQL warehouse; source `public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze` filtered to `_source_key = 'psa_health_expenditure_share_national_annual'`.
- Executed a validation-only multi-statement SQL script (draft v3 logic) using temporary views `share_source`, `share_hierarchy`, `share_hierarchy_detail`, `share_cells`, `share_gates`, `share_final`. No production Delta CREATE TABLE, INSERT, MERGE or overwrite was performed.
- User-provided Databricks results: **17 of 17 gates PASS**, **0 reported gate failures**, **128 candidate agent-year rows**. These are confirmed execution results, replacing the previously pending test status for this transformation only.
- Independently reviewed the 2023 `share_final` result: **16 agent rows** with hierarchy paths and status columns.

### Observed 2023 controls and hierarchy examples

| Financing agent / path | Level | Share (%) | Status |
|---|---|---:|---|
| Total Current Health Expenditure | parent | 100.0 | ok |
| General Government | parent | 42.5 | ok |
| General Government / Central Government | child | 23.0 | ok |
| General Government / Central Government / Department of Health | subagent | 19.3 | ok |
| General Government / Social security agency / Social Health Insurance Agency (PHIC) | subagent | 10.2 | ok |
| Households | parent | 44.4 | ok |
| General Government / Other social security agency (GSIS, SSS) | child | NULL | below_0_05_pct |
| Rest of the World | parent | NULL | below_0_05_pct |

- PSA `a/` markers remain NULL percentages with `below_0_05_pct` status, not imputed zero.
- Hierarchical rows represent overlapping parent/subgroup breakdowns; **do not sum all rows as mutually exclusive categories**.
- One source label (`Other ministries and public units` with continuation text) retains an embedded newline and extra whitespace in the displayed financing-agent path; consider cosmetic normalization with source text preserved, subject to regression validation.

### Remaining before Silver publication

- Confirm team-agreed build-input and source-row disposition/lineage contract; reconcile the 18 Bronze rows (16 data, 2 intentional metadata exclusions).
- Implement guarded production Delta publication and Silver `DQRun` checks; rerun validations after any code change.
- Review full year-level business semantics if required by team; this test confirms configured gates and sampled 2023 output, not every possible semantic invariant.
- Poverty Silver still awaits the reviewed 108-row area mapping. PR to `dev` when ready; do not alter auto-assigned reviewers.


### 2026-10-08 — PSA health expenditure per capita: Bronze inspection and draft Silver design

- **Environment:** Databricks SQL Editor, read-only Bronze inspection supplied by developer; **no Silver publishing**.
- **Source:** `psa_health_expenditure_per_capita_national_annual`, Bronze table `public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze`; configured by `config/sources_socioeconomic.yaml` (PSA Table 9.24).
- **Observed physical source rows:** 4 (annual PHP amount), 5 (Growth Rate header), 6 (growth periods), 7 (growth percentage), 10–12 (population-basis notes), 14 (PSA source credit): eight Bronze rows, two substantive metric rows and six intentional non-data rows.
- **Source controls:** 2023 per-capita amount PHP 11,082.68; 2022 annual growth -2.8%. Values have commas/whitespace; growth cells use percent signs.
- **Transformation draft:** `src/03_silver/socioeconomic/socioeconomic_health_expenditure_per_capita_silver.sql` generates temp views `per_capita_source`, `per_capita_cells`, `per_capita_final`, `per_capita_gates`. Two metric source rows unpivot into sixteen source-year cells and pair into eight final `(year)` records. The `value_2016` growth cell refers to growth during 2015–16, not 2016–17; 2021 and 2022 are revision-marked. Preserve physical source row positions, raw amount/growth cells, as-of and ingestion lineage, population basis, and growth period. Do not aggregate metric types together.
- **Engineering controls:** 18 source-and-output validation gates, including exact source-position accounting, row classification, source file/version consistency, strict numeric parsing, expected year coverage, unique annual grain, and 2023/2022 controls. No Delta write, no shared ledger append, no shared quality writes.
- **Execution status:** SQL prepared only. No Databricks run or gate pass is claimed. Publication remains blocked pending the approved build-input / row-disposition contract and shared DQRun QC integration.


### Per Capita Silver — Databricks Validation Results (2026-10-08)

- Source: PSA Statistical Yearbook 2025, Table 9.24.
- Environment: Databricks SQL Editor.
- Execution: Standalone read-only SQL validation query.
- Result: PASS — 18 of 18 gates; 0 failures.
- Bronze input: 8 physical rows (2 contributing, 6 intentionally filtered).
- Transformation: 16 annual metric cells yielding 8 candidate records, 2016-2023.
- PSA controls: 2023 expenditure = PHP 11,082.68; 2022 growth = -2.8%.
- Publication: Not performed.
- Shared DQRun QC and lineage/disposition integration: Pending.
- Evidence: Validation results supplied from Databricks SQL Editor.



### Child Mortality Silver - Databricks Validation (2026-10-08)

- Source: PSA Statistical Yearbook 2025, Table 9.9 (2017 and 2022 NDHS).
- Bronze: public_health.bronze.socioeconomic_psa_child_mortality_bronze.
- Draft SQL: src/03_silver/socioeconomic/socioeconomic_child_mortality_silver_validation.sql.
- Grain: characteristic_group, characteristic, survey_year, mortality_metric.
- Environment: Databricks SQL Editor; standalone read-only SQL.
- Result: PASS - 18/18 gates; zero failures.
- Source reconciliation: 39 Bronze physical rows = 4 group headers + 30 data rows + 5 notes/source rows.
- Output preview: 180 metric records = 165 ordinary + 10 low-precision + 5 suppressed.
- Low-precision estimates: numeric value retained with low_precision status.
- Suppressed values: original '*' retained, numeric value NULL.
- PSA controls: NCR 2022 IMR = 8; BARMM 2017 U5MR = 55.
- Historical geography: 17 source-defined regions; no automatic PSGC assignment.
- Publication: NOT performed.
- Shared DQRun QC and build-input/row-disposition lineage integration: Pending.
- Evidence: User-supplied Databricks validation results, 18 PASS and zero failures.


## Child Mortality Silver — Databricks Validation (2026-10-08)

- Source: public_health.bronze.socioeconomic_psa_child_mortality_bronze
- Working SQL: src/03_silver/socioeconomic/socioeconomic_child_mortality_silver.sql
- Execution: Databricks SQL Editor, read-only
- Result: 21/21 validation gates PASS; zero failures
- Input: 39 physical Bronze rows
- Intermediate: 180 metric cells (165 normal, 10 low-precision, 5 suppressed)
- Silver candidate: 60 wide rows
- Grain: characteristic_group + characteristic + survey_year
- Controls: NCR 2022 infant mortality = 8; BARMM 2017 under-five mortality = 55
- Publication: NOT performed
- Pending: complete provenance/lineage, raw-value preservation, team QC contract integration, final Silver publication approval

Engineering decision:
Reshape six source mortality columns into three metric-specific rates per
characteristic and survey year. Preserve reliability classifications so
suppressed and low-precision observations remain distinguishable.
Keep the standalone original 18-gate validation as separate evidence.


## Child Mortality Silver — Raw-Value Fidelity Validation (2026-10-08)

- Execution: Databricks SQL Editor, read-only
- Result: 22/22 validation gates PASS; zero failures
- Candidate output: 60 wide Silver records
- Source metric cells checked: 180
- Gate 21: Raw-value fidelity PASS
- Added columns:
  - infant_mortality_raw
  - child_mortality_raw
  - under5_mortality_raw
- Raw-value handling: Preserve original PSA strings, including
  suppressed (*) and parenthesized low-precision observations.
- Previous validation: 21/21 PASS, retained as historical evidence.
- Publication status: NOT performed.

Engineering decision:
Keep raw source values beside numeric mortality rates and reliability
flags to support traceability and source-to-Silver reconciliation.
Validation remains read-only pending team lineage/QC alignment.


## Child Mortality Silver — Lineage Validation (2026-10-08)

- Execution: Databricks SQL Editor, read-only
- Result: 23/23 validation gates PASS; zero failures
- Candidate: 60 wide Silver records
- Grain: characteristic_group + characteristic + survey_year
- Gate 22: Source lineage consistency PASS
- Source lineage fields:
  - _source_key
  - _source_file
  - _source_sheet
  - _source_row_num
  - _as_of_date
  - _ingested_at
- Gate 21: Raw-value fidelity PASS
- Gate 23: PSA control values PASS
- Previous evidence: 22/22 PASS retained
- Publication: NOT performed

Engineering decision:
Retain six Bronze provenance fields in the Silver candidate.
Validate their consistency before using MAX() aggregation.
Preserve original mortality strings, parsed rates, and reliability
flags for source-to-Silver reconciliation.

Pending:
Align row disposition, build lineage, QC tables, and publication
logic with the team's approved Silver contract.


## PSA Poverty Area Map — Reference Data Validation (2026-10-08)

- Reference file: data/reference/socioeconomic_poverty_area_map.csv
- Original file: socioeconomic_poverty_area_map.csv (Jemma's guide)
- Records: 108
- Columns: 12
- Duplicate area_key: 0
- Blank area_key: 0
- Duplicate geo_name_source: 0
- Blank geo_name_source: 0
- First estimate year: 2021 (106 areas), 2023 (2 areas)
- Expected Silver grain: (area_key, year)
- Expected Silver records: 322
- Hash check: Matching displayed SHA-256 prefixes; full comparison pending

Geographic coverage findings:
- 21 records have comparison_eligible=false.
- 66 province records have coverage_confirmed=false and comparison_eligible=true.
- Preserve existing mapping flags and exclusion reasons.

Engineering decisions:
- Keep the original reference mapping unchanged.
- Store a repository copy instead of depending on a personal Downloads folder.
- Do not automatically consider comparison eligibility proof of confirmed geographic coverage.
- Validate mapping in Databricks before publishing Poverty Silver.

Publication status:
- Reference CSV copied locally.
- No Databricks mapping table created.
- No permanent Silver table published.


### Reference CSV Integrity Verification

- Date: 2026-10-08
- Method: SHA-256 hash comparison using PowerShell Get-FileHash
- Original: Downloads/socioeconomic_poverty_area_map.csv
- Repository copy: data/reference/socioeconomic_poverty_area_map.csv
- Actual comparison result: True
- Conclusion: Both files are byte-for-byte identical.

Engineering decision:
Preserve the validated reference CSV unchanged to maintain
source integrity and reproducibility. This verifies file identity,
not Databricks table readiness or semantic correctness.


### Poverty Reference CSV — Git Tracking Decision (2026-10-08)

Files:
- .gitignore
- data/reference/socioeconomic_poverty_area_map.csv

Action:
Added a narrow .gitignore exception allowing only the
PSA Poverty Area Map CSV under data/reference/.

Reason:
The mapping is a small, required transformation dependency.
Version-controlling it supports reproducibility and team review
without exposing other datasets in the data/ directory.

Validation:
- git status confirms .gitignore is modified.
- git status confirms data/reference/ is untracked and visible.
- Original CSV and repository copy have identical SHA-256 hashes.

Status:
- Changes remain local and unstaged.
- No commit or push performed.
- No Databricks tables modified.


### PSA Poverty — Bronze-to-Ingestion Metadata Reconciliation (2026-10-08)

Environment: Databricks SQL Editor
Execution: Read-only SELECT queries

Source tables:
- public_health.bronze.socioeconomic_psa_poverty_bronze
- public_health.bronze.ingestion_metadata

Actual validation results:
- tab2: 117 Bronze rows, exactly 1 metadata match
- tab6: 118 Bronze rows, exactly 1 metadata match
- Total Bronze rows: 235
- Both sheets have status = processed
- Both sheets share the same batch_id and content_checksum
- Bronze source paths successfully match metadata raw_file_path
- Bronze ingestion timestamps match metadata retrieved_at

Engineering decision:
Validate source-to-ingestion metadata joins before Silver
transformation to prevent missing or ambiguous build lineage.

Result: PASS — both sheets have exactly one matching metadata record.

Limitations:
- This validates ingestion lineage matching only.
- Poverty Silver transformation has not yet been validated in Databricks.
- No permanent Silver or Quality tables were modified.


### Poverty Silver Publication — 2026-10-08

- Table: public_health.silver.socioeconomic_poverty
- Publication: SUCCESS (Databricks SQL, 11/11 statements)
- Row count: 322 (verified)
- Validation gates: 9/9 PASS
- Reference mapping: 108 records
- Bronze source tables: unchanged
- Remaining: Quality disposition publication and downstream DQ checks, pending approved contract.


### Geography Validation Dependency — 2026-10-08

- Geography Silver target: public_health.silver.admin_boundaries_silver
- Source of table name: origin/dev config/sources.yaml
- Databricks SHOW TABLES result: No rows returned
- S04/S05 geographic validation: PENDING (not executed)
- Poverty Silver: Published, 322 rows; nine poverty gates PASS
- Decision: Do not rerun or overwrite Poverty Silver.
- Next action: Run geography validation when the Geography team's Silver table becomes available.


### Remaining Socioeconomic Silver Publication Dependencies — 2026-10-08

- Health Expenditure Per Capita: 18/18 validation checks PASS; not published.
- Health Expenditure Share: 17/17 validation checks PASS; not published.
- Shared lineage/QC contract: referenced in Jemma's v1.2 guide, but not found in current local files or origin/dev.
- Search for row_disposition and build_inputs in origin/dev src/ and docs/: no matches.
- Decision: Defer publication of these two tables until the shared integration requirements are confirmed.
- Published tables remain unchanged.
