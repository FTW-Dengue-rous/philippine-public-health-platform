# Bronze Layer - Geography Domain

## 1. Domain Overview

**Purpose**

The Geography Bronze domain preserves geographic reference records from two sources:

1. **Philippine Statistics Authority (PSA) Philippine Standard Geographic Code (PSGC) API** - geographic attributes and nested population observations.
2. **HDX Philippine administrative boundaries** - geographic boundary features and geometry for administrative levels ADM1–ADM3.

These sources serve different purposes. PSGC is the canonical geographic reference used by the current pipeline, while HDX supplies boundary geometry that must be reconciled to the PSGC geography in Silver.

**Scope**

This document covers the Bronze ingestion notebooks:

- `geography_bronze.ipynb`
- `admin_boundaries_bronze.ipynb`

It documents the behavior visible in the supplied notebooks and the attached geography profiling notes. It does not claim that a notebook run or its outputs were independently executed during preparation of this document.

**Business questions supported**

Geographic identifiers and population observations support downstream joins and population-based analyses. Administrative boundary geometry can support mapping and spatial analysis. Geography Bronze does not itself calculate healthcare-service gaps, facility access, or population ratios; those require downstream transformations and appropriate facility/population data.

**Implementation status**

- PSGC: landing-to-Bronze notebook provided.
- Administrative boundaries: staged-input-to-Bronze notebook provided, followed by a separate Bronze QC workflow.
- PSGC-to-HDX reconciliation: documented as a Silver responsibility, not performed by these Bronze loaders.

## 2. Source and Input Data

### 2.1 PSGC API

| Attribute | Description |
|---|---|
| Provider | Philippine Statistics Authority (PSA), PSGC API |
| Input | Completed API-to-landing batch |
| Configuration | `config/sources_geography.yaml` |
| Required configuration | `source_name`, `version`, `endpoint`, `landing_path`, `bronze_table` |
| Supported configuration layout | Top-level `psgc` or nested `sources.psgc` |
| Landing selection | Explicit `landing_batch_path`, or newest completed matching batch |
| Authentication in Bronze | No PSA token required; the notebook reads already-landed data |
| Target table | Configured `bronze_table` (the profiling notes identify `public_health.bronze.geography_bronze`) |

The Bronze notebook expects the API-to-landing stage to have completed first. It selects only a batch whose `_SUCCESS` marker and `manifest.json` agree and whose status is `landed`, with matching source name, version, and endpoint.

### 2.2 HDX Administrative Boundaries

| Attribute | Description |
|---|---|
| Provider | Humanitarian Data Exchange (HDX) boundary dataset, as represented in the supplied pipeline artifacts |
| Input | Validated handoff, landing receipt, staging manifest, and prepared JSON-lines feature files |
| Input handoff | `handoff.json` |
| Landing receipt | `receipt.json` |
| Staging manifest | `manifest.json` |
| Target table | `public_health.bronze.admin_boundaries_bronze` |
| Administrative levels | ADM1, ADM2, ADM3 |
| Downstream stage | Separate Bronze QC notebook, then Silver |

The notebook requires the handoff, receipt, manifest, and source version/batch identifiers to agree. It reads the exact prepared files listed by the staging manifest rather than searching a directory for arbitrary input files.

## 3. Code and Ingestion Flow

### 3.1 PSGC: `geography_bronze.ipynb`

The notebook follows this sequence:

1. **Load configuration.** Reads the YAML path from the `config_path` widget or `PSGC_CONFIG_PATH` environment variable. If neither is supplied, it searches parent directories for `config/sources_geography.yaml`.
2. **Select a landing batch.** Uses the optional `landing_batch_path`; otherwise selects the newest completed batch matching the configured source, version, and endpoint.
3. **Validate landing contracts.** Confirms the success marker, manifest, file list, page count, record counts, raw API page content, landed JSON-lines content, geographic codes, record versions, and content checksum.
4. **Read landed records.** Spark reads the validated JSON-lines files and extracts selected PSGC fields while preserving the full record as `source_record_json`.
5. **Validate the Spark candidate.** Checks that the Spark record count matches the validated landing count, that PSGC codes are present, and that codes are unique.
6. **Check the target table.** If the table exists, requires exact schema compatibility and Delta format. It also checks existing records for duplicates, unexpected codes, or conflicting source JSON.
7. **Preview or write.** The  `write_to_bronze=no` previews the number of records to insert. With `write_to_bronze=yes`, the notebook creates the target table if absent and performs an insert-only Delta `MERGE`. Furthermore, `write_to_bronze` defaults to "no" if unspecified.
8. **Reconcile the result.** Checks that the stored snapshot has the expected number of records and passes the existing-row consistency checks.

#### Notebook parameters

| Widget / setting | Purpose |
|---|---|
| `config_path` | Full path to the geography YAML configuration |
| `landing_batch_path` | Optional explicit completed landing batch; blank selects the newest matching completed batch |
| `write_to_bronze` | `no` for preview; `yes` to write |

The notebook requires read access to the landing Volume and create/write access to the target Delta table. The target catalog/schema must already exist. The `qc_results_table` setting is reserved for a separate quality workflow; this notebook does not write to it.

### 3.2 Administrative boundaries: `admin_boundaries_bronze.ipynb`

The notebook follows this sequence:

1. **Read the handoff.** Requires `handoff_path` and validates that the path is a safe `/Volumes/...` path ending in `handoff.json`.
2. **Validate identifiers.** Requires the source key, dataset ID, source version, landing receipt path, staging manifest path, batch ID, Bronze table, and DQ-results table. The source version must be a 64-character lowercase hexadecimal SHA-256 value. The batch ID must equal `dataset_id:source_version`.
3. **Verify upstream artifacts.** Reads the landing receipt and staging manifest, checks their `ready` statuses and matching dataset/version/batch identifiers, and checks the manifest's landing version against the receipt location.
4. **Read prepared feature files.** Reads the exact manifest-listed files for each administrative level. Relative paths, file existence, and file sizes are checked before reading.
5. **Build Bronze records.** Preserves each raw feature as JSON and extracts feature type, feature ID, properties JSON, geometry JSON, and geometry type. Adds source, version, batch, level, file, CRS, URL, receipt/manifest, validation, ingestion-time, and record-fingerprint metadata.
6. **Reconcile candidate counts.** Candidate row counts by administrative level must equal the manifest's expected counts.
7. **Determine load action.** A new source version is loaded only if no rows for that version exist. A complete existing version is treated as `ALREADY_COMPLETE` after duplicate-fingerprint checks. A partial or inconsistent version stops rather than being appended to.
8. **Write and verify.** New records are appended to the Delta table after exact schema compatibility checks. The notebook then verifies row counts by level, total rows, and the batch ID.
9. **Publish a handoff for QC.** Writes `bronze_handoff.json` and sets the Databricks task value `bronze_handoff_path`. The batch remains pending Bronze QC and is not yet approved for Silver.

The notebook header specifies maximum concurrent runs of one. This is important because its load-action checks occur before the append and are not a substitute for coordinating concurrent writers.

## 4. Bronze Table Design

### 4.1 `public_health.bronze.geography_bronze`

**Purpose:** Stores source-aligned PSGC geography records and nested population observations.

**Grain:** One PSGC geographic code per logical source snapshot.

**Logical identity used by the notebook:** `source_system + source_version + source_endpoint + content_checksum + psgc_code`.

The notebook's `MERGE` key identifies a record within a particular source snapshot. A changed content checksum is treated as a separate snapshot rather than an update to the prior snapshot.

| Column | Type / representation | Origin | Description |
|---|---|---|---|
| `psgc_code` | STRING | `code`, falling back to `psgc_code` | Geographic code preserved as a string |
| `area_name` | STRING | Source | Area name |
| `correspondence_code` | STRING | Source | Source correspondence code, if present |
| `geographic_level` | STRING | Source | Source geographic level; blank values are preserved |
| `reg` | STRING | Source | Region code/attribute |
| `prv` | STRING | Source | Province code/attribute |
| `mun` | STRING | Source | Municipality/city code/attribute |
| `bgy` | STRING | Source | Barangay code/attribute |
| `old_name` | STRING | Source | Previous or alternate name, if present |
| `city_class` | STRING | Source | City classification, if present |
| `income_classification` | STRING | Source | Source income classification, if present |
| `urban_rural` | STRING | Source | Source urban/rural attribute, if present |
| `island_region` | STRING | Source | Source island-region attribute, if present |
| `record_status` | STRING | Source `status` | Status field from source record |
| `record_version` | STRING | Source `version` | Version carried by the record, if present |
| `populations_json` | STRING containing JSON | `populations`, falling back to `population_data` | Nested population observations retained without flattening |
| `source_record_json` | STRING containing JSON | Full landed record | Preserves the complete source record |
| `source_system` | STRING | Configuration | Source name |
| `source_version` | STRING | Configuration | Configured source version |
| `source_endpoint` | STRING | Configuration | Configured endpoint |
| `batch_id` | STRING | Landing manifest / run ID | Landing batch lineage; an existing batch ID is retained for an identical snapshot |
| `content_checksum` | STRING | Landing manifest | Logical snapshot checksum |
| `raw_path` | STRING | Runtime | Selected landing batch path |
| `ingested_at` | TIMESTAMP | Runtime | Bronze ingestion timestamp |

The notebook extracts source attributes as strings. It does not standardize names, infer geographic levels, convert population observations into rows, or otherwise perform Silver-style normalization.

### 4.2 `public_health.bronze.admin_boundaries_bronze`

**Purpose:** Preserves HDX administrative boundary features, including their source geometry, and records technical lineage.

**Grain:** One source feature for one administrative level and source version. The loader's rerun checks identify a source version and verify expected row counts by level; the profiling notes describe the logical identity as `admin_level + boundary_pcode + source_version` for the administrative-boundary pipeline. The Bronze notebook itself appends after its pre-write version checks.

| Column | Type / representation | Origin | Description |
|---|---|---|---|
| `source_feature_json` | STRING containing JSON | Prepared feature | Full source feature JSON |
| `_staging_file_path` | STRING | Spark file metadata | Path of the staged input file |
| `feature_type` | STRING | Feature JSON `type` | GeoJSON feature type |
| `source_feature_id` | STRING | Feature JSON `id` | Source feature identifier, if present |
| `properties_json` | STRING containing JSON | Feature JSON `properties` | Original properties object |
| `geometry_json` | STRING containing JSON | Feature JSON `geometry` | Original geometry object |
| `geometry_type` | STRING | `geometry.type` | Geometry type, e.g. `Polygon` or `MultiPolygon` |
| `_source_key` | STRING | Handoff | Source identifier |
| `_dataset_id` | STRING | Handoff | Dataset identifier |
| `_source_version` | STRING | Handoff | SHA-256 source-version identifier |
| `_batch_id` | STRING | Handoff | Batch identifier derived from dataset and source version |
| `_admin_level` | INT | Staging manifest | Administrative level (ADM1, ADM2, or ADM3) |
| `_source_file` | STRING | Staging manifest | Original source filename |
| `_source_file_sha256` | STRING | Staging manifest | SHA-256 checksum of the source file |
| `_source_crs` | STRING | Staging manifest | Source coordinate reference system |
| `_source_url` | STRING, nullable | Landing receipt | Source URL (nullable if omitted from receipt) |
| `_landing_receipt_path` | STRING | Runtime | Path to the validated receipt |
| `_staging_manifest_path` | STRING | Runtime | Path to the validated manifest |
| `_validation_id` | STRING, nullable | Handoff | Upstream validation identifier, if supplied |
| `_landing_ingested_at` | TIMESTAMP | Landing receipt | Upstream landing timestamp |
| `_bronze_ingested_at` | TIMESTAMP | Runtime | Bronze ingestion timestamp |
| `_record_sha256` | STRING | Derived from raw feature JSON | SHA-256 fingerprint of the feature JSON |

The table schema above reflects the columns created in the supplied notebook. Exact deployed schema and observed row counts should be confirmed from the target table and a successful run.

## 5. Design Decisions and Rationale

### D1 - Preserve source values and raw JSON

- **Context:** Geographic sources may add fields or contain values that need later interpretation.
- **Decision:** Preserve the full PSGC record in `source_record_json` and the full boundary feature in `source_feature_json`, alongside selected fields.
- **Rationale:** Maintains traceability to the source and gives Silver access to original values.
- **Downstream impact:** Silver can standardize and validate attributes without losing the original payload.

### D2 - Preserve PSGC codes as strings

- **Context:** Geographic codes are identifiers, not numeric measures. Numeric casting can remove leading zeros or alter formatting.
- **Decision:** The PSGC notebook requires a nonblank string code and exposes it as `psgc_code` STRING.
- **Rationale:** Preserves source representation and supports reliable code-based joins.
- **Downstream impact:** Keep code columns as strings throughout the pipeline.

### D3 - Retain nested population observations in Bronze

- **Context:** One PSGC record can contain multiple population observations, including years such as 2015, 2020, and 2024.
- **Decision:** Keep the nested observations in `populations_json` as a JSON string rather than flattening them in Bronze.
- **Rationale:** Bronze remains source-aligned; parsing and exploding the array belongs in Silver.
- **Downstream impact:** The current population Silver design parses `populations_json` into observations at the `psgc_code × population_year × source_version` grain.

### D4 - Do not infer blank geographic levels in Bronze

- **Context:** The profiling notes identify special cases such as City of Isabela (Not a Province) and the Special Geographic Area, for which a blank source geographic level may be meaningful or require further interpretation.
- **Decision:** Preserve a blank `geographic_level` rather than guessing a replacement.
- **Rationale:** Prevents unsupported assumptions from being embedded in raw ingestion.
- **Downstream impact:** Silver should standardize geographic levels using documented rules and retain the ability to trace them to source values.

### D5 - Use content-based snapshot identity for PSGC

- **Context:** A source version label alone may not distinguish different retrieved contents.
- **Decision:** The PSGC notebook uses source, version, endpoint, checksum, and PSGC code as the `MERGE` key.
- **Rationale:** Re-running the same content is idempotent, while changed content can be retained as a separate snapshot.
- **Downstream impact:** The supplied Silver notebook expects one checksum/batch snapshot for its configured version. Loading a different snapshot for the same configured version is blocked to avoid silently changing the input selected by Silver.

### D6 - Validate landing artifacts before PSGC writes

- **Context:** Partial pagination, changed files, duplicate codes, or mismatched manifests could create an incomplete geography reference.
- **Decision:** Require `_SUCCESS`, a matching landed manifest, complete expected filenames, matching raw and landed page records, reconciled counts, unique codes, compatible record versions, and a matching content checksum.
- **Rationale:** Detects incomplete or inconsistent landing batches before modifying Bronze.
- **Downstream impact:** Silver receives a snapshot whose landing-level contracts passed the notebook's checks.

### D7 - Preserve each administrative-boundary source version

- **Context:** Boundary data may change over time and different source versions may reflect different administrative structures.
- **Decision:** Administrative-boundary Bronze uses source-version snapshots and appends a new version only after checks indicate that the version is not already present.
- **Rationale:** Retains source history and avoids overwriting prior versions.
- **Downstream impact:** Silver reconciliation must use a deliberate source-version selection and must not assume all boundary versions describe the same geography.

### D8 - Do not append to a partial administrative-boundary version

- **Context:** A partial load can leave a version with incomplete administrative levels.
- **Decision:** If rows for a version exist but counts by level do not match the manifest, the notebook stops. A complete version is treated as already loaded after duplicate fingerprint checks.
- **Rationale:** Avoids compounding an uncertain partial state with another append.
- **Operational note:** The documented recovery path should be an explicit investigation and repair, not an automatic retry that appends to the partial version.

### D9 - Separate Bronze loading from Bronze QC and Silver approval

- **Context:** Successful persistence does not by itself mean the data is fit for downstream analytical use.
- **Decision:** The administrative-boundary notebook writes a handoff with status `bronze_loaded_pending_qc`; the separate QC notebook owns the data-quality audit and Silver approval gate.
- **Rationale:** Separates technical ingestion integrity from data-quality approval.
- **Downstream impact:** A loaded batch must not be described as Silver-approved until the QC workflow passes.

### D10 - Reconcile HDX boundaries to PSGC in Silver, not by name-only joins in Bronze

- **Context:** PSGC codes and HDX P-codes use different formats, and administrative hierarchies and names can differ. The profiling notes report 1,747 boundary rows: 17 ADM1, 88 ADM2, and 1,642 ADM3. They report direct derived-code matches of 17/17 ADM1, 79/88 ADM2, and 1,519/1,642 ADM3.
- **Decision:** Preserve the boundary source attributes in Bronze and perform explicit reconciliation downstream.
- **Rationale:** A transformed code is useful for deterministic matching but does not resolve every structural or historical difference.
- **Downstream impact:** The notes describe deterministic code matching and carefully constrained name/hierarchy matching, with explicit statuses such as `CODE_MATCH`, `NAME_LEVEL_MATCH`, `HIERARCHY_MATCH`, `NOT_APPLICABLE`, `UNMATCHED`, and `AMBIGUOUS`.
- **Important interpretation:** `UNMATCHED` does not automatically mean invalid. The profiling notes recommend a warning rather than a blanket failure for expected structural/version differences. Final QC severity should follow the implemented Silver/QC rules.

### D11 - Normalize boundary names only for comparison

- **Context:** The notes identify encoding/mojibake and naming differences, including abbreviations, alternate historical names, and capital annotations.
- **Decision:** The documented direction is controlled normalization for matching while preserving original source values.
- **Rationale:** Supports reconciliation without rewriting source evidence.
- **Status:** This describes the documented reconciliation approach; the Bronze loader shown here preserves the raw feature and does not implement the matching normalization itself.

## 6. Data Quality and Error Handling

### 6.1 PSGC checks implemented in the notebook

| Check | Current behavior |
|---|---|
| Landing completion | Requires `_SUCCESS` and a manifest with `status = landed` |
| Source identity | Manifest source name, version, and endpoint must match configuration |
| Success marker | `_SUCCESS` contents must equal the manifest run ID |
| Manifest counts | Counts must be nonnegative integers; page and record counts must be positive |
| Expected files | Manifest file list and actual page files must match the expected page count |
| Raw/landed agreement | Parsed `results` from each raw page must equal the corresponding landed JSON-lines records |
| Geographic code | Code must be a nonblank string, using `code` or fallback `psgc_code` |
| Duplicate codes | Duplicate geographic codes within the batch are rejected |
| Record version | If present, the record version must match the manifest source version |
| Record counts | Manifest record counts must reconcile to landed records |
| Content integrity | Canonical record hashes must reproduce the manifest checksum |
| Spark candidate | Count must match landing; code must be present and unique |
| Target compatibility | Existing schema must match exactly; existing table must be Delta |
| Existing snapshot | Duplicate codes, unexpected codes, and conflicting source JSON cause failure |
| Post-write integrity | Stored snapshot count and consistency checks must pass |

**Known operational limitation:** The notebook uses a single-writer expectation for a snapshot. Delta does not enforce the logical uniqueness key itself, so concurrent writers should not be run for the same snapshot.

### 6.2 Administrative-boundary checks implemented in the notebook

| Check | Current behavior |
|---|---|
| Handoff path | Must be a safe `/Volumes/...` file path ending in `handoff.json` |
| Handoff contract | Required fields must be present |
| Source version | Must be a 64-character lowercase hexadecimal SHA-256 string |
| Batch identity | Must equal `dataset_id:source_version` |
| Receipt and manifest | Must be `ready` and match dataset, source version, and batch |
| Staging location | Manifest landing version must match the receipt's parent location |
| Staged file paths | Reject absolute paths, parent traversal, and backslashes in relative paths |
| Staged files | Files must exist and match manifest byte sizes |
| Candidate counts | Counts by administrative level and total must match the manifest |
| Existing version | Complete version is a no-op; partial/inconsistent version fails |
| Duplicate fingerprints | Existing version is rejected if duplicate `_admin_level + _record_sha256` pairs are found |
| Schema | Existing table must have exact candidate schema before append |
| Post-write reconciliation | Counts by level, total, and batch ID must match expectations |
| QC handoff | Emits `bronze_handoff.json` for the separate Bronze QC stage |

The notebook delegates the full data-quality audit and Silver approval gate to `admin_boundaries_bronze_qc.ipynb`.

## 7. Downstream Dependencies and Analytical Impact

### 7.1 Expected consumers

The supplied profiling notes identify these intended Silver outputs:

- `public_health.silver.geography_silver` - canonical PSGC geography.
- `public_health.silver.population_silver` - parsed and typed population observations from `geography_bronze.populations_json`.
- `public_health.silver.admin_boundaries_silver` - cleaned HDX ADM1–ADM3 boundary records.
- `public_health.silver.geography_crosswalk_silver` - reconciliation between current PSGC geography and HDX boundaries.

These are documented intended dependencies; actual orchestration and current table status should be verified in the repository and workspace.

### 7.2 Join and modeling considerations

- Use PSGC codes as strings; do not cast them to numbers.
- Do not directly equate `psgc_code` and HDX `adm3_pcode`. The notes describe a derived P-code mapping (`PH` plus the first seven characters of a ten-character PSGC code) that matches many, but not all, ADM3 records.
- Use a reviewed crosswalk for unmatched, ambiguous, historical, or structurally different areas. Do not rely on names alone as identity keys.
- Preserve the difference between source-level geography and downstream standardized geography.
- Keep population observations at their recorded year and source version. Bronze does not interpolate missing years.
- Boundary centroid distance is a straight-line geographic proxy, not actual patient travel distance. If used in downstream analysis, describe it as distance from a municipality's representative geographic point to the nearest hospital, not as residents' travel distance.
- For service-gap analysis, the full canonical geography should define the geographic denominator. Facility presence should be left-joined to that denominator downstream so areas with no recorded facility are not accidentally dropped.

### 7.3 Business-question relevance

| Question | Geography contribution | What geography alone cannot establish |
|---|---|---|
| A1: Areas with no recorded hospital and resident population | PSGC area identity and population observations provide geography and denominators | Requires facility data and Gold aggregation |
| A2: Highest hospital level and Level 3 gaps | Provides consistent area identifiers and hierarchy | Requires hospital registry classifications and Gold logic |
| A3: Areas with no recorded licensed primary care facility and population | Provides area identifiers and population observations | Requires the correct HFSRB primary-care source and Gold aggregation |
| A4: Population per hospital, primary care facility, or hospital bed | Provides geography and population denominators | Requires facility counts/beds, matching geographic scope, and Gold calculations |

## 8. Validation and Reproducibility

### 8.1 PSGC notebook

1. Confirm that the API-to-landing job completed successfully.
2. Ensure the landing batch contains `_SUCCESS`, `manifest.json`, raw page JSON, and landed JSON-lines files.
3. Import `geography_bronze.ipynb` into Databricks and attach suitable compute.
4. Set `config_path` to the correct `sources_geography.yaml`.
5. Optionally set `landing_batch_path` to a specific completed batch.
6. Run with `write_to_bronze=no` first and review the selected batch, record count, existing snapshot count, and insert count.
7. Only after review, set `write_to_bronze=yes` and run again.
8. Confirm `Landing → Bronze completed.` and review the final table, snapshot count, batch ID, and checksum.

The notebook's built-in checks are the validation evidence described here. No successful execution result is asserted by this document.

### 8.2 Administrative-boundary notebook

1. Run the upstream ingestion and staging workflow to produce a handoff, ready receipt, and staging manifest.
2. Confirm that the handoff's source version, dataset ID, batch ID, and artifact paths correspond to the intended source snapshot.
3. Set `handoff_path` to the full path of `handoff.json`.
4. Run `admin_boundaries_bronze.ipynb` with maximum concurrent runs set to one.
5. Review expected and candidate counts by ADM level and the selected load action.
6. Confirm post-write reconciliation and inspect the generated `bronze_handoff.json`.
7. Run `admin_boundaries_bronze_qc.ipynb` and confirm the batch passes the applicable QC gate before treating it as approved for Silver.


## 9. Open Issues and Future Improvements

1. **Snapshot selection:** Keep the PSGC Bronze version/checksum selection aligned with the Silver reader, which expects one snapshot for the configured version.
2. **Concurrent loads:** Enforce one writer per PSGC snapshot and maximum concurrent runs of one for the administrative-boundary loader.
3. **Path error diagnosis:** The profiling notes describe a helper that treats any `dbutils.fs.ls` exception as a missing path. Where that helper is still used upstream, distinguish permission/access failures from genuinely absent paths.
4. **Crosswalk completion:** Continue reviewing unresolved and ambiguous HDX-to-PSGC matches, particularly special administrative structures and historical hierarchy changes.
5. **Source naming/encoding:** Keep original values, and use controlled normalized comparison keys only in reconciliation.
6. **Observed counts:** Refresh row counts and schema details from the actual target tables after each meaningful source refresh; counts in profiling notes are point-in-time observations.
7. **Population coverage:** Keep observed population years and source versions explicit; any interpolation or projection should be a separate, documented downstream decision.
8. **Documentation alignment:** Verify that YAML filenames and layouts used by current Silver notebooks match the Bronze configuration. The PSGC notebook notes that Silver readers may still expect `../../config/sources_geography.yaml` with a top-level `sources` section.

## 10. Change Log

| Date | Change | Reason |
|---|---|---|
| 2026-10-12 | Initial geography Bronze documentation draft | Based on the supplied PSGC Bronze notebook, administrative-boundary Bronze notebook, and geography profiling notes |
