-- =============================================================================
-- Builds public_health.silver.facilities_area_boundary from
-- public_health.silver.admin_boundaries_silver (HDX COD-AB PHL).
-- Grain: one city/municipality from geography_silver.
--
-- Purpose
--   Provides the shared municipality polygons and centroids used for OSM
--   point-in-polygon matching and downstream distance analysis. Reuses the team's
--   HDX boundaries so facilities and dim_geography use the same geography source.
--
-- Boundary assignment
--   geography_silver defines the required cities and municipalities.
--   Accepts an HDX polygon when its PSGC code matches the area and either:
--     - the HDX and geography names agree, or
--     - admin_boundaries_silver matched the boundary by name.
--
--   Rejects code-matched polygons whose names disagree to avoid assigning the
--   wrong geometry.
--
-- boundary_rule
--   hdx            accepted HDX polygon
--   name_conflict  matching code exists, but the boundary name conflicts
--   no_boundary    no usable HDX polygon exists for the area
--
-- Validation
--   Stops the build for duplicate accepted polygons, missing/invalid geometry,
--   invalid area, coordinates outside the Philippines, or non-WGS84 geometry.
--   Reports missing/conflicting boundaries as warnings.
--
-- Run before:
--   build_facilities_area_exceptions.py
--   facilities_silver_00_reference.sql
--   downstream facilities Silver builds
--
-- Requires geography_silver and admin_boundaries_silver.
-- =============================================================================

-- [0] place key: the same normalisation as facilities_silver_01_registry.sql, brackets dropped first
CREATE OR REPLACE TEMPORARY FUNCTION fac_norm (s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(
    translate(
        upper(replace(replace(replace(replace(s, 'Ã±', 'N'), 'Ã‘', 'N'), 'ñ', 'N'), '?', 'N')), 'ÑÁÉÍÓÚ', 'NAEIOU'
    ),
    '[^A-Z0-9]', ' '
), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION fac_place (s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    regexp_replace(regexp_replace(
        concat(' ', fac_norm(regexp_replace(s, "['’`-]", '')), ' '),
        ' (HUC|ICC|CC|CAPITAL|NOT A PROVINCE) ', ' '
    ),
    ' STA ', ' SANTA '), ' STO ', ' SANTO '
), ' GEN ', ' GENERAL '), ' GOV ', ' GOVERNOR '), ' SEN ', ' SENATOR '),
'^ (MUNICIPALITY OF|ISLAND GARDEN CITY OF|SCIENCE CITY OF|CITY OF) ', ' '), ' CITY $', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION fac_boundary_key (s STRING) RETURNS STRING
RETURN replace(fac_place(regexp_replace(s, '\\([^)]*\\)', ' ')), ' ', '');

-- The name inside brackets, as a second name: HDX writes a renamed municipality as
-- 'Bacungan (Leon T. Postigo)' (old name, current name in brackets). Null when there is no
-- bracket or it holds only a tag such as '(Capital)'.
CREATE OR REPLACE TEMPORARY FUNCTION fac_boundary_alt_key (s STRING) RETURNS STRING
RETURN nullif(replace(fac_place(regexp_extract(s, '\\(([^)]*)\\)', 1)), ' ', ''), '');

-- Philippine bounding box (lon_min, lat_min, lon_max, lat_max) for the centroid gate. Same box as
-- PH_BBOX in facilities_silver_04a_osm_locate.py and ph_bbox in 04; was typed in the gate until
-- 2026-10-19 (rule 2a).
DECLARE OR REPLACE VARIABLE fab_ph_bbox ARRAY<DOUBLE> DEFAULT array(114D, 4D, 127D, 21.5D);

-- [1] inputs: the only place that names columns of the two source tables
DECLARE OR REPLACE VARIABLE fab_geography_checksum STRING;
SET VAR fab_geography_checksum
= (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

DECLARE OR REPLACE VARIABLE fab_source_version STRING;
SET VAR fab_source_version
= (
    SELECT max_by(source_version, silver_processed_at) FROM public_health.silver.admin_boundaries_silver
    WHERE cast(admin_level AS STRING) = '3'
);

CREATE OR REPLACE TEMP VIEW fab_geo AS
SELECT
    lpad(trim(cast(psgc_code AS STRING)), 10, '0') AS psgc_code,
    area_name,
    geographic_level
FROM public_health.silver.geography_silver
WHERE content_checksum = fab_geography_checksum AND geographic_level IN ('City', 'Mun');

CREATE OR REPLACE TEMP VIEW fab_hdx AS
SELECT
    nullif(lpad(trim(cast(psgc_code AS STRING)), 10, '0'), '') AS psgc_code,
    boundary_pcode,
    boundary_name,
    adm2_name AS boundary_parent_name,
    psgc_match_status,
    cast(area_sqkm AS DOUBLE) AS area_km2,
    cast(center_lat AS DOUBLE) AS centroid_lat,
    cast(center_lon AS DOUBLE) AS centroid_lon,
    geometry_json,
    source_crs,
    cast(boundary_version AS STRING) AS boundary_version,
    cast(source_version AS STRING) AS source_version
FROM public_health.silver.admin_boundaries_silver
WHERE cast(admin_level AS STRING) = '3' AND source_version = fab_source_version;

-- [2] candidate polygons per area, with the name check
CREATE OR REPLACE TEMP VIEW fab_match AS
SELECT
    psgc_code,
    boundary_pcode,
    boundary_name,
    psgc_match_status,
    name_agrees,
    (name_agrees OR psgc_match_status <> 'CODE_MATCH') AS accepted
FROM (
    SELECT
        g.psgc_code,
        h.boundary_pcode,
        h.boundary_name,
        h.psgc_match_status,
        fac_boundary_key(g.area_name) IN (
            fac_boundary_key(h.boundary_name),
            coalesce(fac_boundary_alt_key(h.boundary_name), '-')
        ) AS name_agrees
    FROM fab_geo AS g
    INNER JOIN fab_hdx AS h ON g.psgc_code = h.psgc_code
) AS m;

CREATE OR REPLACE TEMP VIEW fab_candidate AS
WITH per_area AS (
    SELECT
        psgc_code,
        count(*) AS hdx_rows,
        count_if(accepted) AS accepted_rows,
        max_by(boundary_pcode, accepted) AS accepted_pcode,
        concat_ws('; ', collect_list(CASE WHEN NOT accepted THEN concat(boundary_pcode, ' ', boundary_name) END))
            AS rejected
    FROM fab_match
    GROUP BY psgc_code
)

SELECT
    g.psgc_code,
    g.area_name,
    g.geographic_level,
    CASE
        WHEN p.accepted_rows = 1 THEN 'hdx'
        WHEN p.hdx_rows > 0 AND p.accepted_rows = 0 THEN 'name_conflict'
        WHEN p.accepted_rows > 1 THEN 'duplicate'
        ELSE 'no_boundary'
    END AS boundary_rule,
    h.boundary_pcode,
    h.boundary_name,
    h.boundary_parent_name,
    h.psgc_match_status,
    coalesce(p.hdx_rows, 0) AS hdx_rows,
    h.centroid_lat,
    h.centroid_lon,
    h.area_km2,
    h.geometry_json,
    h.source_crs,
    'HDX COD-AB PHL (admin_boundaries_silver)' AS boundary_source,
    h.boundary_version,
    fab_source_version AS source_version,  -- noqa: RF02
    CASE
        WHEN p.accepted_rows = 0 AND p.hdx_rows > 0
            THEN concat('HDX polygon(s) carry this code but the name differs: ', p.rejected)
        WHEN p.hdx_rows IS NULL THEN 'no HDX polygon carries this code'
    END AS review_note,
    fab_geography_checksum AS geography_checksum  -- noqa: RF02
FROM fab_geo AS g
LEFT JOIN per_area AS p ON g.psgc_code = p.psgc_code
LEFT JOIN fab_hdx AS h ON p.accepted_rows = 1 AND g.psgc_code = h.psgc_code AND p.accepted_pcode = h.boundary_pcode;

-- [3] gates: each must be 0, or nothing is written
CREATE OR REPLACE TEMP VIEW fab_gates AS
SELECT
    'admin_boundaries_silver has no ADM3 rows in its latest source_version' AS gate,
    cast((SELECT count(*) FROM fab_hdx) = 0 AS INT) AS failures
UNION ALL
SELECT
    'geography area with 2+ accepted HDX polygons (run check AB07 in the boundaries notebook)' AS gate,
    count(*) AS failures
FROM fab_candidate
WHERE boundary_rule = 'duplicate'
UNION ALL
SELECT
    'not exactly one row per geography city / municipality' AS gate,
    abs((SELECT count(*) FROM fab_geo) - count(DISTINCT psgc_code))
    + abs(count(*) - count(DISTINCT psgc_code)) AS failures
FROM fab_candidate
UNION ALL
SELECT
    'accepted polygon without GeoJSON geometry' AS gate,
    count(*) AS failures
FROM fab_candidate
WHERE boundary_rule = 'hdx' AND (geometry_json IS NULL OR NOT trim(geometry_json) LIKE '{%')
UNION ALL
SELECT
    'accepted polygon: centroid outside the Philippines or area <= 0' AS gate,
    count(*) AS failures
FROM fab_candidate
WHERE
    boundary_rule = 'hdx'
    AND (
        coalesce(centroid_lon, 0) NOT BETWEEN fab_ph_bbox[0] AND fab_ph_bbox[2]
        OR coalesce(centroid_lat, 0) NOT BETWEEN fab_ph_bbox[1] AND fab_ph_bbox[3]
        OR coalesce(area_km2, 0) <= 0
    )
UNION ALL
SELECT
    'source_crs is not WGS84 lon/lat (04a expects EPSG:4326)' AS gate,
    count(*) AS failures
FROM fab_candidate
WHERE boundary_rule = 'hdx' AND source_crs IS NOT NULL AND NOT upper(source_crs) RLIKE '4326|CRS84|WGS ?84';

SELECT raise_error(concat('facilities_area_boundary was NOT written. Gate failed: ', gate, ' = ', failures))
FROM fab_gates
WHERE failures > 0;

-- [4] write
CREATE OR REPLACE TABLE public_health.silver.facilities_area_boundary AS
SELECT * FROM fab_candidate;

-- [5] result: gates, then what to review (warnings do not stop the run)
SELECT * FROM fab_gates;

SELECT
    'boundary_rule = ' || boundary_rule AS item,
    count(*) AS areas
FROM public_health.silver.facilities_area_boundary
GROUP BY boundary_rule
UNION ALL
SELECT
    'HDX ADM3 polygons not used (no psgc_code, or code not a geography city / municipality)' AS item,
    count(*) AS areas
FROM fab_hdx AS h
WHERE
    NOT EXISTS (
        SELECT 1 FROM fab_match AS m
        WHERE m.boundary_pcode = h.boundary_pcode AND m.accepted
    )
ORDER BY item;

-- areas without a polygon: OSM points there fall back to nearest boundary or their addr:city tag
SELECT
    psgc_code,
    area_name,
    boundary_rule,
    review_note
FROM public_health.silver.facilities_area_boundary
WHERE boundary_rule <> 'hdx'
ORDER BY boundary_rule, psgc_code;
