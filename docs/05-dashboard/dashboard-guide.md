# Dashboard guide

Owner: Shiena Arico, Margarette Legaspi
Last updated: 2026-10-19

The dashboard is a Databricks Lakeview dashboard: **Philippine Public Health Platform**.

The current dashboard (updated 2026-10-16) reads gold tables and views in `public_health.gold`. It is organised by theme rather than by question: eight pages, all populated. It covers the supply-side questions (S1, S2; S3 partially through registry-based presence) plus highlights of need, workforce, equity, access, priority, and case studies (N1-N4, W1, E1, E2 partial, A1, P1, P2, D1). Questions without visuals are query-only (see below). See [business context](../01-context/problem-and-business-context.md) for the full question framework.

Dashboard file: `dashboard/Philippine Public Health Platform.lvdash.json`

## Pages

All eight pages are populated. There is no separate S3 page: the old empty S3 draft page was replaced by this theme-based design.

### Overview

National KPIs (population, registered deaths, beds per 10,000, municipalities with no hospital, government doctors and nurses per 10,000, poverty incidence), top priority provinces, and a beds map. Covers highlights of S1, W1, E1, P1.

### Need

Leading causes of registered deaths (2023 vs 2024), modelled disease burden by province, dengue cases and deaths by month. Covers N1, N2 (modelled), N3.

### Gaps and equity

Beds per 10,000 by hospital level and ownership per planning unit, health workers per 10,000 by poverty band, poverty vs beds, tuberculosis priority areas, ranking stability, and evidence gaps. Covers S1, E1, E2 (partial), P1, P2, SUP6 (partial).

### Access

Localities with no recorded hospital and residents affected, localities with no licensed primary care, service presence, distance to nearest recorded hospital, and PhilHealth claims per 100,000. Covers A1, S3 (registry-based presence only).

### PhilHealth Claims

Claims paid by province, with a claims package filter.

### Case studies

Tuberculosis analysis by wealth fifth (workforce, TPT, treatment success), top 20 municipalities by notifications, and kidney care (dialysis claims vs stations). Covers N4, CASE.

### Preparedness

Dengue by region and month, dengue peak vs recorded beds, and hospital occupancy by province. Covers N3, S2, D1.

### About data

Data sources, pipeline status per table, and evidence readiness. Covers SUP6.

## Dashboard datasets

The dashboard has 41 datasets querying `public_health.gold` views and marts. Key sources:

* `v_facility_capacity_totals`, `fact_facility_capacity`, `mart_area_service_profile` -- supply (S1, S2)
* `v_disease_metric_totals`, `fact_disease_metric` -- need (N1, N2, N3, N4)
* `v_workforce_preferred`, `fact_workforce_capacity` -- workforce (W1)
* `v_area_indicator_latest`, `fact_area_indicator` -- socioeconomic indicators (E1, E2)
* `mart_locality_service_presence`, `fact_area_access` -- access (A1, A2, S3 presence)
* `mart_area_priority`, `mart_tb_case_study`, `mart_kidney_case_study`, `mart_dengue_peak_capacity`, `mart_evidence_readiness` -- priority, case studies, preparedness, readiness
* `dim_geography`, `dim_date`, `dim_data_source` -- reference joins

## Query-only data

Not shown on any dashboard page; query the gold tables instead:

* FHSIS BHS/RHU/health-centre counts (S3) -- `facilities_metric_silver` and gold tables
* Workforce employer split, LGU vs DOH (W2) -- `fact_workforce_capacity`
* Level 3 hospital presence by area (A2) -- `fact_area_access`
* Income-class analysis (E2) -- `fact_area_indicator` and `dim_geography`
* Supporting analyses SUP1-SUP5 -- gold fact tables

## How to use

1. Open the dashboard in the Databricks UI.
2. Select one of the eight pages.
3. Use filters to narrow by area, ownership, or level.
4. Hover over visuals for details.
5. For definitions, see [metric definitions](../04-pipeline/gold/metric-definitions.md).

## Data freshness

The dashboard reflects the latest gold build in `public_health.gold`. To confirm it is current:
1. Check the latest pipeline job run succeeded.
2. Run: `SELECT max(finished_at) FROM public_health.quality.build_log WHERE target_table LIKE '%public_health.gold%'`
3. Verify the dashboard page shows data.

## Interpretation cautions

* **Zero vs missing**: A zero count means the source reported zero. An empty cell means no data was reported. See [assumptions](../01-context/assumptions-and-limitations.md).
* **Recorded is not absence**: A facility not listed does not prove it does not exist.
* **Population year**: Population is from 2024 (or closest available). Facility data may be from a different snapshot date.
* **Restricted data**: The Preparedness page's bed-occupancy charts use FOI-restricted data. Do not export or share them outside the project.
