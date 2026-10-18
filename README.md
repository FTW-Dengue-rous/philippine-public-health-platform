# Philippine Public Health Platform

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

A data platform on Databricks that brings Philippine public health data — facilities, diseases, workforce, socioeconomic indicators, and geography — into a unified, quality-checked warehouse. It answers supply-side questions about hospital availability, bed occupancy, and primary care capacity across the country's planning areas.

Built by team **ftw-dengue-rous** as an FTW Data Engineering Capstone project.

---

## Quick start

```bash
# 1. Clone and set up local checks
pip install -r requirements-dev.txt
pre-commit install

# 2. Deploy the pipeline to Databricks (dev target)
databricks bundle deploy -t dev

# 3. Run the pipeline job in the Databricks UI or CLI
databricks jobs run-now --job-name ph-public-health-pipeline
```

See [Setup guide](docs/07-operations/setup-guide.md) for prerequisites, permissions, and full configuration.

## What this platform does

The platform ingests publicly available and FOI-released data from DOH, PSA, UP NOAH, HDX, IHME, and other sources, processes it through a medallion architecture (bronze → silver → gold), and serves analytical marts and a dashboard for public health planning.

**The main business question:**

* **BQ1** — Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions? (capacity gap analysis)

A previous-scope question, outside the active scope (blocked on admission-share and length-of-stay parameters):

* **BQ2** — If a selected historical dengue outbreak recurred against the latest available hospital capacity, which regions or provinces would face the greatest estimated bed shortfalls under different assumptions? (dengue surge stress test; previous scope)

BQ1 breaks down into pillars: Need (N1-N4), Supply (S1-S3), Access (A1-A2), Workforce (W1-W2), Equity (E1-E2), Priority (P1-P2), plus supporting (SUP1-SUP6) and conditional (CON1-CON3) analyses.

**Currently built and on the dashboard:**

* **S1** — How do hospital counts and authorized beds relative to population vary across areas, by level and ownership?
* **S2** — How does bed occupancy differ across areas and between government and private hospitals?
* **S3** — How does reported BHS, RHU, and health-centre availability relative to population vary across provinces and cities?

See [business questions](docs/01-context/problem-and-business-context.md#analytical-questions) for the full framework with grain, sources, status, and caveats per question.

## Architecture at a glance

```
Sources (DOH, PSA, HDX, UP NOAH, IHME, FOI)
    │
    ▼
Landing volume (CSV / Excel / GeoJSON)
    │
    ▼
Bronze  ── public_health.bronze    (raw, all-string, config-driven loaders)
    │         + bronze QC (stops on ERROR)
    ▼
Silver  ── public_health.silver   (cleaned, typed, matched, lineage-tracked)
    │         + silver QC + cross-domain QC
    ▼
Gold    ── public_health.test_gold2 (v2 analytical model, active) + public_health.gold (v1, legacy)
    │
    ▼
Dashboard (Lakeview) + Unity Catalog serving
```

Catalog: `public_health` · Schemas: `bronze`, `silver`, `gold` (v1, legacy), `test_gold2` (v2, active), `quality`

Full architecture: [Architecture overview](docs/03-architecture/architecture-overview.md)

## Project status

| Domain | Bronze | Silver | Gold | Dashboard |
|---|:---:|:---:|:---:|:---:|
| Geography (PSGC, admin boundaries) | Yes | Yes | Yes | — |
| Facilities (NHFR, HFSRB, PSA, FHSIS) | Yes | Yes | Yes | Draft |
| Diseases (dengue, TB, cancer) | Yes | Yes | Yes | — |
| Workforce (FHSIS, PSA, PSMO) | Yes | Yes | Yes | — |
| Socioeconomic (poverty, expenditure) | Yes | Yes | Yes | — |

Yes = implemented and verified on Databricks. The full pipeline (bronze, silver, gold v2) was verified end to end on 2026-10-18 in the current workspace; see the [run record](docs/06-evidence/2026-10-18-new-workspace-run.md). See [Known issues and backlog](docs/08-governance/known-issues-and-backlog.md) for caveats.

## Key limitations

* **Restricted data**: Bed occupancy and some FOI-released data carry sharing restrictions. See [Data governance](docs/08-governance/data-governance.md).
* **Reference year matters**: Sources span different years (2018–2025). Never compare partial years with full years without adjustment. See [Assumptions and limitations](docs/01-context/assumptions-and-limitations.md).
* **Geographic comparability**: PSGC codes change over time. The platform uses PSA PSGC Q2 2024 as the reference geography. Area names that do not match are logged as exceptions. See [Data gaps](docs/02-data/data-gaps.md).
* **Recorded ≠ absent**: A facility not listed in a registry does not prove it does not exist. See [Assumptions and limitations](docs/01-context/assumptions-and-limitations.md).
* **OSM coverage is community-maintained**: `facilities_osm_point_silver` exists (16,030 rows, built 2026-10-18), but absence from OSM does not prove a facility does not exist. See [Known issues](docs/08-governance/known-issues-and-backlog.md).

## Documentation

Full documentation lives in [`docs/`](docs/README.md). Key entry points:

* **New to the project?** -> [Business context](docs/01-context/problem-and-business-context.md) -> [Data sources](docs/02-data/data-sources.md) -> [Architecture](docs/03-architecture/architecture-overview.md)
* **Want to run the pipeline?** -> [Setup guide](docs/07-operations/setup-guide.md) -> [Runbook](docs/07-operations/runbook.md)
* **Maintaining the platform?** -> [Architecture](docs/03-architecture/architecture-overview.md) -> [CI/CD and testing](docs/07-operations/ci-cd-and-testing.md) -> [Troubleshooting](docs/07-operations/troubleshooting.md)
* **Using the dashboard?** -> [Dashboard guide](docs/05-dashboard/dashboard-guide.md) -> [Metric definitions](docs/04-pipeline/gold/metric-definitions.md)
* **Lineage and quality contract** -> [lineage-qc-contract_v1.3.md](docs/lineage-qc-contract_v1.3.md)
* **Handover** -> [Handover checklist](handover-checklist.md)
* **Verified execution** -> [Evidence: 2026-10-18 full pipeline run](docs/06-evidence/2026-10-18-new-workspace-run.md)

## Repository layout

```
src/
  00_setup/          Schema and quality table DDL
  01_ingestion/      PSGC and admin boundary ingestion notebooks
  02_bronze/         Config-driven bronze loaders (one per domain)
  03_silver/         Silver build scripts (SQL) per domain
  04_gold/           Gold mart build scripts (SQL)
  05_quality/        Bronze, silver, gold QC scripts
config/             Source YAML configs (one per domain) + reference CSVs
resources/           Databricks job definitions (DABs)
builders/            Reference CSV generators (run by hand)
tests/               pytest smoke test
dashboard/           Lakeview dashboard JSON
docs/               This documentation
archive/             Obsolete notebooks and SQL (not deployed)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch workflow, PR conventions, and local checks.

## License and data usage

Source data retains the license of its provider. Open data (PSA, HDX, UP NOAH) is under ODbL or CC-BY. Restricted data (FOI releases, bed occupancy) is for internal use only and must not be redistributed. See [Data governance](docs/08-governance/data-governance.md) for per-source terms.
