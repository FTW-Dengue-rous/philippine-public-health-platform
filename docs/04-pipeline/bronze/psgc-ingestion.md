# PSGC Bronze Ingestion Evidence

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

## Purpose

This document records validation evidence for the PSA Philippine
Standard Geographic Code (PSGC) Bronze ingestion pipeline.

The pipeline retrieves PSGC reference data from the PSA API,
preserves the raw API responses, validates the extracted dataset,
and safely loads validated records into the Bronze Delta table.

---

## Source

**Source:** Philippine Statistics Authority (PSA) PSGC API

**Source version:** `Q2_2024`

**Endpoint:** `all`

Authentication is performed using a PSA API token stored in
Databricks Secrets.

No API tokens or credentials are committed to the repository.

---

## Landing Location

Validated raw files are stored under:

`/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/psgc/raw/version=Q2_2024/content_checksum=6f410c890595efaf757f87c465976212216133e4b1c49f6e24ff2871881ad091`

Each API page is preserved as an original JSON response.

A corresponding NDJSON file is also created per API page for
structured Spark ingestion.

---

## Bronze Target

Bronze table:

`public_health.bronze.geography_bronze`

Ingestion metadata table:

`public_health.bronze.ingestion_metadata`

---

## Extraction Results

| Validation | Result |
|---|---:|
| API-reported records | 43,762 |
| Records retrieved | 43,762 |
| Pages retrieved | 44 |
| Raw API page files | 44 |
| NDJSON page files | 44 |
| Unique source codes | 43,762 |
| Missing source codes | 0 |
| Duplicate source codes | 0 |
| Version mismatches | 0 |

All extraction and landing reconciliation checks passed.

---

## Content Checksum

The logical PSGC snapshot produced the following SHA-256 checksum:

`6f410c890595efaf757f87c465976212216133e4b1c49f6e24ff2871881ad091`

The checksum is generated from deterministic representations of
the logical source records.

This allows the pipeline to identify previously processed source
content during reruns.

---

## Bronze Validation

The validated PSGC dataset was merged into:

`public_health.bronze.geography_bronze`

| Validation | Result |
|---|---:|
| Source records | 43,762 |
| Bronze incoming records | 43,762 |
| Bronze stored records | 43,762 |
| Bronze unique PSGC codes | 43,762 |
| Missing Bronze PSGC codes | 0 |

The Bronze row count reconciled exactly with the source record count.

---

## Idempotency Design

The ingestion pipeline uses the following controls:

1. A deterministic SHA-256 checksum identifies the logical source snapshot.
2. Previously processed checksums are checked before Bronze promotion.
3. Validated raw data is stored under a checksum-based path.
4. Bronze records are written using Delta `MERGE`.
5. The Bronze merge identity is:

   `content_checksum + psgc_code`

6. Batch execution state is recorded in the ingestion metadata table.

Supported run statuses include:

- `in_progress`
- `processed`
- `failed`
- `skipped_duplicate`

---

## Idempotency Rerun Test

**Status: PASSED**

The PSGC ingestion notebook was executed again against the same
`Q2_2024` source dataset.

The second run generated the same logical content checksum:

`6f410c890595efaf757f87c465976212216133e4b1c49f6e24ff2871881ad091`

The pipeline detected that the same logical dataset had already
been successfully processed.

The second ingestion run was marked:

`skipped_duplicate`

and the notebook exited before another Bronze write occurred.

### Result

| Validation | Result |
|---|---:|
| Original Bronze rows | 43,762 |
| Bronze rows after rerun | 43,762 |
| Unique PSGC codes | 43,762 |
| Duplicate rows added | 0 |
| Second-run status | `skipped_duplicate` |

This demonstrates that rerunning the same PSGC source batch does
not create duplicate records in the Bronze layer.

---

## Failure Recovery

Raw extraction is initially written to a run-specific temporary path:

`raw/_tmp/run_id=<run_id>`

Only validated batches are promoted to the permanent checksum-based
raw location.

If downstream processing fails after raw promotion, the persisted
raw files can be reused instead of downloading the PSA source again.

The Bronze Delta `MERGE` also protects retry attempts from inserting
duplicate records.

### Known Source Data Exceptions

Two PSGC records contain a blank `geographic_level` in the PSA source:

- `0990100000` — City of Isabela (Not a Province)
- `1999900000` — Special Geographic Area

The Bronze layer preserves these source values without inference.

Population observations may also contain blank values or `#N/A`.
These values are preserved in Bronze and will be standardized to
NULL during Silver transformation.

---

## Validation Queries

### Bronze row count and uniqueness

```sql
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT psgc_code) AS unique_psgc_codes
FROM public_health.bronze.geography_bronze;
```
## Idempotency Rerun Test
**Status: PASSED**

The PSGC ingestion notebook was executed again against the same
`Q2_2024` source dataset.

The rerun produced the same logical content checksum:

`6f410c890595efaf757f87c465976212216133e4b1c49f6e24ff2871881ad091`

The ingestion metadata table identified that the same logical
dataset had already been successfully processed.

The second ingestion run was therefore marked:

`skipped_duplicate`

and the notebook exited before raw promotion and the Bronze MERGE.

### Result

| Validation | Result |
|---|---:|
| Original Bronze rows | 43,762 |
| Bronze rows after rerun | 43,762 |
| Unique PSGC codes | 43,762 |
| Duplicate rows added | 0 |
| Second-run status | `skipped_duplicate` |

This demonstrates that rerunning the same PSGC source batch does
not create duplicate records in the Bronze layer.
