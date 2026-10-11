-- =============================================================================
-- Loads the reviewed poverty area map into the silver schema. Run this first, and again
-- whenever the CSV changes. Every column is loaded as text (PSGC codes have leading zeros).
--
--   socioeconomic_poverty_area_map.csv  -> public_health.silver.socioeconomic_poverty_area_map
--
-- The CSV is drafted by build_socioeconomic_poverty_area_map.py, reviewed by a person and kept
-- in the repo (config/reference/). This file only loads it.
-- The other two approved lists (financing agents, child mortality characteristics) are short
-- and fixed, so they are written inside their own build files, not loaded from a CSV.
--
-- BEFORE RUNNING: replace the path below with where the CSV is readable from
-- (a Volume folder, or a workspace path if your compute can read it).
-- =============================================================================

-- [1] area map
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_poverty_area_map AS
SELECT area_key, geo_name_source, geo_level, psgc_code, parent_geo_name_source, geo_coverage_basis,
       coverage_confirmed, first_estimate_year, is_superseded_area, comparison_eligible,
       exclusion_reason, source_order
FROM read_files('/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/socioeconomic/socioeconomic_poverty_area_map.csv',
       format => 'csv', header => true, multiLine => true,
       schema => 'area_key STRING, geo_name_source STRING, geo_level STRING, psgc_code STRING, parent_geo_name_source STRING, geo_coverage_basis STRING, coverage_confirmed STRING, first_estimate_year STRING, is_superseded_area STRING, comparison_eligible STRING, exclusion_reason STRING, source_order STRING');

-- [2] checks: each must return 0. A failure stops the run here.
CREATE OR REPLACE TEMP VIEW reference_checks AS
SELECT 'area map: table is empty' AS check_name,
       CASE WHEN count(*) = 0 THEN 1 ELSE 0 END AS failures
  FROM public_health.silver.socioeconomic_poverty_area_map
UNION ALL
SELECT 'area map: duplicate area_key', count(*) FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_poverty_area_map GROUP BY area_key HAVING count(*) > 1)
UNION ALL
SELECT 'area map: duplicate geo_name_source', count(*) FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_poverty_area_map GROUP BY geo_name_source HAVING count(*) > 1)
UNION ALL
SELECT 'area map: duplicate psgc_code', count(*) FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE psgc_code IS NOT NULL GROUP BY psgc_code HAVING count(*) > 1)
UNION ALL
SELECT 'area map: psgc_code is not 10 digits (leading zeros lost?)', count(*)
  FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE psgc_code IS NOT NULL AND NOT psgc_code RLIKE '^[0-9]{10}$'
UNION ALL
SELECT 'area map: unknown geo_level', count(*)
  FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE geo_level IS NULL OR geo_level NOT IN ('country', 'region', 'ncr_district', 'province', 'city')
UNION ALL
SELECT 'area map: first_estimate_year is not 2021, 2023 or 2025', count(*)
  FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE try_cast(first_estimate_year AS INT) IS NULL OR try_cast(first_estimate_year AS INT) NOT IN (2021, 2023, 2025)
UNION ALL
SELECT 'area map: a flag is not true or false', count(*)
  FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE try_cast(coverage_confirmed AS BOOLEAN) IS NULL OR try_cast(is_superseded_area AS BOOLEAN) IS NULL
     OR try_cast(comparison_eligible AS BOOLEAN) IS NULL
UNION ALL
SELECT 'area map: not comparison-eligible but no exclusion_reason', count(*)
  FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE try_cast(comparison_eligible AS BOOLEAN) = false AND exclusion_reason IS NULL
UNION ALL
SELECT 'area map: psgc: key does not match psgc_code', count(*)
  FROM public_health.silver.socioeconomic_poverty_area_map
  WHERE (area_key LIKE 'psgc:%' AND NOT (area_key <=> concat('psgc:', psgc_code)))
     OR (area_key NOT LIKE 'psgc:%' AND psgc_code IS NOT NULL);

SELECT raise_error(concat('Reference check failed: ', check_name, ' = ', failures))
FROM reference_checks WHERE failures > 0;

-- [3] result
-- SELECT * FROM reference_checks;
