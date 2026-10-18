# Conceptual model

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

The gold layer organizes data into a star-schema style model with dimensions and facts, then builds marts on top for specific business questions.

## Plain-language overview

The model answers one main question:

1. **BQ1**: Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

A previous-scope question (BQ2: if a historical dengue outbreak recurred, which areas would face bed shortfalls?) is outside the active scope.

To answer it, the platform brings together five types of data:

* **Who needs care** (Need) -- disease cases, deaths, and prevalence by area and time.
* **What supply exists** (Supply) -- hospitals, beds, primary care facilities, and their occupancy.
* **Who can reach care** (Access) -- which localities have a hospital, which have a Level 3 hospital.
* **Who staffs care** (Workforce) -- public doctors, nurses, and midwives by area.
* **Who can afford care** (Equity) -- poverty incidence, income class, health expenditure.

Each type comes from different sources with different grains (region vs province vs municipality, annual vs weekly vs snapshot). The gold model normalizes them to a common geography (`dim_geography`) and time (`dim_date`) so they can be joined.

## Entity groups

```
DIMENSIONS (describe the world)
  dim_geography  -- every PSGC area, from region to municipality
  dim_facility    -- every hospital and primary care facility
  dim_disease     -- every disease and cause of death
  dim_date        -- calendar dates
  dim_data_source -- every data source (for lineage)

FACTS (measure the world)
  fact_facility_capacity   -- beds and hospital counts per facility per snapshot
  fact_disease_metric      -- cases, deaths, prevalence per area per disease per period
  fact_workforce_capacity  -- headcounts per area per profession per year
  fact_area_indicator      -- poverty, expenditure, child mortality per area per period

MARTS (answer business questions)
  mart_area_service_profile    -- S1/S2/S3: supply-side dashboard mart
  mart_area_burden_indicator   -- N1-N4: disease burden per area
  mart_locality_service_presence -- A1/A2: which localities have which services
  mart_area_priority           -- P1: area priority ranking
  mart_area_evidence           -- SUP6: evidence readiness per area
  mart_evidence_readiness      -- SUP6: source coverage and QC pass rate
  mart_tb_case_study           -- CASE: TB notifications vs workforce
  mart_kidney_case_study       -- N2: kidney disease analysis
  mart_dengue_peak_capacity    -- N3/D1: dengue peak vs hospital capacity
```

## How facts connect to dimensions

| Fact | Joins to dim_geography on | Joins to dim_date on | Joins to dim_facility on | Joins to dim_disease on |
|---|---|---|---|---|
| `fact_facility_capacity` | `area_key` (facility location) | `snapshot_date` | `facility_key` | -- |
| `fact_disease_metric` | `area_key` | `date_key` | -- | `disease_key` |
| `fact_workforce_capacity` | `area_key` | `date_key` | -- | -- |
| `fact_area_indicator` | `area_key` | `date_key` | -- | -- |

All facts also join to `dim_data_source` on `source_key` for lineage.

## How marts combine facts

The main BQ1 mart (`mart_capacity_gap`, not built) would join:

```
mart_capacity_gap
  = fact_disease_metric     (need: disease burden per area)
  + fact_facility_capacity  (supply: beds per area)
  + fact_workforce_capacity (workforce: staff per area)
  + fact_area_indicator     (equity: poverty per area)
  + mart_locality_service_presence (access: hospital presence per locality)
  rolled up to the same analysis unit (province / HUC / NCR)
```

The currently built v2 `mart_area_service_profile` (109 rows, 62 columns) combines supply, workforce, and equity in a single wide table per planning unit:

```
mart_area_service_profile (v2)
  = fact_facility_capacity  (hospitals, beds, levels)
  + facilities_metric_silver (BHS, RHU, health centres)
  + fact_workforce_capacity (doctors, nurses, midwives, BHW)
  + fact_area_indicator     (poverty incidence, band)
  + population_silver        (population denominator)
  rolled up to planning unit (province / HUC / NCR)
```

Disease burden (N1-N4) is in `mart_area_burden_indicator` (2,071 rows) but is not yet joined to this mart. The legacy v1 `mart_area_service_profile` in `public_health.gold` (2,784 rows) uses a different grain: `supply_section x area_level x area x year x ownership x facility_level`.

## Design choices

* **Star schema, not snowflake.** Dimensions are flat tables, not nested. This keeps queries simple and fast on the SQL warehouse.
* **Surrogate keys.** Dimensions use `xxhash64` of the natural key as the primary key. This is stable across rebuilds and avoids string comparisons in joins.
* **One fact per domain.** Disease metrics, facility capacity, workforce, and area indicators are separate fact tables. They share `dim_geography` and `dim_date` but have different grains.
* **Marts denormalize for the dashboard.** Marts pre-compute joins and aggregations so the dashboard queries a single wide table.
* **Source priority is a seed table.** When multiple sources cover the same metric, `source_priority` stores the preference rule. This is a reviewed CSV, not derived from data.

See [logical data model and ERD](logical-data-model-and-erd.md) for the detailed entity-relationship diagram and [table catalog](table-catalog.md) for the full table list.
