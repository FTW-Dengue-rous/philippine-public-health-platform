# Data Dictionary

## Bronze Layer

### `public_health.bronze.psgc`

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
