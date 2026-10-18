# Change log

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Notable changes to the platform.

## 2026-10

* **2026-10-15**: Final documentation completion. Wrote 7 gold stub files (table-catalog, conceptual-model, logical-data-model-and-erd, business-data-dictionary, analytical-validation-and-traceability, findings-report, seed-data). Updated gold README to clarify v2 as active model. Updated architecture overview, lineage map, problem-and-business-context (full BQ framework), scope, data-marts, and known-issues/backlog. All gold docs now reflect data model v2 (test_gold2 schema). Produced final deliverables: change summary, rubric coverage table, validation results, handover checklist.
* **2026-10-15**: Documentation audit and rewrite. Root README, docs index, all context/data/architecture/pipeline/operations/governance/dashboard/evidence docs written from scratch based on actual implementation.
* **2026-10-14**: `facilities_osm_point_silver` documented per user instruction (unverified — table not found on Databricks).
* **2026-10-13**: `mart_area_service_profile` gold mart built and validated (~2,784 rows, answers S1/S2/S3).
* **2026-10-12**: Facilities silver v1.7 SQL builds ran on Databricks: metric (2,988 rows), bed occupancy (1,977 rows).
* **2026-10-10**: Facilities silver v1.7 SQL builds ran on Databricks: id_map (5,254 rows), registry (3,954 rows). Confirmed Delta, `read_files()`, and `DESCRIBE HISTORY` in subquery work on Databricks.
* **2026-10-09**: Lineage and quality contract v1.3 drafted. Quality tables created (`build_log`, `build_inputs`, `row_disposition`, views). Geography silver built (43,762 rows).
* **2026-10-06 to 2026-10-07**: Disease source configs verified against actual files.

## Earlier

* **Sep 2026**: Repository created, CI/CD pipelines set up, DABs bundle configured, schema setup.
* **Sep–Oct 2026**: Bronze loaders implemented for all domains. Earlier notebook-based silver builds (v1.5) replaced by v1.7 SQL builds.

## Key decisions

See [architecture decisions](../03-architecture/decisions.md) for the rationale behind major design choices.
