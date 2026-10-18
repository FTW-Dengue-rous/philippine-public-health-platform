# Data dictionary

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Column definitions for the silver and gold tables. For metric formulas, see [metric definitions](metric-definitions.md).

## `mart_area_service_profile` (v1, public_health.gold)

This v1 mart was the dashboard source until the dashboard moved to the v2 `test_gold2` tables. It has 2,701 rows. Each row is one supply section, area, year, ownership type, and hospital level.

| Column | Type | Description |
|---|---|---|
| `supply_section` | STRING | Which question: `S1_hospital_supply`, `S2_hospital_occupancy`, `S3_primary_care_supply` |
| `area_level` | STRING | `City/Mun` or `Province` |
| `area_key` | STRING | Area identifier (PSGC code or province_unit_key fallback) |
| `psgc_code` | STRING | PSGC code from geography_silver (null for some NCR/historical areas) |
| `area_name` | STRING | Area name from geography_silver |
| `region_name` | STRING | Region name |
| `province_name` | STRING | Province name (null for NCR and HUC/ICC areas) |
| `year` | INT | Reference year (null for S1 current snapshot) |
| `ownership` | STRING | `Government`, `Private`, or `Total` (normalized via INITCAP) |
| `facility_level` | STRING | Hospital level from registry |
| `population` | BIGINT | Population from population_silver or facilities_metric_silver |
| `hospital_count` | INT | Count of hospitals in the area |
| `authorized_beds` | INT | Sum of Authorized Bed Capacity |
| `analysis_beds` | INT | Beds used for analysis |
| `beds_per_10000_pop` | DOUBLE | `authorized_beds / population × 10000` |
| `avg_bor` | DOUBLE | Average bed occupancy rate (S2 only) |
| `min_bor` | DOUBLE | Minimum BOR in the area (S2 only) |
| `max_bor` | DOUBLE | Maximum BOR in the area (S2 only) |
| `facility_count_reporting` | INT | Number of facilities reporting BOR (S2 only) |
| `pct_bor_over_100` | DOUBLE | Percentage of hospitals with BOR > 100 (S2 only) |
| `sum_implementing_beds` | INT | Sum of implementing beds (S2 only) |
| `bhs_count` | INT | Barangay Health Stations count (S3 only) |
| `rhu_count` | INT | Rural Health Units count (S3 only) |
| `mhc_count` | INT | Main Health Centres count (S3 only) |
| `chc_count` | INT | City Health Centres count (S3 only) |
| `health_centers_total` | INT | `COALESCE(health_centers_total, mhc + chc)` (S3 only) |
| `bhs_per_10000_pop` | DOUBLE | `bhs_count / population × 10000` (S3 only) |
| `rhu_per_10000_pop` | DOUBLE | `rhu_count / population × 10000` (S3 only) |
| `primary_care_per_10000_pop` | DOUBLE | `health_centers_total / population × 10000` (S3 only) |

## `mart_area_service_profile` (v2, public_health.test_gold2)

This v2 mart is the active data model. It has 109 rows and 62 columns. Each row is one planning unit. A planning unit is a province (without its highly urbanized cities), a single highly urbanized city (HUC), or one NCR district. Verified schema (DESCRIBE TABLE, 2026-10-18):

| Column | Type | Description |
|---|---|---|
| `planning_unit_key` | BIGINT | Surrogate key for the planning unit (PK) |
| `area_code` | STRING | Area code from dim_geography |
| `area_name` | STRING | Planning unit name |
| `region_key` | BIGINT | Foreign key to dim_geography (region) |
| `unit_level` | STRING | Province, HUC, or NCR |
| `income_class` | STRING | Income classification |
| `population` | DECIMAL(30,4) | Population denominator |
| `population_year` | INT | Year of population estimate |
| `population_source` | BIGINT | Source key for population |
| `hospitals` | BIGINT | Count of hospitals in the planning unit |
| `beds` | BIGINT | Total authorized beds |
| `beds_per_10k` | DECIMAL(33,2) | Beds per 10,000 population |
| `beds_level1` | BIGINT | Level 1 hospital beds |
| `beds_level2` | BIGINT | Level 2 hospital beds |
| `beds_level3` | BIGINT | Level 3 hospital beds |
| `government_beds` | BIGINT | Government hospital beds |
| `government_bed_share` | DOUBLE | Government beds / total beds |
| `level3_hospitals` | BIGINT | Count of Level 3 hospitals |
| `highest_hospital_level` | STRING | Highest hospital level in the unit |
| `localities` | BIGINT | Count of cities/municipalities |
| `localities_without_hospital` | BIGINT | Localities with no hospital |
| `population_without_hospital` | DECIMAL(30,4) | Population with no hospital access |
| `licensed_primary_care_facilities_recorded` | BIGINT | Licensed primary care facilities count |
| `localities_without_licensed_primary_care_recorded` | BIGINT | Localities without licensed primary care |
| `population_without_licensed_primary_care_recorded` | DECIMAL(30,4) | Population without licensed primary care |
| `reported_bhs` | BIGINT | Reported BHS count |
| `reported_health_centers` | BIGINT | Reported health centres count |
| `fhsis_reported_population` | DECIMAL(30,4) | FHSIS reported population |
| `reported_bhs_per_10k` | DECIMAL(33,2) | BHS per 10,000 population |
| `reported_health_centers_per_10k` | DECIMAL(33,2) | Health centres per 10,000 population |
| `fhsis_count_year` | INT | FHSIS count year |
| `fhsis_mapping_outcome` | STRING | FHSIS mapping result |
| `doctors` | BIGINT | Doctor headcount |
| `nurses` | BIGINT | Nurse headcount |
| `midwives` | BIGINT | Midwife headcount |
| `bhw` | BIGINT | BHW headcount |
| `doctors_per_10k` | DECIMAL(33,2) | Doctors per 10,000 population |
| `nurses_per_10k` | DECIMAL(33,2) | Nurses per 10,000 population |
| `midwives_per_10k` | DECIMAL(33,2) | Midwives per 10,000 population |
| `bhw_per_10k` | DECIMAL(33,2) | BHW per 10,000 population |
| `doh_deployed_share` | DOUBLE | Share of DOH-deployed workforce |
| `workforce_year` | INT | Workforce data year |
| `poverty_incidence_pct` | DECIMAL(20,4) | Poverty incidence (%) |
| `poverty_year` | INT | Poverty data year |
| `poverty_band` | STRING | Poverty band category |
| `beds_per_10k_quintile` | INT | Quintile rank for beds per 10k |
| `reported_bhs_per_10k_quintile` | INT | Quintile rank for BHS per 10k |
| `reported_health_centers_per_10k_quintile` | INT | Quintile rank for health centres per 10k |
| `doctors_per_10k_quintile` | INT | Quintile rank for doctors per 10k |
| `nurses_per_10k_quintile` | INT | Quintile rank for nurses per 10k |
| `midwives_per_10k_quintile` | INT | Quintile rank for midwives per 10k |
| `bhw_per_10k_quintile` | INT | Quintile rank for BHW per 10k |
| `poverty_incidence_pct_quintile` | INT | Quintile rank for poverty incidence |
| `hospitals_without_bed_count` | BIGINT | Hospitals with null bed count |
| `registry_as_of_date` | DATE | Registry snapshot date |
| `bhw_year` | INT | BHW data year |
| `fhsis_exclusion_reason` | STRING | Reason FHSIS data excluded (if any) |
| `workforce_mapping_outcome` | STRING | Workforce mapping result |
| `workforce_exclusion_reason` | STRING | Reason workforce excluded (if any) |
| `bhw_exclusion_reason` | STRING | Reason BHW excluded (if any) |
| `poverty_exclusion_reason` | STRING | Reason poverty excluded (if any) |
| `localities_without_population` | BIGINT | Localities with null population |

## `facilities_registry_silver`

| Column | Type | Description |
|---|---|---|
| `facility_key` | STRING | Stable facility identifier (primary key) |
| `facility_category` | STRING | `hospital`, `infirmary`, `primary_care`, `dialysis_clinic` |
| `ownership` | STRING | `Government` or `Private` |
| `ownership_class` | STRING | Ownership sub-class |
| `service_level` | STRING | Hospital level (Level 1, 2, 3, or Specialist) |
| `authorized_beds` | INT | Authorized Bed Capacity |
| `analysis_beds` | INT | Beds used for analysis |
| `psgc_code` | STRING | PSGC code for the facility's location |
| `area_key` | STRING | Area key for joining to geography |
| `_silver_build_id` | STRING | Build ID (links to `build_log`) |
| `_source_key` | STRING | Source identifier |
| `_source_file` | STRING | Source file path |
| Lineage columns | Various | Per the [lineage contract](../../lineage-qc-contract_v1.3.md) |

## `facilities_bed_occupancy_silver`

| Column | Type | Description |
|---|---|---|
| `facility_key` | STRING | Facility identifier (foreign key to registry) |
| `year` | INT | Reporting year. The actual column name in the table is `year` (verified 2026-10-18). Some earlier documentation references `reporting_year`; that column does not exist. |
| `ownership` | STRING | `government` or `private` (lowercase in this table) |
| `hospital_level` / `service_level` | STRING | Hospital level |
| `bor_pct` | DOUBLE | Bed Occupancy Rate (implementing / authorized × 100) |
| `authorized_beds` | INT | Authorized beds |
| `implementing_beds` | INT | Implementing beds |
| `baseline_eligible` | BOOLEAN | Whether the facility is eligible for baseline comparison |
| `province_unit_key` | STRING | Province unit key as published |
| `province_district` | STRING | Province district name for geography join |
| `region_as_published` | STRING | Region name as published in the source |

## `facilities_metric_silver`

| Column | Type | Description |
|---|---|---|
| `area_key` | STRING | Area key |
| `psgc_code` | STRING | PSGC code |
| `year` | INT | Reference year |
| `ownership` | STRING | Ownership (Government, Private, or Total) |
| `hospitals` | INT | Hospital count |
| `authorized_beds` | INT | Authorized beds |
| `bhs` | INT | BHS count |
| `rhu` | INT | RHU count |
| `mhc` | INT | MHC count |
| `chc` | INT | CHC count |
| `health_centers_total` | INT | Total health centres |
| `barangays` | INT | Barangay count |
| `population` | BIGINT | Population |
| `_source_key` | STRING | Source key (e.g. `doh_fhsis_demographic`, `psa_bhs_region_annual`) |

## `geography_silver`

Verified schema (DESCRIBE TABLE, 2026-10-18):

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC code (primary key) |
| `correspondence_code` | STRING | Correspondence code from PSA |
| `area_name` | STRING | Area name (with n repaired) |
| `area_name_raw` | STRING | Original area_name before n repair |
| `geographic_level` | STRING | `Reg`, `Prov`, `City`, `Mun`, `SubMun`, `Bgy` |
| `region_code` | STRING | Region code |
| `province_code` | STRING | Province code (null for NCR) |
| `municipality_code` | STRING | Municipality/city code |
| `barangay_code` | STRING | Barangay code |
| `city_class` | STRING | City classification (HUC, ICC, CC) |
| `income_classification` | STRING | Income classification |
| `urban_rural` | STRING | Urban/rural classification |
| `island_region` | STRING | Island-region grouping |
| `record_status` | STRING | Status from PSA source |
| `source_version` | STRING | PSGC version (Q2 2024) |
| `content_checksum` | STRING | Source content checksum |
| `batch_id` | STRING | Ingestion batch ID |
| `silver_processed_at` | TIMESTAMP | Silver processing timestamp |

## `population_silver`

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC code |
| `population_year` | INT | Population year (2015, 2020, 2024) |
| `population` | BIGINT | Population count |

Note: The table name is `population_silver` (verified 2026-10-18). Some earlier docs call it `geography_population_silver`, but that table does not exist.

## Bronze table definitions

For bronze column definitions, see the [bronze pipeline docs](../bronze/README.md) and the YAML source configs in `config/`. The detailed bronze dictionary below uses table names from a previous version. The current naming convention is `<domain>_<source>_<content>_bronze`.




> **Legacy section below.** The geography and admin boundary column definitions are still accurate. The facility table names (such as `facilities_primary_care` and `active_facilities`) are from a previous version. The current naming convention is `<domain>_<source>_<content>_bronze`. See the [bronze pipeline docs](../bronze/README.md) and YAML source configs for current table names.

## Bronze Layer

### `public_health.bronze.geography_bronze`

**Purpose**

Stores Philippine Standard Geographic Code (PSGC) records from the Philippine Statistics Authority (PSA) API. The PSGC is the official code system for all geographic areas in the Philippines.

The table keeps source attributes as individual columns, population data as JSON, the full source record as JSON, and ingestion metadata.

**Grain**

One row per PSGC geographic code per logical source snapshot.

**Source**

PSA Philippine Standard Geographic Code (PSGC) API.

**Natural source key**

`psgc_code`

**Bronze merge key**

`content_checksum + psgc_code`

This lets the same PSGC code appear in different source snapshots without creating duplicate rows within one snapshot.

| Column | Data Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC geographic identifier. Derived from the PSA source field `code`. |
| `area_name` | STRING | Official geographic area name from PSA. |
| `correspondence_code` | STRING | Correspondence code supplied by PSA. |
| `geographic_level` | STRING | Geographic level of the record, such as `Reg`, `Prov`, `City`, `Mun`, `SubMun`, or `Bgy`. Blank values may exist in the source for exceptional geographic records. |
| `reg` | STRING | Region component/code supplied by PSA. |
| `prv` | STRING | Province component/code supplied by PSA. |
| `mun` | STRING | Municipality/city component/code supplied by PSA. |
| `bgy` | STRING | Barangay component/code supplied by PSA. |
| `old_name` | STRING | Previous geographic name supplied by PSA, when available. |
| `city_class` | STRING | PSA city classification, when applicable. |
| `income_classification` | STRING | Income classification supplied by PSA, generally applicable to provinces, cities, and municipalities. |
| `urban_rural` | STRING | Urban/rural classification supplied by PSA, primarily populated for barangay records. |
| `island_region` | STRING | Major island-region grouping supplied by PSA, such as Luzon, Visayas, or Mindanao. |
| `record_status` | STRING | Status value from the PSA source record. Renamed from source field `status` to distinguish it from ingestion-run status. |
| `record_version` | STRING | Version value contained in the individual PSA source record. Renamed from source field `version`. |
| `populations_json` | STRING | JSON array containing population observations associated with the PSGC code. Each observation may contain `id`, `population`, `psgc`, and `year`. Preserved in Bronze for later parsing and normalization in Silver. |
| `source_record_json` | STRING | Complete logical PSA source record preserved as JSON for auditability, traceability, and future reprocessing. |
| `source_system` | STRING | Name of the source system, e.g. `PSA PSGC`. |
| `source_version` | STRING | PSGC source version requested by the ingestion pipeline, e.g. `Q2_2024`. |
| `source_endpoint` | STRING | PSA API endpoint used for the ingestion. |
| `batch_id` | STRING | Unique identifier for the ingestion run that wrote the Bronze record. |
| `content_checksum` | STRING | Deterministic SHA-256 checksum representing the logical source snapshot. Used for idempotency and duplicate detection. |
| `raw_path` | STRING | Permanent landing path containing the validated raw source files associated with the snapshot. |
| `ingested_at` | TIMESTAMP | Timestamp when the record was written to the Bronze Delta table. |

#### Source-value notes

Some PSGC attributes only apply to certain geographic levels. For example, `old_name`, `city_class`, `income_classification`, `urban_rural`, and `record_status` may be blank for records where they do not apply. A blank value does not always mean a data error.

Population values are kept in source form in Bronze. They may contain commas, spaces, blank strings, or values like `#N/A`. The Silver layer cleans and converts these values.

---

### `public_health.bronze.geography_phl_admin_boundaries`

**Purpose**

Stores boundary features from the Humanitarian Data Exchange (HDX). Each row is one GeoJSON Feature with its raw properties, geometry, and lineage metadata. The data supports auditability, safe reruns, and downstream geographic matching.

**Grain**

One row per GeoJSON Feature, per administrative level, per HDX source version.

**Source**

HDX Philippines Administrative Boundaries (`cod-ab-phl`).

Source format: GeoJSON.

Source resource:

`https://data.humdata.org/dataset/cod-ab-phl/resource/0120c30e-ba8b-487d-83f5-a664eddd3a8e`

**Source key**

`hdx_phl_admin`

**Administrative levels**

* ADM1 — region-level boundaries
* ADM2 — province-level boundaries
* ADM3 — municipality/city-level boundaries

HDX p-codes are kept as source values in Bronze. They are not yet treated as official PSGC codes.

Matching p-codes to PSGC codes, standardising names, and fixing source differences are Silver-layer tasks.

**Source version key**

`_source_version`

The source version is the SHA-256 checksum of the downloaded HDX archive. It identifies one immutable version of the source data.

**Batch key**

`_batch_id`

The batch ID is deterministic. It follows the pattern `dataset_id:source_version`.

**Bronze rerun rule**

For the same `_source_version`:

* if no records exist, load the full validated batch;
* if the full batch already exists, do nothing (no-op);
* if a partial or broken batch exists, fail rather than append.

This prevents duplicate records when the same source version is rerun.

| Column | Data Type | Description |
|---|---|---|
| `source_feature_json` | STRING | Complete GeoJSON Feature preserved from the HDX source for auditability, traceability, and future reprocessing. |
| `_staging_file_path` | STRING | Exact prepared JSONL file read by Spark for the Bronze record. Technical staging is not a Medallion layer. |
| `feature_type` | STRING | GeoJSON object type. Expected source value is `Feature`. |
| `source_feature_id` | STRING | GeoJSON Feature identifier when supplied by the source; may be null. |
| `properties_json` | STRING | Raw GeoJSON `properties` object containing source administrative attributes. |
| `geometry_json` | STRING | Raw GeoJSON geometry object including source coordinates. |
| `geometry_type` | STRING | Source geometry type. Validated values for the current source are `Polygon` and `MultiPolygon`. |
| `_source_key` | STRING | Source configuration key. Expected value: `hdx_phl_admin`. |
| `_dataset_id` | STRING | HDX dataset identifier. Expected value: `cod-ab-phl`. |
| `_source_version` | STRING | SHA-256 checksum identifying the immutable HDX source archive. |
| `_batch_id` | STRING | Deterministic source batch identifier composed from the dataset ID and source version. |
| `_admin_level` | INT | Administrative level represented by the Feature: `1`, `2`, or `3`. |
| `_source_file` | STRING | Original extracted GeoJSON layer, such as `phl_admin1.geojson`, `phl_admin2.geojson`, or `phl_admin3.geojson`. |
| `_source_file_sha256` | STRING | SHA-256 checksum of the extracted source GeoJSON layer. |
| `_source_crs` | STRING | Coordinate reference system reported by the source. |
| `_source_url` | STRING | HDX resource URL used during source ingestion. |
| `_landing_receipt_path` | STRING | Path to the immutable Landing `receipt.json` containing source provenance and ingestion metadata. |
| `_staging_manifest_path` | STRING | Path to the validated staging `manifest.json` containing prepared-file metadata and expected row counts. |
| `_validation_id` | STRING | Validation execution associated with the original Bronze load. Later validation executions of the same source version do not rewrite existing Bronze rows. |
| `_landing_ingested_at` | TIMESTAMP | Timestamp when the immutable source version was ingested into Landing. |
| `_bronze_ingested_at` | TIMESTAMP | Timestamp when the Bronze record was committed to the Delta table. |
| `_record_sha256` | STRING | SHA-256 fingerprint of the complete source GeoJSON Feature used for record-level reconciliation and duplicate detection. |

#### Source property notes

The fields in `properties_json` depend on the administrative level.

Common source properties include:

| Source Property | Description |
|---|---|
| `adm0_name` | Country-level source name. |
| `adm0_pcode` | Country-level source p-code. |
| `adm1_name` | ADM1 source administrative name. |
| `adm1_pcode` | ADM1 source p-code. |
| `adm2_name` | ADM2 source administrative name, present on ADM2 and ADM3 records. |
| `adm2_pcode` | ADM2 source p-code, present on ADM2 and ADM3 records. |
| `adm3_name` | ADM3 source administrative name. |
| `adm3_pcode` | ADM3 source p-code. |
| `adm3_ref_name` | Additional ADM3 reference name when supplied by the source. |
| `area_sqkm` | Source-provided administrative area in square kilometers. |
| `center_lat` | Source-provided center latitude. Preserved as supplied and not treated as a calculated centroid. |
| `center_lon` | Source-provided center longitude. Preserved as supplied and not treated as a calculated centroid. |
| `valid_on` | Source validity start value. |
| `valid_to` | Source validity end value when supplied. |
| `version` | Administrative-boundary version value supplied by the source. |
| `lang` | Primary source language metadata. |
| `lang1` | Additional source language metadata. |
| `lang2` | Additional source language metadata. |
| `lang3` | Additional source language metadata. |

Alternate-name fields such as `adm0_name1`, `adm0_name2`, `adm1_name1`, `adm1_name2`, and similar fields for other levels are also kept when present.

The full `source_feature_json` is the authoritative Bronze record. If a future HDX version adds new source properties, the JSON will capture them.

Bronze validation checks geometry type only. A `Polygon` or `MultiPolygon` value does not prove full geometric or topological validity. Full spatial validity checks happen in downstream processing when needed.

#### Current validated source snapshot

Current immutable source version:

`032db5d91fcb8a13aef378d6b4453da7225ef7f0fb9c0a1c3bf3c2205d0010d6`

| Administrative Level | Feature Count |
|---|---:|
| ADM1 | 17 |
| ADM2 | 88 |
| ADM3 | 1,642 |
| **Total** | **1,747** |

The current source contains:

* ADM1: 15 `MultiPolygon`, 2 `Polygon`
* ADM2: 59 `MultiPolygon`, 29 `Polygon`
* ADM3: 369 `MultiPolygon`, 1,273 `Polygon`

The current source CRS is:

`urn:ogc:def:crs:OGC:1.3:CRS84`

These counts describe this source version only. Future HDX versions may have different counts. The pipeline gets expected row counts from the staging manifest, not from these hard-coded values.

#### Current rerun validation

The current source version was loaded successfully with:

* ADM1: 17 rows
* ADM2: 88 rows
* ADM3: 1,642 rows
* Total: 1,747 rows

The same source version was rerun and returned:

`write_outcome = already_complete`

No additional Bronze rows were written, and the table remained at 1,747
records for the source version.

---

### `public_health.bronze.geography_phl_admin_boundaries_dq`

**Purpose**

Stores validation results for the HDX boundary pipeline. A source version must pass validation before it can load into Bronze.

The table keeps all validation history. It does not replace previous results.

**Grain**

One row per validation check per administrative level per validation
execution.

**Related Bronze table**

`public_health.bronze.geography_phl_admin_boundaries`

**Source dataset**

HDX `cod-ab-phl`.

| Column | Data Type | Description |
|---|---|---|
| `validation_id` | STRING | Unique identifier for one validation execution. |
| `run_id` | STRING | Ingestion notebook run identifier associated with the validation. |
| `batch_id` | STRING | Source batch being validated. |
| `dataset` | STRING | Source dataset identifier. Expected value: `cod-ab-phl`. |
| `executed_at` | TIMESTAMP | Timestamp when the validation execution was recorded. |
| `stage` | STRING | Pipeline validation stage. |
| `admin_level` | INT | Administrative level evaluated by the validation rule. |
| `check_name` | STRING | Name of the validation rule. |
| `check_type` | STRING | Validation category, such as schema, null, uniqueness, accepted values, foreign key, volume, or format. |
| `status` | STRING | Validation result. Expected values are `PASS`, `WARN`, or `FAIL`. |
| `severity` | STRING | Severity assigned to the validation rule. |
| `fail_count` | BIGINT | Number of records failing the validation rule. |
| `total_count` | BIGINT | Number of records evaluated by the validation rule. |
| `fail_pct` | DOUBLE | Percentage of evaluated records that failed the rule. |
| `threshold` | DOUBLE | Allowed failure threshold recorded for the validation rule. |
| `detail` | STRING | Additional validation detail or error context. |

#### Validation checks

Current validation includes:

* required source-field availability;
* optional source-field availability;
* Spark JSON parsing;
* manifest-to-record row-count reconciliation;
* nonblank administrative p-codes;
* p-code uniqueness within each administrative level;
* nonblank administrative names;
* GeoJSON `Feature` type;
* accepted geometry types (`Polygon` or `MultiPolygon`);
* ADM2-to-ADM1 parent-reference integrity; and
* ADM3-to-ADM2 parent-reference integrity.

A source version must have no blocking `FAIL` results before it can load into Bronze.

`WARN` results are kept for auditability but do not block the load.

#### Current validated execution

The latest validated handoff used validation ID:

`8b5188af-8739-464f-8614-ca5b39dd4e2c`

The validation execution recorded:

* 37 validation checks
* 0 blocking `FAIL` results
* expected ADM1 rows: 17
* expected ADM2 rows: 88
* expected ADM3 rows: 1,642
* expected total rows: 1,747

A later validation of the same source version does not change the `_validation_id` on rows already loaded. Existing Bronze rows keep the validation that authorised their original load.

---

### Bronze: Facilities domain

---

### `public_health.bronze.facilities_primary_care`

**Description:** Regional Distribution of Primary Care Facilities.

| Property | Value |
|---|---|
| Source file | `primary_care_asof20260630.xlsx` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | Philippine Statistics Authority (PSA) |
| Bronze table | `public_health.bronze.facilities_primary_care` |
| Refresh mode | Overwrite |
| Status | Active |

#### Data Structure

| Column | Type | Description |
|---|---|---|
| `REGION` | STRING | Philippine region code (e.g. `NCR`, `REGION 1`, `BARMM`). |
| `CHD` | STRING | Center for Health Development jurisdiction name (e.g. `METRO MANILA`, `ILOCOS`). |
| `GOVERNMENT` | LONG | Count of government primary-care facilities in the region. |
| `PRIVATE` | LONG | Count of private primary-care facilities in the region. |
| `TOTAL` | LONG | Sum of government and private facility counts. |
| `Status` | STRING | Data-quality flag from the source (`Ok`, `TBU`, or null). |

#### Source-specific Handling

The first row contains a report title rather than field names. Read the Excel file with `header=1` so the second row becomes the dataset header. The source includes a trailing `TOTAL` row with `REGION = 'TOTAL '` (note trailing space).

---

### `public_health.bronze.active_facilities`

**Description:** National Health Facility Registry active-facilities extract.

| Property | Value |
|---|---|
| Source file | `nhfr_activefacilities_asof_20260929.csv` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | National Health Facility Registry (NHFR) |
| Bronze table | `public_health.bronze.active_facilities` |
| Refresh mode | Overwrite |

#### Data Structure

| Column | Type | Description |
|---|---|---|
| `Health Facility Code` | STRING | Unique facility identifier from the NHFR. |
| `Health Facility Code Short` | INT | Shortened facility code. |
| `Facility Name` | STRING | Official facility name. |
| `Old Health Facility Name 1` | STRING | Previous facility name (first alias). |
| `Old Health Facility Name 2` | STRING | Previous facility name (second alias). |
| `Old Health Facility Name 3` | STRING | Previous facility name (third alias). |
| `Facility Major Type` | STRING | High-level facility classification (e.g. hospital, infirmary). |
| `Health Facility Type` | STRING | Detailed facility type. |
| `Ownership Major Classification` | STRING | Government or private ownership. |
| `Ownership Sub-Classification for Government facilities` | STRING | Government ownership sub-category. |
| `Ownership Sub-Classification for private facilities` | STRING | Private ownership sub-category. |
| `Street Name and #` | STRING | Street-level address. |
| `Building name and #` | STRING | Building-level address. |
| `Region Name` | STRING | Region where the facility is located. |
| `Region PSGC` | INT | Philippine Standard Geographic Code for the region. |
| `Province Name` | STRING | Province where the facility is located. |
| `Province PSGC` | INT | PSGC for the province. |
| `City/Municipality Name` | STRING | City or municipality. |
| `City/Municipality PSGC` | INT | PSGC for the city/municipality. |
| `Barangay Name` | STRING | Barangay. |
| `Barangay PSGC` | INT | PSGC for the barangay. |
| `Zip Code` | STRING | Postal code. |
| `Landline Number` | STRING | Primary landline contact. |
| `Landline Number 2` | STRING | Secondary landline contact. |
| `Fax Number` | STRING | Fax number. |
| `Email Address` | STRING | Primary email. |
| `Alternate Email Address` | STRING | Alternate email. |
| `Official Website` | STRING | Facility website URL. |
| `Service Capability` | STRING | Service capability level. |
| `Bed Capacity` | STRING | Authorized bed capacity. |
| `Licensing Status` | STRING | Current license status. |
| `License Validity Date` | DATE | License expiration date. |

#### Source-specific Handling

The file has facility identifiers, names, ownership details, addresses, contacts, licensing information, and bed-capacity fields. Several source column names contain spaces and special characters. Enable Delta column mapping to preserve them without renaming:

* `delta.columnMapping.mode = name`
* `delta.minReaderVersion = 2`
* `delta.minWriterVersion = 5`

Infer the schema from the CSV header during ingestion.

---

### `public_health.bronze.facilities_hospital_list`

**Description:** Regional Distribution of Hospitals in the Philippines.

| Property | Value |
|---|---|
| Source file | `hospital_list_asof20260630.xlsx` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | Philippine Department of Health (DOH) |
| Bronze table | `public_health.bronze.facilities_hospital_list` |
| Refresh mode | Overwrite |

#### Data Structure

The source uses a grouped layout: Government hospitals by level, Private hospitals by level, and combined Totals by level. Pandas auto-suffixes duplicate column names with `.1` and `.2`.

| Column | Type | Description |
|---|---|---|
| `col_0` | STRING | Region (unnamed in source). |
| `col_1` | STRING | CHD — Center for Health Development (unnamed in source). |
| `LEVEL 1` | STRING | Government Level 1 hospitals. |
| `LEVEL 2` | STRING | Government Level 2 hospitals. |
| `LEVEL 3` | STRING | Government Level 3 hospitals. |
| `col_5` | DOUBLE | Government total (unnamed in source). |
| `LEVEL 1.1` | STRING | Private Level 1 hospitals. |
| `LEVEL 2.1` | DOUBLE | Private Level 2 hospitals. |
| `LEVEL 3.1` | STRING | Private Level 3 hospitals. |
| `col_9` | DOUBLE | Private total (unnamed in source). |
| `LEVEL 1.2` | DOUBLE | Grand total Level 1 (Government + Private). |
| `LEVEL 2.2` | DOUBLE | Grand total Level 2 (Government + Private). |
| `LEVEL 3.2` | DOUBLE | Grand total Level 3 (Government + Private). |
| `col_13` | DOUBLE | Grand total across all levels (unnamed in source). |

#### Source-specific Handling

The workbook uses a multi-row header: report title, sub-headers, a blank row, then field names. Use `header=3` to read the correct header row.

Enable Delta column mapping because the source has names such as `LEVEL 1` and `Total No. of Facilities`. Use `overwriteSchema=true` to allow controlled schema updates on later refreshes.

Unnamed source columns are retained as:

* `col_0`: Region
* `col_1`: CHD
* `col_5`: Government total
* `col_9`: Private total
* `col_13`: Grand total

---

### `public_health.bronze.facilities_infirmary`

**Description:** Regional Distribution of Regulated Infirmaries.

| Property | Value |
|---|---|
| Source file | `infirmary_asof20260630.xlsx` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | Philippine Department of Health (DOH) |
| Bronze table | `public_health.bronze.facilities_infirmary` |
| Refresh mode | Overwrite |

#### Data Structure

The source groups data by Government infirmaries (count and Authorized Bed Capacity), then combined Totals. Pandas auto-suffixes duplicate column names with `.1`.

| Column | Type | Description |
|---|---|---|
| `col_0` | STRING | Region (unnamed in source). |
| `col_1` | STRING | CHD — Center for Health Development (unnamed in source). |
| `No. of Facilities` | DOUBLE | Government Level 1 infirmary count. |
| `ABC` | DOUBLE | Government Level 1 Authorized Bed Capacity. |
| `No. of Facilities.1` | DOUBLE | Government Level 2 infirmary count. |
| `ABC.1` | DOUBLE | Government Level 2 Authorized Bed Capacity. |
| `col_6` | DOUBLE | Government total facilities (unnamed in source). |
| `col_7` | DOUBLE | Government total ABC (unnamed in source). |
| `Total No. of Facilities` | DOUBLE | Grand total infirmaries (Government + Private). |
| `Total ABC` | DOUBLE | Grand total Authorized Bed Capacity. |
| `REGION` | STRING | Region label (extra column from source). |
| `col_11` | DOUBLE | Trailing source column (unnamed). |

#### Source-specific Handling

The workbook has the same multi-row header pattern as the hospital file. Use `header=3` to start at the true column-header row.

Enable Delta column mapping for source fields such as `No. of Facilities` and `Total ABC`. Use `overwriteSchema=true` on refreshes.

Unnamed source columns are retained as:

* `col_0`: Region
* `col_1`: CHD
* `col_6`: Government total facilities
* `col_7`: Government total ABC
* `col_11`: Trailing source column

---

### `public_health.bronze.government_medical_practitioners_by_region`

**Description:** Annual number of government-employed medical practitioners by Philippine region and profession (2012–2023).

| Property | Value |
|---|---|
| Source file | `TABLE 9.14 Number of Government Medical Practitioners by Region- 2012 to 2023.csv` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/health workforce/` |
| Provider | Philippine Statistics Authority (PSA) |
| Bronze table | `public_health.bronze.government_medical_practitioners_by_region` |
| Refresh mode | Overwrite |
| Expected coverage | 17 regions × 4 professional categories |

#### Data Structure

| Column | Type | Description |
|---|---|---|
| `Region` | STRING | Philippine region; the national total may include a prefix in the source. |
| `Professionals` | STRING | Professional category: Doctors, Dentists, Nurses, or Midwives. |
| `2012` | INT | Practitioner count for 2012. |
| `2013` | INT | Practitioner count for 2013. |
| `2014` | INT | Practitioner count for 2014. |
| `2015` | INT | Practitioner count for 2015. |
| `2016` | INT | Practitioner count for 2016. |
| `2017` | INT | Practitioner count for 2017. |
| `2018` | INT | Practitioner count for 2018. |
| `2019` | INT | Practitioner count for 2019. |
| `2020` | INT | Practitioner count for 2020. |
| `2021` | INT | Practitioner count for 2021. |
| `2022` | INT | Practitioner count for 2022. |
| `2023` | INT | Practitioner count for 2023. |

#### Source-specific Handling

The CSV begins with a title row and includes a repeated header row. Exclude both before writing the bronze table:

* Exclude records where `Region` starts with `TABLE`.
* Exclude the repeated header where `Region = 'Region'`.

Apply an explicit 14-column Spark schema. Schema inference alone can misread the title row and return a single-column dataset. Cast year columns to integers, and sanitize column names where needed for Delta compatibility.

#### Intended Analytical Use

This table supports analysis of public-health workforce trends, profession mix, and regional workforce distribution from 2012 through 2023. Treat zero counts with caution. They may represent missing or unreported values in the source.

---

### `public_health.bronze.psmo_oncologists`

**Description:** Philippine Society of Medical Oncologists (PSMO) oncologist count by region and province/area.

| Property | Value |
|---|---|
| Source file | `psmo_oncologists.csv` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/workforce/psmo_oncologists/` |
| Provider | Philippine Society of Medical Oncologists (PSMO) |
| Bronze table | `public_health.bronze.psmo_oncologists` |
| Refresh mode | Idempotent MERGE (upsert) |
| Merge key | `(region, province_area, as_of_date)` |
| Expected coverage | 52 rows per snapshot (regions and provinces nationwide) |

#### Data Structure

| Column | Type | Description |
|---|---|---|
| `region` | STRING | Philippine region (e.g. `NCR`, `CAR`, `Region 1`). |
| `province_area` | STRING | Province, city, or district within the region. Some values contain commas and are quoted in the source CSV. |
| `doctor_count` | INT | Number of PSMO oncologists in the region/province. |
| `source_file` | STRING | Filename of the source CSV (metadata column). |
| `as_of_date` | DATE | Data snapshot date, passed as a widget parameter (metadata column). |
| `ingested_at` | TIMESTAMP | Load timestamp via `current_timestamp()` (metadata column). |

#### Source-specific Handling

The CSV is clean with a standard header row (no title-row issues). An explicit Spark schema (3 fields) is applied instead of `inferSchema` to avoid an extra file scan and enforce correct types.

Three metadata columns are added during ingestion: `source_file` (basename of the source path), `as_of_date` (widget parameter, validated as `YYYY-MM-DD`), and `ingested_at` (current timestamp).

Unlike other bronze tables that use full overwrite, this table uses an idempotent MERGE on `(region, province_area, as_of_date)`. Re-running with the same `as_of_date` upserts matching rows; data from other snapshot dates is preserved.

#### Notebook Parameters (Widgets)

| Widget | Default | Description |
|---|---|---|
| `as_of_date` | `2026-06-30` | Data snapshot date in `YYYY-MM-DD` format. |
| `source_file_path` | `/Volumes/.../psmo_oncologists.csv` | Full path to the source CSV in the landing zone. |

Both parameters can be overridden when running as a job task via `--as_of_date` and `--source_file_path`.

---

### `public_health.bronze.globocan_2024_statistics_at_glance`

**Description:** GLOBOCAN 2024 summary cancer statistics for the Philippines, split by sex.

| Property | Value |
|---|---|
| Source file | `globocan_2024.xlsx` (sheet: `statistics_at_glance`) |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/diseases/neoplasm/globocan/` |
| Provider | GLOBOCAN 2024 / IARC (WHO) |
| Bronze table | `public_health.bronze.globocan_2024_statistics_at_glance` |
| Refresh mode | Idempotent (`CREATE OR REPLACE TABLE`) |

#### Data Structure

| Column | Type | Description |
|---|---|---|
| `metric_category` | STRING | Category: `population`, `incidence`, `mortality`, or `prevalence`. |
| `metric` | STRING | Specific metric name (e.g. `Population`, `Number of new cancer cases`). |
| `males` | DOUBLE | Value for males. |
| `females` | DOUBLE | Value for females. |
| `both_sexes` | DOUBLE | Value for both sexes combined. |
| `unit` | STRING | Unit: `persons`, `cases`, `rate`, `percent`, or `deaths`. |
| `source_page` | LONG | Page reference in the GLOBOCAN source document. |
| `source_file` | STRING | Basename of the source Excel file (metadata). |
| `source_sheet` | STRING | Sheet name (metadata). |
| `ingestion_date` | TIMESTAMP | Ingestion run timestamp (metadata). |

#### Source-specific Handling

Headers are clean at row 0. Object columns are cast to string for Arrow compatibility before conversion to Spark DataFrame.

---

### `public_health.bronze.globocan_2024_cancer_site_metrics`

**Description:** GLOBOCAN 2024 per-cancer-site metrics for the Philippines, including new cases, deaths, and prevalence.

| Property | Value |
|---|---|
| Source file | `globocan_2024.xlsx` (sheet: `cancer_site_metrics`) |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/diseases/neoplasm/globocan/` |
| Provider | GLOBOCAN 2024 / IARC (WHO) |
| Bronze table | `public_health.bronze.globocan_2024_cancer_site_metrics` |
| Refresh mode | Idempotent (`CREATE OR REPLACE TABLE`) |

#### Data Structure

| Column | Type | Description |
|---|---|---|
| `cancer_site` | STRING | Cancer site (e.g. `Breast`, `Lung`). Last two rows are `All cancers` and `All cancers excl. NMSC` totals. |
| `new_cases_number` | LONG | Number of new cancer cases. |
| `new_cases_rank` | DOUBLE | Rank by new case count. NULL for total rows. |
| `new_cases_percent` | DOUBLE | Percentage of all new cases. NULL for total rows. |
| `new_cases_cum_risk` | DOUBLE | Cumulative risk of developing this cancer before age 75. NULL for total rows. |
| `deaths_number` | LONG | Number of cancer deaths. |
| `deaths_rank` | DOUBLE | Rank by death count. NULL for total rows. |
| `deaths_percent` | DOUBLE | Percentage of all cancer deaths. NULL for total rows. |
| `deaths_cum_risk` | DOUBLE | Cumulative risk of dying from this cancer before age 75. NULL for total rows. |
| `prevalence_5yr_number` | LONG | 5-year prevalent case count. |
| `prevalence_prop_per_100k` | DOUBLE | 5-year prevalence proportion per 100k population. NULL for total rows. |
| `source_file` | STRING | Basename of the source Excel file (metadata). |
| `source_sheet` | STRING | Sheet name (metadata). |
| `ingestion_date` | TIMESTAMP | Ingestion run timestamp (metadata). |

#### Source-specific Handling

Headers are clean at row 0. The last two rows are summary totals with NULL rank and percentage values. Preserved in Bronze without filtering; Silver should exclude or flag them.

---

### `public_health.bronze.neoplasm_prevalence`

**Description:** IHME Global Burden of Disease (GBD) neoplasm prevalence estimates by Philippine province and cancer type (2021–2023).

| Property | Value |
|---|---|
| Source file | `neoplasm_prevalence.csv` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/diseases/neoplasm/IHME VizHub – GBD Results Tool/` |
| Provider | Institute for Health Metrics and Evaluation (IHME) |
| Bronze table | `public_health.bronze.neoplasm_prevalence` |
| Refresh mode | Idempotent MERGE (upsert) |
| Merge key | `(measure, location, cause, metric, year)` |
| Expected coverage | 82 provinces × 34 cancer causes × 3 years = 8,364 rows |

#### Data Structure

| Column | Type | Description |
|---|---|---|
| `measure` | STRING | Measure type — always `Prevalence` in the current dataset. |
| `location` | STRING | Philippine province (e.g. `Camarines Norte`, `Cebu`). 82 distinct values. |
| `cause` | STRING | Cancer type (e.g. `Breast cancer`, `Liver cancer`). 34 distinct values, including `Tracheal, bronchus, and lung cancer` which contains commas and is quoted in the source CSV. |
| `metric` | STRING | Metric type — always `Number` in the current dataset. |
| `year` | INT | Estimate year: 2021, 2022, or 2023. |
| `val` | DOUBLE | Point estimate of prevalence count. |
| `upper` | DOUBLE | Upper uncertainty bound. |
| `lower` | DOUBLE | Lower uncertainty bound. |
| `source_file` | STRING | Full UC volume path of the source CSV (metadata column). |
| `source_system` | STRING | Source system name: `IHME GBD Results Tool` (metadata column). |
| `ingestion_date` | TIMESTAMP | Load timestamp via `current_timestamp()` (metadata column). |

#### Source-specific Handling

The CSV uses a standard single-row header with no title-row issues. An explicit Spark `StructType` schema (8 fields) is applied instead of `inferSchema` to avoid an extra file scan and enforce correct types. The `cause` field `Tracheal, bronchus, and lung cancer` contains embedded commas and is quoted in the source CSV (246 lines). Spark's CSV reader handles this natively.

Source columns are trimmed and cast to their target types. Rows with a null `year` are filtered out as a defensive measure. `dropDuplicates` on the natural key `(measure, location, cause, metric, year)` removes any duplicate source rows before writing.

Three metadata columns are added: `source_file` (full source path), `source_system` (`IHME GBD Results Tool`), and `ingestion_date` (current timestamp).

#### Idempotent Load Strategy

Unlike bronze tables that use full overwrite, this table uses an idempotent MERGE on `(measure, location, cause, metric, year)`:

* **First run:** Creates the table with full overwrite and Delta column mapping.
* **Later runs:** Upserts matching rows via Delta `MERGE`. Only rows where `val`, `upper`, or `lower` have changed are updated (conditional `whenMatchedUpdate`). This avoids unnecessary writes. Unmatched rows are inserted.

Running the notebook any number of times produces the same result with no duplicate rows.

#### Error Handling

The write step is wrapped in `try/except` blocks. Both the `saveAsTable` action and the MERGE `execute` action run inside the `try` block. Exceptions are caught and re-raised with a descriptive error message.

#### Debug Mode

A `DEBUG` flag in the config cell controls an exploratory schema-inspection cell. When `DEBUG = False` (the default), the inspection cell is skipped to avoid unnecessary full scans in production.

---

### Bronze: Population domain

---

### `public_health.bronze.population_bronze` — Legacy PSA Population File Ingestion

**Status:** Legacy / retained in repository; not used by the current population Silver pipeline.

**Purpose**

Stores raw PSA population Excel sheets using positional columns. The loader does not interpret source headers during ingestion. Each loaded file and worksheet is tagged with source-file, worksheet, row, and snapshot-date metadata. The table is kept for historical reference. The current `population_silver` table is sourced from `populations_json` in `public_health.bronze.geography_bronze`, not from this table.

**Source**

PSA population Excel files in the configured Landing folder:

`/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/population`

The ingestion notebook selects files matching:

`population_YYYY_asof_YYYYMMDD.xlsx`

**Grain**

One row per source worksheet row, per source file, sheet, and snapshot. The ingestion notebook assigns `_source_row_num` within each worksheet. The source row is stored positionally across `c0` through `c13`.

**Refresh / idempotency behavior**

- By default, files already present in the table (identified by `_source_file`) are not loaded again.
- The `reload_all` parameter allows previously loaded files to be reloaded.
- Loading uses `REPLACE WHERE` for the matching `_source_file` and `_source_sheet` combination.
- The ingestion notebook checks that a source sheet does not exceed 14 columns.

#### Data Structure

| Column | Data Type | Description |
|---|---|---|
| `c0` | STRING | First positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c1` | STRING | Second positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c2` | STRING | Third positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c3` | STRING | Fourth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c4` | STRING | Fifth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c5` | STRING | Sixth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c6` | STRING | Seventh positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c7` | STRING | Eighth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c8` | STRING | Ninth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c9` | STRING | Tenth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c10` | STRING | Eleventh positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c11` | STRING | Twelfth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c12` | STRING | Thirteenth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `c13` | STRING | Fourteenth positional cell from the source worksheet. Meaning depends on the worksheet and source layout. |
| `_rescued_data` | STRING | Reserved for data rescued by the ingestion reader. The notebook currently writes `NULL`. |
| `_source_file` | STRING | Source Excel filename, expected to follow `population_YYYY_asof_YYYYMMDD.xlsx`. |
| `_source_sheet` | STRING | Worksheet name from the source Excel file. |
| `_source_row_num` | INT | Row number assigned during ingestion within the worksheet. |
| `_as_of_date` | DATE | Snapshot date parsed from the source filename. |
| `_ingested_at` | TIMESTAMP | UTC timestamp assigned to the batch when the worksheet is loaded. |

#### Source-specific Handling and Limitations

- The ingestion process does not parse or standardize source headers. All worksheet cells are loaded as positional string columns (`c0` to `c13`).
- The meaning of each positional column can vary by worksheet or file. Use the corresponding source file and worksheet to interpret them.
- The ingestion notebook validates the filename convention and checks for worksheets wider than 14 columns. It does not normalize the data into a year/value schema.
- This table is not the source for the current `population_silver` transformation. Current Silver population observations are parsed from `public_health.bronze.geography_bronze.populations_json`.

---

### Bronze: Socio-economic domain

Bronze tables use the config-driven naming convention `socioeconomic_<source>_<content>_bronze`. All data columns are STRING in bronze. Lineage columns are added by the loader. Sources are defined in `config/sources_socioeconomic.yaml`.

---

### `public_health.bronze.socioeconomic_psa_poverty_bronze`

**Description:** PSA official poverty statistics — per capita poverty threshold, poverty incidence among population, and magnitude of poor population, by region and province.

| Property | Value |
|---|---|
| Source file | `psa_poverty_province_biennial_2021_2025.xlsx` (sheets `tab2`, `tab6`) |
| Landing location | `/Volumes/.../g5_landing/socioeconomic/psa_poverty/` |
| Provider | Philippine Statistics Authority |
| Bronze table | `public_health.bronze.socioeconomic_psa_poverty_bronze` |
| Refresh mode | Upsert (merge keys: `area_name, year`) |
| Coverage | 18 regions (incl. NCR districts) and provinces; survey years 2021, 2023, 2025 |
| Sharing | Open |

| Column | Type | Description |
|---|---|---|
| `area_name` | STRING | Region or province name as published. |
| `threshold_2021` / `threshold_2023` / `threshold_2025` | STRING | Annual per capita poverty threshold (pesos). |
| `incidence_2021` / `incidence_2023` / `incidence_2025` | STRING | Poverty incidence among population (%). |
| `incidence_cv_*` / `incidence_se_*` | STRING | Coefficient of variation and standard error of incidence. |
| `incidence_ci_low_*` / `incidence_ci_high_*` | STRING | 95% confidence interval bounds of incidence. |
| `poor_pop_2021` / `poor_pop_2023` / `poor_pop_2025` | STRING | Magnitude of poor population ('000), tab6. |
| `poor_pop_cv_*` / `poor_pop_se_*` / `poor_pop_ci_*` | STRING | CV, SE and confidence interval of poor population. |
| `notes` | STRING | Source notes (e.g. low-precision flag `b/`). |
| Lineage columns | Various | `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`. |

Source-specific handling: Data starts at row 7. The loader uses `header_mode: names` with explicit column layouts. Sheet tab2 holds incidence and threshold. Sheet tab6 holds magnitude of poor. Footnote lines at the bottom of each sheet load as rows and are dropped in silver. The 2025 national poverty incidence control value is 9.7%.

---

### `public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze`

**Description:** PSA Table 9.26 — percent share of current health expenditure by financing agent, national, 2016–2023.

| Property | Value |
|---|---|
| Source file | `psa_health_expenditure_share_national_annual_2016_2023.csv` |
| Landing location | `/Volumes/.../g5_landing/socioeconomic/psa_health_expenditure/share_national_annual/` |
| Provider | Philippine Statistics Authority (Philippine National Health Accounts) |
| Bronze table | `public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze` |
| Refresh mode | Upsert (merge keys: `financing_agent, year`) |
| Sharing | Open |

| Column | Type | Description |
|---|---|---|
| `agent_level1` | STRING | Level-1 financing agent (e.g. General Government, Households). |
| `agent_level2` | STRING | Level-2 sub-agent (e.g. Department of Health, PHIC). Blank on level-1 rows. |
| `share_2016` … `share_2023` | STRING | Percent share for each year. `a/` = share below 0.05% (null token). |
| `col_3`, `col_5`, … `col_11` | STRING | Empty spacer columns from the source layout. |
| Lineage columns | Various | `_source_key`, `_source_file`, `_source_row_num`, `_as_of_date`. |

Source-specific handling: The table has a two-level hierarchy. Level 1 is in `agent_level1`. Sub-agents are in `agent_level2` with `agent_level1` blank. The silver layer carries the parent down. Households (out-of-pocket) = 44.4% in 2023. Never add a parent agent to its children.

---

### `public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze`

**Description:** PSA Table 9.24 — per capita health expenditure (pesos, current prices) and annual growth rate, national, 2016–2023.

| Property | Value |
|---|---|
| Source file | `psa_health_expenditure_per_capita_national_annual_2016_2023.csv` |
| Landing location | `/Volumes/.../g5_landing/socioeconomic/psa_health_expenditure/per_capita_national_annual/` |
| Provider | Philippine Statistics Authority (Philippine National Health Accounts) |
| Bronze table | `public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze` |
| Refresh mode | Upsert (merge keys: `indicator, year`) |
| Sharing | Open |

| Column | Type | Description |
|---|---|---|
| `indicator` | STRING | `Per Capita Health Expenditure` (amount) or growth-rate label. |
| `value_2016` … `value_2023` | STRING | Per-capita amount (pesos) or growth rate (%). |
| Lineage columns | Various | `_source_key`, `_source_file`, `_source_row_num`, `_as_of_date`. |

Source-specific handling: Row 4 (0-based) is the per capita amount. Row 7 is the growth rate for the period ending that year. The year header row is shifted one column left of the values. The 2023 per capita value is PHP 11,082.68.

---

### `public_health.bronze.socioeconomic_psa_child_mortality_bronze`

**Description:** PSA Table 9.9 — early childhood mortality rates (per 1,000) by region, residence, mother's education and wealth quintile, NDHS 2017 and 2022.

| Property | Value |
|---|---|
| Source file | `psa_child_mortality_region_survey_2017_2022.csv` |
| Landing location | `/Volumes/.../g5_landing/socioeconomic/psa_child_mortality/` |
| Provider | Philippine Statistics Authority (National Demographic and Health Survey) |
| Bronze table | `public_health.bronze.socioeconomic_psa_child_mortality_bronze` |
| Refresh mode | Upsert (merge keys: `characteristic_group, characteristic, survey_year`) |
| Sharing | Open |

| Column | Type | Description |
|---|---|---|
| `characteristic_group` | STRING | Background category (Region, Residence, Mother's Education, Wealth quintile). |
| `characteristic` | STRING | Specific value within the group (e.g. NCR, Urban, Lowest). |
| `imr_2022` / `imr_2017` | STRING | Infant mortality rate (per 1,000 live births). |
| `cmr_2022` / `cmr_2017` | STRING | Child mortality rate. |
| `u5mr_2022` / `u5mr_2017` | STRING | Under-five mortality rate. |
| Lineage columns | Various | `_source_key`, `_source_file`, `_source_row_num`, `_as_of_date`. |

Source-specific handling: The file uses encoding cp1252 (an en dash appears in a footnote). Values in parentheses mean 250 to 499 children, which is low precision. A `*` means fewer than 250 children and the value is suppressed. There are 17 regions, using the old definition (no Negros Island Region).

---

### Bronze: Workforce domain

Bronze tables use the config-driven naming convention `workforce_<source>_<content>_bronze`. Sources are defined in `config/sources_workforce.yaml`. Two workforce sources (`psa_gov_practitioners` and `psmo_oncologists`) are documented above under their earlier table names (`government_medical_practitioners_by_region` and `psmo_oncologists`). Their config-driven names are `workforce_psa_gov_practitioners_bronze` and `workforce_psmo_oncologists_bronze`.

---

### `public_health.bronze.workforce_fhsis_health_workers_bronze`

**Description:** DOH FHSIS Demographic Profile — number and ratio of public health workers (LGU-hired and DOH-hired) by area, 2018–2025.

| Property | Value |
|---|---|
| Source files | `doh_fhsis_demographic_province_annual_2018.xlsx` … `_2024.xlsx`, `doh_fhsis_demographic_municipality_annual_2025.xlsx` |
| Landing location | `/Volumes/.../g5_landing/workforce/doh_fhsis_demographic/` |
| Provider | Department of Health (FHSIS annual report) |
| Bronze table | `public_health.bronze.workforce_fhsis_health_workers_bronze` |
| Refresh mode | Upsert (merge keys: `area_name, year`) |
| Coverage | 2018–2024 national/region/province/city; 2025 down to municipality with PSGC |
| Sharing | Public |

| Column | Type | Description |
|---|---|---|
| `area_name` | STRING | Area as published (region, province, city, or municipality). 2025 also has `psgc_code`. |
| `population` | STRING | Population printed in the FHSIS workbook (not always present in 2018). |
| `doctors_lgu_hired` / `doctors_doh_hired` / `doctors_total` / `doctors_ratio` | STRING | Doctor counts and ratio. 2018 split is male/female instead of LGU/DOH. |
| `nurses_lgu_hired` / `nurses_doh_hired` / `nurses_total` / `nurses_ratio` | STRING | Nurse (PHN before 2024) counts and ratio. |
| `midwives_*` / `dentists_*` / `medtech_*` / `nutritionists_*` | STRING | Same LGU/DOH/total/ratio pattern per profession. |
| `sanitary_engineers_*` / `sanitary_inspectors_*` | STRING | Same pattern. |
| `bhw_lgu_hired` / `bhw_doh_hired` / `bhw_total` / `bhw_ratio` | STRING | Barangay Health Worker counts and ratio. |
| `household_estimates` | STRING | Household count (2019-2020, 2022, 2024-2025 only). |
| `col_<n>` | STRING | Empty spacer or scratch-calculation columns. |
| Lineage columns | Various | `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`. |

Source-specific handling: There is one workbook per year. The year is read from `_source_file`, not from a column. The layout changes by year: 3, 2, or 1 sheets, and the profession order differs. Labels MDs and PHNs are loaded as doctors and nurses. A `*` means no report (stored as null). A `0` can mean zero or no data (per the 2018 legend). Ratio columns are population per worker. Always recompute rates in gold. Never use the file ratios. Years 2018 to 2024 have no PSGC, so silver matches `area_name` to geography. The 2025 PSGC is mostly text with leading zeros.

---

### Shared ingestion metadata

---
### `public_health.bronze.ingestion_metadata`

**Purpose**

Stores batch-level ingestion metadata for monitoring, lineage, idempotency, and failure recovery.

**Grain**

One row per ingestion attempt.

| Column | Data Type | Description |
|---|---|---|
| `batch_id` | STRING | Unique identifier for the ingestion attempt. |
| `source_name` | STRING | Name of the source system being ingested. |
| `source_version` | STRING | Source version requested by the ingestion run. |
| `endpoint` | STRING | API endpoint used by the ingestion run. |
| `content_checksum` | STRING | Deterministic checksum of the logical source content, when available. |
| `raw_file_path` | STRING | Landing path associated with the ingestion run. |
| `record_count` | BIGINT | Number of logical source records retrieved by the run. |
| `page_count` | INT | Number of API pages retrieved by the run. |
| `retrieved_at` | TIMESTAMP | Timestamp when the ingestion attempt was created/retrieved. |
| `status` | STRING | Current ingestion-run status. Expected values include `in_progress`, `processed`, `failed`, and `skipped_duplicate`. |

---

## Silver Layer

### Silver: Disease domain

The disease silver tables are built by SQL scripts in `src/03_silver/diseases/`. Each script follows the write-audit-publish pattern: it classifies rows, captures inputs, builds a candidate table, runs validation gates, publishes the result, and records the build in `quality.build_log`.

Every silver row carries 7 lineage columns: `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, and `_metric_source_columns`. Load time, load ID, and file checksum are stored in `quality.build_inputs`, not on the row itself. You can join them with `quality.v_build_lineage`.

---

### `public_health.silver.diseases_metric_silver`

**Grain:** One measure of one disease, in one area, in one period, from one source.
**Key:** `(disease_key, area_key, period_grain, period_key, measure, _source_key)`

| Column | Type | Description |
|---|---|---|
| `disease_key` | STRING | Disease code from the disease directory. |
| `area_key` | STRING | Area key for joining to geography. |
| `period_basis` | STRING | Period convention (e.g. `calendar_year`, `source_date_unconfirmed`). |
| `period_grain` | STRING | `year`, `month`, or `week`. |
| `period_key` | STRING | Period label (year, `YYYY-MM`, or week identifier). |
| `period_label` | STRING | Display label for the period. |
| `year` | INT | Calendar year. |
| `month` | INT | Calendar month (monthly sources only). |
| `week` | INT | Week number (weekly sources only). |
| `period_start` / `period_end` | DATE | Period start/end dates (null for weekly dengue until week convention confirmed). |
| `measure` | STRING | Measure name (`cases`, `deaths`, `prevalence`). |
| `value` | DECIMAL(20,4) | Measure value. Null when `value_status` is not `ok`. |
| `value_status` | STRING | `ok`, `blank`, `no_report`, `parse_error`, or a source-specific status. |
| `is_complete_year` | BOOLEAN | Whether the area holds every period the source holds for the year. |
| Lineage (7 cols) | Various | `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_metric_source_columns`. |

Sources: DOH dengue surveillance (region by month), UP NOAH (region by week), HDX dengue (province by week), PSA registered deaths (national monthly/annual, region annual), FHSIS TB notifications, IHME modelled deaths and prevalence, and PhilHealth claims (aggregated only).

---

### `public_health.silver.diseases_deaths_age_silver`

**Grain:** Registered deaths of one cause, in one area, in one year, broken down by age group.
**Key:** `(disease_key, area_key, year, age_group, _source_key)`
**Source:** PSA deaths by region, annual (2023, 2024). This is the only source with age groups. Each bronze row becomes 20 rows: 19 age bands plus "not stated".

| Column | Type | Description |
|---|---|---|
| `disease_key` | STRING | Disease/cause code. |
| `area_key` | STRING | Area key. |
| `year` | INT | Reporting year (2023, 2024). |
| `age_group` | STRING | Age band code (e.g. `age_25_29`, `not_stated`). |
| `deaths` | DECIMAL(20,4) | Death count. Null when status is not `ok`. |
| `value_status` | STRING | `ok`, `blank`, `no_report`, `parse_error`. |
| Lineage (7 cols) | Various | Same 7 lineage columns; `_metric_source_columns` maps `{deaths: 'age_25_29'}`. |

---

### `public_health.silver.diseases_source_coverage_silver`

**Grain:** One source's coverage of one area in one year. The row says whether the source reports every period of the year for that area.
Gold `fact_disease_metric` uses this to set `is_complete_year`.

| Column | Type | Description |
|---|---|---|
| `_source_key` | STRING | Source dataset key. |
| `area_key` | STRING | Area key. |
| `year` | INT | Year. |
| `periods_present` | INT | Distinct periods the area has for the year. |
| `is_complete_year` | BOOLEAN | Whether the area holds every period the source holds. |
| Lineage (7 cols) | Various | Standard lineage columns. |

---

### `public_health.silver.diseases_tb_programme_silver`

**Grain:** One TB programme indicator, in one area, in one year, split by sex.
**Key:** `(disease_key, area_key, year, indicator, sex, _source_key)`
**Source:** FHSIS 2025 (TB preventive treatment and treatment success). The `disease_key` column distinguishes drug-sensitive TB (`tb_all_forms`) from drug-resistant TB (`tb_drug_resistant`).

| Column | Type | Description |
|---|---|---|
| `disease_key` | STRING | `tb_all_forms` or `tb_drug_resistant`. |
| `area_key` | STRING | Area key. |
| `year` | INT | Reporting year (2025). |
| `indicator` | STRING | `tpt_given`, `tpt_eligible_contacts`, `treatment_cohort`, `treatment_success`. |
| `indicator_definition` | STRING | Definition of the indicator. |
| `sex` | STRING | `male`, `female`, or `both_sexes`. |
| `value` | DECIMAL(20,4) | Indicator value. `tpt_eligible_contacts` is an FHSIS estimate (notified × 4 × 70%). |
| `value_status` | STRING | `ok`, `estimated`, `blank`, etc. |
| Lineage (7 cols) | Various | Standard lineage columns. |

---

### `public_health.silver.diseases_hospital_claims_silver`

**Grain:** PhilHealth hospital claims aggregated by area, year, and case-rate package. This table is **RESTRICTED**. Hospital identity is removed. Only aggregate counts are published. Cells built from fewer than the minimum number of hospitals are suppressed to protect confidentiality.
**Key:** `(area_key, year, case_rate_package, metric, _source_key)`

| Column | Type | Description |
|---|---|---|
| `area_key` | STRING | Hospital's city/municipality (where care was delivered, not patient residence). |
| `year` | INT | Admission year (2016–2025). |
| `case_rate_package` | STRING | PhilHealth case-rate package (14 packages). |
| `metric` | STRING | `claims_filed`, `claims_paid`, `claims_amount_claimed_php`, `claims_paid_amount_claimed_php`. |
| `value` | DECIMAL(20,4) | Claim count or amount (PHP). |
| `value_status` | STRING | `ok` or `suppressed` (fewer than `suppression_min_hospitals`). |
| `claim_status` | STRING | Claim status filter applied (all statuses for utilisation; paid only for money). |
| Lineage (7 cols) | Various | Standard lineage columns. |

---

### `public_health.silver.diseases_directory_silver`

**Grain:** One disease or cause in the disease directory. This is a reference table.
**Key:** `disease_key`

| Column | Type | Description |
|---|---|---|
| `disease_key` | STRING | Disease code (natural key). |
| `disease_name` | STRING | Disease name. |
| `related_condition_group` | STRING | Reviewed group linking one condition across lists (tuberculosis, dengue, stroke, …). |
| `classification` | STRING | `psa_tabulation_list`, `ihme_gbd`, `programme`, or `phic_case_rate_package`. |
| `cause_level` | STRING | `0` all_causes, `1` group, `2` cause, `3` sub_cause. |
| `parent_disease_key` | STRING | Parent cause code (for hierarchy). |
| `is_focus_disease` | STRING | Whether the disease is a selected focus disease (`true`/`false`). |

---

### `public_health.silver.diseases_cause_aggregation`

**Grain:** The death-composition category (communicable, noncommunicable, or injury) for one disease code. This is a reference table.
**Key:** `disease_key`

| Column | Type | Description |
|---|---|---|
| `disease_key` | STRING | Disease code. |
| `category` | STRING | Death-composition category (communicable, noncommunicable, injury, etc.). |

Built by `diseases_silver_00_reference.sql`. A PSA cause takes the category of its chapter. IHME and programme causes have no category.

---

### Silver: Geography domain

The geography silver tables are documented in the [key tables section above](#data-dictionary) (`geography_silver` and `population_silver`). The geography domain also builds:

---

### `public_health.silver.admin_boundaries_silver`

**Grain:** One administrative boundary feature, per administrative level, per source version.
**Key:** `(psgc_code, admin_level, source_version)`
**Source:** HDX COD-AB bronze (`geography_phl_admin_boundaries`).

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC code matched to the boundary (left-padded to 10 digits). |
| `admin_level` | INT | Administrative level: 1 (region), 2 (province), 3 (municipality/city). |
| `boundary_level` | STRING | `region`, `province`, or `locality`. |
| `boundary_pcode` | STRING | HDX p-code. |
| `area_sqkm` | DOUBLE | Administrative area in square kilometres. |
| `center_lat` / `center_lon` | DOUBLE | Source-provided centre coordinates. |
| `source_version` | STRING | HDX source version (SHA-256 checksum of the archive). |
| `silver_processed_at` | TIMESTAMP | Silver processing timestamp. |

---

### Silver: Facilities domain

The facilities silver tables are documented in the [key tables section above](#data-dictionary) (`facilities_registry_silver`, `facilities_bed_occupancy_silver`, and `facilities_metric_silver`). The facilities domain also builds:

---

### `public_health.silver.facilities_id_map_silver`

**Grain:** One cross-source facility mapping row.
**Key:** `(source_record_id, _source_key)`

This table matches facilities from the NHFR (National Health Facility Registry) and HFSRB (Health Facilities and Services Regulatory Board) lists into a single stable `facility_key`. It carries address lineage columns and `_first_build_id`. Rows with an ambiguous `nhfr_code` are moved to `quality.quarantine` with the reason `ambiguous_nhfr_code`.

---

### `public_health.silver.facilities_osm_point_silver`

**Grain:** One OpenStreetMap health facility point, placed in a city or municipality.
**Key:** `osm_key` (`osm_type/osm_id`)
**Status:** The OSM point-in-polygon step is not yet built. The `shapely` library is not installed on serverless compute, and geography silver does not yet have polygon geometry. The scripts are `facilities_silver_04_osm_point.sql` and `04a_osm_locate.py`.

---
### Silver: Population domain

---

### `public_health.silver.population_silver`

**Purpose**

Stores population observations parsed from the `populations_json` array in `public_health.bronze.geography_bronze`. Each JSON array element becomes one Silver row. This makes population values available for filtering, joins, trend analysis, and downstream population-based metrics.

**Source**

`public_health.bronze.geography_bronze`, specifically the `populations_json` column. Geographic identity and source lineage are carried from the Bronze record.

**Grain**

One row per `psgc_code × population_year × source_version`.

**Natural grain key**

`psgc_code + population_year + source_version`

#### Data Structure

| Column | Data Type | Description |
|---|---|---|
| `psgc_code` | STRING | Philippine Standard Geographic Code inherited from the Bronze geography record. Identifies the geographic area associated with the population observation. |
| `population_year` | INT | Year to which the population observation applies, parsed from the nested JSON observation's `year` field. |
| `population` | BIGINT | Parsed population count. Source text is trimmed and commas are removed before conversion. Values that cannot be converted remain null and are identified by `population_parse_status`. |
| `population_raw` | STRING | Original population value from the nested JSON observation, retained for traceability and troubleshooting. |
| `population_parse_status` | STRING | Parse outcome for the source population value. Expected values: `VALID`, `MISSING`, or `INVALID`. |
| `source_version` | STRING | Version of the PSA PSGC source snapshot associated with the Bronze record (e.g. `Q2_2024`). |
| `batch_id` | STRING | Identifier of the Bronze ingestion batch from which the observation was derived. |
| `silver_processed_at` | TIMESTAMP | Timestamp when the population observation was transformed and written to Silver. |

---

### Socio-economic domain

The socioeconomic silver tables are built by SQL scripts in `src/03_silver/socioeconomic/`. They follow the same write-audit-publish pattern and lineage contract as the other domains.

---

### `public_health.silver.socioeconomic_poverty_silver`

**Grain:** Official poverty statistics of one area in one reporting year.
**Key:** `(area_key, year)`
**Source:** PSA official poverty statistics, sheets tab2 (incidence and threshold) and tab6 (magnitude of poor), for 2021, 2023, and 2025.

| Column | Type | Description |
|---|---|---|
| `area_key` | STRING | Area key matched to geography. |
| `year` | INT | Survey year (2021, 2023, 2025). |
| `poverty_incidence_pct` | DECIMAL(20,4) | Poverty incidence among population (%). Null when not published. |
| `poor_population` | DECIMAL(20,4) | Magnitude of poor population ('000). |
| `incidence_status` / `poor_pop_status` | STRING | `ok`, `not_published`, `not_computed`, `parse_error`. |
| `comparison_eligible` | BOOLEAN | Whether the estimate is comparable with PSGC-based areas. |
| `exclusion_reason` | STRING | Why the row is not comparison-eligible (if any). |
| `value_note` | STRING | PSA precision label (e.g. incidence precision). |
| Lineage (9 cols) | Various | `_silver_build_id`, `_source_key`, `_source_file`, `_as_of_date`, `_incidence_source_sheet`, `_incidence_source_row_num`, `_magnitude_source_sheet`, `_magnitude_source_row_num`, `_metric_source_columns`. |

Rows with `comparison_eligible = false` are kept, not dropped. Never sum or average poverty percentages. Provinces created after 2021 (Maguindanao del Norte and Maguindanao del Sur) are blank for earlier years.

---

### `public_health.silver.socioeconomic_health_expenditure_share_silver`

**Grain:** Percent share of current health expenditure for one financing agent in one year.
**Key:** `(financing_agent, year)`
**Source:** PSA Table 9.26, national, 2016–2023. Each bronze row becomes 8 rows, one per year.

| Column | Type | Description |
|---|---|---|
| `financing_agent` | STRING | Financing agent name (16 agents, two-level hierarchy). |
| `parent_agent` | STRING | Parent agent in the hierarchy. |
| `agent_level` | INT | Hierarchy level (1 or 2). |
| `year` | INT | Year (2016–2023). |
| `share_pct` | DECIMAL(20,4) | Percent share of current health expenditure. |
| `share_status` | STRING | `ok` or parse status. |
| Lineage (7 cols) | Various | `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet` (null), `_source_row_num`, `_as_of_date`, `_metric_source_columns`. |

Never add a parent agent to its children. Households (out-of-pocket) = 44.4% in 2023.

---

### `public_health.silver.socioeconomic_health_expenditure_per_capita_silver`

**Grain:** Per capita health expenditure or growth rate in one year.
**Key:** `(indicator, year)`
**Source:** PSA Table 9.24, national, 2016–2023.

| Column | Type | Description |
|---|---|---|
| `indicator` | STRING | `per_capita_health_expenditure` or `growth_rate`. |
| `year` | INT | Year (2016–2023). |
| `value` | DECIMAL(20,4) | Amount (pesos) or growth rate (%). |
| `value_status` | STRING | `ok` or parse status. |
| Lineage (7 cols) | Various | Standard lineage columns. |

2023 per capita = PHP 11,082.68. The 2021 and 2022 values are revised (marked `r`). The population basis changes in 2020 (census) and 2021 (2020-based projections).

---

### `public_health.silver.socioeconomic_child_mortality_silver`

**Grain:** One childhood mortality rate for one characteristic group in one survey year.
**Key:** `(characteristic_group, characteristic, survey_year)`
**Source:** PSA Table 9.9 (NDHS 2017 and 2022).

| Column | Type | Description |
|---|---|---|
| `characteristic_group` | STRING | Background category (Region, Residence, Mother's Education, Wealth quintile). |
| `characteristic` | STRING | Specific value within the group. |
| `survey_year` | INT | NDHS survey year (2017 or 2022). |
| `imr` | DECIMAL(20,4) | Infant mortality rate (per 1,000). |
| `cmr` | DECIMAL(20,4) | Child mortality rate. |
| `u5mr` | DECIMAL(20,4) | Under-five mortality rate. |
| `value_status` | STRING | `ok`, `low_precision` (parentheses), `suppressed` (*), etc. |
| Lineage (7 cols) | Various | Standard lineage columns. |

Equity angle: under-five mortality by wealth quintile ranges from 35 (lowest) to 8 (highest) in 2022.

---

### Workforce domain

The workforce silver tables are built by SQL scripts in `src/03_silver/workforce/`. They follow the same write-audit-publish pattern and lineage contract.

---

### `public_health.silver.workforce_headcount_silver`

**Grain:** One profession in one area in one year from one source.
**Key:** `(_source_key, area_key, year, profession)`
**Sources:** FHSIS 2018–2025 (`doh_fhsis_demographic`) and PSA Table 9.14 2012–2023 (`psa_gov_practitioners`).

| Column | Type | Description |
|---|---|---|
| `_source_key` | STRING | Source dataset key. |
| `area_key` | STRING | Area key matched to geography. |
| `year` | INT | Reporting year. |
| `profession` | STRING | Profession (doctors, dentists, nurses, midwives, nutritionists, medtech, sanitary_engineers, sanitary_inspectors, bhw). |
| `headcount_total` | DECIMAL(20,4) | Total headcount. Null when status is not `ok` (silver stores 0 for 2018 "0 = No Data" → becomes null). |
| `headcount_status` | STRING | `ok`, `blank`, `no_report`, `zero_no_data`, `parse_error`. |
| `analysis_eligible` | BOOLEAN | Whether the row is eligible for rate analysis (refers to `headcount_total`). |
| `source_role` | STRING | `preferred`, `cross_check`, or `fallback` (PSA 2018–2023 is `cross_check` against FHSIS). |
| `is_break_year` | BOOLEAN | Whether the series definition changes this year (e.g. nurses 2019). |
| Lineage (7 cols) | Various | `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_metric_source_columns`. |

Null is not the same as zero. Filter to `source_role = 'preferred'` or to one source, or the query will double count. Country, region, province, city, and municipality rows sit together. Never add a province to its listed cities.

---

### `public_health.silver.workforce_area_denominator_silver`

**Grain:** One area in one year. Population and households as printed by FHSIS. This table is for cross-check only. The A5 and W1 rates use the population domain (decision D4).
**Key:** `(_source_key, area_key, year)`

| Column | Type | Description |
|---|---|---|
| `_source_key` | STRING | Source dataset key. |
| `area_key` | STRING | Area key. |
| `year` | INT | Reporting year. |
| `reported_population` | DOUBLE | Population as printed by FHSIS. |
| `households` | DOUBLE | Household count as printed by FHSIS (2019-2020, 2022, 2024-2025 only). |
| `population_status` / `households_status` | STRING | `ok`, `blank`, `no_report`, `zero_no_data`, `parse_error`. |
| Lineage (combined) | Various | Shared: `_silver_build_id`, `_source_key`, `_source_file`, `_as_of_date`, `_metric_source_columns`. Per side: `_population_source_sheet`/`_row_num`, `_households_source_sheet`/`_row_num`. |

Population comes from different sheets than households. A side's lineage columns are filled only when that side contributes (indicated by `households_source_present`).

---

### `public_health.silver.workforce_specialist_silver`

**Grain:** One specialist profession in one area (snapshot).
**Key:** `(_source_key, area_key)`
**Source:** PSMO oncologist directory (`psmo_oncologists`).

| Column | Type | Description |
|---|---|---|
| `_source_key` | STRING | Source dataset key. |
| `area_key` | STRING | Area key matched to geography. |
| `profession` | STRING | Specialist profession (e.g. `medical_oncologists`). |
| `headcount` | INT | Specialist count. |
| `as_of_date` | DATE | Snapshot date. |
| Lineage (7 cols) | Various | Standard lineage columns. |

PSMO members only (medical oncology). This excludes radiation and surgical oncologists. Geography is mixed: provinces, cities, and NCR districts.

---

## Gold Layer

The active gold model is **v2**, in schema `public_health.test_gold2`. Scripts are in `src/04_gold/test_v2/` named `gold_v2_NN_<name>.sql`. The model has 5 dimensions, 4 facts, 4 reference tables or views, and 11 marts. Every table (not view) follows the write-audit-publish pattern: inputs, candidate, gates, publish, and `quality.build_log`. Surrogate keys are `xxhash64` of the natural key, so they stay stable across rebuilds. Build order: 00, then {11, 21, 31, 12, 13}, then {20, 30, 35, 40}, then {41, 43, 42, 44}, then 51, 52, {53, 54}, {55, 56, 57}, {61, 62, 63}, 71.

`mart_area_service_profile` (v2) is documented in the [key tables section above](#data-dictionary) (62 columns, verified schema). The remaining tables are documented below.

---

### Dimensions

---

### `public_health.test_gold2.dim_geography`

**Grain:** One area in the current PSGC snapshot (one row per `area_code`), plus named areas that have no PSGC code.
**Primary key:** `area_key` (BIGINT). **Natural key:** `(area_code)`.
**Reads:** `geography_silver`, `admin_boundaries_silver`, and named areas (reviewed list).

| Column | Type | Description |
|---|---|---|
| `area_key` | BIGINT | Surrogate key (PK). |
| `area_code` | STRING | Area code (`psgc:<code>` or named code). |
| `psgc_code` | STRING | PSGC code (null for named areas). |
| `area_name` | STRING | Area name (ñ repaired). |
| `geographic_level` | STRING | `region`, `province`, `city`, `municipality`, `submunicipality`, `special_geographic_area`, `country`, `foreign`. |
| `income_class` | STRING | Income class (`1st`–`5th`). |
| `city_class` | STRING | `HUC`, `ICC`, or `CC` (cities only). |
| `parent_area_key` | BIGINT | Parent area key. |
| `region_key` | BIGINT | Region area key. |
| `province_key` | BIGINT | Province area key (null for NCR/HUCs). |
| `planning_unit_key` | BIGINT | Planning unit key (province without HUCs, each HUC, NCR). |
| `broad_unit_key` | BIGINT | Broad unit key (province + its HUCs); null for HUCs outside NCR. |
| `area_sqkm` | DOUBLE | Boundary area (from admin_boundaries_silver). |
| `center_lat` / `center_lon` | DOUBLE | Boundary centre coordinates. |
| `has_boundary` | BOOLEAN | Whether a boundary feature matched. |
| `snapshot_date` | DATE | Quarter end of the source version (Q2_2024 → 2024-06-30). |
| `_gold_build_id` | STRING | Gold build identifier. |

Barangays and the placeholder row `0990100000` are excluded. `planning_unit_key` follows open decision 2.

---

### `public_health.test_gold2.dim_date`

**Grain:** One reporting period under one period convention (year, month, week, or snapshot date).
**Primary key:** `date_key` (BIGINT). **Natural key:** `(period_basis, period_label)`.

| Column | Type | Description |
|---|---|---|
| `date_key` | BIGINT | Surrogate key (PK). |
| `period_basis` | STRING | `calendar_year`, `month`, `source_date_unconfirmed`, `snapshot`. |
| `period_grain` | STRING | `year`, `month`, `week`, or `snapshot`. |
| `period_label` | STRING | Period label (year, `YYYY-MM`, week identifier, or `YYYY-MM-DD`). |
| `year` | INT | Calendar year. |
| `month` | INT | Calendar month (monthly only). |
| `week` | INT | Week number (weekly only). |
| `period_start` / `period_end` | DATE | Period start/end (null for weekly dengue until week convention confirmed). |
| `is_pandemic_period` | BOOLEAN | Whether the period falls in the pandemic window (2020–2022, configurable). |
| `_gold_build_id` | STRING | Gold build identifier. |

One row per reporting period, not per day. Sources report by year, month, week, or snapshot.

---

### `public_health.test_gold2.dim_data_source`

**Grain:** One source dataset, keyed by the `_source_key` that silver rows carry.
**Primary key:** `data_source_key` (BIGINT). **Natural key:** `(source_dataset)`.

| Column | Type | Description |
|---|---|---|
| `data_source_key` | BIGINT | Surrogate key (PK). |
| `source_name` | STRING | Human-readable source name. |
| `source_organization` | STRING | Publishing organisation. |
| `source_dataset` | STRING | Dataset key (the `_source_key` silver rows carry). |
| `value_type` | STRING | `reported`, `registered`, `modelled`, or `estimated`. |
| `source_as_of_date` | DATE | Source as-of date. |
| `sharing` | STRING | `open`, `public`, or `restricted`. |
| `license` | STRING | Licence (e.g. CC BY 4.0, ODbL, IHME agreement). |
| `source_domain` | STRING | Domain (`diseases`, `facilities`, `workforce`, `socioeconomic`). |
| `used_in` | STRING | Which v2 table reads the source. |
| `_gold_build_id` | STRING | Gold build identifier. |

Reviewed list of 25+ source datasets, copied by hand from the `sources_<domain>.yaml` files.

---

### `public_health.test_gold2.dim_facility`

**Grain:** One facility establishment in `facilities_registry_silver` (listed, or carried as `not_listed`).
**Primary key:** `facility_key` (BIGINT). **Natural key:** `(facility_source_id)`.
**Reads:** `facilities_registry_silver` and `dim_geography`.

| Column | Type | Description |
|---|---|---|
| `facility_key` | BIGINT | Surrogate key (PK). |
| `facility_source_id` | STRING | Registry `facility_key` (natural key). |
| `facility_name` | STRING | Facility name. |
| `area_key` | BIGINT | Area key (city, municipality, or Manila submunicipality). |
| `facility_category` | STRING | `hospital`, `infirmary`, `primary_care`, or `dialysis_clinic`. |
| `hospital_level` | STRING | `Level 1`, `Level 2`, `Level 3`, or `unknown` (hospitals only; null otherwise). |
| `ownership` | STRING | `government` or `private` (lowercase). |
| `facility_status` | STRING | `listed` or `not_listed`. Only listed facilities are counted. |
| `authorized_beds` | BIGINT | Authorized Bed Capacity. |
| `analysis_beds` | BIGINT | Beds used for analysis. |
| `analysis_beds_basis` | STRING | Basis of the analysis bed count. |
| `dialysis_stations` | BIGINT | Dialysis station count (K1). Null = not reported, never zero. |
| `is_license_valid_on_as_of` | BOOLEAN | Whether the license is valid as of the snapshot date (A3, A4). |
| `_gold_build_id` | STRING | Gold build identifier. |

---

### `public_health.test_gold2.dim_disease`

**Grain:** One disease or cause.
**Primary key:** `disease_key` (BIGINT). **Natural key:** `(disease_code)`.
**Reads:** `diseases_directory_silver` and `diseases_cause_aggregation`.

| Column | Type | Description |
|---|---|---|
| `disease_key` | BIGINT | Surrogate key (PK). |
| `disease_code` | STRING | Disease code (natural key). |
| `disease_name` | STRING | Disease name. |
| `disease_group` | STRING | Related condition group (tuberculosis, dengue, stroke, chronic_kidney_disease, …). |
| `cause_group` | STRING | Death composition category (communicable, noncommunicable, injury, …). |
| `classification` | STRING | `psa_tabulation_list`, `ihme_gbd`, `programme`, or `phic_case_rate_package`. |
| `cause_level` | STRING | `all_causes`, `group`, `cause`, or `sub_cause`. |
| `parent_disease_key` | BIGINT | Parent disease key (for hierarchy). |
| `is_focus_disease` | BOOLEAN | Whether the disease is a selected focus disease (N2, case studies). |
| `_gold_build_id` | STRING | Gold build identifier. |

A cause is never summed with its children. PSA, IHME, programme, and PhilHealth case-rate packages are different lists. Never sum them together.

---

### Facts

---

### `public_health.test_gold2.fact_facility_capacity`

**Grain:** One capacity measurement of one facility group (category, ownership, hospital level) in one area and period, from one source and capacity basis.
**Primary key:** `fact_facility_capacity_key` (BIGINT).
**Grain key:** `(area_key, date_key, data_source_key, capacity_basis, facility_category, ownership, hospital_level)`.
**Reads:** `facilities_registry_silver`, `facilities_metric_silver`, `facilities_bed_occupancy_silver`, `dim_geography`, `dim_date`, and `dim_data_source`.

Three bases in one table, kept apart by `capacity_basis`:

| `capacity_basis` | Replaces (v1) | Description |
|---|---|---|
| `registry_snapshot` | fact_area_facility_capacity_snapshot | Listed facilities per city/municipality at the latest registry snapshot. |
| `published_statistic` | fact_facility_published | PSA and FHSIS published counts by area and year. |
| `occupancy_report` | fact_bed_occupancy | Bed occupancy of reporting hospitals (RESTRICTED, aggregates only). |

| Column | Type | Description |
|---|---|---|
| `fact_facility_capacity_key` | BIGINT | Surrogate key (PK). |
| `area_key` | BIGINT | Area key. |
| `date_key` | BIGINT | Period key (FK to dim_date). |
| `data_source_key` | BIGINT | Source key (FK to dim_data_source). |
| `capacity_basis` | STRING | `registry_snapshot`, `published_statistic`, or `occupancy_report`. |
| `coverage_basis` | STRING | Geographic coverage basis. |
| `facility_category` | STRING | `hospital`, `barangay_health_station`, `rural_health_unit`, `main_health_center`, `city_health_center`, `health_center_total`. |
| `ownership` | STRING | `government`, `private`, or `total`. |
| `hospital_level` | STRING | `Level 1`–`3`, `unknown`, or `all` (null for non-hospital published). |
| `facility_count` | BIGINT | Number of facilities (registry, published). |
| `authorized_beds` | BIGINT | Authorized beds. |
| `analysis_beds` | BIGINT | Analysis beds. |
| `dialysis_stations` | BIGINT | Dialysis stations (registry, null when no facility has a count). |
| `bor_pct` | DOUBLE | Bed occupancy rate (occupancy_report only). |
| `implementing_beds` | BIGINT | Implementing beds (occupancy_report only). |
| `reporting_hospitals` | INT | Number of reporting hospitals (occupancy_report only). |
| `value_status` | STRING | `ok` or suppression/suppression status. |
| `_gold_build_id` | STRING | Gold build identifier. |

ALWAYS filter `capacity_basis` before adding anything up. Each basis fills only its own measure columns. The others are null.

---

### `public_health.test_gold2.fact_disease_metric`

**Grain:** One metric of one disease, area, period, age group, and sex from one source.
**Primary key:** `fact_disease_metric_key` (BIGINT).
**Grain key:** `(disease_key, area_key, date_key, data_source_key, age_group, sex, metric_name, metric_basis)`.
**Reads:** `diseases_metric_silver`, `diseases_source_coverage_silver`, `diseases_deaths_age_silver`, `diseases_tb_programme_silver`, `diseases_hospital_claims_silver`, `dim_disease`, `dim_geography`, `dim_date`, and `dim_data_source`.

Four row sources, kept apart by `data_source_key` and `metric_name`:

| Source | metric_name | Notes |
|---|---|---|
| metric (diseases_metric_silver) | `cases`, `deaths`, `prevalence` | One gold row per silver row. |
| deaths_by_age (deaths_deaths_age_silver) | `deaths` | `metric_definition = registered_deaths`, own age group. |
| tb_programme (diseases_tb_programme_silver) | `tpt_given`, `tpt_eligible_contacts`, `treatment_cohort`, `treatment_success` | Has a sex split. |
| claims (diseases_hospital_claims_silver) | `claims_filed`, `claims_paid`, `claims_amount_claimed_php`, … | RESTRICTED, aggregated, small cells suppressed. |

| Column | Type | Description |
|---|---|---|
| `fact_disease_metric_key` | BIGINT | Surrogate key (PK). |
| `disease_key` | BIGINT | FK to dim_disease. |
| `area_key` | BIGINT | FK to dim_geography. |
| `date_key` | BIGINT | FK to dim_date. |
| `data_source_key` | BIGINT | FK to dim_data_source. |
| `metric_name` | STRING | `cases`, `deaths`, `prevalence`, `tpt_*`, `treatment_*`, `claims_*`. |
| `metric_definition` | STRING | `registered_deaths`, indicator definition, etc. |
| `metric_basis` | STRING | `number` (counts). Rates are computed in marts. |
| `age_group` | STRING | Age band code (`all_ages` for metric rows). |
| `age_group_name` | STRING | Age band display name. |
| `age_min` / `age_max` | INT | Age band bounds. |
| `sex` | STRING | `male`, `female`, or `both_sexes` (`both_sexes` for non-TB rows). |
| `value` | DECIMAL(20,4) | Metric value. Null when `value_status` is not `ok`; never read as 0. |
| `value_status` | STRING | `ok`, `suppressed`, `estimated`, etc. |
| `value_lower` / `value_upper` | DOUBLE | Uncertainty bounds (IHME). |
| `coverage_basis` | STRING | Geographic coverage basis (claims: `facility_location`, `facility_location_province_excl_huc`, `facility_location_region`). |
| `is_complete_year` | BOOLEAN | Whether the area holds every period the source holds (metric rows only). |
| `is_preliminary` | BOOLEAN | Whether the latest year is preliminary. |
| `is_break_year` | BOOLEAN | Whether the series definition changes this year. |
| `_gold_build_id` | STRING | Gold build identifier. |

For totals, filter `age_group = 'all_ages' AND sex = 'both_sexes'`. The preferred source per measure comes from `source_priority`.

---

### `public_health.test_gold2.fact_workforce_capacity`

**Grain:** Headcount of one profession in one area and year from one source.
**Primary key:** `fact_workforce_capacity_key` (BIGINT).
**Grain key:** `(area_key, date_key, profession_code, data_source_key)`.
**Reads:** `workforce_headcount_silver`, profession names and groups (reviewed list), `dim_geography`, `dim_date`, and `dim_data_source`.

| Column | Type | Description |
|---|---|---|
| `fact_workforce_capacity_key` | BIGINT | Surrogate key (PK). |
| `area_key` | BIGINT | FK to dim_geography. |
| `date_key` | BIGINT | FK to dim_date. |
| `data_source_key` | BIGINT | FK to dim_data_source. |
| `profession_code` | STRING | Profession code (doctors, nurses, midwives, bhw, …). |
| `profession_name` | STRING | Display name. |
| `profession_group` | STRING | `core_clinical` (doctors, nurses, midwives), `community` (BHW), `other`. |
| `headcount_total` | DECIMAL(20,4) | Headcount. Null when status is not ok; never 0. |
| `headcount_status` | STRING | `ok`, `blank`, `zero_no_data`, etc. |
| `analysis_eligible` | BOOLEAN | Whether the row is eligible for rate analysis. |
| `source_role` | STRING | `preferred`, `cross_check`, or `fallback` (same role words as source_priority). |
| `is_break_year` | BOOLEAN | Whether the series definition changes this year (nurses 2019). |
| `_gold_build_id` | STRING | Gold build identifier. |

Filter to `source_role = 'preferred'` or to one source to avoid double counting. Rows that are not `analysis_eligible` are kept.

---

### `public_health.test_gold2.fact_area_indicator`

**Grain:** One population or socioeconomic indicator of one area and period from one source (long format).
**Primary key:** `fact_area_indicator_key` (BIGINT).
**Grain key:** `(area_key, date_key, data_source_key, indicator_name, indicator_category)`.
**Reads:** `population_silver`, `workforce_area_denominator_silver`, `socioeconomic_poverty_silver`, `socioeconomic_health_expenditure_share_silver`, `socioeconomic_health_expenditure_per_capita_silver`, `dim_geography`, `dim_date`, and `dim_data_source`.

Three v1 tables in one long table:

| indicator_name | indicator_category | Replaces (v1) |
|---|---|---|
| `population` | `census` (psa_psgc) or `reported` (FHSIS) | fact_population |
| `poverty_incidence_pct` / `poor_population` | `poverty` | fact_poverty |
| `health_expenditure_share_pct` / `health_expenditure_per_capita_php` / `_growth_pct` | `agent` (share) or per-capita | context_health_expenditure |

| Column | Type | Description |
|---|---|---|
| `fact_area_indicator_key` | BIGINT | Surrogate key (PK). |
| `area_key` | BIGINT | FK to dim_geography. |
| `date_key` | BIGINT | FK to dim_date. |
| `data_source_key` | BIGINT | FK to dim_data_source. |
| `indicator_name` | STRING | `population`, `poverty_incidence_pct`, `poor_population`, `health_expenditure_share_pct`, `health_expenditure_per_capita_php`, `growth_pct`. |
| `indicator_category` | STRING | `census`, `reported`, `poverty`, or financing agent name. |
| `category_level` | INT | Agent hierarchy level (health expenditure). |
| `parent_category` | STRING | Parent agent (health expenditure). |
| `value` | DECIMAL(30,4) | Indicator value. Null when `value_status` is not `ok`; never 0. |
| `value_status` | STRING | `ok`, `not_published`, `label_under_review`, etc. |
| `coverage_basis` | STRING | Geographic coverage basis. |
| `comparison_eligible` | BOOLEAN | Whether the row is comparable with PSGC-based areas (poverty). Null on non-poverty rows. |
| `exclusion_reason` | STRING | Why not comparison-eligible (if any). |
| `value_note` | STRING | PSA precision label or note. |
| `is_latest_period` | BOOLEAN | Whether this is the latest period for the area (snapshots). |
| `_gold_build_id` | STRING | Gold build identifier. |

Never sum across `indicator_name`, `indicator_category`, or `data_source_key`. Census and FHSIS population are two sources. Never add them together.

---

### Reference tables and views

---

### `public_health.test_gold2.source_priority` (seed table)

**Grain:** One source for one metric, disease scope, geographic level, period grain, and range of years, with its role.
**Key:** `(metric, disease_scope, geo_level, period_grain, year_from, year_to, data_source_key)`.

Sources overlap on purpose. This table says which source gold shows for each metric. The marts join it, so a source is never picked by hand inside a query.

| Column | Type | Description |
|---|---|---|
| `metric` | STRING | Measure (e.g. `cases`, `deaths`, `prevalence`). |
| `disease_scope` | STRING | Disease or cause list (e.g. `dengue`, `tuberculosis`, `psa_tabulation_list`). |
| `geo_level` | STRING | `country`, `region`, or `province`. |
| `period_grain` | STRING | `week`, `month`, or `year`. |
| `year_from` / `year_to` | INT | Year range the row covers. |
| `data_source_key` | BIGINT | FK to dim_data_source. |
| `source_dataset` | STRING | Source dataset key. |
| `priority` | INT | Priority rank (1 = highest). |
| `role` | STRING | `preferred` (shown), `cross_check` (compared, never shown), `fallback` (used only when preferred has no row). |
| `replay_eligibility` | STRING | Whether the row is usable for the BQ2 replay scenario. |
| `reason` | STRING | Why this source and role. |

---

### `public_health.test_gold2.area_coverage_map` (view) and `huc_province_crosswalk` (view)

**`huc_province_crosswalk`** — One row per HUC outside NCR, with the province it sits in. Key: `huc_area_key`.

**`area_coverage_map`** — One row per area published by one source in one year in one fact table, with how it maps to a planning unit. Key: `(fact_table, data_source_key, geo_coverage_basis, area_key, date_key)`.

| Column | Type | Description |
|---|---|---|
| `fact_table` | STRING | Which fact table the row comes from. |
| `data_source_key` | BIGINT | Source key. |
| `geo_coverage_basis` | STRING | Coverage basis of the source row. |
| `area_key` | BIGINT | Published area key. |
| `date_key` | BIGINT | Period key. |
| `planning_unit_key` | BIGINT | Planning unit the area maps to. |
| `mapping_outcome` | STRING | `direct`, `aggregate`, `not_separable`, `not_used`, or `out_of_scope`. |

---

### `public_health.test_gold2.ref_osm_healthsite_point`

**Grain:** One OpenStreetMap health facility point (healthsites.io export via HDX), placed in a city or municipality.
**Primary key:** `osm_point_key` (BIGINT). **Natural key:** `(osm_key)` = `osm_type/osm_id`.
This table sits outside the 5-dimension and 4-fact model. It is a reference or map layer, not a fact (it has no measures) and not a dimension (no fact joins to it).

| Column | Type | Description |
|---|---|---|
| `osm_point_key` | BIGINT | Surrogate key (PK). |
| `osm_key` | STRING | `osm_type/osm_id` (natural key). |
| `osm_type` / `osm_id` | STRING | OSM type and id. |
| `name` | STRING | Facility name (OSM tag). |
| `amenity` | STRING | OSM amenity tag. |
| `facility_type` | STRING | Health facility type (OSM tag). |
| `area_key` | BIGINT | Placed area key (point-in-polygon, nearest_boundary, exception, or addr_city_name). |
| `location_precision` | STRING | `point` (coordinates known) or municipality only. |
| `_gold_build_id` | STRING | Gold build identifier. |

NEVER a facility count. OSM data is crowd-sourced, incomplete, and uneven. Sharing: open, ODbL 1.0. Show "© OpenStreetMap contributors" on every chart or map.

---

### `public_health.test_gold2.v_facility_capacity_totals`, `v_disease_metric_totals`, `v_workforce_preferred`, `v_area_indicator_latest` (views)

Four thin views (one per fact) that apply each fact's **selection contract**. The selection contract is the set of filters every total must carry so valid rows are never added twice. The views do no computation and create no new table. They are a safe entry point for ad hoc dashboard and Genie totals.

| View | Fact | Selection contract |
|---|---|---|
| `v_facility_capacity_totals` | fact_facility_capacity | One `capacity_basis`, `coverage_basis`, ownership `total`, all hospital levels, `value_status = 'ok'`. |
| `v_disease_metric_totals` | fact_disease_metric | One `data_source_key` (preferred), one `metric_name`, `age_group = 'all_ages'`, `sex = 'both_sexes'`, one `coverage_basis`. |
| `v_workforce_preferred` | fact_workforce_capacity | `source_role = 'preferred'`, one `profession_code`, `analysis_eligible`. |
| `v_area_indicator_latest` | fact_area_indicator | One `indicator_name`, `indicator_category`, `value_status = 'ok'`, one `date_key` per area (snapshot). |

---

### Marts (views)

---

### `public_health.test_gold2.mart_locality_service_presence`

**Grain:** One city or municipality, with or without a facility. **Key:** `area_key`.
**Answers:** A1 (no hospital recorded), A2 (highest hospital level), A3 (no licensed primary care recorded), and A4 (population per hospital, bed, or primary care facility).

| Column | Type | Description |
|---|---|---|
| `area_key` | BIGINT | Locality area key (PK). |
| `area_code` / `area_name` | STRING | Locality code and name. |
| `geographic_level` | STRING | `city` or `municipality`. |
| `city_class` | STRING | HUC/ICC/CC. |
| `planning_unit_key` | BIGINT | Planning unit the locality rolls up to. |
| `has_hospital_recorded` | BOOLEAN | Whether the registry lists a hospital there. |
| `has_level3_hospital_recorded` | BOOLEAN | Whether a Level 3 hospital is recorded. |
| `hospital_count` | INT | Count of hospitals (0 when none listed). |
| `hospital_beds` | INT | Sum of analysis beds (0 when none listed, null when listed but no bed count). |
| `hospitals_without_bed_count` | INT | Hospitals with null bed count. |
| `has_licensed_primary_care_recorded` | BOOLEAN | Whether a licensed primary care facility is recorded. |
| `licensed_primary_care_facilities` | INT | Count of licensed primary care facilities. |
| `population` | BIGINT | Latest census count of the locality. |
| `population_year` | INT | Census year. |
| `population_per_hospital` | DOUBLE | Population / hospital count (A4). |
| `population_per_hospital_bed` | DOUBLE | Population / hospital beds (A4). |
| `population_per_licensed_primary_care` | DOUBLE | Population / primary care facilities (A4). |

"Recorded" is literal. A `false` value means the registry lists none there, not that none exists. Every city and municipality in `dim_geography` has a row. Manila submunicipalities do not have their own rows. They are counted in the City of Manila.

---

### `public_health.test_gold2.mart_base_planning_unit`

**Grain:** One planning unit, with its census population. **Key:** `planning_unit_key`. This is a helper for the BQ1 marts. It keeps the profile, burden, evidence, and priority marts on the same unit list and denominator.

| Column | Type | Description |
|---|---|---|
| `planning_unit_key` | BIGINT | Planning unit key (PK). |
| `area_code` / `area_name` | STRING | Unit code and name. |
| `unit_level` | STRING | `province`, `HUC`, `NCR`, or `other` (Isabela City, SGA). |
| `localities` | INT | Count of cities/municipalities in the unit. |
| `localities_without_population` | INT | Localities with no census count for the year. |
| `population` | BIGINT | Sum of census counts of the unit's localities (null when any locality is missing). |
| `population_year` | INT | Census year. |

---

### `public_health.test_gold2.mart_area_burden_indicator`

**Grain:** One planning unit with one burden indicator (a disease, a measure, and a source), in the latest year the source has. Every unit has a row for every indicator, even when it has no value. **Key:** `(planning_unit_key, burden_indicator_key)`.
**Answers:** N2 (modelled deaths and prevalence by province) and N4 (TB notifications).

| Column | Type | Description |
|---|---|---|
| `planning_unit_key` | BIGINT | Planning unit key. |
| `burden_indicator_key` | BIGINT | Indicator key (disease × measure × source). |
| `disease_key` | BIGINT | FK to dim_disease. |
| `disease_name` | STRING | Disease name. |
| `metric_name` | STRING | `cases`, `deaths`, or `prevalence`. |
| `value` | DECIMAL(20,4) | Burden value (null when unavailable). |
| `value_lower` / `value_upper` | DOUBLE | Uncertainty bounds (IHME). |
| `value_year` | INT | Year of the value. |
| `rate_per_100k` | DOUBLE | value / census population × 100,000 (null when > 2 years apart or no population). |
| `quintile` | INT | 1 = lowest rate, 5 = highest (among units with a rate). |
| `value_available` | BOOLEAN | Whether the unit has a value. |
| `coverage_compatible` | BOOLEAN | Whether the source area maps to the unit. |
| `comparison_eligible` | BOOLEAN | Whether the unit enters comparisons. |
| `exclusion_reason` | STRING | Why not eligible. |
| `data_source_key` | BIGINT | FK to dim_data_source. |

Indicators: TB notifications (FHSIS, reported, summed over localities) and IHME modelled deaths and prevalence (province, direct rows only). Dengue is read from `fact_disease_metric` directly for N3, not from this table.

---

### `public_health.test_gold2.mart_area_evidence`

**Grain:** One planning unit with one indicator, even when the unit has no value. **Key:** `(planning_unit_key, indicator_key)`.
**Answers:** Why an area is missing from a comparison, and where the platform's evidence is not enough (Supporting).

| Column | Type | Description |
|---|---|---|
| `planning_unit_key` | BIGINT | Planning unit key. |
| `area_code` / `area_name` | STRING | Unit code and name. |
| `unit_level` | STRING | Province, HUC, NCR, other. |
| `indicator_key` | STRING | Indicator name (the eight profile rates + every burden indicator). |
| `indicator_group` | STRING | `hospital`, `primary_care`, `workforce`, `equity`, or burden group. |
| `value` | DOUBLE | Indicator value. |
| `value_year` | INT | Year of the value. |
| `data_source_key` | BIGINT | Source key. |
| `value_available` | BOOLEAN | Whether the unit has a value. |
| `coverage_compatible` | BOOLEAN | Whether the source area maps to the unit. |
| `comparison_eligible` | BOOLEAN | Whether the unit enters comparisons. |
| `exclusion_reason` | STRING | Why not eligible. |

Nothing is computed here. The view only turns `mart_area_service_profile` and `mart_area_burden_indicator` into one long list.

---

### `public_health.test_gold2.priority_weight_params` (seed) and `mart_area_priority` (view)

**`priority_weight_params`** — One row per weight of one gap type in one weight set. Key: `(weight_set, indicator)`. Weight sets: `equal`, `supply_heavy`, and `equity_heavy`. These are PROPOSED starting values.

**`mart_area_priority`** — One planning unit, burden indicator, weight set, and eligibility rule. Key: `(planning_unit_key, burden_indicator_key, weight_set, eligibility_config)`.
**Answers:** P1 (which areas combine high burden with gaps, and which type of gap) and P2 (how stable the ranking is when weights and rules change).

| Column | Type | Description |
|---|---|---|
| `planning_unit_key` | BIGINT | Planning unit key. |
| `burden_indicator_key` | BIGINT | Burden indicator. |
| `weight_set` | STRING | Weight set name. |
| `eligibility_config` | STRING | `complete_only` or `rescale_missing`. |
| `has_hospital_gap` | BOOLEAN | Beds per 10k in the lowest fifth. |
| `has_primary_care_gap` | BOOLEAN | Primary care gap (FHSIS rate or share without HFSRB facility). |
| `primary_care_gap_basis` | STRING | Which measure raised the primary care gap. |
| `has_workforce_gap` | BOOLEAN | ≥ 2 of doctors/nurses/midwives per 10k in lowest fifth. |
| `has_socioeconomic_flag` | BOOLEAN | Poverty incidence in the highest fifth. |
| `is_high_burden` | BOOLEAN | Burden rate in the highest fifth. |
| `flags_count` | INT | Number of flags raised (unweighted). |
| `score` | DOUBLE | Weighted sum of flags (0–1). |
| `rank` | INT | 1 = highest score; ties broken by burden rate. |

PROPOSAL: the fifths, the "two of three" rule, and the weight sets are starting values for the team to set. They are not published standards.

---

### `public_health.test_gold2.fact_area_access`

**Grain:** One city or municipality, with two straight-line distances. **Key:** `area_key`.
**Answers:** The "how far" part of A1 and A2. This does NOT measure distance to a hospital building for the registry measure, because the registry has no coordinates.

| Column | Type | Description |
|---|---|---|
| `area_key` | BIGINT | Locality area key (PK). |
| `area_code` / `area_name` | STRING | Locality code and name. |
| `planning_unit_key` | BIGINT | Planning unit. |
| `population` | BIGINT | Census population. |
| `has_hospital_recorded` | BOOLEAN | Whether the locality has a hospital recorded. |
| `has_level3_hospital_recorded` | BOOLEAN | Whether a Level 3 hospital is recorded. |
| `nearest_hospital_locality_km` | DOUBLE | Straight-line km to the nearest locality with a hospital recorded (0 if it has one). |
| `nearest_level3_hospital_locality_km` | DOUBLE | Straight-line km to the nearest locality with a Level 3 hospital. |
| `nearest_osm_hospital_km` | DOUBLE | Straight-line km to the nearest OSM hospital point (map layer, unverified). |
| `osm_hospital_basis` | STRING | OSM measure basis/caveat. |
| `coordinates_validated` | BOOLEAN | Whether the locality has a boundary centre. |

Distance is great-circle (haversine) km, with Earth radius 6,371 km. This is a straight line, not travel distance. OSM measure is labelled "© OpenStreetMap contributors".

---

### `public_health.test_gold2.mart_tb_case_study`

**Grain:** One city or municipality. **Key:** `area_key`.
**Answers:** T1 (do places with higher TB notification rates have fewer public health workers?) and T2 (TPT coverage and treatment success by area).

| Column | Type | Description |
|---|---|---|
| `area_key` | BIGINT | Locality area key (PK). |
| `area_code` / `area_name` | STRING | Locality code and name. |
| `tb_cases_2024` / `tb_cases_2025` | INT | FHSIS TB notifications (all forms). |
| `tb_rate_2024_per_100k` / `tb_rate_2025_per_100k` | DOUBLE | Notification rate (2024 census population). |
| `doctors_per_10k` / `nurses_per_10k` / `midwives_per_10k` | DOUBLE | FHSIS 2025 workforce (preferred, eligible). |
| `bhw_per_10k` | DOUBLE | Null for 2025 (LGU-hired only). |
| `bhw_lgu_hired_per_10k` | DOUBLE | LGU-hired BHW rate (label "LGU-hired only"). |
| `has_primary_care_recorded` | BOOLEAN | A3. |
| `has_hospital_recorded` | BOOLEAN | A1. |
| `tpt_coverage_pct` | DOUBLE | tpt_given / tpt_eligible_contacts × 100. |
| `ds_treatment_success_rate` | DOUBLE | treatment_success / treatment_cohort × 100 (tb_all_forms = DS-TB). |
| `mdr_treatment_success_rate` | DOUBLE | treatment_success / treatment_cohort × 100 (tb_drug_resistant). |
| `comparison_eligible` | BOOLEAN | Locality has 2025 notifications, 2024 population, usable workforce. |
| `exclusion_reason` | STRING | First missing thing. |
| `programme_available` | BOOLEAN | At least one programme denominator exists. |
| `small_cohort_flag` | BOOLEAN | Treatment cohort < 10. |

`tpt_eligible_contacts` is an FHSIS estimate (notified cases times 4 times 70%). Label it as an estimate. Rates are computed here. Never copy them from printed percentages.

---

### `public_health.test_gold2.mart_kidney_case_study`

**Grain:** One province (or NCR) as IHME publishes it. **Key:** `(kidney_unit_key, unit_basis)`.
**Answers:** K1 — which provinces have high estimated chronic kidney disease mortality but few dialysis stations per population.

| Column | Type | Description |
|---|---|---|
| `kidney_unit_key` | BIGINT | Unit key. |
| `unit_basis` | STRING | `planning` (no HUC / NCR) or `broad` (province + HUCs; IHME assumed to include them). |
| `area_name` | STRING | Province or NCR name. |
| `ckd_deaths` | DOUBLE | IHME modelled CKD deaths (latest year, cause ihme_589). |
| `ckd_deaths_lower` / `ckd_deaths_upper` | DOUBLE | Uncertainty bounds. |
| `ckd_deaths_year` | INT | Year of the estimate. |
| `ckd_death_rate_per_100k` | DOUBLE | Modelled deaths / census population × 100,000. |
| `dialysis_stations_reported` | INT | Recorded station count (null when no facility has a count). |
| `has_dialysis_facility_recorded` | BOOLEAN | Whether any dialysis facility is listed. |
| `dialysis_stations_per_100k` | DOUBLE | Stations / census population × 100,000. |
| `station_completeness_pct` | DOUBLE | Share of dialysis facilities with a station count. |
| `comparison_eligible` | BOOLEAN | `unit_basis = planning` (broad rows excluded until IHME confirms coverage). |
| `exclusion_reason` | STRING | Why not eligible. |

These are modelled estimates. Never mix them with registered deaths. Show IHME attribution on charts. Missing is not zero.

---

### `public_health.test_gold2.mart_dengue_peak_capacity`

**Grain:** One area as one dengue source publishes it, in one year. The row shows the peak reported dengue period set beside current recorded hospital beds. **Key:** `(area_key, data_source_key, year)`.
**Answers:** DP (where were historical dengue peaks largest relative to current recorded capacity?) and N3 (when and where dengue peaks, how concentrated, and repeat high burden). This does NOT answer BQ2, which needs the replay with admission and length-of-stay assumptions.

| Column | Type | Description |
|---|---|---|
| `area_key` | BIGINT | Area key. |
| `data_source_key` | BIGINT | Dengue source (hdx_dengue, upnoah, or doh_foi_dengue). |
| `year` | INT | Year. |
| `peak_period_label` | STRING | Peak period label (week number or dated week). |
| `peak_label` | STRING | `highest period` or `highest observed period` (when year incomplete). |
| `peak_cases` | DECIMAL(20,4) | Cases in the peak period. |
| `annual_cases` | DECIMAL(20,4) | Total annual cases. |
| `peak_period_share_pct` | DOUBLE | peak / annual. |
| `top4_periods_share_pct` | DOUBLE | Top 4 weeks / annual (weekly sources only). |
| `is_complete_year` | BOOLEAN | Whether the year is complete for the area. |
| `annual_cases_per_100k` | DOUBLE | Annual cases / census population × 100,000. |
| `high_burden_years` | INT | Count of high-burden years (top fifth, ≥ 50 weeks / 12 months). |
| `repeat_high_burden` | BOOLEAN | 2 or more high-burden years. |
| `hospital_beds_recorded` | INT | Registry analysis beds of the same coverage. |
| `comparison_eligible` | BOOLEAN | Whether coverage maps to the unit. |
| `coverage_note` | STRING | Coverage caveat (e.g. `region as published`). |

Three dengue sources are never mixed (the grain keeps `data_source_key`). Weekly and monthly peaks never sit in one ranking. HDX peaks are dated on Sundays (the start of the DOH morbidity week). Labels stay as dated weeks until D4 is confirmed.

---

### `public_health.test_gold2.mart_evidence_readiness`

**Grain:** One silver or gold table, in its latest succeeded build. **Key:** `table_name`.
**Answers:** SUP6 — is each table built, checked, and built from the latest inputs? (data readiness page).

| Column | Type | Description |
|---|---|---|
| `table_name` | STRING | Built table name (PK). |
| `schema_name` | STRING | `test_gold` or `test_gold2`. |
| `layer` | STRING | `silver` or `gold`. |
| `domain` | STRING | Domain. |
| `model` | STRING | Build model label (`v2` for every v2 file). |
| `latest_build_id` | STRING | Latest succeeded build ID. |
| `built_at` | TIMESTAMP | Build timestamp. |
| `inputs` | INT | Number of inputs recorded for the build. |
| `stale_inputs` | INT | Inputs with a newer succeeded build than the version read. |
| `is_fresh` | BOOLEAN | No input has a newer build (null when no comparable version). |
| `qc_pass` / `qc_warn` / `qc_fail` | INT | Latest QC run counts (null when no QC has run). |
| `approval` | STRING | Build approval status (provisional until silver QC passed). |

Only tables on the build pattern appear here (they have a row in `quality.build_log`). Tables written by a notebook and the views (marts, coverage map, default views) have no build, so they have no row in this table.
