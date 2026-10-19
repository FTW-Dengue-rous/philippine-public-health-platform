# Findings report

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

Findings from the built gold tables, organized by the platform's business question framework. BQ1 (capacity gap analysis) is the platform's only active main question; the supporting sections (N, S, A, W, E, P, SUP) provide its evidence base. Each section states the question, the gold table, the answer grain, the silver inputs, whether the data can answer it, and the verified finding or status. BQ2 is previous scope.

See [business context](../../01-context/problem-and-business-context.md) for the full question framework and traceability table. See [metric definitions](metric-definitions.md) for formulas and [assumptions and limitations](../../01-context/assumptions-and-limitations.md) for interpretation rules.

Numbers marked **v1** come from the earlier `mart_area_service_profile` (2,784 rows, built 2026-10-13; count re-verified 2026-10-18). Numbers marked **v2** come from `public_health.gold` tables (built 2026-10-18). Numbers marked **silver** come from direct silver table queries. All counts verified by COUNT(*) and aggregate queries on 2026-10-18.

---

## BQ1: Capacity gap analysis

> Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

* **Gold table**: `mart_capacity_gap` (not built). Partially covered by `mart_area_service_profile` v2 (109 rows, 62 columns).
* **Answer grain**: Province / HUC / NCR (one row per planning unit).
* **Silver inputs**: All domain silver tables.
* **Answerable?**: Yes, with caveat. Supply, workforce, poverty, and access are joined per planning unit. Disease burden is in `mart_area_burden_indicator` (2,071 rows) but not yet joined.
* **Caveat**: Needs one analysis unit for province-level facts (province + HUC + NCR rule). Gap ID G11.

### Verified finding (v2)

The v2 `mart_area_service_profile` has 109 planning units. Of these, 99 have at least one hospital and 10 have none. 37 have at least one Level 3 hospital. Average beds per 10,000 population is 10.4 (range: 0.00 to 51.74). 1,114 localities (cities/municipalities) have no hospital, affecting approximately 38.1 million residents.

Disease burden per area is available in `mart_area_burden_indicator` (2,071 rows, 109 areas, 10 diseases) but has not been joined to the service profile. Full BQ1 requires this integration.

---

## Need (N1-N4): Disease burden

### N1: Cause-of-death shares

> Which causes account for the largest numbers and shares of registered deaths in each region, and which contributed most to the 2023 to 2024 change?

* **Gold table**: `fact_disease_metric` (593,171 rows, built).
* **Answer grain**: Region x cause x year (2023, 2024).
* **Silver inputs**: `diseases_metric_silver` (PSA deaths region annual), `diseases_directory_silver`.
* **Answerable?**: Yes, with caveat.
* **Caveat**: Two-year change is not a trend. Shares only, no per-capita rate for 2023 (no 2023 population). Confirm the 2024 file has a regional all-cause total. Gap IDs G1, G9.
* **Finding**: Table built and queryable. Content verification pending. No specific cause-level findings reported yet.

### N2: Disease prevalence and mortality

> Which provinces have the largest estimated prevalence or mortality for selected diseases, and how did estimates change from 2019 to 2023?

* **Gold table**: `fact_disease_metric` (built), `mart_kidney_case_study` (81 rows, built).
* **Answer grain**: Province x disease x year (2019-2023).
* **Silver inputs**: `diseases_metric_silver` (IHME GBD main causes, neoplasms).
* **Answerable?**: Yes, with caveat.
* **Caveat**: Counts rank large provinces first. A fair comparison needs rates: re-export GBD as rate, or add annual population. Confirm whether GBD provinces include their HUCs. Gap IDs G1, G2.
* **Finding**: Kidney case study mart built (81 rows). General prevalence mart built but content not yet verified.

### N3: Dengue peak and concentration

> When and where does reported dengue peak, how concentrated are cases within the year, and which areas repeatedly report high burden?

* **Gold table**: `fact_disease_metric` (built), `mart_dengue_peak_capacity` (981 rows, built).
* **Answer grain**: Region x month (2021-2025), region x week (2016-2019, 2022-2025), province x week (2016-2020).
* **Silver inputs**: `diseases_metric_silver` (DOH FOI, UP NOAH, HDX).
* **Answerable?**: Yes, with caveat.
* **Caveat**: No province-level dengue after 2020. 2025 is January to September only. HDX and UP NOAH week conventions not confirmed. Gap IDs G4, G17.
* **Finding**: Dengue peak capacity mart built (981 rows). Content verification pending.

### N4: TB notification hotspots

> Which municipalities and cities report the highest TB notification counts, and how did notifications change from 2024 to 2025?

* **Gold table**: `fact_disease_metric` (built), `mart_tb_case_study` (1,642 rows, built).
* **Answer grain**: Municipality x year (2024, 2025).
* **Silver inputs**: `diseases_metric_silver` (FHSIS TB), `population_silver`.
* **Answerable?**: Yes, with caveat.
* **Caveat**: Notifications reflect detection and reporting, not only how common TB is. Two years cannot show a trend.
* **Finding**: TB case study mart built (1,642 rows, 1,642 areas). Of these, 1,634 have 2025 notifications and 1,622 have doctors-per-10k data. Content verification pending.

---

## Supply (S1-S3): Facility capacity and occupancy

### S1: Hospital availability

> How do hospital counts and authorized beds relative to population vary across areas, and how is supply distributed by hospital level and ownership?

* **Gold table**: `mart_area_service_profile` v1 (2,784 rows) and v2 (109 rows; the dashboard now reads v2 tables).
* **Answer grain**: Area x hospital level x ownership (snapshot: NHFR 2026-09-29, HFSRB 2026-06-30, population 2024).
* **Silver inputs**: `facilities_registry_silver`, `facilities_metric_silver`, `population_silver`.
* **Answerable?**: Yes, with caveat.
* **Caveat**: Authorized beds are licensed beds, not staffed beds. Depends on facility identity (duplicate nhfr_code resolved first). Gap ID G11.

#### Verified finding (v1)

The registry contains hospitals across 94 provinces and 526 cities/municipalities. Government and private hospitals are split roughly evenly by count, but authorized bed capacity is concentrated in government hospitals.

#### Verified finding (v2)

Average beds per 10,000 population across 109 planning units is 10.4. The range is 0.00 to 51.74, showing wide variation. Some NCR districts have null population, so their rate is null (not zero).

### S2: Bed occupancy

> How does bed-day-weighted occupancy differ across areas and between government and private hospitals, among facilities with comparable reports?

* **Gold table**: `mart_area_service_profile` v1 (built). The dashboard shows occupancy on its Preparedness page via `public_health.gold.v_facility_capacity_totals`.
* **Answer grain**: Area x ownership x year (2020-2025).
* **Silver inputs**: `facilities_bed_occupancy_silver`.
* **Answerable?**: Yes, with caveat.
* **Caveat**: Reporting cohort is small for 2020-2024 (roughly 120-185 rows a year) and much larger in 2025 (1,067 baseline-eligible facilities). Comparing 2025 with earlier years is not valid because the cohort changed. Occupancy over 150% is excluded as a data error. Gap ID G5.

#### Verified finding (silver, 2025, baseline eligible, BOR <= 150)

Bed-day-weighted BOR (implementing beds as weight):

| Ownership | Weighted BOR | Facilities | Implementing beds |
|---|---|---|---|
| Government | 97.6% | 314 | 54,995 |
| Private | 57.0% | 753 | 50,620 |

Government hospitals show much higher occupancy than private hospitals. Simple average BOR is 90.9% (government) and 55.1% (private); the bed-day-weighted figures are higher because larger hospitals tend to report higher occupancy.

### S3: Primary care availability

> How does reported BHS, RHU, and health-centre availability relative to population vary across provinces and cities?

* **Gold table**: `mart_area_service_profile` v1 (S3 section), v2 (reported_bhs, reported_health_centers columns).
* **Answer grain**: Province and city, 2018-2025.
* **Silver inputs**: `facilities_metric_silver` (FHSIS).
* **Answerable?**: Yes, with caveat.
* **Caveat**: FHSIS coverage is incomplete. Some areas are not reported every year. A zero count means the source reported zero; a null means no report was filed.

#### Verified finding (silver)

FHSIS area counts by year:

| Year | Areas |
|---|---|
| 2018 | 211 |
| 2019 | 197 |
| 2020 | 197 |
| 2021 | 197 |
| 2022 | 197 |
| 2023 | 140 |
| 2024 | 141 |
| 2025 | 142 |

Coverage dropped from 197 areas (2019-2022) to 140-142 (2023-2025). BHS per 10,000 population varies across provinces. The current dashboard has no dedicated S3 page: its Access page shows registry-based primary-care presence, while FHSIS BHS/RHU counts (S3) are query-only from `facilities_metric_silver`.

---

## Access (A1-A2)

### A1: No-hospital localities

> What share of municipalities and cities have no in-scope hospital, and how many residents live there?

* **Gold table**: `mart_area_service_profile` v2 (built).
* **Answer grain**: Municipality, rolled up to province and region.
* **Silver inputs**: `facilities_registry_silver`, `geography_silver`, `population_silver`.
* **Answerable?**: Yes.
* **Caveat**: Administrative absence only. Residents may use a hospital in a neighbouring locality.

#### Verified finding (v2)

Across 109 planning units, 1,114 localities have no hospital. The total population in those localities is approximately 38.1 million.

### A2: Level 3 hospital presence

> Which planning areas have no Level 3 hospital, and how does Level 3 presence vary?

* **Gold table**: `mart_area_service_profile` v2 (built).
* **Answer grain**: Province / HUC / NCR.
* **Silver inputs**: `facilities_registry_silver`, `geography_silver`.
* **Answerable?**: Yes, with caveat.
* **Caveat**: The planning unit must be defined: HUCs and NCR have no province row in PSGC. Gap ID G11.

#### Verified finding (v2)

Of 109 planning units, 37 have at least one Level 3 hospital. The remaining 72 planning units (66%) have no Level 3 hospital. Level 3 hospitals are concentrated in urban and regional centre areas.

---

## Workforce (W1-W2)

### W1: Workforce shortages

> Which areas have the lowest numbers of public doctors, nurses and midwives relative to population?

* **Gold table**: `fact_workforce_capacity` (28,071 rows, built), `mart_area_service_profile` v2 (built).
* **Answer grain**: Province x profession x year (2018-2024); municipality x profession (2025).
* **Silver inputs**: `workforce_headcount_silver`, FHSIS reported denominators, `population_silver`.
* **Answerable?**: Yes, with caveat.
* **Caveat**: Public sector only. Census population exists for 2015, 2020 and 2024 only; for other years use the FHSIS reported denominator and label it. Gap IDs G1, G8.

#### Verified finding (v2)

Average per-capita workforce across 109 planning units:

| Profession | Avg per 10,000 |
|---|---|
| Doctors | 0.5 |
| Nurses | 2.4 |
| Midwives | 2.9 |

These are low relative to WHO benchmarks. Specific areas with the lowest values can be identified by querying the v2 mart and ranking ascending.

### W2: Workforce composition

> How does public workforce composition vary between LGU-employed and DOH-deployed workers?

* **Gold table**: `fact_workforce_capacity` (built).
* **Answer grain**: Region or province x profession x year (2020-2025).
* **Silver inputs**: `workforce_headcount_silver`.
* **Answerable?**: Yes, with caveat.
* **Caveat**: 2019 employer split is incomplete: use totals only for 2019.

#### Verified finding (v2)

The average DOH-deployed share across planning units is 43.7%. This means roughly 44% of public health workers are DOH-deployed and 56% are LGU-employed, on average. Variation by area and profession can be queried from `fact_workforce_capacity`.

---

## Equity (E1-E2)

### E1: Poverty and service gaps

> Are areas with higher poverty associated with lower beds or public workers per population and poorer local hospital access?

* **Gold table**: `fact_area_indicator` (8,928 rows, built), `mart_area_service_profile` v2 (built).
* **Answer grain**: Province / HUC, poverty reference year next to supply snapshot year.
* **Silver inputs**: `socioeconomic_poverty_silver`, plus S1, A1, W1 inputs.
* **Answerable?**: Yes, with caveat.
* **Caveat**: Only comparison_eligible areas (poverty province may or may not include HUCs). Poverty is not published below province. Descriptive, not causal. Gap IDs G3, G11.
* **Finding**: The v2 mart has `poverty_incidence_pct` and `poverty_band` columns alongside beds, workforce, and access metrics. Scatter plots and rank correlations can be computed from this data. No specific correlation findings reported yet.

### E2: Service by poverty band

> How do service supply and government bed share differ by poverty band or LGU income class?

* **Gold table**: `fact_area_indicator` (built), `mart_area_service_profile` v2 (built).
* **Answer grain**: Poverty band or income class.
* **Silver inputs**: `socioeconomic_poverty_silver`, `geography_silver` (income class), facilities silver.
* **Answerable?**: Yes, with caveat.
* **Caveat**: Income class values need cleaning (4th*, 1st (as Mun), Special, -). Income class describes LGU revenue, not household income.

#### Verified finding (v2)

Beds per 10,000 and government bed share by poverty band:

| Poverty band | Planning units | Avg beds per 10k | Gov bed share |
|---|---|---|---|
| Under 10% | 37 | 10.8 | 62.3% |
| 10% to under 20% | 16 | 8.2 | 70.4% |
| 20% to under 30% | 13 | 6.2 | 60.2% |
| 30% or more | 1 | 8.3 | 61.6% |

Areas with lower poverty (under 10%) have more beds per 10,000 (10.8) than areas with 20-30% poverty (6.2). The pattern is not linear: the single area with 30%+ poverty has 8.3 beds per 10k. Government bed share is highest in the 10-20% band (70.4%) and lower in the under-10% band (62.3%). Sample sizes are small (1-37 units per band).

---

## Priority (P1-P2)

### P1: Priority areas

> Which areas combine high values of a selected disease-burden indicator with low service supply, poor access or socioeconomic disadvantage?

* **Gold table**: `mart_area_priority` (12,426 rows, built).
* **Answer grain**: Province / HUC.
* **Silver inputs**: All BQ1 facts.
* **Answerable?**: Gated. Needs N, S, A, W and E validated on the same analysis unit first.
* **Caveat**: The built `mart_area_priority` covers supply-only ranking. Full P1 needs all pillars. Gap IDs G10, G11.
* **Finding**: Supply-only priority ranking exists (12,426 rows). Disease-burden and equity dimensions are not yet integrated.

### P2: Ranking stability

> If a combined score is used, how stable are area rankings when weights and eligibility rules change?

* **Gold table**: `mart_capacity_gap` (not built), `priority_weight_params` (12 rows, built).
* **Answerable?**: Gated.
* **Caveat**: Weighting sets are a team decision, stored as a parameter table. Gap ID G10.
* **Finding**: Parameter table exists (12 rows) but the scoring script is not built.

---

## Case study (CASE)

> Do municipalities with higher reported TB notifications also have lower public workforce supply?

* **Gold table**: `mart_tb_case_study` (1,642 rows, built).
* **Answer grain**: Municipality (2025).
* **Silver inputs**: `diseases_metric_silver` (FHSIS TB), `workforce_headcount_silver`, `population_silver`.
* **Answerable?**: Optional.
* **Caveat**: Only municipalities with both values. Exploratory comparison.
* **Finding**: Mart built. 1,634 of 1,642 areas have 2025 TB notifications. 1,622 have doctors-per-10k data. Content verification pending.

---

## BQ2: Dengue surge stress test (previous scope)

> If a selected historical dengue outbreak recurred against the latest available hospital capacity, which regions or provinces would face the greatest estimated bed shortfalls under different assumptions?

* **Gold table**: `mart_surge_stress_test` (not built).
* **Answer grain**: Region x scenario; province x scenario.
* **Silver inputs**: `diseases_metric_silver`, facilities silver, `scenario_params`.
* **Answerable?**: Previous scope. Not an active deliverable.
* **Caveat**: If re-scoped, blocked until admission share and length-of-stay parameters are sourced. Gap ID G6.
* **Finding**: Not built. `mart_dengue_peak_capacity` (981 rows) supports D1 (wave selection) but D2-D5 are blocked.

---

## Supporting (SUP1-SUP6)

| ID | Question | Gold table | Built? | Finding |
|---|---|---|---|---|
| SUP1 | Cause-of-death by age group and region | `fact_disease_metric` (built) | Yes, with caveat | Gold model has no age dimension. Age group is a column, not a dimension. Content verification pending. |
| SUP2 | National composition of registered deaths | `fact_disease_metric` (built) | Yes, with caveat | Uses approved aggregation set. 2020-2021 COVID shift is a series break. Content verification pending. |
| SUP3 | Regional hospital and bed totals, 2020-2024 | `fact_facility_capacity` (built) | Yes | PSA published totals as a separate source. Not mixed with NHFR/HFSRB snapshot. Content verification pending. |
| SUP4 | Change in public workforce counts over time | `fact_workforce_capacity` (built) | Yes, with caveat | Nurse definition breaks in 2019. Two sources, two series. Content verification pending. |
| SUP5 | Out-of-pocket share of health spending | `fact_area_indicator` (built) | Yes | National context only. Content verification pending. |
| SUP6 | Evidence readiness | `mart_evidence_readiness` (built) | Yes | Reads quality schema directly. 30 rows (one per source/table). |

---

## Conditional (CON1-CON3)

| ID | Question | Status | Finding |
|---|---|---|---|
| CON1 | Distance to nearest Level 3 hospital | Needs input | `fact_area_access` built (1,642 rows) but no distance column. Needs validated coordinates. Not travel time. Gap ID G7. |
| CON2 | PSMO oncologists vs cancer estimates | Optional | `fact_workforce_capacity` and `fact_disease_metric` built. Manual join possible. Members-only directory. |
| CON3 | Local bed-day reconstruction | Previous scope (fed BQ2) | `diseases_hospital_encounters_silver` (restricted). One hospital, pneumonia only. Cannot validate dengue admission share. |

---

## Recommendations

The platform is a data engineering capstone. It does not make health policy recommendations. The following are next steps for the data, not policy advice:

1. **Verify gold fact table content** -- query each fact table and confirm values match expectations. Row counts are confirmed (2026-10-18); content verification is next.
2. **Integrate disease burden into the capacity gap mart** -- `mart_area_burden_indicator` (2,071 rows) exists but is not yet joined to `mart_area_service_profile` (109 rows). Full BQ1 needs this.
3. **Source BQ2 parameters (previous scope)** -- only if the dengue surge stress test is re-scoped. Dengue admission share and length-of-stay values from clinical literature or DOH.
4. **Add FHSIS primary-care visuals (S3)** -- the dashboard Access page shows registry-based presence only. BHS/RHU availability needs widgets or stays query-only. The gold mart has the data.
5. **Dashboard on gold -- done.** Dashboard datasets read `public_health.gold` tables and views (verified 2026-10-18).
6. **Add age group dimension** -- SUP1 needs an age dimension in gold.
7. **Clean income class values** -- E2 needs cleaned income class values.

---

## Method

All findings are computed from silver and gold tables using SQL. No statistical modeling is applied. No causal claims are made. All comparisons are descriptive. See [assumptions and limitations](../../01-context/assumptions-and-limitations.md) for the full list of interpretation rules.

Evidence: build logs in `public_health.quality.build_log` (85 succeeded builds: 2026-10-09, 2026-10-12, 2026-10-18) and the [2026-10-18 run record](../../06-evidence/2026-10-18-new-workspace-run.md). Row counts and aggregate values verified by COUNT(*), AVG, SUM, and MIN/MAX queries on 2026-10-18 against `public_health.gold` and `public_health.silver` schemas.
