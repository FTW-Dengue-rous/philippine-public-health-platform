# Reproducibility: running without Databricks

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

The team builds and runs LUNASaan? on Databricks, but the pipeline depends on a short list of **capabilities**, not on Databricks. This page lists them, gives the Databricks implementation and an open-source one for each, and names the few places in the code that are tied to Databricks. With these capabilities, every layer can be rebuilt from the landing files.

Status date: 2026-10-20. Platform facts live here; layer pages link to this page instead of repeating them.

---

## 1. What the pipeline needs

| Capability | Used by | On Databricks | Open-source way |
|---|---|---|---|
| File storage for landing files | Bronze loaders read `<landing_root>/<domain>/<source>/…`; silver reads `<landing_root>/reference/<domain>/` | Unity Catalog Volume (`/Volumes/...`) | A local folder or an object store (S3, GCS, Azure Blob, MinIO) that Spark can read |
| Spark with Spark SQL (4.0 or later) | Every loader, `.sql` file and QC script | Databricks Runtime, Serverless, Databricks SQL | Apache Spark 4.x |
| Versioned table format | `CREATE OR REPLACE TABLE`, `replaceWhere`, `MERGE INTO`, `DESCRIBE HISTORY`, table versions | Delta Lake | Open-source Delta Lake (`delta-spark` for your Spark version) |
| Catalog with three-part names | `public_health.bronze`, `.silver`, `.gold`, `.quality` | Unity Catalog | Unity Catalog OSS, or two-part names after the edits in section 3 |
| Python | Loaders, reference-map builders, QC scripts, the OSM point-in-polygon step | Serverless Python environments | Python 3.10+ with PySpark |
| Run in order, stop on failure | Bronze → gate → silver → silver QC → gold → gold QC | Databricks Jobs, deployed with Asset Bundles | Any scheduler or script that stops on the first non-zero exit (Airflow, Dagster, cron, a Makefile) |
| Run parameters | `--job_run_id`, `--domains`, `--source_keys`, `--plan`, `--force_keys` | Job task parameters, `{{job.run_id}}` | Command-line arguments (every script accepts them) |
| Lineage and run history | Build inputs, freshness, QC results | `public_health.quality` tables written by the pipeline | The same tables. Unity Catalog's lineage graph is a convenience, not a requirement |
| Dashboard | Reads the gold marts and default views | AI/BI dashboard and Genie | Any BI tool that queries SQL over Spark (Superset, Metabase, Power BI, Tableau) |
| CI | Lint and tests on pull requests | GitHub Actions (sqlfluff, pytest) | Any CI; skip the deploy step |

## 2. Software and libraries

| Item | Version | Why |
|---|---|---|
| Java | 17+ | Required by Spark 4 |
| Apache Spark (`pyspark`) | 4.0+ | SQL engine and Python API. The SQL uses `DECLARE OR REPLACE VARIABLE` / `SET VAR`, which need Spark 4 |
| Delta Lake (`delta-spark`) | The release for your Spark version | Versions, history, `MERGE`, `replaceWhere` |
| `pyyaml` | 6.0.2 on Databricks | Reads `config/sources_<domain>.yaml` |
| `openpyxl` | 3.1.5 on Databricks | Reads Excel landing files |
| `shapely` | below 2.1, with `numpy<2` | Point in polygon (`facilities_silver_04a_osm_locate.py`). Shapely 2.1 needs numpy 2, which broke pandas on the Databricks base image |

The Databricks versions are the pinned serverless environments in the job YAML (`default`, and `geo` for the OSM step). Check each script's `import` lines before a first run.

**Run Spark with ANSI mode on (`spark.sql.ansi.enabled = true`).** It is the default in Databricks SQL and Spark 4. With it on, a `CAST` that can't convert a value stops the query; with it off, the same `CAST` returns NULL silently. Gold relies on the error: a bad value must stop the build, not become a missing value (AD-13).

**Run the driver on UTC, or keep timezone-aware timestamps** (D-54). Load times are compared across tables; a naive timestamp read in another timezone marks fresh sources STALE.

**Spark SQL features the SQL files use.** Porting to another engine (PostgreSQL, DuckDB, Snowflake, BigQuery) means replacing:

- functions: `xxhash64`, `max_by`, `min_by`, `count_if`, `try_cast`, `percentile`, `stack`, `named_struct`, `explode` / `LATERAL VIEW`, `array_contains`, `array_except`, `json_object_keys`, `from_json`, `regexp_extract`, `raise_error`;
- operators and statements: the null-safe `<=>`, `DECLARE OR REPLACE VARIABLE` / `SET VAR`, `CREATE OR REPLACE TEMP VIEW`, `QUALIFY`;
- Delta statements: `MERGE INTO`, `DESCRIBE HISTORY`, `VERSION AS OF`;
- `read_files()` in the silver `00_reference` steps, which is Databricks-only: load the reference CSVs another way with the same schema strings.

Surrogate keys are `xxhash64` values; another hash gives other key values, which is fine when every table is rebuilt in the same run.

## 3. Places tied to Databricks

| Where | What | Change for an open-source rebuild |
|---|---|---|
| `landing_root` in each `config/sources_<domain>.yaml`; `psgc.landing_path` and `hdx_phl_admin.landing_path` in `sources_geography.yaml` | Volume paths (`/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`) | Your landing folder or bucket. Keep the layout below it |
| Reference CSV paths in each silver `*_00_reference.sql` | Volume paths | The same folder under your landing root |
| Table names (`public_health.<layer>.<table>`) in SQL and YAML | Three-part names | Keep a `public_health` catalog, or remove the prefix |
| `qualified_table()` in the PSGC loader and QC, and the HDX loader | Reject non three-part names | Keep the catalog, or relax the check |
| `safe_volume_file` / `safe_handoff_path` in the HDX loader and QC | Accept only `/Volumes/...` | Change for another storage root |
| `dbutils.widgets` | Notebook parameters | Nothing: scripts read command-line arguments first |
| `%pip` lines in file headers | Notebook magics | `pip install` before the run |
| `databricks.yml`, `resources/*.yml` | Jobs and Asset Bundles | Rebuild the same order in your scheduler (section 4) |
| Dashboard | AI/BI and Genie | Point your BI tool at `public_health.gold` marts and `v_*` views |

## 4. Rebuilding from scratch

1. Install Java, Spark, Delta Lake and the libraries; configure the Spark session with the Delta extension and catalog.
2. Create the catalog and the schemas `bronze`, `silver`, `gold`, `quality`.
3. Run the setup scripts in `src/00_setup/` (the setup job runs the same): the schemas, `ingestion_metadata.sql` and `quality_setup.sql`. They only create what is missing.
4. Land the files under `landing_root` with the folder and file names in the YAML entries ([bronze overview](../04-pipeline/bronze/README.md)). Copy the reference CSVs from `config/reference/<domain>/` to `<landing_root>/reference/<domain>/`.
5. **Bronze:** `python src/02_bronze/run_bronze.py`. It runs the six domains (geography first) and their bronze QC, and stops on a FAIL. The PSGC and HDX loaders read API pages already saved in landing; re-pulling them needs network access to the APIs (`src/01_ingestion`).
6. **Gate:** `python src/05_quality/bronze/bronze_gate.py --domains <domain>` before each domain's silver.
7. **Silver:** geography, admin boundaries and population first, each followed by its QC; then for each domain: the `00_reference` step, the build files in number order, the domain QC. Then `silver_cross_domain_qc.py`. Run order per domain: [`src/03_silver/README.md`](../../src/03_silver/README.md).
8. **Gold:** `src/04_gold` in number order (`gold_01` → `gold_24`: `dimension/`, `fact/`, `mart/`), then `gold_qc.py`. Gold has no setup file; step 3 creates the `gold` schema.
9. **Dashboard:** connect your BI tool to the gold marts and default views.

Steps 5–8 are what the Databricks job does: run them as one workflow that stops on the first failure.

## 5. Data that can't be downloaded

- **Restricted sources** came through FOI requests or from a hospital: DOH dengue and TB FOI files, the HFSRB hospital beds and occupancy release, PhilHealth claims, the Davao pneumonia admissions. IHME GBD is treated as restricted under its licence.
- They sit under `<domain>/restricted/` in landing and are never committed (D-47). Request and release documents hold the requester's personal details; keep them out of the repository too.
- **Without them:** set their YAML entries to `enabled: false`. The effects are listed in the [data request log](../02-data/data-request-log.md), section 5.
- **Getting them:** file the same requests through eFOI ([data request log](../02-data/data-request-log.md), section 4).
- **Open sources:** download them from the publisher named in each YAML entry. IHME and OpenStreetMap require attribution on every chart.

## 6. History of updates

| Date | Change |
|---|---|
| 2026-10-18 | Written as `platform-requirements.md` |
| 2026-10-20 | Moved to `07-operations/reproducibility.md`; updated for geography inside `run_bronze.py`, the preload gate, gold `gold_01`–`gold_24`, pinned environments, `read_files()` and timestamps |
