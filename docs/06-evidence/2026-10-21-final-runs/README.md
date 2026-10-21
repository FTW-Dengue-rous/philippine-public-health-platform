# Final runs (2026-10-21)

Three full runs of the final pipeline job on the same inputs and the same code. They are the evidence that the pipeline is complete, passes its own QC, and is idempotent: bronze does not reload, and silver and gold rebuild to the same content.

Status date: 2026-10-21. All three runs done; every idempotency check passed.

Method and queries: [evidence guide](../README.md), sections 2 and 3, and [`evidence_queries.sql`](../evidence_queries.sql).

---

## 1. Runs

| Run | Job run id | Run by | Started – ended (Manila) | Result | Record |
|---|---|---|---|---|---|
| 1 | `186099985728312` | Jemma | 2026-10-21 04:49 – 06:13 | Succeeded. 0 FAIL in every layer; 7 expected gold WARNs | [run-1](run-1/run-1.md) |
| 2 | `26759964775689` | Jemma | 2026-10-21 10:16 – 11:16 | Succeeded. 0 FAIL; G12 PASS on all 9 gold tables; bronze loaded nothing; same row counts; `qc_registry` passed | [run-2](run-2/run-2.md) |
| 3 | `996544156339205` | Jemma | 2026-10-21 11:28 – 12:32 | Succeeded. 0 FAIL; G12 PASS on all 9 gold tables; bronze loaded nothing; same row counts; `qc_registry` passed | [run-3](run-3/run-3.md) |

Code: branch `dev`, commit **to fill**. Between runs 1 and 2, the job YAML (new `qc_registry` task), setup YAML comments, the registry seed and the new registry check SQL changed. No build or QC script changed, so the data rules are the same in all three runs. Runs 2 and 3 use exactly the same commit.

## 2. Rules for these runs

- **One person runs all three.** Nobody else runs the job, a task or a build in the workspace until run 3's queries are captured. Every run writes to the same tables, so an extra run becomes one of the "last three" in queries I1–I3 and in G12.
- No pull request merge, bundle deploy or Volume change between runs.
- Capture B1, S1, S2 and G1 right after each run, before the next run starts.
- Run I1, I2 and I3 right after run 3 (running them after run 2 as well is fine; they are read-only).
- **No code change until run 3's queries are captured**, including the switch to `strict_registry=True` (O-17). Make it after run 3.

**The next run of the same job started at 10:16 Manila on 2026-10-21** (run id `26759964775689`). It writes to the same tables. Choose one:

| Option | When it applies | What to do |
|---|---|---|
| Count it as run 2 | It succeeds, and no pull request was merged and no bundle deploy happened since run 1 (same job, same commit) | Capture B1, S1, S2, G1 right after it ends. Then run 3 |
| Don't count it | Another job, another branch, or it fails or is stopped | Wait until it ends. Then run 2 and run 3 back to back. Record it here as an extra run between runs 1 and 2 |

With the second option, the "last three" columns of I1, I2 and I3 show runs 2 and 3 plus the extra run, not run 1. The pass rules still hold: the last two columns must match.

## 3. Comparison (after run 3)

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
