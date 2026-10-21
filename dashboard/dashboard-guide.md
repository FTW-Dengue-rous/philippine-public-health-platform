# Dashboard guide

Owner: Shiena Arico, Margarette Legaspi
Last updated: 2026-10-21

The dashboard is a Databricks Lakeview dashboard: **Philippine Public Health Platform**.

## Purpose and audience

The dashboard answers the platform's main business question (BQ1): which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

It is intended for public health planners, DOH programme managers, data analysts, and capstone reviewers. It shows where health-service availability falls short of population need and disease burden, across the country's planning areas.

See [business context](../docs/01-context/problem-and-business-context.md) for the full question framework, user profiles, and the analytical question map.

## Summary

The current dashboard (gold build verified 2026-10-18) reads gold tables and views in `public_health.gold`. It is organised by theme rather than by question: eight pages, all populated. It covers the supply-side questions (S1, S2; S3 partially through registry-based presence) plus highlights of need, workforce, equity, access, priority, and case studies (N1-N4, W1, E1, E2 partial, A1, P1, P2, D1). Questions without visuals are query-only (see below).

Dashboard file: `dashboard/Philippine Public Health Platform.lvdash.json`

## Pages

All eight pages are populated. There is no separate S3 page: the old empty S3 draft page was replaced by this theme-based design.

### Overview

National KPIs (population, registered deaths, beds per 10,000, municipalities with no hospital, LGU- and DOH-hired doctors and nurses per 10,000, poverty incidence), top priority provinces, and a beds map. Covers highlights of S1, W1, E1, P1.

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

Not shown on any dashboard page; query the gold tables instead. See the [gold data dictionary](../docs/04-pipeline/gold/gold-data-dictionary.md) for column details.

* FHSIS BHS/RHU/health-centre counts (S3) -- `mart_area_service_profile` (gold); `facilities_metric_silver` holds the raw counts in silver
* Workforce employer split, LGU vs DOH (W2) -- `fact_workforce_capacity`
* Level 3 hospital presence by area (A2) -- `fact_area_access`
* Income-class analysis (E2) -- `fact_area_indicator` and `dim_geography`
* Supporting analyses SUP1-SUP5 -- gold fact tables

## How to use

1. Open the dashboard in the Databricks UI.
2. Select one of the eight pages.
3. Use filters to narrow by area, ownership, or level.
4. Hover over visuals for details.
5. For definitions, see [metric definitions](../docs/04-pipeline/gold/metric-definitions.md).

## Data freshness

The dashboard reflects the latest gold build in `public_health.gold`. It refreshes when opened. To confirm it is current:
1. Check the latest pipeline job run succeeded. See the [runbook](../docs/07-operations/runbook.md) for how to run the pipeline and verify QC results.
2. Run: `SELECT max(finished_at) FROM public_health.quality.build_log WHERE target_table LIKE '%public_health.gold%'`
3. Verify the dashboard page shows data.

If `quality.build_log` is not available in your workspace, trace freshness manually from the silver `_source_*` lineage columns. See the [data lineage map](../docs/02-data/data-lineage-map.md).

## Interpretation cautions

* **Zero vs missing**: A zero count means the source reported zero. An empty cell means no data was reported. See [assumptions](../docs/01-context/assumptions.md).
* **Not listed does not mean absent**: A facility not listed in a registry does not prove it does not exist. Every label says "recorded". See [limitations and recommendations](../docs/01-context/limitations-and-recommendations.md), LM-03.
* **Mixed years**: Sources span different years (registry 2026, census 2024, disease data 2018 to 2025). Never compare partial years with full years without adjustment. Every chart shows the years it uses. See LM-02.
* **Population year**: Population is from the 2024 census. Rates are null when the count year and population year are more than 2 years apart (O-15). There is no fallback to an earlier census year. See [metric definitions](../docs/04-pipeline/gold/metric-definitions.md), rule 3.
* **Straight-line distances**: Distance to the nearest recorded hospital is a straight line between area centres, not travel distance or time. The target is the nearest locality with a recorded hospital. See LM-04.
* **Modelled vs reported**: IHME values are modelled estimates, not registered counts. They are kept separate from reported values in the marts. See LM-13.
* **Claims geography**: PhilHealth claims show the place of care (facility location), not the patient's residence. Nobody can measure travel for care from claims data. See LM-10.
* **Association is not cause**: A link between two figures does not prove that one causes the other. See SL-02.
* **Restricted data**: Several dashboard pages use FOI-released or licence-restricted sources (bed occupancy, dengue, PhilHealth claims, IHME). These appear as aggregates only; cells built from fewer than 3 records are suppressed. Do not export restricted charts outside the project without confirming terms with each FOI officer. See [data governance](../docs/08-governance/data-governance.md).
* **No causal claims**: The platform does not establish causal effects or measure real-world impact. Treat each result as a lead to verify, not a confirmed fact. See SL-09.
* **Workforce coverage**: Health worker counts cover LGU-hired and DOH-hired workers recorded in FHSIS only, for every profession shown — not just doctors. They do not represent the entire Philippine healthcare workforce and exclude private-sector workers. Ratios per 10,000 population use this limited coverage. A missing count means no count was reported, not that zero workers are present. These counts alone do not prove an overall workforce shortage. See [metric definitions](../docs/04-pipeline/gold/metric-definitions.md), section 3.

Full lists of assumptions (AS-xx), data limitations (LM-xx), and study limitations (SL-xx) are in [assumptions](../docs/01-context/assumptions.md) and [limitations and recommendations](../docs/01-context/limitations-and-recommendations.md).

## Troubleshooting

| Symptom | What to check |
|---|---|
| A page shows no data | The gold tables may not be built. Run `SELECT count(*) FROM public_health.gold.dim_geography` to confirm the schema exists. If not, run the pipeline (see the [runbook](../docs/07-operations/runbook.md)). |
| A page shows stale data | The dashboard refreshes when opened. If values seem old, check the latest pipeline run and the `quality.build_log` query in Data freshness above. |
| A filter shows no options | The filter dataset may have failed. Check the dataset query in the dashboard JSON for errors. Open the dashboard in edit mode and click the dataset to see the query and error. |
| A chart shows "suppressed" | This is expected for restricted data. Cells built from fewer than 3 records are suppressed. See [data governance](../docs/08-governance/data-governance.md). |
| Distance or map widgets are blank | The widget needs `center_lat` and `center_lon` from `dim_geography`. Areas without coordinates have no map shape. See LM-16. |

For pipeline failures, see the [runbook](../docs/07-operations/runbook.md) and [troubleshooting](../docs/07-operations/troubleshooting.md).

## Related documentation

* [Business context and question framework](../docs/01-context/problem-and-business-context.md)
* [Assumptions](../docs/01-context/assumptions.md) and [limitations and recommendations](../docs/01-context/limitations-and-recommendations.md)
* [Metric definitions](../docs/04-pipeline/gold/metric-definitions.md)
* [Gold data dictionary](../docs/04-pipeline/gold/gold-data-dictionary.md)
* [Data governance](../docs/08-governance/data-governance.md)
* [Runbook](../docs/07-operations/runbook.md) and [troubleshooting](../docs/07-operations/troubleshooting.md)
* [Data lineage map](../docs/02-data/data-lineage-map.md)
* [Known issues and backlog](../docs/08-governance/known-issues-and-backlog.md)
