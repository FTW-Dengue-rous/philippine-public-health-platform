# Architecture overview

Owner: Jemma Santiago
Last updated: 2026-10-18

## Tech stack

| Component | Technology |
|---|---|
| Compute | Databricks serverless Spark (Python tasks) + serverless SQL warehouse |
| Storage | Delta Lake on Unity Catalog (`public_health` catalog) |
| Orchestration | Databricks Jobs via Declarative Automation Bundles (databricks.yml) |
| CI/CD | GitHub Actions (lint, test, SQL lint, secret scan, bundle deploy) |
| Version control | Git (GitHub, dev → main branching) |
| Dashboard | Databricks Lakeview |
| Landing volume | Unity Catalog volume (`/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`) |

## Catalog and schema layout

```
public_health (catalog)
  ├── bronze    raw tables from landing files (all STRING columns + lineage)
  ├── silver    cleaned, typed, matched, lineage-tracked tables
  ├── gold      analytical marts and dimensions for dashboard
  └── quality   build_log, build_inputs, row_disposition, qc_results, views
```

Created by `src/00_setup/schema_setup.sql`. Quality tables created by `src/00_setup/quality_setup.sql`.

The gold layer uses data model v2, which builds into schema `public_health.test_gold2` (to be promoted to `public_health.gold`). The job deploys v2 scripts from `src/04_gold/test_v2/`. All 25 gold v2 build scripts ran successfully on 2026-10-18 in the current workspace (see the [2026-10-18 run record](../06-evidence/2026-10-18-new-workspace-run.md)). See [gold layer](../04-pipeline/gold/README.md) for the full data model and [evidence](../06-evidence/README.md) for verified row counts.

## Data flow

```
┌─────────────────────────────────────────────────────────────────┐
│  Sources                                                        │
│  DOH (NHFR, HFSRB, FHSIS, FOI)                                   │
│  PSA (PSGC, poverty, hospitals, beds, BHS, expenditure)        │
│  HDX (admin boundaries, healthsites, dengue)                   │
│  UP NOAH (dengue weekly)                                         │
│  IHME, GLOBOCAN, PSMO                                          │
└───────────────────────────┬─────────────────────────────────────┘
                              │
                    Landing volume (UC volume)
                    /Volumes/.../g5_landing/
                              │
              ┌───────────────┴───────────────┐
              │                               │
    src/01_ingestion/              src/02_bronze/                  
    (PSGC API, admin               (config-driven loaders,       
     boundaries notebook)           one per domain)                
              │                               │                    
              └───────────────┬───────────────┘                    
                              │                                    
                              ▼                                    
                 public_health.bronze.*                              
                 (all STRING + lineage columns)                    
                              │                                    
                              ▼                                    
                 src/05_quality/bronze/                             
                 (bronze QC — stops on ERROR)                      
                              │                                    
                              ▼                                    
                 src/03_silver/ (SQL builds per domain)            
                 → public_health.silver.*                          
                              │                                    
                              ▼                                    
                 src/05_quality/silver/                            
                 (silver QC + cross-domain QC)                     
                              │                                    
                              ▼                                    
                 src/04_gold/ (SQL mart builds)                    
                 → public_health.gold.*                            
                              │                                    
                              ▼                                    
                 src/05_quality/gold/ (gold QC)                    
                              │                                    
                              ▼                                    
                 Dashboard (Lakeview)                               
```

## Orchestration

The pipeline runs as a Databricks Job (`ph_public_health_pipeline`) defined in `resources/ph_public_health_job.yml` and deployed via DABs (`databricks.yml`).

Execution order:

1. **Setup** (Run Job task, idempotent) — creates catalog/schemas/quality tables if missing.
2. **Bronze** (parallel per domain) — loaders read landing files, write bronze tables. Geography and admin boundaries have their own loader tasks; diseases/facilities/socioeconomic/workforce use `run_bronze.py`.
3. **Bronze QC** — geography, admin boundaries, and population run separate QC tasks. Other domains run QC inside `run_bronze.py`. A QC FAIL fails the task and stops downstream.
4. **Silver** (per domain, depends on bronze QC) — SQL scripts build silver tables. Each script captures inputs, validates, writes, and records the build in `build_log` and `build_inputs`.
5. **Silver QC** — per-domain QC scripts check silver tables.
6. **Cross-domain silver QC** — checks that span domains (e.g. geography joins).
7. **Gold** — SQL scripts build analytical marts.
8. **Gold QC** — placeholder task; no checks implemented yet ([known issues](../08-governance/known-issues-and-backlog.md) KI11).

Dependency rule: a task waits for the tables it reads AND the QC of those tables. A failing QC (dq_utils raises on ERROR) stops everything downstream.

## Two serverless environments

| Environment | Used by | Dependencies |
|---|---|---|
| `default` | All Python and SQL tasks | pyyaml, openpyxl (numpy 1.26 base) |
| `geo` | facilities 04a (point-in-polygon) | numpy<2, shapely<2.1, pyyaml, openpyxl |

The `geo` environment pins shapely below 2.1 because shapely 2.1 wheels require numpy 2, which breaks pandas imports in other tasks. All dependencies are pinned so a run resolves to the same versions every time.

## Quality checkpoints

Quality is enforced at three layers:

1. **Bronze QC** — checks raw data before silver can read it. ERROR severity stops the pipeline.
2. **Silver QC** — checks cleaned data after each silver build. ERROR severity stops the pipeline.
3. **Gold QC** — designed but not implemented: `gold_qc.py` is a placeholder ([known issues](../08-governance/known-issues-and-backlog.md) KI11); gold output is not automatically validated before dashboard consumption.

Quality results are written to `public_health.quality.qc_results` via `dq_utils.DQRun`. Build lineage is recorded in `build_log`, `build_inputs`, and `row_disposition`. See the [lineage and quality contract](../lineage-qc-contract_v1.3.md) for the shared rules.

## CI/CD

CI runs on every push and PR to `dev`/`main`: Python lint (ruff), unit tests (pytest), SQL lint (sqlfluff), secret scan (gitleaks), repo hygiene (large file and notebook output checks).

CD deploys the Databricks bundle after CI passes: `dev` branch → dev target, `main` → prod target. The prod target requires a manual approval gate (GitHub Environment reviewer).

See [CI/CD and testing](../07-operations/ci-cd-and-testing.md) for the full pipeline.
