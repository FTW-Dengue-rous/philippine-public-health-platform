-- ========================================
-- gold_15_mart_base_planning_unit.sql
-- Creates the view public_health.gold.mart_base_planning_unit (helper for the BQ1 marts)
--   One row is: one planning unit, with its census population
--   Key: planning_unit_key
--
-- Reads: dim_geography (gold 01), dim_data_source (gold 03),
--        mart_locality_service_presence (gold 14)
--
-- Rules
--   * A planning unit is every area that cities and municipalities roll up to in
--     dim_geography.planning_unit_key (O-01): a province without its HUCs, each HUC, and NCR.
--     A city or municipality with no province row is its own unit and gets unit_level = other
--     (Isabela City, the Special Geographic Area municipalities). Whether the dashboard shows
--     them is open (O-16).
--   * population = the sum of the census counts of the unit's cities and municipalities, all
--     from the latest census year. They do not overlap and come from one source, so the sum is
--     allowed (proposal section 7). The census province row is not used: its coverage differs
--     by year.
--   * population is null when one locality of the unit has no count for that year. The number
--     of such localities is in localities_without_population. Null is not zero. Sulu has no
--     2024 census count in the source, so its population stays null; it is never filled from
--     2020 (D-41).
--
-- History
--   2026-10-14  Written for the combined data model (from gold_52, v1).
--   2026-10-20  Moved to public_health.gold and renamed gold_15. Comments updated (O-01, O-16,
--               Sulu). No logic change.
-- ========================================

CREATE OR REPLACE VIEW public_health.gold.mart_base_planning_unit AS
WITH census_year AS (
  SELECT max(population_year) AS population_year
  FROM public_health.gold.mart_locality_service_presence
),

localities AS (
  SELECT l.planning_unit_key,
         y.population_year,
         count(*) AS localities,
         count_if(l.population IS NULL OR l.population_year <> y.population_year) AS localities_without_population,
         sum(CASE WHEN l.population_year = y.population_year THEN l.population END) AS population_sum
  FROM public_health.gold.mart_locality_service_presence AS l
  CROSS JOIN census_year AS y
  GROUP BY l.planning_unit_key, y.population_year
)

SELECT u.area_key AS planning_unit_key,
       u.area_code,
       u.area_name,
       CASE WHEN u.area_code = 'psgc:1300000000' THEN 'NCR'
            WHEN u.geographic_level = 'province' THEN 'province'
            WHEN u.city_class = 'HUC' THEN 'HUC'
            ELSE 'other' END AS unit_level,
       u.region_key,
       r.area_name AS region_name,
       u.income_class,
       a.localities,
       CASE WHEN a.localities_without_population = 0 THEN a.population_sum END AS population,
       a.population_year,
       s.data_source_key AS population_data_source_key,
       a.localities_without_population
FROM localities AS a
INNER JOIN public_health.gold.dim_geography AS u ON u.area_key = a.planning_unit_key
LEFT JOIN public_health.gold.dim_geography AS r ON r.area_key = u.region_key
LEFT JOIN public_health.gold.dim_data_source AS s ON s.source_dataset = 'psa_psgc';


-- Checked 2026-10-14: 82 provinces, 17 HUCs outside NCR, 1 NCR, 9 other (Isabela City and the
-- SGA municipalities). units_without_population includes Sulu (D-41).
SELECT unit_level, count(*) AS units, sum(localities) AS localities, sum(population) AS population,
       count_if(population IS NULL) AS units_without_population, max(population_year) AS population_year
FROM public_health.gold.mart_base_planning_unit
GROUP BY unit_level
ORDER BY unit_level;
