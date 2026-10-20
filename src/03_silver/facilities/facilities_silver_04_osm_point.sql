-- =============================================================================
-- Builds public_health.silver.facilities_osm_point_silver:
--   one OpenStreetMap health facility (healthsites.io export via HDX), with its location and the
--   city / municipality it is in. Key: (osm_type, osm_id).
-- Follows facilities-silver-plan.md v2.1 (section 12) and lineage-qc-contract.md v1.3
-- (single-source lineage columns, contract 3.3; build_log / build_inputs per build;
-- row_disposition holds only the bronze rows that were NOT loaded).
-- Run order: 00a -> build_facilities_area_exceptions.py (when inputs change) -> 00 -> 01 -> 02 -> 03 -> 04a -> [04]
--
-- What this table is for
--   * Facility points for maps, and distance to facilities (computed in gold from the
--     municipality centroids in dim_geography, which come from the same HDX boundaries).
--   * A cross-check of the official registry. It is NOT a facility count: OSM is crowd-sourced,
--     incomplete and uneven by area. Official counts come from facilities_registry_silver.
--
-- Area of each point, first rule that applies (plan 4.2, step v2)
--   1. point_in_polygon   coordinates inside a city / municipality boundary (step 04a)
--   2. nearest_boundary   coordinates outside every boundary but within 1 km of one (coast, pier)
--   3. exception          addr:city label in facilities_area_exceptions (source_group 'osm')
--   4. addr_city_name     addr:city label = one city / municipality name nationwide (a label with
--                         'City' matches cities only). Used for points WITHOUT usable coordinates.
--   Otherwise the row is quarantined (not loaded) with its reason; it does not fail the build.
--   For a point placed by its coordinates, the addr:city label is only compared: a different
--   LGU sets addr_city_conflict (reported, coordinates win).
--
-- Which bronze file (2026-10-14)
--   hdx_healthsites is load_mode latest_file and bronze keeps every snapshot. This build reads only
--   the newest file (latest _as_of_date). Older snapshots are not inputs (no build_inputs or
--   row_disposition rows). Two files with the same latest _as_of_date stop the build (gate
--   'inputs: not exactly one healthsites file'). 04a, the exceptions builder and
--   facilities_silver_qc.py use the same rule.
--
-- Known limits of this source (plan 12.3)
--   * The HDX CSV export (as of 2026-09-29) has no coordinates for the 3,870 OSM ways (building
--     outlines; 1,593 of the 1,946 hospitals). The 2026-10-14 file is derived from the GeoJSON export
--     (build_hdx_healthsites_csv_from_geojson.py, decision D12) and has the outline centroid for
--     every way, so they are placed by point_in_polygon too. Rows without coordinates (none in the
--     2026-10-14 file) get an area only from addr:city, with location_precision = 'municipality'.
--   * Boundaries are the team's HDX polygons (facilities_silver_00a_area_boundary.sql). Areas with
--     boundary_rule other than 'hdx' have no polygon (SGA municipalities, and any HDX code whose
--     name disagrees with geography): points there fall to nearest_boundary or addr:city.
--
-- Build sequence (contract 5.1)
--   Step 1  [0] settings, helpers  [1] ..__classified  [2] ..__inputs
--   Step 2  [3] ..__area (coordinates from 04a, then addr:city)  [4] ..__candidate
--   Step 3  [4b] ..__dispositions  [5] ..__gates  [6] build log, STOP on failure
--   Step 4  [7] write  [8] build_log, build_inputs, row_disposition (rows not loaded only)  [9] summary
--
-- Needs: facilities_silver_00a_area_boundary.sql (HDX boundaries), facilities_silver_00_reference.sql
--   (exceptions), facilities_silver_04a_osm_locate.py run just before (same job), quality_setup.sql,
--   geography silver, bronze QC for hdx_healthsites. The versions of the boundary and exceptions
--   tables are recorded in build_inputs as reference inputs.
-- SHARING: open (ODbL 1.0). Gold and the dashboard must show "© OpenStreetMap contributors".
-- =============================================================================

-- [0] settings
DECLARE OR REPLACE VARIABLE osm_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;
-- Philippine bounding box (lon_min, lat_min, lon_max, lat_max). Same box as PH_BBOX in
-- facilities_silver_04a_osm_locate.py and the centroid gate in 00a; was typed in the gate until
-- 2026-10-19 (rule 2a).
DECLARE OR REPLACE VARIABLE ph_bbox ARRAY<DOUBLE> DEFAULT array(114D, 4D, 127D, 21.5D);
-- OSM tags that make a row a health facility (one list, used in [0] and [4]; was typed three times)
DECLARE OR REPLACE VARIABLE osm_health_amenities ARRAY<STRING>
  DEFAULT array('hospital', 'clinic', 'doctors', 'dentist', 'pharmacy', 'laboratory', 'health_post', 'nursing_home', 'blood_bank');
DECLARE OR REPLACE VARIABLE geography_checksum STRING;
SET VARIABLE geography_checksum =
  (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

-- Same helper functions as facilities_silver_01_registry.sql (kept identical)
CREATE OR REPLACE TEMPORARY FUNCTION fac_norm(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(
         translate(upper(replace(replace(replace(replace(s, 'Ã±', 'N'), 'Ã‘', 'N'), 'ñ', 'N'), '?', 'N')), 'ÑÁÉÍÓÚ', 'NAEIOU'),
         '[^A-Z0-9]', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION fac_place(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         regexp_replace(regexp_replace(concat(' ', fac_norm(regexp_replace(s, "['’`-]", '')), ' '),
         ' (HUC|ICC|CC|CAPITAL|NOT A PROVINCE) ', ' '),
         ' STA ', ' SANTA '), ' STO ', ' SANTO '), ' GEN ', ' GENERAL '), ' GOV ', ' GOVERNOR '), ' SEN ', ' SENATOR '),
         '^ (MUNICIPALITY OF|ISLAND GARDEN CITY OF|SCIENCE CITY OF|CITY OF) ', ' '), ' CITY $', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION fac_place_key(s STRING) RETURNS STRING
RETURN replace(fac_place(s), ' ', '');

CREATE OR REPLACE TEMPORARY FUNCTION fac_city_hint(s STRING) RETURNS BOOLEAN
RETURN fac_norm(s) RLIKE '(^CITY OF )|( CITY$)|( CITY )';

CREATE OR REPLACE TEMPORARY FUNCTION fac_lgu(code STRING) RETURNS STRING
RETURN CASE WHEN code RLIKE '^13806[0-9]{2}000$' THEN '1380600000' ELSE code END;

-- Cities and municipalities of the geography snapshot
CREATE OR REPLACE TEMP VIEW fac_osm_geo AS
SELECT psgc_code, area_name,
       CASE geographic_level WHEN 'City' THEN 'city' ELSE 'municipality' END AS geo_level,
       fac_place_key(area_name) AS place_norm
FROM public_health.silver.geography_silver
WHERE content_checksum = geography_checksum AND geographic_level IN ('City', 'Mun');

-- OSM tags that make a row a health facility (setting osm_health_amenities). amenity first;
-- healthcare when amenity is missing or not a health amenity (laboratory, optometrist, ... are
-- tagged healthcare only).
CREATE OR REPLACE TEMP VIEW fac_osm_health_amenity AS
SELECT explode(osm_health_amenities) AS amenity;


-- The newest Healthsites file (see "Which bronze file" above)
CREATE OR REPLACE TEMP VIEW fac_osm_latest_file AS
SELECT DISTINCT _source_file
FROM public_health.bronze.facilities_hdx_healthsites_bronze
WHERE _source_key = 'hdx_healthsites'
  AND _as_of_date = (SELECT max(_as_of_date) FROM public_health.bronze.facilities_hdx_healthsites_bronze
                     WHERE _source_key = 'hdx_healthsites');


-- =============================================================================
-- [1] classify every bronze row of the newest file
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_osm_point_silver__classified AS
SELECT 'public_health.bronze.facilities_hdx_healthsites_bronze' AS input_table, t.*,
       lower(trim(t.amenity)) AS amenity_norm,
       lower(trim(split(t.healthcare, ';')[0])) AS healthcare_first,
       CASE WHEN a.amenity IS NOT NULL OR nullif(trim(t.healthcare), '') IS NOT NULL THEN 'data' ELSE 'non_data' END AS row_class,
       CASE WHEN a.amenity IS NULL AND nullif(trim(t.healthcare), '') IS NULL THEN 'not_a_health_facility' END AS reason
FROM public_health.bronze.facilities_hdx_healthsites_bronze t
LEFT JOIN fac_osm_health_amenity a ON a.amenity = lower(trim(t.amenity))
WHERE t._source_key = 'hdx_healthsites'
  AND t._source_file IN (SELECT _source_file FROM fac_osm_latest_file);


-- =============================================================================
-- [2] inputs: the bronze file, geography, the two reference tables, and the 04a staging table
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_osm_table_versions AS
SELECT 'public_health.bronze.facilities_hdx_healthsites_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.facilities_hdx_healthsites_bronze)) AS table_version
UNION ALL SELECT 'public_health.silver.geography_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.geography_silver))
UNION ALL SELECT 'public_health.silver.facilities_area_exceptions',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_area_exceptions))
UNION ALL SELECT 'public_health.silver.facilities_area_boundary',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_area_boundary))
UNION ALL SELECT 'public_health.silver.facilities_osm_point_silver__located',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_osm_point_silver__located));

CREATE OR REPLACE TABLE public_health.silver.facilities_osm_point_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.facilities_osm_point_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT osm_build_id AS build_id, 'public_health.silver.facilities_osm_point_silver' AS target_table,
       'bronze_source' AS input_kind, f.input_table, max(v.table_version) AS input_table_version,
       f._source_key AS source_key, f._source_file AS source_file, f._source_sheet AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at AS ingested_at, f.input_rows, CAST(NULL AS STRING) AS reference_version,
       count(m.batch_id) AS metadata_matches
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet AND m.retrieved_at = f._ingested_at
LEFT JOIN fac_osm_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
SELECT osm_build_id, 'public_health.silver.facilities_osm_point_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CASE WHEN t.table_name LIKE '%geography_silver' THEN geography_checksum END,
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.geography_silver' AS table_name, count(*) AS n FROM fac_osm_geo
      UNION ALL SELECT 'public_health.silver.facilities_area_exceptions', count(*) FROM public_health.silver.facilities_area_exceptions
      UNION ALL SELECT 'public_health.silver.facilities_area_boundary', count(*) FROM public_health.silver.facilities_area_boundary
      UNION ALL SELECT 'public_health.silver.facilities_osm_point_silver__located', count(*)
                FROM public_health.silver.facilities_osm_point_silver__located) t
LEFT JOIN fac_osm_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] area of every data row: coordinates (04a), then the addr:city label
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_osm_point_silver__area AS
WITH d AS (
  SELECT c.*, l.longitude, l.latitude, l.coordinate_status, l.located_psgc, l.locate_method,
         l.boundary_candidates, l.distance_to_boundary_km,
         nullif(trim(c.addr_city), '') AS city_label
  FROM public_health.silver.facilities_osm_point_silver__classified c
  LEFT JOIN public_health.silver.facilities_osm_point_silver__located l
    ON l._source_key = c._source_key AND l._source_file = c._source_file
   AND l._source_sheet <=> c._source_sheet AND l._source_row_num = c._source_row_num
  WHERE c.row_class = 'data'),
exc AS (     -- reviewed addr:city labels (an unresolvable label has neither code nor key)
  SELECT d._source_row_num, max(e.psgc_code) AS exc_psgc, max(e.match_type) AS exc_type, count(*) AS exc_n
  FROM d
  JOIN public_health.silver.facilities_area_exceptions e
    ON e.source_group = 'osm' AND e.match_type IN ('area_label', 'unresolvable')
   AND fac_place_key(e.match_value) = fac_place_key(d.city_label)
  WHERE d.city_label IS NOT NULL
  GROUP BY d._source_row_num),
nm AS (      -- the label matched to a city / municipality name, nationwide
  SELECT d._source_row_num, count(*) AS name_n, max(g.psgc_code) AS name_psgc
  FROM d
  JOIN fac_osm_geo g
    ON g.place_norm = fac_place_key(d.city_label)
   AND (NOT fac_city_hint(d.city_label) OR g.geo_level = 'city')
  WHERE d.city_label IS NOT NULL
  GROUP BY d._source_row_num)
SELECT d._source_key, d._source_file, d._source_sheet, d._source_row_num,
       d.longitude, d.latitude, d.coordinate_status, d.boundary_candidates, d.distance_to_boundary_km,
       d.city_label,
       CASE WHEN exc.exc_type = 'area_label' AND exc.exc_n = 1 THEN exc.exc_psgc
            WHEN nm.name_n = 1 THEN nm.name_psgc END AS city_label_psgc,
       CASE WHEN d.locate_method IS NOT NULL THEN d.located_psgc
            WHEN exc.exc_type = 'area_label' AND exc.exc_n = 1 THEN exc.exc_psgc
            WHEN exc.exc_type IS NULL AND nm.name_n = 1 THEN nm.name_psgc END AS psgc_code,
       CASE WHEN d.locate_method IS NOT NULL THEN d.locate_method
            WHEN exc.exc_type = 'area_label' AND exc.exc_n = 1 THEN 'exception'
            WHEN exc.exc_type IS NULL AND nm.name_n = 1 THEN 'addr_city_name' END AS geo_resolution_method,
       CASE WHEN d.locate_method IS NOT NULL THEN NULL
            WHEN exc.exc_type = 'area_label' AND exc.exc_n = 1 THEN NULL
            WHEN exc.exc_type IS NULL AND nm.name_n = 1 THEN NULL
            WHEN exc.exc_type = 'unresolvable' THEN 'place_reviewed_unresolvable'
            WHEN exc.exc_n > 1 THEN 'ambiguous_exception'
            WHEN d.city_label IS NULL AND d.coordinate_status = 'ok' THEN 'coordinates_outside_boundaries'
            WHEN d.city_label IS NULL THEN 'no_coordinates_no_city'
            WHEN nm.name_n > 1 THEN 'ambiguous_city_label'
            ELSE 'city_label_unresolved' END AS unlocated_reason,
       nm.name_n AS city_label_candidates
FROM d
LEFT JOIN exc ON exc._source_row_num = d._source_row_num
LEFT JOIN nm ON nm._source_row_num = d._source_row_num;


-- =============================================================================
-- [4] candidate rows (located data rows only)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_osm_point_silver__candidate AS
SELECT
  c.osm_type, c.osm_id,
  concat(c.osm_type, '/', c.osm_id)                                         AS osm_key,
  nullif(trim(c.name), '')                                                  AS facility_name,
  -- facility type: amenity when it is a health amenity, else the first healthcare value
  CASE WHEN array_contains(osm_health_amenities, c.amenity_norm) THEN c.amenity_norm
       ELSE c.healthcare_first END                                          AS facility_type,
  c.amenity_norm                                                            AS amenity,
  nullif(trim(c.healthcare), '')                                            AS healthcare,
  nullif(trim(c.speciality), '')                                            AS speciality,
  nullif(trim(c.operator), '')                                              AS operator,
  lower(nullif(trim(c.operator_type), ''))                                  AS operator_type,
  CASE WHEN lower(c.operator_type) IN ('government', 'public', 'government_local', 'barangay_government',
                                       'public/government') THEN 'government'
       WHEN lower(c.operator_type) IN ('private', 'private_non_profit', 'ngo', 'religious',
                                       'cooperative', 'consortium') THEN 'private' END AS ownership,
  nullif(trim(c.operational_status), '')                                    AS operational_status,
  try_cast(trim(c.beds) AS INT)                                             AS beds,
  nullif(trim(c.emergency), '')                                             AS emergency,
  -- location
  a.longitude, a.latitude,
  (a.coordinate_status = 'ok')                                              AS has_coordinates,
  a.coordinate_status,
  CASE WHEN a.geo_resolution_method IN ('point_in_polygon', 'nearest_boundary') THEN 'point'
       ELSE 'municipality' END                                              AS location_precision,
  concat('psgc:', a.psgc_code)                                              AS area_key,
  a.psgc_code,
  a.city_label                                                              AS geo_name_source,
  a.geo_resolution_method,
  coalesce(a.boundary_candidates, 0)                                        AS boundary_candidates,
  a.distance_to_boundary_km,
  -- addr:city compared with the area from the coordinates (only for points placed by coordinates)
  CASE WHEN a.geo_resolution_method IN ('point_in_polygon', 'nearest_boundary') AND a.city_label_psgc IS NOT NULL
       THEN fac_lgu(a.city_label_psgc) <> fac_lgu(a.psgc_code) ELSE false END AS addr_city_conflict,
  nullif(trim(c.addr_street), '')                                           AS addr_street,
  nullif(trim(c.addr_postcode), '')                                         AS addr_postcode,
  try_cast(c.completeness AS DOUBLE)                                        AS tag_completeness_pct,
  to_timestamp(c.changeset_timestamp, 'yyyy/MM/dd HH:mm:ssx')               AS osm_last_edited_at,
  (SELECT max(boundary_version) FROM public_health.silver.facilities_area_boundary) AS boundary_version,
  'open'                                                                    AS sharing,
  'ODbL-1.0 (OpenStreetMap contributors)'                                   AS license,
  -- lineage (7)
  osm_build_id AS _silver_build_id,
  c._source_key, c._source_file, c._source_sheet, c._source_row_num, c._as_of_date,
  map_filter(map('longitude', 'X', 'latitude', 'Y', 'beds', 'beds', 'facility_type',
                 CASE WHEN array_contains(osm_health_amenities, c.amenity_norm) THEN 'amenity' ELSE 'healthcare' END),
             (k, v) -> NOT (k IN ('longitude', 'latitude') AND a.coordinate_status <> 'ok')
                       AND NOT (k = 'beds' AND try_cast(trim(c.beds) AS INT) IS NULL)) AS _metric_source_columns
FROM public_health.silver.facilities_osm_point_silver__classified c
JOIN public_health.silver.facilities_osm_point_silver__area a
  ON a._source_key = c._source_key AND a._source_file = c._source_file
 AND a._source_sheet <=> c._source_sheet AND a._source_row_num = c._source_row_num
WHERE a.psgc_code IS NOT NULL;


-- =============================================================================
-- [4b] dispositions (contract v1.3, 7.1): bronze rows NOT loaded. Saved before the gates, so the
--      reconciliation gate checks exactly what step [8] writes.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_osm_point_silver__dispositions AS
SELECT osm_build_id AS build_id, 'public_health.silver.facilities_osm_point_silver' AS target_table,
       c._source_key AS source_key, c._source_file AS source_file, c._source_sheet AS source_sheet,
       c._source_row_num AS source_row_num, i.load_batch_id, i.content_checksum,
       CASE WHEN c.row_class = 'non_data' THEN 'dropped_non_data' ELSE 'quarantined' END AS disposition,
       coalesce(c.reason, a.unlocated_reason) AS reason,
       to_json(named_struct('osm_type', c.osm_type, 'osm_id', c.osm_id)) AS target_key,
       current_timestamp() AS recorded_at
FROM public_health.silver.facilities_osm_point_silver__classified c
LEFT JOIN public_health.silver.facilities_osm_point_silver__area a
  ON a._source_key = c._source_key AND a._source_file = c._source_file
 AND a._source_sheet <=> c._source_sheet AND a._source_row_num = c._source_row_num
LEFT JOIN public_health.silver.facilities_osm_point_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class = 'non_data' OR a.psgc_code IS NULL;


-- =============================================================================
-- [5] gates. severity 'fail' stops the build; 'warn' is reported in build_log.parameters.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_osm_point_silver__gates AS
SELECT 'inputs: not exactly one healthsites file' AS gate, 'fail' AS severity,
       abs((SELECT count(*) FROM public_health.silver.facilities_osm_point_silver__inputs WHERE input_kind = 'bronze_source') - 1) AS failures
UNION ALL
SELECT 'inputs: no processed ingestion log match, or more than one', 'fail', count(*)
  FROM public_health.silver.facilities_osm_point_silver__inputs
  WHERE input_kind = 'bronze_source' AND (metadata_matches > 1 OR (metadata_matches = 0 AND strict_load_lookup))
UNION ALL
-- 04a must have run on exactly the bronze rows of this build (same file, load time and row set)
SELECT 'inputs: 04a staging does not match the bronze rows read (rerun 04a)', 'fail', count(*) FROM (
  SELECT c._source_row_num FROM public_health.silver.facilities_osm_point_silver__classified c
  LEFT ANTI JOIN public_health.silver.facilities_osm_point_silver__located l
    ON l._source_key = c._source_key AND l._source_file = c._source_file AND l._source_sheet <=> c._source_sheet
   AND l._source_row_num = c._source_row_num AND l._ingested_at = c._ingested_at
  UNION ALL
  SELECT l._source_row_num FROM public_health.silver.facilities_osm_point_silver__located l
  LEFT ANTI JOIN public_health.silver.facilities_osm_point_silver__classified c
    ON l._source_key = c._source_key AND l._source_file = c._source_file AND l._source_sheet <=> c._source_sheet
   AND l._source_row_num = c._source_row_num AND l._ingested_at = c._ingested_at)
UNION ALL
SELECT 'inputs: boundaries changed after 04a ran (rerun 04a)', 'fail',
       CASE WHEN (SELECT count(DISTINCT boundary_rows) FROM public_health.silver.facilities_osm_point_silver__located) = 1
             AND (SELECT max(boundary_rows) FROM public_health.silver.facilities_osm_point_silver__located)
               = (SELECT count(*) FROM public_health.silver.facilities_area_boundary WHERE boundary_rule = 'hdx' AND geometry_json IS NOT NULL)
            THEN 0 ELSE 1 END
UNION ALL
SELECT 'key not unique (osm_type, osm_id)', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_osm_point_silver__candidate GROUP BY osm_type, osm_id HAVING count(*) > 1)
UNION ALL
SELECT 'key column null', 'fail', count(*)
  FROM public_health.silver.facilities_osm_point_silver__candidate WHERE osm_type IS NULL OR osm_id IS NULL
UNION ALL
SELECT 'psgc_code not a city / municipality of the geography snapshot', 'fail', count(*)
  FROM public_health.silver.facilities_osm_point_silver__candidate c
  LEFT ANTI JOIN fac_osm_geo g ON g.psgc_code = c.psgc_code
UNION ALL
SELECT 'coordinates present but outside the Philippines, or a point without coordinates placed by them', 'fail', count(*)
  FROM public_health.silver.facilities_osm_point_silver__candidate
  WHERE (has_coordinates AND (longitude NOT BETWEEN ph_bbox[0] AND ph_bbox[2] OR latitude NOT BETWEEN ph_bbox[1] AND ph_bbox[3]))
     OR (location_precision = 'point' AND NOT has_coordinates)
UNION ALL
SELECT 'coordinates that are not numbers', 'fail', count(*)
  FROM public_health.silver.facilities_osm_point_silver__classified c
  JOIN public_health.silver.facilities_osm_point_silver__area a
    ON a._source_file = c._source_file AND a._source_row_num = c._source_row_num
  WHERE a.coordinate_status IN ('not_a_number', 'outside_ph')
UNION ALL
SELECT 'facility_type missing', 'fail', count(*)
  FROM public_health.silver.facilities_osm_point_silver__candidate WHERE facility_type IS NULL
UNION ALL
SELECT 'lineage: a lineage column is null (only _source_sheet may be)', 'fail', count(*)
  FROM public_health.silver.facilities_osm_point_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _source_row_num IS NULL
     OR _as_of_date IS NULL OR _metric_source_columns IS NULL OR size(_metric_source_columns) = 0
UNION ALL
SELECT 'reconciliation: inputs where rows referenced by silver <> rows read - rows not loaded', 'fail', count(*)
FROM public_health.silver.facilities_osm_point_silver__inputs i
LEFT JOIN (
  SELECT _source_key, _source_file, _source_sheet, count(*) AS n FROM (
    SELECT DISTINCT _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.silver.facilities_osm_point_silver__candidate)
  GROUP BY _source_key, _source_file, _source_sheet) ref
  ON ref._source_key = i.source_key AND ref._source_file = i.source_file AND ref._source_sheet <=> i.source_sheet
LEFT JOIN (
  SELECT source_key, source_file, source_sheet, count(*) AS n
  FROM public_health.silver.facilities_osm_point_silver__dispositions GROUP BY source_key, source_file, source_sheet) nl
  ON nl.source_key = i.source_key AND nl.source_file = i.source_file AND nl.source_sheet <=> i.source_sheet
WHERE i.input_kind = 'bronze_source' AND i.input_rows - coalesce(nl.n, 0) <> coalesce(ref.n, 0)
UNION ALL
-- control for hdx_healthsites_facility_asof_20261014.csv (sources_facilities.yaml qc.expected_rows).
-- A newer Healthsites file fails here on purpose until its count is verified and set in both places.
SELECT 'control: bronze rows of the newest file = 16,032 (bronze QC expected_rows)', 'fail',
       CASE WHEN (SELECT count(*) FROM public_health.silver.facilities_osm_point_silver__classified) = 16032 THEN 0 ELSE 1 END
UNION ALL
SELECT 'setting: 04a ran with another nearest-boundary distance than this build records', 'fail',
       CASE WHEN (SELECT count(DISTINCT nearest_max_km) FROM public_health.silver.facilities_osm_point_silver__located) = 1
            THEN 0 ELSE 1 END
UNION ALL
-- warnings: reported, never block
SELECT 'warn: health facilities not located (quarantined; see row_disposition)', 'warn', count(*)
  FROM public_health.silver.facilities_osm_point_silver__dispositions WHERE disposition = 'quarantined'
UNION ALL
SELECT 'warn: located by addr:city only (no coordinates; location_precision = municipality)', 'warn', count(*)
  FROM public_health.silver.facilities_osm_point_silver__candidate WHERE location_precision = 'municipality'
UNION ALL
SELECT 'warn: point on a shared border (2+ boundaries; smallest area kept)', 'warn', count(*)
  FROM public_health.silver.facilities_osm_point_silver__candidate WHERE boundary_candidates > 1
UNION ALL
SELECT 'warn: addr:city names another LGU than the coordinates (coordinates kept)', 'warn', count_if(addr_city_conflict)
  FROM public_health.silver.facilities_osm_point_silver__candidate;


-- =============================================================================
-- [6] build log row; stop if a gate failed (the failed build is logged first)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_osm_build_log AS
SELECT osm_build_id AS build_id, 'silver' AS layer, 'facilities' AS domain,
       'public_health.silver.facilities_osm_point_silver' AS target_table,
       silver_build_started_at AS started_at, current_timestamp() AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.facilities_osm_point_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT) AS target_table_version, code_version AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup, 'geography_checksum', geography_checksum,
                            'ph_bbox', ph_bbox, 'osm_health_amenities', osm_health_amenities,
                            'nearest_max_km', (SELECT max(nearest_max_km) FROM public_health.silver.facilities_osm_point_silver__located),
                            'warnings', g.warn_names)) AS parameters,
       job_run_id AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0 AND severity = 'fail') AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'fail' THEN concat(gate, ' = ', failures) END)) AS failed_names,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'warn' THEN concat(gate, ' = ', failures) END)) AS warn_names
      FROM public_health.silver.facilities_osm_point_silver__gates) g;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM fac_osm_build_log WHERE status = 'failed';

SELECT raise_error(concat('facilities_osm_point_silver was NOT published. ', error_message))
FROM fac_osm_build_log WHERE status = 'failed';


-- =============================================================================
-- [7] write (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_osm_point_silver AS
SELECT * FROM public_health.silver.facilities_osm_point_silver__candidate;


-- =============================================================================
-- [8] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.facilities_osm_point_silver),
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_osm_point_silver)),
       code_version, parameters, run_id, error_message
FROM fac_osm_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.facilities_osm_point_silver__inputs;

-- bronze rows not loaded (staged in [4b]); loaded rows are not written (contract 7.1)
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
       content_checksum, disposition, reason, target_key, recorded_at
FROM public_health.silver.facilities_osm_point_silver__dispositions;


-- =============================================================================
-- [9] summary and warnings; drop staging tables (__classified and __area kept until the next run)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_osm_summary AS
SELECT facility_type, location_precision, geo_resolution_method, count(*) AS points,
       count(DISTINCT psgc_code) AS cities_municipalities
FROM public_health.silver.facilities_osm_point_silver
GROUP BY facility_type, location_precision, geo_resolution_method;

CREATE OR REPLACE TEMP VIEW fac_osm_warnings AS
SELECT gate, failures FROM public_health.silver.facilities_osm_point_silver__gates WHERE severity = 'warn';

SELECT * FROM fac_osm_warnings;

DROP TABLE IF EXISTS public_health.silver.facilities_osm_point_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.facilities_osm_point_silver__gates;
DROP TABLE IF EXISTS public_health.silver.facilities_osm_point_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.facilities_osm_point_silver__dispositions;

SELECT * FROM fac_osm_summary ORDER BY points DESC;
