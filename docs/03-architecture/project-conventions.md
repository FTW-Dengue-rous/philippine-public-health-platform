# Project conventions

Owner: Jemma Santiago
Last updated: 2026-10-18

## Naming

| Item | Convention | Example |
|---|---|---|
| Bronze tables | `<domain>_<source>_<content>_bronze` | `facilities_doh_nhfr_hospitals_bronze` |
| Silver tables | `<domain>_<entity>_silver` | `facilities_registry_silver` |
| Gold tables | `mart_<name>` or `fact_<name>` / `dim_<name>` | `mart_area_service_profile` |
| Source keys | Folder name, nested joined by `_`. Never changed once in use. | `doh_hfsrb_hospitals` |
| Lineage columns | Start with `_` | `_source_key`, `_silver_build_id` |
| Per-source lineage in combined rows | `_<side>_<name>` | `_nhfr_source_row_num` |
| SQL files | `<domain>_silver_<NN>_<name>.sql` | `facilities_silver_01_registry.sql` |
| Config files | `sources_<domain>.yaml` | `sources_facilities.yaml` |

## Bronze

* Every data column is STRING. Typing happens in silver.
* Original column names from the file are kept. Only characters Delta does not allow (space, `,`, `;`, `{}`, `()`, `=`, tab, newline) become `_`.
* Renaming to standard names happens in silver via `column_map`.
* Lineage columns added by the loader: `_rescued_data`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_ingested_at`.
* `as_of_date` = date the file was downloaded or released, NOT load time.
* One folder = one layout = one bronze table.

## Silver

* One row per business grain (e.g. one facility, one area × year × ownership × source).
* Lineage columns per the [shared contract](../lineage-qc-contract_v1.3.md): `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_metric_source_columns`.
* Load-time facts (load batch id, checksum, build time) are stored once per build in `build_inputs` and `build_log`, not on every row.
* `row_disposition` stores only rows that were NOT loaded (dropped, duplicate, quarantined, merged).
* Builds use `CREATE OR REPLACE` for the complete new state. If validation fails, the target table is left unchanged.

## SQL

* Files are numbered by execution order within a domain (`00_reference`, `01_registry`, `02_metric`, etc.).
* Each silver build script declares its inputs, captures them, validates, writes, and records the build.
* Text normalization functions (e.g. `fac_norm`, `fac_place`) are defined as `CREATE OR REPLACE TEMPORARY FUNCTION` at the top of the script that uses them.

## Python

* Bronze loaders are config-driven: one script per domain reads the YAML and loads all sources.
* `run_bronze.py` is the single entry point: runs the loader then bronze QC for each domain.
* `dq_utils.py` provides `DQRun` for writing quality check results to `qc_results`.

## Git

* Branch from `dev`, PR into `dev`, merge to `main` at milestones.
* PR titles: `type: description` (feat, fix, docs, test, ci, chore, refactor).
* Pre-commit hooks: ruff lint + format, end-of-file newline, trailing whitespace, sqlfluff, nbstripout, gitleaks.
* Never commit secrets, full datasets, or notebook outputs.

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for the full workflow.
