# Evidence

Owner: LUNASaan Documentation Team

Proof that the pipeline runs, checks itself and gives the same result twice. Each run record holds the job run, the query results and screenshots, with the run date in the name. The methods are described elsewhere; this folder holds the results.

Status date: 2026-10-21. This checkout records final runs 1, 2, and 3. Exact deployment provenance, geography/boundary task-output capture, and final reconciliation evidence remain required before presenting the records as proof of an exact source revision or complete end-to-end recovery validation.

---

## 1. Folder layout

One record per pipeline session, named by date. The final runs are the evidence to read; earlier records are history.

```
06-evidence/
├── README.md                          this guide and the run index (section 5)
├── evidence_queries.sql               the seven queries (B1, S1, S2, G1, I1, I2, I3)
└── 2026-10-21-final-runs/             the evidence: three runs on the same inputs
    ├── README.md                      runs, rules, comparison (I1, I2, I3)
    ├── run-1/                         run-1.md and its screenshots
    ├── run-2/
    ├── run-3/
    └── reconciliation/                queries A–D, once after run 3
```

| Record | Proves |
|---|---|
| Each `run-N/` | The job ran end to end; bronze skipped or loaded correctly and the gate passed; silver and gold built; QC has no FAIL and only expected WARNs |
| `2026-10-21-final-runs/README.md` | Three runs on the same inputs give the same published content |
| `reconciliation/` | Every bronze row is loaded or set aside with a reason; controls match at both layers ([silver reconciliation](../04-pipeline/silver/reconciliation.md), section 5) |

A new session of runs gets its own `<yyyy-mm-dd>-<what>/` folder. Don't move or rewrite an older record: add a note to it instead.

## 2. The three evidence runs

Run the full job three times with no new data and no code change between runs (D-59: runs are manual).

| Run | What it shows |
|---|---|
| Run 1 | The current code end to end. G12 may WARN once against the run before the gold pass (for example the weekly `date_key` after D-44) |
| Run 2 | Same inputs: bronze skips every file; silver and gold rebuild; every G12 row PASS ("same as previous") |
| Run 3 | Confirms run 2: every G12 row PASS again |

Between runs, don't:

- merge a pull request or redeploy the bundle;
- add or replace a file in the landing Volume;
- run a single task or a build by hand (an extra build shifts the I1 columns).

For each run, save into `run-N/` of the session folder:

1. A screenshot of the job run (all tasks green) with its run id and duration, and of the task graph.
2. The outputs of queries B1, S1, S2, G1 (section 3), exported as CSV or screenshots.
3. The `run_bronze.py` summary and the six gate outputs (task logs).
4. `run-N.md`: what ran, the results, and why each WARN is expected ([run 1](2026-10-21-final-runs/run-1/run-1.md) is the model).
5. The deployed Git commit SHA and bundle deployment ID, copied from the deployment record before the next run starts.

After run 3, fill the comparison in the session `README.md` from queries I1, I2 and I3: row counts per table, the G12 status per gold table, and what each bronze loader did, across the three runs.

Then run the reconciliation queries A–D once and save them in `reconciliation/` with the run date. Record the three runs in the [change log](../08-governance/change-log.md) and the results in [quality results](../04-pipeline/quality/quality-results.md).

### Idempotency passes when

| Check | Where | Pass |
|---|---|---|
| Bronze reloads nothing | I3, and the `run_bronze.py` summary of runs 2 and 3 | `no_reload` true for every source: `run_2` and `run_3` show "loaded 0, failed 0" |
| Geography and boundaries change nothing | MERGE task output, runs 2 and 3 | 0 inserts, 0 updates |
| Silver and gold row counts | I1 | `same_count` true for every table |
| Gold content | I2 | `run_2` and `run_3` PASS for all 9 tables, detail "same as previous" |
| No new failures | G1, runs 2 and 3 | Only G07 and G13 WARN; no G12 row |

## 3. Queries

All seven are in [`evidence_queries.sql`](evidence_queries.sql). Run them right after the job finishes, before anything else builds.

| Query | When | What it returns | Expected |
|---|---|---|---|
| B1 | Each run | Bronze checks not PASS, from the latest QC run of each source (what the gate reads) | Only the WARNs in [bronze quality checks](../04-pipeline/bronze/bronze-quality-checks.md): B08 claims, B08 `doh_fhsis_demographic`, B10 `psgc_population` |
| S1 | Each run | Last run of every QC script | No FAIL, no ERROR |
| S2 | Each run | Latest build of every silver and gold table (test schemas left out) | Every table, finished during this run |
| G1 | Each run | Gold QC results not PASS, latest gold QC run | No FAIL |
| I1 | After run 3 | Row counts per table across the last three builds | Same count in all three columns |
| I2 | After run 3 | G12 per gold table across the last three gold QC runs | `run_2`, `run_3` PASS |
| I3 | After run 3 | Per bronze source, what its loader logged in its last three runs (loaded, skipped, failed) from `ingestion_metadata` | `run_2`, `run_3`: loaded 0, failed 0; `no_reload` true |

Notes on reading them:

- **Bronze dates stay old.** `run_bronze.py` re-runs QC only for sources it loaded or that are not cleared. In S1 and B1, an unchanged source keeps the date of its last QC run.
- **B1 reads the latest run only.** A failure that a later run fixed no longer shows. The first version partitioned by `detail` and kept old failures.
- **I3 covers the file and API loaders.** PSGC geography and HDX boundaries don't log skips to `ingestion_metadata`; their evidence is the task output (`unchanged`, 0 inserts, 0 updates).
- **S1 lists retired script names.** `population_silver_qc.py` (2026-10-17) is the old name of `psgc_population_silver_qc.py`.

## 4. Rules

- **One person runs the evidence runs.** Every run writes to the same tables, so a teammate's run in between becomes part of the "last three" in I1–I3 and in G12. Agree who runs before starting.
- **One owner per record.** The person who ran it writes its record. The other reviews it and adds a note instead of rewriting it.
- Name screenshots `<n>_run<N>.png` inside the run folder, numbered in query order: 1 B1, 2 S1, 3 S2, 4 G1, 5 I1, 6 I2, 7 I3, 8 job run, 9 job details (List view), 10 run history of the job, 11 task graph (Graph view). Add `a`, `b` when one result needs two screenshots (for example `3a_run1.png`, `3b_run1.png`).
- Never put restricted values in a screenshot: aggregates, counts and QC results only (D-47).
- Don't edit an output; rerun and replace it.
- A WARN in the evidence is fine when it is an expected WARN on the layer's quality page; anything else gets a note in the run record.

## 5. Run index

| Date | Record | Status | What it shows |
|---|---|---|---|
| 2026-10-21 | [Final runs](2026-10-21-final-runs/README.md) | Evidence, partially complete | Three recorded runs on unchanged inputs; deployment provenance, geography/boundary task output, and reconciliation evidence remain required |

**Final runs, 2026-10-21:**

| Run | Date | Result |
|---|---|---|
| 1 | 2026-10-21 | [Run record](2026-10-21-final-runs/run-1/run-1.md), job run `186099985728312`. Bronze: nothing reloaded (I3). Gold built in `public_health.gold`. Gold QC 118 checks: 111 PASS, 7 WARN, 0 FAIL. WARNs: G12 on 5 tables (content changed since the run before the gold pass), G13 (Kalayaan, Makati, Pikit: boundary changes between censuses), G07 claims (27 region cells suppressed). Silver QC: 0 FAIL. Bronze: 3 expected WARNs |
| 2 | 2026-10-21 | [Run record](2026-10-21-final-runs/run-2/run-2.md), job run `26759964775689`. Bronze loaded nothing; all 28 tables same row count; G12 PASS "same as previous" on all 9 gold tables; gold QC 118 checks: 116 PASS, 2 WARN (G13, G07), 0 FAIL |
| 3 | 2026-10-21 | [Run record](2026-10-21-final-runs/run-3/run-3.md), job run `996544156339205`. Bronze loaded nothing; all 28 tables had the same row counts; G12 passed for all 9 gold tables; gold QC had 0 FAIL. Exact commit SHA, bundle deployment ID, and geography/boundary task output were not captured. |

## 6. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Folder guide and capture plan for three evidence runs written |
| 2026-10-21 | Folder layout: one dated record per session; final runs in `2026-10-21-final-runs/`; the 2026-10-18 record kept as history. Rules for two people |
| 2026-10-21 | I3 added: bronze loads across the three runs |
| 2026-10-21 | Queries moved to `evidence_queries.sql`. B1 reads each source's latest QC run; S2 and I1 leave out test schemas; I1 adds `same_count`. Pass criteria for idempotency; run 1 recorded |
