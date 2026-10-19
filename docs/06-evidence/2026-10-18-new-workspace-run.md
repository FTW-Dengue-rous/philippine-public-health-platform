# Evidence: full pipeline run in the current workspace (2026-10-18)

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

This record documents the first complete, orchestrated pipeline run in this Databricks workspace: setup, bronze, silver, and gold all executed end to end from the repository working tree on 2026-10-18. It also corrects an earlier version of the evidence README that dated these builds to a "2026-10-15 full pipeline run"; that date is not supported by `quality.build_log` or by the tables' Delta history (see [Correction of earlier records](#correction-of-earlier-records)).

Recorded from job run metadata, `quality.build_log` / `qc_results`, and table Delta history, inspected 2026-10-18 around 15:20-15:45 UTC. All times are UTC.

## Workspace

* Workspace: https://dbc-13a6fb23-1fc8.cloud.databricks.com (workspace ID `o=7474644595563972`)
* Catalog: `public_health` (schemas `bronze`, `silver`, `gold` = active gold model, `quality`)
* SQL tasks ran on serverless SQL warehouse `414b6777f946b454`; Python tasks ran as `spark_python_task` with `environment_key: default` (serverless environment)
* All tasks ran as user `crisstin92@gmail.com`

## Executed code revision

* Repository: `FTW-Dengue-rous/philippine-public-health-platform`, checked out in the Databricks Git folder `/Users/crisstin92@gmail.com/philippine-public-health-platform`, branch `docs-re`, HEAD commit `e81328f` ("team contribution", committed 2026-10-18 13:40:05 UTC).
* Job tasks reference WORKSPACE file paths, so the executed code is the Git-folder working tree. At run time `src/` was identical to HEAD `e81328f`: the only uncommitted changes were in `resources/ph_public_health_dashboard.yml` and `resources/ph_public_health_job.yml`, which the manually created job does not read (it references `src/` files directly).
* The three commits on 2026-10-18 after 13:01 UTC (`4e2d53b`, `ff69352`, `e81328f`) touched documentation only, so the executed revision is `e81328f` for every attempt including the repairs.

## Jobs

Two jobs in this workspace execute the same pipeline scripts from the repository working tree:

| Job | ID | Tasks | Notes |
|---|---|---|---|
| "New Job 2026-10-15 21:16:29" (manually created pipeline job) | 553440510410749 | 66 | Task files point at `/Workspace/.../src/...`; no job parameters. Does not include the OSM silver build tasks. |
| "[dev crisstin92] ph-public-health-pipeline" (bundle job) | 835555203376044 | 72 | Deployed with `databricks bundle deploy` from `resources/ph_public_health_job.yml` (DABs). Includes `silver_facilities_04a_osm_locate` and `silver_facilities_04_osm_point`, which the manual job lacks. Defines job parameter `admin_boundaries_run_dir` (default empty). |

## Runs (2026-10-18, UTC)

| Run | Job | Start | End | Result |
|---|---|---|---|---|
| 218424935830057 | 553440510410749 | 11:27:42 | 12:40:07 | SUCCESS. 40 tasks (setup, bronze, silver, silver QC) - the job had 40 tasks at trigger time, before the 26 gold tasks were added. First successful run after the silver task rewire. |
| 513012844601841 | 553440510410749 | 12:44:51 | 15:09:19 | SUCCESS after two repairs (full 66-task run). See timeline below. |
| 23167081408523 | 835555203376044 | 11:50:38 | 14:47:23 | SUCCESS. 72 tasks, including the OSM silver build. |

Run pages (same workspace):

* https://dbc-13a6fb23-1fc8.cloud.databricks.com/?o=7474644595563972#job/553440510410749/run/218424935830057
* https://dbc-13a6fb23-1fc8.cloud.databricks.com/?o=7474644595563972#job/553440510410749/run/513012844601841
* https://dbc-13a6fb23-1fc8.cloud.databricks.com/?o=7474644595563972#job/835555203376044/run/23167081408523

## Timeline of run 513012844601841 (the full 66-task run)

| Attempt | Window (UTC) | Result |
|---|---|---|
| Original attempt | 12:44:51 - 14:14:56 | FAILED at `gold_11_dim_geography`: `[TABLE_OR_VIEW_ALREADY_EXISTS] ... dim_geography__inputs` (SQLSTATE 42P07). The bundle job was executing the same `CREATE OR REPLACE TABLE ...__inputs` scripts concurrently; the two creates raced and the manual job's attempt lost. All downstream gold tasks were skipped. |
| Repair 1 (id 459542098631489) | 14:39:42 - 14:43:27 | FAILED at `gold_20_fact_facility_capacity`: same error class on `fact_facility_capacity__inputs`. The bundle run was still active (it ended 14:47:23), so the same race recurred. |
| Repair 2 (id 1001567219889287) | 14:55:24 - 15:09:19 | SUCCESS. All rerun gold tasks passed, including the final `gold_qc` task (14:55-15:09). |

Setup, bronze, silver, and silver QC tasks had already succeeded in the original attempt and were not rerun by the repairs; only the failed and downstream gold tasks were rerun. Recovery used the run-repair mechanism (rerun of failed tasks) from the run page, not a full re-run.

## Outputs

`quality.build_log` recorded 72 succeeded builds on 2026-10-18 (17 SQL-built silver tables per execution, several tables built more than once across the runs, plus gold builds). The Delta history of `build_log` attributes the writes to both job IDs, confirming both jobs participated.

The gold objects in `public_health.gold` were created by these runs. The 12 managed tables show Delta history with first versions (v0) between 14:11 and 15:09 UTC (for example `dim_geography` 14:11:56, `fact_disease_metric` 14:14:03); the 17 marts and helper views are views, recreated by definition on each run. Current row counts (COUNT(*), inspected 2026-10-18 about 15:20-15:40 UTC):

| Object | Rows |
|---|---|
| `dim_geography` | 1,764 |
| `dim_facility` | 3,957 |
| `dim_disease` | 179 |
| `dim_date` | 783 |
| `dim_data_source` | 25 |
| `fact_facility_capacity` | 30,365 |
| `fact_disease_metric` | 593,171 |
| `fact_workforce_capacity` | 28,071 |
| `fact_area_indicator` | 8,928 |
| `fact_area_access` | 1,642 |
| `source_priority` | 34 |
| `ref_osm_healthsite_point` | 16,030 |
| `area_coverage_map` | 9,909 |
| `huc_province_crosswalk` | 17 |
| `priority_weight_params` | 12 |
| `mart_locality_service_presence` | 1,642 |
| `mart_base_planning_unit` | 109 |
| `mart_area_service_profile` (view) | 109 |
| `mart_area_burden_indicator` | 2,071 |
| `mart_area_evidence` | 2,943 |
| `mart_area_priority` | 12,426 |
| `mart_tb_case_study` | 1,642 |
| `mart_kidney_case_study` | 81 |
| `mart_dengue_peak_capacity` | 981 |
| `mart_evidence_readiness` | 28 |

Key silver counts (current state, same inspection): `geography_silver` 43,762; `population_silver` 127,945; `admin_boundaries_silver` 1,747; `facilities_id_map_silver` 5,257; `facilities_registry_silver` 3,957; `facilities_metric_silver` 2,988; `facilities_bed_occupancy_silver` 9,145; `facilities_osm_point_silver` 16,030; `diseases_metric_silver` 131,887; `socioeconomic_poverty_silver` 322; `workforce_headcount_silver` 28,071.

Caveat on table state: the current tables reflect interleaved writes from BOTH jobs, which executed identical scripts against the same inputs. The counts above are the state observed after the last write (15:09 UTC), not a snapshot attributable to one job.

## Quality and reconciliation outcomes

* `qc_results` on 2026-10-18: 1,443 checks across bronze and silver layers; **0 FAIL; 87 WARN**; no gold-layer rows.
* Recurring WARN groups on 2026-10-18 include: S25 bed occupancy above the baseline maximum (1,779 of 9,036 rows); S29 quarantined rows within limits (for example 1,404 `illness_missing` in hospital claims, 18 `area_unresolved` in diseases metric, 10 `service_of_existing_facility` in registry); S27/S28 OSM placement (35 points placed by city tag only, 2 outside boundaries); S53-S58 population coverage and census consistency; S68-S73 workforce reconciliation (totals vs components, year-on-year jumps); S94-S96 socioeconomic definition caveats (poverty drops above 15 points, child-mortality reference period unconfirmed); S98 stale latest source years (`hdx_dengue` 2021, `psa_deaths_national_annual` 2020); S99 workforce reported population vs census.
* Gold QC: the `gold_qc` task runs 14 checks (G00-G13) validating published gold tables and writing results to `qc_results` (KI11 resolved 2026-10-19).
* Historical QC rows retained in `qc_results`: 2026-10-11 (18 FAIL), 2026-10-12 (15 FAIL), 2026-10-15 (34 FAIL, all S00 "QC ran without error" - the QC scripts themselves errored against not-yet-existing tables or mismatched columns). The 2026-10-18 executions are the first recorded bronze-and-silver QC passes with zero FAIL rows.

## Manual steps, errors, and limitations

1. Two jobs ran the same scripts concurrently. This twice caused `[TABLE_OR_VIEW_ALREADY_EXISTS]` failures in the manual job's gold tasks (14:10 and 14:41) because concurrent `CREATE OR REPLACE TABLE` statements on the same `__inputs` tables race. Neither job coordinates with the other (KI12).
2. The manual job cannot build `facilities_osm_point_silver` (its OSM tasks were excluded because the `geo` environment dependency is unavailable on the job's serverless environment). In this run the bundle job built the table at 13:16 UTC. A from-scratch replay of only the manual job would fail at `gold_43_ref_osm_healthsite_point` unless the OSM silver build runs first (KI13).
3. Silver Python builds (geography, population, admin boundaries) do not write `build_log` rows; only SQL-built silver tables are logged there. Bronze loads are also not logged in `build_log`.
4. The Lakeview dashboard reads `public_health.gold` (63 table references in the dashboard JSON). Dashboard queries run when the dashboard is opened; the job does not refresh the dashboard.
5. No secrets are used in the job configuration; authentication is workspace-internal.

## What this run demonstrates

* The full pipeline (setup, bronze, silver, gold) executes end to end in this workspace from the repository working tree at `docs-re` HEAD `e81328f`, on the configured warehouse and serverless environment, producing all expected non-empty gold objects with the row counts listed above.
* Run repair recovers a partially failed run: only the failed and downstream gold tasks were rerun, and the run reached SUCCESS without rebuilding silver.
* Bronze and silver QC pass with zero FAIL rows in the orchestrated runs.

## What this run does NOT demonstrate

* Identical-input idempotency (rebuild with unchanged inputs producing identical outputs). Not tested; see [idempotency comparison](idempotency/comparison.md) for earlier manual comparisons.
* Incremental bronze loading (unchanged-file skipping) behavior. Not measured in this record.
* A clean single-job replay: the OSM silver table came from the concurrent bundle job, so the manual job alone has not been proven to build everything from scratch.
* Dashboard freshness beyond the fact that its queries run live against `public_health.gold`.
* Independent client handover. No walkthrough with a receiving user has been recorded.
* Full resolution of BQ1. `mart_capacity_gap` is not built; disease burden is not yet joined into the capacity-gap mart. See [business context](../01-context/problem-and-business-context.md).
* Gold-layer data quality at the time of this run (2026-10-18): no gold QC checks existed yet. Gold QC was implemented on 2026-10-19 (14 checks, G00-G13; KI11 resolved) but has not been verified in a repeat of this full pipeline run.

## Correction of earlier records

The previous version of the [evidence README](README.md) stated a `build_log` total of "114 builds, 106 succeeded, 8 failed, 2026-10-13 to 2026-10-15" and dated all silver and gold builds to 2026-10-15. Neither claim is supported by this workspace's records:

* `quality.build_log` was created 2026-10-09 08:05 UTC and contains no rows dated 2026-10-13 to 2026-10-15. Its Delta history shows DELETE operations only on 2026-10-09 and appends only since, so rows from 2026-10-13 to 2026-10-15 cannot have existed and been removed.
* The silver SQL tables and all `public_health.gold` objects have Delta version 0 (creation) on 2026-10-18 (`diseases_metric_silver` 12:03:47, `socioeconomic_poverty_silver` 12:02:05, `workforce_headcount_silver` 12:04:01, `facilities_osm_point_silver` 13:16:12, `dim_geography` 14:11:56, `fact_disease_metric` 14:14:03, and others). The setup script only runs `CREATE SCHEMA IF NOT EXISTS`, so nothing dropped an earlier `public_health.gold`.
* `qc_results` rows dated 2026-10-15 record 34 FAILED S00 checks (QC script errors against missing tables), not a successful full run.

The build-date claims across the documentation have been corrected to 2026-10-18 in this session. The [change log](../08-governance/change-log.md) records the correction. The earlier claims probably reflect the original team workspace's build history; that history is not accessible from this workspace and was not verified here.
