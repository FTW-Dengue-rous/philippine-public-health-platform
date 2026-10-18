# Evidence

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Execution records and supporting artifacts that verify the pipeline ran successfully on Databricks.

## What is recorded

* **Build log**: `public_health.quality.build_log` — one row per silver or gold build with build ID, target table, status, start/finish time, and parameters.
* **Build inputs**: `public_health.quality.build_inputs` — one row per input file/sheet per build with source key, file, sheet, load batch ID, checksum, and ingested timestamp.
* **QC results**: `public_health.quality.qc_results` — check results with severity, pass/fail, and actual vs expected values.
* **Row dispositions**: `public_health.quality.row_disposition` — rows not loaded (dropped, duplicate, quarantined, merged).

## Build log summary

As of 2026-10-18, the build log contains 114 builds: 106 succeeded and 8 failed. All 8 failures were early attempts on 2026-10-13 and 2026-10-14 before fixes were applied. The latest full pipeline run completed on 2026-10-15 with all silver and gold v2 tables succeeding.

Query executed 2026-10-18:

```sql
SELECT COUNT(*) AS total, COUNT(CASE WHEN status='succeeded' THEN 1 END) AS succeeded,
       COUNT(CASE WHEN status='failed' THEN 1 END) AS failed,
       MIN(started_at) AS earliest, MAX(finished_at) AS latest
FROM public_health.quality.build_log;
-- Result: 114 total, 106 succeeded, 8 failed, 2026-10-13 to 2026-10-15
```

## Verified silver builds (2026-10-15 full pipeline run)

| Table | Rows | Build date | Script |
|---|---|---|---|
| `geography_silver` | 43,762 | 2026-10-09 | `geography_silver.py` |
| `population_silver` | 127,945 | 2026-10-09 | `psgc_population_silver.py` |
| `admin_boundaries_silver` | 1,747 | 2026-10-09 | `admin_boundaries_silver.py` |
| `facilities_id_map_silver` | 5,257 | 2026-10-15 | `facilities_silver_01_registry.sql` |
| `facilities_registry_silver` | 3,957 | 2026-10-15 | `facilities_silver_01_registry.sql` |
| `facilities_metric_silver` | 2,988 | 2026-10-15 | `facilities_silver_02_metric.sql` |
| `facilities_bed_occupancy_silver` | 9,145 | 2026-10-15 | `facilities_silver_03_bed_occupancy.sql` |
| `facilities_osm_point_silver` | 16,030 | 2026-10-15 | `facilities_silver_04_osm_point.sql` |
| `diseases_metric_silver` | 131,887 | 2026-10-15 | `diseases_silver_01_metric.sql` |
| `diseases_directory_silver` | 179 | 2026-10-15 | `diseases_silver_00_reference.sql` |
| `diseases_deaths_age_silver` | 90,480 | 2026-10-15 | `diseases_silver_02_deaths_age.sql` |
| `diseases_source_coverage_silver` | 73 | 2026-10-15 | `diseases_silver_04_source_coverage.sql` |
| `diseases_tb_programme_silver` | 73,216 | 2026-10-15 | `diseases_silver_05_tb_programme.sql` |
| `diseases_hospital_encounters_silver` | built | 2026-10-15 | `diseases_silver_03_hospital_encounters.sql` |
| `diseases_hospital_claims_silver` | built | 2026-10-15 | `diseases_silver_06_hospital_claims.sql` |
| `socioeconomic_poverty_silver` | 322 | 2026-10-15 | `socioeconomic_silver_01_poverty.sql` |
| `socioeconomic_health_expenditure_share_silver` | 128 | 2026-10-15 | `socioeconomic_silver_02_health_expenditure_share.sql` |
| `socioeconomic_health_expenditure_per_capita_silver` | 8 | 2026-10-15 | `socioeconomic_silver_03_health_expenditure_per_capita.sql` |
| `socioeconomic_child_mortality_silver` | 60 | 2026-10-15 | `socioeconomic_silver_04_child_mortality.sql` |
| `workforce_headcount_silver` | 28,071 | 2026-10-15 | `workforce_silver_02_headcount.sql` |
| `workforce_specialist_silver` | 52 | 2026-10-15 | `workforce_silver_04_specialist.sql` |
| `workforce_area_denominator_silver` | 3,023 | 2026-10-15 | `workforce_silver_03_denominator.sql` |

*(Source: build_log query and COUNT(*) per table, executed 2026-10-18. Row counts are from the latest successful build per table.)*

## Verified gold v2 builds (2026-10-15)

All gold v2 tables in `public_health.test_gold2` were built successfully on 2026-10-15.

| Table | Rows | Build date |
|---|---|---|
| `dim_geography` | 1,764 | 2026-10-15 |
| `dim_facility` | 3,957 | 2026-10-15 |
| `dim_disease` | 179 | 2026-10-15 |
| `dim_date` | 783 | 2026-10-15 |
| `dim_data_source` | 25 | 2026-10-15 |
| `fact_facility_capacity` | 30,365 | 2026-10-15 |
| `fact_disease_metric` | 593,171 | 2026-10-15 |
| `fact_workforce_capacity` | 28,071 | 2026-10-15 |
| `fact_area_indicator` | 8,928 | 2026-10-15 |
| `fact_area_access` | 1,642 | 2026-10-15 |
| `source_priority` | 34 | 2026-10-15 |
| `ref_osm_healthsite_point` | 16,030 | 2026-10-15 |
| `area_coverage_map` | 9,909 | 2026-10-15 |
| `huc_province_crosswalk` | 17 | 2026-10-15 |
| `priority_weight_params` | 12 | 2026-10-15 |
| `mart_locality_service_presence` | 1,642 | 2026-10-15 |
| `mart_base_planning_unit` | 109 | 2026-10-15 |
| `mart_area_service_profile` | 109 | 2026-10-15 |
| `mart_area_burden_indicator` | 2,071 | 2026-10-15 |
| `mart_area_evidence` | 2,943 | 2026-10-15 |
| `mart_area_priority` | 12,426 | 2026-10-15 |
| `mart_tb_case_study` | 1,642 | 2026-10-15 |
| `mart_kidney_case_study` | 81 | 2026-10-15 |
| `mart_dengue_peak_capacity` | 981 | 2026-10-15 |
| `mart_evidence_readiness` | 30 | 2026-10-15 |

*(Source: build_log query and COUNT(*) per table, executed 2026-10-18.)*

## Legacy gold v1

`public_health.gold.mart_area_service_profile` (2,701 rows) is the earlier v1 build from 2026-10-13. It remains in the `gold` schema but the pipeline now deploys v2 scripts from `src/04_gold/test_v2/` into `public_health.test_gold2`. See [gold README](../04-pipeline/gold/README.md) for the model version decision.

## Previously unverified — now resolved

* `facilities_osm_point_silver` was documented as unverified (2026-10-14). It was built successfully on 2026-10-15 with 16,030 rows. See [known issues](../08-governance/known-issues-and-backlog.md) KI1 (resolved).

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

-- QC failures (a failed check stores status = its severity; only FAIL blocks)
SELECT * FROM public_health.quality.qc_results
WHERE status = 'FAIL'
ORDER BY executed_at DESC;

-- Row dispositions
SELECT reason, count(*) FROM public_health.quality.row_disposition
WHERE build_id = '<build_id>'
GROUP BY reason;
```
