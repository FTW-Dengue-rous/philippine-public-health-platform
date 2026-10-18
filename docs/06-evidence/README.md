# Evidence

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Execution records and supporting artifacts that verify the pipeline ran successfully on Databricks.

## What is recorded

* **Build log**: `public_health.quality.build_log` — one row per silver or gold build with build ID, target table, status, start/finish time, and parameters.
* **Build inputs**: `public_health.quality.build_inputs` — one row per input file/sheet per build with source key, file, sheet, load batch ID, checksum, and ingested timestamp.
* **QC results**: `public_health.quality.qc_results` — check results with severity, pass/fail, and actual vs expected values.
* **Row dispositions**: `public_health.quality.row_disposition` — rows not loaded (dropped, duplicate, quarantined, merged).

## Verified builds

| Table | Rows | Build date | Build method |
|---|---|---|---|
| `geography_silver` | 43,762 | 2026-10-09 | `geography_silver.py` (Python) |
| `facilities_id_map_silver` | 5,254 | 2026-10-10 | `facilities_silver_01_registry.sql` (v1.7 SQL) |
| `facilities_registry_silver` | 3,954 | 2026-10-10 | `facilities_silver_01_registry.sql` (v1.7 SQL) |
| `facilities_metric_silver` | 2,988 | 2026-10-12 | `facilities_silver_02_metric.sql` (v1.7 SQL) |
| `facilities_bed_occupancy_silver` | 1,977 | 2026-10-12 | `facilities_silver_03_bed_occupancy.sql` (v1.7 SQL) |
| `mart_area_service_profile` | ~2,784 | 2026-10-13 | `gold_53_mart_area_service_profile.sql` |

*(Source: Databricks build_log and verified by the team during 2026-10-09 to 2026-10-13 runs.)*

## Unverified

* `facilities_osm_point_silver` — documented per user instruction but table not found on Databricks (2026-10-14). See [known issues](../08-governance/known-issues-and-backlog.md) KI1.

## Idempotency

See [idempotency/comparison.md](idempotency/comparison.md) for rebuild comparison results.

## How to verify a build

```sql
-- Latest builds
SELECT build_id, target_table, started_at, finished_at, status
FROM public_health.quality.build_log
ORDER BY started_at DESC LIMIT 20;

-- Inputs for a build
SELECT * FROM public_health.quality.build_inputs
WHERE build_id = '<build_id>'
ORDER BY source_key;

-- QC failures
SELECT * FROM public_health.quality.qc_results
WHERE severity = 'ERROR' AND result = 'FAIL'
ORDER BY recorded_at DESC;

-- Row dispositions
SELECT reason, count(*) FROM public_health.quality.row_disposition
WHERE build_id = '<build_id>'
GROUP BY reason;
```
