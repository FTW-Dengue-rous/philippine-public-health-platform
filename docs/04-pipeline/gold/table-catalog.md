# Gold table catalog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

The gold layer lives in schema `public_health.gold`. The pipeline job runs scripts from `src/04_gold/` organised into `dimension/`, `fact/`, and `mart/` subfolders.

The model has 5 dimensions, 4 facts, 4 reference/seed tables, and 11 marts. Build order follows the numbered prefixes: 01-05 (dims) -> 06-09 (facts) -> 10-13 (refs) -> 14-15 (base marts) -> 16-20 (marts + fact_area_access) -> 21-24 (case studies + evidence readiness) -> gold_qc.

See [data-marts.md](data-marts.md) for the question-to-mart mapping and [data-dictionary.md](data-dictionary.md) for column definitions.

## Dimensions

| Table | Script | Grain | Primary key | Sources |
|---|---|---|---|---|
| `dim_geography` | `gold_01` | One row per PSGC area (region to sub-municipality) plus 7 named areas (Philippines, Foreign, etc.) | `area_key` (BIGINT, xxhash64) | `geography_silver`, `admin_boundaries_silver` |
| `dim_facility` | `gold_04` | One row per facility establishment | `facility_key` | `facilities_registry_silver`, `facilities_id_map_silver` |
| `dim_disease` | `gold_05` | One row per disease/cause | `disease_key` | `diseases_directory_silver` |
| `dim_date` | `gold_02` | One row per date | `date_key` | Generated (calendar) |
| `dim_data_source` | `gold_03` | One row per source key | `source_key` | `ingestion_metadata`, config YAMLs |

## Facts

| Table | Script | Grain | Primary key | Sources | Questions |
|---|---|---|---|---|---|
| `fact_facility_capacity` | `gold_06` | One row per facility per snapshot | `facility_key`, `snapshot_date` | `facilities_registry_silver`, `facilities_metric_silver` | S1, A1, A2, D3, SUP3 |
| `fact_disease_metric` | `gold_07` | One row per area x disease x period x source | `area_key`, `disease_key`, `date_key`, `source_key` | `diseases_metric_silver` | N1-N4, SUP1, SUP2, CASE |
| `fact_workforce_capacity` | `gold_08` | One row per area x profession x year | `area_key`, `profession`, `date_key` | `workforce_headcounts_silver` | W1, W2, SUP4 |
| `fact_area_indicator` | `gold_09` | One row per area x indicator x period | `area_key`, `indicator_key`, `date_key` | `socioeconomic_poverty_silver`, `facilities_metric_silver` | E1, E2, SUP5 |

## Reference and seed tables

| Table | Script | Purpose | Sources |
|---|---|---|---|
| `source_priority` | `gold_10` | Source preference rules per metric (which source wins when multiple cover the same area/year) | Reviewed CSV, `dim_data_source` |
| `ref_osm_healthsite_point` | `gold_12` | OSM healthsite points with matched geography | `facilities_osm_point_silver`, `dim_geography` |
| `area_coverage_map` | `gold_11` | Which areas each fact covers (coverage matrix) | All fact tables |
| `fact_default_views` | `gold_13` | Default views over each fact table for dashboard consumption | All facts, `source_priority` |

## Marts

| Table | Script | Grain | Purpose | Questions |
|---|---|---|---|---|
| `mart_locality_service_presence` | `gold_14` | One row per locality (city/municipality) | Which services are present in each locality | A1, A2 |
| `mart_base_planning_unit` | `gold_15` | One row per planning area (province/HUC/NCR) | Base planning unit reference for area-level analysis | BQ1 (analysis unit) |
| `mart_area_service_profile` | `gold_16` | One row per planning unit (province/HUC/NCR) | Supply-side questions S1, S2, S3, W1, E1, A1-A2 | S1, S2, S3, W1, E1, A1, A2 |
| `mart_area_burden_indicator` | `gold_17` | One row per area x disease x period | Disease burden per area | N1-N4 |
| `mart_area_evidence` | `gold_18` | One row per area | Evidence readiness per area (how many sources cover this area) | SUP6 |
| `mart_area_priority` | `gold_19` | One row per area | Area priority ranking based on supply and burden | P1 (partial) |
| `fact_area_access` | `gold_20` | One row per locality | Access indicators (distance, presence) | A1, A2, CON1 |
| `mart_tb_case_study` | `gold_21` | One row per locality | TB notifications vs workforce supply | CASE, N4 |
| `mart_kidney_case_study` | `gold_22` | One row per area | Kidney disease analysis | N2 (neoplasm) |
| `mart_dengue_peak_capacity` | `gold_23` | One row per area | Dengue peak vs capacity | N3, D1 |
| `mart_evidence_readiness` | `gold_24` | One row per source x table x build | Evidence readiness summary (QC pass rate, coverage, unmatched areas) | SUP6 |

## Build dependencies

```
01_dim_geography, 02_dim_date, 03_dim_data_source, 04_dim_facility, 05_dim_disease
  |
  +-> 06_fact_facility_capacity (needs dim_geography, dim_facility, dim_date, dim_data_source)
  +-> 07_fact_disease_metric (needs dim_geography, dim_disease, dim_date, dim_data_source)
  +-> 08_fact_workforce_capacity (needs dim_geography, dim_date, dim_data_source)
  +-> 09_fact_area_indicator (needs dim_geography, dim_date, dim_data_source)
        |
        +-> 10_source_priority, 12_ref_osm_healthsite_point
        +-> 11_area_coverage_map (needs all 4 facts)
        +-> 13_fact_default_views (needs source_priority + all 4 facts)
              |
              +-> 14_mart_locality_service_presence
                    |
                    +-> 15_mart_base_planning_unit
                          |
                          +-> 16_mart_area_service_profile (also needs 11, 08)
                          +-> 17_mart_area_burden_indicator (also needs 11, 10, 07)
                                |
                                +-> 18_mart_area_evidence (needs 16, 17)
                                +-> 19_mart_area_priority (needs 16, 17)
                          +-> 20_fact_area_access (needs 14, 12)
              +-> 21_mart_tb_case_study (needs 14, 07, 08)
              +-> 22_mart_kidney_case_study (needs 14, 11, 07)
              +-> 23_mart_dengue_peak_capacity (needs 14, 11, 07)
                    |
                    +-> 24_mart_evidence_readiness (needs 13, 18, 19, 20, 21, 22, 23)
                          |
                          +-> gold_qc
```

## Not yet built

| Table | Purpose | Status |
|---|---|---|
| `mart_capacity_gap` | BQ1 main mart: need, supply, access, workforce, equity per area | Not built (verified 2026-10-18). `mart_area_service_profile` (109 rows) partially covers it: supply, workforce, poverty. Disease burden integration remaining. |
| `mart_surge_stress_test` | BQ2 main mart (previous scope): replayed cases, bed demand, spare beds, shortfall | Previous scope. Not built; if re-scoped, blocked on admission share and LOS parameters. |

See [business questions](../../01-context/problem-and-business-context.md#analytical-questions) for the full framework.
