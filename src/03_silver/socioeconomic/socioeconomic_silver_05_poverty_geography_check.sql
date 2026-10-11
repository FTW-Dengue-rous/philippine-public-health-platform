-- =============================================================================
-- Validates every PSGC code of the poverty area map against the geography silver table.
-- Run it after socioeconomic_silver_00_reference.sql, and again whenever geography silver or the
-- area map changes.
--
-- Geography table: public_health.silver.geography_silver (source of truth for PSGC codes and
-- names). Columns used: psgc_code, area_name, geographic_level (Reg / Prov / City / Mun / SubMun /
-- Bgy, or null for the two placeholder rows 0990100000 and 1999900000).
--
-- This file only VALIDATES. It does not assign codes (the area map does that) and it does not
-- bring geography attributes (income class, urban/rural, population) into poverty silver.
-- Those joins belong in gold, for rows where comparison_eligible is true.
--
-- Result: one row per finding.
--   FAIL    stops the run. Fix the area map or geography silver before poverty silver is used.
--   WARN    a code is not in geography (retired or renamed). Read it and decide.
--   REVIEW  expected differences (a name spelled differently, a code with no level).
--
-- Names are compared after normalising: upper case, N for N-tilde, punctuation to spaces, and
-- "CITY OF X" read as "X CITY". So "Cotabato City" equals "City of Cotabato".
-- =============================================================================

-- Name key used on both sides of the comparison
CREATE OR REPLACE TEMPORARY FUNCTION se_geo_name_key(s STRING) RETURNS STRING
RETURN regexp_replace(
         trim(regexp_replace(regexp_replace(translate(upper(s), 'Ñ', 'N'), '[^A-Z0-9]', ' '), ' +', ' ')),
         '^CITY OF (.+)$', '$1 CITY');

CREATE OR REPLACE TEMP VIEW poverty_geography_checks AS
WITH g AS (
  SELECT lpad(trim(psgc_code), 10, '0') AS psgc_code,
         area_name                      AS geo_name,
         CASE geographic_level WHEN 'Reg' THEN 'region' WHEN 'Prov' THEN 'province' WHEN 'City' THEN 'city'
              ELSE lower(geographic_level) END AS geo_level,
         count(*) OVER (PARTITION BY lpad(trim(psgc_code), 10, '0')) AS rows_for_code
  FROM public_health.silver.geography_silver
),
m AS (
  SELECT area_key, geo_name_source, geo_level, psgc_code
  FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE psgc_code IS NOT NULL
)
SELECT 'S04' AS check_id, 'PSGC code not found in geography' AS finding, 'WARN' AS severity,
       m.area_key, m.geo_name_source, m.psgc_code, m.geo_level AS map_level,
       CAST(NULL AS STRING) AS geography_level, CAST(NULL AS STRING) AS geography_name
FROM m LEFT ANTI JOIN g ON g.psgc_code = m.psgc_code
UNION ALL
SELECT DISTINCT 'S93', 'PSGC code appears more than once in geography', 'FAIL',
       m.area_key, m.geo_name_source, m.psgc_code, m.geo_level, g.geo_level, g.geo_name
FROM m JOIN g ON g.psgc_code = m.psgc_code WHERE g.rows_for_code > 1
UNION ALL
SELECT 'S93', 'geographic level differs from geography', 'FAIL',
       m.area_key, m.geo_name_source, m.psgc_code, m.geo_level, g.geo_level, g.geo_name
FROM m JOIN g ON g.psgc_code = m.psgc_code
WHERE g.geo_level IS NOT NULL AND g.geo_level <> m.geo_level
UNION ALL
SELECT 'S93', 'geography has no level for this code (placeholder row)', 'FAIL',
       m.area_key, m.geo_name_source, m.psgc_code, m.geo_level, g.geo_level, g.geo_name
FROM m JOIN g ON g.psgc_code = m.psgc_code
WHERE g.geo_level IS NULL
UNION ALL
SELECT 'S04', 'name differs from geography', 'REVIEW',
       m.area_key, m.geo_name_source, m.psgc_code, m.geo_level, g.geo_level, g.geo_name
FROM m JOIN g ON g.psgc_code = m.psgc_code
WHERE se_geo_name_key(m.geo_name_source) <> se_geo_name_key(g.geo_name);

-- Findings, most serious first
SELECT * FROM poverty_geography_checks
ORDER BY CASE severity WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END, finding, geo_name_source;

-- Stop if anything is a FAIL
SELECT raise_error(concat('Poverty area map does not agree with geography silver: ', n, ' FAIL finding(s). ',
                          'See poverty_geography_checks.'))
FROM (SELECT count(*) AS n FROM poverty_geography_checks WHERE severity = 'FAIL') WHERE n > 0;