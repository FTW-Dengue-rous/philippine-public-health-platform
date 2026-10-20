-- ========================================
-- Builds public_health.gold.dim_geography
--   One row is: one area in the current PSGC snapshot, plus 7 named areas with no PSGC code
--   Primary key: area_key = xxhash64(area_code). The same area_code gives the same key on
--                every rebuild.
--   Natural key: area_code ('psgc:<10-digit code>' or a named code such as 'ph')
--
-- Reads
--   public_health.silver.geography_silver        codes, names, levels, city class, income class
--   public_health.silver.admin_boundaries_silver area, centroid, boundary match (HDX COD-AB)
--   named areas                                  reviewed list in this file
--
-- Columns: area_key, area_code, psgc_code, area_name, geographic_level, income_class,
--   parent_area_key, region_key, province_key, planning_unit_key, broad_unit_key, snapshot_date.
-- Extra columns (not in the Proposal v3.1 column list):
--   * city_class (HUC, ICC, CC): for the planning unit rule and E1 "province and HUC".
--   * area_sqkm, center_lat, center_lon, has_boundary: from admin_boundaries_silver (D-34),
--     for maps and straight-line distance (gold 20).
--
-- Rules
--   * Snapshot: codes, names, levels and hierarchy come from ONE geography_silver snapshot:
--     the content_checksum of the row processed last (D-30).
--   * Levels kept: region, province, city, municipality, submunicipality, and the Special
--     Geographic Area row 1999900000 (no level in silver; silver publishes rows on it).
--     Submunicipality and the SGA are additions to the v3.1 list.
--     Left out: barangays and rows with no level, such as the placeholder 0990100000 (D-31).
--   * Boundaries: left join on the matched psgc_code AND the level (ADM1 = region,
--     ADM2 = province, ADM3 = city or municipality). Latest source_version per level.
--     Nothing is re-matched here. These areas have no boundary (has_boundary = false, null area
--     and centroid): submunicipalities, the SGA, the named areas, and any area HDX does not
--     match.
--   * Hierarchy from the PSGC code:
--       region   = first 2 digits + '00000000'
--       province = first 5 digits + '00000', when that code is a province row
--       A region or a HUC never gets a province. An ICC or CC inside a province gets it.
--       parent   = the city for a submunicipality, else the province, else the region.
--                  A province's parent is its region; a region's parent is 'ph'.
--   * Planning unit and broad unit (O-01, built as proposed):
--       planning unit  NCR for every NCR area; the province for a province and its
--                      localities (HUCs excluded, ICCs stay inside); the area itself for a HUC
--                      or a locality with no province row (Isabela City, the SGA). Null for
--                      regions outside NCR.
--       broad unit     the same, except a HUC outside NCR, where it is null. The province of
--                      such a HUC comes from huc_province_crosswalk (gold 11), built after
--                      this table.
--   * Named areas: ph, foreign, hist:maguindanao (undivided Maguindanao, region BARMM) and
--     ncr-district:1 to 4 (planning and broad unit NCR). They take the latest snapshot_date.
--     The list sits before [1], which records its row count.
--   * snapshot_date = quarter end of the silver source_version (Q2_2024 gives 2024-06-30).
--     try_cast is deliberate here: a version the pattern cannot read gives null, and the gate
--     'no snapshot date' then stops the build.
--
-- Build steps (write-audit-publish)
--   [0] build id and settings
--   [1] __inputs     every input, with the build that wrote it and its latest silver QC
--   [2] __candidate  the candidate rows
--   [3] __gates      every gate must have failures = 0
--   [4] stop if a gate failed: the failed build is logged, the published table is not touched
--   [5] write the table from the candidate (full rebuild)
--   [6] record the build in quality.build_log and quality.build_inputs
--   [7] drop the staging tables, then show the summary
--
-- History
--   2026-10-14  Written for the combined data model (from gold_11, v1).
--   2026-10-19  Moved to public_health.gold and renamed gold_01. Comments updated. Build log
--               parameters: 'model' label removed (one final model), planning_unit_rule = 'O-01'.
--               No change to the table.
--   2026-10-20  The named-area list is defined before [1], and its row count is read from it
--               (was typed as 7).
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
-- true : every silver input needs a succeeded build in quality.build_log.
-- false: a silver table written by a notebook is allowed. Gold inputs always need one.
--        Keep false here: geography_silver and admin_boundaries_silver are written by notebooks.
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
-- true : a silver input whose latest QC (quality.v_table_health) has a FAIL stops the build.
--        No QC run does not stop it; it makes the approval provisional (step [4]).
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job


-- Named areas (no PSGC code), reviewed list. [1] counts its rows.
-- up_code = parent and region; in_unit = true gives the parent as planning and broad unit.
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


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_geography__inputs AS
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
         (SELECT count(*) FROM dim_geography_named) AS input_rows
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
-- PSGC rows of the latest snapshot, with standard level, city class and income class spellings.
-- The CASE accepts HUC / ICC / CC or the long spellings. Income class keeps the first digit 1-5.
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

-- Boundaries of the latest source_version per admin level, with a PSGC code.
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

-- PSGC rows with their region, province and city codes and their boundary.
-- Province = first 5 digits + '00000' when that is a province row; never for a region or a HUC.
-- City = the parent city of a submunicipality.
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

-- PSGC rows plus named areas, with parent, planning unit and broad unit codes (rules in the header)
CREATE OR REPLACE TEMP VIEW dim_geography_all AS
SELECT area_code, psgc_code, area_name, geographic_level, income_class,
       CASE geographic_level WHEN 'region' THEN 'ph' WHEN 'province' THEN region_code
            ELSE coalesce(city_code, province_code, region_code) END AS parent_code,
       region_code, province_code,
       CASE WHEN is_ncr THEN 'psgc:1300000000' WHEN geographic_level = 'region' THEN NULL
            ELSE coalesce(province_code, area_code) END AS planning_unit_code,
       CASE WHEN is_ncr THEN 'psgc:1300000000' WHEN geographic_level = 'region' THEN NULL
            WHEN city_class = 'HUC' THEN NULL      -- HUC outside NCR: province via huc_province_crosswalk (gold 11)
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

-- Codes become keys: key = xxhash64(code); a null code gives a null key.
CREATE OR REPLACE TABLE public_health.gold.dim_geography__candidate AS
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
-- [3] gates: every row must have failures = 0.
--     AB07 is the same rule as the admin boundaries silver check AB07 (one code per level).
--     The last gate checks that every parent and unit key points to a row of this table.
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_geography__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.dim_geography__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.dim_geography__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.dim_geography__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.dim_geography__candidate
WHERE area_key IS NULL OR area_code IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_geography__candidate GROUP BY area_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_geography__candidate
  GROUP BY area_code HAVING count(*) > 1)
UNION ALL
SELECT 'no snapshot date', count_if(snapshot_date IS NULL) FROM dim_geography_src
UNION ALL
SELECT 'PSGC code on two boundaries of one level (AB07)', count(*) FROM (
  SELECT 1 FROM dim_geography_boundary GROUP BY boundary_level, psgc_code HAVING count(*) > 1)
UNION ALL
SELECT 'no boundary with a PSGC code', CAST(count(*) = 0 AS INT) FROM dim_geography_boundary
UNION ALL
SELECT 'centroid outside the Philippines or area <= 0', count(*) FROM public_health.gold.dim_geography__candidate
WHERE has_boundary AND (coalesce(center_lon, 0) NOT BETWEEN 114 AND 127
   OR coalesce(center_lat, 0) NOT BETWEEN 4 AND 21.5 OR coalesce(area_sqkm, 0) <= 0)
UNION ALL
SELECT 'city without a recognised city_class', count(*) FROM public_health.gold.dim_geography__candidate WHERE geographic_level = 'city' AND city_class IS NULL
UNION ALL
SELECT 'area_name missing', count(*) FROM public_health.gold.dim_geography__candidate WHERE area_name IS NULL
UNION ALL
SELECT 'locality with no planning unit', count(*) FROM public_health.gold.dim_geography__candidate
WHERE geographic_level IN ('city', 'municipality', 'submunicipality') AND planning_unit_key IS NULL
UNION ALL
SELECT 'parent or unit key not in the candidate', count(*) FROM (
  SELECT explode(array(parent_area_key, region_key, province_key, planning_unit_key, broad_unit_key)) AS k
  FROM public_health.gold.dim_geography__candidate) AS c
LEFT ANTI JOIN public_health.gold.dim_geography__candidate AS d ON d.area_key = c.k
WHERE c.k IS NOT NULL;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.dim_geography__gates WHERE failures <> 0
--     approval: provisional while a silver input has no QC run or has WARN findings to review.
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_geography_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'geography'                                      AS domain,
       'public_health.gold.dim_geography'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds, 'planning_unit_rule', 'O-01')) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.dim_geography__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.dim_geography__inputs) AS q;

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
CREATE OR REPLACE TABLE public_health.gold.dim_geography AS
SELECT * FROM public_health.gold.dim_geography__candidate;


-- ========================================
-- [6] record the build, with the table version just written. If your runtime rejects this
--     SET VAR, delete it: the version stays null, and freshness checks (G06,
--     mart_evidence_readiness) cannot compare this table.
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.dim_geography));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.dim_geography),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_geography_build_log;

-- one row per input; the named-area list is recorded with code_version as its version
INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.dim_geography', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.dim_geography__inputs;

-- ========================================
-- [7] remove the staging tables, then show the summary
-- ========================================
DROP TABLE IF EXISTS public_health.gold.dim_geography__candidate;
DROP TABLE IF EXISTS public_health.gold.dim_geography__gates;
DROP TABLE IF EXISTS public_health.gold.dim_geography__inputs;

-- Summary by level and city class.
-- Expect 1,634 of the 1,642 cities and municipalities with a boundary. Total rows on the
-- 2026-10-13 run: 1,764. without_broad_unit = the HUCs outside NCR, regions outside NCR, ph and
-- foreign, and hist:maguindanao.
SELECT geographic_level, city_class, count(*) AS areas, count_if(has_boundary) AS with_boundary,
       count_if(province_key IS NULL) AS without_province,
       count_if(broad_unit_key IS NULL) AS without_broad_unit
FROM public_health.gold.dim_geography
GROUP BY geographic_level, city_class ORDER BY geographic_level, city_class;