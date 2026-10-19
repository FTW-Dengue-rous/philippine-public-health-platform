# Logical data model and ERD

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

The gold data model lives in schema `public_health.gold`. It uses a star schema with 5 dimensions and 4 facts.

BQ1 is the platform's only main business question: Which areas show the largest gaps in health-service availability relative to population and selected indicators of disease burden, and how do these gaps differ by socioeconomic conditions?

## Design rationale

The team chose the current star-schema design (5 dimensions, 4 facts) on 2026-10-14 because it is self-contained, uses a cleaner star schema, and answers BQ1 and its supporting analyses (BQ2 is previous scope). An earlier v1 model used a different grain and has been superseded.

Decision date: 2026-10-14. See [architecture decisions](../../03-architecture/decisions.md) for rationale.

## Keys and relationships

### Surrogate keys

Every dimension primary key is a BIGINT surrogate: `xxhash64` of the dimension's natural key (one column, or a column pair for `dim_date`). Hashes are stable across rebuilds and keep joins numeric. The natural key is always kept as its own column, so every row stays traceable to its source.

| Dimension | Primary key (BIGINT) | Hash input (natural key) | Natural key column |
|---|---|---|---|
| `dim_geography` | `area_key` | `area_code` | `area_code` STRING (e.g. `psgc:0130000000`) |
| `dim_facility` | `facility_key` | silver `facility_key` | `facility_source_id` STRING (the silver UUID) |
| `dim_disease` | `disease_key` | `disease_code` | `disease_code` STRING (e.g. `psa_1_001`, `all_causes`) |
| `dim_date` | `date_key` | `period_basis` + `period_label` | `period_label` STRING (e.g. `2022-M05`) |
| `dim_data_source` | `data_source_key` | `source_dataset` | `source_dataset` STRING (YAML source key) |

### Foreign keys

| Fact | FK to dim_geography | FK to dim_date | FK to dim_facility | FK to dim_disease | FK to dim_data_source |
|---|---|---|---|---|---|
| `fact_facility_capacity` | `area_key` | `date_key` | -- (area-level grain, no facility key) | -- | `data_source_key` |
| `fact_disease_metric` | `area_key` | `date_key` | -- | `disease_key` | `data_source_key` |
| `fact_workforce_capacity` | `area_key` | `date_key` | -- | -- | `data_source_key` |
| `fact_area_indicator` | `area_key` | `date_key` | -- | -- | `data_source_key` |

Notes:

* No v2 fact table carries `facility_key`. `fact_facility_capacity` is aggregated to area level (category, ownership, hospital level); facility detail lives in `dim_facility` and silver.
* `fact_area_access` (not shown above) carries `area_key` and `planning_unit_key` from `dim_geography` plus locality name columns; it has no date or data-source surrogate keys.

## Entity-relationship diagram

```
                    dim_geography
                   /   |   |   \
                  /    |   |    \
  fact_facility_  fact_disease_  fact_workforce_  fact_area_
  capacity        metric        capacity        indicator
      |              |              |              |
  dim_facility   dim_disease                    dim_data_source
      |              |                              |
                   \  |  /_________________________/
                    \ | /
                  dim_date

MARTS (built on facts + dims)
  mart_locality_service_presence -> mart_base_planning_unit
    -> mart_area_service_profile (S1/S2/S3)
    -> mart_area_burden_indicator (N1-N4)
      -> mart_area_evidence (SUP6)
      -> mart_area_priority (P1)
  fact_area_access (A1/A2)
  mart_tb_case_study (CASE)
  mart_kidney_case_study (N2)
  mart_dengue_peak_capacity (N3; D1 is previous scope)
  mart_evidence_readiness (SUP6, last)
```

## Grain definitions

| Table | Grain (one row per) | Columns in the grain |
|---|---|---|
| `dim_geography` | PSGC area | `area_key` |
| `dim_facility` | Facility establishment | `facility_key` |
| `dim_disease` | Disease or cause | `disease_key` |
| `dim_date` | Calendar date | `date_key` |
| `dim_data_source` | Source | `source_key` |
| `fact_facility_capacity` | Facility x snapshot | `facility_key`, `snapshot_date` |
| `fact_disease_metric` | Area x disease x period x source | `area_key`, `disease_key`, `date_key`, `source_key` |
| `fact_workforce_capacity` | Area x profession x year | `area_key`, `profession`, `date_key` |
| `fact_area_indicator` | Area x indicator x period | `area_key`, `indicator_key`, `date_key` |
| `mart_area_service_profile` | Planning unit | `planning_unit_key` |
| `mart_locality_service_presence` | Locality | `area_key` |
| `mart_base_planning_unit` | Planning area | `planning_unit_key` |
| `mart_area_burden_indicator` | Area x disease x period | `area_key`, `disease_key`, `date_key` |
| `mart_area_evidence` | Area | `area_key` |
| `mart_area_priority` | Area | `area_key` |
| `fact_area_access` | Locality | `area_key` |
| `mart_evidence_readiness` | Source x table x build | `source_key`, `table_name`, `build_id` |

## Geography hierarchy in dim_geography

```
country (Philippines)
  |
  +-- region (e.g. Region I - Ilocos)
  |     |
  |     +-- province (e.g. Ilocos Norte)
  |     |     |
  |     |     +-- municipality (e.g. Laoag)
  |     |     +-- city (component, e.g. Batac)
  |     |
  |     +-- HUC (e.g. Laoag City, if highly urbanized)
  |     +-- ICC (independent component city)
  |
  +-- NCR (no provinces)
        |
        +-- city/municipality (e.g. Manila, Quezon City)
```

Key columns: `area_key` (PK), `area_code`, `psgc_code`, `area_name`, `geographic_level`, `city_class` (HUC/ICC/CC), `income_class`, `parent_area_key`, `region_key`, `province_key`, `planning_unit_key`, `broad_unit_key`, `snapshot_date`, `area_sqkm`, `center_lat`, `center_lon`, `has_boundary`.

The planning unit rule: provinces, HUCs, and NCR districts are the analysis units for BQ1. A HUC outside NCR has `broad_unit_key` = null (no crosswalk yet).

See [table catalog](table-catalog.md) for the full table list and [data dictionary](data-dictionary.md) for column definitions.
