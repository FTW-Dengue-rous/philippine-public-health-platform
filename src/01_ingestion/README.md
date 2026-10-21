# Ingestion

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Reference-data ingestion notebooks for geography and boundaries. Run by hand before the pipeline job.

Files:
1. `psgc_ingestion` — loads the PSA PSGC reference geography into bronze.
2. `admin_boundaries_ingestion` — loads HDX administrative boundaries into bronze.

These notebooks are not part of the job task list. Run them by hand after landing the source files.

Docs: [data sources](../../docs/02-data/data-sources.md), [PSGC ingestion](../../docs/04-pipeline/bronze/psgc-ingestion.md).
