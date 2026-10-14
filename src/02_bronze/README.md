# Bronze ingestion

This page explains how source files move into `public_health.bronze` for the diseases, facilities, workforce and socioeconomic domains.

It covers:

- landing folders and file naming
- the config-driven Bronze loaders
- Bronze row structure and lineage columns
- `ingestion_metadata`
- Bronze QC
- the Bronze table inventory

Teammates own the geography (PSGC and HDX boundaries) and population Bronze pipelines, so this page does not cover them. See [silver-geography-population.md](silver-geography-population.md).

## Status

| Item | Status |
| --- | --- |
| Config-driven loader design (one `sources_<domain>.yaml` per domain) | Designed on 2026-10-06. All four domains moved away from per-dataset loader code on this date |
| Loaders `<domain>_bronze.py` (version `2026-10-06.2`) | Tested on local Spark on 2026-10-05 and 2026-10-06 using Parquet as a stand-in for Delta |
| Diseases Bronze, 16 tables, 26 files | Earlier loader ran on Databricks for 20 files across 12 tables. 6 files were still pending on 2026-10-06 |
| Facilities Bronze, 15 tables, 32 files | Earlier loader ran on Databricks for 30 files. 2 files were still pending on 2026-10-06 |
| Workforce Bronze, 3 tables, 10 files | Earlier loader ran on Databricks for 9 files. 1 file was still pending on 2026-10-06 |
| Socioeconomic Bronze, 5 tables, 5 files | Tested on local Spark on 2026-10-05. No Databricks run was recorded as of 2026-10-06 |
| Diseases Bronze, later state | Team record says Bronze was complete on 2026-10-05. Bronze QC ran on Databricks for 16 sources on 2026-10-07. See [validation.md](validation.md) |
| Facilities Bronze, later state | Team record says the config-driven rerun finished for all 15 sources on 2026-10-07 |
| Workforce Bronze, later state | Team record says Workforce Bronze was complete on 2026-10-05 |
| All domains, later state | Team record from 2026-10-07 says all Bronze files were believed loaded. This page does not confirm that per table. Owners should replace these notes with dated run results after confirmation |
| `ingestion_metadata.sql` (shared 15-column table) | SQL written on 2026-10-05. No Databricks run status was recorded |
| Bronze QC scripts `<domain>_bronze_qc.py` | Tested on local Spark on 2026-10-05. No Databricks run status was recorded |
| Bronze tables frozen | Team decision on 2026-10-08: no more changes to the Bronze table design |
| Incremental loading (loader `2026-10-14.1`) and `run_bronze.py` | Written on 2026-10-14. Tested on local Spark with Parquet as a stand-in for Delta. Tests used the real 2025 FHSIS TB workbook and Healthsites files and covered new, unchanged, changed, re-dated, forced, failed-then-fixed, deleted-row, missing-checksum and YAML-removed-file cases. Not yet run on Databricks |

## Sources

Each row below represents one or more entries in a `sources_<domain>.yaml` file. The YAML entry name is the `source_key`.

| Domain | Source key(s) | What it holds | Notes |
| --- | --- | --- | --- |
| Diseases | `doh_foi_dengue` | DOH dengue cases and deaths, region by month, Jan 2021 to Sep 2025 | Restricted (eFOI). 2025 is a partial year |
| Diseases | `upnoah` | UP NOAH dengue, region by week, 2016 to 2019 and 2022 to 2025 | Open, ODbL. Sheet `Regional Data` |
| Diseases | `hdx_dengue` | HDX dengue cases and deaths, province by week, 2016 to 2021 | Open, CC BY. Two files; the 2021 file repeats rows from the first |
| Diseases | `doh_foi_tb_region2` | DOH Region II TB tables, 2020 to 2025 | Restricted (eFOI). Seven stacked tables. Bronze only |
| Diseases | `psa_deaths_national_monthly`, `psa_deaths_region_annual`, `psa_deaths_national_annual`, `psa_deaths_province_annual` | PSA registered deaths by cause, with one YAML entry per layout | Open. Year comes from `_source_file` |
| Diseases | `psa_deaths_allcause_region_annual`, `psa_notifiable_national_annual`, `psa_morbidity_leading_national_annual` | PSA yearbook tables 9.5, 9.15, 9.12 and 9.13 | Open. Stacked or wide layouts |
| Diseases | `doh_fhsis_tb`, `doh_fhsis_morbidity` | FHSIS TB notifications for 2024 to 2025, plus heart disease and pneumonia for 2024 | Public. Both write `_source_key = doh_fhsis` |
| Diseases | `davao_hospital_pneumonia` | Pneumonia admissions from one government hospital, patient level | Restricted. De-identified extract |
| Diseases | `philhealth_foi_tb_claims` | PhilHealth TB claims, 2017 to 2019 | Restricted (eFOI). Bronze only |
| Diseases | `ihme_gbd` | IHME GBD 2023 modelled deaths and prevalence, province by year, 2019 to 2023 | Restricted by licence. Non-commercial use only; no redistribution |
| Facilities | `doh_nhfr` | NHFR active hospitals with PSGC codes, as of 2026-09-29 | Public. Hospitals only |
| Facilities | `doh_hfsrb_hospitals`, `doh_hfsrb_infirmaries`, `doh_hfsrb_primary_care`, `doh_hfsrb_dialysis_clinics`, `doh_hfsrb_blood_service` | DOH HFSRB licensed facility lists, as of 2026-06-30 | Public. Government and Private sheets only |
| Facilities | `hdx_healthsites` | OpenStreetMap health facility points from healthsites.io | Open, ODbL. Has coordinates but no PSGC |
| Facilities | `psa_hospitals_region_annual`, `psa_beds_region_annual`, `psa_hospitals_national_annual`, `psa_bhs_region_annual`, `psa_hospitals_beds_national_annual`, `psa_hospitals_region_annual_legacy` | PSA hospital, bed and barangay health station tables | Open. Two layouts exist for hospitals by region |
| Facilities | `bed_occupancy` | Bed occupancy rate by hospital, 2020 to 2025 | Restricted. Source and permission are still marked CONFIRM |
| Facilities | `doh_fhsis_demographic` | FHSIS `BGY & BHS` tab, 2018 to 2025 | Public. Reads workbooks landed under `workforce/` |
| Workforce | `doh_fhsis_demographic` | FHSIS health worker tabs, 2018 to 2025, 18 sheets | Public. Layout changes by year |
| Workforce | `psa_gov_practitioners` | PSA Table 9.14 government practitioners, region by year, 2012 to 2023 | Open. Used as the history source for 2012 to 2017 |
| Workforce | `psmo_oncologists` | PSMO medical oncologist counts by area, one snapshot | Open. Pull date is marked CONFIRM |
| Socioeconomic | `psa_poverty` | PSA poverty threshold, poverty incidence and poor population, 2021, 2023 and 2025 | Open. Sheets `tab2` and `tab6` |
| Socioeconomic | `psa_health_expenditure_share_national_annual`, `psa_health_expenditure_per_capita_national_annual` | PSA yearbook tables 9.26 and 9.24, 2016 to 2023 | Open |
| Socioeconomic | `psa_child_mortality` | PSA Table 9.9, NDHS 2017 and 2022 | Open. Encoding: cp1252 |
| Socioeconomic | `psa_psgc` | PSGC datafile with income class, urban/rural classification and 2024 population | Open. Geography owns the file. It is landed under `geography/psa_psgc/` |

## Tables

### Landing layout and naming

- Landing root: `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`
- Folder pattern: `<domain>/<source>/[<geo>_<grain>/]`
- One folder represents one layout and one Bronze table.
- Restricted files stay under `<domain>/restricted/`. Do not commit them to GitHub.
- Table-by-period files use `{source}_{content}_{geo}_{grain}_{years}.{ext}`.
- Snapshot files use `{source}_{content}_{geo}_asof_{yyyymmdd}.{ext}`.
- Bronze tables use `public_health.bronze.<domain>_<source>_<content>_bronze`.
- Example: `diseases_upnoah_dengue_regional_bronze`
- Config files: `config/sources_<domain>.yaml`
- Loader code: `src/02_bronze/<domain>_bronze.py`
- QC code: `src/02_bronze/<domain>_bronze_qc.py`

### Bronze row shape

One Bronze row represents one data row from one source file or sheet.

Bronze has no business key. The combination of `_source_key`, `_source_file`, `_source_sheet` and `_source_row_num` identifies the source row.

The loader keeps every data column as a string and adds these lineage columns:

| Column | Holds |
| --- | --- |
| `_source_key` | YAML entry key, or `source_key_override` |
| `_source_file` | File path under the landing root. The loader also uses this as the replacement unit on reruns |
| `_source_sheet` | Excel sheet name. Null for CSV files |
| `_source_row_num` | 0-based row number in the file or sheet |
| `_as_of_date` | Release or download date from the YAML. This is not the load time |
| `_ingested_at` | Load timestamp in UTC. The same timestamp is used for the whole run |
| `_rescued_data` | Values found beyond the last named column, with their positions |

### `public_health.bronze.ingestion_metadata`

`ingestion_metadata` is append-only.

For file ingestion, one row represents one file or sheet that the loader processed or attempted to process. The table is also shared with the API ingestion job.

Silver reads this table to get the load id and file checksum.

| Column | File loads write |
| --- | --- |
| `batch_id` | One id per loader run. All files in the run share it |
| `source_name`, `source_version` | YAML source key and the file's `as_of_date` as text |
| `endpoint`, `page_count` | Used by API loads only. Null for file loads |
| `content_checksum` | SHA-256 checksum of the file |
| `raw_file_path` | File path in the landing area |
| `record_count` | Rows written to Bronze after reconciliation |
| `retrieved_at` | Load time in UTC |
| `status` | `processed`, `failed` or `skipped_duplicate`. `skipped_duplicate` means the file has not changed since its last load; `error_message` identifies that earlier load. The API job also uses `in_progress` |
| `bronze_table`, `source_sheet`, `column_count`, `file_size_bytes` | Target table, sheet, number of data columns and file size |
| `error_message` | Error details on failure, or a warning attached to a processed row such as replaced bytes |

### Inventory (39 tables, 73 files)

The table names below omit the `public_health.bronze.` prefix.

`Sharing` comes from the YAML `sharing` field.

| Domain | Bronze table | Source | Grain or note | Sharing |
| --- | --- | --- | --- | --- |
| Diseases | `diseases_doh_foi_dengue_bronze` | DOH eFOI | Region by month | restricted |
| Diseases | `diseases_upnoah_dengue_regional_bronze` | UP NOAH | Region by week | open |
| Diseases | `diseases_hdx_dengue_bronze` | HDX | Province by week, 2 files | open |
| Diseases | `diseases_doh_foi_tb_region2_bronze` | DOH eFOI | Stacked tables, `col_n` names, Bronze only | restricted |
| Diseases | `diseases_psa_deaths_national_monthly_bronze` | PSA | National by month, 5 files | open |
| Diseases | `diseases_psa_deaths_region_annual_bronze` | PSA OpenSTAT | Region by year, with age groups | open |
| Diseases | `diseases_psa_deaths_national_annual_bronze` | PSA | National by year, 2015 to 2020 | open |
| Diseases | `diseases_psa_deaths_province_annual_bronze` | PSA | Province and region by year, by sex | open |
| Diseases | `diseases_fhsis_tb_bronze` | DOH FHSIS | Municipality by year | public |
| Diseases | `diseases_fhsis_morbidity_bronze` | DOH FHSIS | Province by year, 2024 | public |
| Diseases | `diseases_davao_hospital_pneumonia_bronze` | Shared hospital extract | Patient level | restricted |
| Diseases | `diseases_philhealth_tb_claims_bronze` | PhilHealth eFOI | Claims rows, Bronze only | restricted |
| Diseases | `diseases_psa_deaths_allcause_region_annual_bronze` | PSA Table 9.5 | Region by year, two stacked blocks | open |
| Diseases | `diseases_psa_notifiable_national_annual_bronze` | PSA Table 9.15 | National, years as columns | open |
| Diseases | `diseases_psa_morbidity_leading_national_annual_bronze` | PSA Tables 9.12 and 9.13 | National, one block per year | open |
| Diseases | `diseases_ihme_gbd_bronze` | IHME GBD 2023 | Province by year, modelled | restricted |
| Facilities | `facilities_nhfr_bronze` | DOH NHFR | One row per hospital | public |
| Facilities | `facilities_hfsrb_hospitals_bronze` | DOH HFSRB | One row per licensed hospital | public |
| Facilities | `facilities_hfsrb_infirmaries_bronze` | DOH HFSRB | One row per infirmary | public |
| Facilities | `facilities_hfsrb_primary_care_bronze` | DOH HFSRB | One row per primary care facility | public |
| Facilities | `facilities_hfsrb_dialysis_clinics_bronze` | DOH HFSRB | One row per dialysis clinic | public |
| Facilities | `facilities_hfsrb_blood_service_bronze` | DOH HFSRB | One row per blood service facility | public |
| Facilities | `facilities_hdx_healthsites_bronze` | HDX, healthsites.io | One row per OSM point | open |
| Facilities | `facilities_psa_hospitals_region_annual_bronze` | PSA Table 9.18 | Region, wide by ownership and year, 2020 to 2024 | open |
| Facilities | `facilities_psa_beds_region_annual_bronze` | PSA Table 9.17 | Region, wide by ownership and year, 2020 to 2024 | open |
| Facilities | `facilities_psa_hospitals_national_annual_bronze` | PSA OpenSTAT | National by year, 2006 to 2015 | open |
| Facilities | `facilities_psa_bhs_region_annual_bronze` | PSA Table 9.19 | Year rows, one column per region | open |
| Facilities | `facilities_bed_occupancy_bronze` | Source marked CONFIRM | One row per hospital; year is the sheet | restricted |
| Facilities | `facilities_fhsis_primary_care_bronze` | DOH FHSIS | Area by year, 2018 to 2025 | public |
| Facilities | `facilities_psa_hospitals_beds_national_annual_bronze` | PSA Table 9.16 | National by year, 1990 to 2015 | open |
| Facilities | `facilities_psa_hospitals_region_annual_legacy_bronze` | PSA Table 9.17 (PSY 2024) | Transposed layout, 2005 to 2015 | open |
| Workforce | `workforce_fhsis_health_workers_bronze` | DOH FHSIS | Area by year, one row set per sheet | public |
| Workforce | `workforce_psa_gov_practitioners_bronze` | PSA Table 9.14 | Region by profession, years as columns | open |
| Workforce | `workforce_psmo_oncologists_bronze` | PSMO directory | Area snapshot | open |
| Socioeconomic | `socioeconomic_psa_poverty_bronze` | PSA poverty statistics | Region and province, 2 sheets | open |
| Socioeconomic | `socioeconomic_psa_health_expenditure_share_bronze` | PSA Table 9.26 | National, financing agent rows | open |
| Socioeconomic | `socioeconomic_psa_health_expenditure_per_capita_bronze` | PSA Table 9.24 | National, indicator rows | open |
| Socioeconomic | `socioeconomic_psa_child_mortality_bronze` | PSA Table 9.9 | Region and background characteristic | open |
| Socioeconomic | `socioeconomic_psa_psgc_bronze` | PSA PSGC datafile | One row per geographic unit | open |

## Rules

- **Keep source-specific settings in YAML, not in the loader code.** Each source has one YAML entry. It defines the source identity, file location, read settings, contract checks, target table, Silver hints, `sharing`, QC settings and notes. The four domain loaders use the same logic. Only `CONFIG_NAMES`, `DOMAIN` and domain-specific text differ.

- **Keep source values as text in Bronze.** Bronze does not cast values, clean business fields, match geography or choose a preferred source. Silver and Gold handle those steps.

- **Use real column names when the source layout allows it.**
  - `header_mode: single` uses the file header.
  - `names` uses YAML column names by position.
  - `none` creates `col_0`, `col_1`, ... and is used only for stacked layouts.

- **Clean column names only as needed for Delta.** Replace unsupported characters and `.` with `_`. Make duplicate names unique without relying on case.

- **Use the same extraction rules across sources.** Convert empty cells to null. Skip and count fully empty rows. Store Excel dates as ISO text. Remove `.0` from whole-number floats. Read formulas from their saved results. Keep footer and note rows in Bronze; Silver removes them when needed.

- **Never edit landing files.** Add a newer snapshot as a new file in the same folder. Put a different layout in its own folder and Bronze table.

- **Run contract checks before writing.** Run `header_check`, `required_columns`, strict decoding and the non-empty-data check for all files in a source first. If any check fails, write nothing for that source.

- **Replace only the affected source files.** Use Delta `replaceWhere` on `_source_key` and `_source_file`, with `mergeSchema`, in one transaction. The first write appends. Incremental loading writes only new or changed files.

- **Reconcile after the write.** Count Bronze rows for each file and make sure they match the rows read. Then append one `ingestion_metadata` row per file or sheet. If metadata logging fails, keep the committed Bronze data but fail the run.

- **Treat `load_mode` as a Silver hint.**
  - `upsert`: Silver keeps the latest `_as_of_date` per merge key.
  - `latest_file`: Silver keeps only the newest snapshot.
  - Bronze still keeps every file listed in the YAML.

- **Use `sharing` to record data-handling intent.** Allowed values are `open`, `public` and `restricted`. This field does not enforce access control by itself. Restricted sources include FOI files, the patient-level hospital extract, the bed occupancy file and IHME GBD. Do not copy record-level values from restricted tables into documentation or GitHub.

- **Bronze table design is frozen as of 2026-10-08.** Bronze rows do not store a load id or checksum. Silver gets both from `ingestion_metadata` using `batch_id` and `content_checksum`. See [lineage-qc-contract.md](lineage-qc-contract.md).

## Incremental loading

Loader `2026-10-14.1` adds incremental loading.

For each listed file or sheet, the loader checks the latest `processed` row in `ingestion_metadata`. It reloads only when something relevant changed.

If a file has not changed, the loader keeps its existing Bronze rows and `_ingested_at`. This also lets Silver keep using the same source load.

This replaces the 2026-10-06 decision to reload unchanged files. After the incident 3 fix, `ingestion_metadata` stores both `content_checksum` and `source_sheet`, so incremental loading does not need another Bronze column.

| Reason | Detected by | Action |
| --- | --- | --- |
| `new` | No `processed` row exists for the same source, file path, sheet and Bronze table | Load |
| `content_changed` | SHA-256 differs from the logged `content_checksum` | Reload that file |
| `as_of_date_changed` | YAML `as_of_date` differs from the logged `source_version` | Reload that file |
| `bronze_rows_differ` | Bronze no longer contains exactly the rows from that load | Reload that file |
| `no_checksum_logged` | The previous processed row has no checksum, usually from loads before 2026-10-07 | Reload once |
| `forced` | `--force true`, or the source is listed in `--force_keys` | Reload all files for that source |
| unchanged | None of the reload conditions apply | Skip and log `skipped_duplicate` |

Additional rules:

- Treat a workbook configured by sheet as one reload unit. Bronze replaces rows by file, so if one configured sheet needs a reload, reload all configured sheets for that workbook entry.
- The loader does **not** detect changes to YAML parsing settings such as `columns`, `data_start_row` or `header_check`. It also does not detect loader code changes. Use `--force_keys` after these changes.
- If you remove a file from the YAML, the loader reports it but keeps its existing Bronze rows. Delete those rows only as an intentional cleanup.
- If a source fails before the write, Bronze does not change for that source. The next run tries it again.
- Use `--plan true` to print `LOAD` or `skip` and the reason for each file without writing anything.

## Run order

1. Run `ingestion_metadata.sql` once to create the shared metadata table.
2. Run `quality_setup.sql` once to create the `public_health.quality` tables used by `dq_utils.DQRun`.
3. Upload source files to the landing folders and update `config/sources_<domain>.yaml`.
4. Run `run_bronze.py --plan true` to preview the load.
5. Run `run_bronze.py` to execute Bronze ingestion and QC.
   - It runs `<domain>_bronze.py` incrementally for each selected domain.
   - It then runs `<domain>_bronze_qc.py` for sources that loaded.
   - Any QC `FAIL` stops the job before Silver.
   - Available options include `--domains`, `--source_keys`, `--force_keys` and `--qc false`.
6. You can also run a domain loader directly. Use `<domain>_bronze.py` with options such as `--source_keys`, `--plan true`, `--force_keys` or `--show_headers N`.
7. If the summary shows that Bronze changed for a domain, rerun that domain's Silver reference/build steps and Silver QC. Then rerun Gold.

## Checks

Loader checks run before or immediately after the write.

Bronze QC runs on the stored tables. It reads the `qc` settings from each YAML entry and writes results through `dq_utils.DQRun` into `public_health.quality`.

| Check | Severity | Quality attribute |
| --- | --- | --- |
| Loader: `header_check` (expected text at expected positions) | FAIL | validity |
| Loader: `required_columns` present | FAIL | validity |
| Loader: strict decoding | FAIL | accuracy |
| Loader: at least one data row per file | FAIL | completeness |
| Loader: rows in table equal rows read, per file | FAIL | completeness |
| Loader: `ingestion_metadata` row written | FAIL | auditability |
| `table_not_empty` | FAIL | completeness |
| `all_files_loaded` | FAIL | completeness |
| `row_count_match` | FAIL | completeness |
| `required_column_present` | FAIL | validity |
| `lineage_not_null` | FAIL | auditability |
| `row_num_unique` | FAIL | uniqueness |
| `no_empty_rows` | WARN | completeness |
| `no_duplicate_rows` | WARN | uniqueness |
| `no_rescued_data` | WARN | validity |
| `numeric_parsable` | WARN | validity |
| `control_total_match`, `control_value_match` | FAIL | accuracy |
| `row_sum_match` | FAIL | consistency |

A YAML entry can disable a check with `skip_checks`. For example, disable `B08` when repeated rows are expected. A YAML entry can also override the check severity.

## Results so far

- **2026-10-04:** First Databricks run for diseases, with 12 sources at that time. Five sources loaded. Five failed because `openpyxl` was missing. Two failed because files were missing. The run created tables under old names without the `diseases_` prefix.
- **2026-10-05:** Local PySpark 4.2 test using Parquet instead of Delta. All 13 facilities sources available at that time loaded and passed QC. Socioeconomic control values also passed locally.
- **2026-10-06:** The earlier loader loaded 59 of 73 files on Databricks. Fourteen files remained: 6 diseases, 2 facilities, 1 workforce and 5 socioeconomic.
- **2026-10-06:** Local tests for the new diseases, facilities and PSMO entries passed `header_check`, reconciled successfully and reran without creating duplicates.
- **2026-10-07:** `header_check` passed against the real files for diseases entries 13 to 16, workforce entries 1 and 2, and all 5 socioeconomic entries.
- The expected diseases total after a full rerun is **16 tables and 184,737 rows**. This is an expected total, not a recorded Databricks result.

## Known limits

- The project does not record a complete Databricks rerun using the new loader. The 2026-10-06 plan was to drop the 12 diseases tables, rerun all diseases sources, then rerun `hdx_dengue`.
- `replaceWhere` with `mergeSchema` was tested locally using Parquet. The project material does not confirm this behavior on Databricks Delta.
- The project does not record a Databricks run for Bronze QC. This was still open on 2026-10-06.
- `sharing: restricted` records intent only. Unity Catalog grants for restricted tables still need to be applied.
- Facilities entries 1 to 13 do not yet have `header_check`. A shifted column in these `names` layouts could load under the wrong name.
- `_as_of_date` is not fully consistent. Some entries use release dates and others use download dates. Many are still marked CONFIRM in the YAML.
- The loaders read files on the driver. The largest file is the PhilHealth claims workbook at 245,405 rows and 12 MB.
- On the first incremental run in a workspace, the loader reloads files whose latest `processed` row has no checksum or sheet. These are usually loads made before the incident 3 fix. Later unchanged runs are skipped.
- The same loader logic is copied into four domain files. Apply shared fixes to all four.
- Older handoff notes and newer configs do not always agree. The 2026-10-04 and 2026-10-05 notes list 12 diseases, 13 facilities and 2 workforce sources and describe a delete-then-append rerun. This page follows the newer design and YAML files: 16 diseases sources, 15 facilities sources, 3 workforce sources and `replaceWhere`.
- `sources_facilities.yaml` still points to `public_health.bronze.qc_results` as its QC table and marks it CONFIRM. The other configs and the team decision use `dq_utils.DQRun` with `public_health.quality`. This page follows that newer approach.
- Folder names are not fully consistent across project files. The facilities YAML uses `psa_hospitals/regional_annual_legacy` and `facilities/restricted`. The design and handoff notes use `region_annual_legacy` and `restricted/bed_occupancy/`.
- `socioeconomic_psa_psgc_bronze` reads a geography-owned source file. Disable this YAML entry if the geography loader already ingests the same file.

## Handoff to Gold

- Gold does not read Bronze directly.
- Silver reads Bronze, keeps the required lineage and passes that lineage forward.
- See [silver-diseases.md](silver-diseases.md), [silver-facilities.md](silver-facilities.md), [silver-workforce.md](silver-workforce.md), [silver-socioeconomic.md](silver-socioeconomic.md) and [gold-model.md](gold-model.md).
- Gold must not read landing files again.
- Gold must not recast the original source text.
- Gold must not recreate load ids. Silver and `ingestion_metadata` provide them.
- Gold must follow the `sharing` rules. Do not export row-level restricted data. Use IHME values only with the required attribution line.
