# Logical data model and ERD

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Data model v2 is the active gold model. It lives in schema `public_health.test_gold2` and will be promoted to `public_health.gold`.

## Why v2

The team chose v2 over v1 because v2 is self-contained (no reads from the v1 schema), uses a cleaner star schema with 5 dimensions and 4 facts, and supports all business questions. v1 tables remain in `public_health.test_gold` for comparison but are not deployed by the job.

Decision date: 2026-10-14. See [architecture decisions](../../03-architecture/decisions.md) for rationale.

## Keys and relationships

### Surrogate keys

All dimension primary keys are `xxhash64` of the natural key, stored as BIGINT. This is stable across rebuilds and avoids string joins.

| Dimension | Primary key | Natural key | Type |
|---|---|---|---|
| `dim_geography` | `area_key` | `area_code` (e.g. `psgc:0130000000`) | BIGINT |
| `dim_facility` | `facility_key` | `facility_key` (from silver) | STRING |
| `dim_disease` | `disease_key` | `disease` + `cause` | BIGINT |
| `dim_date` | `date_key` | `date` | INT (YYYYMMDD) |
| `dim_data_source` | `source_key` | `source_key` (from YAML) | STRING |

### Foreign keys

| Fact | FK to dim_geography | FK to dim_date | FK to dim_facility | FK to dim_disease | FK to dim_data_source |
|---|---|---|---|---|---|
| `fact_facility_capacity` | `area_key` | `snapshot_date_key` | `facility_key` | -- | `source_key` |
| `fact_disease_metric` | `area_key` | `date_key` | -- | `disease_key` | `source_key` |
| `fact_workforce_capacity` | `area_key` | `date_key` | -- | -- | `source_key` |
| `fact_area_indicator` | `area_key` | `date_key` | -- | -- | `source_key` |

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
  mart_dengue_peak_capacity (N3/D1)
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
| `mart_area_service_profile` | Section x area level x area x year x ownership x level | `supply_section`, `area_level`, `area_key`, `year`, `ownership`, `facility_level` |
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
