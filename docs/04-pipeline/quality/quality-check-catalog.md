# Quality check catalog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

Complete list of quality checks across bronze, silver, and gold layers.

## Bronze checks

Implemented in `src/05_quality/bronze/*.py` via `dq_utils.DQRun`.

| Check | Rule | Severity | Expected result | Failure action | Implementation |
|---|---|---|---|---|---|
| B02 | Row count matches `expected_rows` in YAML | ERROR | Actual = expected | Fail task, stop downstream | `dq_utils.DQRun` |
| B03 | No nulls in key columns | ERROR | 0 nulls | Fail task, stop downstream | `dq_utils.DQRun` |
| B06 | Numeric columns are numeric | ERROR | 0 non-numeric values | Fail task, stop downstream | `dq_utils.DQRun` |
| B08 | No rescued data (`_rescued_data` is null) | WARN | 0 rescued values | Record warning, continue | `dq_utils.DQRun` |
| B09 | Control totals match (e.g. sum of cases per year) | ERROR | Actual = expected | Fail task, stop downstream | `dq_utils.DQRun` |
| B11 | Required columns exist | ERROR | All present | Fail task, stop downstream | Loader pre-write check |
| B12 | Header check passes | ERROR | Headers match YAML | Fail task, stop write | Loader pre-write check |
| B14 | Each file gives ≥1 data row | ERROR | ≥1 row | Fail task, stop write | Loader post-write check |

Per-source overrides: `skip_checks: [B08]` or `severity: {B03: WARN}` in the YAML `qc:` section.

## Silver checks

Implemented in `src/05_quality/silver/*.py` and inline in silver SQL scripts.

| Check | Rule | Severity | Expected result | Failure action | Implementation |
|---|---|---|---|---|---|
| S01 | No null keys | ERROR | 0 nulls in key columns | Fail build, leave target unchanged | Silver SQL validation gate |
| S02 | No duplicate keys | ERROR | 0 duplicates | Fail build, leave target unchanged | Silver SQL validation gate |
| S03 | Lineage complete | ERROR | Every row has `_silver_build_id`, `_source_key`, `_source_file` | Fail build | Silver SQL validation gate |
| S04 | Row count reconciliation | ERROR | Silver rows + disposition rows = bronze input rows | Fail build | Silver SQL |
| S05 | Geographic match | WARN | Area keys resolve to `geography_silver` | Record warning, continue | Silver QC scripts |
| S06 | Exactly one ingestion_metadata match per input | ERROR | 1 match per input | Fail build | Silver SQL input capture |

## Cross-domain silver checks

Implemented in `src/05_quality/silver/silver_cross_domain_qc.py`.

| Check | Rule | Severity |
|---|---|---|
| X01 | Facilities area keys join to geography | WARN |
| X02 | Disease area keys join to geography | WARN |
| X03 | Workforce area keys join to geography | WARN |
| X04 | Socioeconomic area keys join to geography | WARN |

## Gold checks

Implemented in `src/05_quality/gold/gold_qc.py` via `dq_utils.DQRun`. Checks published gold tables in `public_health.gold` after the last build script. Any FAIL raises and stops downstream tasks.

| Check | Rule | Severity | Expected result | Failure action | Implementation |
|---|---|---|---|---|---|
| G00 | QC ran without error | FAIL | Script completes | Written by DQRun on crash | `dq_utils.DQRun` |
| G01 | Table has rows | FAIL | Row count > 0 | Fail run, stop downstream | `gold_qc.py` |
| G02 | Primary key complete and unique | FAIL | 0 nulls, 0 duplicates | Fail run | `gold_qc.py` |
| G03 | Grain (natural key) unique | FAIL | 0 duplicate grain tuples | Fail run | `gold_qc.py` |
| G04 | Foreign key resolves to its dimension | FAIL | 0 unmatched FKs | Fail run | `gold_qc.py` |
| G05 | Published table = latest succeeded build | FAIL | No data write after build version (OPTIMIZE/VACUUM ignored) | Fail run | `gold_qc.py` |
| G06 | Built from latest build of every input | FAIL | Gold build version >= every input's latest build version | Fail run | `gold_qc.py` |
| G07 | Control total: gold = silver | FAIL (claims: WARN when lower) | Row counts reconcile | Fail run | `gold_qc.py` |
| G08 | Value and value_status consistent | FAIL | Measures on their declared basis | Fail run | `gold_qc.py` |
| G09 | Default view / mart / seed readable and not empty | FAIL | Readable, non-empty | Fail run | `gold_qc.py` |
| G10 | One preferred source per disease series | FAIL | Selection contract holds | Fail run | `gold_qc.py` |
| G11 | Measure values in a valid range | FAIL | Within configured bounds | Fail run | `gold_qc.py` |
| G12 | Content fingerprint unchanged since previous QC run | WARN | Same as previous (idempotency) | Record warning | `gold_qc.py` |
| G13 | Census population change between censuses plausible | WARN | Within expected range | Record warning | `gold_qc.py` |

See [quality control framework](quality-control-framework.md) for the framework overview and [quality results](quality-results.md) for recorded outcomes.
