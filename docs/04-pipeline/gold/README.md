# Gold layer

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

The gold layer builds analytical marts and dimensions from silver tables for dashboard consumption.

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

## Key mart: `mart_area_service_profile`

The primary dashboard mart. Answers supply-side questions S1, S2, S3.

| Property | Value |
|---|---|
| Table | `public_health.test_gold2.mart_area_service_profile` |
| Script | `gold_v2_53_mart_area_service_profile.sql` |
| Grain | `supply_section x area_level x area_key x year x ownership x facility_level` |
| Rows | ~2,784 |
| Columns | 29 |
| Sources | All from silver |

### Sections

| Section | Area level | Rows | Distinct areas | Years |
|---|---|---|---|---|
| S1_hospital_supply | City/Mun | 904 | 536 | null (current) |
| S1_hospital_supply | Province | 331 | 94 | null |
| S2_hospital_occupancy | Province | 281 | 84 | 2025 |
| S3_primary_care_supply | City/Mun | 624 | 112 | 2018-2025 |
| S3_primary_care_supply | Province | 644 | 82 | 2018-2025 |

See [data dictionary](data-dictionary.md) for column definitions, [metric definitions](metric-definitions.md) for formulas, [data-marts.md](data-marts.md) for the question-to-mart mapping, and [sample queries](sample-queries.md) for usage examples.
