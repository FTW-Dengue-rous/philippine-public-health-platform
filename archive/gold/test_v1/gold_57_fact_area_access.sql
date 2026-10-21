-- ========================================
-- Creates the view public_health.test_gold.fact_area_access
--   One row is: one city or municipality, with the straight-line distance to the nearest
--   city or municipality that has a hospital recorded
--   Key: area_key
--   Answers: the "far" part of the story (A1 and A2 as a distance)
--
-- Reads: mart_locality_service_presence, dim_geography
--
-- This is approach A of facilities-silver-plan.md section 12.7 (decision D14): centre of a
-- locality to the centre of the nearest locality with a registry hospital. It is NOT the
-- distance to a hospital building: the registry has no coordinates.
--
-- Rules
--   * Centres are center_lat and center_lon of dim_geography (HDX boundaries). They are not
--     computed again here.
--   * A locality with a hospital recorded has distance 0.
--   * Distance = great-circle (haversine) km, Earth radius 6,371 km. It is a straight line,
--     not travel distance or time. Across water it is optimistic. Label it "straight-line".
--   * A locality without a boundary has no distance (null), unless it has its own hospital.
--     A hospital locality without a boundary cannot be the nearest one for another locality.
--   * coordinates_validated = the locality and its nearest hospital locality both have a
--     boundary in dim_geography.
--
-- Differences from the v3 draft columns (the draft was never confirmed)
--   * nearest_hospital_area_key and nearest_level3_area_key replace the two facility keys:
--     the nearest thing is a locality, not a facility.
--   * It is a view, so it has no _gold_build_id. About 1,640 x 530 pairs are compared on each
--     read. If the dashboard is slow, change the first line to CREATE OR REPLACE TABLE.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold.fact_area_access AS
WITH locality AS (
  SELECT l.area_key, l.area_code, l.area_name, l.planning_unit_key, l.population,
         l.has_hospital_recorded, l.has_level3_hospital_recorded,
         g.center_lat AS lat, g.center_lon AS lon,
         coalesce(g.has_boundary, false) AND g.center_lat IS NOT NULL AND g.center_lon IS NOT NULL AS has_centre
  FROM public_health.test_gold.mart_locality_service_presence AS l
  INNER JOIN public_health.test_gold.dim_geography AS g ON g.area_key = l.area_key
),

pairs AS (
  SELECT a.area_key, h.area_key AS hospital_area_key, h.area_name AS hospital_area_name,
         h.has_level3_hospital_recorded AS is_level3,
         CASE WHEN a.area_key = h.area_key THEN 0.0
              ELSE 2 * 6371 * asin(sqrt(
                     pow(sin(radians(h.lat - a.lat) / 2), 2)
                     + cos(radians(a.lat)) * cos(radians(h.lat)) * pow(sin(radians(h.lon - a.lon) / 2), 2))) END AS km
  FROM locality AS a
  INNER JOIN locality AS h
    ON h.has_hospital_recorded AND (a.area_key = h.area_key OR (a.has_centre AND h.has_centre))
),

nearest AS (
  SELECT area_key,
         min_by(hospital_area_key, km) AS nearest_hospital_area_key,
         min_by(hospital_area_name, km) AS nearest_hospital_area_name,
         min(km) AS nearest_hospital_km,
         min_by(hospital_area_key, km) FILTER (WHERE is_level3) AS nearest_level3_area_key,
         min_by(hospital_area_name, km) FILTER (WHERE is_level3) AS nearest_level3_area_name,
         min(km) FILTER (WHERE is_level3) AS nearest_level3_km
  FROM pairs
  GROUP BY area_key
)

SELECT a.area_key,
       n.nearest_hospital_area_key,
       round(n.nearest_hospital_km, 1) AS nearest_hospital_km,
       n.nearest_level3_area_key,
       round(n.nearest_level3_km, 1) AS nearest_level3_km,
       'locality centre to the centre of the nearest locality with a hospital recorded, straight line' AS distance_basis,
       a.has_centre AS coordinates_validated,
       a.area_code,                       -- extra
       a.area_name,                       -- extra
       a.planning_unit_key,               -- extra
       a.population,                      -- extra
       a.has_hospital_recorded,           -- extra
       n.nearest_hospital_area_name,      -- extra
       n.nearest_level3_area_name         -- extra
FROM locality AS a
LEFT JOIN nearest AS n ON n.area_key = a.area_key;


SELECT count(*) AS localities,
       count(nearest_hospital_km) AS with_distance,
       count_if(nearest_hospital_km = 0) AS with_own_hospital,
       round(percentile_approx(nearest_hospital_km, 0.5), 1) AS median_km,
       round(percentile_approx(nearest_hospital_km, 0.9), 1) AS p90_km,
       round(max(nearest_hospital_km), 1) AS max_km,
       round(percentile_approx(nearest_level3_km, 0.5), 1) AS median_km_to_level3
FROM public_health.test_gold.fact_area_access;
