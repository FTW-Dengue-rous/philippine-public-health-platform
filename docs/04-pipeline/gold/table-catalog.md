# Gold table catalog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Gold builds into `public_health.gold` in numbered order: five dimensions (`gold_01`–`05`), four facts (`06`–`09`), shared seeds and views (`10`–`13`), then marts (`14`–`24`). The exact file-to-object map and dependencies are maintained in [`src/04_gold/README.md`](../../../src/04_gold/README.md#1-folder-layout-and-run-order).

| Group | Objects | Grain summary |
|---|---|---|
| Dimensions | `dim_geography`, `dim_date`, `dim_data_source`, `dim_facility`, `dim_disease` | One row per defined area, reporting period, source, facility, or disease. |
| Facts | `fact_facility_capacity`, `fact_disease_metric`, `fact_workforce_capacity`, `fact_area_indicator` | One source-defined observation at the fact's documented grain. |
| Shared objects | `source_priority`, `priority_weight_params`, `huc_province_crosswalk`, `area_coverage_map`, `ref_osm_healthsite_point`, `v_*` | Reviewed selection rules, coverage mapping, map reference data, and safe default views. |
| Marts | `mart_*` and `fact_area_access` | Question-specific outputs for the dashboard and analysis. |

Use the [technical data dictionary](gold-data-dictionary.md) for columns and the [data marts page](data-marts.md) for business-question mapping. `ref_osm_healthsite_point` supports maps and distance analysis; it is not a facility count.
