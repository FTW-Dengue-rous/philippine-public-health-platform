# Silver quality checks

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Silver quality checks are implemented in `src/05_quality/silver/` and inline in silver SQL scripts. Each silver build script runs validation gates before writing the target table. If validation fails, the build is logged as failed and the target table is left unchanged.

## Per-domain checks (inline in silver SQL)

| Check | Rule | Severity | Expected result | Failure action |
|---|---|---|---|---|
| S01 | No null keys | ERROR | 0 nulls in key columns | Fail build, leave target unchanged |
| S02 | No duplicate keys | ERROR | 0 duplicates | Fail build, leave target unchanged |
| S03 | Lineage complete | ERROR | Every row has `_silver_build_id`, `_source_key`, `_source_file` | Fail build |
| S04 | Row count reconciliation | ERROR | Silver rows + disposition rows = bronze input rows | Fail build |
| S05 | Geographic match | WARN | Area keys resolve to `geography_silver` | Record warning, continue |
| S06 | Exactly one ingestion_metadata match per input | ERROR | 1 match per input | Fail build |

## Cross-domain checks

Implemented in `src/05_quality/silver/silver_cross_domain_qc.py`. Runs after all domain silver builds complete.

| Check | Rule | Severity |
|---|---|---|
| X01 | Facilities area keys join to geography | WARN |
| X02 | Disease area keys join to geography | WARN |
| X03 | Workforce area keys join to geography | WARN |
| X04 | Socioeconomic area keys join to geography | WARN |

Cross-domain checks produce warnings, not errors. They identify rows where area keys from domain silver tables do not resolve to `geography_silver`. These rows are typically caused by PSGC code changes or name mismatches.

## Results storage

QC results are stored in `public_health.quality.qc_results`. Build metadata is in `public_health.quality.build_log`. Row dispositions (dropped, duplicate, quarantined, merged) are in `public_health.quality.row_disposition`.

## Verified results

All domain silver builds succeeded on 2026-10-18 (orchestrated pipeline runs; zero FAIL QC rows recorded):

* `facilities_id_map_silver`: 5,257 rows, 0 null keys, 0 duplicates, lineage complete. PASS.
* `facilities_registry_silver`: 3,957 rows, 0 null keys, 0 duplicates, lineage complete. PASS.
* `facilities_metric_silver`: 2,988 rows, 0 null keys, 0 duplicates, lineage complete. PASS.
* `facilities_bed_occupancy_silver`: 9,145 rows, 0 null keys, 0 duplicates, lineage complete. PASS.
* `facilities_osm_point_silver`: 16,030 rows, 0 null keys, 0 duplicates, lineage complete. PASS.
* `diseases_metric_silver`: 131,887 rows. PASS.
* `diseases_deaths_age_silver`: 90,480 rows. PASS.
* `diseases_tb_programme_silver`: 73,216 rows. PASS.
* `socioeconomic_poverty_silver`: 322 rows. PASS.
* `socioeconomic_health_expenditure_share_silver`: 128 rows. PASS.
* `workforce_headcount_silver`: 28,071 rows. PASS.
* `workforce_specialist_silver`: 52 rows. PASS.

*(Source: build_log status = succeeded for all 2026-10-18 builds. Row counts from COUNT(*) queries, 2026-10-18.)*

Warnings (non-blocking, facilities bed occupancy):
* BOR > 150 (implausible, excluded): 110 rows.
* BOR > 100 (over capacity): 281 rows.
* City unresolved (geography): 1 row.

See [quality results](../quality/quality-results.md) for the full verified outcomes and [quality control framework](../quality/quality-control-framework.md) for the framework overview.