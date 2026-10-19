# Silver rebuild strategy

Why silver rebuilds its tables in full, what that costs, and how to cut the cost later.

Status date: 2026-10-19. Decision: D-57 (replaces the "per-source rebuild next" plan in AD-15). Back to the [silver overview](README.md).

---

## 1. Summary

- Every silver **observation table** is rebuilt in full on every run, through write-audit-publish: build a candidate, gate it, then replace the published table.
- **We planned two optimisations and decided not to do them for now:** per-source incremental rebuild and table layout tuning (`OPTIMIZE`, Z-order, partitioning). No silver domain is near a million rows, so both would cost more effort or compute than they save. Both move to the recommendations (section 3a and section 6).
- The real cost problem is not row volume. Our sources change rarely, so most runs rebuild silver and gold from **unchanged** inputs.
- The cheapest fix is to **skip silver and gold when nothing changed** (R1). Per-source incremental (R3) comes last, when a domain reaches millions of rows.

## 2. How silver runs today

| Pattern | Tables | On every run |
|---|---|---|
| Full rebuild (write-audit-publish) | `population_silver`; diseases `01`–`06`; facilities `00a`, `02`, `03`, `04`; workforce `02`–`04`; socioeconomic `01`–`04` | Read all bronze rows of the table's sources, rebuild, gate, replace. New `_silver_build_id` and `build_log` row |
| MERGE, keyed | `geography_silver` (`psgc_code + content_checksum`), `admin_boundaries_silver` (per `source_version`) | Unchanged input gives 0 inserts and 0 updates |
| Rebuild with state carried forward | `facilities_id_map_silver`, `facilities_registry_silver` | Reads its previous version so `facility_key` values stay the same |

One job run, end to end:

| Layer | Behaviour |
|---|---|
| Bronze | **Incremental.** The loader compares each file's checksum with the load log and loads only new or changed files |
| Silver | **Full rebuild** of every observation table, whether or not its bronze changed |
| Gold | **Full rebuild** of every dimension, fact and mart |
| QC | Runs on every published table |

## 3. Why we keep the full rebuild

| Reason | What it means in practice |
|---|---|
| **Checks cover the whole table** | The candidate is the full table, so each gate (key unique, rows read = rows loaded + rows set aside, control totals, cross-source checks such as S40–S44) checks everything that will be published. Incremental builds need per-source gates **plus** cross-source gates on a table that mixes old and new builds |
| **A rule change reaches every row** | Some changes alter the meaning of rows that already exist. Example: D-44 gave every weekly dengue row new dates, a new basis and possibly a new year. A full rebuild applies the rule everywhere at once. An incremental build would leave old rows on the old rule until someone forces them |
| **Idempotent by construction** | The same bronze gives the same rows. Only `_silver_build_id` changes |
| **Simple recovery** | A failed gate leaves the published table untouched; the last good version stays in Delta history |
| **Volume is small** | Diseases silver held about 565k rows (claims about 244k) when checked on 2026-10-16. A full Delta rewrite at this size is not the slow part |
| **Sources change rarely** | Files are annual, monthly or weekly series published as releases, plus FOI files that arrive every few months. Bronze already skips unchanged files |

## 3a. Considered and deferred (row volume under a million)

These were planned after the capstone. The team decided not to build them now because every silver domain is well under a million rows (diseases, the largest, held about 565k rows on 2026-10-16; claims about 244k). They stay in the recommendations for when volume grows.

| Option | What it would do | Why not now | Revisit when |
|---|---|---|---|
| Per-source incremental rebuild (R3) | Rebuild only the changed `_source_key` with `replaceWhere` | Needs per-source and cross-source gates, scoped QC and an equality test against a full rebuild, for a moderate saving at this size. A rule change like D-44 would still need a full rebuild | A domain reaches millions of rows, or one silver task becomes the slowest part of the run |
| `OPTIMIZE` / Z-order (R5) | Compact small files and co-locate rows for faster reads | Tables are a few files each. Running it costs compute and gives no measurable read gain at this size | Tables reach millions of rows, or queries on one table get slow |
| Partitioning by `_source_key` (R5) | Split tables into folders per source | Small tables split into many small files, which makes reads slower, not faster. Only useful together with R3 | Built together with R3 |

## 4. Limitations of this choice

| ID | Limitation | Effect |
|---|---|---|
| RS-1 | Every run rebuilds every silver and gold table, even when no bronze file changed | Compute is spent on unchanged work. With a weekly schedule, most runs would process identical inputs |
| RS-2 | One new file rebuilds its whole table | A new FOI file for one source rebuilds every source in `diseases_metric_silver` |
| RS-3 | Rewrite cost grows with the **total** rows, not the **new** rows | Fine today. It does not scale to millions of rows per domain |
| RS-4 | Nothing skips a run automatically | The schedule in the job YAML is commented out, so runs are manual today. Switching it on without R1 multiplies RS-1 |
| RS-5 | Where the run time goes is not measured per task | Full runs on 2026-10-16 and 2026-10-17 took about 65–70 minutes including bronze. The task timeline was not broken down, so measure it before optimising |

## 5. When to revisit

| Trigger | Do |
|---|---|
| The job should run automatically | R0 (file-arrival trigger) first; R1 only if a fixed schedule is kept |
| Sources start arriving often (monthly or weekly feeds) | R1, then R2 |
| A domain table reaches millions of rows, or one silver task becomes the slowest part of the run | R3 for that domain, with R5 |

## 6. Recommendations, in order

| # | What | How | Saving | Effort |
|---|---|---|---|---|
| **R0** | **Job settings only (YAML, no code)** | (a) `trigger.file_arrival` on the landing path instead of a schedule, so the job runs only when a new file lands; code or rule changes still need a manual run. (b) `performance_target: STANDARD` for the serverless Python tasks; the SQL warehouse at the smallest size with a short auto-stop | Large for no-change runs; lower DBUs per run | 1 hour |
| **R1** | **Skip silver and gold when nothing changed** | After the bronze gates, a `change_check` task compares each domain's current bronze inputs (file, sheet, load time) with the `build_inputs` of its latest succeeded silver build (the logic of the freshness checks S16, S33, S63, S83). It sets a task value `has_changes`. A Databricks `condition_task` runs silver, gold and QC only when it is true. A `force_rebuild` job parameter overrides it, because a code or rule change (like D-44) must rebuild without new data | Largest: a no-change run costs bronze plus one check | 0.5–1 day |
| **R2** | **Per-domain skip** | The same check per domain. Each domain's silver chain runs only when its bronze changed. Gold reads across domains, so gold stays a full rebuild whenever any silver table changed | Large | 1 day |
| **R3** | **Per-source incremental inside a domain** (diseases first) | Rebuild unit = `_source_key` (+ `_source_file`), written with Delta `replaceWhere`; `diseases_metric_silver` partitioned by `_source_key`. Per-source gates on the candidate, cross-source gates (S40–S44) on the published table. `diseases_source_coverage_silver` recomputes only the changed sources. QC S09 and S33 scoped to the rebuilt sources. `build_log` and `build_inputs` record which sources a build touched. Not MERGE on the business key: per-source replace keeps the rows read = rows loaded + rows set aside accounting ([reconciliation](reconciliation.md)) | Moderate today; grows with volume | 2–3 days |
| **R4** | Pin inputs | Read bronze with `VERSION AS OF` from `build_inputs` and pass `{{job.run_id}}` as the build id. Helps R1–R3 prove exactly what each build read | Correctness, not cost | 1 day |
| **R5** | Table layout tuning | `OPTIMIZE` (and Z-order on the common filter columns) for tables that reach millions of rows; partition by `_source_key` only together with R3. Deferred by decision, see section 3a | Read speed at volume; none today | 0.5 day |

Rules for R3, if it is built:

1. A rule or code change always goes through a full rebuild (`force_rebuild`), never through an incremental run.
2. Acceptance test: on the same inputs, the incremental result equals the full-rebuild result, row for row (all columns except `_silver_build_id`).

## 7. For the presentation

> Silver rebuilds its tables in full on purpose. At our volume the rebuild is cheap, every check sees the whole table, and a rule change reaches every row at once. The real waste would be rebuilding unchanged data on a schedule, so the first optimisation is to skip silver and gold when no bronze file changed. We had planned per-source incremental builds and table tuning such as `OPTIMIZE` and partitioning, but every domain is still under a million rows, so we deferred them to the recommendations for when volume grows.

## 8. History of updates

| Date | Change |
|---|---|
| 2026-10-16 | Full rebuild kept for the capstone; per-source incremental planned next (AD-15) |
| 2026-10-19 | Per-source incremental moved to recommendations; cost order R1 → R4 set (D-57). Page written |
| 2026-10-19 | Section 3a: per-source incremental and `OPTIMIZE` / Z-order / partitioning recorded as planned, then deferred because volume is under a million rows; R5 added |
| 2026-10-19 | R0 added: file-arrival trigger and serverless standard mode (job YAML only) |
| 2026-10-19 | Back link to the silver overview; R3 links the reconciliation page |