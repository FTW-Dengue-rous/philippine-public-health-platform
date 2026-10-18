# Socioeconomic Bronze Layer Documentation

Owner: Virna Pomendia
Last updated: 2026-10-18

**Project:** Philippine Public Health Platform
**Code reference:** `origin/dev` @ `976b766`
**Validation evidence:** Databricks QC on 2026-10-07; read-only verification on 2026-10-12
**Status:** Five Bronze tables verified against recorded QC, counts, ingestion metadata, and Delta history. The QC run's `code_version` has not been matched to this repository commit.

## 1. Domain Overview

The Socioeconomic Bronze layer ingests **PSA poverty, national health expenditure, child mortality, and file-based PSGC reference data** from a governed landing Volume into Delta tables. It preserves source values, notes, and physical-row lineage; numeric interpretation and geographic harmonization occur in Silver.

The domain supports **BQ1 Equity (E1/E2)** through poverty, while national expenditure and child mortality provide contextual analysis. The file-based PSGC source supports geographic attributes but does not replace the separate Geography-domain pipeline. Bronze does not compute cross-domain rates or establish geographic comparability.

## 2. Source and Input Data

### 2.1 Source Overview

All sources are from the **Philippine Statistics Authority (PSA)** and are **file-based**, not API ingestion. Paths below are relative to the YAML `landing_root`: `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`.

| Source key | Input file / sheet | Landing folder | Coverage / source version | Key limitation |
|---|---|---|---|---|
| `psa_poverty` | `psa_poverty_province_biennial_2021_2025.xlsx`, `tab2` + `tab6` | `socioeconomic/psa_poverty/` | 2021, 2023, 2025; as-of `2026-08-26` | Mixed province/HUC/NCR coverage; two different poverty measures |
| `psa_health_expenditure_share_national_annual` | `psa_health_expenditure_share_national_annual_2016_2023.csv` | `socioeconomic/psa_health_expenditure/share_national_annual/` | 2016–2023; as-of `2026-10-05` | National only; parent/child financing-agent categories overlap |
| `psa_health_expenditure_per_capita_national_annual` | `psa_health_expenditure_per_capita_national_annual_2016_2023.csv` | `socioeconomic/psa_health_expenditure/per_capita_national_annual/` | 2016–2023; as-of `2026-10-05` | Amount and growth occupy separate physical rows |
| `psa_child_mortality` | `psa_child_mortality_region_survey_2017_2022.csv` | `socioeconomic/psa_child_mortality/` | Survey years 2017, 2022; as-of `2026-10-05` | Survey-based; suppression and low-precision markers; `cp1252` encoding |
| `psa_psgc` | `psa_psgc_barangay_asof_20260713.xlsx`, `PSGC` | `geography/psa_psgc/` | June 2026 snapshot; file version `2026-07-13` | Separate from the Geography-domain API PSGC snapshot |

### 2.2 Input Files and Configuration

- `config/sources_socioeconomic.yaml` registers filenames, target tables, layouts, `as_of_date`, `qc` controls, and `landing_root` (no source URLs embedded in the Python loader).
- `src/02_bronze/socioeconomic_bronze.py` is the CSV/XLSX loader; `src/05_quality/bronze/socioeconomic_bronze_qc.py` runs Bronze checks through `src/05_quality/dq_utils.py`.
- `--source_keys` selects one or more configured sources; without it the loader processes all enabled entries, **including `psa_psgc`**. `--show_headers 8` previews inputs; `--config_path` overrides YAML discovery.
- Poverty sheets use YAML column-layout aliases (`*poverty_tab2`, `*poverty_tab6`), `data_start_row: 7` (zero-based), and `header_check` (including the first `PHILIPPINES` data label). Child mortality uses `cp1252`. Missing files/sheets, unsupported formats, and failed header checks fail the affected source before writing.

## 3. Bronze Data Design

### 3.1 Target Table

**Catalog:** `public_health` · **Schema:** `bronze` · **Format:** Delta. Each table contains source-aligned **physical rows**, not final Silver observations.

| Table name (under `public_health.bronze`) | Grain | Configured rows |
|---|---|---:|
| `socioeconomic_psa_poverty_bronze` | One physical workbook row per `tab2`/`tab6` | 235 (117 + 118) |
| `socioeconomic_psa_health_expenditure_share_bronze` | One financing-agent/footnote/credit source row | 18 |
| `socioeconomic_psa_health_expenditure_per_capita_bronze` | One amount/growth/header/note source row | 8 |
| `socioeconomic_psa_child_mortality_bronze` | One survey characteristic/header/note source row | 39 |
| `socioeconomic_psa_psgc_bronze` | One PSGC workbook row | 43,768 |

**Write strategy:** first load creates the table; subsequent selected-file loads use Delta `overwrite` with **`replaceWhere`** scoped to `_source_key` and `_source_file` (not SQL `MERGE`). The YAML `load_mode: upsert` is descriptive here; the Python writer controls the actual operation. Unselected files are intended to remain unchanged.

### 3.2 Schema and Column Descriptions

**All business fields are nullable `STRING`** at Bronze. Actual names and positional layouts are defined in the YAML. Representative fields:

| Source | Source fields retained as text |
|---|---|
| Poverty | `area_name`, `threshold_*`, `incidence_*`, `incidence_cv_*`, `poor_pop_*`, confidence intervals, `notes` |
| Spending share | `agent_level1`, `agent_level2`, `share_2016` … `share_2023` |
| Per-capita spending | `indicator`, `value_2016` … `value_2023` |
| Child mortality | `characteristic_group`, `characteristic`, `imr_*`, `cmr_*`, `u5mr_*` |
| PSGC | Original worksheet fields with sanitized names (codes, levels, income class, population); **do not assume a Bronze column named `psgc_code`** |

Whitespace-only cells become null; fully blank rows are skipped; populated notes remain. Missing sheet-specific columns become null when the two poverty sheets are combined. Extra non-null cells beyond the configured width are retained as JSON text in `_rescued_data`.

### 3.3 Lineage and Metadata

| Bronze column | Type | Purpose |
|---|---|---|
| `_source_key`, `_source_file` | `STRING` | Configured source and relative input file |
| `_source_sheet` | `STRING` (nullable) | Excel tab; null for CSV |
| `_source_row_num` | `INT` | Zero-based physical source row |
| `_as_of_date` | `DATE` | Source version/as-of date, not a data-observation year |
| `_ingested_at` | `TIMESTAMP` | Load timestamp |
| `_rescued_data` | `STRING` (nullable) | Unexpected overflow values |

The **batch ID, SHA-256 file checksum, source version, full path, row count, and processing status** live in `public_health.bronze.ingestion_metadata`, not as per-row Bronze columns. Both poverty sheets share their workbook checksum.

## 4. Code Walkthrough

### 4.1 Configuration and Initialization

`find_config()` and `load_config()` locate and validate YAML, merge defaults and per-source settings, and select sources. The loader uses Spark, Python `csv`/`openpyxl`, a per-run UUID, and one ingestion timestamp.

### 4.2 Input Discovery and Reading

`resolve_files()` uses explicit YAML paths and options. CSV reading respects delimiter/encoding; Excel reading selects the sheet and cached formula results (`data_only=True`). Files not listed in an explicit source configuration are not ingested.

### 4.3 Transformation and Record Construction

`check_header()` validates source layout; `build_records()` assigns YAML column names and retains nonempty source rows. `to_bronze_df()` stores business fields as text and adds lineage. Poverty sheets are combined by name. Numeric parsing, source footnote interpretation, hierarchy, year unpivoting, and geographic matching are deferred to Silver.

### 4.4 Writing to Bronze

`write_bronze()` writes Delta; `mergeSchema=true` permits added fields but **does not replace layout review**. `replaceWhere` refreshes only selected files. Same-input reruns should not append duplicate file rows, but still create a write and new audit entries: **no checksum-based skip**. Concurrent writers are not explicitly locked; avoid overlapping loads.

### 4.5 Audit Logging and Reconciliation

`rows_in_table()` reconciles post-write file/sheet counts; `log_metadata()` appends ingestion records. A missing file/header error can stop a source **before** writing; a reconciliation or metadata-write failure can occur **after** Delta data is committed. Resolve audit mismatches before Silver. One source failing does not prevent the loader from attempting other selected sources, but the overall run is marked unsuccessful.

## 5. Design Decisions

### 5.1 Source Preservation

Retain notes and source markers (`a/`, `*`, parentheses), not guessed numeric replacements. Poverty incidence refers to **people**, not families; financing-agent parent and child rows are not additive.

### 5.2 Schema and Data Type Strategy

String-first ingestion prevents premature loss of source annotations. Positional YAML layouts and header guards handle irregular PSA tables. Review any source layout changes even when Delta schema evolution technically succeeds.

### 5.3 Incremental Loading and Idempotency

File-scoped `replaceWhere` replaces selected data, while ingestion metadata is append-only. The scoped overwrite is intended to prevent append duplicates, but a new same-input rerun regression of the *current Python loader* was **not performed** for this document.

### 5.4 Lineage and Reproducibility

Physical row numbers, source files/sheets, load timestamps, metadata batch IDs/checksums, and Delta history form the audit trail. The historical QC `code_version` has not been independently tied to `976b766`.

### 5.5 Other Domain-Specific Decisions

The Socioeconomic file-based PSGC reference (**43,768 rows**) is distinct from the Geography API snapshot (**43,762 rows** in the project reference). Coordinate canonical geography and avoid accidentally rerunning both sources.

**Historical note (superseded):** The initial Poverty ingestion experimented with direct PSA retrieval (HTTP 403), then separate R2-based SQL tables (`tab2` **141** rows; `tab6` **142**, including separators) and `REPLACE USING` rerun tests. This approach was replaced by the shared-Volume YAML/Python loader, which loads **117 + 118 = 235** configured source rows. The old counts/tests use a *different extraction contract* and **do not validate current `replaceWhere` reruns**.

## 6. Data Quality and Error Handling

`src/05_quality/bronze/socioeconomic_bronze_qc.py` records results using `DQRun`:

| Check group | Actual coverage |
|---|---|
| `B01–B06` | Existence, expected rows, required fields, lineage and physical-row uniqueness |
| `B07–B12` | Source anomalies, numeric readability, PSA control values and optional totals |
| `B13–B15` | Ingestion-metadata reconciliation, unexpected files, Bronze column types |
| `B00` | Error fallback if QC cannot complete |

The configured severity is authoritative: certain source anomalies are **WARN**; a confirmed count mismatch is a **FAIL**. A missing/unmatched metadata record may raise **WARN** under B13; warnings require review, not assumed acceptance. FAIL normally raises **after** QC logs are written.

On failure, review the file path/layout, `ingestion_metadata`, `quality.run_log`, `quality.qc_results`, and `quality.v_open_issues`. Do not blindly rerun data that may already have been committed.

## 7. Downstream Dependencies and Analytical Impact

### 7.1 Silver Layer Dependencies

| Bronze | Silver / planned use |
|---|---|
| Poverty | Combine `tab2` and `tab6`, unpivot years, apply reviewed area map and `comparison_eligible`; deployed `socioeconomic_poverty`, target naming `socioeconomic_poverty_silver` |
| Spending share | `socioeconomic_health_expenditure_share_silver` intended; `__candidate_v2` was observed, not a canonical publication |
| Per-capita spending | `socioeconomic_health_expenditure_per_capita_silver` intended; canonical table not confirmed |
| Child mortality | `socioeconomic_child_mortality_silver` observed published; interpret reliability/suppression |
| File PSGC | Reference income/geography attributes; canonical Geography Silver dependency remains separate |

### 7.2 Gold Layer and Business Questions

The updated Gold v3.1 design uses poverty for **`FACT_POVERTY` and Equity E1/E2**. National health expenditure remains **context outside the core constellation facts**; child mortality is supporting survey context. PSGC attributes may support area-income comparisons after geographic review. Bronze alone does not certify Gold eligibility.

### 7.3 Important Interpretation Notes

**Missing ≠ zero.** Published poverty percentages are not freely additive; national expenditure cannot be assigned to provinces. A matching PSGC key does not imply identical HUC boundaries or denominators. Cross-domain marts prefer exact compatible periods; the two-year alignment allowance is conditional, not universal.

## 8. Validation and Reproducibility

**Verified results:** Existing `DQRun` records from **2026-10-07** show four `ALL` runs, each **74 checks / 0 FAIL / 0 WARN**. Latest `validation_id`: `b4ed3728-c8dd-430a-aebe-45fa5e23321a` (15:00:05 UTC). Read-only Databricks checks on **2026-10-12** confirmed:

| Source | Current rows vs configured | Latest QC checks | Last data-write version → current Delta version |
|---|---:|---:|---|
| Poverty | 235 / 235 | 18/18 PASS | 0 → 2 |
| Health expenditure share | 18 / 18 | 15/15 PASS | 0 → 2 |
| Health expenditure per capita | 8 / 8 | 13/13 PASS | 0 → 2 |
| Child mortality | 39 / 39 | 14/14 PASS | 0 → 2 |
| PSA PSGC | 43,768 / 43,768 | 14/14 PASS | 0 → 0 |
| **Total** | **44,068 / 44,068** | **74/74 PASS** | — |

All **six** latest file/sheet ingestion records are `processed`, share batch ID `25d73d11-8005-4810-92cc-fb0d8f46558a` (2026-10-07 14:30:19 UTC), and contain SHA-256 checksums. Poverty sheet audit counts are **117** (`tab2`) + **118** (`tab6`), with the same workbook hash. All five tables' initial data commits occurred before the QC run. Subsequent Delta operations (on four tables) were `SET TBLPROPERTIES` and `COMPUTE STATS` only; no subsequent data writes appear in the inspected histories.

**Read-only checks** (SQL Warehouse; each `LIMIT` caps output, not necessarily compute):

```sql
SELECT validation_id, started_at, status, checks_total, checks_fail, checks_warn
FROM public_health.quality.run_log
WHERE layer = 'bronze' AND domain = 'socioeconomic'
ORDER BY started_at DESC LIMIT 5;

SELECT source_name, source_sheet, record_count, status, content_checksum
FROM public_health.bronze.ingestion_metadata
WHERE batch_id = '25d73d11-8005-4810-92cc-fb0d8f46558a'
LIMIT 10;
```

For source-level detail, filter `public_health.quality.qc_results` by the validation ID above. For source counts, group by `_source_key`, `_source_file`, `_source_sheet` in the relevant Bronze table. For data-write continuity, run `DESCRIBE HISTORY <table> LIMIT 5` separately (example: `DESCRIBE HISTORY public_health.bronze.socioeconomic_psa_poverty_bronze LIMIT 5;`).

**Execution reference only** (approved Databricks Python/Spark environment; **not required for this documentation update**):

```bash
python src/02_bronze/socioeconomic_bronze.py --show_headers 8 --source_keys psa_poverty
python src/02_bronze/socioeconomic_bronze.py --source_keys psa_poverty
python src/05_quality/bronze/socioeconomic_bronze_qc.py --source_keys psa_poverty
```

## 9. Open Issues and Follow-up

- **Run provenance:** match October 7 QC `code_version` to the reviewed source commit if required; do not claim it was the `976b766` revision.
- **Idempotency:** current Python loader's same-input rerun regression has not been newly executed; avoid reloading shared data solely for documentation.
- **Geography ownership:** agree the canonical PSGC source and whether `psa_psgc` should remain enabled for all-source ingestion.
- **Downstream gating:** Bronze PASS does **not** imply that Socioeconomic Silver lineage/QC or Gold geographic eligibility has passed; track those separately.

## 10. Change Log

| Version | Date | Description |
|---|---|---|
| 1.0 | 2026-10-12 | Consolidated source implementation and verified Bronze QC, counts, metadata and Delta histories. |
| 1.1 | 2026-10-12 | Aligned to the team's ten-section template; consolidated duplicate evidence and retained superseded ingestion history in one note. Documentation-only change; no ingestion rerun. |

**Related:** `docs/lineage-qc-contract_v1.3.md` · [`Socioeconomic Silver`](socioeconomic_silver.md) · `config/sources_socioeconomic.yaml` · `src/02_bronze/socioeconomic_bronze.py` · `src/05_quality/bronze/socioeconomic_bronze_qc.py`.
