# Team and timeline

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

## Team

| Role | Name | Responsibilities |
|---|---|---|
| Team lead | Jemma Santiago | Disease domain, architecture plan, QC framework, gold layer, lineage contract, prod deployment |
| Data engineer | Virna Pomendia | Socioeconomic and workforce domain, dataset acquisition, presentation and script |
| Data engineer | Shiena Arico | Geography domain, PSGC and HDX ingestion, dimension modelling, dashboard |
| Data engineer | Via Cabuyao | Facilities domain, dataset acquisition, presentation and script |
| Data engineer | Ma. Cristina Villota | Facilities domain, dataset acquisition, Documentation |
| Data engineer | Margarette Legaspi | Population domain, dataset acquisition, documentation, dashboard |

*(Source: `databricks.yml` permissions and team conversation. Email addresses are in the bundle config.)*

## Domain ownership

The person responsible for a domain's Bronze implementation also owns its Silver implementation and domain documentation.

| Domain | Owner | Scope |
|---|---|---|
| Facilities | Cristina Villota, Via Cabuyao | Bronze, silver, documentation |
| Diseases | Jemma Santiago | Bronze, silver, documentation |
| Geography | Shiena Arico | Bronze, silver, documentation |
| Population | Margarette Legaspi | Bronze, silver, documentation |
| PSGC and HDX ingestion | Shiena Arico | Part of the geography domain (ingestion pipelines) |
| Socioeconomic | Virna Pomendia | Bronze, silver, documentation |
| Workforce | Virna Pomendia | Bronze, silver, documentation |
| Gold layer | Jemma Santiago | Gold model (`public_health.gold`), gold QC |
| Dashboard | Shiena Arico, Margarette Legaspi | Lakeview dashboard |
| CI/CD and DevOps | Jemma Santiago | Pipeline, deployment, CI/CD |

## Timeline

| Phase | Period | Milestone |
|---|---|---|
| Setup | Sep 2026 | Repository, CI/CD, DABs, schema setup |
| Bronze | Sep–Oct 2026 | Config-driven loaders for all domains, bronze QC |
| Silver | Oct 2026 | SQL silver builds (v1.7), lineage contract v1.3 |
| Gold | Oct 2026 | Analytical marts, `mart_area_service_profile` |
| Dashboard | Oct 2026 | Lakeview dashboard, v2 model, eight populated pages |
| Documentation | Oct 2026 | Full documentation audit and rewrite |

## Handover readiness

**Status: Unverified.**

A formal handover exercise (where someone who did not build the system follows the documentation to access, run, and verify the pipeline) has not been conducted. The documentation is written for self-service handover, but it has not been validated by an external reviewer.

To validate handover:
1. Ask a new engineer to follow the [setup guide](../07-operations/setup-guide.md) to deploy and run the pipeline.
2. Ask them to use the [runbook](../07-operations/runbook.md) to verify the latest run.
3. Ask them to interpret a dashboard page using the [dashboard guide](../05-dashboard/dashboard-guide.md) and [metric definitions](../04-pipeline/gold/metric-definitions.md).
4. Ask them to find recovery instructions in [troubleshooting](../07-operations/troubleshooting.md).
5. Record any unclear steps and fix them.
