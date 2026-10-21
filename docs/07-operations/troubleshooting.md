# Troubleshooting

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Symptoms we have met, their usual cause and the fix. For the general procedure (read the message, look at the evidence, fix at the source, rerun downward), see the [runbook](runbook.md). Each layer's quality page has a longer "when a check fails" table: [bronze](../04-pipeline/bronze/bronze-quality-checks.md), [silver](../04-pipeline/silver/silver-quality-checks.md).

Status date: 2026-10-21.

Never fix a failure by editing a silver or gold table by hand, deleting quality rows, or loosening a check without a written reason.

---

## 1. Bronze

| Symptom | Likely cause | Fix |
|---|---|---|
| Loader says `header_check` failed | The file's title or header rows changed (new layout, shifted columns) | Compare with the YAML; if the new layout is right, update the entry (or give it its own folder and table). Rerun |
| Loader: decoding error | The file isn't in the declared encoding | Set the right `encoding` in the YAML (for example `cp1252` for PSA Table 9.9); rerun |
| B03 / B11 FAIL | A new file with a different row count or total, or a wrong YAML value | Check the file. If it's right, update `qc.expected_rows` or the control in the YAML; rerun `run_bronze.py` (the source is re-queued) |
| B13 FAIL "no processed row" / "different load" | The load-log row wasn't written, or the table holds rows from another load | Rerun `run_bronze.py`: a file with no `processed` row reloads |
| B00 FAIL "invalid override" | `qc.skip_checks` / `qc.severity` names an unknown code, B00, or a severity other than WARN / FAIL | Fix the YAML; rerun |
| Gate: NOT_CHECKED | The source has no bronze QC result (for example after resetting the quality schema) | Run `run_bronze.py` (re-queues it) or that domain's QC script |
| Gate: STALE | The source was reloaded after its last QC | Run `run_bronze.py` |
| Gate: CRASHED | A QC run of the domain errored | Read `quality.v_run_errors`; fix and rerun |
| Admin boundaries task stops: "latest HDX ingestion run incomplete" | The newest `_runs/<id>/` has no complete handoff | Finish or retry the HDX ingestion; the loader never falls back to an older run |
| Geography loader `blocked` | Another snapshot for the same PSGC version, or a logged but incomplete batch | Follow the message; delete the partial batch on purpose before reloading |
| A changed parsing setting has no effect | Setting changes aren't detected; the file is unchanged, so it's skipped | `run_bronze.py --force_keys <source>`, then rerun that domain's silver |

## 2. Silver

| Symptom | Likely cause | Fix |
|---|---|---|
| `<table> was NOT published. gates failed: ...` | A build gate is not 0 | `SELECT * FROM <table>__gates WHERE failures <> 0`; the gate name says what to fix |
| `Reference check failed: ...` in a `00_reference` step | A reviewed CSV disagrees with geography, or was built from another snapshot or workbook | Rerun the builder, review, copy the CSV to the Volume, rerun `00_reference` ([reference maps](../04-pipeline/silver/reference-maps.md)) |
| `UNRESOLVED_COLUMN ... m.source_sheet` | `bronze.ingestion_metadata` in this workspace predates the file-load columns | `ingestion_metadata_fix.sql` (run in the workspace; not kept in the repo) Part 1, rerun the loader, Part 2 ([runbook](runbook.md), incident 3) |
| S00 FAIL "build ... did not record `<key>`" | The table was built before 2026-10-19, without the recorded settings QC reads (rule 2a) | Rerun that table's build file (workforce: `01` first), then its QC |
| S16 / S33 / S63 / S83 FAIL | Bronze, a reference table or the geography snapshot changed after the build | Rebuild the domain's silver in full, then QC. After any `00_reference` rerun, rerun **every** build of that domain ([runbook](runbook.md), incident 5) |
| S09 FAIL | Bronze changed since the build, or rows are unaccounted for | Rebuild; if it persists, compare `row_disposition` with bronze ([reconciliation](../04-pipeline/silver/reconciliation.md)) |
| A silver row count drops after a rebuild, with no FAIL | New quarantined rows (S29, S73 WARN) | Query the set-aside rows (`row_disposition`, or `workforce_fhsis__resolved` for workforce); fix with a reviewed decision ([runbook](runbook.md), incident 7) |
| S29 FAIL | More than 5% and more than 10 rows of a source set aside | Read the reasons in the S29 detail; fix the map, exception or rule. Don't raise the limit without a written reason ([runbook](runbook.md), incident 2) |
| S49 FAIL | The diseases area map is older than geography silver | Rerun the reference maps, then diseases `00`–`04` |
| S59 FAIL | A new census year in the PSGC payload | Add the year and its control to `sources_population.yaml`; rerun the population QC |
| Workforce `01` gate "override not bound to the current file version" | A workbook was re-downloaded with other content | Re-check the overridden rows, update `bound_checksum` in `OVERRIDES`, rerun the builder and `00`–`03` |
| Workforce `02` / `03` gate "settings ... missing: rerun 01" | `workforce_fhsis__settings` wasn't written | Run workforce `01`, then `02` and `03` |
| OSM step: `numpy.dtype size changed` | shapely 2.1 installed with numpy 2 | Use the `geo` environment pins (`numpy<2`, `shapely<2.1`) |

## 3. Gold

| Symptom | Likely cause | Fix |
|---|---|---|
| `gates failed: silver input whose latest QC has a FAIL` | A silver input failed its latest QC | Fix and rerun that silver table and its QC first |
| `gates failed: input without a succeeded build` | A dimension this file needs wasn't built | Run the gold files in number order |
| `gates failed: <key> not in dim_<name>` | A fact row points to a key the dimension doesn't have | Fix the silver source of the key; never add a code to the dimension by hand ([runbook](runbook.md), incident 1) |
| `gold_02_dim_date` gate on `period_basis` | Silver writes a week convention the gate doesn't list | The gate must accept `iso_week` and `iso_week_ending_date` (D-44, D-46) |
| A `CAST` error in a gold file | A value silver should have parsed or flagged | Fix the silver step that produced it; don't switch to `try_cast` (AD-13) |
| G12 WARN | Gold content changed since the previous QC run | Expected after a data or rule change (detail says whether the inputs changed). On two runs with the same inputs it's a finding |
| G06 FAIL | A gold table was built before one of its inputs was rebuilt | Rerun gold in number order after the silver rebuild |

## 3a. Quality registry

| Symptom | Likely cause | Fix |
|---|---|---|
| A QC task stops with `KeyError: <code> is not an active code in public_health.quality.check_registry` | Strict registry (default since 2026-10-21): the script records a code the registry lacks | Add the code to Step 1b of `quality_registry_seed.sql`, the [check catalog](../04-pipeline/quality/quality-check-catalog.md) and the script in one PR; deploy; rerun the job (the setup job reseeds) |
| A QC task stops with `ValueError: <code> is a <layer> check; this run is <layer>` | The registry holds the code under another layer | Fix the layer in Step 1b of the seed; rerun |
| `qc_registry` task fails: `check_registry is missing or has the wrong layer for: ...` | Same causes, found after the run; data and QC results are already written | Fix the codes it names in Step 1b of the seed; the next run checks again |

## 4. Job and workspace

| Symptom | Likely cause | Fix |
|---|---|---|
| A second run waits in the queue | `max_concurrent_runs: 1` | Expected; the PSGC and HDX loaders allow one writer |
| Fresh load marked STALE right after loading | Naive timestamps read in another timezone | Timezone-aware UTC is in place since D-54; check custom scripts use it too |
| `bundle deploy` fails on a variable | `warehouse_id` not set | Set it in `databricks.yml` or pass `--var` |
| CI fails on `dev` | A lint, test, SQL-lint, secrets or hygiene job failed (CI passes on `dev` since 2026-10-21) | Run the local checks in [CI/CD and testing](ci-cd-and-testing.md) and fix what they report |

## 5. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Page written from the runbook incidents and the layer quality pages |
| 2026-10-21 | Quality registry section (strict registry, `qc_registry`); CI row updated |
