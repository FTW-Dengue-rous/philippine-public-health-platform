# Runbook

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

How to run the pipeline, how to find out why a run stopped, how to fix it, and how to rerun safely. It also keeps a log of the failures and data incidents we have had: add a row every time a run stops, or when a data gap changes what a mart can show (incident 6).

Status date: 2026-10-21. Started 2026-10-13. First-time setup: [setup guide](setup-guide.md). Symptom-by-symptom fixes: [troubleshooting](troubleshooting.md).

## 0. A routine run

Runs are started by hand (D-59): whoever lands new data starts the job.

1. Land the new files ([setup guide](setup-guide.md), section 3). If a reference decision changed, rerun its builder and copy the CSV to the Volume first ([reference maps](../04-pipeline/silver/reference-maps.md)).
2. Optional: `run_bronze.py --plan true` to see what will load.
3. Run the job (`databricks bundle run ph_public_health_pipeline -t dev`, or **Run now**).
4. After the run: every QC script's last run has no FAIL, new WARNs are explained (queries in section 3 and the [setup guide](setup-guide.md), section 5), and G12 says whether gold changed.
5. Record the run in the [change log](../08-governance/change-log.md); for an evidence run, save the outputs in [`06-evidence/`](../06-evidence/README.md).

A code, YAML or rule change needs a full run too, even with no new data.

## 1. First steps for any failure

1. **Read the message.** It names the table and the gate or check that failed.
2. **Find which layer stopped.** Use the table in section 2.
3. **Look at the evidence before changing anything.** Use the queries in section 3.
4. **Fix the cause at its source** (a reference file, a rule, a setting). Do not edit a silver or gold table by hand, and do not loosen a check just to pass.
5. **Rerun from the layer you fixed, downward.** See section 4.
6. **Add a row to the incident log** (section 6).

## 2. What each failure message means

| Message starts with | Raised by | Meaning | Was anything written? |
|---|---|---|---|
| `<table> was NOT published. gates failed: ...` | A silver or gold build file (SQL) | One or more build gates are not 0 | No. The published table is as it was. A `failed` row is in `quality.build_log`. The staging tables are kept |
| `Reference check failed: ...` | A `*_00_reference.sql` file | A reviewed CSV has a problem | The reference table was replaced, the builds after it did not run |
| `silver QC gate FAILED for ...` | A QC script, through `dq_utils` | At least one check has status FAIL | QC results are saved. No data table is changed. In a job, the next task does not start |
| `gates failed: silver input whose latest QC has a FAIL` | A gold build file | A silver input of this gold table failed its latest QC | No. Fix or rerun the silver QC first |
| `gates failed: input without a succeeded build` | A gold build file | A dimension this fact needs has not been built in this schema | No. Build the dimension first |
| `gates failed: <key> not in dim_<name>` | A gold build file | A fact row points to a key the dimension does not have | No. See the Sulu incident in section 6 |
| `[UNRESOLVED_COLUMN.WITH_SUGGESTION] ... m.source_sheet` (or another `m.` column) | Spark, while reading a silver build file | `bronze.ingestion_metadata` in this workspace has an older schema without the file-load columns the lineage join needs | No. The query fails before any step runs. See incident 3 |

## 3. Where to look

Replace the names in angle brackets.

**A build gate failed (silver or gold).** The staging tables are kept after a failure:

```sql
SELECT * FROM public_health.<schema>.<table>__gates WHERE failures <> 0;
```

**The failed build and its message:**

```sql
SELECT build_id, target_table, status, finished_at, error_message
FROM public_health.quality.build_log
WHERE target_table = 'public_health.<schema>.<table>'
ORDER BY finished_at DESC LIMIT 5;
```

**A key is missing from a dimension.** Example for an area:

```sql
SELECT DISTINCT s.area_key
FROM public_health.silver.<silver_table> AS s
LEFT ANTI JOIN public_health.gold.dim_geography AS g ON g.area_code = s.area_key;
```

**A QC check failed.** The message gives the `validation_id`:

```sql
SELECT table_name, source_key, check_id, check_name, status, observed, expected, detail
FROM public_health.quality.qc_results
WHERE validation_id = '<validation_id>' AND status = 'FAIL';
```

**Rows a silver build did not load, and why:**

```sql
SELECT target_table, source_key, disposition, reason, count(*) AS row_count
FROM public_health.quality.row_disposition
WHERE build_id = '<build_id>'
GROUP BY ALL ORDER BY row_count DESC;
```

**Health of every table (latest QC):**

```sql
SELECT layer, table_name, overall_status, checks_fail, checks_warn, last_checked_at
FROM public_health.quality.v_table_health
ORDER BY overall_status, table_name;
```

**Row counts that changed between the last two builds:**

```sql
WITH b AS (
  SELECT target_table, row_count,
         row_number() OVER (PARTITION BY target_table ORDER BY finished_at DESC) AS rn
  FROM public_health.quality.build_log
  WHERE status = 'succeeded')
SELECT target_table,
       max(CASE WHEN rn = 2 THEN row_count END) AS rows_before,
       max(CASE WHEN rn = 1 THEN row_count END) AS rows_now
FROM b GROUP BY target_table
HAVING NOT (rows_before <=> rows_now);
```

## 4. Safe rerun

| What you rerun | Safe to rerun? | Why | Then rerun |
|---|---|---|---|
| A gold build file | Yes | Full rebuild. A failed gate leaves the published table untouched. Each run gets a new build id | Every gold file that reads it (facts after a dimension) |
| A silver build file (SQL) | Yes | Same write-audit-publish pattern. `facilities_registry_silver` keeps its `facility_key` values from the id map | Its silver QC, then the gold files that read it |
| A `*_00_reference.sql` file | Yes | It replaces the reference table from the CSV and gives it a new table version | **Every** silver build of that domain that reads the table, even if its rows did not change. A skipped build keeps the old version in `build_inputs` and QC S16 fails (incident 5) |
| A QC script | Yes | It appends a new run to `quality.qc_results`. Views read the latest run. `quality.quarantine` is replaced per check, not duplicated | Nothing, unless it was blocking the next layer |
| `geography_silver.py`, `admin_boundaries_silver.py`, `psgc_population_silver.py` | Yes | MERGE on a key (geography, boundaries); population replaces its snapshot. A rerun on unchanged bronze writes no business change | Their QC; the domain reference builders if the PSGC snapshot changed; every silver build; gold |
| A bronze loader or `run_bronze.py` | Yes (loaders `2026-10-19.1`) | Only new or changed files load; unchanged files keep their load ids. A source whose QC is not cleared is re-queued. `--force` / `--force_keys` reload in full and make that source's silver stale | Bronze QC (run_bronze.py does this), the gate, then the silver builds of a domain whose bronze changed, silver QC, gold |

Rules:

- **Rerun downward, never upward.** After fixing layer N, rerun N and everything after it that reads the fixed table.
- **Dimensions before facts.** In gold, run the files in number order.
- **Nothing in `quality.build_log` or `quality.build_inputs` is ever deleted.** A rerun adds rows. The latest succeeded build is the one that counts.
- **Never fix a failure by hand-editing a table.** The next rebuild would undo it, and the lineage would be wrong.
- **Never raise a threshold without writing the reason next to it.**

## 5. Run order

The job runs, in order ([architecture overview](../03-architecture/architecture-overview.md), section 6):

1. `setup` (the setup job: schemas, `ingestion_metadata`, quality tables; create-only).
2. `bronze_<domain>` × 6: `run_bronze.py --domains <domain>` (load + bronze QC + re-queue). Geography also runs the population payload QC.
3. `gate_<domain>` × 6: `bronze_gate.py`.
4. Silver: geography, admin boundaries and population first, each with its QC; then facilities, diseases, workforce, socioeconomic: `00_reference` → builds in number order → domain QC. Diseases `06` waits for the facilities registry QC. Per-domain order: [`src/03_silver/README.md`](../../src/03_silver/README.md).
5. `qc_silver_cross_domain`, after every silver QC task.
6. Gold `gold_01` → `gold_24` (`dimension/`, `fact/`, `mart/`), then `qc_gold`.
7. `qc_registry` (`quality_registry_check.sql`): every check code recorded in the run is in `check_registry` with the right layer. It writes nothing; a failure here loses no data.

By hand, run the same files in the same order. In a workspace whose `bronze.ingestion_metadata` predates the file-load columns, run `ingestion_metadata_fix.sql` (run in the workspace; not kept in the repo) Part 1 first (incident 3).

## 6. Incident log

| # | Date | Where it stopped | Message | Cause | Fix | Prevention | Status |
|---|---|---|---|---|---|---|---|
| 1 | 2026-10-13 | `gold_37_fact_poverty.sql` | `fact_poverty was NOT published. gates failed: area_key not in dim_geography = 1` | Sulu. The poverty area map was drafted from the PSGC file of 13 Jul 2026, where Sulu is `0906600000` (Region IX). `geography_silver` holds the Q2 2024 snapshot, where Sulu is `1906600000` (BARMM) | Regenerate `socioeconomic_poverty_area_map.csv` with `build_socioeconomic_poverty_area_map.py`, which now aligns every code to the latest `geography_silver` snapshot (Sulu becomes `psgc:1906600000`). Do not edit the CSV by hand. Rerun socioeconomic `00_reference`, `01_poverty`, `socioeconomic_silver_qc.py`, then `gold_37` | (a) New check in `socioeconomic_silver_00_reference.sql`: every code must be in the latest geography snapshot at its level. (b) Generator rule `align_to_snapshot` in `build_socioeconomic_poverty_area_map.py` | Fixed 2026-10-13: CSV replaced, socioeconomic silver rerun, `gold_37` published (reported by Jemma). Open: the new `00_reference` check is not applied yet |
| 2 | 2026-10-13 | `silver_cross_domain_qc.py` | `silver QC gate FAILED for facilities_osm_point_silver: ... S29 quarantined rows within the limit` | Not a defect. 2,662 of 16,032 OSM rows (16.6%) are quarantined by the build, above the default 5% limit. Reasons: `no_coordinates_no_city` 2,579, `place_reviewed_unresolvable` 78, `ambiguous_city_label` 3, `coordinates_outside_boundaries` 2 | Set a limit for this source in `QUARANTINE_FAIL_PCT_BY_SOURCE`: `("facilities_osm_point_silver", "hdx_healthsites"): 20.0`, with the reason as a comment. Rerun the script | If the share rises well above 17%, do not raise the limit. Find out what changed | **Cause removed 2026-10-14.** The new Healthsites file (`..._asof_20261014.csv`, coordinates filled from the GeoJSON) gives every row coordinates. `04a` on Databricks: 16,032 rows, all with coordinates, 16,021 inside an outline, 8 by nearest boundary, 3 not placed by coordinates. `04` on Databricks: 16,030 published, 2 quarantined (0.01%, was 16.6%). 20% entry removed from `QUARANTINE_FAIL_PCT_BY_SOURCE` (default 5% applies). **Closed 2026-10-14:** `silver_cross_domain_qc.py` on Databricks: 68 checks, 0 FAIL, 11 WARN; S29 `facilities_osm_point_silver` / `hdx_healthsites` WARN, 2 of 16,032 (`coordinates_outside_boundaries`), under the 10-row floor |
| 3 | 2026-10-13 | `diseases_silver_01_metric.sql` (line 30), `diseases_silver_02_deaths_age.sql` (line 29), `diseases_silver_03_hospital_encounters.sql` (line 30), in a teammate's workspace (reported by Shiena) | `[UNRESOLVED_COLUMN.WITH_SUGGESTION] A column, variable, or function parameter with name m.source_sheet cannot be resolved. Did you mean one of the following? [f._source_sheet, m.source_name, f._source_file, f._source_key, m.source_version]. SQLSTATE: 42703` | `m` is `public_health.bronze.ingestion_metadata`. In that workspace the table has the team columns only (`source_name`, `source_version`, ...) and not the file-load columns (`source_sheet`, and possibly `content_checksum`) that the silver lineage join reads (`m.source_sheet <=> f._source_sheet`). The silver SQL is correct; the workspace's bronze metadata is behind | Run `ingestion_metadata_fix.sql`: Part 1 adds only the missing columns (checks `information_schema` first, safe to rerun); then rerun `diseases_bronze.py` (revised) so new metadata rows carry `source_sheet` and `content_checksum`; Part 2 checks for Excel files without a sheet name and duplicate metadata rows, and stops with `raise_error` if any. Then rerun diseases silver 01 → 02 → 03 unchanged. Adding the columns alone is not enough: old rows keep `source_sheet` NULL and sheet files get 0 matches | (a) Run `ingestion_metadata_fix.sql` Part 1 once in every workspace before any silver build, together with `quality_setup.sql`. (b) Do not remove the `source_sheet` condition from the join to get past the error, even locally: multi-sheet files then match more than one metadata row, `load_batch_id` and `content_checksum` become NULL and the `metadata_matches` gate fails or lineage is wrong | Open: fix sent to the team 2026-10-13, not yet confirmed as run |
| 4 | 2026-10-13 | `facilities_silver_00_reference.sql` (reference checks) | `[USER_RAISED_EXCEPTION] Reference check failed: area exceptions: proposed_area_name differs from geography silver (regenerate the file) = 2 SQLSTATE: P0001` | Two names: Sergio Osmeña Sr. (`0907214000`) and Science City of Muñoz (`0304917000`). `geography_silver` stored them with a damaged ñ (`Ã±`, UTF-8 read as Latin-1). `build_facilities_area_exceptions.py` repairs the ñ before writing `proposed_area_name`; the check compared against the unrepaired name | The check now applies the same repair before comparing: `e.proposed_area_name IS DISTINCT FROM replace(replace(g.area_name, 'Ã±', 'ñ'), 'Ã‘', 'Ñ')`. Rerun `00_reference` with the 2026-10-14 file (an old copy in a query tab still fails) | (a) One normalisation rule shared by a builder and the check that verifies it. (b) The ñ belongs fixed at the source, in `geography_silver` | **Fixed 2026-10-14.** Builder rerun on Databricks reported `damaged names repaired here: 0`, so `geography_silver` has also been repaired at the source; the `replace()` in the check is now a no-op |
| 5 | 2026-10-14 | `facilities_silver_qc.py` | `FAIL S16 silver built from the current bronze loads and reference versions [input_table_version] \| fail=1/None \| public_health.silver.facilities_area_exceptions 0 -> 3` on `facilities_metric_silver` | Not a data defect. The exceptions CSV was regenerated and `00_reference` reloaded it (table version 0 → 3). `01`, `03`, `04a` and `04` were rerun; `02_metric` was not, so its `build_inputs` still named version 0 | Rerun `facilities_silver_02_metric.sql` (no code change), then `facilities_silver_qc.py` | After `build_facilities_area_exceptions.py` or `00_reference`, run `01` to `04` in full before QC (run order in [silver facilities](../04-pipeline/silver/facilities.md)) | **Fixed 2026-10-14.** `02` rerun: 2,988 rows, same as before. QC: 136 checks, 0 FAIL, 9 WARN (all known) |
| 6 | 2026-10-14 | `gold_v2_52_mart_base_planning_unit.sql`, now `gold_15` (no stop; found in the summary query: `province` units_without_population = 1) | None. `mart_base_planning_unit.population` is null for one province unit | Sulu. All 19 municipalities have census counts for 2015 and 2020 only. `population_silver` holds no 2024 row for any Sulu area (860 rows, all `1906…`, all VALID, all from the `Q2_2024` file), while every other 2024 row joins to `geography_silver` (43,331 rows, 0 orphans). The source file carries no 2024 count for Sulu; it is not a code mismatch on our side. The mart rule then sets the unit population to null because its localities are not all on the latest census year | None in code. Accepted gap: Sulu keeps `population = null` in `mart_base_planning_unit` and `mart_area_service_profile` (its `beds_per_10k`, workforce and BHW rates are null). The 2020 counts stay visible per locality in `mart_locality_service_presence`. Reason: a 2020 denominator must not sit beside 2024 ones in a ranking, and the 2-year alignment window would null the rates anyway (registry 2026, workforce 2025) | (a) Findings and the data dictionary name Sulu as a known gap for every per-population indicator. (b) If PSA publishes the 2024 Sulu count, add it as a population source (not a hand edit) and rebuild `population_silver` → `gold_v2_40` → marts; nothing in the marts changes. (c) Check `localities_without_population` in the 52 summary after every population rebuild | **Accepted 2026-10-14.** Evidence: `SELECT population_year, source_version, count(*), count_if(g.psgc_code IS NULL) FROM population_silver p LEFT JOIN geography_silver g ...` → 2015 42,307 / 2020 42,307 / 2024 43,331, 0 not in geography; Sulu rows by code `1906…`: 2015 and 2020 only |
| 7 | 2026-10-20 | No stop. Found by comparing row counts after the rule 2a rebuild: `workforce_headcount_silver` 28,080 → 28,071, `workforce_area_denominator_silver` 3,024 → 3,023 | None (S29 WARN: `psgc_code_not_in_geography 1` of 4,999 and of 3,627) | FHSIS 2025 workbook, sheet *Health Workers*, row 1243, Zamboanga Sibugay, prints code `0908001000`, which is not a PSGC code. Because 2025 rows are resolved by their printed code first, the row was quarantined as `code_not_in_geography` (9 professions in headcount, 1 denominator row). Not caused by the revision: the resolution rule was the same before | Row override to `psgc:0908300000`, status `accepted`, in `OVERRIDES` of `build_workforce_area_exceptions.py` (D-58). Reran the builder, copied the CSV, ran workforce `00` → `03`, `workforce_silver_qc.py`, `silver_cross_domain_qc.py` | The builder's 2025 check lists printed codes that are another area in geography, but not codes missing from geography: those surface only as S29 / S73 WARNs. Compare row counts between builds after every rebuild (query in section 3) | **Fixed 2026-10-20.** Headcount 28,080, denominator 3,024; workforce S29 back to 8 (`area_label_missing`); cross-domain 68 checks, 0 FAIL, 10 WARN |
| 8 | 2026-10-21 | `psgc_population_bronze_qc.py`, first run in a new workspace | `invalid qc block in the YAML: skip_checks ['B02','B03','B06','B08','B09','B11','B12','B14']` (B00) | `config/sources_population.yaml` listed `skip_checks` for file and sheet checks that this script does not have. Since D-53 the script rejects override codes it doesn't know. The prepared workspace never hit it because its population bronze QC had already passed and was not re-queued | Removed `skip_checks` from the YAML (comment left in its place), redeployed, repaired the run. It then finished green: run `908246813677292`, [new-workspace run](../06-evidence/2026-10-21-empty-workspace-run/README.md) | When a QC script's check list changes, check every `qc:` block that names its codes. Override validation only runs when the QC script runs, so a skipped source can hide a bad override | **Closed 2026-10-21** |

### Notes from incident 1

- Gold worked as designed: it refused to publish a fact with an area the dimension does not have.
- Silver should have caught it first. Its check only looked at the map file, not at `geography_silver`.
- Do not add the missing code to `dim_geography` to make the gate pass. `geography_silver` is the only source of PSGC codes.
- Sulu's region differs by source. PSA poverty (and the 2024 census region totals) count Sulu in Region IX. `dim_geography` rolls it up to BARMM. Do not rebuild Region IX or BARMM totals from provinces for 2024 and 2025.

### Notes from incident 2

- The rows are quarantined in silver, which is correct. S29 does not find bad rows. It asks whether the share quarantined is acceptable.
- No gold table reads `facilities_osm_point_silver`, so the gate inside the gold files is not affected. The job stops only because the QC task fails.
- First cross-domain run with the default limit (2026-10-14): every S29 row is PASS or WARN. The largest share is diseases hospital claims, 1,404 of 245,405 (0.6%, `illness_missing`).

### Notes from incident 3

- The same lineage join (`ingestion_metadata` matched on source name, file path, sheet and load time) is used by every silver build, so facilities, workforce and socioeconomic silver will fail the same way in a workspace that has not been fixed.
- The `diseases_bronze.py` rerun is Python, so it cannot be inside the SQL fix file. Part 1 and Part 2 of `ingestion_metadata_fix.sql` are split around it.
- Part 1 uses SQL scripting (`BEGIN ... FOR ... END`): serverless, a SQL warehouse or DBR 16.3+. On older compute, run plain `ALTER TABLE ... ADD COLUMNS` for each missing column instead.
- If `DESCRIBE` shows the old diseases loader schema (`run_id`, `source_key`, `ingested_at`) instead of the team columns, use the `ingestion_metadata.sql` migration, not this fix.
- Changing the code locally with Genie to get past the error and not committing it still gives results that do not follow the lineage contract. Those results should not feed QC or gold.

### Notes from incident 4

- The check was right to stop: a reference file whose names disagree with geography usually means the file was built from another snapshot. Here both sides had the same code; only the text encoding differed.
- Run the file from the repo, not from a saved query tab. The query tab `New Query 2026-10-13` still held the old check on 2026-10-14.

### Notes from incident 5

- S16 compares the table versions a build recorded with the current versions. A newer version fails even when the rows are identical, because the check cannot know that.
- Here the rebuild gave the same 2,988 rows: the FHSIS exception rows did not change. Rerun anyway; do not wave the FAIL through.

### Notes from incident 6

- Not a pipeline failure: the mart did what the rule says. It is logged because a null unit population changes what the dashboard can show for Sulu.
- Sulu differs by source in three ways now: region (PSA poverty and the 2024 census totals put it in Region IX, `dim_geography` in BARMM — incident 1), poverty map codes (incident 1), and no 2024 census count (this incident). Keep one findings note that covers all three.
- Do not fall back to 2020 for one unit. The quintiles in `mart_area_service_profile` rank units against each other, so every denominator must be the same census year.

## 7. Template for a new incident

| Field | Write |
|---|---|
| Date and who | |
| Where it stopped | File or task |
| Message | Copy it exactly |
| Evidence | The query you ran and what it returned |
| Cause | One or two sentences |
| Fix | What changed, in which file |
| Reran | Which files, in which order |
| Prevention | The check or rule that stops it next time |
| Status | Open, fixed, or accepted with a reason |

## 8. History of updates

| Date | Change |
|---|---|
| 2026-10-13 – 10-14 | Started; incidents 1–6 |
| 2026-10-20 | Moved to `07-operations/runbook.md`. Routine run (section 0), current run order (gold `public_health.gold`, `gold_01`–`gold_24`, preload gate), geography scripts in the rerun table, row-count query, incident 7 |
| 2026-10-21 | Run order: `qc_registry` task after `qc_gold` |
| 2026-10-21 | Incident 8: `skip_checks` in `sources_population.yaml` failed B00 in a new workspace |
