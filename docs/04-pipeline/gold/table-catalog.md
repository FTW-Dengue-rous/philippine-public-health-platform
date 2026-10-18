# Gold table catalog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

The gold layer (data model v2) lives in schema `public_health.test_gold2`. The pipeline job runs all v2 scripts in `src/04_gold/test_v2/`. When promoted to production, the schema name changes to `public_health.gold`.

The model has 5 dimensions, 4 facts, 4 reference/seed tables, and 11 marts. Build order follows the numbered prefixes: 00 (setup) -> 11-13, 21, 31 (dims) -> 20, 30, 35, 40 (facts) -> 41-44 (refs) -> 51-57 (marts spine) -> 61-63 (case studies) -> 71 (evidence readiness).

See [data-marts.md](data-marts.md) for the question-to-mart mapping and [data-dictionary.md](data-dictionary.md) for column definitions.

## Dimensions

| Table | Script | Grain | Primary key | Sources |
|---|---|---|---|---|
| `dim_geography` | `gold_v2_11` | One row per PSGC area (region to sub-municipality) plus 7 named areas (Philippines, Foreign, etc.) | `area_key` (BIGINT, xxhash64) | `geography_silver`, `admin_boundaries_silver` |
| `dim_facility` | `gold_v2_21` | One row per facility establishment | `facility_key` | `facilities_registry_silver`, `facilities_id_map_silver` |
| `dim_disease` | `gold_v2_31` | One row per disease/cause | `disease_key` | `diseases_directory_silver` |
| `dim_date` | `gold_v2_12` | One row per date | `date_key` | Generated (calendar) |
| `dim_data_source` | `gold_v2_13` | One row per source key | `source_key` | `ingestion_metadata`, config YAMLs |

## Facts

| Table | Script | Grain | Primary key | Sources | Questions |
|---|---|---|---|---|---|
| `fact_facility_capacity` | `gold_v2_20` | One row per facility per snapshot | `facility_key`, `snapshot_date` | `facilities_registry_silver`, `facilities_metric_silver` | S1, A1, A2, D3, SUP3 |
| `fact_disease_metric` | `gold_v2_30` | One row per area x disease x period x source | `area_key`, `disease_key`, `date_key`, `source_key` | `diseases_metric_silver` | N1-N4, SUP1, SUP2, CASE |
| `fact_workforce_capacity` | `gold_v2_35` | One row per area x profession x year | `area_key`, `profession`, `date_key` | `workforce_headcounts_silver` | W1, W2, SUP4 |
| `fact_area_indicator` | `gold_v2_40` | One row per area x indicator x period | `area_key`, `indicator_key`, `date_key` | `socioeconomic_poverty_silver`, `facilities_metric_silver` | E1, E2, SUP5 |

## Reference and seed tables

| Table | Script | Purpose | Sources |
|---|---|---|---|
| `source_priority` | `gold_v2_41` | Source preference rules per metric (which source wins when multiple cover the same area/year) | Reviewed CSV, `dim_data_source` |
| `ref_osm_healthsite_point` | `gold_v2_43` | OSM healthsite points with matched geography | `facilities_osm_point_silver`, `dim_geography` |
| `area_coverage_map` | `gold_v2_42` | Which areas each fact covers (coverage matrix) | All fact tables |
| `fact_default_views` | `gold_v2_44` | Default views over each fact table for dashboard consumption | All facts, `source_priority` |

## Marts

| Table | Script | Grain | Purpose | Questions |
|---|---|---|---|---|
| `mart_locality_service_presence` | `gold_v2_51` | One row per locality (city/municipality) | Which services are present in each locality | A1, A2 |
| `mart_base_planning_unit` | `gold_v2_52` | One row per planning area (province/HUC/NCR) | Base planning unit reference for area-level analysis | BQ1 (analysis unit) |
| `mart_area_service_profile` | `gold_v2_53` | `supply_section x area_level x area_key x year x ownership x facility_level` | Supply-side questions S1, S2, S3 | S1, S2, S3 |
| `mart_area_burden_indicator` | `gold_v2_54` | One row per area x disease x period | Disease burden per area | N1-N4 |
| `mart_area_evidence` | `gold_v2_55` | One row per area | Evidence readiness per area (how many sources cover this area) | SUP6 |
| `mart_area_priority` | `gold_v2_56` | One row per area | Area priority ranking based on supply and burden | P1 (partial) |
| `fact_area_access` | `gold_v2_57` | One row per locality | Access indicators (distance, presence) | A1, A2, CON1 |
| `mart_tb_case_study` | `gold_v2_61` | One row per locality | TB notifications vs workforce supply | CASE, N4 |
| `mart_kidney_case_study` | `gold_v2_62` | One row per area | Kidney disease analysis | N2 (neoplasm) |
| `mart_dengue_peak_capacity` | `gold_v2_63` | One row per area | Dengue peak vs capacity | N3, D1 |
| `mart_evidence_readiness` | `gold_v2_71` | One row per source x table x build | Evidence readiness summary (QC pass rate, coverage, unmatched areas) | SUP6 |

## Build dependencies

```
00_setup
  |
  +-> 11_dim_geography, 21_dim_facility, 31_dim_disease, 12_dim_date, 13_dim_data_source
        |
        +-> 20_fact_facility_capacity (needs dim_geography, dim_facility, dim_date, dim_data_source)
        +-> 30_fact_disease_metric (needs dim_geography, dim_disease, dim_date, dim_data_source)
        +-> 35_fact_workforce_capacity (needs dim_geography, dim_date, dim_data_source)
        +-> 40_fact_area_indicator (needs dim_geography, dim_date, dim_data_source)
              |
              +-> 41_source_priority, 43_ref_osm_healthsite_point
              +-> 42_area_coverage_map (needs all 4 facts)
              +-> 44_fact_default_views (needs source_priority + all 4 facts)
                    |
                    +-> 51_mart_locality_service_presence
                          |
                          +-> 52_mart_base_planning_unit
                                |
                                +-> 53_mart_area_service_profile (also needs 42, 35)
                                +-> 54_mart_area_burden_indicator (also needs 42, 41, 30)
                                      |
                                      +-> 55_mart_area_evidence (needs 53, 54)
                                      +-> 56_mart_area_priority (needs 53, 54)
                                +-> 57_fact_area_access (needs 51, 43)
                    +-> 61_mart_tb_case_study (needs 51, 30, 35)
                    +-> 62_mart_kidney_case_study (needs 51, 42, 30)
                    +-> 63_mart_dengue_peak_capacity (needs 51, 42, 30)
                          |
                          +-> 71_mart_evidence_readiness (needs 44, 55, 56, 57, 61, 62, 63)
```

## Not yet built

| Table | Purpose | Status |
|---|---|---|
| `mart_capacity_gap` | BQ1 main mart: need, supply, access, workforce, equity per area | Designed, not built. Needs province+HUC+NCR analysis unit. |
| `mart_surge_stress_test` | BQ2 main mart: replayed cases, bed demand, spare beds, shortfall | Needs input. Blocked on admission share and LOS parameters. |
| `priority_weight_params` | P2 weighting sets | Gated. Team decision. |

See [business questions](../../01-context/problem-and-business-context.md#analytical-questions) for the full framework.
