# Problem and business context

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

## Problem

Public health planning in the Philippines requires data from many sources — DOH facility registries, PSA population and poverty statistics, FHSIS facility counts, disease surveillance, and workforce data. These sources use different geographic codes, reference years, formats, and reporting standards. Without a unified platform, planners must manually reconcile data across spreadsheets and PDFs, which is slow, error-prone, and hard to reproduce.

The platform solves this by ingesting, cleaning, matching, and quality-checking these sources into a single Databricks-based warehouse with consistent geography (PSGC Q2 2024), traceable lineage, and a dashboard for analysis.

## Intended users

* **Public health planners** — need to see where hospital capacity, bed occupancy, and primary care facilities are insufficient relative to population.
* **DOH program managers** — need to compare facility availability across regions and provinces, by ownership and level.
* **Data analysts and researchers** — need a clean, documented, queryable warehouse with known lineage and quality checks.
* **Capstone reviewers** — need to understand, reproduce, and validate the pipeline.

## Analytical questions

The platform is designed to answer a structured set of business questions across five pillars (Need, Supply, Access, Workforce, Equity) plus a Priority synthesis, a dengue surge stress-test scenario, and supporting/conditional analyses. Each question maps to a mart or fact table and a set of dimensions.

### Implementation status legend

* **Built** — the mart/fact table exists and the question can be queried today.
* **Yes, with caveat** — the silver data exists; the gold mart or fact table is designed but may need final validation or a dimension column.
* **Needs input** — blocked until an external parameter or source is provided.
* **Gated** — depends on upstream questions being validated first.
* **Optional** — exploratory or contextual; not required for the core deliverable.

### BQ1 — Main: Capacity gap analysis

> Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

* **Mart**: `mart_capacity_gap` (built from all facts below).
* **Dimensions**: `dim_geography`, `dim_period`, `dim_disease`, `dim_source`.
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

### BQ2 — Main: Dengue surge stress test

> If a selected historical dengue outbreak recurred against the latest available hospital capacity, which regions or provinces would face the greatest estimated bed shortfalls under different assumptions?

* **Mart**: `mart_surge_stress_test`.
* **Dimensions**: `dim_geography`, `dim_period`, `scenario_key`.
* **Grain**: One row per area and scenario: replayed cases, added bed demand, spare beds, shortfall, exceed flag.
* **Status**: **Needs input.** Blocked until admission share and length-of-stay parameters are sourced.

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
| CON3 | Local bed-day reconstruction from one Davao hospital | One hospital x day | `diseases_hospital_encounters_silver` (restricted) | Optional. Pneumonia, one hospital. Cannot validate dengue admission share. |

### Mart-to-question mapping

| Mart / fact table | Answers | Build status |
|---|---|---|
| `mart_area_service_profile` | S1, S2, S3 | **Built** (~2,784 rows, 2026-10-13) |
| `mart_capacity_gap` | BQ1, A1, A2, E1, E2, P1, P2 | **Designed, not built** |
| `mart_surge_stress_test` | BQ2, D1–D5 | **Designed, not built** (blocked on parameters) |
| `fact_disease_metric` | N1, N2, N3, N4, SUP1, SUP2, CASE | Silver exists; gold fact not materialised |
| `fact_facility_capacity` | S1, A1, A2, D3, SUP3 | Silver exists; gold fact not materialised |
| `fact_bed_occupancy` | S2, D3 | Silver exists; gold fact not materialised |
| `fact_workforce` | W1, W2, CASE, SUP4 | Silver exists; gold fact not materialised |
| `fact_population` | N4, W1, A1, CASE | Silver exists; gold fact not materialised |
| `fact_socioeconomic` | E1, E2, SUP5 | Silver exists; gold fact not materialised |
| `mart_evidence_readiness` | SUP6 | Script exists (`gold_71_mart_evidence_readiness.sql`) |

### Dimensions

| Dimension | Key columns | Used by |
|---|---|---|
| `dim_geography` | `psgc_code`, `area_name`, `geographic_level`, `region_name`, `province_name` | All questions |
| `dim_period` | `year`, `month`, `week` | N1–N4, S2, W1–W2, D1–D5, SUP1–SUP5 |
| `dim_disease` | `disease`, `cause`, `cause_group`, `value_type`, `age_group` | N1–N4, P1, SUP1, SUP2, CASE |
| `dim_source` | `_source_key`, `_source_file` | All questions (lineage) |
| `dim_facility` | `facility_key`, `facility_level`, `ownership` | S1, S2, A1, A2, D3 |
| `dim_profession` | `profession`, `employer_type` | W1, W2, CASE, SUP4 |

## Success criteria

* A new engineer can reproduce the pipeline end-to-end from this documentation.
* Row counts and key metrics match across rebuilds (idempotency).
* Every silver and gold row is traceable to its source file through lineage columns and the build log.
* Quality checks stop the pipeline when data is bad, so the dashboard never serves unchecked data.
* **S1, S2, S3** are answered by `mart_area_service_profile` on the dashboard with documented metrics and known limitations.
* **N1–N4, W1–W2, E1–E2, SUP1–SUP6** can be queried from silver tables; gold facts and `mart_capacity_gap` are designed but not yet materialised.
* **BQ2 (D1–D5)** is blocked until admission share and length-of-stay parameters are sourced.
* **P1–P2** are gated until Need, Supply, Access, Workforce and Equity are validated on the same analysis unit.
* All caveats are documented so results are never misinterpreted.
