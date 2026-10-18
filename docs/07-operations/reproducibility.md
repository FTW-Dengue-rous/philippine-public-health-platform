# Reproducibility

Owner: Jemma Santiago
Last updated: 2026-10-18

## What it means

A build is reproducible if the same source files and code produce the same output tables. The platform supports this through:
* Incremental bronze (unchanged files keep the same load IDs).
* Silver `VERSION AS OF` reads (time-travel to the exact bronze version a build consumed).
* Build IDs in `build_log` and `build_inputs` that record which inputs were used.
* `CREATE OR REPLACE` for silver and gold (deterministic output from the same input).

## How to reproduce a build

1. **Identify the build**: Find the build ID in `build_log`.

```sql
SELECT build_id, target_table, started_at, finished_at, status
FROM public_health.quality.build_log
WHERE target_table = 'public_health.silver.facilities_registry_silver'
ORDER BY started_at DESC LIMIT 5;
```

2. **Find the inputs**: Look up what bronze versions were consumed.

```sql
SELECT * FROM public_health.quality.build_inputs
WHERE build_id = '<build_id>'
ORDER BY source_key, source_file;
```

3. **Read the bronze at that version**: Use `VERSION AS OF` with the `ingested_at` timestamp.

```sql
SELECT * FROM public_health.bronze.facilities_doh_nhfr_hospitals_bronze
VERSION AS OF TIMESTAMP '<ingested_at>';
```

4. **Re-run the silver script**: Execute the same SQL script with the same bronze inputs. The output should match.

## Versioning

| Component | Version source | How to check |
|---|---|---|
| Code | Git commit | `git log --oneline -1` |
| Source files | Landing volume + `as_of_date` in YAML | File path in `build_inputs.source_file` |
| Bronze | Delta version (time-travel) | `DESCRIBE HISTORY public_health.bronze.<table>` |
| Silver | Delta version + build ID | `DESCRIBE HISTORY public_health.silver.<table>` |
| PSGC | Q2 2024 | `config/sources_geography.yaml` → `version: Q2_2024` |
| Dependencies | Pinned in `requirements.txt` and `requirements-dev.txt` | `pip freeze` |
| DABs environments | Pinned in `resources/ph_public_health_job.yml` | Check `dependencies:` under each `environment_key` |

## Expected row counts (latest verified build)

| Table | Rows | Build date |
|---|---|---|
| `geography_silver` | 43,762 | 2026-10-09 |
| `population_silver` | 127,945 | 2026-10-09 |
| `facilities_id_map_silver` | 5,257 | 2026-10-15 |
| `facilities_registry_silver` | 3,957 | 2026-10-15 |
| `facilities_metric_silver` | 2,988 | 2026-10-15 |
| `facilities_bed_occupancy_silver` | 9,145 | 2026-10-15 |
| `facilities_osm_point_silver` | 16,030 | 2026-10-15 |
| `diseases_metric_silver` | 131,887 | 2026-10-15 |
| `socioeconomic_poverty_silver` | 322 | 2026-10-15 |
| `workforce_headcount_silver` | 28,071 | 2026-10-15 |
| `test_gold2.mart_area_service_profile` | 109 | 2026-10-15 |
| `test_gold2.fact_disease_metric` | 593,171 | 2026-10-15 |
| `test_gold2.fact_facility_capacity` | 30,365 | 2026-10-15 |
| `test_gold2.fact_workforce_capacity` | 28,071 | 2026-10-15 |
| `test_gold2.fact_area_indicator` | 8,928 | 2026-10-15 |
| `gold.mart_area_service_profile` (v1) | 2,701 | 2026-10-13 |

These counts are from the latest successful Databricks builds, verified by COUNT(*) queries on 2026-10-18. They should match on rebuild with the same inputs. If they differ, check for changed source files or YAML config.

## Without restricted data

Restricted FOI data (bed occupancy, hospital beds) cannot be redistributed. To reproduce without it:
* The bed occupancy silver table (`facilities_bed_occupancy_silver`) will not build. S2 dashboard pages will be empty.
* The dengue FOI source (`doh_foi_dengue`) will not load. Disease metrics from FOI will be absent.
* All other domains (geography, facilities registry, metrics, workforce, socioeconomic) build from open data and are fully reproducible.

## Local vs Databricks

* **Local checks** (pre-commit, pytest) validate code style and project structure. They do NOT validate pipeline behavior.
* **Databricks runs** are the real validation. A successful job run with expected row counts and no ERROR QC failures is the proof.
* Local Spark tests (e.g. Jemma's local tests on Spark 4.0) validated SQL logic but could not test Delta-specific features (time travel, `read_files()`). These were confirmed on Databricks.
