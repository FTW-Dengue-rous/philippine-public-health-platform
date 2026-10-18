# Population Bronze Layer Documentation

Owner: Margarette Legaspi
Last updated: 2026-10-15

## 1. Domain Overview

The active population input described in this documentation is the `populations_json` field in `public_health.bronze.geography_bronze`. The supplied standalone `01_population_bronze.ipynb` notebook documents a separate workbook-ingestion path to `public_health.bronze.population_bronze`; it is included below as legacy reference, not as the active input to Population Silver.

## 2. Source and Input Data

### 2.1 Active source: `geography_bronze.populations_json`

Population observations are carried inside the records ingested by the Geography Bronze process from the PSGC source. The relevant Bronze table is:

`public_health.bronze.geography_bronze`

The `populations_json` column preserves the source population information as JSON text. The Geography Bronze loader populates it from the source record's `populations` field, falling back to `population_data` when needed.

The JSON array contains population entries with fields such as:

- `id` — source population-entry identifier, when provided.
- `population` — population value as supplied by the source.
- `psgc` — geographic code associated with the population entry.
- `year` — population reference year.

Bronze preserves the nested source structure as JSON text rather than converting it into a typed population table.

### 2.2 Retired input path: `population_bronze.ipynb`

The supplied notebook documents a previous approach that read PSA population Excel workbooks from a configurable landing directory and wrote them to:

`public_health.bronze.population_bronze`

That notebook is **not the active source for Population Silver** under the current project decision. Its workbook ingestion behavior is included here as legacy context only; downstream processing should not depend on `population_bronze` unless the project explicitly reactivates that pipeline.

The notebook expected filenames matching:

`population_<YYYY>_asof_<YYYYMMDD>.xlsx`

For example, the year and as-of date were extracted from the filename, with the date parsed as `_as_of_date`. Files that did not match the pattern were ignored. A `reload_all` widget controlled whether previously loaded files were reloaded.

## 3. Active Bronze Data Design

### 3.1 Where population data resides

Population values are nested in the Geography Bronze record rather than stored in a separate active population Bronze table.

| Item | Current design |
|---|---|
| Bronze table | `public_health.bronze.geography_bronze` |
| Population field | `populations_json` |
| Source structure | JSON array preserved as text |
| Geographic context | Geography record and PSGC-related source fields |
| Type casting and normalization | Population Silver |
| Active input to Population Silver | `geography_bronze.populations_json` |

### 3.2 Preservation principle

Bronze retains the source population payload and its source-record context. Parsing and structuring the nested population entries are downstream tasks. A source record can contain population entries for more than one year.

### 3.3 Relevant Geography Bronze columns

The Geography Bronze table also contains source and lineage fields useful for tracing population data to its source record. Depending on the Geography Bronze schema, these include:

- `psgc_code` — geographic code retained from the source.
- `area_name` — source area name.
- `geographic_level` — source geographic-level value; it may be blank for special cases.
- `populations_json` — nested population entries as JSON text.
- `source_system`, `source_version`, `source_endpoint` — source identification.
- `batch_id`, `content_checksum`, `raw_path`, `ingested_at` — ingestion and reproducibility lineage.
- `source_record_json` — preserved source record, useful when investigating parsing issues.

These fields are listed to explain the active source context; verify them against the deployed table schema before using this document as a schema contract.

## 4. Legacy Notebook Walkthrough (Reference Only)

This section summarizes the supplied `01_population_bronze` notebook for reference.

### 4.1 Parameters and configuration

The notebook defined:
- `landing_path` — directory containing population Excel workbooks.
- `reload_all` — whether to reload files already present in the target table.
- `N_COLS = 14` — positional input width, represented as `c0` through `c13`.
- `FILE_REGEX` — filename convention used to identify year/as-of-date batches.

### 4.2 Legacy table schema

The notebook created `public_health.bronze.population_bronze` if it did not exist, with:
- `c0` through `c13` as `STRING`.
- `_rescued_data` as `STRING`.
- `_source_file` and `_source_sheet` as `STRING`.
- `_source_row_num` as `INT`.
- `_as_of_date` as `DATE`.
- `_ingested_at` as `TIMESTAMP`.

The data columns were positional rather than header-derived. The table comment described the content as raw PSA population files, with one batch per file and no header parsing.

### 4.3 Legacy file discovery and loading

The notebook listed files in the landing directory, selected filenames matching the configured regular expression, parsed the date embedded in the filename, and skipped files already present unless `reload_all` was enabled.

For each selected workbook, it:
1. Listed available sheets.
2. Checked that each sheet did not exceed the configured 14-column width.
3. Read the sheet using Excel file support with header parsing disabled.
4. Assigned row numbers and filtered fully empty rows.
5. Inserted rows while replacing existing rows for the same file and sheet.
6. Added `_as_of_date` and a batch-level `_ingested_at` timestamp.

The notebook included SQL checks for row counts by file/sheet/date, inspection of initial rows, and duplicate combinations of file, sheet, and row number.

### 4.4 Legacy limitations

The supplied notebook does not provide a semantic mapping from `c0`–`c13` to named population fields. It also does not perform population parsing, geographic-code matching, or business-rule validation. Those tasks would have required downstream interpretation of the positional data.

Because this is no longer the active input path, these legacy limitations should not be confused with the current Population Silver design.

## 5. Design Decisions

- **Use the Geography Bronze payload for the active path:** Population Silver reads `populations_json` from `public_health.bronze.geography_bronze`.
- **Preserve the source structure in Bronze:** the population array remains JSON text rather than being expanded into population rows in Bronze.
- **Retain year and source context downstream:** population entries may represent different years and should not be collapsed without an explicit rule.
- **Distinguish missing data from zero:** an absent or invalid population entry does not establish that the population is zero.
- **Keep population year separate from facility snapshot dates:** these fields describe different time references.

## 6. Data Quality and Error Handling

The active Geography Bronze loader validates its landing batch and preserves `populations_json` from the source record. Population-specific semantic checks belong in Silver.

Recommended Population Silver checks include:

- Confirm that `populations_json` can be parsed as the expected JSON structure.
- Validate that each population entry has a usable year and population value before treating it as a valid observation.
- Preserve parse outcomes, such as `VALID`, `MISSING`, and `INVALID`, instead of silently dropping malformed or absent entries.
- Validate that population values can be converted to the intended numeric type and are within an acceptable domain.
- Check whether population-entry PSGC codes are present and consistent with the intended geography key.
- Identify duplicate observations at the chosen geographic-code, population-year, and source-version grain.
- Report observed population years and unexpected year/value patterns for review.

These are recommended Silver-side controls; this document does not claim that each check is already implemented or has passed.

## 7. Downstream Dependencies and Analytical Impact

Population Silver uses `populations_json` from `public_health.bronze.geography_bronze` as its population input. The documentation identifies `public_health.silver.population_silver` as the intended structured output, with population observations parsed from the JSON array.

The supplied Bronze notebook does not implement Population Silver parsing, Gold population facts, service-gap calculations, or population-year selection. Those behaviors should be documented against their respective implementation files.

## 8. Validation and Reproducibility

The legacy notebook includes checks for the old workbook table, including row counts by file, sheet, and date; sample-row inspection; and duplicate combinations of file, sheet, and row number. These checks apply to the legacy workbook path, not to the active Geography Bronze → Population Silver path.

For the active path, verify the source table and `populations_json` content against the relevant Geography Bronze and Population Silver implementation and deployed schemas.

## 9. Open Issues and Follow-up

- Verify that `public_health.bronze.geography_bronze` contains the expected `populations_json` values.
- Confirm Population Silver parsing and validation behavior in its implementation.
- Confirm the source-version and batch lineage fields carried from Bronze into Silver.
- Keep the standalone workbook notebook and `public_health.bronze.population_bronze` identified as legacy unless that path is explicitly reactivated.

## 10. Change Log

| Version | Description |
|---|---|
| 1.0 | Initial Population Bronze documentation. Clarifies that the active Population Silver input is `populations_json` from `public_health.bronze.geography_bronze`; documents the supplied standalone population notebook as a retired/legacy path. |
