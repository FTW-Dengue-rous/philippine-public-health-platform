# Lineage map

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Source-to-table lineage per domain. Each source feeds specific business questions (BQ1 and sub-questions; BQ2 is previous scope). For the shared lineage contract (column-level rules, identifiers, build tracking), see [lineage-qc-contract_v1.3.md](../lineage-qc-contract_v1.3.md). For the full question-to-source traceability, see [business context](../01-context/problem-and-business-context.md#business-question-traceability).

## Geography

```
PSA PSGC API  →  src/01_ingestion/psgc_ingestion  →  landing/psgc/  →  geography_bronze.py  →  public_health.bronze.geography_bronze  →  geography_silver.py  →  public_health.silver.geography_silver (43,762 rows)
                                                                                                                                        →  psgc_population_silver.py  →  public_health.silver.population_silver

HDX GeoJSON   →  src/01_ingestion/admin_boundaries_ingestion  →  landing/admin_boundaries/  →  admin_boundaries_bronze.py  →  public_health.bronze.admin_boundaries_bronze  →  admin_boundaries_silver.py  →  public_health.silver.admin_boundaries_silver
```

## Facilities

```
Landing volume (15 sources)
    →  facilities_bronze.py (config: sources_facilities.yaml)
    →  public_health.bronze.facilities_*_bronze (15 tables)
        →  facilities_silver_00_reference.sql   →  reference tables (facility categories, ownership, etc.)
        →  facilities_silver_01_registry.sql   →  public_health.silver.facilities_id_map_silver (5,254 rows)
                                            →  public_health.silver.facilities_registry_silver (3,954 rows)
        →  facilities_silver_02_metric.sql     →  public_health.silver.facilities_metric_silver (2,988 rows)
        →  facilities_silver_03_bed_occupancy.sql  →  public_health.silver.facilities_bed_occupancy_silver (1,977 rows)
        →  facilities_silver_04_osm_point.sql   →  public_health.silver.facilities_osm_point_silver (UNVERIFIED)
            →  gold_16_mart_area_service_profile.sql  →  public_health.gold.mart_area_service_profile
                →  Dashboard (S1, S2, S3)
```

## Diseases

```
Landing volume (multiple sources)
    →  diseases_bronze.py (config: sources_diseases.yaml)
    →  public_health.bronze.diseases_*_bronze
        →  diseases_silver_00_reference.sql  →  reference tables
        →  diseases_silver_01_metric.sql    →  public_health.silver.diseases_metric_silver
        →  diseases_silver_02_deaths_age.sql →  public_health.silver.diseases_deaths_age_silver
        →  diseases_silver_03_hospital_encounters.sql
        →  diseases_silver_04_source_coverage.sql
        →  diseases_silver_05_tb_programme.sql
        →  diseases_silver_06_hospital_claims.sql
            →  gold_07_fact_disease_metric.sql   →  public_health.gold.fact_disease_metric
            →  gold_05_dim_disease.sql             →  public_health.gold.dim_disease
```

## Workforce

```
Landing volume
    →  workforce_bronze.py (config: sources_workforce.yaml)
    →  public_health.bronze.workforce_*_bronze
        →  workforce_silver_00_reference.sql   →  reference tables
        →  workforce_silver_01_fhsis_areas.sql
        →  workforce_silver_02_headcount.sql
        →  workforce_silver_03_denominator.sql
        →  workforce_silver_04_specialist.sql
            →  gold_08_fact_workforce_capacity.sql  →  public_health.gold.fact_workforce_capacity
```

## Socioeconomic

```
Landing volume
    →  socioeconomic_bronze.py (config: sources_socioeconomic.yaml)
    →  public_health.bronze.socioeconomic_*_bronze
        →  socioeconomic_silver_00_reference.sql
        →  socioeconomic_silver_01_poverty.sql  →  public_health.silver.socioeconomic_poverty_silver
        →  socioeconomic_silver_02_health_expenditure_share.sql
        →  socioeconomic_silver_03_health_expenditure_per_capita.sql
        →  socioeconomic_silver_04_child_mortality.sql
        →  socioeconomic_silver_05_poverty_geography_check.sql
            →  gold_09_fact_area_indicator.sql  →  public_health.gold.fact_area_indicator
```
