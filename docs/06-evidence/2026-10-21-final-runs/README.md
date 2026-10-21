# Final runs (2026-10-21)

Three full runs of the final pipeline job on the same inputs. They are the evidence that the pipeline is complete, passes its own QC, and is idempotent: bronze does not reload, and silver and gold rebuild to the same content.

Status date: 2026-10-21. All three runs done; every idempotency check passed.

Method and queries: [evidence guide](../README.md), sections 2 and 3, and [`evidence_queries.sql`](../evidence_queries.sql).

---

## 1. Runs

| Run | Job run id | Run by | Started – ended (Manila) | Result | Record |
|---|---|---|---|---|---|
| 1 | `186099985728312` | Jemma | 2026-10-21 04:49 – 06:13 | Succeeded. 0 FAIL in every layer; 7 expected gold WARNs | [run-1](run-1/run-1.md) |
| 2 | `26759964775689` | Jemma | 2026-10-21 10:16 – 11:16 | Succeeded. 0 FAIL; G12 PASS on all 9 gold tables; bronze loaded nothing; same row counts; `qc_registry` passed | [run-2](run-2/run-2.md) |
| 3 | `996544156339205` | Jemma | 2026-10-21 11:28 – 12:32 | Succeeded. 0 FAIL; G12 PASS on all 9 gold tables; bronze loaded nothing; same row counts; `qc_registry` passed | [run-3](run-3/run-3.md) |

All three runs used the bundle job `[dev jemmalyn_santiago] ph-public-health-pipeline` (job id `587047839768584`), deployed from `dev`.

**Code.** Runs 2 and 3 ran the same deployment. Between runs 1 and 2, only QC metadata changed: the job YAML (new last task `qc_registry`), setup YAML comments, the registry seed and the new `quality_registry_check.sql`. No build or QC script changed, so the data rules are the same in all three runs. Strict registry (`strict_registry=True`) was merged into `dev` after run 3, so none of these runs used it.

## 2. How the runs were kept comparable

- One person ran all three; nobody else ran the job, a task or a build in the workspace until run 3's queries were captured. Every run writes to the same tables, so an extra run would have become one of the "last three" in queries I1–I3 and in G12.
- No pull request was merged, no bundle was deployed and no landing file changed between runs 2 and 3.
- B1, S1, S2 and G1 were captured right after each run, before the next one started.
- I1, I2 and I3 were run after each of runs 2 and 3; the run-3 screenshots are the final comparison.

## 3. Comparison

| Check | Query | Pass | Result |
|---|---|---|---|
| Bronze reloads nothing | I3 | `no_reload` true for every source | **Pass:** 40 of 40 sources, loaded 0 and failed 0 in runs 1, 2 and 3 |
| PSGC geography and HDX boundaries unchanged | Task output | `unchanged`, 0 inserts, 0 updates | `bronze_geography` and `bronze_admin_boundaries` green in every run; task output not captured |
| Same row counts | I1 | `same_count` true for every table | **Pass:** 28 of 28 tables, runs 1, 2 and 3 |
| Same gold content | I2 | `run_2` and `run_3` PASS for all 9 tables, "same as previous" | **Pass:** 9 of 9 in runs 2 and 3 (run 1: WARN on 5 tables once, expected) |
| No new failures | G1 of runs 2 and 3 | 0 FAIL; only G07 and G13 WARN | **Pass** in runs 2 and 3 |

**Conclusion:** on the same inputs and code, the pipeline loads nothing new in bronze and rebuilds silver and gold to the same row counts and the same gold content. QC has 0 FAIL in every layer across all three runs. The I1, I2 and I3 screenshots are in `run-3/`.

## 4. History of updates

| Date | Change |
|---|---|
| 2026-10-21 | Folder created; run 1 recorded; run `26759964775689` (10:16) listed as candidate run 2 |
| 2026-10-21 | Run 2 recorded: it meets the conditions and counts as run 2. Every idempotency check passed |
| 2026-10-21 | Run 3 recorded; comparison complete: every idempotency check passed |
| 2026-10-21 | Page tidied after run 3: planning text (run-2 options, "before run 3" rules) replaced by how the runs were kept comparable; code note states the deployment and that strict registry came after run 3 |
