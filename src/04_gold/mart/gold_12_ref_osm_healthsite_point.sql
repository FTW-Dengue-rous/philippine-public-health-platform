-- ========================================
-- Builds public_health.gold.ref_osm_healthsite_point
--   One row is: one OpenStreetMap health facility point (healthsites.io export via HDX), placed in
--   a city or municipality of dim_geography
--   Primary key: osm_point_key (BIGINT, xxhash64 of osm_key, stable across rebuilds)
--   Natural key: (osm_key) = osm_type/osm_id
--
-- Reads
--   public_health.silver.facilities_osm_point_silver   (2026-10-14 file: coordinates from the GeoJSON)
--   public_health.gold.dim_geography
--
-- What it is for
--   * The dashboard map: points by facility_type, with the "© OpenStreetMap contributors" line.
--   * Straight-line distance from each locality (dim_geography centroid) to the nearest OSM
--     hospital: computed in the access mart, not here. OSM is the only geocoded facility source
--     the platform has (the registry has no coordinates).
-- Rules
--   * NEVER a facility count. OSM is crowd-sourced, incomplete and uneven by area. Official
--     counts come from fact_facility_capacity (registry_snapshot) and dim_facility.
--   * One gold row per silver row; nothing is re-matched or re-placed. area_key is the silver
--     placement (point_in_polygon, nearest_boundary, exception or addr_city_name) and
--     location_precision says whether the coordinates or only the municipality are known.
--   * Sharing: open, ODbL 1.0. Every chart or map that uses it shows the attribution line.
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job


-- ========================================
-- [1] inputs
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.ref_osm_healthsite_point__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_osm_point_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_osm_point_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_geography
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.ref_osm_healthsite_point__candidate AS
SELECT xxhash64(o.osm_key)                        AS osm_point_key,
       o.osm_key,
       o.osm_type,
       o.osm_id,
       o.facility_name,
       o.facility_type,
       o.amenity,
       o.healthcare,
       o.speciality,
       o.operator,
       o.ownership,
       o.operational_status,
       CAST(o.beds AS INT)                        AS beds_tagged,            -- OSM tag, not verified
       o.emergency,
       CAST(o.latitude AS DOUBLE)                 AS latitude,
       CAST(o.longitude AS DOUBLE)                AS longitude,
       o.has_coordinates,
       o.location_precision,                      -- point (coordinates known) or municipality
       xxhash64(o.area_key)                       AS area_key,
       o.geo_resolution_method,
       xxhash64(o._source_key)                    AS data_source_key,
       o._as_of_date                              AS source_as_of_date,
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.facilities_osm_point_silver AS o;


-- ========================================
-- [3] gates
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.ref_osm_healthsite_point__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.ref_osm_healthsite_point__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.ref_osm_healthsite_point__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.ref_osm_healthsite_point__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.ref_osm_healthsite_point__candidate
WHERE osm_point_key IS NULL OR osm_key IS NULL OR area_key IS NULL OR facility_type IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.ref_osm_healthsite_point__candidate GROUP BY osm_point_key HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> silver rows', abs((SELECT count(*) FROM public_health.gold.ref_osm_healthsite_point__candidate) - count(*))
FROM public_health.silver.facilities_osm_point_silver
UNION ALL
SELECT 'point precision without coordinates, or coordinates outside the Philippines', count(*)
FROM public_health.gold.ref_osm_healthsite_point__candidate
WHERE (location_precision = 'point' AND (latitude IS NULL OR longitude IS NULL))
   OR (latitude IS NOT NULL AND (latitude NOT BETWEEN 4 AND 21.5 OR longitude NOT BETWEEN 114 AND 127))
UNION ALL
SELECT 'location_precision outside point, municipality', count(*)
FROM public_health.gold.ref_osm_healthsite_point__candidate WHERE location_precision NOT IN ('point', 'municipality')
UNION ALL
SELECT 'area_key not a city, municipality or submunicipality in dim_geography', count(*)
FROM public_health.gold.ref_osm_healthsite_point__candidate AS c
LEFT JOIN public_health.gold.dim_geography AS g ON g.area_key = c.area_key
WHERE g.area_key IS NULL OR g.geographic_level NOT IN ('city', 'municipality', 'submunicipality')
UNION ALL
SELECT 'data_source_key not in dim_data_source', count(*) FROM (
  SELECT DISTINCT data_source_key AS k FROM public_health.gold.ref_osm_healthsite_point__candidate) AS c
LEFT ANTI JOIN public_health.gold.dim_data_source AS d ON d.data_source_key = c.k;


-- ========================================
-- [4] stop if a gate failed
-- ========================================
CREATE OR REPLACE TEMP VIEW ref_osm_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'facilities'                                    AS domain,
       'public_health.gold.ref_osm_healthsite_point' AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v2', 'table_role', 'reference map layer, outside the dimensional model',
                            'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.ref_osm_healthsite_point__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.ref_osm_healthsite_point__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM ref_osm_build_log WHERE status = 'failed';

SELECT raise_error(concat('ref_osm_healthsite_point was NOT published. ', error_message))
FROM ref_osm_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.ref_osm_healthsite_point AS
SELECT * FROM public_health.gold.ref_osm_healthsite_point__candidate;

COMMENT ON TABLE public_health.gold.ref_osm_healthsite_point IS
  'OpenStreetMap health facility points (healthsites.io via HDX), map layer only. © OpenStreetMap contributors, ODbL 1.0. Never a facility count.';


-- ========================================
-- [6] record the build
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.ref_osm_healthsite_point));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.ref_osm_healthsite_point),
       gold_target_version, code_version, parameters, run_id, error_message
FROM ref_osm_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.ref_osm_healthsite_point', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.ref_osm_healthsite_point__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.gold.ref_osm_healthsite_point__candidate;
DROP TABLE IF EXISTS public_health.gold.ref_osm_healthsite_point__gates;
DROP TABLE IF EXISTS public_health.gold.ref_osm_healthsite_point__inputs;

-- Silver 2026-10-14: 16,030 rows (hospital 1,946, pharmacy 6,982, clinic 2,945, dentist 1,855, doctors 1,526 in the source file).
SELECT facility_type, location_precision, count(*) AS points, count_if(ownership IS NOT NULL) AS with_ownership,
       count(DISTINCT area_key) AS localities
FROM public_health.gold.ref_osm_healthsite_point
GROUP BY facility_type, location_precision ORDER BY points DESC;