# Handover checklist and final deliverables

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

This document consolidates the final documentation deliverables: a change summary, rubric coverage table, validation results, unresolved gaps, and a handover checklist for the receiving team.

Update 2026-10-18: the pipeline has since been executed end to end in the current workspace (see the [2026-10-18 run record](docs/06-evidence/2026-10-18-new-workspace-run.md)). Sections 1-3 below describe the 2026-10-15 documentation session and have been updated where verification results changed.

---

## 1. Change summary

### What changed in this session

* Wrote 7 gold documentation files that were previously stubs: [table-catalog](docs/04-pipeline/gold/table-catalog.md), [conceptual-model](docs/04-pipeline/gold/conceptual-model.md), [logical-data-model-and-erd](docs/04-pipeline/gold/logical-data-model-and-erd.md), [business-data-dictionary](docs/04-pipeline/gold/business-data-dictionary.md), [analytical-validation-and-traceability](docs/04-pipeline/gold/analytical-validation-and-traceability.md), [findings-report](docs/04-pipeline/gold/findings-report.md), [seed-data](docs/04-pipeline/gold/seed-data.md).
* Updated [gold README](docs/04-pipeline/gold/README.md) to clarify data model v2 as the active model.
* Updated [architecture overview](docs/03-architecture/architecture-overview.md) to mention the gold model and `public_health.gold` schema (then `test_gold2`, renamed 2026-10-19).
* Updated [lineage map](docs/02-data/lineage-map.md) to reference v2 gold scripts instead of v1.
* Integrated the full business question framework (BQ1, BQ2, N1-N4, S1-S2, A1-A2, W1-W2, E1-E2, P1-P2, D1-D5, SUP1-SUP6, CON1-CON3) into [problem-and-business-context](docs/01-context/problem-and-business-context.md), [scope](docs/01-context/scope.md), [data-marts](docs/04-pipeline/gold/data-marts.md), root [README](README.md), and [known-issues-and-backlog](docs/08-governance/known-issues-and-backlog.md).
* Updated [change log](docs/08-governance/change-log.md).

### What did NOT change

* No pipeline code, SQL scripts, Python loaders, YAML configs, or job definitions were modified.
* No pipeline was deployed or run.
* No data was modified.

---

## 2. Rubric coverage table

| Criterion | Weight | Where it is documented | Evidence |
|---|---|---|---|
| Problem and data understanding | 10% | [problem-and-business-context](docs/01-context/problem-and-business-context.md) (problem, users, BQ framework), [data-sources](docs/02-data/data-sources.md) (source catalog), [assumptions-and-limitations](docs/01-context/assumptions-and-limitations.md), [glossary](docs/01-context/glossary.md), [data-gaps](docs/02-data/data-gaps.md) | Source configs in `config/`, YAML `as_of_date` fields, data-gaps table G1-G12 |
| Data architecture and pipeline design | 15% | [architecture-overview](docs/03-architecture/architecture-overview.md) (tech stack, data flow, orchestration), [project-conventions](docs/03-architecture/project-conventions.md), [decisions](docs/03-architecture/decisions.md) (AD1-AD8), [bronze README](docs/04-pipeline/bronze/README.md), [silver README](docs/04-pipeline/silver/README.md), [gold README](docs/04-pipeline/gold/README.md), [table-catalog](docs/04-pipeline/gold/table-catalog.md), [logical-data-model-and-erd](docs/04-pipeline/gold/logical-data-model-and-erd.md) | `databricks.yml`, `resources/ph_public_health_job.yml` (task dependencies), `src/` directory structure |
| Data transformation and quality | 10% | [quality-control-framework](docs/04-pipeline/quality/quality-control-framework.md), [quality-check-catalog](docs/04-pipeline/quality/quality-check-catalog.md), [quality-results](docs/04-pipeline/quality/quality-results.md), [silver quality checks](docs/04-pipeline/silver/silver-quality-checks.md), [lineage-qc-contract](docs/lineage-qc-contract_v1.3.md), [gold-usage-rules](docs/04-pipeline/gold/gold-usage-rules.md) | `src/05_quality/` scripts, `dq_utils.py`, quality tables in `public_health.quality.*` |
| Implementation and reproducibility | 10% | [setup-guide](docs/07-operations/setup-guide.md), [runbook](docs/07-operations/runbook.md), [reproducibility](docs/07-operations/reproducibility.md), [ci-cd-and-testing](docs/07-operations/ci-cd-and-testing.md), [seed-data](docs/04-pipeline/gold/seed-data.md) | Build logs in `public_health.quality.build_log`, idempotency comparison in [evidence](docs/06-evidence/idempotency/comparison.md) |
| Documentation quality | 5% | [docs README](docs/README.md) (index with reading paths), root [README](README.md), all docs linked, [glossary](docs/01-context/glossary.md), [business-data-dictionary](docs/04-pipeline/gold/business-data-dictionary.md), [metric-definitions](docs/04-pipeline/gold/metric-definitions.md), [assumptions-and-limitations](docs/01-context/assumptions-and-limitations.md) | This file, all cross-links validated |

---

## 3. Validation results and unresolved gaps

### Validated

| Item | Method | Result |
|---|---|---|
| All docs are non-empty | Read every file in `docs/` | No stubs, no empty sections, no placeholders |
| Gold model documented | Read `src/04_gold/` scripts and gold README | 5 dims, 4 facts, 4 reference, 11 marts, build order documented |
| Business question framework | User-provided BQ table | Integrated into 5 docs with status and caveats |
| Cross-references consistent | Checked table names, script names, schema names across docs | Lineage map updated to v2, gold README updated, architecture overview updated |
| Source catalog matches configs | Cross-checked `data-sources.md` against YAML files in `config/` | All source keys, formats, and coverage match |
| Quality checks match implementation | Cross-checked `quality-check-catalog.md` against `src/05_quality/` scripts | Check IDs (B02-B14, S01-S06, X01-X04, G01-G03) match |
| Row counts match evidence | Cross-checked runbook, evidence README, quality results, silver README | All verified row counts consistent across docs |

### Unresolved gaps

| Gap | What is missing | Impact | Where documented |
|---|---|---|---|
| `facilities_osm_point_silver` | Resolved 2026-10-18: built by the bundle-job run (16,030 rows; Delta history and QC verified) | None | [2026-10-18 run record](docs/06-evidence/2026-10-18-new-workspace-run.md) |
| Gold QC checks | Resolved 2026-10-19: `gold_qc.py` now implements 14 checks (G00-G13) writing to `qc_results` (KI11 resolved) | Gold data quality is automatically validated after the last gold build | [known issues](docs/08-governance/known-issues-and-backlog.md) KI11 (resolved) |
| `mart_capacity_gap` (BQ1) | Not built; needs province/HUC/NCR analysis unit | BQ1 main question not answered | [data-marts](docs/04-pipeline/gold/data-marts.md), [backlog](docs/08-governance/known-issues-and-backlog.md) |
| `mart_surge_stress_test` (BQ2) | Not built; needs admission share and LOS parameters | BQ2 main question not answered | [data-marts](docs/04-pipeline/gold/data-marts.md), [backlog](docs/08-governance/known-issues-and-backlog.md) |
| Dashboard S3 page | Resolved: S3 is covered via the Access page (registry-based presence) | Full FHSIS BHS/RHU counts remain query-only | [dashboard-guide](docs/05-dashboard/dashboard-guide.md) |
| FOI ticket numbers | Marked CONFIRM in FOI log | Provenance incomplete for 3 FOI requests | [foi-data-request-log](docs/02-data/foi-data-request-log.md) |
| Handover walkthrough | Not conducted | Cannot claim handover is tested | [team-and-timeline](docs/08-governance/team-and-timeline.md#handover-readiness) |
| Prod service principal | `databricks.yml` has TODO for SP UUID | Prod deployment cannot run | [setup-guide](docs/07-operations/setup-guide.md) |
| Income class cleaning | Values like "4th*", "1st (as Mun)" need normalization | E2 cannot be answered cleanly | [backlog](docs/08-governance/known-issues-and-backlog.md) |
| Age dimension in gold | No `dim_age_group` in v2 model | SUP1 cannot be answered | [backlog](docs/08-governance/known-issues-and-backlog.md) |

---

## 4. Handover checklist for the receiving team

### Access and accounts

- [ ] Confirm Databricks workspace access (URL, account).
- [ ] Confirm Unity Catalog permissions on `public_health` catalog (USE CATALOG, SELECT on bronze/silver/gold/quality).
- [ ] Confirm landing volume access: `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`.
- [ ] Confirm GitHub repository access: `FTW-Dengue-rous/philippine-public-health-platform`.
- [ ] Add receiving team members to `databricks.yml` prod target permissions.
- [ ] Set up GitHub Environment secrets for CD (`DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET`).
- [ ] Resolve the prod service principal UUID (currently TODO in `databricks.yml`).

### Reproduce the pipeline

- [ ] Clone the repository locally.
- [ ] Run `pip install -r requirements-dev.txt` and `pre-commit install`.
- [ ] Run `databricks bundle deploy -t dev`.
- [ ] Set the `admin_boundaries_run_dir` job parameter to the latest ingestion run folder.
- [ ] Run the pipeline job: `databricks jobs run-now --job-name ph-public-health-pipeline`.
- [ ] Before running, confirm the other pipeline job (bundle-deployed) is idle; concurrent runs race on shared tables (KI12).
- [ ] Verify all tasks succeeded (green in Jobs UI).
- [ ] Check row counts match [runbook expected outputs](docs/07-operations/runbook.md#expected-outputs).
- [ ] Check `SELECT * FROM public_health.quality.qc_results WHERE status = 'FAIL'` returns no rows (a failed check stores status = FAIL; WARN does not block).
- [ ] Open the Lakeview dashboard and confirm all eight pages show data.

### Understand the system

- [ ] Read the [docs index](docs/README.md) and follow the business user reading path.
- [ ] Read the [architecture overview](docs/03-architecture/architecture-overview.md).
- [ ] Read the [runbook](docs/07-operations/runbook.md) and understand execution order.
- [ ] Read the [metric definitions](docs/04-pipeline/gold/metric-definitions.md) and interpret a dashboard page.
- [ ] Read the [assumptions and limitations](docs/01-context/assumptions-and-limitations.md) and understand what the data can and cannot tell you.

### Routine operation

- [ ] Understand how to run the pipeline (see [runbook](docs/07-operations/runbook.md)).
- [ ] Know how to check QC results after each run.
- [ ] Know how to ingest new PSGC snapshots (quarterly) and admin boundaries (when HDX updates).
- [ ] Know how to update a source file (see [data governance](docs/08-governance/data-governance.md#how-to-update-sources)).
- [ ] Know how to add a new source (YAML entry + landing file + bronze + silver).

### Troubleshooting

- [ ] Read the [troubleshooting guide](docs/07-operations/troubleshooting.md).
- [ ] Know how to diagnose a bronze header check failure.
- [ ] Know how to diagnose a silver validation gate failure.
- [ ] Know how to handle the admin boundaries blank parameter.
- [ ] Know how to handle the numpy/shapely environment issue.
- [ ] Know who to escalate to (see [troubleshooting escalation table](docs/07-operations/troubleshooting.md#escalation)).

### Recovery

- [ ] Know that rerunning the full pipeline is safe (bronze is incremental, silver/gold use CREATE OR REPLACE).
- [ ] Know how to force-reload bronze after a config change.
- [ ] Know how to use Delta time travel to roll back a silver table.
- [ ] Know how to trace a row from gold to source (see [analytical validation](docs/04-pipeline/gold/analytical-validation-and-traceability.md#how-to-trace-a-row)).

### Known issues to address

- [x] `facilities_osm_point_silver` verified (16,030 rows, built 2026-10-18).
- [ ] Verify gold fact table row counts and content.
- [x] S3 is covered via the Access page (registry-based presence). Full FHSIS BHS/RHU counts remain query-only.
- [ ] Confirm FOI ticket numbers.
- [ ] Clean income class values for E2.
- [ ] Build `mart_capacity_gap` (BQ1 main mart).
- [ ] Source BQ2 parameters (admission share, LOS).
- [ ] Add age group dimension for SUP1.
- [ ] Set up a pipeline schedule when moving to prod.

### Handover validation

A formal handover walkthrough has not been conducted. To validate handover:
1. Ask a new engineer to follow the [setup guide](docs/07-operations/setup-guide.md) to deploy and run the pipeline.
2. Ask them to use the [runbook](docs/07-operations/runbook.md) to verify the latest run.
3. Ask them to interpret a dashboard page using the [dashboard guide](docs/05-dashboard/dashboard-guide.md) and [metric definitions](docs/04-pipeline/gold/metric-definitions.md).
4. Ask them to find recovery instructions in [troubleshooting](docs/07-operations/troubleshooting.md).
5. Record any unclear steps and fix them.

Do not claim that client handover has been tested unless this walkthrough is completed and recorded.