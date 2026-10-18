# Facilities Bronze Layer Documentation

Owner: Cristina Villota, Via Cabuyao
Last updated: 2026-10-15

## Overview

The facilities bronze layer loads 15 source files into Delta tables in `public_health.bronze.facilities_*`. The loader is `src/02_bronze/facilities_bronze.py`, called by `run_bronze.py --domains facilities`. Config is in `config/sources_facilities.yaml`.

## Sources

| Source key | Provider | Format | Coverage | Bronze table | Expected rows |
|---|---|---|---|---|---|
| `doh_nhfr_hospitals` | DOH NHFR | CSV | All registered hospitals (snapshot 2026-09-29) | `facilities_doh_nhfr_hospitals_bronze` | ~3,000 |
| `doh_hfsrb_hospitals` | DOH HFSRB | XLSX | Licensed hospitals (2026-06-30) | `facilities_doh_hfsrb_hospitals_bronze` | ~1,400 |
| `doh_hfsrb_infirmaries` | DOH HFSRB | XLSX | Licensed infirmaries | `facilities_doh_hfsrb_infirmaries_bronze` | ~130 |
| `doh_hfsrb_primary_care` | DOH HFSRB | XLSX | Licensed primary care | `facilities_doh_hfsrb_primary_care_bronze` | ~300 |
| `doh_hfsrb_dialysis_clinics` | DOH HFSRB | XLSX | Dialysis clinics | `facilities_doh_hfsrb_dialysis_clinics_bronze` | ~100 |
| `doh_hfsrb_blood_service` | DOH HFSRB | XLSX | Blood service facilities | `facilities_doh_hfsrb_blood_service_bronze` | ~30 |
| `psa_hospitals_region_annual` | PSA | CSV | Hospitals by region, 2020-2024 | `facilities_psa_hospitals_region_annual_bronze` | ~100 |
| `psa_hospitals_national_annual` | PSA | CSV | Hospitals nationally, 2006-2015 | `facilities_psa_hospitals_national_annual_bronze` | ~20 |
| `psa_beds_region_annual` | PSA | CSV | Beds by region, 2020-2024 | `facilities_psa_beds_region_annual_bronze` | ~100 |
| `psa_beds_national_annual` | PSA | CSV | Beds nationally, 1990-2015 | `facilities_psa_beds_national_annual_bronze` | ~26 |
| `psa_bhs_region_annual` | PSA | CSV | BHS by region, 2006-2023 | `facilities_psa_bhs_region_annual_bronze` | ~120 |
| `hdx_healthsites` | HDX (OSM) | CSV | Health facility points (lat/lon) | `facilities_hdx_healthsites_bronze` | ~3,500 |
| `doh_fhsis_demographic` | DOH FHSIS | XLSX | BHS/RHU/MHC/CHC by province/city, 2018-2025 | `facilities_doh_fhsis_demographic_bronze` | ~1,600 |
| `doh_foi_bed_occupancy` | DOH (FOI) | XLSX | Bed occupancy by hospital, 2020-2025 | `facilities_doh_foi_bed_occupancy_bronze` | ~2,000 |
| `doh_foi_hospital_beds` | DOH (FOI) | XLSX | Hospital beds by municipality, 2018-2025 | `facilities_doh_foi_hospital_beds_bronze` | ~200 |

## Loader behavior

* **Incremental**: Only new or changed files load. File change is detected by content checksum. Unchanged files keep the same load batch ID.
* **All STRING**: Every data column is loaded as STRING. Typing happens in silver.
* **Lineage columns**: `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_ingested_at`, `_rescued_data`.
* **Header modes**: `single` (one header row), `skip_rows` (skip N rows before header), `multi_sheet` (multiple sheets in one XLSX).
* **Encoding**: Default UTF-8. Set `encoding_errors: replace` in YAML to load files with bad bytes.

## Quality checks

Bronze QC runs inside `run_bronze.py` after loading. Checks per source (configured in YAML `qc:` section):

* B02: Row count matches `expected_rows`.
* B03: No nulls in key columns.
* B06: Numeric columns are numeric.
* B09: Control totals match (e.g. sum of hospitals per year).
* B11: Required columns exist.
* B12: Header check passes.
* B14: Each file gives at least one data row.

A QC FAIL (ERROR severity) raises an exception and stops the task, preventing silver from running.

## Restricted data

Two FOI sources are restricted: `doh_foi_bed_occupancy` and `doh_foi_hospital_beds`. They live in `restricted/` subfolders in the landing volume and are not synced by the DABs bundle. See [data governance](../../08-governance/data-governance.md) for sharing rules.

## Evidence

Bronze build evidence is in `public_health.quality.build_log` and `public_health.bronze.ingestion_metadata`. Each source load records a batch ID, content checksum, and ingested timestamp. See [evidence](../../06-evidence/README.md).

## Known issues

* `facilities_osm_point_silver` (the silver table from `hdx_healthsites`) is not verified to exist on Databricks. See [known issues](../../08-governance/known-issues-and-backlog.md).
* HFSRB license numbers are not unique across facilities. The silver layer uses `name:<category>|<norm_name>|<psgc>` as the source_record_id.

See [bronze README](README.md) for the loader architecture and [silver facilities](../silver/facilities.md) for the silver layer.