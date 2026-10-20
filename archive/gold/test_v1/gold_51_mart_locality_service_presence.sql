-- ========================================
-- Creates the view public_health.test_gold.mart_locality_service_presence
--   One row is: one city or municipality, with or without a facility
--   Key: area_key
--   Answers: A1 (no hospital recorded), A2 (highest hospital level), A3 (no licensed primary
--   care recorded), A4 (population per hospital, bed, primary care facility)
--
-- Reads: dim_geography, dim_period, fact_population, fact_area_facility_capacity_snapshot
--
-- Rules
--   * Every city and municipality of dim_geography has a row. A Manila submunicipality has
--     none: its facilities are counted in the City of Manila by the capacity fact.
--   * "Recorded" is literal. has_hospital_recorded = false means the registry lists no hospital
--     there on its as-of date. It does not confirm that no hospital exists.
--   * The two flags are separate indicators and are never merged.
--   * Counts are 0 when nothing is listed. hospital_beds is 0 when no hospital is listed, and
--     null when hospitals are listed but none has a bed count.
--   * Population is the latest census count of the locality (source psa_psgc). Null stays null.
--   * A4 ratios are filled only where the locality has at least one facility or bed.
--     Localities with none are reported by the two flags.
--   * The latest registry snapshot is used when the capacity fact holds more than one.
--
-- Columns added to the v3 list: area_code, geographic_level, city_class,
--   has_level3_hospital_recorded, hospitals_without_bed_count, population_per_hospital,
--   population_per_hospital_bed, population_per_licensed_primary_care.
-- Names follow model v3.1 (region_key, not region_area_key). A view has no _gold_build_id.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold.mart_locality_service_presence AS
WITH census AS (
  SELECT f.area_key,
         CAST(max(p.year) AS INT) AS population_year,
         max_by(f.population, p.year) AS population
  FROM public_health.test_gold.fact_population AS f
  INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key
  WHERE f.population_type = 'census' AND f.population IS NOT NULL
  GROUP BY f.area_key
),

snapshot AS (
  SELECT max_by(period_key, period_start_date) AS period_key
  FROM public_health.test_gold.dim_period
  WHERE period_basis = 'snapshot'
),

capacity AS (
  SELECT c.area_key,
         sum(CASE WHEN c.facility_category = 'hospital' THEN c.facility_count END) AS hospitals,
         max(CASE WHEN c.facility_category = 'hospital' AND c.hospital_level LIKE 'Level %'
                  THEN c.hospital_level END) AS highest_hospital_level,
         sum(CASE WHEN c.facility_category = 'hospital' THEN c.analysis_beds END) AS hospital_beds,
         sum(CASE WHEN c.facility_category = 'hospital' THEN c.facilities_without_beds END) AS hospitals_without_bed_count,
         sum(CASE WHEN c.facility_category = 'primary_care' THEN c.facility_count END) AS primary_care_listed,
         sum(CASE WHEN c.facility_category = 'primary_care' THEN c.facilities_license_valid END) AS primary_care_licensed,
         sum(CASE WHEN c.facility_category = 'infirmary' THEN c.facility_count END) AS infirmaries
  FROM public_health.test_gold.fact_area_facility_capacity_snapshot AS c
  INNER JOIN snapshot AS s ON s.period_key = c.period_key
  GROUP BY c.area_key
),

as_of AS (
  SELECT max(CASE WHEN c.facility_category = 'hospital' THEN greatest(c.nhfr_as_of_date, c.hfsrb_as_of_date) END)
           AS registry_as_of_date,
         max(CASE WHEN c.facility_category = 'primary_care' THEN c.hfsrb_as_of_date END) AS primary_care_list_as_of_date
  FROM public_health.test_gold.fact_area_facility_capacity_snapshot AS c
  INNER JOIN snapshot AS s ON s.period_key = c.period_key
)

SELECT g.area_key,
       g.area_code,
       g.area_name,
       g.geographic_level,
       g.city_class,
       g.planning_unit_key,
       g.region_key,
       n.population,
       n.population_year,
       coalesce(c.hospitals, 0) AS hospitals_recorded,
       coalesce(c.hospitals, 0) > 0 AS has_hospital_recorded,
       c.highest_hospital_level,
       coalesce(c.highest_hospital_level = 'Level 3', false) AS has_level3_hospital_recorded,
       CASE WHEN coalesce(c.hospitals, 0) = 0 THEN 0 ELSE c.hospital_beds END AS hospital_beds,
       coalesce(c.hospitals_without_bed_count, 0) AS hospitals_without_bed_count,
       coalesce(c.primary_care_listed, 0) AS primary_care_facilities_listed,
       coalesce(c.primary_care_licensed, 0) AS licensed_primary_care_facilities_recorded,
       coalesce(c.primary_care_licensed, 0) > 0 AS has_licensed_primary_care_recorded,
       coalesce(c.infirmaries, 0) AS infirmaries_recorded,
       CASE WHEN c.hospitals > 0 THEN round(n.population / c.hospitals, 0) END AS population_per_hospital,
       CASE WHEN c.hospital_beds > 0 THEN round(n.population / c.hospital_beds, 0) END AS population_per_hospital_bed,
       CASE WHEN c.primary_care_licensed > 0 THEN round(n.population / c.primary_care_licensed, 0) END
         AS population_per_licensed_primary_care,
       a.registry_as_of_date,
       a.primary_care_list_as_of_date
FROM public_health.test_gold.dim_geography AS g
CROSS JOIN as_of AS a
LEFT JOIN census AS n ON n.area_key = g.area_key
LEFT JOIN capacity AS c ON c.area_key = g.area_key
WHERE g.geographic_level IN ('city', 'municipality');


-- Phase 2 proof (proposal section 8): localities with no hospital and no primary care recorded
SELECT count(*) AS localities,
       count_if(NOT has_hospital_recorded) AS without_hospital_recorded,
       sum(CASE WHEN NOT has_hospital_recorded THEN population END) AS population_without_hospital,
       count_if(NOT has_licensed_primary_care_recorded) AS without_licensed_primary_care_recorded,
       sum(CASE WHEN NOT has_licensed_primary_care_recorded THEN population END) AS population_without_primary_care,
       count_if(NOT has_hospital_recorded AND NOT has_licensed_primary_care_recorded) AS without_both,
       count_if(population IS NULL) AS without_population,
       max(registry_as_of_date) AS registry_as_of_date,
       max(primary_care_list_as_of_date) AS primary_care_list_as_of_date
FROM public_health.test_gold.mart_locality_service_presence;
