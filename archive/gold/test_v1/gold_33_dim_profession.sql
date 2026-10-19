-- ========================================
-- Builds public_health.test_gold.dim_profession
--   One row is: one health profession
--   Primary key: profession_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Natural key: (profession_code)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.workforce_headcount_silver
--   profession names and groups (reviewed list in this file)
--
-- v3.1 columns: profession_key, profession_code, profession_name, profession_group.
-- No extra columns.
-- Rules
--   * Workforce silver has no profession table. The nine codes are the literals written by
--     workforce_silver_02_headcount.sql. Display names and groups are a reviewed list in this
--     file, because the printed label in silver changes by year.
--   * profession_group: core_clinical (doctors, nurses, midwives), community (barangay health
--     workers), other.
--   * A gate fails when silver holds a profession that is not in the list.
--   * The nurse series changes definition in 2019: see is_break_year in fact_workforce.
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
CREATE OR REPLACE TABLE public_health.test_gold.dim_profession__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.workforce_headcount_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.workforce_headcount_silver
  UNION ALL
  SELECT 'reference' AS input_kind, CAST(NULL AS STRING) AS input_table, 'profession names and groups' AS source_file,
         CAST(9 AS BIGINT) AS input_rows
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_profession__candidate AS
SELECT xxhash64(profession_code)                  AS profession_key,
       profession_code,
       profession_name,
       profession_group,
       gold_build_id                              AS _gold_build_id
FROM VALUES
  ('doctors', 'Doctors', 'core_clinical'),
  ('nurses', 'Nurses', 'core_clinical'),
  ('midwives', 'Midwives', 'core_clinical'),
  ('bhw', 'Barangay health workers', 'community'),
  ('dentists', 'Dentists', 'other'),
  ('medtech', 'Medical technologists', 'other'),
  ('nutritionists', 'Nutritionists', 'other'),
  ('sanitary_engineers', 'Sanitary engineers', 'other'),
  ('sanitary_inspectors', 'Sanitary inspectors', 'other')
  AS t (profession_code, profession_name, profession_group);


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_profession__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.dim_profession__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.dim_profession__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.dim_profession__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.dim_profession__candidate
WHERE profession_key IS NULL OR profession_code IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_profession__candidate GROUP BY profession_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_profession__candidate
  GROUP BY profession_code HAVING count(*) > 1)
UNION ALL
SELECT 'profession in workforce silver that is not in this list', count(*) FROM (SELECT DISTINCT profession FROM public_health.silver.workforce_headcount_silver) AS s
LEFT ANTI JOIN public_health.test_gold.dim_profession__candidate AS c ON c.profession_code = s.profession
UNION ALL
SELECT 'core clinical professions <> 3', abs(count_if(profession_group = 'core_clinical') - 3) FROM public_health.test_gold.dim_profession__candidate;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.dim_profession__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_profession_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'workforce'                                      AS domain,
       'public_health.test_gold.dim_profession'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.dim_profession__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.dim_profession__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_profession_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_profession was NOT published. ', error_message))
FROM dim_profession_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_profession AS
SELECT * FROM public_health.test_gold.dim_profession__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.dim_profession));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.dim_profession),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_profession_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.dim_profession', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.dim_profession__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.dim_profession__candidate;
DROP TABLE IF EXISTS public_health.test_gold.dim_profession__gates;
DROP TABLE IF EXISTS public_health.test_gold.dim_profession__inputs;

SELECT profession_code, profession_name, profession_group
FROM public_health.test_gold.dim_profession ORDER BY profession_group, profession_code;
