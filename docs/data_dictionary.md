# Data Dictionary

## Bronze Ingestion: Health Facilities and Medical Practitioners Data

This ingests raw health-facility and health-workforce source files from the landing zone into the `ph_public_health.bronze` schema. Bronze tables preserve the source structure as closely as possible and are refreshed in full on each run.

### Table of Contents

1. [Shared Conventions](#shared-conventions)
2. [Tables at a Glance](#tables-at-a-glance)
3. [`facilities_primary_care`](#ph_public_healthbronzefacilities_primary_care) — Regional Distribution of Primary Care Facilities
4. [`active_facilities`](#ph_public_healthbronzeactive_facilities) — NHFR Active Facilities
5. [`facilities_hospital_list`](#ph_public_healthbronzefacilities_hospital_list) — Regional Distribution of Hospitals
6. [`facilities_infirmary`](#ph_public_healthbronzefacilities_infirmary) — Regional Distribution of Regulated Infirmaries
7. [`government_medical_practitioners_by_region`](#ph_public_healthbronzegovernment_medical_practitioners_by_region) — Government Medical Practitioners by Region, 2012–2023

---

### Shared Conventions

* **Catalog:** `ph_public_health`
* **Schema:** `bronze`
* **Storage format:** Delta
* **Load strategy:** Full refresh (overwrite)
* **Excel dependency:** `openpyxl` is required when using Serverless compute.
* **Column preservation:** Tables with spaces or special characters in column names require Delta column mapping.

---

### Tables at a Glance

| Bronze Table | Source File | Provider | Rows | Columns | Status |
|---|---|---|---|---|---|
| `facilities_primary_care` | `primary_care_asof20260630.xlsx` | PSA | 19 | 6 | Active |
| `active_facilities` | `nhfr_activefacilities_asof_20260929.csv` | NHFR | 1,359 | 32 | Active |
| `facilities_hospital_list` | `hospital_list_asof20260630.xlsx` | DOH | 40 | 14 | Active |
| `facilities_infirmary` | `infirmary_asof20260630.xlsx` | DOH | 58 | 12 | Active |
| `government_medical_practitioners_by_region` | `TABLE 9.14 …2012 to 2023.csv` | PSA | 72 | 14 | Active |

> Row and column counts reflect the state at the time of writing and may change after a refresh.

---

### `ph_public_health.bronze.facilities_primary_care`

**Description:** Regional Distribution of Primary Care Facilities.

| Property | Value |
|---|---|
| Source file | `primary_care_asof20260630.xlsx` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | Philippine Statistics Authority (PSA) |
| Bronze table | `ph_public_health.bronze.facilities_primary_care` |
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

### `ph_public_health.bronze.active_facilities`

**Description:** National Health Facility Registry active-facilities extract.

| Property | Value |
|---|---|
| Source file | `nhfr_activefacilities_asof_20260929.csv` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | National Health Facility Registry (NHFR) |
| Bronze table | `ph_public_health.bronze.active_facilities` |
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

### `ph_public_health.bronze.facilities_hospital_list`

**Description:** Regional Distribution of Hospitals in the Philippines.

| Property | Value |
|---|---|
| Source file | `hospital_list_asof20260630.xlsx` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | Philippine Department of Health (DOH) |
| Bronze table | `ph_public_health.bronze.facilities_hospital_list` |
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

### `ph_public_health.bronze.facilities_infirmary`

**Description:** Regional Distribution of Regulated Infirmaries.

| Property | Value |
|---|---|
| Source file | `infirmary_asof20260630.xlsx` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/` |
| Provider | Philippine Department of Health (DOH) |
| Bronze table | `ph_public_health.bronze.facilities_infirmary` |
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

### `ph_public_health.bronze.government_medical_practitioners_by_region`

**Description:** Annual number of government-employed medical practitioners by Philippine region and profession (2012–2023).

| Property | Value |
|---|---|
| Source file | `TABLE 9.14 Number of Government Medical Practitioners by Region- 2012 to 2023.csv` |
| Landing location | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/health workforce/` |
| Provider | Philippine Statistics Authority (PSA) |
| Bronze table | `ph_public_health.bronze.government_medical_practitioners_by_region` |
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
## Bronze Layer

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
