# Dashboard guide

Owner: Cristina Villota
Last updated: 2026-10-15

The dashboard is a Databricks Lakeview dashboard: **Philippine Public Health Platform**.

Dashboard file: `dashboard/Philippine Public Health Platform.lvdash.json`

## Pages

### Page 1: Title

Title page with platform name and description.

### S1 — Hospital Availability by Level & Ownership

* **Question**: How does hospital availability (counts and authorized beds relative to population) vary by hospital level and ownership across planning areas?
* **Source**: `public_health.gold.mart_area_service_profile` where `supply_section = 'S1_hospital_supply'`.
* **Visuals**: Hospital counts, authorized beds, beds per 10,000 population by area, ownership, and facility level.
* **Filters**: Area level (City/Mun or Province), ownership (Government/Private), facility level.
* **Metrics**: See [metric definitions](../04-pipeline/gold/metric-definitions.md) — S1 section.
* **Data freshness**: Current snapshot (no year dimension; reflects the latest registry build).
* **Limitations**: Population may be null for some NCR areas. Beds per 10,000 pop is null when population is null.

### S2 — Hospital Bed Occupancy

* **Question**: How does bed occupancy differ across areas and between government and private hospitals?
* **Source**: `public_health.gold.mart_area_service_profile` where `supply_section = 'S2_hospital_occupancy'`.
* **Visuals**: Average BOR, percentage of hospitals with BOR over 100%, weighted BOR by ownership.
* **Filters**: Province, ownership (Government/Private).
* **Year**: 2025 (latest).
* **Filter**: `baseline_eligible = true` (facilities with comparable reports).
* **Metrics**: See [metric definitions](../04-pipeline/gold/metric-definitions.md) — S2 section.
* **Limitations**: 96 rows have null `psgc_code` (NCR districts, historical Maguindanao). BOR > 150 excluded as data error.

### S3 — BHS, RHU & Health Centre Availability

* **Question**: How does reported BHS, RHU, and health-centre availability relative to population vary across provinces and cities?
* **Source**: `public_health.gold.mart_area_service_profile` where `supply_section = 'S3_primary_care_supply'`.
* **Status**: Draft. Page exists but has no widgets yet.
* **Metrics**: See [metric definitions](../04-pipeline/gold/metric-definitions.md) — S3 section.
* **Coverage**: 2018–2025, province and city levels.
* **Source**: FHSIS (`facilities_metric_silver` where `_source_key = 'doh_fhsis_demographic'`).

## Dashboard datasets

The dashboard has 19 datasets querying `mart_area_service_profile` and silver tables directly. Key datasets:

| Dataset | Section | Query target |
|---|---|---|
| `hospital_detail` | S1 | `facilities_registry_silver` + geography |
| `s1_top20_provinces` | S1 | Registry aggregated to province |
| `s1_beds_per_capita` | S1 | Registry + population |
| `s2_bor_detail` | S2 | `facilities_bed_occupancy_silver` (2025, baseline eligible) |
| `s2_province_summary` | S2 | BOR aggregated to province |
| `s2_top20_prov_bor` | S2 | Top 20 provinces by BOR |
| `s3_explore` | S3 | `facilities_metric_silver` (FHSIS) |
| `s3_totals` | S3 | National totals, latest year |

## How to use

1. Open the dashboard in the Databricks UI.
2. Select a page (S1, S2, or S3).
3. Use filters to narrow by area, ownership, or level.
4. Hover over visuals for details.
5. For definitions, see [metric definitions](../04-pipeline/gold/metric-definitions.md).

## Data freshness

The dashboard reflects the latest gold mart build. To confirm it is current:
1. Check the latest pipeline job run succeeded.
2. Run: `SELECT max(finished_at) FROM public_health.quality.build_log WHERE target_table LIKE '%gold%'`
3. Verify the dashboard page shows data.

## Interpretation cautions

* **Zero vs missing**: A zero count means the source reported zero. An empty cell means no data was reported. See [assumptions](../01-context/assumptions-and-limitations.md).
* **Recorded is not absence**: A facility not listed does not prove it does not exist.
* **Population year**: Population is from 2024 (or closest available). Facility data may be from a different snapshot date.
* **Restricted data**: S2 bed occupancy uses FOI-restricted data. Do not export or share S2 data outside the project.
