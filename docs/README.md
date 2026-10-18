# Documentation index

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

This directory contains the full documentation for the Philippine Public Health Platform. Start here to find what you need.

## The guiding question

The platform addresses one main question:

> **BQ1**: Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

A previous-scope question framed the dengue surge stress test (outside the active scope):

> **BQ2**: If a selected historical dengue outbreak recurred against the latest available hospital capacity, which regions or provinces would face the greatest estimated bed shortfalls under different assumptions?

BQ1 breaks down into 20+ analytical questions across five pillars: Need, Supply, Access, Workforce, and Equity, plus a Priority synthesis, supporting analyses, and conditional explorations. See [business context](01-context/problem-and-business-context.md) for the full question framework, traceability table, and implementation status.

## Suggested reading paths

### For business users and stakeholders

1. [Business context](01-context/problem-and-business-context.md) — what problem the platform solves and for whom
2. [Scope](01-context/scope.md) — what is in and out of scope
3. [Data sources](02-data/data-sources.md) — where the data comes from
4. [Dashboard guide](05-dashboard/dashboard-guide.md) — how to use the dashboard
5. [Metric definitions](04-pipeline/gold/metric-definitions.md) — what the numbers mean
6. [Assumptions and limitations](01-context/assumptions-and-limitations.md) — what the data can and cannot tell you

### For technical maintainers

1. [Architecture overview](03-architecture/architecture-overview.md) — system design and data flow
2. [Project conventions](03-architecture/project-conventions.md) — coding and naming standards
3. [Setup guide](07-operations/setup-guide.md) — environment, permissions, and configuration
4. [Runbook](07-operations/runbook.md) — execution order, verification, and recovery
5. [CI/CD and testing](07-operations/ci-cd-and-testing.md) — continuous integration and deployment
6. [Troubleshooting](07-operations/troubleshooting.md) — common failures and fixes
7. [Lineage and quality contract](lineage-qc-contract_v1.3.md) — shared lineage and QC rules
8. [Known issues and backlog](08-governance/known-issues-and-backlog.md) — open work and constraints

### For data engineers extending the pipeline

1. [Architecture overview](03-architecture/architecture-overview.md)
2. [Bronze pipeline](04-pipeline/bronze/README.md) — config-driven loaders and bronze QC
3. [Silver pipeline](04-pipeline/silver/README.md) — SQL builds per domain
4. [Gold pipeline](04-pipeline/gold/README.md) — analytical marts
5. [Quality framework](04-pipeline/quality/quality-control-framework.md) — QC checks and severity
6. [Lineage and quality contract](lineage-qc-contract_v1.3.md) — lineage columns and identifiers
7. [Reproducibility](07-operations/reproducibility.md) — how to reproduce a build

## File index

### 01-context/

| File | Content |
|---|---|
| [problem-and-business-context.md](01-context/problem-and-business-context.md) | Problem statement, stakeholders, and analytical questions |
| [scope.md](01-context/scope.md) | In scope, out of scope, stretch goals |
| [assumptions-and-limitations.md](01-context/assumptions-and-limitations.md) | Working assumptions and interpretation limits |
| [glossary.md](01-context/glossary.md) | Definitions of terms (PSGC, NHFR, HFSRB, FHSIS, BOR, ABC) |

### 02-data/

| File | Content |
|---|---|
| [data-sources.md](02-data/data-sources.md) | Per-source catalog: provider, format, coverage, license |
| [data-gaps.md](02-data/data-gaps.md) | Missing or unavailable source data |
| [lineage-map.md](02-data/lineage-map.md) | Source-to-table lineage per domain |
| [foi-data-request-log.md](02-data/foi-data-request-log.md) | FOI request tracking |

### 03-architecture/

| File | Content |
|---|---|
| [architecture-overview.md](03-architecture/architecture-overview.md) | System architecture, tech stack, data flow diagram |
| [project-conventions.md](03-architecture/project-conventions.md) | Naming, coding, and structural conventions |
| [decisions.md](03-architecture/decisions.md) | Architecture decision records |
| [ci-cd-setup.md](03-architecture/ci-cd-setup.md) | CI/CD pipeline summary (links to operations detail) |

### 04-pipeline/

| Folder | Content |
|---|---|
| [bronze/](04-pipeline/bronze/README.md) | Bronze layer: loaders, configs, per-domain docs |
| [silver/](04-pipeline/silver/README.md) | Silver layer: SQL builds, per-domain docs |
| [gold/](04-pipeline/gold/README.md) | Gold layer: marts, data model, dictionary, metrics |
| [quality/](04-pipeline/quality/quality-control-framework.md) | Quality control framework, check catalog, results |

### 05-dashboard/

| File | Content |
|---|---|
| [dashboard-guide.md](05-dashboard/dashboard-guide.md) | Dashboard pages, filters, metrics, and interpretation |

### 06-evidence/

| File | Content |
|---|---|
| [README.md](06-evidence/README.md) | Execution evidence and run records |
| [idempotency/comparison.md](06-evidence/idempotency/comparison.md) | Idempotent rebuild comparison |

### 07-operations/

| File | Content |
|---|---|
| [setup-guide.md](07-operations/setup-guide.md) | Environment, dependencies, permissions, configuration |
| [runbook.md](07-operations/runbook.md) | Execution order, verification, failure handling, recovery |
| [reproducibility.md](07-operations/reproducibility.md) | Exact inputs, versions, and steps to reproduce a build |
| [ci-cd-and-testing.md](07-operations/ci-cd-and-testing.md) | CI/CD pipelines, local checks, testing |
| [troubleshooting.md](07-operations/troubleshooting.md) | Common failures, symptoms, diagnostic steps, fixes |

### 08-governance/

| File | Content |
|---|---|
| [data-governance.md](08-governance/data-governance.md) | Ownership, access, sharing classes, sensitive data |
| [known-issues-and-backlog.md](08-governance/known-issues-and-backlog.md) | Known issues, planned work, and priorities |
| [team-and-timeline.md](08-governance/team-and-timeline.md) | Team roles and project timeline |
| [change-log.md](08-governance/change-log.md) | Notable changes to the platform |

### Shared contract

| File | Content |
|---|---|
| [lineage-qc-contract_v1.3.md](lineage-qc-contract_v1.3.md) | Shared lineage and quality contract (v1.3) |
