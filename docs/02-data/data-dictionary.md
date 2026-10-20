# Data dictionary

This page is the index of every table in the platform. It lists each bronze and silver table with its source, grain and key. It also links to the page with the column detail. Gold has its own full dictionary.

Status date: 2026-10-20. Bronze inventory taken from `config/sources_<domain>.yaml` on that date; silver keys from the silver QC scripts.

---

## 1. Where the column detail lives

| Layer | Column detail | Why there |
|---|---|---|
| Landing | `config/sources_<domain>.yaml`: folder and file names per source | The YAML entry is the landing contract (AD-04, AD-17) |
| Bronze, file sources | The source's YAML entry: `columns` (or the file header for `header_mode: single`), `required_columns`, `column_map`, `notes` | Bronze keeps the file's own column names. Only the YAML defines them, so a copy here would drift |
| Bronze, API sources | Section 4 of this page | The loader fixes their schema, not a YAML |
| Silver | The domain pages in [`04-pipeline/silver/`](../04-pipeline/silver/README.md) and the header of each build file | Each table's columns follow its build rules |
| Gold | [Gold data dictionary](../04-pipeline/gold/data-dictionary.md) (technical) and [business data dictionary](../04-pipeline/gold/business-data-dictionary.md) (plain language) | Full column lists, checked against the SQL |
| Quality | [Quality overview](../04-pipeline/quality/README.md) and the [lineage and quality contract](../04-pipeline/quality/lineage-and-quality-contract.md), section 5 | Shared by every layer |

## 2. Shared conventions

| Item | Value |
|---|---|
| Catalog | `public_health` |
| Schemas | `bronze`, `silver`, `gold`, `quality` |
| Format | Delta |
| Bronze table names | `<domain>_<source>_<content>_bronze` (D-09). API tables: `geography_bronze`, `admin_boundaries_bronze` |
| Bronze data columns | Every data column is STRING, with the file's own name. Characters Delta does not allow (space , ; { } ( ) = tab newline, and `.`) become `_` |
| Bronze lineage columns (file sources) | `_rescued_data`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_ingested_at` |
| Bronze load mode (file sources) | Incremental by file checksum. Only new or changed files load. The loader replaces a file's rows with `replaceWhere` and never appends them twice (AD-05). It does not overwrite the table |
| Silver lineage columns | `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date` (+ `_metric_source_columns` where unpivoted) (D-24) |
| Gold lineage column | `_gold_build_id` |
| Null | Not available. Never zero |
| Restricted sources | `sharing: restricted` (D-47): never profiled, aggregates only in gold |

## 3. Bronze inventory

Expected rows are `qc.expected_rows` in the YAML (all files of the entry together); the live counts are in `quality.table_stats`.

### 3.1 Diseases (`sources_diseases.yaml`, 19 tables)

| Bronze table | Source key | Source | Sharing | Expected rows |
|---|---|---|---|---|
| `diseases_doh_foi_dengue_bronze` | `doh_foi_dengue` | DOH dengue, region × month, 2021–2025 (FOI) | restricted | 1,026 |
| `diseases_upnoah_dengue_regional_bronze` | `upnoah` | UP NOAH dengue, region × ISO week, 2016–2019, 2022–2025 | open (ODbL) | 7,072 |
| `diseases_hdx_dengue_bronze` | `hdx_dengue` | HDX dengue, province × week, 2016–2021 (2 files) | open (CC BY) | 32,955 |
| `diseases_doh_foi_tb_region2_bronze` | `doh_foi_tb_region2` | DOH Region II TB, stacked tables, 2020–2025 (FOI; bronze only) | restricted | 127 |
| `diseases_psa_deaths_national_monthly_bronze` | `psa_deaths_national_monthly` | PSA registered deaths by cause × month, 2020–2024 | open | 589 |
| `diseases_psa_deaths_region_annual_bronze` | `psa_deaths_region_annual` | PSA deaths by cause, region and age, 2023–2024 | open | 4,524 |
| `diseases_psa_deaths_national_annual_bronze` | `psa_deaths_national_annual` | PSA deaths by cause, national, 2015–2020 | open | 119 |
| `diseases_psa_deaths_province_annual_bronze` | `psa_deaths_province_annual` | PSA deaths by cause, sex and province, 2006–2015 | open | 9,224 |
| `diseases_fhsis_tb_bronze` | `doh_fhsis` | FHSIS TB case notification, 2024, 2025 | public | 3,493 |
| `diseases_fhsis_tb_tpt_bronze` | `doh_fhsis` | FHSIS TB preventive treatment, 2025 | public | 1,748 |
| `diseases_fhsis_tb_treatment_success_bronze` | `doh_fhsis` | FHSIS TB treatment success (DS and MDR), 2025 | public | 3,496 |
| `diseases_fhsis_morbidity_bronze` | `doh_fhsis` | FHSIS heart disease and pneumonia, 2024 | public | 286 |
| `diseases_davao_hospital_pneumonia_bronze` | `davao_hospital_pneumonia` | Pneumonia admissions, one Davao hospital, 2017–2025 (de-identified extract) | restricted | 25,924 |
| `diseases_philhealth_tb_claims_bronze` | `philhealth_foi_tb_claims` | PhilHealth TB claims, 2017–2019 (FOI; bronze only) | restricted | 60,678 |
| `diseases_psa_deaths_allcause_region_annual_bronze` | `psa_deaths_allcause_region_annual` | PSA all-cause deaths by region, 1992–2023 | open | 79 |
| `diseases_psa_notifiable_national_annual_bronze` | `psa_notifiable_national_annual` | PSA notifiable diseases, national, 2014–2021 | open | 23 |
| `diseases_psa_morbidity_leading_national_annual_bronze` | `psa_morbidity_leading_national_annual` | PSA ten leading causes of morbidity | open | 78 |
| `diseases_ihme_gbd_bronze` | `ihme_gbd` | IHME GBD 2023 modelled deaths and prevalence, provinces, 2019–2023 (2 files) | restricted (licence) | 38,540 |
| `diseases_philhealth_claims_hospital_bronze` | `philhealth_foi_claims_hospital` | PhilHealth claims by hospital and case-rate package, 2016–2025 (FOI-REQ-2026-6223) | restricted | 245,405 |

The four FHSIS tables share the source key `doh_fhsis` (`source_key_override`).

### 3.2 Facilities (`sources_facilities.yaml`, 15 tables)

| Bronze table | Source key | Source | Sharing | Expected rows |
|---|---|---|---|---|
| `facilities_nhfr_bronze` | `doh_nhfr` | NHFR active hospitals, as of 2026-09-29 | public | 1,359 |
| `facilities_hfsrb_hospitals_bronze` | `doh_hfsrb_hospitals` | HFSRB licensed hospitals, as of 2026-06-30 | public | 1,336 |
| `facilities_hfsrb_infirmaries_bronze` | `doh_hfsrb_infirmaries` | HFSRB licensed infirmaries | public | 614 |
| `facilities_hfsrb_primary_care_bronze` | `doh_hfsrb_primary_care` | HFSRB licensed primary care facilities | public | 1,180 |
| `facilities_hfsrb_dialysis_clinics_bronze` | `doh_hfsrb_dialysis_clinics` | HFSRB free-standing dialysis clinics | public | 800 |
| `facilities_hfsrb_blood_service_bronze` | `doh_hfsrb_blood_service` | HFSRB free-standing blood service facilities | public | 121 |
| `facilities_hdx_healthsites_bronze` | `hdx_healthsites` | OpenStreetMap health points via healthsites.io (2 snapshots; silver reads the newest) | open (ODbL) | 32,064 |
| `facilities_psa_hospitals_region_annual_bronze` | `psa_hospitals_region_annual` | PSA Table 9.18 hospitals by region, 2020–2024 | open | 18 |
| `facilities_psa_beds_region_annual_bronze` | `psa_beds_region_annual` | PSA Table 9.17 authorized beds by region, 2020–2024 | open | 18 |
| `facilities_psa_hospitals_national_annual_bronze` | `psa_hospitals_national_annual` | PSA OpenSTAT hospitals, national, 2006–2015 | open | 10 |
| `facilities_psa_bhs_region_annual_bronze` | `psa_bhs_region_annual` | PSA Table 9.19 barangay health stations, 2006–2023 | open | 19 |
| `facilities_bed_occupancy_bronze` | `doh_foi_hospital_beds` (and the superseded `bed_occupancy`) | HFSRB hospital beds and occupancy per reporting hospital, 2018–2025 (FOI DOH-984883683631) | restricted | 9,145 (+ 1,977 superseded) |
| `facilities_fhsis_primary_care_bronze` | `doh_fhsis_demographic` | FHSIS BGY & BHS tab: barangays, health centres, BHS, 2018–2025 | public | 1,436 |
| `facilities_psa_hospitals_beds_national_annual_bronze` | `psa_hospitals_beds_national_annual` | PSA Table 9.16 hospitals and beds, national, 1990–2015 | open | 32 |
| `facilities_psa_hospitals_region_annual_legacy_bronze` | `psa_hospitals_region_annual_legacy` | PSA hospitals by region, older layout, 2005–2015 | open | 49 |

### 3.3 Workforce (`sources_workforce.yaml`, 3 tables)

| Bronze table | Source key | Source | Sharing | Expected rows |
|---|---|---|---|---|
| `workforce_fhsis_health_workers_bronze` | `doh_fhsis_demographic` | FHSIS health workers by area, 2018–2025 (18 sheets) | public | 4,999 |
| `workforce_psa_gov_practitioners_bronze` | `psa_gov_practitioners` | PSA Table 9.14 government medical practitioners, 2012–2023 | open | 72 |
| `workforce_psmo_oncologists_bronze` | `psmo_oncologists` | PSMO medical oncologists by area, directory snapshot | open | 52 |

### 3.4 Socioeconomic (`sources_socioeconomic.yaml`, 5 tables)

| Bronze table | Source key | Source | Sharing | Expected rows |
|---|---|---|---|---|
| `socioeconomic_psa_poverty_bronze` | `psa_poverty` | PSA poverty threshold, incidence and poor population, 2021/2023/2025 | open | 235 |
| `socioeconomic_psa_health_expenditure_share_bronze` | `psa_health_expenditure_share_national_annual` | PSA Table 9.26 health expenditure share by financing agent, 2016–2023 | open | 18 |
| `socioeconomic_psa_health_expenditure_per_capita_bronze` | `psa_health_expenditure_per_capita_national_annual` | PSA Table 9.24 per capita health expenditure, 2016–2023 | open | 8 |
| `socioeconomic_psa_child_mortality_bronze` | `psa_child_mortality` | PSA Table 9.9 early childhood mortality, NDHS 2017 and 2022 | open | 39 |
| `socioeconomic_psa_psgc_bronze` | `psa_psgc` | PSGC datafile with income class, urban/rural and 2024 population | open | 43,768 |

### 3.5 Geography and population (API sources)

| Bronze table | Source | Grain | Detail |
|---|---|---|---|
| `geography_bronze` | PSA PSGC API (`psgc`, version Q2_2024); also carries the population payload (`psgc_population`) | One PSGC code per logical snapshot | Section 4.1 |
| `admin_boundaries_bronze` | HDX COD-AB `cod-ab-phl` (`hdx_phl_admin`) | One GeoJSON feature per admin level per HDX source version | Section 4.2 |
| `admin_boundaries_dq` | Validation evidence of the HDX ingestion before the bronze load | One check per admin level per validation run | Section 4.3 |

Population has no table of its own: `population_silver` parses `geography_bronze.populations_json` (section 5.1).

### 3.6 Shared

| Table | Purpose | Detail |
|---|---|---|
| `bronze.ingestion_metadata` | The load log: one row per file or sheet per load, or per API ingestion attempt | Section 4.4 |

### 3.7 Retired tables

Tables from the notebook-era loaders (before the config-driven loader of 2026-10-06, D-12) and earlier names. They are not read by the pipeline. Drop them from the workspace once nothing depends on them.

| Old table | What replaced it |
|---|---|
| `active_facilities` | `facilities_nhfr_bronze` (same NHFR export) |
| `facilities_hospital_list` (regional summary sheet) | `facilities_hfsrb_hospitals_bronze` (the facility list of the same HFSRB workbook) |
| `facilities_infirmary` (regional summary sheet) | `facilities_hfsrb_infirmaries_bronze` |
| `facilities_primary_care` (regional summary) | `facilities_hfsrb_primary_care_bronze` (licensed list) and `facilities_fhsis_primary_care_bronze` (FHSIS counts) |
| `government_medical_practitioners_by_region` | `workforce_psa_gov_practitioners_bronze` |
| `psmo_oncologists` | `workforce_psmo_oncologists_bronze` |
| `neoplasm_prevalence` | `diseases_ihme_gbd_bronze` (IHME neoplasms file, D-11) |
| `globocan_2024_statistics_at_glance`, `globocan_2024_cancer_site_metrics` | Not used: neoplasms come from IHME by province (D-11) |
| `geography_phl_admin_boundaries`, `geography_phl_admin_boundaries_dq` | `admin_boundaries_bronze`, `admin_boundaries_dq` |
| `population_bronze` (positional PSA Excel load) | `geography_bronze.populations_json`, parsed into `population_silver` |

## 4. Bronze API tables: columns

### 4.1 `bronze.geography_bronze`

PSGC records from the PSA API. **Grain:** one row per PSGC code per logical snapshot. **Merge key:** `content_checksum + psgc_code`, so the same code can exist in two snapshots but never twice in one. The loader refuses a second snapshot for the same version.

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC code (source field `code`) |
| `area_name` | STRING | Official name |
| `correspondence_code` | STRING | PSA correspondence code |
| `geographic_level` | STRING | `Reg`, `Prov`, `City`, `Mun`, `SubMun`, `Bgy`; blank for a few special records (`0990100000`, `1999900000`) |
| `reg`, `prv`, `mun`, `bgy` | STRING | Code components supplied by PSA |
| `old_name` | STRING | Previous name, when available |
| `city_class` | STRING | HUC, ICC, CC, when applicable |
| `income_classification` | STRING | Income class (provinces, cities, municipalities) |
| `urban_rural` | STRING | Urban/rural (barangays) |
| `island_region` | STRING | Luzon, Visayas or Mindanao |
| `record_status` | STRING | Source field `status`, renamed |
| `record_version` | STRING | Source field `version`, renamed |
| `populations_json` | STRING | JSON array of population observations (`id`, `population`, `psgc`, `year`), parsed in silver |
| `source_record_json` | STRING | The complete source record |
| `source_system` | STRING | `PSA PSGC` |
| `source_version` | STRING | Requested PSGC version, e.g. `Q2_2024` |
| `source_endpoint` | STRING | API endpoint used |
| `batch_id` | STRING | Ingestion run that wrote the row |
| `content_checksum` | STRING | SHA-256 of the logical snapshot |
| `raw_path` | STRING | Landing path of the validated raw files |
| `ingested_at` | TIMESTAMP | Write time |

Blank `old_name`, `city_class`, `income_classification`, `urban_rural` or `record_status` is normal for levels where the attribute does not apply. Population values can hold commas, a bracketed note or `-`; silver parses them (bronze QC B10 WARN, expected).

### 4.2 `bronze.admin_boundaries_bronze`

HDX administrative boundaries (ADM1 region, ADM2 province, ADM3 city or municipality). **Grain:** one GeoJSON feature per admin level per HDX source version. **Rerun rule** for one `_source_version`: no rows → load the full batch; full batch → do nothing; partial batch → fail. HDX p-codes stay as source values; matching to PSGC is silver's job.

| Column | Type | Description |
|---|---|---|
| `source_feature_json` | STRING | The complete GeoJSON feature |
| `_staging_file_path` | STRING | Prepared JSONL file read for the row |
| `feature_type` | STRING | `Feature` |
| `source_feature_id` | STRING | Feature id, when supplied |
| `properties_json` | STRING | Raw `properties` (`adm1_pcode`, `adm2_name`, `area_sqkm`, `center_lat`, `center_lon`, `valid_on` …) |
| `geometry_json` | STRING | Raw geometry |
| `geometry_type` | STRING | `Polygon` or `MultiPolygon` |
| `_source_key` | STRING | `hdx_phl_admin` |
| `_dataset_id` | STRING | `cod-ab-phl` |
| `_source_version` | STRING | SHA-256 of the immutable HDX archive |
| `_batch_id` | STRING | `dataset_id:source_version` |
| `_admin_level` | INT | 1, 2 or 3 |
| `_source_file` | STRING | Extracted layer, e.g. `phl_admin3.geojson` |
| `_source_file_sha256` | STRING | SHA-256 of that layer |
| `_source_crs` | STRING | CRS reported by the source |
| `_source_url` | STRING | HDX resource URL |
| `_landing_receipt_path` | STRING | Landing `receipt.json` |
| `_staging_manifest_path` | STRING | Staging `manifest.json` with expected row counts |
| `_validation_id` | STRING | Validation run that authorized the load (never rewritten by a later validation) |
| `_landing_ingested_at` | TIMESTAMP | When the version reached landing |
| `_bronze_ingested_at` | TIMESTAMP | Commit time |
| `_record_sha256` | STRING | SHA-256 of the feature, for reconciliation and duplicates |

The capstone loaded version `032db5d9…10d6`. The HDX team checked it at load time.

| Item | Value |
|---|---|
| Features | 1,747 (ADM1 17, ADM2 88, ADM3 1,642) |
| CRS | `urn:ogc:def:crs:OGC:1.3:CRS84` |
| Rerun | Returned `already_complete` |
| Bronze QC | HB00–HB14 |

The loader reads expected counts from the staging manifest. It never uses these numbers.

### 4.3 `bronze.admin_boundaries_dq`

Validation evidence written by the HDX ingestion before a version may load. Append-only. **Grain:** one check per admin level per validation run. The recorded bronze QC of the loaded table is HB00–HB14 in `quality.qc_results`.

| Column | Type | Description |
|---|---|---|
| `validation_id` | STRING | Validation run |
| `run_id` | STRING | Ingestion run |
| `batch_id` | STRING | Batch validated |
| `dataset` | STRING | `cod-ab-phl` |
| `executed_at` | TIMESTAMP | When the check ran |
| `stage` | STRING | Validation stage |
| `admin_level` | INT | Level checked |
| `check_name`, `check_type` | STRING | Rule and category (schema, null, uniqueness, accepted values, foreign key, volume, format) |
| `status`, `severity` | STRING | `PASS`, `WARN`, `FAIL`; severity of the rule |
| `fail_count`, `total_count` | BIGINT | Failing and checked records |
| `fail_pct`, `threshold` | DOUBLE | Failing share; allowed share |
| `detail` | STRING | Context |

A version goes to the bronze loader only with no blocking FAIL. WARNs stay in the table and do not block.

### 4.4 `bronze.ingestion_metadata`

The shared load log (`ingestion_metadata.sql`). One row per file or sheet per load (file sources) or per API ingestion attempt. Silver takes each input's load id and checksum from here (D-20); bronze QC B13 and the preload gate read it.

| Column | Type | Description |
|---|---|---|
| `batch_id` | STRING | Ingestion run (shared by the files of one loader run) |
| `source_name` | STRING | Source key (`_source_key`) |
| `source_version` | STRING | Requested version; the `as_of_date` for file loads |
| `endpoint` | STRING | API endpoint; null for file loads |
| `content_checksum` | STRING | SHA-256 of the file or snapshot |
| `raw_file_path` | STRING | Landing path |
| `record_count` | BIGINT | Records retrieved or rows written |
| `page_count` | INT | API pages; null for file loads |
| `retrieved_at` | TIMESTAMP | When the load ran (UTC, D-54); equals the rows' `_ingested_at` |
| `status` | STRING | `in_progress`, `processed`, `failed`, `skipped_duplicate` |
| `bronze_table` | STRING | Target table (file loads) |
| `source_sheet` | STRING | Excel sheet; null for CSV |
| `column_count` | INT | Data columns written |
| `file_size_bytes` | BIGINT | File size |
| `error_message` | STRING | First 500 characters of the error, when failed |

## 5. Silver inventory

Keys are the grain keys checked by S02 and S03. Columns: the domain page.

| Domain | Silver table | One row is | Key | Detail |
|---|---|---|---|---|
| Geography | `geography_silver` | One PSGC area in one snapshot | `psgc_code`, `content_checksum` | [geography](../04-pipeline/silver/geography.md) |
| Geography | `admin_boundaries_silver` | One HDX boundary in one version, matched to PSGC | `admin_level`, `boundary_pcode`, `source_version` | [geography](../04-pipeline/silver/geography.md) |
| Population | `population_silver` | One area × census year × PSGC version | `psgc_code`, `population_year`, `source_version` | Section 5.1, [population](../04-pipeline/silver/population.md) |
| Facilities | `facilities_registry_silver` | One facility (NHFR matched to HFSRB) | `facility_key` | [facilities](../04-pipeline/silver/facilities.md) |
| Facilities | `facilities_id_map_silver` | One source identifier of a facility | `_source_key`, `source_record_id` | same |
| Facilities | `facilities_metric_silver` | One published count by area, year, ownership | `area_key`, `year`, `ownership`, `_source_key` | same |
| Facilities | `facilities_bed_occupancy_silver` (restricted) | One reporting hospital record | Source row | same |
| Facilities | `facilities_osm_point_silver` | One OSM point placed in a locality | `osm_type`, `osm_id` | same |
| Diseases | `diseases_metric_silver` | One measure of one disease, area, period, source | `disease_key`, `area_key`, `period_grain`, `period_key`, `measure`, `_source_key` | [diseases](../04-pipeline/silver/diseases.md) |
| Diseases | `diseases_deaths_age_silver` | Deaths of one cause, area, year, age group | `disease_key`, `area_key`, `year`, `age_group`, `_source_key` | same |
| Diseases | `diseases_hospital_encounters_silver` (restricted) | One de-identified admission | Source row | same |
| Diseases | `diseases_source_coverage_silver` | One source × scope × level × grain × year | `_source_key`, `disease_scope`, `geo_level`, `period_grain`, `year` | same |
| Diseases | `diseases_tb_programme_silver` | One TB programme indicator × area × year × age × sex | `indicator`, `drug_resistance`, `area_key`, `year`, `age_group`, `sex`, `_source_key` | same |
| Diseases | `diseases_hospital_claims_silver` (restricted) | Claims of one hospital × year × package × status | `year`, `facility_name_norm`, `area_key`, `disease_key`, `claim_status`, `_source_key` | same |
| Workforce | `workforce_headcount_silver` | One profession × area × year × source | `_source_key`, `area_key`, `year`, `profession` | [workforce](../04-pipeline/silver/workforce.md) |
| Workforce | `workforce_area_denominator_silver` | FHSIS-printed population and households of one area-year | `_source_key`, `area_key`, `year` | same |
| Workforce | `workforce_specialist_silver` | One PSMO area listing in one snapshot | `_source_key`, `snapshot_date`, `area_label_source` | same |
| Socioeconomic | `socioeconomic_poverty_silver` | One area × survey year | `area_key`, `year` | [socioeconomic](../04-pipeline/silver/socioeconomic.md) |
| Socioeconomic | `socioeconomic_health_expenditure_share_silver` | One financing agent × year | `financing_agent`, `year` | same |
| Socioeconomic | `socioeconomic_health_expenditure_per_capita_silver` | One year | `year` | same |
| Socioeconomic | `socioeconomic_child_mortality_silver` | One characteristic × survey year | `characteristic_group`, `characteristic`, `survey_year` | same |

Each domain's `00_reference` step loads reviewed CSVs into silver reference tables (AD-09).

| Domain | Reference tables |
|---|---|
| Diseases | `diseases_directory_silver`, `diseases_cause_aggregation`, area map, cause map |
| Facilities | Area exceptions, id-map overrides |
| Workforce | Area exceptions, row overrides |
| Socioeconomic | Poverty area map |

Detail: [reference maps](../04-pipeline/silver/reference-maps.md).

### 5.1 `silver.population_silver`

Population observations parsed from `geography_bronze.populations_json` (`psgc_population_silver.py`, full rebuild). **Grain:** `psgc_code × population_year × source_version`. The table keeps every observation, even values that do not parse.

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC code of the bronze record |
| `population_year` | INT | Census year (2015, 2020, 2024 in Q2_2024) |
| `population` | BIGINT | Parsed count; null unless the status is `VALID` or `VALID_WITH_NOTE` |
| `population_raw` | STRING | Original value |
| `population_note` | STRING | Leading bracketed note, e.g. `excluding CITY OF ANGELES` |
| `population_parse_status` | STRING | `VALID`, `VALID_WITH_NOTE`, `MISSING` (null, empty or `-`), `INVALID` |
| `source_version` | STRING | PSGC version |
| `content_checksum` | STRING | Snapshot checksum from bronze |
| `batch_id` | STRING | Bronze batch |
| `silver_processed_at` | TIMESTAMP | Write time |

QC: S00–S09, S51–S59 ([silver quality checks](../04-pipeline/silver/silver-quality-checks.md), section 8).

## 6. Gold

5 dimensions, 4 facts, seeds, helpers, default views and marts, every column listed: [gold data dictionary](../04-pipeline/gold/data-dictionary.md). Object list: [gold table catalog](../04-pipeline/gold/table-catalog.md).

## 7. History of updates

| Date | Change |
|---|---|
| 2026-10 (early) | First dictionary: notebook-era bronze tables, PSGC and HDX API tables, `population_silver` |
| 2026-10-20 | Rebuilt as an index. Bronze inventory taken from the current YAMLs (42 tables). Old tables listed as retired. HDX tables renamed. Load mode corrected. `ingestion_metadata` and `population_silver` updated. Silver inventory added. Gold links to its own dictionary. Rewritten in short, active sentences |
