# Evidence

Proof that the pipeline runs, checks itself and gives the same result twice. Each folder holds screenshots and query outputs from recorded runs, with the run date in the file name. The methods are described elsewhere; this folder holds the results.

Status date: 2026-10-20. Capture plan for the three evidence runs below; outputs are added after the runs.

---

## 1. What each folder proves

| Folder | Proves | Captured from |
|---|---|---|
| `architecture/` | The job as deployed: task graph, settings, environments | Job page in the workspace (graph view, settings) |
| `bronze/` | Every source loaded or correctly skipped; bronze QC and the gate passed | `run_bronze.py` summary, gate output, query B1 |
| `silver/` | Every silver build succeeded; domain and cross-domain QC have no FAIL; expected WARNs only | Query S1, S2, the QC run summaries |
| `gold/` | Gold built; gold QC has no FAIL; readiness mart current | Query G1, `mart_evidence_readiness`, the gold QC summary |
| `idempotency/` | Three runs on the same inputs give the same published content | `run-01/`, `run-02/`, `run-03/`, and `run-comparison.md` (queries I1, I2) |
| `reconciliation/` | Every bronze row is loaded or set aside with a reason; controls match at both layers | Queries A–D of [silver reconciliation](../04-pipeline/silver/reconciliation.md), section 5 |

## 2. The three evidence runs

Run the full job three times with no new data and no code change between runs (D-59: runs are manual).

| Run | What it shows |
|---|---|
| Run 1 | The current code end to end. G12 may WARN once against the run before the gold pass (for example the weekly `date_key` after D-44) |
| Run 2 | Same inputs: bronze skips every file; silver and gold rebuild; every G12 row PASS ("same as previous") |
| Run 3 | Confirms run 2: every G12 row PASS again |

For each run, save into `idempotency/run-0N/`:

1. A screenshot of the job run (all tasks green) with its run id and duration.
2. The outputs of queries B1, S1, S2, G1 (section 3), exported as CSV or screenshots.
3. The `run_bronze.py` summary and the six gate outputs (task logs).

After run 3, write `idempotency/run-comparison.md` from queries I1 and I2: row counts per table across the three runs, and the G12 status per gold table.

Then run the reconciliation queries A–D once and save them in `reconciliation/` with the run date. Record the three runs in the [change log](../08-governance/change-log.md) and the results in [quality results and evidence](../04-pipeline/quality/quality-results-and-evidence.md).

## 3. Queries

**B1. Bronze QC and the gate's view, latest run per source**

```sql
SELECT r.domain, q.source_key, q.check_id, q.status, q.detail
FROM public_health.quality.qc_results q
JOIN public_health.quality.run_log r ON r.validation_id = q.validation_id
WHERE q.layer = 'bronze' AND q.status <> 'PASS'
QUALIFY row_number() OVER (PARTITION BY r.domain, q.source_key, q.check_id, q.detail ORDER BY q.executed_at DESC) = 1
ORDER BY q.status, r.domain, q.source_key;
```

**S1. Every QC script's last run (all layers)**

```sql
SELECT layer, script_name, status, checks_total, checks_pass, checks_warn, checks_fail,
       started_at, validation_id
FROM public_health.quality.run_log
QUALIFY row_number() OVER (PARTITION BY script_name ORDER BY started_at DESC) = 1
ORDER BY layer, script_name;
```

**S2. Latest build of every silver and gold table**

```sql
SELECT layer, target_table, status, row_count, target_table_version, finished_at
FROM public_health.quality.build_log
WHERE status = 'succeeded'
QUALIFY row_number() OVER (PARTITION BY target_table ORDER BY finished_at DESC) = 1
ORDER BY layer, target_table;
```

**G1. Gold QC results that are not PASS (latest run)**

```sql
SELECT table_name, check_id, check_name, status, observed, expected, detail
FROM public_health.quality.qc_results
WHERE layer = 'gold'
  AND validation_id = (SELECT max_by(validation_id, started_at) FROM public_health.quality.run_log
                       WHERE layer = 'gold')
  AND status <> 'PASS'
ORDER BY status, table_name, check_id;
```

**I1. Row counts per table across the last three builds**

```sql
WITH b AS (
  SELECT target_table, row_count, finished_at,
         row_number() OVER (PARTITION BY target_table ORDER BY finished_at DESC) AS rn
  FROM public_health.quality.build_log
  WHERE status = 'succeeded')
SELECT target_table,
       max(CASE WHEN rn = 3 THEN row_count END) AS run_1,
       max(CASE WHEN rn = 2 THEN row_count END) AS run_2,
       max(CASE WHEN rn = 1 THEN row_count END) AS run_3
FROM b WHERE rn <= 3
GROUP BY target_table
ORDER BY target_table;
```

Run it right after run 3, before any other build. Expected: the same count in all three columns for every table. Geography and boundaries are MERGE builds outside `build_log`; their rerun evidence is 0 inserts and 0 updates in the task output.

**I2. G12 per gold table, last three gold QC runs**

```sql
WITH g AS (
  SELECT q.table_name, q.status, q.observed, q.detail, r.started_at,
         dense_rank() OVER (ORDER BY r.started_at DESC) AS run_rank
  FROM public_health.quality.qc_results q
  JOIN public_health.quality.run_log r ON r.validation_id = q.validation_id
  WHERE q.layer = 'gold' AND q.check_id = 'G12')
SELECT table_name,
       max(CASE WHEN run_rank = 3 THEN status END) AS run_1,
       max(CASE WHEN run_rank = 2 THEN status END) AS run_2,
       max(CASE WHEN run_rank = 1 THEN status END) AS run_3
FROM g WHERE run_rank <= 3
GROUP BY table_name
ORDER BY table_name;
```

Expected: `run_2` and `run_3` PASS for every table.

## 4. Rules

- Name files `<what>_<yyyy-mm-dd>.<ext>` (for example `gate_2026-10-20.png`) inside the run folder.
- Never put restricted values in a screenshot: aggregates, counts and QC results only (D-47).
- Don't edit an output; rerun and replace it.
- A WARN in the evidence is fine when it is an expected WARN on the layer's quality page; anything else gets a note in `run-comparison.md`.

## 5. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Folder guide and capture plan for three evidence runs written |
