# Evidence

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

Execution records and supporting artifacts that verify the pipeline runs on Databricks.

## Records

| Record | Content |
|---|---|
| [Full pipeline run in the current workspace (2026-10-18)](2026-10-18-new-workspace-run.md) | Job runs, IDs, timestamps, task outcomes, executed revision, outputs, QC outcomes, corrections of earlier claims |
| [Idempotency comparison](idempotency/comparison.md) | Rebuild comparison results |

## What is recorded

* **Job runs**: the Databricks Jobs run history of the two pipeline jobs (IDs and URLs in the run record above).
* **Build log**: `public_health.quality.build_log` — one row per SQL silver or gold build with build ID, target table, status, start/finish time, and parameters. Bronze loads and Python silver builds (geography, population, admin boundaries) are not logged here.
* **Build inputs**: `public_health.quality.build_inputs` — one row per input file/sheet per build with source key, file, sheet, load batch ID, checksum, and ingested timestamp.
* **QC results**: `public_health.quality.qc_results` — check results with severity, pass/fail, and actual vs expected values.
* **Row dispositions**: `public_health.quality.row_disposition` — rows not loaded (dropped, duplicate, quarantined, merged).

## Build log summary

Query executed 2026-10-18, after the pipeline runs:

```sql
SELECT COUNT(*) AS total, COUNT(CASE WHEN status='succeeded' THEN 1 END) AS succeeded,
       COUNT(CASE WHEN status='failed' THEN 1 END) AS failed,
       MIN(started_at) AS earliest, MAX(finished_at) AS latest
FROM public_health.quality.build_log;
-- Result: 85 total, 85 succeeded, 0 failed, 2026-10-09 to 2026-10-18
-- By date: 2026-10-09: 9 builds, 2026-10-12: 4 builds, 2026-10-18: 72 builds
```

The `build_log` table was created 2026-10-09 08:05 UTC. Its Delta history shows DELETE operations only on 2026-10-09 and appends only since then, so the retained history is complete.

**Correction (2026-10-18)**: an earlier version of this file stated "114 builds: 106 succeeded and 8 failed ... 2026-10-13 to 2026-10-15". Those numbers cannot be reproduced: `build_log` contains no rows dated 2026-10-13 to 2026-10-15 and has no deletions after 2026-10-09. The unsupported figure has been removed. See the [run record](2026-10-18-new-workspace-run.md#correction-of-earlier-records) for the verification steps.

## Full pipeline run (2026-10-18)

The pipeline (setup, bronze, silver, gold) ran end to end in this workspace on 2026-10-18. The manually created job's full 66-task run (513012844601841) succeeded after two run repairs; a race with the concurrently running bundle job caused the two intermediate failures. A 40-task silver-stage run (218424935830057) and the bundle job's 72-task run (23167081408523) also succeeded the same day. Full details, timestamps, and outputs: [2026-10-18 run record](2026-10-18-new-workspace-run.md).

## Verified silver builds (2026-10-18 pipeline runs)

The SQL-built silver tables below were created or rebuilt by the 2026-10-18 orchestrated runs. Geography, population, and admin boundaries are built by Python scripts that do not write `build_log`; their current builds date from 2026-10-09 (table Delta history).

| Table | Rows | Build date | Script |
|---|---|---|---|
| `geography_silver` | 43,762 | 2026-10-09 | `geography_silver.py` |
| `population_silver` | 127,945 | 2026-10-09 | `psgc_population_silver.py` |
| `admin_boundaries_silver` | 1,747 | 2026-10-09 | `admin_boundaries_silver.py` |
| `facilities_id_map_silver` | 5,257 | 2026-10-18 | `facilities_silver_01_registry.sql` |
| `facilities_registry_silver` | 3,957 | 2026-10-18 | `facilities_silver_01_registry.sql` |
| `facilities_metric_silver` | 2,988 | 2026-10-18 | `facilities_silver_02_metric.sql` |
| `facilities_bed_occupancy_silver` | 9,145 | 2026-10-18 | `facilities_silver_03_bed_occupancy.sql` |
| `facilities_osm_point_silver` | 16,030 | 2026-10-18 | `facilities_silver_04_osm_point.sql` + `facilities_silver_04a_osm_locate.py` (bundle job) |
| `diseases_metric_silver` | 131,887 | 2026-10-18 | `diseases_silver_01_metric.sql` |
| `diseases_directory_silver` | 179 | 2026-10-18 | `diseases_silver_00_reference.sql` |
| `diseases_deaths_age_silver` | 90,480 | 2026-10-18 | `diseases_silver_02_deaths_age.sql` |
| `diseases_source_coverage_silver` | 73 | 2026-10-18 | `diseases_silver_04_source_coverage.sql` |
| `diseases_tb_programme_silver` | 73,216 | 2026-10-18 | `diseases_silver_05_tb_programme.sql` |
| `diseases_hospital_encounters_silver` | built | 2026-10-18 | `diseases_silver_03_hospital_encounters.sql` |
| `diseases_hospital_claims_silver` | built | 2026-10-18 | `diseases_silver_06_hospital_claims.sql` |
| `socioeconomic_poverty_silver` | 322 | 2026-10-18 | `socioeconomic_silver_01_poverty.sql` |
| `socioeconomic_health_expenditure_share_silver` | 128 | 2026-10-18 | `socioeconomic_silver_02_health_expenditure_share.sql` |
| `socioeconomic_health_expenditure_per_capita_silver` | 8 | 2026-10-18 | `socioeconomic_silver_03_health_expenditure_per_capita.sql` |
| `socioeconomic_child_mortality_silver` | 60 | 2026-10-18 | `socioeconomic_silver_04_child_mortality.sql` |
| `workforce_headcount_silver` | 28,071 | 2026-10-18 | `workforce_silver_02_headcount.sql` |
| `workforce_specialist_silver` | 52 | 2026-10-18 | `workforce_silver_04_specialist.sql` |
| `workforce_area_denominator_silver` | 3,023 | 2026-10-18 | `workforce_silver_03_denominator.sql` |

*(Source: build_log query, table Delta history (creation timestamps), and COUNT(*) per table, executed 2026-10-18.)*

## Verified gold builds (2026-10-18)

All gold objects in `public_health.gold` were created by the 2026-10-18 runs (first creation 14:11 UTC; final writes 15:09 UTC). The schema contains 12 managed tables (the 5 dimensions, 4 facts, `source_priority`, `priority_weight_params`, `ref_osm_healthsite_point`) and 17 views (all marts, `area_coverage_map`, `fact_area_access`, `huc_province_crosswalk`, and the helper views `v_area_indicator_latest`, `v_disease_metric_totals`, `v_facility_capacity_totals`, `v_workforce_preferred`), verified via `system.information_schema.tables` on 2026-10-18.

| Object | Rows | Build date |
|---|---|---|
| `dim_geography` | 1,764 | 2026-10-18 |
| `dim_facility` | 3,957 | 2026-10-18 |
| `dim_disease` | 179 | 2026-10-18 |
| `dim_date` | 783 | 2026-10-18 |
| `dim_data_source` | 25 | 2026-10-18 |
| `fact_facility_capacity` | 30,365 | 2026-10-18 |
| `fact_disease_metric` | 593,171 | 2026-10-18 |
| `fact_workforce_capacity` | 28,071 | 2026-10-18 |
| `fact_area_indicator` | 8,928 | 2026-10-18 |
| `fact_area_access` | 1,642 | 2026-10-18 |
| `source_priority` | 34 | 2026-10-18 |
| `ref_osm_healthsite_point` | 16,030 | 2026-10-18 |
| `area_coverage_map` | 9,909 | 2026-10-18 |
| `huc_province_crosswalk` | 17 | 2026-10-18 |
| `priority_weight_params` | 12 | 2026-10-18 |
| `mart_locality_service_presence` | 1,642 | 2026-10-18 |
| `mart_base_planning_unit` | 109 | 2026-10-18 |
| `mart_area_service_profile` (view) | 109 | 2026-10-18 |
| `mart_area_burden_indicator` | 2,071 | 2026-10-18 |
| `mart_area_evidence` | 2,943 | 2026-10-18 |
| `mart_area_priority` | 12,426 | 2026-10-18 |
| `mart_tb_case_study` | 1,642 | 2026-10-18 |
| `mart_kidney_case_study` | 81 | 2026-10-18 |
| `mart_dengue_peak_capacity` | 981 | 2026-10-18 |
| `mart_evidence_readiness` | 28 | 2026-10-18 |

*(Source: build_log query, table Delta history, and COUNT(*) per table, executed 2026-10-18. Counts are current table state; both jobs wrote to these tables during the runs.)*

## Legacy gold v1

An earlier v1 `mart_area_service_profile` (2,784 rows; built 2026-10-13 in the original team workspace; count verified 2026-10-18) used a different grain (`supply_section x area_level x area_key x year x ownership x facility_level`). It was superseded when the v2 model (formerly in schema `test_gold2`) was renamed to `public_health.gold` on 2026-10-19. The current `public_health.gold.mart_area_service_profile` is a view with 109 rows at planning-unit grain. See [gold README](../04-pipeline/gold/README.md) for the model details.

## Previously unverified — now resolved

* `facilities_osm_point_silver` was documented as unverified (2026-10-14). It was created on 2026-10-18 at 13:16 UTC by the bundle job's run (23167081408523) and has 16,030 rows. Verified via the table's Delta history (version 0) and `qc_results` rows recorded 13:35-14:07 UTC. See [known issues](../08-governance/known-issues-and-backlog.md) KI1 (resolved).

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
