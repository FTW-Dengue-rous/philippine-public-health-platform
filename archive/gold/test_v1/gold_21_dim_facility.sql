-- ========================================
-- Builds public_health.test_gold.dim_facility
--   One row is: one facility establishment in facilities_registry_silver (listed, or carried as not_listed)
--   Primary key: facility_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Natural key: (facility_source_id)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.facilities_registry_silver
--   public_health.test_gold.dim_geography
--
-- v3.1 columns: facility_key, facility_source_id, facility_name, area_key, facility_category,
--   hospital_level, ownership.
-- Extra columns (proposed additions)
--   * facility_status (listed, not_listed): only listed facilities are counted. Closure is
--     never inferred from a carried row.
--   * authorized_beds, analysis_beds, analysis_beds_basis: beds per facility, with the basis
--     shown next to analysis_beds (facilities handoff rule).
--   * dialysis_stations: K1. Null means not reported, never zero.
--   * is_license_valid_on_as_of: A3 and A4 count licensed primary care facilities.
-- Rules
--   * No matching, keys or area resolution are redone. facility_source_id is the registry
--     facility_key and facility_key is its hash.
--   * ownership is government or private (lower case of the registry column ownership).
--   * hospital_level is Level 1, Level 2 or Level 3, read from service_level. A hospital whose
--     service level names no level gets unknown, so the check "filled for hospitals only" holds.
--   * area_key is the registry area: a city, municipality or Manila submunicipality.
-- Facilities silver ran on Databricks on 2026-10-12, all gates 0. Registry 3,957 rows.
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
CREATE OR REPLACE TABLE public_health.test_gold.dim_facility__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_registry_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_registry_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_geography
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_facility__candidate AS
SELECT xxhash64(r.facility_key)                   AS facility_key,
       r.facility_key                             AS facility_source_id,
       r.facility_name,
       xxhash64(r.area_key)                       AS area_key,
       r.facility_category,
       CASE WHEN r.facility_category = 'hospital'
            THEN coalesce(nullif(regexp_extract(r.service_level, '(Level [1-3])', 1), ''), 'unknown') END AS hospital_level,
       lower(trim(r.ownership))                   AS ownership,
       r.facility_status,                         -- extra
       CAST(r.authorized_beds AS BIGINT)          AS authorized_beds,       -- extra
       CAST(r.analysis_beds AS BIGINT)            AS analysis_beds,         -- extra
       r.analysis_beds_basis,                     -- extra
       CAST(r.dialysis_stations AS BIGINT)        AS dialysis_stations,     -- extra
       r.is_license_valid_on_as_of,               -- extra
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.facilities_registry_silver AS r;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_facility__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.dim_facility__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.dim_facility__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.dim_facility__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.dim_facility__candidate
WHERE facility_key IS NULL OR facility_source_id IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_facility__candidate GROUP BY facility_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_facility__candidate
  GROUP BY facility_source_id HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> registry rows', abs((SELECT count(*) FROM public_health.test_gold.dim_facility__candidate) - count(*)) FROM public_health.silver.facilities_registry_silver
UNION ALL
SELECT 'facility_category outside the four known values', count(*) FROM public_health.test_gold.dim_facility__candidate
WHERE facility_category NOT IN ('hospital', 'infirmary', 'primary_care', 'dialysis_clinic') OR facility_category IS NULL
UNION ALL
SELECT 'ownership outside government, private', count(*) FROM public_health.test_gold.dim_facility__candidate WHERE ownership NOT IN ('government', 'private') OR ownership IS NULL
UNION ALL
SELECT 'hospital_level missing for a hospital or filled for another category', count(*) FROM public_health.test_gold.dim_facility__candidate WHERE (facility_category = 'hospital') <> (hospital_level IS NOT NULL)
UNION ALL
SELECT 'listed facility without an area', count(*) FROM public_health.test_gold.dim_facility__candidate WHERE facility_status = 'listed' AND area_key IS NULL
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.dim_facility__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'analysis beds total <> registry total', CAST(abs(coalesce((SELECT sum(analysis_beds) FROM public_health.test_gold.dim_facility__candidate), 0) - coalesce(sum(analysis_beds), 0)) AS BIGINT)
FROM public_health.silver.facilities_registry_silver;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.dim_facility__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_facility_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'facilities'                                      AS domain,
       'public_health.test_gold.dim_facility'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.dim_facility__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.dim_facility__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_facility_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_facility was NOT published. ', error_message))
FROM dim_facility_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_facility AS
SELECT * FROM public_health.test_gold.dim_facility__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.dim_facility));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.dim_facility),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_facility_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.dim_facility', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.dim_facility__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.dim_facility__candidate;
DROP TABLE IF EXISTS public_health.test_gold.dim_facility__gates;
DROP TABLE IF EXISTS public_health.test_gold.dim_facility__inputs;

SELECT facility_category, hospital_level, ownership, facility_status, count(*) AS facilities,
       sum(analysis_beds) AS analysis_beds, count_if(dialysis_stations IS NOT NULL) AS with_station_count
FROM public_health.test_gold.dim_facility
GROUP BY facility_category, hospital_level, ownership, facility_status
ORDER BY facility_category, hospital_level, ownership;
