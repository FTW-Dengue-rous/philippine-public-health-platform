# Quality control framework

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Quality is enforced at three layers: bronze, silver, and gold. Each layer has QC scripts in `src/05_quality/`.

## Severity levels

| Severity | Behavior |
|---|---|
| ERROR | Raises an exception via `dq_utils.DQRun`. Fails the task. Stops downstream execution. |
| WARN | Records the warning in `qc_results`. Pipeline continues. |
| INFO | Records information in `qc_results`. Pipeline continues. |

A documented warning is not a blocking quality gate. Only ERROR stops downstream execution.

## Quality tables

Created by `src/00_setup/quality_setup.sql`:

| Table | Purpose |
|---|---|
| `quality.build_log` | One row per build (silver or gold). Build ID, target table, status, start/finish time, parameters. |
| `quality.build_inputs` | One row per input file/sheet per build. Source key, file, sheet, load batch ID, checksum, ingested at. |
| `quality.row_disposition` | Rows NOT loaded (dropped, duplicate, quarantined, merged). Input accounting per the [contract](../../lineage-qc-contract_v1.3.md). |
| `quality.qc_results` | QC check results: validation ID, source key, check name, severity, passed/failed, actual vs expected. |

Views:

| View | Purpose |
|---|---|
| `quality.v_build_lineage` | `build_inputs` joined to `build_log` for successful builds. One row per input per build. |
| `quality.v_qc_results_identity` | QC results with identity columns for comparison. |

## Bronze QC checks

Bronze QC scripts live in `src/05_quality/bronze/`. Checks per source (configured in YAML `qc:` section):

| Check | Description | Default severity |
|---|---|---|
| B02 | Row count match | ERROR |
| B03 | Null key columns | ERROR |
| B06 | Numeric columns are numeric | ERROR |
| B08 | No rescued data | WARN |
| B09 | Control totals match | ERROR |
| B11 | Required columns exist | ERROR |
| B12 | Header check | ERROR |
| B14 | Each file gives at least one data row | ERROR |

Checks can be skipped per source (`skip_checks: [B08]`) or severity changed (`severity: {B03: WARN}`).

## Silver QC checks

Silver QC scripts live in `src/05_quality/silver/`. They check:

* Null keys (ERROR)
* Duplicate keys (ERROR)
* Lineage completeness — every row has `_silver_build_id`, `_source_key`, `_source_file` (ERROR)
* Row count reconciliation — silver rows + disposition rows = bronze input rows (ERROR)
* Geographic match — area keys resolve to `geography_silver` (WARN for unmatched)
* Cross-domain checks — e.g. facilities join to geography, disease areas join to geography

## Gold QC

Gold QC lives in `src/05_quality/gold/gold_qc.py`. It validates mart output:

* Mart row counts are non-zero
* Key columns are non-null
* Metric columns are within expected ranges

See [quality check catalog](quality-check-catalog.md) for the full list and [quality results](quality-results.md) for recorded outcomes.
