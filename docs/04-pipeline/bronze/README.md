# Bronze layer

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

The bronze layer preserves raw source data with no transformations. Every data column is STRING. The loader adds lineage columns.

## How it works

Each domain has one bronze loader script in `src/02_bronze/`:

| Domain | Loader | Config |
|---|---|---|
| Facilities | `facilities_bronze.py` | `config/sources_facilities.yaml` |
| Diseases | `diseases_bronze.py` | `config/sources_diseases.yaml` |
| Workforce | `workforce_bronze.py` | `config/sources_workforce.yaml` |
| Socioeconomic | `socioeconomic_bronze.py` | `config/sources_socioeconomic.yaml` |
| Geography | `geography_bronze.py` | `config/sources_geography.yaml` |
| Admin boundaries | `admin_boundaries_bronze.py` | `config/sources_geography.yaml` |

For diseases, facilities, workforce, and socioeconomic, `run_bronze.py` is the single entry point. It runs the loader (incremental: only new or changed files) then bronze QC for the sources that actually loaded.

Geography and admin boundaries have their own loader and QC tasks.

## Bronze columns

Every bronze table has:

* Original data columns (all STRING, names cleaned for Delta compatibility)
* `_rescued_data` — values that could not be parsed to the declared schema (if any)
* `_source_key` — which source (YAML entry name)
* `_source_file` — file path relative to landing root
* `_source_sheet` — sheet name (null for CSV)
* `_source_row_num` — 0-based row number in the source file
* `_as_of_date` — date the file was downloaded or released
* `_ingested_at` — timestamp when the bronze row was written

## Incremental loading

The loader is incremental: only new or changed files load. Unchanged files are skipped, so bronze rows and load IDs stay the same and silver built from them stays fresh. Use `--force` or `--force_keys` to reload in full (after a YAML or loader change).

## Ingestion-contract checks

The loader runs checks before writing anything:

* `header_check` — title/header rows must contain expected text at expected positions. Stops on mismatch.
* `required_columns` — for `header_mode: single`, required header names must exist.
* `encoding_errors: strict` — stops on encoding errors. Set `replace` to load anyway.
* Each file must give at least one data row. After write, rows per file must equal rows read.

## Bronze QC

Bronze QC scripts live in `src/05_quality/bronze/`. They check:

* Row counts match expected (where configured)
* Control totals match (e.g. dengue cases per year)
* No nulls in key columns
* Numeric columns are numeric

A QC FAIL (ERROR severity) raises an exception via `dq_utils.DQRun` and fails the task, stopping downstream execution.

See [bronze quality checks](bronze-quality-checks.md) for the check catalog.
