# Bronze Layer - Geography Domain

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

## 1. Domain Overview

The Geography Bronze domain loads geographic reference records and administrative-boundary features into Bronze tables. It covers two notebooks:

- `geography_bronze.py` - loads completed PSGC API landing batches.
- `admin_boundaries_bronze.py` - loads prepared administrative-boundary features from a validated handoff and staging manifest.

The notebooks preserve source content and add ingestion lineage. They do not perform the full PSGC-to-boundary reconciliation; that belongs in a downstream step.

## 2. Source and Input Data

### 2.1 PSGC API

| Item | Details |
|---|---|
| Configuration | `sources_geography.yaml` |
| Supported configuration layout | Top-level `psgc` or nested `sources.psgc` |
| Required settings | `source_name`, `version`, `endpoint`, `landing_path`, `bronze_table` |
| Input | Completed API-to-landing batch |
| Target | Configured `bronze_table` (the notebook's expected target is `public_health.bronze.geography_bronze`) |

The notebook reads already-landed data; it does not call the PSGC API or require an API token. It validates the selected landing batch using `_SUCCESS`, `manifest.json`, the `landed` status, and matching source name, version, and endpoint. The batch can be selected with the `landing_batch_path` widget or discovered from the configured landing path.

### 2.2 Administrative Boundaries

| Item | Details |
|---|---|
| Notebook | `admin_boundaries_bronze.py` |
| Input handoff | `handoff.json` |
| Landing receipt | `receipt.json` |
| Staging manifest | `manifest.json` |
| Input data | Prepared JSON-lines feature files listed by the staging manifest |
| Target table | `public_health.bronze.admin_boundaries_bronze` |

The notebook checks that the handoff, receipt, manifest, source identifiers, and file metadata agree before loading. It reads the files named in the manifest rather than arbitrary files from a directory. The pipeline separates Bronze loading from the administrative-boundary Bronze QC workflow.

## 3. Bronze Data Design

### 3.1 `public_health.bronze.geography_bronze`

**Purpose:** Preserve PSGC geography attributes, nested population observations, and source-record lineage.

**Grain:** One PSGC code per source snapshot.

**Logical merge key:** `source_system + source_version + source_endpoint + content_checksum + psgc_code`.

| Column | Representation | Description |
|---|---|---|
| `psgc_code` | STRING | Geographic code, taken from `code` or fallback `psgc_code` |
| `area_name` | STRING | Source area name |
| `correspondence_code` | STRING | Source correspondence code, when present |
| `geographic_level` | STRING | Source geographic level; blank values are preserved |
| `reg`, `prv`, `mun`, `bgy` | STRING | Source geographic hierarchy attributes |
| `old_name` | STRING | Source previous or alternate name, when present |
| `city_class` | STRING | Source city classification, when present |
| `income_classification` | STRING | Source income classification, when present |
| `urban_rural` | STRING | Source urban/rural attribute, when present |
| `island_region` | STRING | Source island-region attribute, when present |
| `record_status` | STRING | Source `status` value |
| `record_version` | STRING | Source `version` value, when present |
| `populations_json` | STRING containing JSON | Nested `populations` value, falling back to `population_data` |
| `source_record_json` | STRING containing JSON | Full landed source record |
| `source_system` | STRING | Configured source name |
| `source_version` | STRING | Configured source version |
| `source_endpoint` | STRING | Configured endpoint |
| `batch_id` | STRING | Landing batch identifier |
| `content_checksum` | STRING | Snapshot checksum from the landing manifest |
| `raw_path` | STRING | Selected landing batch path |
| `ingested_at` | TIMESTAMP | Bronze ingestion timestamp |

The notebook keeps the selected source attributes as strings and does not flatten the population array or normalize geography values.

### 3.2 `public_health.bronze.admin_boundaries_bronze`

**Purpose:** Preserve administrative-boundary features, including their properties and geometry, with source lineage.

| Column | Representation | Description |
|---|---|---|
| `source_feature_json` | STRING containing JSON | Full source feature |
| `_staging_file_path` | STRING | Path of the staged input file |
| `feature_type` | STRING | Feature JSON `type` |
| `source_feature_id` | STRING | Feature JSON `id`, when present |
| `properties_json` | STRING containing JSON | Original feature properties |
| `geometry_json` | STRING containing JSON | Original geometry object |
| `geometry_type` | STRING | Geometry type from the source feature |
| `_source_key` | STRING | Source identifier from the handoff |
| `_dataset_id` | STRING | Dataset identifier from the handoff |
| `_source_version` | STRING | Source-version identifier |
| `_batch_id` | STRING | Batch identifier from the handoff |
| `_admin_level` | INT | Administrative level from the staging manifest |
| `_source_file` | STRING | Source filename from the manifest |
| `_source_file_sha256` | STRING | Source-file checksum from the manifest |
| `_source_crs` | STRING | Source coordinate reference system |
| `_source_url` | STRING | Source URL from the landing receipt (nullable if omitted from receipt) |
| `_landing_receipt_path` | STRING | Validated receipt path |
| `_staging_manifest_path` | STRING | Validated staging-manifest path |
| `_validation_id` | STRING, nullable | Upstream validation identifier, if supplied |
| `_landing_ingested_at` | TIMESTAMP | Landing timestamp from the receipt |
| `_bronze_ingested_at` | TIMESTAMP | Bronze ingestion timestamp |
| `_record_sha256` | STRING | SHA-256 fingerprint derived from the feature JSON |

The column list reflects the schema constructed by the supplied notebook; the actual deployed table should be checked separately if runtime confirmation is required.

## 4. Code Walkthrough

### 4.1 PSGC notebook

1. Reads the configuration path from the `config_path` widget or `PSGC_CONFIG_PATH` environment variable.
2. Resolves the PSGC settings and validates the required configuration fields.
3. Selects and validates a completed landing batch and its manifest.
4. Reads the landed JSON-lines records and extracts the PSGC attributes, nested population JSON, and full source record.
5. Adds source and batch lineage fields.
6. Checks record counts, nonblank PSGC codes, and code uniqueness.
7. Checks the target table schema and Delta format when the table already exists.
8. Previews without writing unless `write_to_bronze` is set to `yes`.
9. When writing is enabled, uses a Delta `MERGE` keyed by source identity, snapshot checksum, and PSGC code.

### 4.2 Administrative-boundary notebook

1. Reads `handoff.json` from the `handoff_path` widget.
2. Validates the handoff and the referenced landing receipt and staging manifest.
3. Reads the exact staged feature files listed in the manifest.
4. Constructs Bronze records with the source feature JSON, properties, geometry, administrative level, and lineage fields.
5. Compares candidate and existing counts by administrative level and checks whether the target version can be loaded safely.
6. Writes a new source version only when the pre-write guards permit it.
7. Verifies write integrity and publishes a `bronze_handoff.json` for the next pipeline step.

## 5. Design Decisions

- **Preserve raw source content.** The PSGC loader stores the full record in `source_record_json`; the boundary loader stores the full feature in `source_feature_json` and retains properties and geometry as JSON.
- **Keep codes as strings.** PSGC codes are stored as strings to preserve their source representation.
- **Keep nested populations in Bronze.** Population observations remain in `populations_json`; this notebook does not flatten them into separate rows.
- **Do not infer missing geography values.** Blank `geographic_level` values are preserved rather than assigned a value by the Bronze loader.
- **Identify PSGC snapshots by content.** The PSGC merge key includes the content checksum, so a different checksum represents a distinct snapshot.
- **Validate before writing.** Both loaders check input contracts and existing data before making writes; the boundary pipeline also verifies the write and publishes a handoff.

## 6. Data Quality and Error Handling

### 6.1 PSGC checks

The notebook checks the landing completion marker and manifest, landing status and source metadata, expected file/page and record counts, nonblank PSGC codes, uniqueness of PSGC codes within the selected batch, and compatibility of an existing target schema. It also checks existing snapshot records for duplicates or conflicting source content before a merge. A Silver-compatibility guard prevents loading a different snapshot for the same configured version when that would make downstream snapshot selection ambiguous.

### 6.2 Administrative-boundary checks

The notebook validates the handoff, receipt, staging manifest, source-version and batch identifiers, and listed input files. It checks expected feature counts by administrative level, existing-version/rerun conditions, target schema compatibility, and post-write counts before publishing the handoff. Detailed data-quality approval is handled by the separate `admin_boundaries_bronze_qc.py` workflow.

## 7. Downstream Dependencies

- PSGC geography attributes and `populations_json` can be read by downstream Silver transformations.
- Administrative-boundary features preserve geometry and source identifiers for downstream processing.
- The Bronze notebooks do not perform the PSGC-to-HDX crosswalk or assert that every boundary feature has a matching PSGC record.

## 8. Validation and Reproducibility

### 8.1 PSGC notebook

1. Confirm that the upstream API-to-landing job completed.
2. Confirm that the selected batch contains `_SUCCESS`, `manifest.json`, and the expected landed files.
3. Set `config_path` and, if needed, `landing_batch_path`.
4. Run with `write_to_bronze` set to `no` and review the selected batch and planned write counts.
5. Set `write_to_bronze` to `yes` only when ready to write.
6. Review the notebook's final status and the target table after the run.

### 8.2 Administrative-boundary notebook

1. Run the upstream ingestion and staging workflow.
2. Set `handoff_path` to the intended `handoff.json`.
3. Run the notebook with a single concurrent writer for the source version.
4. Review expected and candidate counts by administrative level and the selected load action.
5. Review the post-write reconciliation and generated `bronze_handoff.json`.
6. Run `admin_boundaries_bronze_qc.py` for the separate Bronze quality checks.

## 9. Open Issues

- Confirm deployed table schemas and runtime row counts against the target tables when documenting a specific execution.
- Review unresolved PSGC-to-boundary matches in the downstream reconciliation step rather than assuming a match in Bronze.

## 10. Change Log

| Date | Change | Reason |
|---|---|---|
| 2026-10-12 | Revised geography Bronze documentation | Reduced material not directly needed to describe the supplied Bronze notebooks; retained source inputs, table structures, processing, and validation behavior |
