# Data dictionary

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Field definitions for the key silver and gold tables. For metric formulas, see [metric definitions](metric-definitions.md).

## `mart_area_service_profile`

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
| `population` | BIGINT | Population from geography_population_silver or facilities_metric_silver |
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
| `year` / `reporting_year` | INT | Reporting year (verify column name — see known issues KI6) |
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

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC code (primary key) |
| `area_name` | STRING | Area name |
| `geographic_level` | STRING | `Region`, `Prov`, `City`, `Mun`, `Bgy` |
| `region_code` | STRING | Region code |
| `province_code` | STRING | Province code (null for NCR) |
| `populations_json` | STRING | JSON of population by year |
| `source_version` | STRING | PSGC version (Q2 2024) |

## `geography_population_silver`

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSGC code |
| `population_year` | INT | Population year (2015, 2020, 2024) |
| `population` | BIGINT | Population count |

## Bronze table definitions

For bronze table column definitions, see the [bronze pipeline docs](../bronze/README.md) and the YAML source configs in `config/`. The detailed bronze dictionary (geography, admin boundaries, legacy facility tables) uses table names from a previous version and has been superseded by the config-driven naming convention (`<domain>_<source>_<content>_bronze`).




> **Legacy section below.** The geography and admin boundary column definitions are still accurate. The facility table names (e.g. `facilities_primary_care`, `active_facilities`) are from a previous version and have been superseded by the config-driven naming convention (`<domain>_<source>_<content>_bronze`). See the [bronze pipeline docs](../bronze/README.md) and YAML source configs for current table names.

## Bronze Layer



### Bronze: Diseases domain


---

### Bronze: Geography domain

---

### `public_health.bronze.geography_bronze`

**Purpose**

Stores source-aligned Philippine Standard Geographic Code (PSGC) records
retrieved from the Philippine Statistics Authority (PSA) API.

The Bronze table preserves useful source attributes as individual columns,
nested population observations as JSON, the complete logical source record,
and ingestion lineage metadata.

**Grain**

One row per PSGC geographic code per logical source snapshot.

**Source**

PSA Philippine Standard Geographic Code (PSGC) API.

**Natural source key**

`psgc_code`

**Bronze merge key**

`content_checksum + psgc_code`

This allows the same PSGC code to exist in different source snapshots while
preventing duplicate records within the same logical snapshot.

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

Some PSGC attributes are only applicable to specific geographic levels.
Therefore, blank values in fields such as `old_name`, `city_class`,
`income_classification`, `urban_rural`, and `record_status` do not
automatically indicate a data-quality failure.

Population observations are kept in source form in Bronze. Population values
may contain commas, surrounding spaces, blank strings, or source values such
as `#N/A`. Cleaning, type conversion, and exploding population observations
are Silver-layer responsibilities.

---

### `public_health.bronze.geography_phl_admin_boundaries`

**Purpose**

Stores source-aligned Philippine administrative boundary features retrieved
from the Humanitarian Data Exchange (HDX) Common Operational Dataset for
Administrative Boundaries (COD-AB).

The Bronze table preserves each complete GeoJSON Feature, raw properties,
geometry, and technical lineage metadata required for auditability,
idempotent reruns, and downstream geographic reconciliation.

**Grain**

One row per GeoJSON Feature per administrative level per immutable HDX
source version.

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

HDX p-codes are preserved as source values in Bronze. They are not yet
treated as canonical/current PSA Philippine Standard Geographic Code (PSGC)
identifiers.

PSGC reconciliation, canonical naming, hierarchy standardization, and
resolution of source-specific administrative differences are Silver-layer
responsibilities.

**Source version key**

`_source_version`

The source version is the SHA-256 checksum of the immutable downloaded HDX
source archive.

**Batch key**

`_batch_id`

The batch identifier is deterministic and follows:

`dataset_id:source_version`

**Bronze rerun rule**

For the same `_source_version`:

* if no records exist, load the complete validated batch;
* if the complete expected batch already exists, perform a no-op;
* if a partial or inconsistent batch exists, fail rather than append.

This prevents duplicate records when the same immutable source version is
rerun.

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

The exact fields available in `properties_json` depend on the
administrative level.

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

Alternate-name fields such as `adm0_name1`, `adm0_name2`, `adm0_name3`,
`adm1_name1`, `adm1_name2`, `adm1_name3`, and equivalent fields for other
administrative levels are also preserved when present.

The complete `source_feature_json` remains the authoritative Bronze
representation if additional source properties appear in a future HDX
version.

The Bronze validation checks geometry type only. A `Polygon` or
`MultiPolygon` value does not by itself prove full geometric or topological
validity. Full spatial validity checks belong in downstream processing when
required.

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

These counts describe this immutable source version only.

Future legitimate HDX source versions may contain different administrative
record counts or geometry distributions. The pipeline derives expected row
counts from the validated staging manifest rather than hard-coding these
values.

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

Stores validation evidence for the HDX Philippines administrative-boundary
pipeline before a source version is allowed to load into Bronze.

The table keeps validation history across executions rather than replacing
previous validation results.

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

A source version must have no blocking `FAIL` results before the ingestion
notebook publishes a validated handoff to the Bronze loader.

`WARN` results are retained for auditability but do not block the handoff.

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

A later validation execution of the same immutable source version does not
rewrite the `_validation_id` stored on already-loaded Bronze records.
Existing Bronze rows retain the validation execution that authorized their
original load.

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

The file includes facility identifiers, names, ownership details, addresses, contacts, licensing information, and bed-capacity fields. Because several source column names contain spaces and special characters, enable Delta column mapping to preserve them without renaming:

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

The workbook uses a multi-row header: report title, sub-headers, blank row, then field names. Use `header=3` to read the correct header row.

Enable Delta column mapping because the source contains names such as `LEVEL 1` and `Total No. of Facilities`. Use `overwriteSchema=true` to allow controlled schema updates on later refreshes.

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

This table supports analysis of public-health workforce trends, profession mix, and regional workforce distribution from 2012 through 2023. Treat zero counts cautiously, as they may represent missing or unreported values in the source.

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

The CSV uses a standard single-row header with no title-row issues. An explicit Spark `StructType` schema (8 fields) is applied instead of `inferSchema` to avoid an extra file scan and enforce correct types. The `cause` field `Tracheal, bronchus, and lung cancer` contains embedded commas and is quoted in the source CSV (246 lines); Spark's CSV reader handles this natively.

Source columns are trimmed and cast to their target types. Null `year` rows are filtered out as a defensive measure. `dropDuplicates` on the natural key `(measure, location, cause, metric, year)` removes any duplicate source rows before writing.

Three metadata columns are added: `source_file` (full source path), `source_system` (`IHME GBD Results Tool`), and `ingestion_date` (current timestamp).

#### Idempotent Load Strategy

Unlike bronze tables that use full overwrite, this table uses an idempotent MERGE on `(measure, location, cause, metric, year)`:

* **First run:** Creates the table with full overwrite and Delta column mapping.
* **Subsequent runs:** Upserts matching rows via Delta `MERGE`. Only rows where `val`, `upper`, or `lower` have changed are updated (conditional `whenMatchedUpdate`), avoiding unnecessary writes. Unmatched rows are inserted.

Re-running the notebook any number of times produces the same result with no duplicate rows.

#### Error Handling

The write step is wrapped in `try/except` blocks. Both the initial `saveAsTable` action and the MERGE `execute` action are isolated as triggering actions inside the `try` block so that exceptions are caught and re-raised with a descriptive error message.

#### Debug Mode

A `DEBUG` flag in the config cell gates an exploratory schema-inspection cell. When `DEBUG = False` (default), the inspection cell is skipped to avoid unnecessary full scans in production.

---

### Bronze: Population domain

---

### `public_health.bronze.population_bronze` — Legacy PSA Population File Ingestion

**Status:** Legacy / retained in repository; not used by the current population Silver pipeline.

**Purpose**

Stores raw PSA population Excel sheets using positional columns rather than interpreting source headers during ingestion. Each loaded file and worksheet is tagged with source-file, worksheet, row, and snapshot-date metadata. The table is retained for historical/reference purposes, but the current `population_silver` table is sourced from `populations_json` in `public_health.bronze.geography_bronze`.

**Source**

PSA population Excel files in the configured Landing folder:

`/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/population`

The ingestion notebook selects files matching:

`population_YYYY_asof_YYYYMMDD.xlsx`

**Grain**

One row per source worksheet row per source file/sheet/snapshot. The ingestion notebook assigns `_source_row_num` within each worksheet. The source row itself is stored positionally across `c0` through `c13`.

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

- The ingestion process does not parse or standardize source headers. All worksheet cells are loaded as positional string columns (`c0`–`c13`).
- The actual meaning of each positional column can vary by worksheet or file, so column meanings should be interpreted using the corresponding source file and worksheet.
- The ingestion notebook validates the filename convention and checks for worksheets wider than 14 columns. It does not itself normalize the data into a year/value schema.
- This table is not the source for the current `public_health.silver.population_silver` transformation. Current Silver population observations are parsed from `public_health.bronze.geography_bronze.populations_json`.

---

### Bronze: Socio-economic domain

---

### Bronze: Workforce domain

---

### Shared ingestion metadata

---
### `public_health.bronze.ingestion_metadata`

**Purpose**

Stores batch-level ingestion metadata for monitoring, lineage,
idempotency, and failure recovery.

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

---

### Silver: Geography domain

---

### Silver: Facilities domain

---
### Silver: Population domain

---

### `public_health.silver.population_silver`

**Purpose**

Stores normalized population observations parsed from the `populations_json` array in
`public_health.bronze.geography_bronze`. Each JSON array element becomes one Silver row,
making population values available for filtering, joins, trend analysis, and downstream
population-based metrics.

**Source**

`public_health.bronze.geography_bronze`, specifically the `populations_json` column,
with geographic identity and source lineage retained from the Bronze record.

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

---

### Workforce domain

---
