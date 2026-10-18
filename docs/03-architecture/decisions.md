# Architecture decisions

Owner: Jemma Santiago
Last updated: 2026-10-18

Key decisions and their rationale.

## AD1: Medallion architecture (bronze → silver → gold)

**Decision**: Use a three-layer medallion architecture on Delta Lake.

**Rationale**: Separates raw preservation (bronze), business logic (silver), and analytical serving (gold). Bronze is never modified, so source data is always traceable. Silver applies cleaning and matching. Gold is optimized for dashboard queries.

## AD2: Config-driven bronze loaders

**Decision**: One Python script per domain reads a YAML config and loads all sources for that domain.

**Rationale**: Adding a new source means adding a YAML entry, not writing new code. The loader handles header modes, column naming, encoding, and ingestion-contract checks (header_check, required_columns).

## AD3: SQL for silver and gold

**Decision**: Silver and gold builds are pure SQL scripts, not Python notebooks.

**Rationale**: SQL is declarative, reviewable, and runs on the serverless SQL warehouse. It avoids the notebook execution issues encountered with earlier Python-based silver builds (v1.5). The lineage contract (v1.3) is implemented in SQL.

## AD4: Databricks Asset Bundles for deployment

**Decision**: Deploy via DABs (`databricks.yml`), not manual job creation.

**Rationale**: Bundles are version-controlled, reproducible, and integrate with CI/CD. The bundle sync excludes `archive/`, `docs/`, `data/`, `tests/`, and ingestion notebooks — only the pipeline code is deployed.

## AD5: NHFR as the registry spine

**Decision**: Use NHFR hospitals as the facility registry base and match HFSRB licensed lists to it.

**Rationale**: NHFR is the most comprehensive facility registry. Matching by NHFR code (numeric) and by normalized name + municipality provides the best coverage. HFSRB-only facilities are added as separate rows.

## AD6: Lineage stored per build, not per row

**Decision**: Load-time facts (batch id, checksum, build time) go in `build_inputs` and `build_log`, not on every silver row.

**Rationale**: These facts are identical for every row of one file in one build. Storing them once reduces columns without losing traceability. A join on `_silver_build_id` recovers them when needed. See [lineage contract](../lineage-qc-contract_v1.3.md) section 3.3.

## AD7: PSGC Q2 2024 as the reference geography

**Decision**: All geographic matching uses PSA PSGC Q2 2024.

**Rationale**: PSGC codes change over time. Using one snapshot as the reference ensures consistent joins. Unmatched names are logged as exceptions, not silently dropped.

## AD8: Serverless compute with two environments

**Decision**: Use serverless Spark for Python tasks and serverless SQL warehouse for SQL tasks. Two environments: `default` (no geometry library) and `geo` (shapely for point-in-polygon).

**Rationale**: Serverless avoids cluster management. The `geo` environment pins shapely<2.1 because shapely 2.1 requires numpy 2, which breaks pandas in other tasks.

## AD9: BQ1 as sole main business question

**Decision**: BQ1 (capacity gap analysis) is the platform's only main business question. BQ2 (dengue surge stress test) is previous scope.

**Rationale**: The platform was originally designed for two main questions. The team narrowed the final scope to BQ1 to focus on the capacity gap analysis deliverable. BQ2 datasets and marts are preserved in the documentation and pipeline code because they may support future re-scoping. D1 (dengue wave selection) remains queryable via `mart_dengue_peak_capacity`, which also serves N3 within BQ1. The scope change does not make BQ1 fully answered: disease burden integration into the capacity gap mart is still pending.
