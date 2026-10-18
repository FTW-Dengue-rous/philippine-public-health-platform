# Findings report

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Insights from the built gold marts. All numbers come from the latest verified build of `mart_area_service_profile` (2026-10-13, ~2,784 rows). Insights from other gold tables are marked as unverified.

See [metric definitions](metric-definitions.md) for formulas and [assumptions and limitations](../../01-context/assumptions-and-limitations.md) for interpretation rules.

## S1: Hospital availability

### Hospital distribution

The registry contains hospitals across 94 provinces and 536 cities/municipalities. Government and private hospitals are split roughly evenly by count, but authorized bed capacity is concentrated in government hospitals.

### Beds per 10,000 population

Beds per 10,000 varies widely across provinces. Areas with the lowest beds-per-capita tend to be smaller or rural provinces. Some NCR districts have null population, so their rate is null (not zero).

**Caveat**: Authorized beds are licensed capacity, not staffed beds. The actual usable capacity may be lower. Population is from 2024 (closest available), while the facility snapshot is from 2026-09-29.

### Level 3 hospital presence

Level 3 hospitals (the highest capability) are concentrated in urban areas. Many provinces have no Level 3 hospital. This is documented in `mart_locality_service_presence` and will inform question A2.

## S2: Bed occupancy

### Occupancy rates (2025, baseline eligible)

Government hospitals show higher occupancy than private hospitals. The weighted BOR (bed-day-weighted) for government hospitals is approximately 97.9%, while private hospitals are approximately 55.4%.

**Caveat**: The 2025 reporting cohort is much larger (~1,160 facilities) than 2020-2024 (~120-185 facilities per year). Comparing 2025 with earlier years is not valid because the reporting cohort changed. Occupancy over 150% is excluded as a data error. Occupancy over 100% may indicate undercounting of beds or overcrowding.

### Reporting coverage

Not all hospitals report occupancy. The `facility_count_reporting` column shows how many hospitals reported in each area. Areas with few reporting hospitals have less reliable averages.

## S3: Primary care availability

### BHS, RHU, and health centres

FHSIS reports BHS, RHU, MHC, and CHC counts by province and city from 2018 to 2025. The latest year (2025) covers 215 areas. BHS per 10,000 population varies across provinces.

**Caveat**: FHSIS coverage is incomplete. Some areas are not reported every year. A zero count means the source reported zero; a null means no report was filed. The S3 dashboard page exists but has no widgets yet.

## Unverified findings (gold v2 tables)

The following gold tables are built by the job but their content has not been independently verified:

* `fact_disease_metric` -- disease cases, deaths, and prevalence per area.
* `fact_workforce_capacity` -- public workforce headcounts per area.
* `fact_area_indicator` -- poverty and socioeconomic indicators per area.
* `mart_area_burden_indicator` -- disease burden per area.
* `mart_area_priority` -- area priority ranking.
* `mart_tb_case_study`, `mart_kidney_case_study`, `mart_dengue_peak_capacity` -- case study marts.

These tables should be queried and their results verified before reporting findings from them.

## Recommendations

The platform is a data engineering capstone. It does not make health policy recommendations. The following are next steps for the data, not policy advice:

1. **Verify gold v2 fact tables** -- query each fact table and confirm row counts and content match expectations.
2. **Build `mart_capacity_gap`** -- the main BQ1 mart joining need, supply, access, workforce, and equity. This requires the province/HUC/NCR analysis unit rule.
3. **Source BQ2 parameters** -- dengue admission share and length-of-stay values from clinical literature or DOH.
4. **Populate the S3 dashboard page** -- add widgets for BHS, RHU, and health centre availability.
5. **Add age group dimension** -- SUP1 (cause-of-death by age group) needs an age dimension in gold.
6. **Clean income class values** -- E2 needs cleaned income class values (4th*, 1st (as Mun), Special, -).

## Method

All findings are computed from silver and gold tables using SQL. No statistical modeling is applied. No causal claims are made. All comparisons are descriptive. See [assumptions and limitations](../../01-context/assumptions-and-limitations.md) for the full list of interpretation rules.

Evidence: build logs in `public_health.quality.build_log` and row counts verified during 2026-10-09 to 2026-10-13 Databricks runs.
