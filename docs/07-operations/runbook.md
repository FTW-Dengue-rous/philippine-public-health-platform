# Runbook

Owner: Jemma Santiago
Last updated: 2026-10-18

## Execution order

The pipeline runs as a single Databricks job (`ph_public_health_pipeline`). Tasks execute in dependency order:

1. **Setup** — creates catalog, schemas, quality tables if missing. Idempotent.
2. **Bronze** (parallel per domain) — loaders read landing files, write bronze tables.
3. **Bronze QC** — checks raw data. A FAIL check is blocking: the QC run raises, the task fails, and `quality.run_log` records status ERROR. WARN checks do not block.
4. **Silver** (per domain, depends on bronze QC) — SQL builds clean tables.
5. **Silver QC** — checks silver tables.
6. **Cross-domain silver QC** — checks spanning domains.
7. **Gold** — SQL builds analytical marts.
8. **Gold QC** — placeholder. `src/05_quality/gold/gold_qc.py` contains no checks yet; a green `gold_qc` task does not validate gold output ([known issues](../08-governance/known-issues-and-backlog.md) KI11).

## How to run

### Option A: Full pipeline (recommended)

```bash
# Deploy latest code
databricks bundle deploy -t dev

# Run the pipeline job
databricks jobs run-now --job-name ph-public-health-pipeline
```

**Do not run the two pipeline jobs at the same time.** The manually created pipeline job and the bundle-deployed job execute the same scripts and write the same tables. Concurrent `CREATE OR REPLACE TABLE` statements race and fail with `TABLE_OR_VIEW_ALREADY_EXISTS` (observed twice on 2026-10-18; see the [run record](../06-evidence/2026-10-18-new-workspace-run.md)). Confirm the other job is idle before starting a run.

**The manually created job does not build the OSM silver table.** It has no `silver_facilities_04a_osm_locate` / `silver_facilities_04_osm_point` tasks, but its `gold_43_ref_osm_healthsite_point` task reads `facilities_osm_point_silver`. Build that table first (run the bundle job or the facilities 04 scripts) or the gold run fails at `gold_43` (KI13).

Set the `admin_boundaries_run_dir` parameter to a completed ingestion run folder:

```
/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/admin_boundaries/_runs/<RUN_ID>
```

To identify the correct run:
1. List the `_runs/` folder: `%fs ls /Volumes/workspace/default/ftw-b12-de/groups/g5_landing/admin_boundaries/_runs/`
2. Open each run folder and check the two handoff files. `handoff.json` is written by the ingestion notebook when the ingestion run completes. `bronze_handoff.json` is written by the bronze loader after a successful load of that run; bronze QC reads it.
3. Do not select the newest folder by timestamp alone. A run may have started but failed before producing a handoff.
4. Bronze loads are not recorded in `quality.build_log` (it logs silver and gold builds only, and has no path column). To confirm the bronze load and its QC passed, check the QC run log: `SELECT validation_id, script_name, started_at, status FROM public_health.quality.run_log WHERE script_name LIKE '%admin_boundaries%' ORDER BY started_at DESC LIMIT 5`. Status PASS with `checks_fail = 0` confirms the batch passed.
5. Use the run folder that contains `bronze_handoff.json` and matches the passing QC run.

### Option B: Single domain

Run `run_bronze.py` for bronze, then the silver SQL scripts in order.

```bash
# Bronze only (facilities example)
python src/02_bronze/run_bronze.py --domains facilities --repo_root .

# Silver (in SQL editor or notebook, in order)
-- 1. facilities_silver_00_reference.sql
-- 2. facilities_silver_01_registry.sql
-- 3. facilities_silver_02_metric.sql
-- 4. facilities_silver_03_bed_occupancy.sql
```

### Option C: Preview (no writes)

```bash
python src/02_bronze/run_bronze.py --plan true --domains facilities
```

Prints per-file LOAD/skip and the reason. Writes nothing. No QC.

## Expected outputs

| Layer | Table | Expected rows |
|---|---|---|
| Bronze | `geography_bronze` | 43,762 |
| Silver | `geography_silver` | 43,762 |
| Silver | `facilities_id_map_silver` | 5,257 |
| Silver | `facilities_registry_silver` | 3,957 |
| Silver | `facilities_metric_silver` | 2,988 |
| Silver | `facilities_bed_occupancy_silver` | 9,145 |
| Silver | `facilities_osm_point_silver` | 16,030 |
| Silver | `diseases_metric_silver` | 131,887 |
| Silver | `socioeconomic_poverty_silver` | 322 |
| Silver | `workforce_headcount_silver` | 28,071 |
| Gold v2 | `mart_area_service_profile` | 109 |
| Gold v1 | `gold.mart_area_service_profile` | 2,784 |

## Verification

After a run, verify:

1. **Job status**: The job run succeeded (all tasks green).
2. **Build log**: `SELECT count(*) FROM public_health.quality.build_log WHERE status = 'success'` increased.
3. **Row counts**: Match expected counts above.
4. **QC results**: `SELECT * FROM public_health.quality.qc_results WHERE status = 'FAIL'` returns no rows. A failed check gets `status` = its `severity` (WARN or FAIL); only FAIL blocks.
5. **Dashboard**: Open the Lakeview dashboard and confirm data is present.

## Failure handling

| Symptom | Likely cause | Action |
|---|---|---|
| Bronze task fails | Header mismatch or encoding error | Check the error message. Fix the YAML config or the source file. Re-run. |
| Silver task fails: "missing ingestion_metadata row" | Bronze was not loaded or metadata is stale | Run bronze first. Check `public_health.bronze.ingestion_metadata` for the source. |
| Silver task fails: validation gate | Null keys, duplicate keys, or lineage incomplete | Check the error message for which gate failed. Inspect the candidate table. |
| Gold task fails | Silver tables not built or stale | Run silver first. Check that `mart_area_service_profile` inputs exist. |
| Gold task fails: `TABLE_OR_VIEW_ALREADY_EXISTS` on a `__inputs` table | Another run is executing the same scripts concurrently | Wait for the other pipeline job to finish, then repair the failed run (rerun failed tasks) from the run page in the Jobs UI or with `databricks jobs repair-run <run-id> --rerun-all-failed-tasks`. Verified 2026-10-18: two repairs took run 513012844601841 to SUCCESS without rebuilding silver. |
| Admin boundaries task fails: "not a /Volumes path" | `admin_boundaries_run_dir` parameter is blank | Set it to a completed `_runs/<RUN_ID>` folder. See [How to identify the correct run](#option-a-full-pipeline-recommended) above. |
| numpy/shapely import error | Wrong environment | The `geo` environment is only for facilities 04a. Other tasks use `default`. |

## Recovery

* **Rerun the full pipeline**: Safe. Bronze is incremental (unchanged files skip). Silver and gold use `CREATE OR REPLACE`.
* **Rerun a single silver script**: Safe. Each script is self-contained and records its own build.
* **Repair a partially failed run**: Verified 2026-10-18. Rerunning only the failed and downstream tasks took run 513012844601841 from FAILED to SUCCESS without rebuilding bronze or silver.
* **Force reload bronze**: Use `--force true` or `--force_keys <key>` after a YAML or loader change. Makes silver stale until rebuilt.
* **Roll back silver**: Delta time travel: `SELECT * FROM public_health.silver.<table> VERSION AS OF <n>`. Previous versions are retained.

## Routine tasks

| Task | Frequency | Role | Expected result |
|---|---|---|---|
| Run the pipeline job | After new data lands or on schedule | Data engineer | All tasks succeed, dashboard updated |
| Check QC results | After each run | Data engineer | No FAIL check results (WARN allowed) |
| Ingest PSGC (quarterly) | Quarterly | Data engineer | New PSGC snapshot in landing, then bronze |
| Ingest admin boundaries | When HDX updates | Data engineer | New run folder, set job parameter |
| Review area exceptions | After each silver build | Data engineer | Unmatched names reviewed or mapped |
| Check landing volume for new files | As needed | Data engineer | New files added to correct folders |

## How to confirm the latest run succeeded

1. Open the Databricks Jobs UI and find `ph-public-health-pipeline`.
2. Check the latest run: all tasks should be green.
3. Run: `SELECT max(finished_at), status FROM public_health.quality.build_log GROUP BY status ORDER BY 1 DESC LIMIT 5`
4. Open the dashboard and verify its pages show data. All eight pages are populated. FHSIS primary-care counts (S3), workforce composition (W2), and Level 3 presence (A2) are query-only; see the [dashboard guide](../05-dashboard/dashboard-guide.md).
