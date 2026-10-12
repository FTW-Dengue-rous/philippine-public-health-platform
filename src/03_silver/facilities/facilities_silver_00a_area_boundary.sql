-- =============================================================================
-- This file builds public_health.silver.facilities_area_boundary from the team's HDX boundaries
-- (public_health.silver.admin_boundaries_silver, HDX COD-AB PHL). One row per city / municipality
-- of geography_silver, with the HDX polygon, centroid and area when one is accepted.
--
-- Why: facilities place OSM points in a municipality by point-in-polygon (04a) and gold measures
-- distance to the municipality centroid. Both must use the SAME boundaries as dim_geography, so
-- this table copies admin_boundaries_silver; it never builds or downloads its own polygons.
--
-- Rules
--   geography_silver decides the areas (latest snapshot, City and Mun). admin_boundaries_silver
--   gives the polygon whose matched psgc_code is that area. A polygon is ACCEPTED when
--     - its HDX name agrees with the geography name (same place key as the facilities builds; the
--       text in brackets counts as a second name: 'Bacungan (Leon T. Postigo)'), or
--     - its psgc_match_status is a name-based match (anything other than CODE_MATCH): those were
--       matched by name in the admin boundaries notebook already.
--   A CODE_MATCH whose names disagree is NOT used (the admin boundaries defect: 16 Maguindanao del
--   Norte / del Sur municipalities carry another municipality's code). The area keeps a row with
--   boundary_rule 'name_conflict' and no geometry, so the gap is visible and nothing is misplaced.
--   Once the notebook fix is applied these rows become 'hdx' without any change here.
--
--   boundary_rule   hdx            exactly one accepted HDX polygon
--                   name_conflict  HDX rows carry the code, none accepted (names disagree)
--                   no_boundary    no HDX row carries the code (e.g. SGA municipalities, which the
--                                  notebook keeps as SPECIAL_STRUCTURE without a psgc_code)
--
-- Gates (stop the run, nothing written): no ADM3 rows; a code with 2+ accepted polygons; an
-- accepted polygon without geometry, outside the Philippines, with area <= 0, or not in WGS84.
-- Warnings (shown, not stopping): name_conflict, no_boundary, HDX polygons not used.
--
-- Run order: geography_silver -> admin_boundaries_silver -> THIS -> build_facilities_area_exceptions.py
--            -> facilities_silver_00_reference.sql -> 01 ... 04
--
-- Column names of admin_boundaries_silver are taken from the notebook owner's guide
-- (admin_level, boundary_pcode, boundary_name, adm2_name, psgc_code, psgc_match_status, area_sqkm,
-- center_lat, center_lon, geometry_json, source_crs, boundary_version, source_version,
-- silver_processed_at). CONFIRM with DESCRIBE before the first run; they are only named in [1].
-- Status: first Databricks run 2026-10-12: 1 name_conflict (Leon T. Postigo, HDX 'Bacungan (Leon T.
-- Postigo)', now accepted through the bracket name) and 8 no_boundary (SGA municipalities, no
-- psgc_code in HDX). Bracket rule tested on local Spark 4.0 against a stand-in.
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
        coalesce(centroid_lon, 0) NOT BETWEEN 114 AND 127 OR coalesce(centroid_lat, 0) NOT BETWEEN 4 AND 21.5
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
