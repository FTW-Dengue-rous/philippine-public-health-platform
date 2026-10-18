# Quality check catalog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

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

Implemented in `src/05_quality/gold/gold_qc.py`.

| Check | Rule | Severity |
|---|---|---|
| G01 | Mart row count > 0 | ERROR |
| G02 | Key columns non-null | ERROR |
| G03 | Metric columns within expected range | WARN |

See [quality control framework](quality-control-framework.md) for the framework overview and [quality results](quality-results.md) for recorded outcomes.
