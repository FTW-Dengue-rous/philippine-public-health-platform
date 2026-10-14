# Workforce Bronze — Ingestion and Quality Evidence

**Project:** Philippine Public Health Platform / LUNASaan?
**Layer / domain:** Bronze / Workforce
**Code reference:** `origin/dev` at commit `7484f62` (Workforce source ZIP exported 2026-10-12)
**Validation evidence:** Read-only Databricks QC inspection on 2026-10-12 of recorded runs from 2026-10-07. The QC run's Git commit was **not recorded**.

## 1. Domain Overview

Workforce Bronze stores source-level public-health workforce observations **before** the Silver layer converts them into comparable area, year, and profession records. In simple terms, the source workbooks contain separate pieces of workforce reports; Bronze keeps those pieces traceable, while Silver interprets and joins them.

**Pipeline:** Landing files → config-driven Bronze Delta tables → Bronze QC → Workforce Silver.

Bronze preserves the original landing files and their lineage, but normalizes their **extracted** cell representations: blank/whitespace-only cells become null, Excel dates become text, whole-number floats lose `.0`, and fully empty rows are skipped. Therefore, “as published” means source-level fidelity, **not** a byte-for-byte copy of the worksheet in Delta.

## 2. Source and Input Data

Configuration: [`config/sources_workforce.yaml`](../../config/sources_workforce.yaml). Configured landing root: `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing` (workspace-specific; not inherently portable).

| Source / key | Input and coverage | Bronze Delta destination | Configured expected rows* |
|---|---|---|---:|
| DOH FHSIS / `doh_fhsis_demographic` | 8 annual Excel workbooks, **18 selected worksheets**, 2018–2025; 2025 includes municipality-level records | `public_health.bronze.workforce_fhsis_health_workers_bronze` | **4,999** |
| PSA Table 9.14 / `psa_gov_practitioners` | 1 CSV with government practitioners by region and year, 2012–2023 | `public_health.bronze.workforce_psa_gov_practitioners_bronze` | **72** |
| PSMO directory / `psmo_oncologists` | 1 CSV snapshot dated 2026-10-05 with listed medical oncologists by area | `public_health.bronze.workforce_psmo_oncologists_bronze` | **52** |

*These are controls recorded in YAML, **not observed Databricks table counts**. The FHSIS annual expectations are **644, 600, 593, 592, 394, 289, 143, and 1,744** (2018–2025). The PSMO YAML also specifies a `doctor_count` control total of **419 area listings/counts**, which must **not** be presented as verified unique individuals nationwide.

Configured landing folders are `workforce/doh_fhsis_demographic/`, `workforce/psa_gov_practitioners/`, and `workforce/psmo_oncologists/`. PSA uses an older 17-region representation; the FHSIS geographic detail changes across years. Neither is automatically comparable at the province level.

## 3. Bronze Data Design

**Grain:** One **nonempty physical data row** from one configured input file or worksheet. The lineage combination `(_source_key, _source_file, _source_sheet, _source_row_num)` identifies its original position; `_source_row_num` is **zero-based**. A workbook spanning several sheets produces separate Bronze rows for those sheets, **not** one pre-aggregated area-year observation.

Source business fields are stored as `STRING`, including numerical-looking counts and source markers. Fields from varying yearly worksheets are combined by column name, with missing columns left null. Core lineage fields are:

`_rescued_data`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_ingested_at`.

`_as_of_date` is the configured **source snapshot/date**; `_ingested_at` is the **pipeline loading timestamp**. They are not interchangeable. `STRING` applies to source business fields, not all typed lineage columns.

## 4. Code Walkthrough

Main scripts: [`src/02_bronze/workforce_bronze.py`](../../src/02_bronze/workforce_bronze.py) (loader version `2026-10-06.2`), [`src/05_quality/bronze/workforce_bronze_qc.py`](../../src/05_quality/bronze/workforce_bronze_qc.py), and the Workforce YAML.

1. **Read configuration.** Discover the YAML or use `--config_path`; merge defaults and select all enabled sources or named `--source_keys`.
2. **Resolve file layouts.** Each configured file/sheet may override format, encoding, header mode, column names, sheet and first data row. FHSIS YAML anchors describe changing profession columns across years.
3. **Read without modifying landing files.** Use CSV reading or `openpyxl` for Excel (cached formula results, not recalculated formulas). Keep nonempty footer lines for later classification; capture cells beyond mapped columns in `_rescued_data`.
4. **Validate before writing.** Check physical `header_check` positions, required named columns, and at least one data row. If a source fails these checks, **that source is not written**.
5. **Build and write Delta.** Assemble the source's worksheet DataFrames with compatible column unions. Existing target tables use `mode('overwrite').option('replaceWhere', ...)` scoped to the selected `_source_key` and `_source_file` values. If the table does not exist, the writer creates it with append mode.
6. **Reconcile and audit.** Compare records read with rows in Delta, per file. Append one `ingestion_metadata` row per input file/sheet, recording batch ID, checksum, source/version, file path, sheet, count, load timestamp and status where supported by the existing audit schema.

The loader attempts the remaining selected sources if one fails, then returns an overall failed run for source or metadata-write failures. **A failure after the Delta write does not automatically roll that write back.**

## 5. Design Decisions

- **Keep raw context:** preserve source strings, markers such as `*`, empty cells, and origin identifiers rather than imposing Silver interpretation at ingestion.
- **Handle evolving layouts in configuration:** FHSIS has 3 selected worksheets/year in 2018–2021, 2/year in 2022–2023, and 1/year in 2024–2025. The config aligns column meanings without merging area-year facts in Bronze.
- **Do not mistake the configuration for write behavior:** `load_mode: upsert` and `merge_keys` exist in YAML, but this loader **does not execute key-based SQL `MERGE`**. Its implemented operation is **file-scoped Delta `replaceWhere`**.
- **Define rerun guarantees narrowly:** a rerun of the same configured files/path replaces their scoped Bronze rows instead of simply appending duplicates, but `_ingested_at` changes and an additional ingestion-audit record is appended. Full byte-for-byte/audit idempotency is **not** guaranteed.
- **Clarify PSMO snapshot behavior:** its YAML sets `load_mode: latest_file`, yet the generic loader does **not** automatically remove rows from an older **different filename**. The Silver snapshot choice and any Bronze retention policy must be explicit.

## 6. Data Quality and Error Handling

The Workforce Bronze QC script uses the shared `DQRun` utility. It defines codes **B00–B15**, including execution-error reporting (`B00`), presence/coverage, expected file counts, required columns, nonnull lineage, uniqueness of source row positions, blank/duplicate rows, rescued overflow, numeric parseability, published control values, metadata reconciliation, unexpected files and business-column string types.

Default **FAIL** checks protect completeness, schema, lineage, uniqueness and configured verified controls; **WARN** checks surface concerns such as duplicate content, nonnumeric markers and rescued values without claiming data was corrected. `B12` (part-to-total consistency) only runs when `qc.row_sum` is configured; the supplied Workforce YAML does not currently provide that rule. `B13` may report **WARN** when table rows and metadata cannot be compared for the same load, rather than falsely passing reconciliation. Severity overrides and skipped checks are possible through YAML.

`DQRun` is imported by this script but its implementation was **not included in the Workforce source ZIP**. Its actual quality tables were subsequently inspected in Databricks (see Section 8). The default QC CLI is designed to fail on `FAIL` checks, unless `--fail_on_error false` is explicitly selected.

**Observed B08 warning:** The recorded 2026-10-07 QC run contains a `WARN` for `doh_fhsis_demographic`, check `B08` (no exact duplicate rows), with `fail_count = 5`. Read-only investigation located **one group of six identical business-data rows** in the 2019 workbook, sheet `Health Workers Part2` (source row indices **16, 22, 48, 64, 100, 239**). Each has `area_name = NULL`, all workforce headcount fields `NULL`, and `medtech_ratio = "0"`; other business fields were null in the inspected record. Thus six identical rows create **five excess duplicates**, explaining B08. These *appear* to be non-data/placeholder records; this interpretation has **not** been checked against the original Excel workbook. No Bronze rows were deleted or changed.

## 7. Downstream Dependencies

Workforce Silver uses the three Bronze sources, geographical name/PSGC mapping and reference data, and downstream rules for choosing comparable workforce counts. FHSIS contributes yearly reported staff totals and source denominators; PSA contributes historical government-practitioner series; PSMO contributes specialty-directory area listings.

Important source limitations carried forward:

- FHSIS and PSA reflect **government/public** workforce reporting; they do not represent the complete private-sector workforce.
- FHSIS 2018 uses male/female breakdowns; later reports emphasize LGU/DOH hiring. The YAML notes incomplete 2019 employment splits—prefer published totals when splits are unreliable.
- Source `*`, blank and zero have context-dependent meanings. **Do not silently convert missing reports to zero headcount.**
- BHW source ratios change denominator conventions (population versus households); comparative rates need a single explicit basis downstream.
- PSMO listings mix provinces, cities, NCR districts and a region label, with possible overlapping practice areas; do **not** add them as proven unique nationwide doctors.
- FHSIS 2018–2024 do not provide PSGC in the selected rows; geography resolution is a Silver responsibility.

## 8. Validation and Reproducibility

**Code review completed:** inspected the ZIP tied to verified `origin/dev` commit `7484f62`, parsed the YAML (**3 configured sources**), and reviewed the loader and QC Python source.

**Observed read-only Databricks QC evidence (queried 2026-10-12):** `public_health.quality.run_log` records two Workforce Bronze runs on 2026-10-07 (timestamps UTC):

| Started at (UTC) | Validation ID | Status | Checks | PASS | WARN | FAIL | Source keys |
|---|---|---|---:|---:|---:|---:|---|
| `13:38:27` | `6e2f430f-d4c4-4287-ad19-d04f9cffb68b` | **WARN** | 70 | 69 | 1 | 0 | `ALL` |
| `11:25:33` | `3f41720e-787a-43b7-90ae-a5952826b743` | **FAIL** | 3 | 0 | 0 | 3 | `ALL` |

The latest recorded run is **WARN, not PASS**. Its only non-passing result in `public_health.quality.qc_results` is **B08**, FHSIS exact duplicates (`fail_count = 5`), traced to six repeated source-level rows in 2019 `Health Workers Part2` (see Section 6). Both runs have `code_version = NULL`, so they **cannot be conclusively attributed to `7484f62`**. The earlier failed run is historical evidence; its underlying failure checks were not investigated here.

**Expected Silver treatment (code review only):** `workforce_silver_01_fhsis_areas.sql` classifies a missing `area_name` as `label_kind = 'blank'`. `workforce_silver_02_headcount.sql` classifies such rows as `non_data` if no usable **headcount** values are present, and headcount generation joins only `row_class = 'data'`. The observed `medtech_ratio = "0"` is not a headcount. Accordingly, the six rows are **expected not to contribute to Silver headcounts if these scripts execute as reviewed**. Their actual Silver disposition/build result is **not verified**.

**Not independently verified:** original landing-workbook cell contents, complete live Bronze row counts/table versions, ingestion batch/checksum matching, the Silver run/disposition, or exact-input Bronze rerun behavior. Do not describe this as a clean QC PASS or as an end-to-end validation.

### Supported CLI examples

Run in a configured **Databricks Python/Spark environment** with Volume access and the required dependencies; the examples below are **not commands to execute in a SQL Warehouse**. Review the selected source before invoking a writing command.

```bash
# Read-only source/header preview (requires access to the configured landing file).
python src/02_bronze/workforce_bronze.py --show_headers 8 --source_keys psa_gov_practitioners

# WRITE: only this Bronze source, if an ingestion run is approved.
python src/02_bronze/workforce_bronze.py --source_keys psa_gov_practitioners

# QC: after that source has been ingested.
python src/05_quality/bronze/workforce_bronze_qc.py --source_keys psa_gov_practitioners
```

Without `--source_keys`, either script selects **all enabled Workforce sources**. Use `--config_path` when the YAML cannot be discovered. QC also supports `--job_run_id`, `--code_version` and `--profile`; output depends on the configured runtime and shared `DQRun` setup.

A read-only table-count check when a Databricks SQL endpoint is available:

```sql
SELECT _source_key, _source_file, _source_sheet, COUNT(*) AS bronze_rows
FROM public_health.bronze.workforce_fhsis_health_workers_bronze
GROUP BY _source_key, _source_file, _source_sheet
ORDER BY _source_file, _source_sheet;
```

For formal evidence, match observed per-file counts to YAML expectations, ingestion-metadata batch/checksums, QC results, table versions, and any warning/failure decisions. Re-run tests only with agreed scope and compute cost.

## 9. Open Issues and Follow-up

1. Keep B08's **five excess duplicate rows** documented; check the six positions against the original 2019 Excel sheet when source-level confirmation is necessary. Do not remove Bronze rows to silence a legitimate WARN.
2. Verify actual Workforce Silver classification/disposition before claiming these rows were excluded in a completed build.
3. Match the QC run to a code revision if evidence becomes available (`code_version` is currently NULL), and verify live ingestion batches, checksums, counts and Delta versions for complete reproducibility evidence.
4. Confirm the intended **PSMO snapshot replacement/retention** contract when a new filename arrives; generic Bronze replacement alone is not “latest only.”
5. Clarify deployment-specific landing path/catalog settings and inspect the current shared `dq_utils.py`/ingestion metadata interfaces; prefer environment-specific configuration.
6. Preserve geographic and metric limitations and investigate future WARN/FAIL findings without suppressing them to obtain a green QC status.

## 10. Change Log

| Date | Change | Evidence status |
|---|---|---|
| 2026-10-12 | Reviewed loader, QC and YAML from `origin/dev` `7484f62`; clarified grain, replacement behavior and snapshot caveats | Static code inspection |
| 2026-10-12 | Added read-only Databricks QC run evidence (69 PASS, 1 WARN, 0 FAIL), investigated B08's six identical 2019 source rows, and assessed expected Silver handling | Actual quality logs inspected; code-version match and Silver execution **not** verified |
