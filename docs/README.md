# Documentation

Start here. This folder explains the LUNASaan? platform: why it exists, what data it uses, how the pipeline is built, how its quality is checked and how to run it. The project summary is in the [root README](../README.md).

## Two kinds of pages

| Where | What | Who reads it |
|---|---|---|
| `docs/` (this folder) | **Overviews.** What a layer or domain does, its rules and limits, in plain terms | Reviewers, analysts, new team members |
| `src/<layer>/README.md` | **Reference.** Run order, every table, grain, gates, check codes, recovery | Engineers running or changing the code |

Each overview links to its reference README. When the two differ, the code and its README win.

## Reading paths

| You want to | Read |
|---|---|
| Understand the project in 15 minutes | [Root README](../README.md) → [problem and business context](01-context/problem-and-business-context.md) → [architecture overview](03-architecture/architecture-overview.md) → [assumptions and limitations](01-context/assumptions-and-limitations.md) |
| Check that the numbers can be trusted | [Quality control framework](04-pipeline/quality/quality-control-framework.md) → [silver reconciliation](04-pipeline/silver/reconciliation.md) → [analytical validation and traceability](04-pipeline/gold/analytical-validation-and-traceability.md) → [evidence](06-evidence/README.md) |
| Use the gold tables or the dashboard | [Gold usage rules](04-pipeline/gold/gold-usage-rules.md) → [metric definitions](04-pipeline/gold/metric-definitions.md) → [dashboard guide](05-dashboard/dashboard-guide.md) |
| Run or fix the pipeline | [Setup guide](07-operations/setup-guide.md) → [runbook](07-operations/runbook.md) → [troubleshooting](07-operations/troubleshooting.md) |
| Know why something was done this way | [Decision log](08-governance/decision-log.md) (D-xx) and [architecture decisions](03-architecture/architecture-decisions.md) (AD-xx) |

## Folders

```
docs/
├── README.md                              ← you are here
├── 01-context/                            why the platform exists
│   ├── problem-and-business-context.md      business questions BQ1, BQ2; users; success criteria
│   ├── scope.md                             in and out of scope
│   ├── assumptions-and-limitations.md       limits that apply to every result
│   └── glossary.md                          terms, codes and abbreviations
├── 02-data/                               what data we use
│   ├── data-sources.md                      every source dataset, by domain
│   ├── data-request-log.md                  FOI and data requests, and what was promised
│   ├── data-gaps.md                         what the sources do not cover
│   └── data-lineage-map.md                  source → bronze → silver → gold → dashboard
├── 03-architecture/                       how it is built
│   ├── architecture-overview.md
│   ├── project-conventions.md               naming, keys, lineage columns, code style
│   ├── architecture-decisions.md            AD-xx
│   └── ci-cd-setup.md                       CI checks, deployment, tests
├── 04-pipeline/                           each layer, per domain
│   ├── bronze/
│   │   ├── README.md                        bronze overview
│   │   ├── diseases.md · facilities.md · workforce.md · socioeconomic.md
│   │   ├── geography.md                     PSGC API landing and HDX boundaries
│   │   └── population.md                    census population inside the PSGC payload
│   ├── silver/
│   │   ├── README.md                        silver overview
│   │   ├── diseases.md · facilities.md · workforce.md · socioeconomic.md
│   │   ├── geography.md · population.md
│   │   ├── silver-quality-checks.md         every silver check: gates, domain and cross-domain QC
│   │   ├── reconciliation.md                how every bronze row is accounted for in silver
│   │   └── rebuild-strategy.md              why silver rebuilds in full; cost recommendations
│   ├── gold/
│   │   ├── README.md                        gold overview
│   │   ├── conceptual-model.md · logical-data-model-and-erd.md
│   │   ├── table-catalog.md · data-dictionary.md · business-data-dictionary.md
│   │   ├── data-marts.md · metric-definitions.md · gold-usage-rules.md
│   │   ├── seed-data.md · sample-queries.md
│   │   ├── analytical-validation-and-traceability.md
│   │   └── findings-report.md
│   └── quality/
│       ├── README.md                        quality overview
│       ├── lineage-and-quality-contract.md  the contract every build follows
│       ├── quality-control-framework.md     gates, severities, where results are stored
│       ├── quality-check-catalog.md         every check code (B, S, G) and what it means
│       └── quality-results-and-evidence.md  results of the recorded runs
├── 05-dashboard/
│   └── dashboard-guide.md
├── 06-evidence/                           screenshots and query outputs, by run
│   ├── README.md                            what each folder proves and how it was captured
│   ├── architecture/ · bronze/ · silver/ · gold/
│   ├── idempotency/                         run-01/, run-02/, run-comparison.md
│   └── reconciliation/                      results for the method in 04-pipeline/silver/reconciliation.md
├── 07-operations/
│   ├── setup-guide.md · runbook.md · troubleshooting.md
│   └── reproducibility.md                   running without Databricks
└── 08-governance/
    ├── data-governance.md                   restricted data (D-47), suppression, attribution
    ├── decision-log.md                      D-01 onwards
    ├── known-issues-and-backlog.md          open issues, post-capstone recommendations
    ├── team-and-timeline.md
    └── change-log.md                        dated runs and revisions
```

## Conventions used in these pages

| Convention | Meaning |
|---|---|
| D-xx | A project decision in the [decision log](08-governance/decision-log.md) |
| AD-xx | An architecture decision in [architecture-decisions.md](03-architecture/architecture-decisions.md) |
| B·· / S·· / G·· | A bronze, silver or gold check code; all are listed in the [check catalog](04-pipeline/quality/quality-check-catalog.md) |
| "Recorded" | Listed in the source registry. It does not prove that nothing else exists |
| Dates | Written as YYYY-MM-DD. A number stated as a fact about the data carries the date it was checked, or points to where the live value is stored |
| File names | No version or date in a page name; versions and dates are inside the page and in the [change log](08-governance/change-log.md) |