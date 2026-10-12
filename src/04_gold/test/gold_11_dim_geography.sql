-- ========================================
-- Builds public_health.test_gold.dim_geography
--   One row is: one area in the current PSGC snapshot (one row per area_code), plus named areas with no PSGC code
--   Primary key: area_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Natural key: (area_code)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.geography_silver
--   public_health.silver.admin_boundaries_silver
--   named areas (reviewed list in this file)
--
-- v3.1 columns: area_key, area_code, psgc_code, area_name, geographic_level, income_class,
--   parent_area_key, region_key, province_key, planning_unit_key, broad_unit_key, snapshot_date.
-- Extra columns (proposed additions)
--   * city_class (HUC, ICC, CC): for the planning unit rule and E1 "province and HUC".
--   * area_sqkm, center_lat, center_lon, has_boundary: from admin_boundaries_silver (D-34),
--     for maps and straight-line distance.
-- Rules
--   * Codes, names, levels and hierarchy come from the latest geography_silver snapshot
--     (latest content_checksum). Boundaries join on the matched psgc_code and the level,
--     latest source_version per level. No re-matching.
--   * Barangays and the placeholder row 0990100000 are left out. The Special Geographic Area
--     1999900000 and submunicipalities are kept: silver publishes rows on them. Both levels
--     are additions to the v3.1 list.
--   * Region = first 2 digits. Province = first 5 digits when that is a Prov row. A HUC
--     never gets a province.
--   * Planning and broad unit follow open decision 2. broad_unit_key is null for a HUC
--     outside NCR (no crosswalk yet).
--   * snapshot_date = quarter end of source_version (Q2_2024 gives 2024-06-30).
-- Level counts and name encoding are checked in silver (GS08, GS07).
-- CONFIRM: DISTINCT city_class, income_classification in geography_silver (not in any QC).
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
-- true : every silver input needs a succeeded build in quality.build_log.
-- false: a silver table written by a notebook is allowed. Gold inputs always need one.
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
-- true : a silver input whose latest QC (quality.v_table_health) has a FAIL stops the build.
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_geography__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.geography_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.geography_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.admin_boundaries_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.admin_boundaries_silver
  UNION ALL
  SELECT 'reference' AS input_kind, CAST(NULL AS STRING) AS input_table, 'named areas' AS source_file,
         CAST(7 AS BIGINT) AS input_rows
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_geography_src AS
SELECT psgc_code,
       area_name,
       CASE geographic_level WHEN 'Reg' THEN 'region' WHEN 'Prov' THEN 'province' WHEN 'City' THEN 'city'
                             WHEN 'Mun' THEN 'municipality' WHEN 'SubMun' THEN 'submunicipality'
                             ELSE 'special_geographic_area' END AS geographic_level,
       CASE WHEN geographic_level <> 'City' THEN NULL
            WHEN upper(trim(city_class)) = 'HUC' OR upper(city_class) LIKE '%HIGHLY%' THEN 'HUC'
            WHEN upper(trim(city_class)) = 'ICC' OR upper(city_class) LIKE '%INDEPENDENT%' THEN 'ICC'
            WHEN upper(trim(city_class)) = 'CC' OR upper(city_class) LIKE '%COMPONENT%' THEN 'CC' END AS city_class,
       CASE regexp_extract(income_classification, '([1-5])', 1)
            WHEN '1' THEN '1st' WHEN '2' THEN '2nd' WHEN '3' THEN '3rd'
            WHEN '4' THEN '4th' WHEN '5' THEN '5th' END AS income_class,
       content_checksum,
       last_day(make_date(try_cast(regexp_extract(source_version, '([0-9]{4})', 1) AS INT),
                          3 * try_cast(regexp_extract(source_version, 'Q([1-4])', 1) AS INT), 1)) AS snapshot_date
FROM public_health.silver.geography_silver
WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at)
                          FROM public_health.silver.geography_silver)
  AND (geographic_level IN ('Reg', 'Prov', 'City', 'Mun', 'SubMun')
       OR (geographic_level IS NULL AND psgc_code = '1999900000'));

-- admin_boundaries_silver columns are named only here.
CREATE OR REPLACE TEMP VIEW dim_geography_boundary AS
SELECT CASE CAST(admin_level AS STRING) WHEN '1' THEN 'region' WHEN '2' THEN 'province' ELSE 'locality' END AS boundary_level,
       lpad(trim(CAST(psgc_code AS STRING)), 10, '0') AS psgc_code,
       boundary_pcode,
       CAST(area_sqkm AS DOUBLE) AS area_sqkm, CAST(center_lat AS DOUBLE) AS center_lat,
       CAST(center_lon AS DOUBLE) AS center_lon
FROM (
  SELECT b.*, max_by(b.source_version, b.silver_processed_at) OVER (PARTITION BY b.admin_level) AS latest_version
  FROM public_health.silver.admin_boundaries_silver AS b
) AS v
WHERE source_version = latest_version
  AND CAST(admin_level AS STRING) IN ('1', '2', '3')
  AND nullif(trim(CAST(psgc_code AS STRING)), '') IS NOT NULL;

CREATE OR REPLACE TEMP VIEW dim_geography_psgc AS
SELECT s.*,
       b.boundary_pcode, b.area_sqkm, b.center_lat, b.center_lon,
       concat('psgc:', s.psgc_code) AS area_code,
       concat('psgc:', substr(s.psgc_code, 1, 2), '00000000') AS region_code,
       (substr(s.psgc_code, 1, 2) = '13') AS is_ncr,
       CASE WHEN s.geographic_level = 'province' THEN concat('psgc:', s.psgc_code)
            WHEN s.geographic_level <> 'region' AND NOT coalesce(s.city_class = 'HUC', false) AND p.psgc_code IS NOT NULL
                 THEN concat('psgc:', p.psgc_code) END AS province_code,
       CASE WHEN s.geographic_level = 'submunicipality' THEN concat('psgc:', c.psgc_code) END AS city_code
FROM dim_geography_src AS s
LEFT JOIN dim_geography_src AS p
  ON p.geographic_level = 'province' AND p.psgc_code = concat(substr(s.psgc_code, 1, 5), '00000')
LEFT JOIN dim_geography_src AS c
  ON c.geographic_level = 'city' AND c.psgc_code = concat(substr(s.psgc_code, 1, 5), '00000')
LEFT JOIN dim_geography_boundary AS b
  ON b.psgc_code = s.psgc_code
 AND b.boundary_level = CASE WHEN s.geographic_level IN ('city', 'municipality') THEN 'locality'
                             ELSE s.geographic_level END;

-- Named areas (no PSGC code), reviewed list.
CREATE OR REPLACE TEMP VIEW dim_geography_named AS
SELECT area_code, area_name, geographic_level, up_code AS parent_code, up_code AS region_code,
       CASE WHEN in_unit THEN up_code END AS unit_code
FROM VALUES
  ('ph', 'Philippines', 'country', CAST(NULL AS STRING), false),
  ('foreign', 'Foreign country', 'foreign', CAST(NULL AS STRING), false),
  ('hist:maguindanao', 'Maguindanao (undivided)', 'historical_province', 'psgc:1900000000', false),
  ('ncr-district:1', 'NCR, First District', 'ncr_district', 'psgc:1300000000', true),
  ('ncr-district:2', 'NCR, Second District', 'ncr_district', 'psgc:1300000000', true),
  ('ncr-district:3', 'NCR, Third District', 'ncr_district', 'psgc:1300000000', true),
  ('ncr-district:4', 'NCR, Fourth District', 'ncr_district', 'psgc:1300000000', true)
  AS t (area_code, area_name, geographic_level, up_code, in_unit);

CREATE OR REPLACE TEMP VIEW dim_geography_all AS
SELECT area_code, psgc_code, area_name, geographic_level, income_class,
       CASE geographic_level WHEN 'region' THEN 'ph' WHEN 'province' THEN region_code
            ELSE coalesce(city_code, province_code, region_code) END AS parent_code,
       region_code, province_code,
       CASE WHEN is_ncr THEN 'psgc:1300000000' WHEN geographic_level = 'region' THEN NULL
            ELSE coalesce(province_code, area_code) END AS planning_unit_code,
       CASE WHEN is_ncr THEN 'psgc:1300000000' WHEN geographic_level = 'region' THEN NULL
            WHEN city_class = 'HUC' THEN NULL      -- needs the HUC to province crosswalk
            ELSE coalesce(province_code, area_code) END AS broad_unit_code,
       snapshot_date, city_class, area_sqkm, center_lat, center_lon,
       (boundary_pcode IS NOT NULL) AS has_boundary
FROM dim_geography_psgc
UNION ALL
SELECT n.area_code, CAST(NULL AS STRING), n.area_name, n.geographic_level, CAST(NULL AS STRING),
       n.parent_code, n.region_code, CAST(NULL AS STRING), n.unit_code, n.unit_code,
       c.snapshot_date, CAST(NULL AS STRING), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), CAST(NULL AS DOUBLE), false
FROM dim_geography_named AS n
CROSS JOIN (SELECT max(snapshot_date) AS snapshot_date FROM dim_geography_src) AS c;

CREATE OR REPLACE TABLE public_health.test_gold.dim_geography__candidate AS
SELECT xxhash64(area_code)                        AS area_key,
       area_code,
       psgc_code,
       area_name,
       geographic_level,
       income_class,
       nvl2(parent_code, xxhash64(parent_code), NULL)                      AS parent_area_key,
       nvl2(region_code, xxhash64(region_code), NULL)                      AS region_key,
       nvl2(province_code, xxhash64(province_code), NULL)                    AS province_key,
       nvl2(planning_unit_code, xxhash64(planning_unit_code), NULL)               AS planning_unit_key,
       nvl2(broad_unit_code, xxhash64(broad_unit_code), NULL)                  AS broad_unit_key,
       snapshot_date,
       city_class,                                -- extra
       area_sqkm,                                 -- extra
       center_lat,                                -- extra
       center_lon,                                -- extra
       has_boundary,                              -- extra
       gold_build_id                              AS _gold_build_id
FROM dim_geography_all;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_geography__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.dim_geography__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.dim_geography__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.dim_geography__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.dim_geography__candidate
WHERE area_key IS NULL OR area_code IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_geography__candidate GROUP BY area_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_geography__candidate
  GROUP BY area_code HAVING count(*) > 1)
UNION ALL
SELECT 'no snapshot date', count_if(snapshot_date IS NULL) FROM dim_geography_src
UNION ALL
SELECT 'PSGC code on two boundaries of one level (AB07)', count(*) FROM (
  SELECT 1 FROM dim_geography_boundary GROUP BY boundary_level, psgc_code HAVING count(*) > 1)
UNION ALL
SELECT 'no boundary with a PSGC code', CAST(count(*) = 0 AS INT) FROM dim_geography_boundary
UNION ALL
SELECT 'centroid outside the Philippines or area <= 0', count(*) FROM public_health.test_gold.dim_geography__candidate
WHERE has_boundary AND (coalesce(center_lon, 0) NOT BETWEEN 114 AND 127
   OR coalesce(center_lat, 0) NOT BETWEEN 4 AND 21.5 OR coalesce(area_sqkm, 0) <= 0)
UNION ALL
SELECT 'city without a recognised city_class', count(*) FROM public_health.test_gold.dim_geography__candidate WHERE geographic_level = 'city' AND city_class IS NULL
UNION ALL
SELECT 'area_name missing', count(*) FROM public_health.test_gold.dim_geography__candidate WHERE area_name IS NULL
UNION ALL
SELECT 'locality with no planning unit', count(*) FROM public_health.test_gold.dim_geography__candidate
WHERE geographic_level IN ('city', 'municipality', 'submunicipality') AND planning_unit_key IS NULL
UNION ALL
SELECT 'parent or unit key not in the candidate', count(*) FROM (
  SELECT explode(array(parent_area_key, region_key, province_key, planning_unit_key, broad_unit_key)) AS k
  FROM public_health.test_gold.dim_geography__candidate) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography__candidate AS d ON d.area_key = c.k
WHERE c.k IS NOT NULL;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.dim_geography__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_geography_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'geography'                                      AS domain,
       'public_health.test_gold.dim_geography'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds, 'planning_unit_rule', 'open decision 2 proposal')) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.dim_geography__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.dim_geography__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_geography_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_geography was NOT published. ', error_message))
FROM dim_geography_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_geography AS
SELECT * FROM public_health.test_gold.dim_geography__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.dim_geography));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.dim_geography),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_geography_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.dim_geography', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.dim_geography__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.dim_geography__candidate;
DROP TABLE IF EXISTS public_health.test_gold.dim_geography__gates;
DROP TABLE IF EXISTS public_health.test_gold.dim_geography__inputs;

-- Expected with boundary: 1,634 of 1,642 localities.
SELECT geographic_level, city_class, count(*) AS areas, count_if(has_boundary) AS with_boundary,
       count_if(province_key IS NULL) AS without_province,
       count_if(broad_unit_key IS NULL) AS without_broad_unit
FROM public_health.test_gold.dim_geography
GROUP BY geographic_level, city_class ORDER BY geographic_level, city_class;