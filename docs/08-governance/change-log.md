# Change log

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Notable changes to the platform.

## 2026-10

* **2026-10-18**: Six documentation corrections verified against Databricks. (1) `mart_capacity_gap` status unified as not built, partially covered by `mart_area_service_profile` v2. (2) Dimension keys corrected in logical-data-model-and-erd.md: all PKs are BIGINT `xxhash64`; natural keys kept as columns; `data_source_key` naming; facts carry no facility key. (3) dashboard-guide.md rewritten for the eight-page v2 dashboard; dashboard references updated in runbook, findings report, known issues, analytical validation, team timeline, data dictionary, data marts. (4) Runbook QC logic corrected: a FAIL check blocks, `run_log` records ERROR. (5) Runbook admin-boundaries run selection corrected: use handoff files and `run_log`, not `build_log` (bronze is not logged there). (6) Socioeconomic silver status updated to the verified 2026-10-15 build; bundled data-gap rows split into G13-G20 (findings N3 now cites G4 and G17).
* **2026-10-18**: Scope narrowed to BQ1 only. BQ2 (dengue surge stress test) relabeled as previous scope across all documentation. Corrected BQ1 wording in conceptual-model.md to match exact supplied text. Added AD9 (BQ1 as sole main question) to decisions.md. Fixed qc_results column names in quality-results.md, runbook.md, and evidence README. Fixed old dimension names (dim_period, dim_source) in problem-and-business-context.md.
* **2026-10-18**: Documentation quality corrections. Clarified ERROR vs FAIL severity mapping in quality-control-framework.md (ERROR is the YAML config name, FAIL is the stored value in qc_results). Added admin_boundaries_run_dir identification instructions in runbook.md (check handoff files, verify the QC run via run_log, do not select newest folder; superseded same day by the verified method). Clarified dashboard coverage in dashboard-guide.md (complete dashboard does not require a page for every supporting question). Updated S3 page status in known-issues-and-backlog.md. Clarified CI/CD doc relationship between architecture summary and operations detail.
* **2026-10-18**: Final documentation audit. Verified all table schemas, row counts, and QC results against Databricks. Corrected geography_silver schema (key is psgc_code, not area_key), population_silver table name, qc_results column names, conceptual model v2 description, CI/CD OSM verification status. Updated 30+ files for consistency.
* **2026-10-15**: Full pipeline run. All silver domain tables built. All 25 gold v2 tables built in test_gold2. Build log: 114 builds, 106 succeeded. `facilities_osm_point_silver` built (16,030 rows). `facilities_bed_occupancy_silver` expanded to 9,145 rows (all years 2018-2025).
* **2026-10-15**: Final documentation completion. Wrote gold stub files (table-catalog, conceptual-model, logical-data-model-and-erd, business-data-dictionary, analytical-validation-and-traceability, findings-report, seed-data). Updated gold README to clarify v2 as active model. Updated architecture overview, lineage map, problem-and-business-context, scope, data-marts, and known-issues/backlog.
* **2026-10-15**: Documentation audit and rewrite. Root README, docs index, all context/data/architecture/pipeline/operations/governance/dashboard/evidence docs written from scratch based on actual implementation.
* **2026-10-14**: `facilities_osm_point_silver` documented per user instruction (unverified at the time; now resolved -- built 2026-10-15 with 16,030 rows).
* **2026-10-13**: `mart_area_service_profile` gold v1 mart built and validated (2,701 rows, answers S1/S2/S3).
* **2026-10-12**: Facilities silver v1.7 SQL builds ran on Databricks: metric (2,988 rows), bed occupancy (1,977 rows at that time; later expanded to 9,145 rows in 2026-10-15 build).
* **2026-10-10**: Facilities silver v1.7 SQL builds ran on Databricks: id_map (5,254 rows at that time; later 5,257 in 2026-10-15 build), registry (3,954 rows; later 3,957). Confirmed Delta, `read_files()`, and `DESCRIBE HISTORY` in subquery work on Databricks.
* **2026-10-09**: Lineage and quality contract v1.3 drafted. Quality tables created (`build_log`, `build_inputs`, `row_disposition`, views). Geography silver built (43,762 rows).
* **2026-10-06 to 2026-10-07**: Disease source configs verified against actual files.

## Earlier

* **Sep 2026**: Repository created, CI/CD pipelines set up, DABs bundle configured, schema setup.
* **Sep–Oct 2026**: Bronze loaders implemented for all domains. Earlier notebook-based silver builds (v1.5) replaced by v1.7 SQL builds.

## Key decisions

See [architecture decisions](../03-architecture/decisions.md) for the rationale behind major design choices.
