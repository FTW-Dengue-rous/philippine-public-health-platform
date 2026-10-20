# Scope

This page says what LUNASaan? covers, what it leaves for later, and what it will not do. Use it to check whether a request belongs to this project.

Owner: LUNASaan Documentation Team
Last updated: 2026-10-20

---

## 1. Scope at a glance

| Tier | What | Status |
|---|---|---|
| **Core** | BQ1: gaps between need and services, with poverty and a prevention view | Built (gold marts 14–19) |
| **Core** | Access: areas with no hospital or primary care recorded; distance to care | Built (marts 14, 20) |
| **Core** | TB case study (T1, T2) | Built (mart 21) |
| **Core** | Kidney care case study (K1), under specialist treatment capacity | Built (mart 22) |
| **Core** | Dengue peaks relative to current recorded capacity (minimal view) | Built (mart 23) |
| **Core** | Pipeline status page (evidence readiness) | Built (mart 24) |
| Stretch 1 | Immunization coverage | Not built |
| Previous scope (stretch 2) | BQ2: full dengue capacity replay | Not built |
| Stretch (later) | Forecasting; a COVID-like worst-case scenario | Not built |
| Conditional | PSMO oncologist supply vs cancer burden estimates (CON2) | Inputs built to silver (`workforce_silver_04_specialist`); the comparison is not built |
| Out of scope | See [section 5](#5-out-of-scope) | — |

The question framework behind these tiers — BQ1, its supporting questions and the previous-scope BQ2 — is in [problem and business context](problem-and-business-context.md). BQ1 is answered by the marts above side by side; a single `mart_capacity_gap` that joins need and supply in one row is designed but not built.

## 2. Deliverables

| Deliverable | Description |
|---|---|
| Pipeline | Bronze → silver → gold on Databricks, run as one job, with quality checks at every layer |
| Gold data model | 5 dimensions, 4 facts, seeds, default views and marts in `public_health.gold` |
| Dashboard | Databricks AI/BI dashboard and Genie, built on the gold marts |
| Documentation | This `docs/` folder and a README in every `src/` layer folder |
| Evidence | Run screenshots, idempotency and reconciliation evidence in `docs/06-evidence/` |
| Presentation | 10–14 minutes, presented and defended |

The output is a **dashboard only** (D-02). A researcher dataset is not delivered.

## 3. Data scope

| Domain | Covers | Main sources |
|---|---|---|
| Diseases | Cases, deaths, prevalence, TB programme, hospital claims | DOH FOI dengue, UP NOAH, HDX dengue, PSA deaths, FHSIS TB and morbidity, IHME GBD 2023, PhilHealth claims (FOI), Davao hospital pneumonia |
| Facilities | Registry of establishments, beds, published counts, bed occupancy, OSM points | DOH NHFR, DOH HFSRB, PSA tables, FHSIS, HFSRB FOI bed occupancy, HDX healthsites |
| Workforce | Health worker headcounts, FHSIS population denominators, oncologists | DOH FHSIS, PSA Table 9.14, PSMO |
| Socioeconomic | Poverty, health expenditure, child mortality | PSA |
| Geography | PSGC codes, names, levels, hierarchy; boundaries | PSGC API (Q2 2024), HDX COD-AB |
| Population | Census population 2015, 2020, 2024 | PSGC datafile population payload |

**Disease scope.** The platform is disease-agnostic. Silver keeps every PSA cause of death, not only the focus diseases (D-10). The dashboard focuses on dengue, TB, chronic kidney disease, pneumonia, heart disease, stroke and neoplasms (as one group, D-11).

**Geographic scope.** Region, province, highly urbanized city (HUC), city and municipality. Barangays are not in gold. Comparisons use **planning units**: each province without its HUCs, each HUC, and NCR.

**Time scope.** Each source keeps its own years. Examples: census 2015, 2020, 2024; poverty 2021, 2023, 2025; dengue 2016–2025 by source; facility registry as a current snapshot (2026).

**Data cut-off.** The team builds only on data already on hand (D-03). The eFOI 2026-5476 release (arrived 2026-10-16) was not ingested before the capstone. No new ingestions are planned in the post-capstone pass.

## 4. Engineering scope

| In scope | Notes |
|---|---|
| Config-driven, incremental bronze loading | One YAML entry per dataset |
| Silver standardisation with row-level lineage | Lineage contract v1.3 |
| Silver and gold full rebuilds, write-audit-publish | Deliberate at current volume (D-57) |
| Gold star schema and marts | Write-audit-publish builds |
| Quality checks at every layer, with gates | One `quality` schema |
| One orchestrated job, started by hand | Databricks Asset Bundles; the person who lands new data starts the job (D-59) |
| CI/CD on GitHub Actions | CI on pull requests and pushes: Python lint and format (ruff), unit tests (pytest), SQL lint (sqlfluff), secret scan (gitleaks), repo hygiene. CD deploys the Databricks bundle after CI passes on a push: `dev` branch to the `dev` target, `main` to `prod`. Failing checks on `dev` are fixed after submission |

| Recommended, not planned (post-capstone) | Why |
|---|---|
| Start the job when a batch of data is ready (trigger on a marker folder); skip silver and gold on automatic runs with no bronze change; then per-domain skip | Useful once runs are automatic; runs stay manual for now (D-57, D-59, [silver rebuild strategy](../04-pipeline/silver/rebuild-strategy.md)) |
| Per-source incremental silver rebuild (`replaceWhere`) | Worth it only when a domain reaches millions of rows (D-57) |
| Shared `silver_tables.yaml` and drift checks | Structural; after the core is stable |
| Unity Catalog grants on restricted tables | `sharing` is declared only for now |
| Shared bronze loader module | The four loaders are identical copies today |

## 5. Out of scope

| Item | Reason |
|---|---|
| Researcher-ready dataset export | Dashboard only (D-02); restricted sources allow aggregates only (D-47) |
| Why people delay care | The data shows where barriers exist. Causes need survey data (D-29) |
| Bed sufficiency per disease | Disease data is yearly counts, not admissions |
| Patient residence vs hospital distance | Claims data gives the place of care, not residence |
| COVID as a core disease | It could overestimate the need for facilities; stretch only |
| Travel time or road distance | Distances are straight-line |
| Record-level publication of FOI data | Aggregates only, suppression under 3 |
| Patient-level clinical data | All sources are aggregated or facility-level. The one restricted release with daily counts (Davao hospital pneumonia) stays in silver and is not redistributed |
| Real-time or daily updates | Sources publish yearly, monthly or weekly |
| Deployment outside the team's Databricks workspace | The pipeline is one Databricks job; the output is a Databricks dashboard (D-02) |

## 6. Timeline

| Week | Plan |
|---|---|
| 1 | Ingestion, first model draft |
| 2 | Final model, silver, QC, dashboard |
| 3 | Productionize, answer the business questions, presentation |
| 4 | Preparation and practice |
| After the capstone | Reliability pass: bronze (closed 2026-10-19), silver (closed 2026-10-20), gold, docs, three evidence runs |

Detail: [Team and timeline](../08-governance/team-and-timeline.md).

## 7. History of updates

| Date | Change |
|---|---|
| 2026-10-01 | Build only on data on hand (D-03) |
| 2026-10-02 | Forecasting and COVID moved to stretch goals |
| 2026-10-07 | Vaccination removed from core (BQ v3) |
| 2026-10-09 | Order set: kidney case study in core; immunization stretch 1; dengue replay stretch 2 (D-27) |
| 2026-10-14 | Minimal dengue peak-vs-capacity view moved into core |
| 2026-10-18 | No further ingestions; eFOI 2026-5476 dropped |
| 2026-10-19 | Page written |
| 2026-10-19 | Full rebuild kept in scope; incremental silver moved to recommendations (D-57) |
| 2026-10-20 | Runs stay manual; trigger and skip deferred (D-59). CI fixes on `dev` after submission |
| 2026-10-20 | BQ2 relabelled previous scope to match the context page; Owner and Last updated metadata added |
| 2026-10-20 | Scope-page integration pass: question-framework link and `mart_capacity_gap` status added; CI row expanded to the actual GitHub Actions checks; deployment boundary added to out of scope |
| 2026-10-20 | Conditional CON2 (PSMO vs cancer estimates) row and patient-level clinical data out-of-scope row added. Draft's GLOBOCAN source, "priority scoring gated" claim, and stretch-listing of already-built CON1 and CASE rejected as unsupported or contradicted by the build |