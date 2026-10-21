# Bronze — facilities

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

The facilities bronze loader lands the configured registry, published-statistics, OSM, FHSIS, and approved FOI files without changing business values. It writes string-preserving source tables in `public_health.bronze`; matching, typing, and deduplication belong to the [silver facilities layer](../silver/facilities.md).

## Inputs and execution

The source list, paths, file formats, header rules, and source-level controls are authoritative in [`config/sources_facilities.yaml`](../../../config/sources_facilities.yaml). Run the loader through the pipeline job or:

```bash
python src/02_bronze/run_bronze.py --domains facilities
```

The configured sources include DOH NHFR and HFSRB registries, PSA published facility and bed series, HDX Healthsites, FHSIS demographic workbooks, and two approved FOI extracts. Source dates, coverage, and access restrictions are documented in [data sources](../../02-data/data-sources.md).

## Loader and quality behaviour

- New or changed files are detected by content checksum. Unchanged files retain their load identity.
- Source values land as strings. Bronze retains file, sheet, row, source key, as-of date, ingestion time, and rescued-data lineage fields.
- The YAML controls required columns, numeric and row-count checks, and source-specific control totals. A blocking bronze QC failure stops the domain gate.
- Use `--plan true` before a run to inspect planned work. Use `--force_keys <source_key>` only after a parsing or configuration change, then rebuild facilities silver.

The complete check semantics and recovery steps are in [bronze quality checks](bronze-quality-checks.md) and the [runbook](../../07-operations/runbook.md).

## Restricted inputs and limits

Only the FOI bed-occupancy and hospital-bed extracts are restricted. Keep them in the approved restricted landing path and do not add them to Git or a distributable bundle. Other source restrictions can differ; see [data governance](../../08-governance/data-governance.md).

Bronze records that a source file was loaded. It does not establish that a facility exists, is operating, or offers a service. In particular, an OSM or registry omission does not prove absence.
