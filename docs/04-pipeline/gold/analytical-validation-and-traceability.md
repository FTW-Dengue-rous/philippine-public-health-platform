# Gold — analytical validation and traceability

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

This page shows how gold proves its numbers. It covers:

- the gates inside every build;
- the gold QC that runs after publishing (G00–G13);
- the checks that prove a rerun gives the same result;
- how to trace a dashboard number back to its source cell.

Status date: 2026-10-20. Back to the [gold overview](README.md). Every check code across layers: [quality check catalog](../quality/quality-check-catalog.md). Results of the recorded runs: [quality results and evidence](../quality/quality-results.md).

---

## 1. Summary

Checks run at four points:

| # | When | What | Where | On failure |
|---|---|---|---|---|
| 1 | **Before the build** | Every silver input has a succeeded build, and its latest silver QC has no FAIL | Step [1] and the first gates of every table file | The build stops. The published table stays as it was. `build_log` gets a `failed` row |
| 2 | **Before publishing** | Build gates on the candidate: keys, grain, foreign keys, control totals, business rules | `__gates` in every table file | Same |
| 3 | **After publishing** | Gold QC on the published objects | `gold_qc.py` (G00–G13); `qc_registry` runs after it and is the last job task | A FAIL makes the task fail; the dashboard refresh does not start |
| 4 | **On demand** | Check queries at the end of seed and mart files; evidence queries | End of gold 10, 11, 19, 22, 23, 24; `gold_o13_evidence.sql` (run in the workspace; not kept in the repo) | A person reads them |

**Why both gates and QC.** A gate stops a bad candidate before anyone sees it. QC checks what gold actually published. It stores the result for reviewers and the dashboard. QC also checks three things a gate cannot:

- Nothing wrote the table after the build.
- The inputs did not move since.
- A rerun gives the same content.

## 2. Inputs: gold's own preload gate

Step [1] of every table file lists each input with the version its latest succeeded build wrote (`quality.v_latest_build`) and the status of its latest silver QC (`quality.v_table_health`). Three gates read that list:

| Gate | Fails when | Setting |
|---|---|---|
| `input without a succeeded build` | A gold input has no succeeded build; or (strict mode) a silver input has none | `strict_input_builds` (false: notebook-built silver tables have no build row) |
| `silver input whose latest QC has a FAIL` | Any silver input's latest QC run has a FAIL | `block_on_silver_qc_fail` (true) |
| `candidate has no rows` | The candidate is empty | — |

A silver input with **no** QC run does not stop the build. It sets the build's `approval` to **provisional** in `build_log.parameters`. `mart_evidence_readiness` shows that flag.

## 3. Build gates per file

Every gate returns a count of failing rows. Every count must be 0. A table fails its gate when any listed item is true.

Every table runs these common gates:

- the candidate has rows;
- every input has a build;
- no silver input has a FAIL;
- the primary key and required key columns are not null;
- the primary key is unique;
- the natural key or grain is unique.

| File | Extra gates (the build fails when any item is true) |
|---|---|
| 01 `dim_geography` | No snapshot date; PSGC code on two boundaries of one level (AB07); no boundary matched at all; centroid outside the Philippines or area ≤ 0; city without a city class; name missing; locality with no planning unit; parent or unit key not in the candidate |
| 02 `dim_date` | Grain outside year, month, week, snapshot; `period_basis` outside the five conventions; weekly period without dates, not 7 days, or not its ISO week and year (D-44, D-46); year missing, month outside 1–12, week outside 1–53; start after end; no registry snapshot period |
| 03 `dim_data_source` | `value_type` outside the five values; `sharing` outside open, restricted; name or as-of date missing; domain outside the six or `used_in` missing |
| 04 `dim_facility` | Rows ≠ registry rows; category outside the four; ownership outside government, private; hospital level missing for a hospital or filled for another category; listed facility without an area; area not in `dim_geography`; analysis beds total ≠ registry total |
| 05 `dim_disease` | Rows ≠ directory rows; name or classification missing; classification outside the four lists; parent not in the candidate |
| 06 `fact_facility_capacity` | Basis outside the three; category, ownership or level not allowed for the basis; measure filled on another basis; registry area not a locality; **registry facilities, beds and stations = listed silver totals**; stations filled where no facility has a count; **published hospitals, BHS and beds = silver totals**; published beds on a non-hospital row; **occupancy records at base, province and region level = silver rows**; breakdowns agree across levels; occupancy area without a region; roll-up colliding with a base row; suppressed row showing a measure; group under the threshold not suppressed |
| 07 `fact_disease_metric` | **Rows = metric + deaths-by-age + TB programme rows + 4 × claims cells**; **value total = silver ok total**; **claims filed at base and region = silver total**; claims at province = silver claims of hospitals in a province; claims amount = silver; paid > filed; suppression follows the threshold; value filled iff ok; modelled value inside its bounds; bounds on a non-modelled source; metric row without a coverage row; `is_complete_year` null; a cause-area-year without exactly 20 age groups; age and sex rules; TB both-sexes row without its male and female rows; `age_min > age_max`; four foreign keys resolve |
| 08 `fact_workforce_capacity` | Profession not in the list; core clinical ≠ 3; **rows = silver rows**; eligible row without a total; ineligible row without a reason; role outside the two; two preferred sources for one cell; negative headcount; **eligible total = silver eligible total**; three foreign keys resolve |
| 09 `fact_area_indicator` | Indicator outside the list; value filled iff ok; negative count; percentage outside 0–100; **census rows and total = silver** (areas in `dim_geography`); **FHSIS population rows = silver**; **poverty rows = 2 × silver**; poverty eligibility without a reason; share rows and per-capita rows = silver; level-1 shares sum to 100 within `share_level1_tolerance_pct`; expenditure area not `ph`; three foreign keys resolve |
| 12 `ref_osm_healthsite_point` | Rows = silver rows; point precision without coordinates or outside the Philippines; precision outside point, municipality; area not a locality; source not in `dim_data_source` |

**Bold** gates are control totals: gold must reconcile exactly with silver. That is how gold proves nothing was lost or doubled between layers.

**Why `CAST`, not `try_cast`.** Gold converts values silver already typed. A value that cannot convert is a bug, so ANSI mode makes `CAST` stop the build instead of producing a silent null that would drop out of totals. The one exception is `dim_geography` reading the year from the PSGC version text: that is parsing, so it uses `try_cast`, and the "no snapshot date" gate catches a failure.

## 4. Gold QC (`gold_qc.py`)

Gold QC runs after `gold_24`; `qc_registry` runs after it and is the last job task. It writes through `dq_utils.DQRun` with layer `gold` and domain `gold`, like every other QC script. It reads each of the 9 model tables at **one fixed version** (its latest). So every check of a table sees the same data.

| Code | Check | Severity | Fails when |
|---|---|---|---|
| G00 | QC ran without error | FAIL | The script crashed (written by `DQRun`) |
| G01 | Table has rows | FAIL | A model table is empty |
| G02 | Primary key complete and unique | FAIL | A null key or required column, or a repeated key |
| G03 | Grain unique | FAIL | The natural key repeats |
| G04 | Foreign key resolves | FAIL | A key value not in its dimension |
| G05 | Published table = latest succeeded build | FAIL | Row count ≠ the build's; the table was written after the build version (OPTIMIZE and VACUUM ignored); the version is older than the build (restored); or no build row |
| G06 | Built from the latest build of every input | FAIL | An input table was rebuilt after this build read it (stale) |
| G07 | Control total gold = silver | FAIL (claims: WARN when lower) | One of 13 controls differs by 1 or more |
| G08 | Value, status and basis consistent | FAIL | Value filled without ok status (or the reverse); suppressed occupancy row with a measure; measure on another basis; eligible workforce row without a headcount; two preferred workforce sources; by-age or by-sex row labelled as a total |
| G09 | View, mart or seed readable and not empty | FAIL | A view errors or returns no rows |
| G10 | One preferred source per disease series | FAIL | A disease × area × period × metric × coverage cell has more than one preferred source in `v_disease_metric_totals` |
| G11 | Measure values in a valid range | FAIL | Negative counts, beds or headcounts; occupancy outside 0–150; claims paid above filed; incidence or share outside 0–100 |
| G12 | Content unchanged since the previous QC run | WARN | The content fingerprint differs from the previous run (idempotency evidence) |
| G13 | Census population change plausible | WARN | An area halved or more than doubled between censuses |

**G07 controls.** G07 compares these gold totals with silver:

- `dim_facility` rows and beds;
- registry facilities and beds (listed);
- published hospitals and authorized beds;
- disease rows and value total (metric + deaths by age + TB programme);
- workforce rows and eligible headcount;
- census population of the areas in `dim_geography`;
- poverty rows (2 × silver);
- claims filed at region level.

A lower claims total gives WARN, because gold suppresses region cells from fewer than 3 hospitals. A higher claims total is always FAIL.

**G13 is business monitoring.** A province that halves between censuses is usually a boundary or code change (for example the Negros Island Region, the Maguindanao split), not an error. It is a WARN so a person reads it.

**Options:** `--job_run_id`, `--code_version`, `--gold_schema`, `--silver_schema`, `--profile`, `--check_views`, `--fail_on_error`. All optional.

## 5. Idempotency: G12

**Claim.** Running gold again on the same inputs gives the same content.

**How QC measures it.** For each model table:

```
fingerprint = "rows=<n>;hash=<sum over rows of xxhash64(to_json(all columns except _gold_build_id))>"
```

The fingerprint leaves out `_gold_build_id`, the only column that changes on a rebuild. The keys are hashes of natural keys, so they stay the same.

**Procedure for the evidence runs** (capture plan: [evidence](../../06-evidence/README.md), section 2; results: [final runs of 2026-10-21](../../06-evidence/2026-10-21-final-runs/README.md)).

1. Run the full job three times with no new data and no code change between runs.
2. Run 1: G12 is PASS with "first fingerprint", or WARN if content changed since an earlier run.
3. Runs 2 and 3: every G12 row should be PASS with "same as previous". Query I2 of the evidence page puts the three runs side by side.

**Expected once after 2026-10-20.** The weekly `date_key` values changed with the new period bases (D-44, D-46), so the first run after that rebuild shows G12 WARN on `dim_date` and `fact_disease_metric`. Runs 2 and 3 should PASS.

**Result (2026-10-21).** Final run 1 showed G12 WARN on 5 tables (`dim_data_source`, `dim_date`, `fact_disease_metric`, `fact_workforce_capacity`, `fact_area_indicator`): content changed since the gold QC run before the gold pass. Final run 2 showed G12 PASS "same as previous" on all 9 tables.

A G12 WARN's detail lists the input tables and versions, so a reader can tell "content changed because an input changed" from "content changed with the same inputs" (the second would be a real idempotency failure).

## 6. Mart and seed checks (read by a person)

| File | Check | Expected |
|---|---|---|
| 10 `source_priority` | Rules by role | 34 = 30 preferred, 2 cross_check, 2 fallback |
| 11 `huc_province_crosswalk` | Check 1: match status | All 17 `matched` |
| 19 `priority_weight_params` | Weights per set | 4 rows, sum 1 (raises otherwise) |
| 22 `mart_kidney_case_study` | Check 1: exclusion reasons | No `ihme_province_coverage_not_confirmed` (D-42) |
| 23 `mart_dengue_peak_capacity` | Check 3: one row per key | No row |
| 24 `mart_evidence_readiness` | Check 1, `schema_name = 'gold'` | No QC missing, no stale table |

`gold_o13_evidence.sql` holds the evidence for the agreed mart values (D-56):

| Query | Shows |
|---|---|
| Q1, Q2 | Units in the top 10 under all three weight sets, and the overlap with `equal` |
| Q3, Q4 | Station completeness distribution; comparable kidney units at 70 / 80 / 90% |
| Q5 | Agreement of "two of three" with the lowest fifth of combined doctor-nurse-midwife density |
| Q6 | Units per poverty band |

## 7. Tracing a number to its source

Example: the TB notification rate of one planning unit on the dashboard.

| Step | Use | Result |
|---|---|---|
| 1 | `mart_area_burden_indicator` row: `planning_unit_key`, `burden_indicator_key`, `reference_year`, `population_year` | The unit, indicator and years |
| 2 | `mart_base_planning_unit`: the unit's localities and population | The denominator and how gold summed it |
| 3 | `fact_disease_metric` rows of the unit's localities (`disease_code = tb_all_forms`, `metric_name = cases`, `data_source_key`, `date_key`) | The counts summed |
| 4 | `_gold_build_id` of those rows → `quality.build_log` | When gold built the fact, with which settings and code version |
| 5 | `quality.build_inputs` of that build | The silver tables and the versions read |
| 6 | Silver row: `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_metric_source_columns` | The source cell |
| 7 | `_silver_build_id` → `build_inputs.content_checksum`, `load_batch_id` | The exact file version and load |
| 8 | `quality.qc_results` with `batch_id = build:<build_id>` | The checks that passed on that build |

Steps 6–8 are the silver part of the [lineage and quality contract](../quality/lineage-and-quality-contract.md), Appendix A.7.

**Why lineage is per build, not per row.** A gold row is usually an aggregate of many silver rows. A list of every source row on every gold row would multiply storage for little gain. The build record (inputs and versions) and the code version reproduce the number. This works while Delta keeps the input versions (contract O4).

## 8. Validation against the business questions

| Question | Validation |
|---|---|
| Do the totals match silver? | Control-total gates and G07 |
| Is every area accounted for? | Marts start from `dim_geography`; every unit gets a row, with an exclusion reason when it has no value (`mart_area_evidence`) |
| Are comparisons fair? | `area_coverage_map` outcomes; the alignment window; one denominator; the two denominators labelled |
| Is the source choice consistent? | `source_priority` checks; G10 |
| Do the results depend on the judgement values? | `gold_o13_evidence.sql` Q1–Q6 |
| Are the sources read correctly? | D-42 to D-46 evidence (IHME HUC test, HDX city–province test, week convention match of 714 region-weeks, HDX lag) |

## 9. Reading the results

**Latest gold QC result of every check:**

```sql
SELECT table_name, check_id, check_name, status, fail_count, total_count, observed, expected, detail
FROM public_health.quality.qc_results
WHERE layer = 'gold'
QUALIFY row_number() OVER (PARTITION BY table_name, check_id, column_name, detail ORDER BY executed_at DESC) = 1
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, table_name, check_id;
```

**G12, latest runs** (three runs side by side: query I2 of the [evidence page](../../06-evidence/README.md)):

```sql
SELECT table_name, status, observed, expected, detail, executed_at
FROM public_health.quality.qc_results
WHERE layer = 'gold' AND check_id = 'G12'
ORDER BY table_name, executed_at DESC;
```

**Failed gold builds and the gate that stopped them:**

```sql
SELECT target_table, started_at, error_message
FROM public_health.quality.build_log
WHERE layer = 'gold' AND status = 'failed'
ORDER BY started_at DESC;
```

## 10. When a check fails

| Result | Likely cause | Do |
|---|---|---|
| Build gate "silver input whose latest QC has a FAIL" | A silver QC FAIL | Fix silver; rerun its QC; rerun gold |
| Build gate "data_source_key not in dim_data_source" | A new silver source | Add it to the source list (gold 03) and the YAML |
| Build gate "period_basis outside the known conventions" | A new period convention in silver | Add it to the gold 02 gate deliberately |
| A control-total gate | A transform error, or silver changed between steps | Rerun the file; if it persists, compare the candidate with silver |
| G05 FAIL "written after build" | Someone wrote the table outside the build | Rerun the file |
| G06 FAIL | An input was rebuilt after this table | Rerun the files after that input, in run order |
| G07 FAIL | Same as a control-total gate, on the published table | Rerun the file; check silver |
| G09 FAIL | A view refers to a missing column or table | Rerun the view's file after its inputs |
| G10 FAIL | Two preferred rules overlap | Fix `source_priority` |
| G12 WARN with unchanged inputs | Non-deterministic logic | Find the column that changed; a tie-break without an order is the usual cause |
| G13 WARN | Boundary or code change between censuses | Read the areas; note them |

## 11. Limitations

| Limitation | Effect |
|---|---|
| Views have no build record | Readiness does not cover marts; G09 checks only that they are readable and not empty |
| Builds read inputs at their current version | `build_inputs` records the version. The build does not pin it (`VERSION AS OF`, R4) |
| Strict registry since 2026-10-21 (`dq_utils.py` default); G00–G13 are in the seed | An unknown G code stops gold QC. The first strict run is the next job run (O-17) |
| No drift check | G12 compares with the previous run only; no trend over runs |
| Restricted cells | QC cannot compare suppressed cells with silver one by one. It compares region totals instead |

## 12. History of updates

| Date | Change |
|---|---|
| 2026-10-11 | Write-audit-publish and build lineage in the first gold SQL |
| 2026-10-14 | Gates rewritten for the combined model; all gates 0 on the first run |
| 2026-10-18 | `gold_qc.py` written (G01–G13), D-48 |
| 2026-10-19 | G05 ignores OPTIMIZE and VACUUM; gold 23 check 3 |
| 2026-10-20 | Gold 02 weekly gate added (D-44, D-46). Null keys stay null in gold 04 and 12 so their gates can fire. `build_log.parameters` records the settings. Page written |
| 2026-10-21 | G12 result of the final runs; strict registry on (O-17) |
