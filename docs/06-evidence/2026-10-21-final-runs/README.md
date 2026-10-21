# Final runs (2026-10-21)

Three full runs of the final pipeline job on the same inputs and the same code. They are the evidence that the pipeline is complete, passes its own QC, and is idempotent: bronze does not reload, and silver and gold rebuild to the same content.

Status date: 2026-10-21. Run 1 done; runs 2 and 3 next.

Method and queries: [evidence guide](../README.md), sections 2 and 3, and [`evidence_queries.sql`](../evidence_queries.sql).

---

## 1. Runs

| Run | Job run id | Run by | Started – ended (Manila) | Result | Record |
|---|---|---|---|---|---|
| 1 | `186099985728312` | Jemma | 2026-10-21 04:49 – 06:13 | Succeeded. 0 FAIL in every layer; 7 expected gold WARNs | [run-1](run-1/run-1.md) |
| 2 | `26759964775689` | to fill | 2026-10-21 10:16 – running | Candidate run 2 (section 2) | `run-2/` |
| 3 | — | — | — | Pending | `run-3/` |

Code for all three runs: branch `dev`, commit **to fill**. All three must use the same commit.

## 2. Rules for these runs

- **One person runs all three.** Nobody else runs the job, a task or a build in the workspace until run 3's queries are captured. Every run writes to the same tables, so an extra run becomes one of the "last three" in queries I1–I3 and in G12.
- No pull request merge, bundle deploy or Volume change between runs.
- Capture B1, S1, S2 and G1 right after each run, before the next run starts.
- Run I1, I2 and I3 once, right after run 3.

**The next run of the same job started at 10:16 Manila on 2026-10-21** (run id `26759964775689`). It writes to the same tables. Choose one:

| Option | When it applies | What to do |
|---|---|---|
| Count it as run 2 | It succeeds, and no pull request was merged and no bundle deploy happened since run 1 (same job, same commit) | Capture B1, S1, S2, G1 right after it ends. Then run 3 |
| Don't count it | Another job, another branch, or it fails or is stopped | Wait until it ends. Then run 2 and run 3 back to back. Record it here as an extra run between runs 1 and 2 |

With the second option, the "last three" columns of I1, I2 and I3 show runs 2 and 3 plus the extra run, not run 1. The pass rules still hold: the last two columns must match.

## 3. Comparison (after run 3)

| Check | Query | Pass | Result |
|---|---|---|---|
| Bronze reloads nothing | I3 | `no_reload` true for every source | Pending |
| PSGC geography and HDX boundaries unchanged | Task output | `unchanged`, 0 inserts, 0 updates | Pending |
| Same row counts | I1 | `same_count` true for every table | Pending |
| Same gold content | I2 | `run_2` and `run_3` PASS for all 9 tables, "same as previous" | Pending |
| No new failures | G1 of runs 2 and 3 | 0 FAIL; only G07 and G13 WARN | Pending |

Save the I1, I2 and I3 screenshots in `run-3/` as `5_run3.png`, `6_run3.png`, `7_run3.png` (the naming rule is in the [evidence guide](../README.md), section 4).

## 4. History of updates

| Date | Change |
|---|---|
| 2026-10-21 | Folder created; run 1 recorded; run `26759964775689` (10:16) listed as candidate run 2 |
