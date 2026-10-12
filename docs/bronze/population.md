# Population Bronze Layer Documentation

## 1. Domain Overview

The Population domain provides population values used as denominators for public-health service-gap analysis. Population data supports comparisons between the number of residents in a geographic area and the recorded availability of hospitals, licensed primary care facilities, and hospital beds.

**Current implementation decision:** the Population Silver layer uses the `populations_json` field from `public_health.bronze.geography_bronze`. The standalone `population_bronze.ipynb` notebook, which ingested separate PSA population workbooks into `public_health.bronze.population_bronze`, is no longer part of the active population ingestion path.

This distinction is important: the legacy notebook is described below only to document the supplied artifact and explain why it should not be treated as the current source for Population Silver.

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

The exact values and optional-field presence depend on the source payload. Bronze preserves the nested source structure rather than converting it into a typed population table.

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

Bronze is responsible for retaining source information and ingestion lineage, not for deciding which population observation is authoritative or converting the nested JSON into the final analytical grain.

Population Silver is responsible for parsing the JSON entries, validating population values and years, associating entries with geographic codes, and creating a structured population dataset.

The population values should not be assumed to be a single current-year value per locality. A source record can contain multiple population entries for different years.

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

This section describes the supplied `01_population_bronze` notebook. It records previous behavior and is not a recommendation to continue using the legacy table.

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

### 5.1 Use the population payload already present in Geography Bronze

Population Silver reads `populations_json` from `public_health.bronze.geography_bronze`. The standalone PSA workbook ingestion notebook is not used for the active pipeline.

### 5.2 Preserve source values in Bronze

The nested JSON is retained in Bronze rather than expanded and cast there. This preserves source details and keeps parsing and validation logic in Silver.

### 5.3 Keep geographic and population observations traceable

Silver should retain the geographic code, population reference year, source/version lineage, and parsing status needed to trace each structured population observation back to the Geography Bronze record.

### 5.4 Treat year and source version as meaningful attributes

A geography record may contain population observations for multiple years. Silver should not collapse these into a single value without an explicit rule. A suitable analytical grain is one geographic code × population year × source version (or other source snapshot identifier used by the implementation).

### 5.5 Do not equate missing population data with zero

A missing, malformed, or absent population entry is not evidence that the area's population is zero. Silver and Gold should preserve the distinction between valid values, missing values, and invalid values.

### 5.6 Separate population reference year from facility snapshot date

Population year and facility registry snapshot date describe different points in time. Gold service-gap outputs should expose these dates clearly rather than implying that population and facility records were collected simultaneously.

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

### 7.1 Population Silver

Population Silver parses the JSON array in `geography_bronze.populations_json` into structured observations. The intended output is:

`public_health.silver.population_silver`

The documented target grain is one PSGC code × population year × source version, with fields such as:
- `psgc_code`
- `population_year`
- `population`
- `population_raw`
- `population_parse_status`
- `source_version`
- `batch_id`
- `silver_processed_at`

Confirm the deployed Silver schema and orchestration before treating this list as an exact implementation contract.

### 7.2 Gold population fact

The Gold model proposes `FACT_POPULATION` at the grain of one area's population for a period and source. Population Silver provides the structured observations needed to build this fact.

Gold should retain source and time context and avoid summing multiple sources or mixing geographic levels. A population value recorded at province level must not be assigned to municipalities without an explicit, reviewed allocation method.

### 7.3 Service-gap analysis

Population denominators support the project’s service-access questions, including:
- Localities with no hospital recorded and their resident population.
- Localities with no licensed primary care facility recorded and their resident population.
- Population per hospital, licensed primary care facility, or hospital bed.

For these measures, begin with the full intended geography denominator and join facility counts at the matching geographic level. Do not infer zero population from a missing record, and do not infer zero facilities merely because no facility row exists when source coverage is incomplete.

### 7.4 Population year selection

For current service-gap analysis, the project has identified the latest observed population year (currently noted as 2024 in the project context) as the preferred denominator, while keeping its reference year explicit. Confirm that the relevant source snapshot actually contains valid 2024 entries before publishing results. Do not automatically fill missing years or extrapolate values without a documented method and quality flags.

## 8. Validation and Reproducibility

For the active path, reproducibility depends on retaining the Geography Bronze source version, checksum, batch, and ingestion metadata alongside the population payload, and on recording the Population Silver processing metadata and parse status.

Useful validation queries/checks include:
- Count geography records with non-null `populations_json`.
- Parse the JSON and count entries by population year.
- Count valid, missing, and invalid population entries.
- Check duplicate rows at the intended Silver grain.
- Compare population-year coverage across geographic levels.
- Reconcile parsed Silver observations with the entries represented in Bronze, accounting for explicitly rejected invalid entries.
- Confirm that Silver runs use `public_health.bronze.geography_bronze` as the population input and do not depend on `public_health.bronze.population_bronze`.

The supplied legacy notebook includes checks for the old workbook table, but those checks do not validate the active Geography Bronze → Population Silver path.

## 9. Open Issues and Follow-up

- Verify the deployed `geography_bronze` schema and confirm that `populations_json` is populated for the expected geography records.
- Verify the Population Silver parser's handling of malformed JSON, missing values, invalid years, and duplicate observations.
- Confirm the exact source-version and batch fields carried into Population Silver.
- Confirm which population year is used in each Gold output and how missing latest-year observations are handled.
- Keep the retired `population_bronze.ipynb` and `population_bronze` table clearly marked as legacy so they are not accidentally reintroduced as a dependency.
- If an alternative population source is introduced later, document its authority, geographic crosswalk, reference year, and precedence rules before combining it with the existing payload.

## 10. Change Log

| Version | Description |
|---|---|
| 1.0 | Initial Population Bronze documentation. Clarifies that the active Population Silver input is `populations_json` from `public_health.bronze.geography_bronze`; documents the supplied standalone population notebook as a retired/legacy path. |
