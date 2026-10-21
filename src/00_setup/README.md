# Setup

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Schema and quality table DDL for the `public_health` catalog. Runs as the `setup` job task before the pipeline.

Files in run order:
1. `schema_setup.sql` — creates the `public_health` catalog and schemas (bronze, silver, gold, quality).
2. `ingestion_metadata.sql` — creates `bronze.ingestion_metadata` for file-load tracking.
3. `quality_setup.sql` — creates the `quality` schema tables (build_log, build_inputs, qc_results, run_log, row_disposition, check_registry).

Job task: `setup` (runs `ph_public_health_setup_job.yml`).

Docs: [setup guide](../../docs/07-operations/setup-guide.md).
