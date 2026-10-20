<img width="1375" height="510" alt="LUNASaan" src="https://github.com/user-attachments/assets/0cea976e-f1a0-456a-98cf-6a3849edeab2" />


# LUNASaan? — Philippine Public Health Platform

> **Tamang Datos. Tamang Lugar. Tamang Tugon.**
> The right data, for the right place, for the right response.


Owner: LUNASaan Documentation Team

Last updated: 2026-10-21

A data platform on Databricks that brings Philippine public health data — facilities, diseases, workforce, socioeconomic indicators, and geography — into a unified, quality-checked warehouse. It shows where health-service availability falls short of population need and disease burden, across the country's planning areas.

Built by team **LUNASaan** (Learning Team 5) as an FTW Data Engineering Capstone project.

---

## Quick start

```bash
# 1. Clone and set up local checks
pip install -r requirements-dev.txt
pre-commit install

# 2. Validate and deploy the pipeline to Databricks (dev target)
databricks bundle validate -t dev
databricks bundle deploy -t dev

# 3. Run the pipeline job from the bundle (or start it in the Databricks UI)
databricks bundle run -t dev ph_public_health_pipeline
```

See [Setup guide](docs/07-operations/setup-guide.md) for prerequisites, permissions, and full configuration.

Source files must be in the landing volume before running, in the folders named in each `config/sources_<domain>.yaml`. Individual sources can be switched off with `enabled: false` in their YAML entry (for example, to rebuild without restricted FOI data).

## What this platform does

The platform ingests publicly available and FOI-released data from DOH, PSA, UP NOAH, HDX, IHME, and other sources, processes it through a medallion architecture (bronze → silver → gold), and serves analytical marts and a dashboard for public health planning.

It is intended for public health planners, DOH programme managers, data analysts, and capstone reviewers. See [business context](docs/01-context/problem-and-business-context.md) for the full problem statement and user profiles.

The data needed to answer this already exists, but it is split across agencies and cannot be joined as published:

| Data | Held by | Typical issue |
|---|---|---|
| Disease counts | DOH (FHSIS, FOI releases), PSA, IHME | Different years, grains and area labels |
| Facility lists and beds | DOH NHFR, DOH HFSRB, PSA | Names inside addresses, no shared facility ID |
| Population and areas | PSA (PSGC) | 10-digit codes that other sources do not use |
| Poverty | PSA | Province rows that may or may not include their cities |
| Health workers | DOH FHSIS, PSA | Layout changes every year |

LUNASaan? joins these sources on one shared geography code (PSGC) and flags every place where they cannot be compared fairly.

About 40 source datasets span six domains: diseases, facilities, workforce, socioeconomic, geography, and population. Full list: [data sources](docs/02-data/data-sources.md).

**The main business question:**

* **BQ1** — Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions? (capacity gap analysis)

A previous-scope question, outside the active scope and retained as a stretch goal only if re-scoped (blocked on admission-share and length-of-stay parameters):

* **BQ2** — If a selected historical dengue outbreak recurred against the latest available hospital capacity, which regions or provinces would face the greatest estimated bed shortfalls under different assumptions? (dengue surge stress test; previous scope)

BQ1 breaks down into pillars: Need (N1-N4), Supply (S1-S3), Access (A1-A2), Workforce (W1-W2), Equity (E1-E2), Priority (P1-P2), plus supporting (SUP1-SUP6) and conditional (CON1-CON3) analyses.

**Built in gold and shown on the dashboard (BQ1):**

* **Need (N1–N4)** — Leading causes of death by region; disease prevalence/mortality by province; dengue peaks and recurring burden; TB notification counts by municipality.
* **Supply (S1–S3)** — Hospital counts and authorized beds relative to population, by level and ownership; bed occupancy by area and ownership; BHS, RHU and health-centre availability (S3 is shown as registry-based presence; full FHSIS counts are query-only).
* **Access (A1–A2)** — Share of municipalities with no in-scope hospital; service presence and distance to the nearest hospital (Level 3 presence, A2, is query-only).
* **Workforce (W1–W2)** — Public doctors, nurses and midwives relative to population (the LGU-employed vs DOH-deployed split, W2, is query-only).
* **Equity (E1–E2)** — Poverty vs service supply, beds and access; government bed share by poverty band (income-class analysis, E2, is query-only).
* **Priority (P1–P2)** — Areas combining high disease burden with low supply, poor access or disadvantage; ranking stability under different weights.
* **Case study (CASE)** — TB notifications vs public workforce supply; kidney care (dialysis claims vs stations).

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
    │         + bronze QC and preload gate (stops on FAIL)
    ▼
Silver  ── public_health.silver   (cleaned, typed, matched, lineage-tracked)
    │         + silver QC + cross-domain QC
    ▼
Gold    ── public_health.gold (analytical marts and dimensions for the dashboard)
    │         + gold QC (G00–G13)
    ▼
Dashboard (Lakeview) + Unity Catalog serving
```

Catalog: `public_health` · Schemas: `bronze`, `silver`, `gold`, `quality`

Full architecture: [Architecture overview](docs/03-architecture/architecture-overview.md)

## Project status

| Domain | Bronze | Silver | Gold | Dashboard |
|---|:---:|:---:|:---:|:---:|
| Geography (PSGC, admin boundaries) | Yes | Yes | Yes | Yes |
| Facilities (NHFR, HFSRB, PSA, FHSIS) | Yes | Yes | Yes | Yes |
| Diseases (dengue, TB, cancer) | Yes | Yes | Yes | Yes |
| Workforce (FHSIS, PSA, PSMO) | Yes | Yes | Yes | Yes |
| Socioeconomic (poverty, expenditure) | Yes | Yes | Yes | Yes |

Yes = implemented and verified on Databricks. The full pipeline (bronze, silver, gold) was verified end to end on 2026-10-18 in the current workspace; see the [run record](docs/06-evidence/2026-10-18-new-workspace-run.md). Recorded QC outcomes are in [quality results and evidence](docs/04-pipeline/quality/quality-results-and-evidence.md); post-run verification steps and expected row counts are in the [runbook](docs/07-operations/runbook.md). See [Known issues and backlog](docs/08-governance/known-issues-and-backlog.md) for caveats.

The Lakeview dashboard has eight pages and reads gold tables in `public_health.gold`. It refreshes when opened. Open it from the Databricks UI; see the [dashboard guide](docs/05-dashboard/dashboard-guide.md) for pages, filters, and data freshness checks.

## What the data shows

Headline figures from the current gold build. "Recorded" means listed in the source registry; it does not prove that no facility exists. Distances are straight-line, not travel distance.

| Finding | Value |
|---|---|
| Cities and municipalities with no hospital recorded | 1,114 of 1,642 (67.8%), home to about 38 million people |
| Cities and municipalities with no licensed primary care facility recorded | 924; 678 have neither |
| Provinces with no Level 3 hospital recorded | 58 of 82; median straight-line distance to a town with one: 45 km |
| Registry beds per 10,000 residents (national) | 8.0 |
| Beds per 10,000 residents: provinces under 10% poverty vs 20-30% poverty | 10.3 vs 6.2 |

The locality counts were verified against `public_health.gold.mart_locality_service_presence` on 2026-10-19; the other figures are the team's presented dashboard values (see the [dashboard guide](docs/05-dashboard/dashboard-guide.md)). Limits that apply to every chart, and the team's recommendations, are in [limitations and recommendations](docs/01-context/limitations-and-recommendations.md). The assumptions behind the figures are in [assumptions](docs/01-context/assumptions.md).

## How quality is enforced

* **Gated layers** — bronze and silver QC stop the job on a FAIL-level check; a preload gate stops a domain's silver when one of its bronze sources is not cleared; silver builds validate keys, duplicates and lineage before publishing.
* **Traceable** — every silver row carries lineage columns; every build records its inputs in `quality.build_log` and `quality.build_inputs`; rows that are dropped, quarantined or merged are recorded with a reason in `quality.row_disposition`.
* **Idempotent** — bronze loads only new or changed files; silver and gold use write-audit-publish. Reruns are safe and a failed build leaves the published table untouched.
* **Honest about gaps** — nulls stay null. Every excluded area or row carries a reason.
* **Gold QC** — checks published gold tables (G00–G13: row counts, primary keys, grain uniqueness, foreign keys, published-table integrity, freshness against inputs, control totals, value consistency, default views, selection contract, measure ranges, idempotency fingerprint, census plausibility). Any FAIL fails the last task of the job. See the [quality framework](docs/04-pipeline/quality/quality-control-framework.md) and the [check catalog](docs/04-pipeline/quality/quality-check-catalog.md).

## Key limitations

* **Restricted data**: Bed occupancy and some FOI-released data carry sharing restrictions. See [Data governance](docs/08-governance/data-governance.md).
* **Reference year matters**: Sources span different years (2018–2025). Never compare partial years with full years without adjustment. See [Limitations and recommendations](docs/01-context/limitations-and-recommendations.md).
* **Geographic comparability**: PSGC codes change over time. The platform uses PSA PSGC Q2 2024 as the reference geography. Area names that do not match are logged as exceptions. See [Data gaps](docs/02-data/data-gaps.md).
* **Recorded ≠ absent**: A facility not listed in a registry does not prove it does not exist. See [Limitations and recommendations](docs/01-context/limitations-and-recommendations.md).
* **OSM coverage is community-maintained**: `facilities_osm_point_silver` exists (16,030 rows, built 2026-10-18), but absence from OSM does not prove a facility does not exist. See [Known issues](docs/08-governance/known-issues-and-backlog.md).

## Documentation

Full documentation lives in [`docs/`](docs/README.md). Key entry points:

* **New to the project?** -> [Business context](docs/01-context/problem-and-business-context.md) -> [Data sources](docs/02-data/data-sources.md) -> [Architecture](docs/03-architecture/architecture-overview.md)
* **Want to run the pipeline?** -> [Setup guide](docs/07-operations/setup-guide.md) -> [Runbook](docs/07-operations/runbook.md)
* **Maintaining the platform?** -> [Architecture](docs/03-architecture/architecture-overview.md) -> [CI/CD setup](docs/03-architecture/ci-cd-setup.md) -> [Troubleshooting](docs/07-operations/troubleshooting.md)
* **Using the dashboard?** -> [Dashboard guide](docs/05-dashboard/dashboard-guide.md) -> [Metric definitions](docs/04-pipeline/gold/metric-definitions.md)
* **Lineage and quality contract** -> [Lineage and quality contract](docs/04-pipeline/quality/lineage-and-quality-contract.md)
* **Handover** -> [Handover checklist](handover-checklist.md)
* **Verified execution** -> [Evidence: 2026-10-18 full pipeline run](docs/06-evidence/2026-10-18-new-workspace-run.md)

## Repository layout

```
src/
  00_setup/          Schema and quality table DDL
  01_ingestion/      PSGC and admin boundary ingestion notebooks
  02_bronze/         Config-driven bronze loaders (one per domain)
  03_silver/         Silver build scripts (SQL) per domain
  04_gold/           Gold build scripts (SQL): dimension/, fact/, mart/
  05_quality/        Bronze, silver, gold QC scripts and the preload gate
config/             Source YAML configs (one per domain) + reference CSVs
resources/           Databricks job definitions (DABs)
builders/            Reference CSV generators (run by hand)
tests/               pytest smoke test
dashboard/           Lakeview dashboard JSON
docs/               This documentation
archive/             Obsolete notebooks and SQL (not deployed)
.github/             GitHub Actions CI workflows
```

## Team

Learning Team 5: Jemma Santiago (team lead), Shiena Arico, Virna Pomendia, Via Cabuyao, Ma. Cristina Villota, and Margarette Legaspi.

Roles and timeline: [team and timeline](docs/08-governance/team-and-timeline.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch workflow, PR conventions, and local checks.

## License and data usage

Source data retains the license of its provider.

* **IHME modelled estimates** — non-commercial use only; show the IHME attribution line with every IHME value; do not redistribute the raw export.
* **OpenStreetMap / healthsites.io** — © OpenStreetMap contributors, ODbL 1.0.
* **HDX** — dengue data under CC BY; COD-AB administrative boundaries.
* **UP NOAH** — regional dengue counts, ODbL.
* **PSA, DOH** — public statistics as published.

Restricted data (FOI releases, bed occupancy) is for internal use only and must not be redistributed. See [Data governance](docs/08-governance/data-governance.md) for per-source terms.
