# Sample queries

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Common queries against the gold and silver tables.

## S1: Hospital beds per 10,000 population by province

```sql
SELECT area_name, ownership, facility_level,
       hospital_count, authorized_beds, population,
       beds_per_10000_pop
FROM public_health.gold.mart_area_service_profile
WHERE supply_section = 'S1_hospital_supply'
  AND area_level = 'Province'
  AND ownership IN ('Government', 'Private')
ORDER BY beds_per_10000_pop DESC NULLS LAST
LIMIT 20;
```

## S2: Bed occupancy by province (2025)

```sql
SELECT area_name, ownership,
       avg_bor, pct_bor_over_100, facility_count_reporting
FROM public_health.gold.mart_area_service_profile
WHERE supply_section = 'S2_hospital_occupancy'
  AND area_level = 'Province'
ORDER BY avg_bor DESC;
```

## S3: BHS per 10,000 population by province (latest year)

```sql
SELECT area_name, year, bhs_count, population, bhs_per_10000_pop
FROM public_health.gold.mart_area_service_profile
WHERE supply_section = 'S3_primary_care_supply'
  AND area_level = 'Province'
  AND year = (SELECT max(year) FROM public_health.gold.mart_area_service_profile
              WHERE supply_section = 'S3_primary_care_supply')
ORDER BY bhs_per_10000_pop DESC NULLS LAST;
```

## Facility registry detail

```sql
SELECT facility_category, ownership, service_level, count(*) as facilities
FROM public_health.silver.facilities_registry_silver
GROUP BY facility_category, ownership, service_level
ORDER BY facility_category, ownership;
```

## Build lineage for a silver row

```sql
SELECT s.*, v.ingested_at, v.load_batch_id, v.content_checksum
FROM public_health.silver.facilities_registry_silver s
JOIN public_health.quality.v_build_lineage v
  ON  v.build_id     =  s._silver_build_id
  AND v.target_table =  'public_health.silver.facilities_registry_silver'
  AND v.source_key   =  s._source_key
  AND v.source_file  =  s._source_file
  AND v.source_sheet <=> s._source_sheet
LIMIT 10;
```
