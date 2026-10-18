# Gold layer

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

The gold layer builds analytical marts and dimensions from silver tables for dashboard consumption. It is the analytical layer that answers the platform's business questions (BQ1 and its sub-questions N1-N4, S1-S3, A1-A2, W1-W2, E1-E2, P1-P2, SUP1-SUP6, CASE; BQ2 and D1-D5 are previous scope). See [business context](../../01-context/problem-and-business-context.md) for the full question framework and traceability table.

## Active model: v2

The pipeline job deploys **data model v2** from `src/04_gold/test_v2/`. Scripts are named `gold_v2_NN_<name>.sql` and build into schema `public_health.test_gold2`. When promoted to production, the schema name changes to `public_health.gold`.

The v1 scripts in `src/04_gold/test/` remain in the repository for comparison but are not deployed by the job. They built into `public_health.test_gold`.

**Decision**: The team chose v2 on 2026-10-14 because it is self-contained (no reads from v1), uses a cleaner star schema with 5 dimensions and 4 facts, and supports all business questions.

## v2 data model

5 dimensions, 4 facts, 4 reference tables, 11 marts. See [table catalog](table-catalog.md) for the full list and [logical data model](logical-data-model-and-erd.md) for the ERD.

```
Dimensions:  dim_geography, dim_facility, dim_disease, dim_date, dim_data_source
Facts:       fact_facility_capacity, fact_disease_metric, fact_workforce_capacity, fact_area_indicator
Reference:   source_priority, ref_osm_healthsite_point, area_coverage_map, fact_default_views
Marts:       mart_locality_service_presence, mart_base_planning_unit,
             mart_area_service_profile, mart_area_burden_indicator,
             mart_area_evidence, mart_area_priority, fact_area_access,
             mart_tb_case_study, mart_kidney_case_study, mart_dengue_peak_capacity,
             mart_evidence_readiness
```

Build order: 00 -> {11, 21, 31, 12, 13} -> {20, 30, 35, 40} -> {41, 43, 42, 44} -> 51 -> 52 -> {53, 54} -> {55, 56, 57} -> {61, 62, 63} -> 71.

## Key mart: mart_area_service_profile (v2)

The v2 mart is a wide table with one row per planning unit (province, HUC, or NCR district) and 62 columns covering hospital supply (S1), bed occupancy (S2), primary care (S3), workforce (W1), poverty (E1), and access (A1-A2) in a single row.

| Property | Value |
|---|---|
| Table | `public_health.test_gold2.mart_area_service_profile` |
| Script | `gold_v2_53_mart_area_service_profile.sql` |
| Grain | One row per planning unit (province / HUC / NCR) |
| Rows | 109 |
| Columns | 62 |
| Sources | All silver tables via fact tables |

Key columns include: `planning_unit_key`, `area_code`, `area_name`, `unit_level`, `population`, `hospitals`, `beds`, `beds_per_10k`, `beds_level1/2/3`, `government_beds`, `government_bed_share`, `level3_hospitals`, `highest_hospital_level`, `localities`, `localities_without_hospital`, `population_without_hospital`, `licensed_primary_care_facilities_recorded`, `reported_bhs`, `reported_health_centers`, `reported_bhs_per_10k`, `reported_health_centers_per_10k`, `doctors`, `nurses`, `midwives`, `bhw`, `doctors_per_10k`, `nurses_per_10k`, `midwives_per_10k`, `bhw_per_10k`, `doh_deployed_share`, `poverty_incidence_pct`, `poverty_band`, and quintile rankings for each per-capita metric.

This mart effectively answers BQ1 supply, access, workforce, and equity questions per planning unit. Disease burden (N1-N4) is in `mart_area_burden_indicator` (2,071 rows).

The legacy v1 `mart_area_service_profile` in `public_health.gold` (2,784 rows, built 2026-10-13; count verified 2026-10-18) uses a different grain: `supply_section x area_level x area_key x year x ownership x facility_level`. The dashboard reads the v2 `test_gold2` tables (verified 2026-10-18: the dashboard JSON references `test_gold2` 63 times and the v1 table 0 times).

See [data dictionary](data-dictionary.md) for column definitions, [metric definitions](metric-definitions.md) for formulas, [data-marts.md](data-marts.md) for the question-to-mart mapping, and [sample queries](sample-queries.md) for usage examples.
