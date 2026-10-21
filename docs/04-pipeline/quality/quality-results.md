# Quality results and evidence

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

This page gives the results of the recorded runs, layer by layer, with their evidence. Each result names its date and its `validation_id` where it has one. Use them to find the result again in `public_health.quality`. Screenshots and query outputs go to [`06-evidence/`](../../06-evidence/README.md).

Status date: 2026-10-21.

---

## 1. Runs at a glance

| Date (PHT) | Run | Layers | Result |
|---|---|---|---|
| 2026-10-16, 00:09–01:13 | Full pipeline run 1 | Bronze → marts | Completed |
| 2026-10-17, 13:39–14:49 | Full pipeline run 2 | Bronze → marts | Completed |
| 2026-10-19 | Bronze notebook runs (baseline QC, gate, `run_bronze`) | Bronze | Gate passed; 0 blocking |
| 2026-10-19 | Silver rebuild with the revisions (D-44, rule 2a) | Silver | Diseases 0 FAIL. Population 0 FAIL. Cross-domain 0 FAIL |
| 2026-10-20 | Workforce rebuild (Zamboanga Sibugay override) and cross-domain QC | Silver | 0 FAIL |
| 2026-10-21 | Final evidence run 1 | All, including gold QC | Succeeded; 0 FAIL; 7 expected gold WARNs |
| 2026-10-21 | Final evidence run 2 | All, including gold QC | Succeeded; 0 FAIL; 2 standing gold WARNs; G12 PASS for all 9 gold tables |
| Pending | Final evidence run 3 and reconciliation | All, including gold QC | — |

The full runs of 2026-10-16/17 used the job and gold of those dates. Gold was in `test_gold2` and had no `gold_qc.py` yet. `qc_results` holds their per-check results. The team wrote their layer pages before the post-capstone revisions.

## 2. Bronze

Notebook runs on 2026-10-19 ([bronze quality checks](../bronze/bronze-quality-checks.md), section 11):

| Step | Result |
|---|---|
| First gate run, all domains | Stopped on 17 sources as NOT_CHECKED: their last QC predated the quality schema. A one-time baseline QC run gave them results |
| Gate, all domains | 41 sources: 39 PASS, 2 WARN, 0 blocking |
| `run_bronze.py`, 6 domains (loaders `2026-10-19.1`) | 46 sources unchanged, 0 loaded, 0 failed, 0 QC re-queued |
| Stricter B13 (FAIL when unverifiable) | 0 B13 FAIL |

**Accepted WARNs** (D-55):

| Check | Source | Reason |
|---|---|---|
| B08 | `philhealth_foi_claims_hospital` | The source repeats sub-rows. Silver sums them |
| B08 | `doh_fhsis_demographic` | The 2019 workbook has blank-area rows. Silver drops them |
| B10 | `psgc_population` | Values hold separators and notes. Silver parses them |
| B03 | Files without `qc.expected_rows` | The YAML has no expected count yet (to-do 7b) |

**What this proves.**

- Every file loaded once and in full.
- Counts match the loader's log.
- No source with a FAIL or no result can reach silver. The gate stopped on the 17 unchecked sources, which shows it works.

## 3. Silver

### 3.1 2026-10-19: rebuild with the revisions

| Script | Result |
|---|---|
| `diseases_silver_qc.py` | 143 checks, 0 FAIL, 7 WARN |
| `silver_rev_d44_verify.sql` steps 1–4 | Passed (the D-44 / D-46 week convention after the rebuild) |
| `psgc_population_silver_qc.py` | 19 checks, 0 FAIL, 5 WARN; S59 PASS (2015, 2020, 2024) |
| `silver_cross_domain_qc.py` | `e56cdd87-64bd-4686-9f32-74ff95622ed6`: 0 FAIL, 11 WARN |

### 3.2 2026-10-20: workforce rebuild and cross-domain

| Script | `validation_id` | Result |
|---|---|---|
| `workforce_silver_qc.py` | `5ddb4edc-a3c7-49f0-ab52-7214b1cba1c5` | 0 FAIL. WARN S68, S69, S70, S72, S73, S77, S79 (expected). Headcount 28,080 rows, denominator 3,024, specialist 52 |
| `silver_cross_domain_qc.py` | `14f27bc1-8c3f-48dd-aa5c-8a6faddd2ed4` | **68 checks, 0 FAIL, 10 WARN** |

Cross-domain WARNs, all expected ([silver quality checks](../silver/silver-quality-checks.md), section 14):

| Check | Reading |
|---|---|
| S29 × 8 | Quarantine below the limit in every source (claims 1,404 of 245,405; FHSIS TB 18 of 3,493; TB programme 2 of 5,244; OSM 2 of 16,032; facilities 7 of 800, 12 of 614, 21 of 1,180; workforce 8 of 4,999) |
| S98 | `hdx_dengue` latest 2021; `psa_deaths_national_annual` latest 2020: the sources stopped publishing |
| S99 | 11 of 171 FHSIS area-years differ from the census by more than 10%; largest regions VI and VII in 2024 (Negros Island Region) |

One S29 WARN fewer than 2026-10-19: the Zamboanga Sibugay row override (D-58) restored 9 headcount rows and 1 denominator row.

**What this proves.**

- Silver loads or accounts for every bronze row (S09, S29, `row_disposition`).
- Keys are unique and resolve.
- Controls from the YAML match.
- Silver built each table from the current bronze loads (S16, S33, S63, S83).
- Silver sets aside under 1% of any source, each row with a reason.

## 4. Gold

### 4.1 Test build, 2026-10-14 (`test_gold2`)

All build gates returned 0 on every table. Row counts and mart figures from that build are in the [table catalog](../gold/table-catalog.md) and the [findings report](../gold/findings-report.md). `gold_qc.py` did not exist yet.

### 4.2 Final build: runs 1 and 2 recorded; run 3 pending

The final job ran twice on unchanged inputs on 2026-10-21. The records are in the [final evidence session](../../06-evidence/2026-10-21-final-runs/README.md). A third run and reconciliation are still required before claiming complete idempotency evidence.

| Item | Expected | Result |
|---|---|---|
| Every gold build, runs 1 and 2 | `succeeded` in `build_log`; every gate 0 | Recorded in the run records: all 28 silver and gold tables succeeded in each run |
| Gold QC run 1 | 0 FAIL; G12 can WARN once after a content change; G13 and G07 can WARN | Recorded: 118 checks, 111 PASS, 7 expected WARN, 0 FAIL. See [run 1](../../06-evidence/2026-10-21-final-runs/run-1/run-1.md) |
| Gold QC run 2 | 0 FAIL; G12 PASS "same as previous" | Recorded: 118 checks, 116 PASS, 2 standing WARN, 0 FAIL; G12 PASS for all 9 gold tables. See [run 2](../../06-evidence/2026-10-21-final-runs/run-2/run-2.md) |
| Row counts across runs 1 and 2 | Same count for every table (query I1) | Recorded: `same_count` true for all 28 tables in run 2 |
| Gold QC run 3 and final comparison | 0 FAIL; **every G12 row PASS "same as previous"** (query I2) | Pending |
| Gold 11 check 1 | All 17 HUCs `matched` | Pending |
| Gold 22 check 1 | No `ihme_province_coverage_not_confirmed` | Pending |
| Gold 23 check 3 | No row | Pending |
| Gold 24 check 1 (`schema_name = 'gold'`) | No QC missing, no stale table | Pending |
| `gold_o13_evidence.sql` Q1–Q6 | Read for D-56 | Pending |

Record the run-3 result here with its date and `validation_id`, then link the final comparison and reconciliation evidence.

## 5. Evidence to capture

The folders, the capture steps for the three runs and the queries (B1, S1, S2, G1, I1, I2) are in the [evidence guide](../../06-evidence/README.md). In addition, for gold:

| Item | Where it goes |
|---|---|
| Mart check queries (gold 11 check 1, 22 check 1, 23 check 3, 24 check 1) | `06-evidence/gold/` |
| `gold_o13_evidence.sql` Q1–Q6 | `06-evidence/gold/` |
| G07 control totals | `06-evidence/reconciliation/` |

## 6. How to read the latest results

**One status per table:**

```sql
SELECT layer, table_name, overall_status, last_checked_at
FROM public_health.quality.v_table_health
ORDER BY layer, table_name;
```

**Everything open (FAIL and WARN), every layer:**

```sql
SELECT layer, table_name, source_key, check_id, status, observed, expected, detail
FROM public_health.quality.v_open_issues
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END, layer, table_name, check_id;
```

**Last run of every QC script:**

```sql
SELECT layer, script_name, domain, status, checks_total, checks_pass, checks_warn, checks_fail,
       started_at, validation_id
FROM public_health.quality.run_log
QUALIFY row_number() OVER (PARTITION BY script_name ORDER BY started_at DESC) = 1
ORDER BY layer, script_name;
```

**Crashed runs:**

```sql
SELECT * FROM public_health.quality.v_run_errors ORDER BY started_at DESC;
```

## 7. History of updates

| Date | Change |
|---|---|
| 2026-10-16, 10-17 | Full runs 1 and 2 |
| 2026-10-19 | Bronze notebook runs; silver rebuild and QC |
| 2026-10-20 | Workforce rebuild and cross-domain QC. Page written; gold section ready for the final runs |
| 2026-10-21 | Final evidence runs 1 and 2 recorded. Gold section updated from the evidence records; run 3 and reconciliation remain pending |
