# Silver — socioeconomic

The conditions around care: official poverty by area, how health spending is financed, spending per person, and child mortality by background. Poverty is the only table placed on PSGC areas; the others are national or by survey characteristic.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.5. Back to the [silver overview](README.md).

## Sources

| Source | What it gives | Years |
|---|---|---|
| PSA official poverty statistics (tab2, tab6) | Poverty threshold, incidence and poor population, among population, full year | 2021, 2023, 2025 |
| PSA Yearbook 9.26 | Share of current health expenditure by financing agent | 2016–2023 |
| PSA Yearbook 9.24 | Health expenditure per person and its growth | 2016–2023 |
| PSA Yearbook 9.9 (NDHS) | Infant, child and under-five mortality by region, residence, education and wealth | Surveys 2017, 2022 |

Settings: `config/sources_socioeconomic.yaml`, including the control values QC checks.

## Tables

| Table | One row is | Rows (last build) |
|---|---|---|
| `socioeconomic_poverty_silver` (`01`) | One area and reporting year | 322 |
| `socioeconomic_health_expenditure_share_silver` (`02`) | One financing agent and year | 128 |
| `socioeconomic_health_expenditure_per_capita_silver` (`03`) | One national year | 8 |
| `socioeconomic_child_mortality_silver` (`04`) | One background characteristic and survey | 60 |

`05` is a check, not a table: it compares every code of the poverty area map with geography and lists name differences for review.

## How it is built

| Step | File | What happens |
|---|---|---|
| Reference load | `00` | The reviewed poverty area map: key, PSGC code, level, coverage basis, first estimate year, comparison eligibility |
| Poverty | `01` | A row is data because its area is in the map, never because its values look like numbers. Cell status `ok`, `not_published`, `not_computed` or `parse_error`. The two sheets are joined by area and year. Poor population converted from thousands to persons. Coefficient of variation → precision class (`ok`, `use_with_caution`, `unknown`) |
| Expenditure share | `02` | An approved list of 16 financing agents in a 3-level hierarchy; `a/` (below 0.05%) → 0.0 with `is_below_0_05` |
| Per capita | `03` | Rows found by label and position; the growth rate under a year is the growth into that year |
| Child mortality | `04` | An approved list of 30 characteristics; `*` → `suppressed` (null), a value in parentheses → `low_precision` |

Report years, the precision cut-off and the share tolerance are named settings recorded with each build. New-file protection: a bronze year column that the settings do not list stops the build.

## Quality checks

`socioeconomic_silver_qc.py`, codes S01–S10 and S80–S96. Highlights:

| Code | Check |
|---|---|
| S83 | Silver was built from the bronze loads and area map that are there now |
| S84 | Control values from the YAML |
| S86, S87 | Hard limits; value agrees with its flag or status |
| S88 | Exactly the expected rows (years and counts from the build settings) |
| S90 | Area attributes match the area map |
| S91 | Level-1 financing shares add up to the total |
| S93 | Every poverty PSGC code exists once in geography, at the same level |

**Expected WARNs:** S94 (incidence fell by more than 15 points or reached zero), S95 (areas not eligible for comparison with PSGC-based data), S96 (child mortality reference period not confirmed).

## Rules for users

- Poverty is among **population**, **full year**. Do not mix it with family-based or first-semester figures.
- Province rows with `comparison_eligible = false` cover a different population than PSGC province figures (they may include or leave out highly urbanized cities). See `exclusion_reason`.
- Financing agents form a hierarchy: never add a parent to its children. Only level-1 agents add up to the total.
- Child mortality regions are the 17 regions of the old definition (no Negros Island Region): regional context only.
- `survey_year` is the survey, not the year deaths occurred.

## Limitations

- Coverage of some poverty provinces that include highly urbanized cities is not confirmed by PSA.
- The child mortality reference period is not confirmed (`reference_period` is null).
- Per capita spending changes population basis in 2020 and 2021, so growth across those years is not like for like.

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
