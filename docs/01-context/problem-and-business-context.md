# Problem and business context

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

## Problem

Public health planning in the Philippines requires data from many sources — DOH facility registries, PSA population and poverty statistics, FHSIS facility counts, disease surveillance, and workforce data. These sources use different geographic codes, reference years, formats, and reporting standards. Without a unified platform, planners must manually reconcile data across spreadsheets and PDFs, which is slow, error-prone, and hard to reproduce.

The platform solves this by ingesting, cleaning, matching, and quality-checking these sources into a single Databricks-based warehouse with consistent geography (PSGC Q2 2024), traceable lineage, and a dashboard for analysis.

## Intended users

* **Public health planners** — need to see where hospital capacity, bed occupancy, and primary care facilities are insufficient relative to population.
* **DOH program managers** — need to compare facility availability across regions and provinces, by ownership and level.
* **Data analysts and researchers** — need a clean, documented, queryable warehouse with known lineage and quality checks.
* **Capstone reviewers** — need to understand, reproduce, and validate the pipeline.

## Analytical questions

BQ1 (capacity gap analysis) is the platform's only main business question. The supporting questions across five pillars (Need, Supply, Access, Workforce, Equity) plus a Priority synthesis feed BQ1: each supplies one side of the capacity-gap comparison per area. Supporting and conditional analyses are retained only where they genuinely support BQ1. Each question maps to a mart or fact table and a set of dimensions. BQ2 (dengue surge stress test) is outside the active scope and is preserved below as previous scope.

### Implementation status legend

* **Built** — the mart/fact table exists and the question can be queried today.
* **Yes, with caveat** — the silver data exists; the gold mart or fact table is designed but may need final validation or a dimension column.
* **Needs input** — blocked until an external parameter or source is provided.
* **Gated** — depends on upstream questions being validated first.
* **Optional** — exploratory or contextual; not required for the core deliverable.

### BQ1 — Main: Capacity gap analysis

> Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

* **Mart**: `mart_capacity_gap` — designed, not built (verified absent from `public_health.test_gold2` on 2026-10-18). BQ1 is partially answered today by `mart_area_service_profile` v2, which joins supply, workforce, poverty, and access per planning unit; disease burden from `mart_area_burden_indicator` is not yet joined.
* **Dimensions**: `dim_geography`, `dim_date`, `dim_disease`, `dim_data_source`.
* **Grain**: One row per analysis area with need, supply, access, workforce and equity indicators side by side.
* **Analysis unit**: Province / HUC (main); region and municipality where data exists.
* **Status**: Yes, with caveat. Needs one analysis unit for province-level facts (province + HUC + NCR rule).

### Need (N1–N4): Disease burden

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| N1 | Which causes account for the largest numbers and shares of registered deaths in each region, and which contributed most to the 2023–2024 change? | Region x cause x year (2023, 2024) | `diseases_metric_silver` (PSA deaths region annual), `diseases_directory_silver` | Yes, with caveat. Two-year change is not a trend. No per-capita rate for 2023 (no 2023 population). |
| N2 | Which provinces have the largest estimated prevalence or mortality for selected diseases, and how did estimates change from 2019 to 2023? | Province x disease x year (2019–2023) | `diseases_metric_silver` (IHME GBD) | Yes, with caveat. Counts rank large provinces first. A fair comparison needs rates. |
| N3 | When and where does reported dengue peak, how concentrated are cases within the year, and which areas repeatedly report high burden? | Region x month (2021–2025), region x week (2016–2020), province x week (2016–2020) | `diseases_metric_silver` (DOH FOI, UP NOAH, HDX) | Yes, with caveat. No province-level dengue after 2020. 2025 is January–September only. |
| N4 | Which municipalities and cities report the highest TB notification counts, and how did notifications change from 2024 to 2025? | Municipality x year (2024, 2025) | `diseases_metric_silver` (FHSIS TB), population silver | Yes, with caveat. Notifications reflect detection, not prevalence. Two years cannot show a trend. |

### Supply (S1–S2): Facility capacity and occupancy

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| S1 | How do hospital counts and authorized beds relative to population vary across areas, and how is supply distributed by hospital level and ownership? | Area x hospital level x ownership (snapshot) | `facilities_registry_silver`, `facilities_metric_silver`, population silver | Yes, with caveat. Authorized beds are licensed, not staffed. |
| S2 | How does bed-day-weighted occupancy differ across areas and between government and private hospitals, among facilities with comparable reports? | Area x ownership x year (2020–2025) | `facilities_bed_occupancy_silver` | Yes, with caveat. Reporting cohort is small for 2020–2024 (~120–185 rows/year) and larger in 2025 (~1,160). |

> **S3** (BHS, RHU and health-centre availability) is a supply question currently answered by `mart_area_service_profile` — see [metric definitions](../04-pipeline/gold/metric-definitions.md).

### Access (A1–A2)

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| A1 | What share of municipalities and cities have no in-scope hospital, and how many residents live there? | Municipality, rolled up to province and region | `facilities_registry_silver`, `geography_silver`, population silver | Yes. Administrative absence only — residents may use a hospital in a neighbouring locality. |
| A2 | Which planning areas have no Level 3 hospital, and how does Level 3 presence vary? | Province / HUC / NCR | `facilities_registry_silver`, `geography_silver` | Yes, with caveat. The planning unit must be defined: HUCs and NCR have no province row in PSGC. |

### Workforce (W1–W2)

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| W1 | Which areas have the lowest numbers of public doctors, nurses and midwives relative to population? | Province x profession x year (2018–2024); municipality x profession (2025) | `workforce_headcounts_silver`, FHSIS reported denominators, population silver | Yes, with caveat. Public sector only. Census population exists for 2015, 2020, 2024 only; for other years use FHSIS reported denominator and label it. |
| W2 | How does public workforce composition vary between LGU-employed and DOH-deployed workers? | Region or province x profession x year (2020–2025) | `workforce_headcounts_silver` | Yes, with caveat. 2019 employer split is incomplete: use totals only for 2019. |

### Equity (E1–E2)

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| E1 | Are areas with higher poverty associated with lower beds or public workers per population and poorer local hospital access? | Province / HUC | `socioeconomic_poverty_silver` + S1, A1, W1 inputs | Yes, with caveat. Only `comparison_eligible` areas. Poverty is not published below province. Descriptive, not causal. |
| E2 | How do service supply and government bed share differ by poverty band or LGU income class? | Poverty band or income class | `socioeconomic_poverty_silver`, `geography_silver` (income class), facilities silver | Yes, with caveat. Income class values need cleaning. Income class describes LGU revenue, not household income. |

### Priority (P1–P2)

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| P1 | Which areas combine high values of a selected disease-burden indicator with low service supply, poor access or socioeconomic disadvantage? | Province / HUC | All BQ1 facts | Gated. Needs N, S, A, W and E validated on the same analysis unit first. |
| P2 | If a combined score is used, how stable are area rankings when weights and eligibility rules change? | Province / HUC x weighting set | Same as P1 + `priority_weight_params` | Gated extension. Weighting sets are a team decision. |

### Case study

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| CASE | Do municipalities with higher reported TB notifications also have lower public workforce supply? | Municipality (2025) | `diseases_metric_silver` (FHSIS TB), `workforce_headcounts_silver`, population silver | Optional. Only municipalities with both values. Exploratory. |

### BQ2 — Previous scope: Dengue surge stress test

> If a selected historical dengue outbreak recurred against the latest available hospital capacity, which regions or provinces would face the greatest estimated bed shortfalls under different assumptions?

* **Mart**: `mart_surge_stress_test`.
* **Dimensions**: `dim_geography`, `dim_date`, `scenario_key`.
* **Grain**: One row per area and scenario: replayed cases, added bed demand, spare beds, shortfall, exceed flag.
* **Status**: **Previous scope.** Not an active deliverable. If re-scoped, blocked until admission share and length-of-stay parameters are sourced.

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| D1 | Which historical dengue waves should be selected for replay, based on reported volume, peak timing and completeness? | Year x source; area x period for chosen window | `diseases_metric_silver` (DOH FOI, HDX, UP NOAH) | Yes, with caveat. 2025 is partial and not eligible. |
| D2 | Under stated admission and length-of-stay assumptions, what additional bed demand would the selected wave imply? | Area x period x scenario | `diseases_metric_silver`, `scenario_params` | Needs input. No dataset gives dengue admission share or LOS. |
| D3 | What spare hospital capacity is estimated from the selected capacity and occupancy profile, by area and ownership? | Area x ownership | `facilities_metric_silver`, `facilities_bed_occupancy_silver`, `scenario_params` | Yes, with caveat. Baseline = 2025 occupancy (candidate, pending validation). |
| D4 | Where does modelled additional bed demand exceed estimated spare capacity, and by how many beds? | Area x scenario | Outputs of D2 and D3 | Needs input. Depends on D2 parameters. |
| D5 | How sensitive are estimated shortfalls and area rankings to admissions, stay length, baseline occupancy and usable-bed assumptions? | Area x scenario preset | Outputs of D2–D4 | Needs input. Needs low and high values for each assumption. |

### Supporting (SUP1–SUP6)

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| SUP1 | Cause-of-death profile by age group and region (PSA 2023–2024) | Region x cause x age group x year | `diseases_metric_silver` (PSA, age columns) | Yes, with caveat. Gold model has no age dimension yet. |
| SUP2 | National composition of registered deaths, infectious vs chronic | National x cause group x month/year | `diseases_metric_silver` (PSA national) | Yes, with caveat. Uses approved aggregation set. 2020–2021 COVID shift is a series break. |
| SUP3 | Regional hospital and bed totals, 2020–2024 | Region x ownership x year | `facilities_metric_silver` (PSA hospitals, PSA beds) | Yes. Not mixed with NHFR/HFSRB snapshot. |
| SUP4 | Change in public workforce counts over time | Region x profession x year (2012–2025) | `workforce_headcounts_silver` | Yes, with caveat. Nurse definition breaks in 2019. Two sources, two series. |
| SUP5 | Out-of-pocket share of health spending, 2016–2023 | National x year | `socioeconomic_health_expenditure_share_silver` | Yes. National context only. |
| SUP6 | Where is the platform's evidence insufficient? (evidence readiness) | Source x table x build | `quality.qc_results`, `quality.build_log`, `quality.build_inputs`, `ingestion_metadata` | Yes. Reads quality schema directly. |

### Conditional (CON1–CON3)

| ID | Question | Grain | Sources | Status |
|---|---|---|---|---|
| CON1 | Straight-line distance to the nearest Level 3 hospital | Municipality | `facilities_registry_silver`, `facilities_osm_point_silver`, `admin_boundaries_silver` | Needs input. Needs validated coordinates. Not travel time. |
| CON2 | PSMO-listed oncologists compared with cancer estimates | Province | Workforce PSMO silver, `diseases_metric_silver` (GBD neoplasms) | Optional. Members-only directory, not total specialist supply. |
| CON3 | Local bed-day reconstruction from one Davao hospital | One hospital x day | `diseases_hospital_encounters_silver` (restricted) | Previous scope: it fed BQ2 parameter sourcing. Pneumonia, one hospital. Cannot validate dengue admission share. |

### Mart-to-question mapping (updated 2026-10-18)

| Mart / fact table | Answers | Build status |
|---|---|---|
| `mart_area_service_profile` (v1) | S1, S2, S3 | **Built** (2,784 rows, `public_health.gold`, 2026-10-13; count verified 2026-10-18). Superseded as dashboard source by v2: the dashboard now reads `test_gold2` tables. |
| `mart_area_service_profile` (v2) | S1, S2, S3, W1, E1, A1, A2 (partial BQ1) | **Built** (109 rows, `public_health.test_gold2`, 2026-10-18). Active model. |
| `mart_capacity_gap` | BQ1, A1, A2, E1, E2, P1, P2 | **Not built.** `mart_area_service_profile` v2 partially covers BQ1 (supply, workforce, poverty, access). Disease burden not yet joined. |
| `fact_disease_metric` | N1, N2, N3, N4, SUP1, SUP2, CASE | **Built** (593,171 rows, `test_gold2`, 2026-10-18) |
| `fact_facility_capacity` | S1, A1, A2, D3, SUP3 | **Built** (30,365 rows, `test_gold2`, 2026-10-18) |
| `fact_workforce_capacity` | W1, W2, CASE, SUP4 | **Built** (28,071 rows, `test_gold2`, 2026-10-18) |
| `fact_area_indicator` | E1, E2, SUP5 | **Built** (8,928 rows, `test_gold2`, 2026-10-18) |
| `fact_area_access` | A1, A2, CON1 | **Built** (1,642 rows, `test_gold2`, 2026-10-18) |
| `mart_area_burden_indicator` | N1-N4 | **Built** (2,071 rows, `test_gold2`, 2026-10-18) |
| `mart_area_priority` | P1 | **Built** (12,426 rows, `test_gold2`, 2026-10-18). Supply-only ranking. |
| `mart_locality_service_presence` | A1, A2 | **Built** (`test_gold2`, 2026-10-18) |
| `mart_evidence_readiness` | SUP6 | **Built** (`test_gold2`, 2026-10-18) |
| `mart_tb_case_study` | CASE | **Built** (1,642 rows, `test_gold2`, 2026-10-18) |
| `mart_kidney_case_study` | N2 | **Built** (81 rows, `test_gold2`, 2026-10-18) |
| `mart_dengue_peak_capacity` | N3, D1 | **Built** (981 rows, `test_gold2`, 2026-10-18) |
| `mart_surge_stress_test` | BQ2, D1-D5 (previous scope) | **Designed, not built.** Work paused. |

### Dimensions (v2 model)

| Dimension | Key columns | Used by |
|---|---|---|
| `dim_geography` | `area_key`, `area_code`, `area_name`, `geographic_level` | All questions |
| `dim_date` | `date_key`, `period_label` | N1-N4, S2, W1-W2, D1-D5, SUP1-SUP5 |
| `dim_disease` | `disease_key`, `disease_code`, `disease_name` | N1-N4, P1, SUP1, SUP2, CASE |
| `dim_data_source` | `data_source_key`, `source_dataset` | All questions (lineage) |
| `dim_facility` | `facility_key`, `facility_level`, `ownership` | S1, S2, A1, A2, D3 |

Note: The v2 model does not have a separate `dim_profession`. Workforce profession and employer type are columns in `fact_workforce_capacity`, not a standalone dimension.

## Success criteria

* A new engineer can reproduce the pipeline end-to-end from this documentation.
* Row counts and key metrics match across rebuilds (idempotency).
* Every silver and gold row is traceable to its source file through lineage columns and the build log.
* Quality checks stop the pipeline when data is bad, so the dashboard never serves unchecked data.
* **S1, S2, S3** are answered on the dashboard (v2 model pages: Overview, Gaps and equity, Preparedness) from `mart_area_service_profile` v2 and related views, with documented metrics and known limitations. FHSIS primary-care counts (S3) are query-only.
* **N1-N4, W1-W2, E1-E2, SUP1-SUP6** are queryable from gold v2 fact tables (`test_gold2`), built 2026-10-18. `mart_capacity_gap` is not built; `mart_area_service_profile` v2 partially covers BQ1 (supply, workforce, poverty, access per planning unit), and disease burden integration is the remaining gap.
* **BQ2 (D1-D5)** is previous scope and not an active deliverable. D1 (wave selection) remains queryable via `mart_dengue_peak_capacity`, which also serves N3.
* **P1** is partially built (`mart_area_priority`, supply-only). Full P1 needs N, A, W, E validated on the same analysis unit.
* **P2** is gated (needs `priority_weight_params`).
* All caveats are documented so results are never misinterpreted.

## Business-question traceability

This table traces each question to the stakeholder decision it supports, the sources and tables that feed it, the metrics computed, the query or dashboard output, and known limitations. "Built" means the table exists and the query can run today. "Partial" means some inputs are built but the full answer needs more work. "Not built" means the table does not exist yet.

| Business question | Stakeholder decision | Sources | Tables or marts | Metrics | Query or dashboard output | Limitations |
|---|---|---|---|---|---|---|
| **BQ1** Capacity gap analysis | Where to allocate new beds, staff, or facilities | All domain silver tables | `mart_area_service_profile` v2 (partial), `mart_capacity_gap` (not built) | Per-capita beds, workforce, poverty, access flags per planning unit | Dashboard (v2 model pages); v2 mart queryable in SQL | Disease burden not yet joined. Full BQ1 needs `mart_capacity_gap`. |
| **N1** Cause-of-death shares | Which causes to prioritise in regional programmes | PSA deaths by region | `fact_disease_metric` (built) | Deaths by cause; share = cause / all-cause; change = 2024 - 2023 | SQL query on `fact_disease_metric` | Two-year change is not a trend. No 2023 population for rates. |
| **N2** Disease prevalence and mortality | Which provinces need disease-specific interventions | IHME GBD | `fact_disease_metric` (built), `mart_kidney_case_study` (built) | Prevalence and deaths with bounds; change = 2023 - 2019 | SQL query; kidney case study mart | Counts rank large provinces first. Rates needed for fair comparison. |
| **N3** Dengue peak and concentration | When and where to surge dengue response | DOH FOI, UP NOAH, HDX | `fact_disease_metric` (built), `mart_dengue_peak_capacity` (built) | Peak period; concentration ratio; repeat-burden count | SQL query; dengue peak mart | No province-level dengue after 2020. 2025 is partial (Jan-Sep). |
| **N4** TB notification hotspots | Where to strengthen TB detection | FHSIS TB, population | `fact_disease_metric` (built), `mart_tb_case_study` (built) | Notification count; change = 2025 - 2024; rate per 100,000 | SQL query; TB case study mart | Notifications reflect detection, not prevalence. Two years is not a trend. |
| **S1** Hospital supply | Where hospital capacity is thin | NHFR, HFSRB, population | `mart_area_service_profile` v1/v2 (built) | Hospitals per 100,000; beds per 10,000; split by level and ownership | Dashboard (Overview and Gaps-and-equity pages, v2 model) | Authorized beds are licensed, not staffed. Population year may not match snapshot. |
| **S2** Bed occupancy | Which hospitals are overcrowded | DOH FOI bed occupancy | `mart_area_service_profile` v1 (built) | Weighted BOR; pct over 100; reporting count | Dashboard (Preparedness page, v2 model) | 2025 cohort is much larger than 2020-2024. BOR > 150 excluded. |
| **A1** No-hospital localities | Where residents lack local hospital access | NHFR, geography, population | `mart_area_service_profile` v2 (built), `fact_area_access` (built) | Share of localities without hospital; affected population | SQL query on v2 mart | Administrative absence only. Residents may use neighbouring hospitals. |
| **A2** Level 3 hospital presence | Where specialised care is absent | NHFR, geography | `mart_area_service_profile` v2 (built), `fact_area_access` (built) | Highest level per area; no-level3 flag; Level 3 count | SQL query on v2 mart | Planning unit must be defined for HUCs and NCR. |
| **W1** Workforce shortages | Where to deploy public health workers | FHSIS workforce, population | `fact_workforce_capacity` (built), `mart_area_service_profile` v2 (built) | Headcount per population; rank ascending | SQL query; v2 mart columns | Public sector only. Population years limited (2015, 2020, 2024). |
| **W2** Workforce composition | LGU vs DOH deployment balance | FHSIS workforce | `fact_workforce_capacity` (built) | DOH-deployed share; by profession and area | SQL query | 2019 employer split incomplete. Use totals only for 2019. |
| **E1** Poverty and service gaps | Whether poorer areas have less capacity | PSA poverty, facilities, workforce | `fact_area_indicator` (built), `mart_area_service_profile` v2 (built) | Poverty incidence next to beds per 10k, workers per pop, no-hospital share | SQL query; v2 mart | Descriptive, not causal. Poverty is province-level only. |
| **E2** Service by income class | Whether poorer LGUs have less supply | PSA poverty, geography income class | `fact_area_indicator` (built), `mart_area_service_profile` v2 (built) | Beds per 10k and government bed share by poverty band and income class | SQL query; v2 mart | Income class values need cleaning. Income class is LGU revenue, not household income. |
| **P1** Priority areas | Which areas to prioritise for investment | All BQ1 facts | `mart_area_priority` (built, supply-only) | Worst-fifth flags; flags count; missing-indicator list | SQL query on `mart_area_priority` | Supply-only ranking. Full P1 needs N, A, W, E validated on same analysis unit. |
| **P2** Ranking stability | Whether rankings are robust to weighting | Same as P1 + `priority_weight_params` (not built) | Weighted sum; stability count | Not built | Gated. Weighting sets are a team decision. |
| **CASE** TB vs workforce | Do high-TB areas have fewer workers | FHSIS TB, workforce, population | `mart_tb_case_study` (built) | TB notifications per 100k; workers per population | SQL query on case study mart | Exploratory. Only municipalities with both values. |
| **BQ2** Dengue surge stress test (previous scope) | Which areas would face bed shortfalls | Dengue cases, facility capacity, occupancy | `mart_surge_stress_test` (not built) | Replayed cases; added bed demand; spare beds; shortfall; exceed flag | Not built | Blocked on admission share and LOS parameters. |
| **D1-D5** Dengue preparedness sub-questions (previous scope) | Wave selection, demand, spare capacity, shortfall, sensitivity | Various | `mart_surge_stress_test` (not built), `mart_dengue_peak_capacity` (built for D1) | See individual question specs | D1 queryable; D2-D5 not built | D2-D5 blocked on external parameters. |
| **SUP1** Cause-of-death by age | Age-specific mortality patterns | PSA deaths by age | `fact_disease_metric` (built, no age dimension) | Deaths by cause and age group | SQL query (age group is a column, not a dimension) | Gold model has no age dimension yet. |
| **SUP2** Infectious vs chronic deaths | National cause-of-death composition | PSA deaths | `fact_disease_metric` (built) | Deaths by cause group / total | SQL query | 2020-2021 COVID shift is a series break. |
| **SUP3** Regional hospital totals | Historical capacity trends | PSA hospitals, PSA beds | `fact_facility_capacity` (built) | Hospital count and beds by ownership and year | SQL query | Not mixed with NHFR/HFSRB snapshot. |
| **SUP4** Workforce trends | Staffing changes over time | FHSIS workforce | `fact_workforce_capacity` (built) | Headcount by profession and year | SQL query | Nurse definition breaks in 2019. Two sources, two series. |
| **SUP5** Health spending | Out-of-pocket burden | PSA health expenditure | `fact_area_indicator` (built) | OOP share of total health expenditure | SQL query | National context only. |
| **SUP6** Evidence readiness | Where data is insufficient | Quality schema | `mart_evidence_readiness` (built) | Files loaded, QC pass rate, coverage gaps | SQL query on evidence readiness mart | Reads quality schema directly. |
| **CON1** Distance to Level 3 | Travel barrier estimation | Facilities, OSM, boundaries | `fact_area_access` (built, no distance) | Haversine distance to nearest Level 3 | Not built | Needs validated coordinates. Not travel time. |
| **CON2** Oncologists vs cancer | Specialist supply vs disease burden | PSMO, GBD neoplasms | `fact_workforce_capacity` (built), `fact_disease_metric` (built) | Oncologists per province next to neoplasm prevalence | SQL query (manual join) | Members-only directory. Optional. |
| **CON3** Bed-day reconstruction | Previous scope: LOS context for the surge model | Hospital encounters (restricted) | `diseases_hospital_encounters_silver` (restricted) | Occupied beds per day; average LOS | Not built | One hospital, pneumonia only. Cannot validate dengue admission share. |
