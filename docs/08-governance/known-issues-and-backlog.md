# Known issues and backlog

What is open after the capstone: known issues that affect results or operations today, the engineering limitations of the pipeline, the backlog ordered by priority, and the recommendations that wait for a trigger. Item numbers are the ones used in the team's to-do list and in the other pages (for example "to-do 13").

Status date: 2026-10-20. Decisions: [decision log](decision-log.md). Assumptions: [assumptions](../01-context/assumptions.md). Limits on reading the data and the team's recommendations: [limitations and recommendations](../01-context/limitations-and-recommendations.md).

---

## 1. Known issues and engineering limitations

### 1.1 Known issues

| ID | Issue | Effect | Treatment | Item |
|---|---|---|---|---|
| KI-01 | Rows held for review: 18 FHSIS TB special-area rows, 21 PhilHealth claims location pairs marked REVIEW, 34 Davao city labels, San Jose (Oriental Mindoro); four workforce row overrides still `proposed` (Taguig, San Juan 2022; Surigao del Norte, Alegria 2025) | Those rows are quarantined or kept out of analysis | Deliberate hold: each is counted, has a reason and is under 1% of its source (S29). Deferred to after submission (D-58) | 13 |
| KI-02 | CI checks fail on `dev`; automated tests are thin | A pull request can't rely on CI yet | Fix after submission; add pytest for the bronze loader, `run_bronze.py`, `bronze_gate.py` | 21 |
| KI-03 | `check_registry` not fully seeded (GB, HB, B16, S59, G codes); `strict_registry=False` except population QC | A script could use an unregistered code | Seed, then switch every script to `strict_registry=True` (O-17) | 7 |
| KI-04 | Files without `qc.expected_rows` | B03 is only WARN for them; a wrong file with a plausible count passes | Fill the expected counts | 7b |
| KI-05 | `sharing: restricted` is declared, not enforced by grants | Anyone with workspace access can read restricted silver rows | Restricted rows never leave silver except as suppressed aggregates; apply Unity Catalog grants | 23 |
| KI-06 | HDX boundaries write no `ingestion_metadata` row | The gate can't detect STALE for `hdx_phl_admin` | HB01 / HB02 reconcile counts to the manifest instead | 18c |
| KI-07 | BOR bed basis and reporting period not confirmed by HFSRB | Occupancy definitions are provisional | `bor_basis_confirmed = false`, `period_confirmed = false` (O-12) | 27 |
| KI-08 | `hdx_dengue` (latest 2021) and `psa_deaths_national_annual` (latest 2020) flagged by S98 | One expected WARN on every cross-domain run | Both stopped publishing: add them to `HISTORICAL_SOURCES` with a comment, or keep as an explained WARN | — |
| KI-09 | `quality_migrate_bronze_qc.sql` run not confirmed; the `batch_id` column comment in `quality_setup.sql` predates the contract | Old results may still sit in `bronze.qc_results`; a misleading comment | Confirm, drop the old table, fix the comment | 7a |
| KI-10 | Deploy of the latest job through the Asset Bundle not recorded | The deployed job may differ from the repo | Record it with the evidence runs; optional `dashboard_refresh` task | 10 |
| KI-11 | A teammate workspace's `ingestion_metadata` fix (runbook incident 3) not confirmed as run | Silver builds fail there with `UNRESOLVED_COLUMN` | Run `ingestion_metadata_fix.sql` in that workspace | — |
| KI-12 | eFOI 2026-5476 (bed sheets 2016–2017, named OHSRS 2023 hospitals) received 2026-10-16 but not ingested | Occupancy starts in 2018; no named hospital utilization | Data freeze before submission. Decide whether to land it after submission | 12 |
| KI-13 | DOH OHSRS regional release (annual consolidated, 2016–2025, government / private by region): inpatient average length of stay (ALOS) and outpatient re-visits; received 2026-10-20, not ingested | No length of stay in the pipeline; the dengue peak view compares cases with beds, not bed-days | Data freeze before submission. Region grain only, so it does not join the province / municipality marts. Main use: bed-day demand for stretch 2 | 36 |

### 1.2 Engineering limitations

These limits affect how the pipeline runs, not what the data means.

| ID | Limitation | Current treatment |
|---|---|---|
| EL-01 | Silver observation tables and gold rebuild in full on every run, even when no bronze file changed. Cost grows with total rows, not new rows | Deliberate at current volume (D-57). Every gate checks the whole table, and a rule change reaches every row. Cost steps R0–R5 are in section 3. Full explanation: [silver rebuild strategy](../04-pipeline/silver/rebuild-strategy.md) |
| EL-02 | Silver reads bronze at its current version, not a pinned version | Silver runs right after bronze QC in the same job |
| EL-03 | `check_registry` is not fully seeded. Most QC scripts run with `strict_registry=False` | Seed it at the end of the project (KI-03, O-17) |
| EL-04 | Four domain files hold copies of the bronze loader and QC code | Kept identical by hand. A shared module is item 14 |
| EL-05 | `sharing: restricted` is declared, not enforced by grants | Unity Catalog grants are item 23 (KI-05) |
| EL-06 | The loader does not detect parsing-setting changes in the YAML | Reload with `--force_keys`. Detection is item 17 |
| EL-07 | The team runs on a personal Databricks workspace | The FTW org workspace could not reach the external volume |
| EL-08 | The job has no trigger or active schedule. A person starts each run | Data arrives through people, so whoever lands it starts the job (D-59). Trigger and skip rules are R0 and R1 |
| EL-09 | CI checks on `dev` fail and automated tests are thin | Fix after submission (KI-02, item 21) |

## 2. Backlog

### Tier 1: finish and prove (now)

| # | Item | Layer | Status |
|---|---|---|---|
| 6a | `gold_02_dim_date`: gate accepts `iso_week` and `iso_week_ending_date`; weekly dates from silver; `source_priority` drops the "approximated" reason for UP NOAH | gold | Gold pass, in progress |
| 5 / 6b | Three full job runs on the same inputs as evidence: gate tasks, silver, gold, `gold_qc.py`; every G12 row PASS on runs 2 and 3 | all | After the gold pass |
| — | Gold README and decision log updates for the gold pass | gold, docs | Gold pass |

### Tier 2: close what the capstone left open

| # | Item | Layer | Effort |
|---|---|---|---|
| 13 | Close the review rows (KI-01) | silver | 1 day |
| 7 | Seed `check_registry` with every code; `strict_registry=True` everywhere | quality | 1 day |
| 7a | Confirm the migration; drop `bronze.qc_results`; fix the `batch_id` comment | quality | 0.5 day |
| 7b | `qc.expected_rows` for every file | bronze | 0.5 day |
| 10 | Confirm the bundle deploy; optional `dashboard_refresh` task after `qc_gold` | job | 0.5 day |
| 12 | Decide on eFOI 2026-5476 (KI-12). Decide together with 36 | bronze, silver | 1–2 days |
| 36 | Decide on the OHSRS regional release (KI-13). Profile every tab first. Parse issues seen so far: 3-row header (metric / year / ownership), text `Started 2025` in a numeric cell (NIR 2016), NOTE footer row | bronze, silver | 1 day |
| — | Fix the failing CI checks on `dev` | CI | — |

### Tier 3: structural improvements

| # | Item | Layer | Effort |
|---|---|---|---|
| 14 | One shared bronze loader and one shared bronze QC module with `--domain`; the four domain files become thin wrappers | bronze | 1–2 days |
| 15 | One `silver_tables.yaml` (keys, inputs, lineage rules, volatile columns) driving a shared silver QC | silver | 2 days |
| 16 | Builders: decision tables to reviewed CSV / YAML; one `builder_utils`; CI check that repo and Volume reference copies match | silver | 2 days |
| 17 | Detect YAML parsing-setting and loader changes (hash into `ingestion_metadata`) so they reload without `--force_keys` | bronze | 1 day |
| 18 | Drift checks: schema drift per source; row count and key sums against the previous run | all | 1–2 days |
| 18a | Rerun-equality check in silver QC; quality attribute as a column on `check_registry` | quality | 1 day |
| 18b | Readiness for views: a build row for marts, or materialise the heavy ones | quality, gold | 0.5 day |
| 18c | HDX boundaries write an `ingestion_metadata` row (KI-06) | bronze | 0.5 day |
| 19 | HUC → province crosswalk as a silver table; `broad_unit_key` for HUCs in `dim_geography` | silver, gold | 1 day |
| 20 | PSGC vintage per analysis year; one owner per PSGC source; aligned lineage column names | bronze, silver | 2–3 days |
| 21 | pytest for the bronze loader, `run_bronze.py`, `bronze_gate.py` (KI-02) | CI | 1 day |
| 22 | `header_check` for facilities entries 1–13; clear CONFIRM markers; split `_as_of_date` into release and download dates | bronze | 1 day |
| 23 | Unity Catalog grants on restricted tables (KI-05) | bronze, silver | 0.5 day |
| 24 | Materialise `fact_area_access` and `area_coverage_map` if latency or readiness needs it | gold | 0.5 day |

### Tier 4: data questions (not code)

| # | Question | Blocks |
|---|---|---|
| 26 | Optional: confirm the week convention with DOH, HDX and UP NOAH (applied in code, D-44, D-46) | — |
| 27 | BOR bed basis and reporting period from HFSRB (KI-07) | `bor_basis_confirmed`, `period_confirmed` |
| 29 | Whether the dashboard shows planning units of level `other` (Isabela City, SGA municipalities) (O-16) | `mart_base_planning_unit` consumers |
| 30 | How a second PhilHealth claims release replaces the first (`06` stops on more than one file) | Future FOI releases |

### Stretch (after Tiers 1–2)

| # | Item |
|---|---|
| 31 | Stretch 1: immunization coverage (`fact_service_coverage`, `mart_immunization_coverage`) |
| 32 | Stretch 2: full dengue capacity replay (BQ2). Length of stay for bed-day demand comes from item 36; 2016–2017 occupancy baseline from item 12 |
| 33 | Facility-grain capacity fact |
| 34 | Specialist workforce fact (PSMO) |
| 35 | Spark reads for large bronze files; ADM4 boundaries; WKT / WKB beside GeoJSON |

## 3. Recommendations: cost (waiting for a trigger)

Silver and gold stay full rebuilds and runs stay manual (D-57, D-59). Build these in order when a trigger in the [rebuild strategy](../04-pipeline/silver/rebuild-strategy.md) is met: runs that should start without a person, frequent source updates, or a domain with millions of rows.

| # | Item | Effort |
|---|---|---|
| R0 | Start the job when a batch is ready: trigger on a `_ready/` marker folder or from the ingestion jobs, never the whole landing Volume; serverless standard mode. (Warehouse auto-stop: applied now) | 1–2 hours |
| R1 | Skip silver and gold on automatic runs with no bronze change; a manual run always rebuilds | 0.5–1 day |
| R2 | Per-domain skip | 1 day |
| R3 | Per-source incremental (`replaceWhere`) when a domain reaches millions of rows | 2–3 days |
| R4 | Pin inputs with `VERSION AS OF`; `{{job.run_id}}` as the build id | 1 day |
| R5 | `OPTIMIZE` / Z-order at volume; partition only with R3 | 0.5 day |

## 4. Done in the post-capstone pass

| Date | Item |
|---|---|
| 2026-10-18 | Gold QC script (D-48); gold promoted to `public_health.gold`, files `gold_01`–`gold_24` (D-49) |
| 2026-10-19 | Bronze closed: QC re-queue, preload gate, geography in `run_bronze.py`, overrides validated, timezone-aware UTC (D-50 to D-55) |
| 2026-10-19 | Silver: D-44 / D-46 week convention; population QC fixes and S59; rule 2a in every silver build and QC file; full rebuild kept (D-57); proposal values agreed (D-56) |
| 2026-10-20 | Silver closed: workforce override for Zamboanga Sibugay (D-58); cross-domain QC 68 checks, 0 FAIL, 10 WARN. Runs stay manual (D-59) |

## 5. History of updates

| Date | Change |
|---|---|
| 2026-10-16 | To-do list written for the week after the capstone |
| 2026-10-19 | Updated with the bronze and silver passes; cost recommendations from D-57 |
| 2026-10-20 | Moved to `08-governance/known-issues-and-backlog.md` with a known-issues table; R0 / R1 per D-59; CI on `dev` added |
| 2026-10-20 | Late FOI releases: KI-13 and item 36 added for the OHSRS regional release; KI-12 / item 12 (eFOI 2026-5476) linked to it; stretch 32 notes both as inputs |
| 2026-10-20 | Engineering limitations EL-01 to EL-09 moved here from "Assumptions and limitations" as section 1.2. Links point to the new assumptions page and the limitations and recommendations page |
