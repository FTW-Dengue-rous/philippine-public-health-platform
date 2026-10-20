# Architecture decisions

The technical choices that shape the pipeline, with the reason and the trade-off for each. Each record links to the full decision log by ID (`D-NN`).

This page is a summary. The full, dated log (business and technical decisions, plus open questions) is the [decision log](../08-governance/decision-log.md). When they disagree, the decision log wins.

Status date: 2026-10-20.

---

## Summary

| ID | Decision | Log IDs |
|---|---|---|
| AD-01 | Medallion lakehouse on Databricks with Delta tables | D-05, D-06 |
| AD-02 | SQL first; Python only where SQL cannot do the job | D-05, D-25 |
| AD-03 | One bronze table per source, text only, frozen schema | D-08, D-09, D-20 |
| AD-04 | Config-driven loading from one YAML file per domain | D-12 |
| AD-05 | Incremental bronze by file checksum | — (2026-10-14) |
| AD-06 | One quality schema; every QC result through `DQRun` | D-14, D-15 |
| AD-07 | Write-audit-publish builds in silver and gold | D-25, D-28 |
| AD-08 | Reduced row-level lineage plus build tables | D-24 |
| AD-09 | Geography is the spine; reference maps are generated | D-16, D-30 |
| AD-10 | Gold star schema: 5 dimensions, 4 facts, marts as views | D-36, D-37, D-38 |
| AD-11 | Selection contracts and default views | D-39 |
| AD-12 | Preload gate and bronze QC re-queue | D-50, D-51, D-52 |
| AD-13 | `CAST` in gold, `try_cast` in silver, ANSI mode on | — (2026-10-18) |
| AD-14 | Restricted data: aggregates only, suppression under 3 | D-47 |
| AD-15 | Silver: full rebuild; cost control by skipping unchanged work, not by per-source incremental (for now); runs stay manual | D-57, D-59 |
| AD-16 | Timezone-aware UTC timestamps | D-54 |
| AD-17 | Manual acquisition for file-based domains; code ingestion for API sources only | D-03, D-59, D-63 |

---

## AD-01 Medallion lakehouse on Databricks with Delta tables

| | |
|---|---|
| **Decision** | Land files in a Volume; build bronze, silver and gold Delta tables in Unity Catalog. Do not use Spark Declarative Pipelines. |
| **Why** | Delta gives table versions, history, `MERGE` and `replaceWhere`. Declarative Pipelines were advised against because of compute cost on the shared workspace. |
| **Trade-off** | The team writes its own orchestration, gates and lineage. In return, every step is plain code that runs outside Databricks too. |

## AD-02 SQL first

| | |
|---|---|
| **Decision** | Silver and gold builds are plain `.sql` files. Python is used for file loading, reference-map builders, geometry (point-in-polygon) and QC scripts. |
| **Why** | The team knows SQL best; reviewers can read it; it ports to other engines. |
| **Trade-off** | Some logic is long in SQL. Large files exceed the lint size limit (diseases silver 01–03). |

## AD-03 One bronze table per source, text only, frozen schema

| | |
|---|---|
| **Decision** | Each source gets its own bronze table with the domain first in the name. Every data column is STRING. Real column names where the header allows. The bronze schema contract is fixed since 2026-10-08: load id and checksum come from `ingestion_metadata`, not new columns. |
| **Why** | A bad source cannot damage another; the raw value is always recoverable; silver decides how to parse. |
| **Trade-off** | Many tables. Silver does all the parsing work. |

## AD-04 Config-driven loading

| | |
|---|---|
| **Decision** | One YAML entry per dataset: location, reading settings, contract checks, target, `sharing`, `qc` block. The four file loaders are the same code. |
| **Why** | Per-dataset scripts did not scale to the number of files. Adding a dataset is one entry. |
| **Trade-off** | Loader and QC code is copied into four files until a shared module exists (backlog). Parsing-setting changes are not detected automatically. |

## AD-05 Incremental bronze by file checksum

| | |
|---|---|
| **Decision** | Each run compares every listed file with its last `processed` row in `ingestion_metadata`. Load only `new`, `content_changed`, `as_of_date_changed`, `bronze_rows_differ` or `forced` files. Replace rows per file with `replaceWhere`. |
| **Why** | Unchanged files keep their rows and load time, so silver built from them stays fresh. Reruns never double rows. |
| **Trade-off** | Needs a checksum per file in the load log; the first run after the change reloaded old files once. |

## AD-06 One quality schema; every result through `DQRun`

| | |
|---|---|
| **Decision** | `public_health.quality` holds `qc_results` (21 agreed columns), `run_log`, `table_stats`, `profile`, `quarantine`, `build_log`, `build_inputs`, `row_disposition` and views. Every QC script writes through `dq_utils.DQRun`. |
| **Why** | One result format across layers and domains. Append-only, so domains can check in parallel. |
| **Trade-off** | `check_registry` is not seeded yet; most scripts run with `strict_registry=False` (O-17). |

## AD-07 Write-audit-publish builds

| | |
|---|---|
| **Decision** | A build writes a candidate, runs its gates, and replaces the published table only when every gate returns 0. A failed build logs `failed` and stops with `raise_error`. |
| **Why** | Consumers never see an unvalidated table. A failure leaves the last good version in place. |
| **Trade-off** | Staging tables per build; a little more compute per build. |

## AD-08 Reduced row-level lineage plus build tables

| | |
|---|---|
| **Decision** | Silver rows carry `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date` (+ `_metric_source_columns` where unpivoted). Load time, load id and checksum live once per build in `build_inputs` and `build_log`. Every bronze row not loaded gets a `row_disposition`. Gold rows carry `_gold_build_id` only. |
| **Why** | Eleven lineage columns per row was too many. Traceability is kept through the build tables. |
| **Trade-off** | Tracing a row needs a join to `build_inputs`. |

## AD-09 Geography spine and generated reference maps

| | |
|---|---|
| **Decision** | `geography_silver` (one PSGC snapshot) is the only table that defines a PSGC code. Each domain maps its labels through reviewed CSVs generated by builder scripts. No build matches by name; unmatched labels are held back with a reason. |
| **Why** | Sources name the same town in many ways. Rules, not hand fixes, keep matching repeatable and reviewable. |
| **Trade-off** | Builders run outside the job; repo and Volume copies of the CSVs are synced by hand (backlog). |

## AD-10 Gold star schema: 5 dimensions, 4 facts

| | |
|---|---|
| **Decision** | Dimensions: geography, date, data source, facility, disease. Facts: facility capacity, disease metric, workforce capacity, area indicator. Breakdowns are columns. New datasets join existing facts (D-38). Marts and default views are views. |
| **Why** | Mentor and reviewers asked for fewer facts; the team target was fewer than 5. Long facts absorb new sources without new tables. |
| **Trade-off** | Facts hold overlapping rows from several sources and levels, so a query must follow the selection contract (AD-11). Views have no build row. |

## AD-11 Selection contracts and default views

| | |
|---|---|
| **Decision** | Each fact has a written rule for what makes a total valid, made executable as a default view (`v_*`). `source_priority` sets the preferred source per metric. Two labelled denominators: census for cross-domain rates, FHSIS-printed for FHSIS facility rates. |
| **Why** | Summing across sources, levels or breakdowns doubles counts silently. |
| **Trade-off** | Analysts must start from the views, not the raw facts. |

## AD-12 Preload gate and bronze QC re-queue

| | |
|---|---|
| **Decision** | `bronze_gate.py` runs per domain before silver and blocks FAIL, CRASHED, STALE and NOT_CHECKED sources. `run_bronze.py` re-runs QC for unchanged sources that are not cleared and reads the result back from `qc_results`. Geography, boundaries and population QC run inside `run_bronze.py`. |
| **Why** | Before, a failed unchanged source stayed failed while the run reported complete, and nothing stopped silver from building on it. |
| **Trade-off** | One more task per domain. HDX boundaries write no load log, so STALE is not detected for them. |

## AD-13 `CAST` in gold, `try_cast` in silver

| | |
|---|---|
| **Decision** | Silver parses text with `try_cast` and records a status per value. Gold only aligns types with `CAST`. Spark runs with `spark.sql.ansi.enabled = true`. |
| **Why** | In silver a bad value must stay visible. In gold a bad value is a bug and must stop the build instead of becoming a silent null. |
| **Trade-off** | ANSI mode is a hard requirement on any platform. |

## AD-14 Restricted data handling

| | |
|---|---|
| **Decision** | FOI releases, the hospital extract and IHME are `sharing: restricted`. Gold publishes them as aggregates only; cells from fewer than 3 records or hospitals are suppressed; restricted tables are never profiled; raw files and request documents never enter the repository. |
| **Why** | Our requests promised academic use and aggregate reporting. |
| **Trade-off** | Some small areas show "suppressed". Unity Catalog grants are not applied yet. |

## AD-15 Silver: full rebuild; cost control by skipping unchanged work

| | |
|---|---|
| **Decision** | Silver observation tables keep the full rebuild (`CREATE OR REPLACE TABLE` from a validated candidate). Per-source incremental rebuild is not planned for now (D-57, replaces the 2026-10-16 plan). When cost matters, cut it in this order: (R1) skip silver and gold when no bronze input changed, with a `force_rebuild` parameter for code or rule changes; (R2) skip per domain; (R3) per-source `replaceWhere` when a domain reaches millions of rows; (R4) pin inputs with `VERSION AS OF`. |
| **Why** | The waste is rebuilding unchanged inputs, not row volume: sources change rarely and bronze already skips unchanged files. At current volume a full rebuild is cheap, every gate sees the whole table, and a rule change (such as D-44) reaches every row at once. |
| **Trade-off** | Every run rebuilds silver and gold even when nothing changed, and one new file rebuilds its whole table. Not claimed as incremental in the presentation. For the capstone, runs stay manual (D-59): the person who lands new data starts the job, so there are no unattended runs to skip. When runs become automatic, R0 triggers on a marker folder (not the whole landing Volume) and R1 skips only automatic runs with no bronze change. Details: [silver rebuild strategy](../04-pipeline/silver/rebuild-strategy.md). |

## AD-16 Timezone-aware UTC

| | |
|---|---|
| **Decision** | All load and QC timestamps are timezone-aware UTC. |
| **Why** | A naive value was read in the driver's timezone and was 8 hours off on a UTC+8 machine, marking fresh sources STALE. |
| **Trade-off** | None on Databricks (UTC drivers); stored values unchanged. |

## AD-17 Manual acquisition for file-based domains

| | |
|---|---|
| **Decision** | Only the two API sources have ingestion code: the PSGC API snapshot and the HDX COD-AB admin boundaries (`src/01_ingestion`, run by hand). Diseases, facilities, workforce and socioeconomic files are downloaded from their publishers, or received as FOI releases, and uploaded to `<landing_root>/<domain>/<source>/` under the file names declared in `config/sources_<domain>.yaml`. Restricted files go to `<domain>/restricted/`. HDX healthsites GeoJSON is converted to CSV with `builders/landing/` before upload. Landed files are never edited; a new release is a new file. |
| **Why** | These sources have no stable API. PSA, DOH and PhilHealth publish workbooks, PDFs and CSVs on portals whose layouts change, and FOI data arrives by release letter with no fixed date (D-03). A scraper per portal would cost more than it saves for releases that change a few times a year, and FOI files cannot be fetched by code at all. |
| **Trade-off** | No unattended refresh: a person must download, upload and then start the job (D-59). A wrong folder or file name is possible. Retrieval is not replayable by code, so the original files on the Volume are the system of record. |
| **Mitigation** | The YAML entry is the landing contract (folder and file per source, AD-04). Bronze detects new or changed files by checksum and never loads a file twice (AD-05). Bronze QC and contract checks reject wrong layouts. The preload gate blocks silver when a source is FAIL, STALE or NOT_CHECKED, so a missing or forgotten upload stops the run instead of silently feeding old data (AD-12). `run_bronze.py --plan true` shows what will load before anything is written. |
| **Later** | A trigger on a `_ready/` marker folder, or from the ingestion jobs, to start the job after an upload (D-59, R0). |

## History of updates

| Date | Change |
|---|---|
| 2026-10-19 | Page written from the decision log D-01 to D-55, the gold README and the layer overviews |
| 2026-10-19 | AD-15 rewritten for D-57: full rebuild kept; per-source incremental moved to recommendations |
| 2026-10-20 | AD-15: runs stay manual; R0 and R1 deferred in a safer form (D-59) |
| 2026-10-20 | AD-17 added: manual acquisition for file-based domains (D-63) |