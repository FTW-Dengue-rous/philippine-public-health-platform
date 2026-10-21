# Bronze Layer - Diseases Domain

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

## 1. Domain Overview

**Purpose**

The Diseases Bronze loader ingests configured disease, morbidity, mortality, notifiable-disease, hospital-encounter, and related health datasets from CSV and Excel files into Delta tables. It preserves source values as strings wherever possible and adds file-level lineage. Type casting, normalization, reference mapping, and analytical rules belong in Silver and later layers.

**Scope**

This document describes `diseases_bronze.py` and its `config/sources_diseases.yaml` configuration. It documents behavior visible in the supplied loader and configuration; it does not claim that all sources were successfully loaded or that deployed table contents were independently verified.

**Implementation characteristics**

- Config-driven ingestion for enabled entries in the `diseases` domain.
- CSV and Excel (`.xlsx`, `.xlsm`) inputs.
- Data columns stored as `STRING`; empty/whitespace-only cells become null.
- File-level lineage and ingestion audit metadata.
- Source/file replacement rather than append-only behavior for reruns of the same configured files.
- Each source is handled independently; a source failure is recorded and does not prevent the loop from attempting other selected sources. The overall process fails at the end if any source or audit logging failed.

## 2. Source and Input Data

### 2.1 Configuration and landing inputs

| Attribute | Description |
|---|---|
| Configuration | `config/sources_diseases.yaml` |
| Landing root in supplied configuration | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing` |
| Source selection | YAML `sources` entries; enabled entries whose domain is `diseases` and which have `path` and `bronze_table` are loadable |
| Default metadata table | `public_health.bronze.ingestion_metadata` |
| Default QC-results table | `public_health.quality.qc_results` (configured for the wider pipeline; this loader does not write QC results directly) |
| Default Silver target hint | `public_health.silver.diseases_metric_silver` (configuration metadata; not written by this Bronze loader) |
| Formats supported by code | CSV, XLSX, XLSM |

The YAML `defaults` are merged into each source entry, and per-file settings can override supported file-level options. The `as_of_date` is required for each resolved file and is attached to every ingested row. It is a configured source/file reference date; it should not automatically be interpreted as the event date or the data's full temporal coverage.

### 2.2 Configured source inventory

The supplied YAML contains the following disease-domain entries and target Bronze tables. File names and paths below are taken from the configuration, not from a claim that the files were present or loaded successfully at documentation time.

| Source key | Input represented in configuration | Target Bronze table | Main layout notes |
|---|---|---|---|
| `doh_foi_dengue` | DOH FOI regional monthly dengue, 2021–2025 | `public_health.bronze.diseases_doh_foi_dengue_bronze` | CSV; header row; required `Year`, `Month`, `Region`, `Cases`, `Deaths` |
| `upnoah` | UP NOAH regional weekly dengue, 2016–2025 | `public_health.bronze.diseases_upnoah_dengue_regional_bronze` | Excel sheet `Regional Data`; required region/year/week and quality/approximation flags |
| `hdx_dengue` | HDX provincial weekly dengue files, 2016–2021 | `public_health.bronze.diseases_hdx_dengue_bronze` | Two CSV files; header check expects HDX-style fields on row index 1 |
| `doh_foi_tb_region2` | DOH FOI Region 2 annual TB workbook, 2020–2025 | `public_health.bronze.diseases_doh_foi_tb_region2_bronze` | CSV with multiple report sections; `header_mode: none`; positional layout checks |
| `psa_deaths_national_monthly` | PSA national monthly deaths by cause, 2020–2024 | `public_health.bronze.diseases_psa_deaths_national_monthly_bronze` | Annual files; Excel sheets for 2020–2022 and CSV for 2023–2024; YAML-provided column names |
| `psa_deaths_region_annual` | PSA regional annual deaths by cause, 2023–2024 | `public_health.bronze.diseases_psa_deaths_region_annual_bronze` | CSV; YAML-provided geolocation, cause, total, and age-band columns |
| `psa_deaths_national_annual` | PSA national annual deaths by cause, 2015–2020 | `public_health.bronze.diseases_psa_deaths_national_annual_bronze` | Excel; YAML-provided columns; 2020 field labeled preliminary in its column name |
| `psa_deaths_province_annual` | PSA provincial annual deaths by cause, 2006–2015 | `public_health.bronze.diseases_psa_deaths_province_annual_bronze` | CSV; YAML-provided area/cause and sex-by-year columns |
| `doh_fhsis_tb` | DOH FHSIS TB municipality annual data, 2024 and 2025 | `public_health.bronze.diseases_fhsis_tb_bronze` | Excel files/sheets differ by year; YAML column positions and header checks are configured per file |
| `doh_fhsis_morbidity` | DOH FHSIS heart disease and pneumonia provincial annual data, 2024 | `public_health.bronze.diseases_fhsis_morbidity_bronze` | CSV; YAML-provided age/sex and total/rate columns; different data start rows by file |
| `davao_hospital_pneumonia` | Davao hospital pneumonia admissions, 2017–2025 | `public_health.bronze.diseases_davao_hospital_pneumonia_bronze` | Excel `Sheet1`; required encounter, patient, admission/discharge, diagnosis, location, disposition, and billing fields |
| `philhealth_foi_tb_claims` | PhilHealth FOI pulmonary TB claims, 2017–2019 | `public_health.bronze.diseases_philhealth_tb_claims_bronze` | Excel sheet `Raw`; first two rows skipped; required claim, member, institution, patient, amount, and count fields |
| `psa_deaths_allcause_region_annual` | PSA registered deaths and rates by region, 1992–2023 | `public_health.bronze.diseases_psa_deaths_allcause_region_annual_bronze` | CSV; `header_mode: none`; multi-row/multi-section positional checks |
| `psa_notifiable_national_annual` | PSA notifiable diseases reported cases by cause, 2014–2021 | `public_health.bronze.diseases_psa_notifiable_national_annual_bronze` | CSV; skips two rows before the header; required disease name and year columns |
| `psa_morbidity_leading_national_annual` | PSA leading causes of morbidity, 2016–2018 and 2021–2023 | `public_health.bronze.diseases_psa_morbidity_leading_national_annual_bronze` | Two CSV files; `header_mode: none`; positional layout checks |
| `ihme_gbd` | IHME GBD neoplasms and main causes, provincial annual estimates, 2019–2023 | `public_health.bronze.diseases_ihme_gbd_bronze` | Two CSV files; required measure/location/cause IDs, year, value, upper, and lower fields |

**Source interpretation caution:** these datasets differ in provider, geographic resolution, time period, measure definition, and reporting process. A shared Bronze layer does not make their values directly additive or comparable. Silver reference mapping and metric-specific rules are needed before cross-source analysis.

### 2.3 Source dates and privacy-sensitive inputs

The YAML includes restricted-path inputs for some DOH and PhilHealth datasets, as well as a hospital-level admissions dataset. Access should follow the team's approved permissions and data-handling rules. The loader records the configured `as_of_date`; it does not infer a date from each row unless that date is already a source column.

## 3. Code and Ingestion Flow

### 3.1 Entry point and configuration loading

The script starts a Spark session, prints loader version `2026-10-06.2` and a per-run UUID, then resolves the configuration file. `--config_path` can specify an explicit YAML path. Otherwise, the loader searches the script directory and current working directory, including nearby `config/`, `configs/`, and `conf/` folders up to six directory levels.

The YAML must contain top-level `landing_root` and `sources`. `defaults` are merged with each source entry, with source-specific settings taking precedence. The YAML entry key is the default `source_key`, unless `source_key_override` is supplied. The loader records the entry name separately for diagnostic messages.

### 3.2 Source selection

With no `--source_keys` argument, the default is `ALL`. In that mode the loader selects entries that:

1. have `domain: diseases`;
2. have a non-empty `path`;
3. have a non-empty `bronze_table`; and
4. are not marked `enabled: false`.

A comma-separated `--source_keys` value selects specific YAML keys. Unknown keys raise an error. The current code does not reapply the `loadable()` filter to explicitly selected keys, so explicitly selecting a disabled or other-domain entry may attempt to process it; use the YAML source keys intentionally.

### 3.3 File resolution and per-file settings

For entries with `files:`, the loader resolves each named file under the source path and allows per-file overrides for `format`, `sheet`, `skip_rows`, `data_start_row`, `encoding`, `encoding_errors`, `delimiter`, `as_of_date`, `header_mode`, `columns`, `required_columns`, and `header_check`. For entries without `files:`, it expands the configured path as a glob under `landing_root` and sorts the matches.

Every resolved file must exist and have an `as_of_date` that is a Python `date` value after YAML parsing. If no format is specified, it is inferred from the file extension. The loader fails the source if no files match.

### 3.4 Reading CSV and Excel files

**CSV**

- Uses the configured delimiter, defaulting to a comma.
- Defaults to UTF-8 with strict decoding. UTF-8 is read as `utf-8-sig` to remove a byte-order mark when present.
- `encoding_errors: replace` allows invalid byte sequences to be replaced; replacement characters are counted and reported as a warning in metadata. Other decoding errors stop the source.

**Excel**

- Supports `.xlsx` and `.xlsm` files through `openpyxl`.
- Uses `data_only=True`, so formulas are read from cached values; formulas are not recalculated by the loader.
- Uses the configured sheet, or the first workbook sheet if no sheet is specified. A missing requested sheet is an error.
- Converts date/datetime cells to ISO strings and whole-number floats such as `2016.0` to `2016`.

The input landing files are read only; the script does not modify the original files.

### 3.5 Constructing column names and records

The loader supports three header modes:

- `single`: takes the physical row at `skip_rows` as the header, then reads following rows as data.
- `names`: uses configured `columns`; data begins at `data_start_row`. If a row has more cells than the supplied names, generated names are added for extra positions.
- `none`: generates `col_0`, `col_1`, and so on; data starts at `data_start_row` (or `skip_rows` as fallback).

Column names are cleaned for Delta/Spark compatibility: spaces, commas, semicolons, braces, parentheses, newlines, tabs, equals signs, and periods are replaced with underscores; blank names become `col_N`. Names colliding with lineage column names are prefixed with `src`. Duplicate names are made unique case-insensitively. The first spelling seen across files in the same source is used as the canonical spelling for names that differ only by case.

All values in each data row are converted to strings, with empty and whitespace-only cells converted to null. Fully empty rows are skipped and counted in the log. Rows after the configured data start are otherwise retained, including potential footer/summary rows. Cells beyond the named column width are captured in `_rescued_data` as `_extra_values`, keyed by their column positions; they are not silently discarded.

### 3.6 Pre-load safety checks

All resolved files for a source are read and checked before that source is written:

1. **`header_check`:** validates configured text at specified zero-based row and column positions, using case-insensitive comparison and normalized whitespace. The expected text must be contained in the actual cell.
2. **`required_columns`:** for `header_mode: single`, checks that required names exist after column-name cleaning.
3. **At least one data row:** each file/sheet must yield at least one non-empty data row.

If any of these checks fail, the source raises an error before writing its candidate rows. Header checks are particularly important for reports with title rows, merged headings, or changing layouts. They do not establish that every data value is semantically correct.

### 3.7 Write strategy and reconciliation

After all files for a source pass pre-load checks, their DataFrames are combined using `unionByName(..., allowMissingColumns=True)`. The write uses Delta format and `mergeSchema=true` so additional source columns can be added in Bronze.

- If the target table does not exist, the combined rows are appended to create it.
- If it exists, the loader uses `overwrite` with `replaceWhere` constrained to the current `_source_key` and the set of relative source-file paths. This replaces the rows for those files in one Delta write while leaving other source keys and other files unchanged.
- After writing, it counts rows per source file and compares actual table counts with the number of records read. A mismatch raises an error.

This is a file replacement strategy, not a row-level business-key merge. Selected sources are reloaded on every run; unchanged files are not skipped. The write can already be committed when a later reconciliation or audit step fails, so a failed run should be investigated rather than assumed to have made no changes.

### 3.8 Ingestion metadata

One metadata row is prepared per file/sheet, using the team's shared metadata schema. The record includes run ID, source key, configured `as_of_date` as `source_version`, SHA-256 of the input file bytes, full input path, reconciled record count, retrieval/ingestion timestamp, status, target table, sheet, column count, file size, and any decoding warning.

If ingestion fails, the loader attempts to write a `failed` metadata row with an error message. If the metadata table exists but lacks some expected columns, the loader logs a note and writes only the columns that exist. If metadata logging fails, the Bronze data may remain committed, but the run is marked failed. The script ends with an error if any selected source failed or any audit write failed.

## 4. Bronze Table Design

### 4.1 Table-per-source pattern

The supplied YAML maps each configured source to a separate target table. This preserves source-specific fields and layouts at Bronze rather than forcing all disease datasets into a single schema. The target table names are listed in Section 2.2.

**Grain:** one non-empty input row from a particular source file (and sheet, for Excel), as interpreted by the configured header/data-start rules. The loader does not establish a universal disease-event grain or a common natural key across sources.

### 4.2 Source columns

Source columns vary by input. Depending on configuration, names come from the physical header (`single`), the YAML `columns` list/map (`names`), or generated positions (`none`). All source columns are Spark `STRING` fields, even when values represent years, counts, rates, codes, dates, or amounts. Missing/blank cells are null. Source values are not type-cast or standardized by this loader.

For `header_mode: names`, the configured names are used as the column names for the positional cells; they should be reviewed against the file's actual layout. For `header_mode: none`, generated `col_N` fields are positional and require downstream documentation to interpret them.

### 4.3 Common lineage columns

| Column | Type | Description |
|---|---|---|
| `_rescued_data` | STRING, nullable | JSON containing non-empty cells beyond the last named column, represented under `_extra_values` with their positional indexes |
| `_source_key` | STRING, not null | Logical source key, using `source_key_override` if configured |
| `_source_file` | STRING, not null | File path relative to the configured landing root, as resolved by the loader |
| `_source_sheet` | STRING, nullable | Excel sheet read; null for CSV |
| `_source_row_num` | INT, not null | Zero-based row/record index in the reader output, including skipped/title rows in the index sequence |
| `_as_of_date` | DATE, not null | Configured reference date for the file/sheet |
| `_ingested_at` | TIMESTAMP, not null | Shared UTC-derived ingestion timestamp for all rows in this run |

For CSV, `_source_row_num` counts CSV records rather than physical text lines; a quoted multiline cell is one CSV record. Blank rows are skipped, but their positions remain reflected in subsequent row numbers.

### 4.4 Shared ingestion metadata schema

The loader prepares these metadata fields, subject to the actual existing metadata table schema:

| Column | Intended meaning |
|---|---|
| `batch_id` | One UUID for the loader run, shared across its files |
| `source_name` | YAML source key / resolved source key |
| `source_version` | Configured file `as_of_date`, serialized as ISO date text |
| `endpoint` | Null for file-based sources |
| `content_checksum` | SHA-256 of the file bytes |
| `raw_file_path` | Full landing file path |
| `record_count` | Number of rows written for that file, after reconciliation |
| `page_count` | Null for file-based sources |
| `retrieved_at` | Loader timestamp |
| `status` | `processed` or `failed` |
| `bronze_table` | Target Bronze table |
| `source_sheet` | Excel sheet name, or null for CSV |
| `column_count` | Number of source columns for the file/sheet |
| `file_size_bytes` | Input file size in bytes |
| `error_message` | Error detail or warning, such as replaced undecodable bytes |

The source checksum is used for audit metadata; the Bronze row replacement predicate is based on source key and relative file path, not the checksum. A changed file at the same path replaces the previously loaded rows for that source/file.

## 5. Design Decisions and Rationale

### D1 - Keep source measures as strings in Bronze

- **Context:** Sources mix counts, rates, years, codes, dates, and report-specific text, and source formats can change.
- **Decision:** All source columns are loaded as `STRING`; blanks become null.
- **Rationale:** Prevents premature type assumptions and preserves source representation for Silver validation and conversion.
- **Downstream impact:** Silver must cast values explicitly, document parsing failures, and distinguish missing values from numeric zero.

### D2 - Preserve the landing files and capture extra cells

- **Context:** Spreadsheet and CSV layouts can contain additional cells or change over time.
- **Decision:** The loader does not modify source files and records non-empty cells beyond the configured column width in `_rescued_data`.
- **Rationale:** Retains traceability and reduces silent data loss when a row is wider than expected.
- **Downstream impact:** Investigate rescued values; do not treat their presence as automatically valid analytical fields.

### D3 - Configure header interpretation per source and file

- **Context:** Sources range from ordinary one-row headers to title-heavy reports and workbooks whose layouts vary by year.
- **Decision:** Use `single`, `names`, or `none` modes, with per-file overrides and positional `header_check` assertions.
- **Rationale:** Supports heterogeneous formats without embedding every source's layout in Python code.
- **Downstream impact:** YAML is part of the ingestion contract and should be version-controlled and reviewed when a source publishes a new format.

### D4 - Validate all files for a source before writing

- **Context:** A source may include multiple files or sheets; loading only a subset could create an incomplete table refresh.
- **Decision:** Collect header-check, required-column, and non-empty-data failures across files, then stop the source before the write if any exist.
- **Rationale:** Avoids replacing the selected file set with a partially validated candidate.
- **Downstream impact:** Correct the configuration or source layout before rerunning; do not bypass failed checks without understanding the layout change.

### D5 - Replace selected source files rather than append duplicates

- **Context:** The loader may be rerun for the same files and should not accumulate duplicate copies of their rows.
- **Decision:** Use Delta `replaceWhere` on `_source_key` and `_source_file` for existing tables.
- **Rationale:** Makes a rerun refresh the selected files while preserving other files and sources in the table.
- **Downstream impact:** The relative file path is operationally significant. Renaming a file can leave the old path's rows behind unless those rows are explicitly handled.

### D6 - Reconcile row counts after writing

- **Context:** A successful write call does not by itself prove that the intended number of rows is present per file.
- **Decision:** Compare read counts with persisted counts grouped by source key and file path.
- **Rationale:** Detects incomplete or unexpected file-level writes.
- **Downstream impact:** Investigate reconciliation errors, noting that the write may already have committed before the mismatch is detected.

### D7 - Separate Bronze ingestion from Silver harmonization

- **Context:** Disease datasets have different definitions, geographic coverage, reporting periods, and measures.
- **Decision:** Bronze retains source-shaped tables and does not force them into a universal fact schema.
- **Rationale:** Keeps source fidelity while allowing metric-specific transformations downstream.
- **Downstream impact:** Silver must define disease/measure mappings, time grains, geography resolution, units, denominators, and comparability rules.

### D8 - Audit failure is a run failure

- **Context:** Operational lineage is needed to trace file versions and ingestion outcomes.
- **Decision:** Metadata logging is required for a successful run; an audit failure marks the overall run failed even if Bronze rows were committed.
- **Rationale:** Prevents a run without adequate lineage from being reported as fully successful.
- **Downstream impact:** Check both Bronze table state and metadata after a failed run before retrying.

## 6. Data Quality and Error Handling

### 6.1 Checks implemented by the loader

- Configuration has `landing_root` and `sources`.
- Selected source keys exist in the YAML.
- Source paths resolve to existing files; each file has a valid configured `as_of_date`.
- File format is supported and the configured Excel sheet exists.
- CSV decoding is strict by default; invalid byte sequences fail unless replacement handling is explicitly configured.
- Configured physical header/title text matches expected positions.
- Required named columns are present for `header_mode: single`.
- Each file/sheet yields at least one non-empty data row.
- Source rows are converted to the declared all-string schema, with extra cells captured in `_rescued_data`.
- Post-write row counts reconcile per source file.
- Metadata records are attempted for successful and failed sources.

### 6.2 What the checks do not establish

These controls are ingestion/layout checks, not full analytical data validation. They do not by themselves verify:

- that every count or rate is numeric, non-negative, or within an expected range;
- that disease definitions, units, age bands, or reporting periods match across sources;
- that geographic names/codes are valid or consistently mapped;
- that source totals reconcile to subgroup totals;
- that records are unique at a disease-specific natural key;
- that footer/summary rows retained after `data_start_row` should be included in analysis;
- that Excel formula cached values are current;
- that a configured `as_of_date` represents the same concept for every provider.

These should be handled by source-specific Silver transformations and quality checks. In particular, because footer rows are retained, YAML data-start settings and downstream filters must be checked carefully for reports that contain totals or multiple sections.

### 6.3 Failure and recovery behavior

A pre-load validation failure stops that source before its write. A write/reconciliation failure can occur after a Delta transaction has committed. Metadata failure can also happen after the Bronze write. The script attempts other selected sources after a source exception, summarizes results, and then raises a final `RuntimeError` if any source failed or audit logging failed.

For recovery, inspect the target table by `_source_key` and `_source_file`, compare its row count with the source file and metadata, correct the underlying configuration or file issue, and rerun the intended source. Avoid assuming that a failed process means no Bronze changes occurred.

## 7. Downstream Dependencies and Analytical Impact

### 7.1 Expected consumers

The supplied configuration includes `public_health.silver.diseases_metric_silver` as a Silver target hint. The Bronze loader writes to the configured Bronze tables; it does not build Silver tables or harmonize disease measures.

The configured sources have different layouts and reporting periods. Interpretation and normalization are not performed by the Bronze loader.

## 8. Validation and Reproducibility

### 8.1 Running the loader

```bash
# Run all enabled, loadable disease sources
python diseases_bronze.py

# Run selected YAML source keys only
python diseases_bronze.py --source_keys doh_foi_dengue,upnoah,hdx_dengue

# Print the first 8 raw rows for a source; do not write
python diseases_bronze.py --show_headers 8 --source_keys ihme_gbd

# Use a specific YAML file
python diseases_bronze.py --config_path /Workspace/.../sources_diseases.yaml
```

If `--config_path` is omitted, the script searches near the current working directory and script location for `sources_diseases.yaml`. `--show_headers` reads and prints source rows but exits before ingestion writes. The script uses Spark and PyYAML; Excel inputs require `openpyxl` (the code attempts to install it if unavailable).

### 8.2 Reproducibility notes

- Loader behavior is labeled `2026-10-06.2`; update this version when parsing behavior changes.
- A new UUID is generated per run and shared by its metadata rows.
- The SHA-256 file checksum is stored in metadata, allowing the exact file bytes to be distinguished across runs.
- `_ingested_at` is assigned once per run in UTC-derived timestamp form; it is not a source event timestamp.
- Selected files are reloaded each run; there is no unchanged-file skip optimization.
- YAML file lists, column names, header checks, and `as_of_date` values are part of the reproducible ingestion configuration.

## 9. Open Issues and Future Improvements

1. Confirm that configured input files exist and that required access permissions are in place before running the loader.
2. Document the meaning of `as_of_date` for each source; the loader attaches the configured value but does not define a universal meaning for it.
3. Review per-file header settings, required columns, and row-start settings when source layouts change.
4. Check for retained total, footer, or repeated-header rows where the source configuration starts reading before those rows end.
5. If a file is renamed or removed from the configured file set, review whether rows for its former `_source_file` path need cleanup.
6. After a write or audit failure, inspect both the target Bronze table and ingestion metadata because a failure can occur after data has been committed.

## 10. Change Log

| Version | Change |
|---|---|
| 1.0 | Initial Diseases Bronze documentation based on the supplied `diseases_bronze.py` implementation and `sources_diseases.yaml` configuration. |
