-- ========================================
-- Creates the view public_health.test_gold2.fact_area_access
--   One row is: one city or municipality, with two straight-line distances:
--     (a) to the centre of the nearest city or municipality that has a hospital RECORDED in the
--         registry (and the nearest one with a Level 3 hospital recorded);
--     (b) to the nearest OpenStreetMap point tagged as a hospital (map layer, unverified).
--   Key: area_key
--   Answers: the "how far" part of A1 and A2. It does NOT measure distance to a hospital
--   building for (a): the registry has no coordinates.
-- Data model v2: gold_57 (v1) rewritten for the v2 tables, with the labels corrected (review
--   point 5, 2026-10-14 night): the registry measure is named nearest_hospital_LOCALITY_km, and
--   the OSM measure is a separate column with its own basis and caveat. v1 -> v2: adds
--   ref_osm_healthsite_point; mart_locality_service_presence and dim_geography are the v2 views.
--
-- Reads: mart_locality_service_presence, dim_geography, ref_osm_healthsite_point
--
-- Rules
--   * Centres are center_lat and center_lon of dim_geography (HDX boundaries). A locality
--     without a boundary has no distance (null), unless it has its own hospital (then 0).
--   * (a) Registry measure: locality centre to the centre of the nearest locality with
--     has_hospital_recorded. 0 when the locality itself has one. A hospital locality without a
--     boundary cannot be the nearest one for another locality. Approach A of
--     facilities-silver-plan section 12.7 (decision D14).
--   * (b) OSM measure: locality centre to the nearest OSM point with amenity, healthcare or
--     facility_type = 'hospital', coordinates known (location_precision = 'point'). OSM points
--     are NOT verified facilities and OSM coverage is uneven: the measure is a map-layer
--     indication, never a count, and is labelled with "© OpenStreetMap contributors".
--   * Distance = great-circle (haversine) km, Earth radius 6,371 km: a straight line, not travel
--     distance or time, optimistic across water. Label both as "straight-line".
--   * coordinates_validated = the locality has a boundary centre.
--
-- A view: about 1,640 x 530 locality pairs plus 1,640 x (OSM hospital points) pairs on each
-- read. If the dashboard is slow, change the first line to CREATE OR REPLACE TABLE.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold2.fact_area_access AS
WITH locality AS (
  SELECT l.area_key, l.area_code, l.area_name, l.planning_unit_key, l.population,
         l.has_hospital_recorded, l.has_level3_hospital_recorded,
         g.center_lat AS lat, g.center_lon AS lon,
         coalesce(g.has_boundary, false) AND g.center_lat IS NOT NULL AND g.center_lon IS NOT NULL AS has_centre
  FROM public_health.test_gold2.mart_locality_service_presence AS l
  INNER JOIN public_health.test_gold2.dim_geography AS g ON g.area_key = l.area_key
),

-- (a) locality to locality with a recorded hospital
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
         min_by(hospital_area_key, km) AS nearest_hospital_locality_key,
         min_by(hospital_area_name, km) AS nearest_hospital_locality_name,
         min(km) AS nearest_hospital_locality_km,
         min_by(hospital_area_key, km) FILTER (WHERE is_level3) AS nearest_level3_locality_key,
         min_by(hospital_area_name, km) FILTER (WHERE is_level3) AS nearest_level3_locality_name,
         min(km) FILTER (WHERE is_level3) AS nearest_level3_locality_km
  FROM pairs
  GROUP BY area_key
),

-- (b) locality centre to the nearest OSM hospital point
osm_hospital AS (
  SELECT osm_point_key, osm_key, facility_name, latitude, longitude
  FROM public_health.test_gold2.ref_osm_healthsite_point
  WHERE has_coordinates AND location_precision = 'point'
    AND (amenity = 'hospital' OR healthcare = 'hospital' OR facility_type = 'hospital')
),

osm_pairs AS (
  SELECT a.area_key, o.osm_key, o.facility_name,
         2 * 6371 * asin(sqrt(
           pow(sin(radians(o.latitude - a.lat) / 2), 2)
           + cos(radians(a.lat)) * cos(radians(o.latitude)) * pow(sin(radians(o.longitude - a.lon) / 2), 2))) AS km
  FROM locality AS a
  INNER JOIN osm_hospital AS o ON a.has_centre
),

osm_nearest AS (
  SELECT area_key,
         min_by(osm_key, km) AS nearest_osm_hospital_point_key,
         min_by(facility_name, km) AS nearest_osm_hospital_point_name,
         min(km) AS nearest_osm_hospital_point_km
  FROM osm_pairs
  GROUP BY area_key
)

SELECT a.area_key,
       n.nearest_hospital_locality_key,
       round(n.nearest_hospital_locality_km, 1)      AS nearest_hospital_locality_km,
       n.nearest_level3_locality_key,
       round(n.nearest_level3_locality_km, 1)        AS nearest_level3_locality_km,
       'locality centre to the centre of the nearest locality with a hospital recorded in the registry; straight line'
                                                     AS locality_distance_basis,
       o.nearest_osm_hospital_point_key,
       round(o.nearest_osm_hospital_point_km, 1)     AS nearest_osm_hospital_point_km,
       'locality centre to the nearest OpenStreetMap point tagged hospital; unverified, uneven coverage; straight line; © OpenStreetMap contributors'
                                                     AS osm_distance_basis,
       a.has_centre                                  AS coordinates_validated,
       a.area_code,
       a.area_name,
       a.planning_unit_key,
       a.population,
       a.has_hospital_recorded,
       n.nearest_hospital_locality_name,
       n.nearest_level3_locality_name,
       o.nearest_osm_hospital_point_name
FROM locality AS a
LEFT JOIN nearest AS n ON n.area_key = a.area_key
LEFT JOIN osm_nearest AS o ON o.area_key = a.area_key;


-- Checks to read after creating the view
SELECT count(*) AS localities,
       count(nearest_hospital_locality_km) AS with_locality_distance,
       count_if(nearest_hospital_locality_km = 0) AS with_own_hospital,
       round(percentile_approx(nearest_hospital_locality_km, 0.5), 1) AS median_km,
       round(percentile_approx(nearest_hospital_locality_km, 0.9), 1) AS p90_km,
       round(max(nearest_hospital_locality_km), 1) AS max_km,
       round(percentile_approx(nearest_level3_locality_km, 0.5), 1) AS median_km_to_level3,
       count(nearest_osm_hospital_point_km) AS with_osm_distance,
       round(percentile_approx(nearest_osm_hospital_point_km, 0.5), 1) AS median_km_osm
FROM public_health.test_gold2.fact_area_access;

-- Localities where the two measures disagree most (OSM point much nearer than any recorded
-- hospital locality): candidates for a registry gap or an OSM tag to check, never a conclusion
SELECT area_name, nearest_hospital_locality_km, nearest_osm_hospital_point_km, nearest_osm_hospital_point_name
FROM public_health.test_gold2.fact_area_access
WHERE NOT has_hospital_recorded AND nearest_osm_hospital_point_km < nearest_hospital_locality_km - 10
ORDER BY nearest_hospital_locality_km - nearest_osm_hospital_point_km DESC
LIMIT 20;