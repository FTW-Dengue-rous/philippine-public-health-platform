# LUNASaan? Philippine Public Health Platform

**Status: engineering and documentation scaffold.** `main` does not contain an end-to-end implemented or evidenced pipeline. Do not use it for public-health decisions or claim dashboard results from it.

LUNASaan? is intended to help Philippine health planners compare recorded service availability, population, selected disease indicators, and socioeconomic context at a consistent geographic level.

## Active business question

**BQ1:** Which areas show the largest gaps in recorded health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

Users are DOH, LGUs, and health-policy teams planning facilities, staff, primary care, and outbreak readiness. BQ1 is descriptive: association is not causation, a listed facility does not prove capacity, and registry absence does not prove no facility exists.

## Start here

- [Documentation index](docs/README.md)
- [Business question and interpretation limits](docs/business_questions.md)
- [Source register](docs/data_sources.md)
- [Data dictionary](docs/data_dictionary.md)
- [Architecture and lineage](docs/architecture.md)
- [Runbook and verification](docs/runbook.md)
- [Implementation status and handover](docs/implementation-status.md)

## Current implementation status

| Area | Current state | Evidence |
|---|---|---|
| Source registration | PSGC is configured | `config/sources.yaml` |
| Databricks setup | One schema-create script is present | `setup/01_create_schemas.sql` |
| Layers | Folder scaffold only | `src/` |
| Automated checks | Structural smoke test and CI configuration | `tests/test_smoke.py`, `.github/workflows/ci.yml` |
| End-to-end data build | Not implemented or evidenced | See [implementation status](docs/implementation-status.md) |

## Evidence rules

- Do not commit restricted, patient-level, or full source data.
- A passing repository test is not proof of data quality, idempotency, recovery, freshness, or dashboard correctness.
- Record source version, retrieval date, geography, transformations, QC results, and reconciliation output before publishing a result.
- Missing is not zero unless the source explicitly says so.
