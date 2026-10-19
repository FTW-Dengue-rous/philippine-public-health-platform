# Quality control framework

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

Quality is enforced at three layers: bronze, silver, and gold. Each layer has QC scripts in `src/05_quality/`.

## Severity levels

| Severity | Behavior |
|---|---|
| ERROR | Raises an exception via `dq_utils.DQRun`. Fails the task. Stops downstream execution. |
| WARN | Records the warning in `qc_results`. Pipeline continues. |
| INFO | Records information in `qc_results`. Pipeline continues. |

A documented warning is not a blocking quality gate. Only ERROR stops downstream execution.

**Stored values:** The `qc_results` table stores `status` as PASS, WARN, or FAIL, and `severity` as WARN or FAIL. A check configured with ERROR severity in the YAML is stored as `severity = 'FAIL'` in `qc_results`. Both refer to the same blocking check: ERROR is the configuration name, FAIL is the stored value. Query `qc_results` with `severity = 'FAIL'` to find blocking failures, not `severity = 'ERROR'`.

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

Gold QC lives in `src/05_quality/gold/gold_qc.py` and validates published gold tables in `public_health.gold`. It runs after the last gold build script (`gold_24_mart_evidence_readiness.sql`) and writes results to `quality.qc_results` via `dq_utils.DQRun`. Any FAIL makes the run raise, so downstream tasks (e.g. dashboard refresh) do not start.

The gold build scripts already gate their own candidate before publishing (write-audit-publish). Gold QC is the check *after* publishing: it proves the published tables are the ones the pipeline built, are fresh against their inputs, still reconcile with silver, follow the selection contracts, and did not change between two runs on the same inputs.

Implemented checks (14 codes):

| Code | Check | Severity |
|---|---|---|
| G00 | QC ran without error | FAIL |
| G01 | Table has rows | FAIL |
| G02 | Primary key complete and unique | FAIL |
| G03 | Grain (natural key) unique | FAIL |
| G04 | Foreign key resolves to its dimension | FAIL |
| G05 | Published table = its latest succeeded build (no data write after build version; OPTIMIZE/VACUUM ignored) | FAIL |
| G06 | Built from the latest build of every input (freshness) | FAIL |
| G07 | Control total: gold = silver | FAIL (claims: WARN when lower) |
| G08 | Value and value_status consistent; measures on their basis | FAIL |
| G09 | Default view / mart / seed readable and not empty | FAIL |
| G10 | One preferred source per disease series (selection contract) | FAIL |
| G11 | Measure values in a valid range | FAIL |
| G12 | Content fingerprint unchanged since the previous QC run (idempotency evidence) | WARN |
| G13 | Census population change between censuses plausible | WARN |

See [quality check catalog](quality-check-catalog.md) for the full list and [quality results](quality-results.md) for recorded outcomes.
