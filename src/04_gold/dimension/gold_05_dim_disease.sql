-- ========================================
-- Builds public_health.gold.dim_disease
--   One row is: one disease or cause
--   Primary key: disease_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Natural key: (disease_code)
--
-- Reads
--   public_health.silver.diseases_directory_silver
--   public_health.silver.diseases_cause_aggregation
--
-- columns: disease_key, disease_code, disease_name, disease_group, cause_group.
-- Extra columns:
--   * classification (psa_tabulation_list, ihme_gbd, programme, phic_case_rate_package): PSA,
--     IHME, programme causes and PhilHealth case-rate packages are different lists and are
--     never summed together. phic_case_rate_package added 2026-10-14 (14 packages from the
--     claims file; related_condition_group links them to the other lists).
--   * cause_level, parent_disease_key: a cause is never summed with its children (N1 shares).
--   * is_focus_disease: the selected diseases of N2 and the case studies.
-- Rules
--   * disease_code is disease_key of diseases_directory_silver. disease_key is its hash.
--   * disease_group is related_condition_group, the reviewed group that links one condition
--     across lists (tuberculosis, dengue, stroke, chronic_kidney_disease ...).
--   * cause_group is the death composition category of diseases_cause_aggregation
--     (communicable, noncommunicable, injury ...). A PSA cause takes the category of its
--     chapter. IHME and programme causes have none.
--   * cause_level is spelled out: 0 all_causes, 1 group, 2 cause, 3 sub_cause.
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
CREATE OR REPLACE TABLE public_health.gold.dim_disease__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_directory_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_directory_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_cause_aggregation' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_cause_aggregation
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_disease_src AS
SELECT trim(disease_key)                          AS disease_code,
       trim(disease_name)                         AS disease_name,
       nullif(trim(related_condition_group), '')  AS disease_group,
       nullif(trim(classification), '')           AS classification,
       CASE trim(cause_level) WHEN '0' THEN 'all_causes' WHEN '1' THEN 'group'
                              WHEN '2' THEN 'cause' WHEN '3' THEN 'sub_cause' END AS cause_level,
       nullif(trim(parent_disease_key), '')       AS parent_code,
       coalesce(lower(trim(is_focus_disease)) = 'true', false) AS is_focus_disease
FROM public_health.silver.diseases_directory_silver;

CREATE OR REPLACE TEMP VIEW dim_disease_category AS
SELECT trim(disease_key) AS disease_code, max(trim(category)) AS category
FROM public_health.silver.diseases_cause_aggregation GROUP BY trim(disease_key);

CREATE OR REPLACE TABLE public_health.gold.dim_disease__candidate AS
SELECT xxhash64(d.disease_code)                   AS disease_key,
       d.disease_code,
       d.disease_name,
       d.disease_group,
       coalesce(a0.category, a1.category, a2.category) AS cause_group,
       d.classification,
       d.cause_level,
       nvl2(d.parent_code, xxhash64(d.parent_code), NULL) AS parent_disease_key,
       d.is_focus_disease,
       gold_build_id                              AS _gold_build_id
FROM dim_disease_src AS d
LEFT JOIN dim_disease_category AS a0 ON a0.disease_code = d.disease_code
LEFT JOIN dim_disease_src AS p1 ON p1.disease_code = d.parent_code
LEFT JOIN dim_disease_category AS a1 ON a1.disease_code = p1.disease_code
LEFT JOIN dim_disease_category AS a2 ON a2.disease_code = p1.parent_code;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_disease__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.dim_disease__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.dim_disease__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.dim_disease__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.dim_disease__candidate
WHERE disease_key IS NULL OR disease_code IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_disease__candidate GROUP BY disease_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_disease__candidate
  GROUP BY disease_code HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> directory rows', abs((SELECT count(*) FROM public_health.gold.dim_disease__candidate) - count(*)) FROM public_health.silver.diseases_directory_silver
UNION ALL
SELECT 'disease_name or classification missing', count(*) FROM public_health.gold.dim_disease__candidate WHERE disease_name IS NULL OR classification IS NULL
UNION ALL
SELECT 'classification outside the four known lists', count(*) FROM public_health.gold.dim_disease__candidate WHERE classification NOT IN ('psa_tabulation_list', 'ihme_gbd', 'programme', 'phic_case_rate_package')
UNION ALL
SELECT 'parent_disease_key not in the candidate', count(*) FROM public_health.gold.dim_disease__candidate AS c LEFT ANTI JOIN public_health.gold.dim_disease__candidate AS d ON d.disease_key = c.parent_disease_key
WHERE c.parent_disease_key IS NOT NULL;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.dim_disease__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_disease_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'diseases'                                      AS domain,
       'public_health.gold.dim_disease'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v2', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.dim_disease__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.dim_disease__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_disease_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_disease was NOT published. ', error_message))
FROM dim_disease_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_disease AS
SELECT * FROM public_health.gold.dim_disease__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.dim_disease));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.dim_disease),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_disease_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.dim_disease', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.dim_disease__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.gold.dim_disease__candidate;
DROP TABLE IF EXISTS public_health.gold.dim_disease__gates;
DROP TABLE IF EXISTS public_health.gold.dim_disease__inputs;

-- Expected: 179 rows (psa_tabulation_list 116, ihme_gbd 46, programme 3, phic_case_rate_package 14).
SELECT classification, count(*) AS diseases, count_if(is_focus_disease) AS focus_diseases,
       count_if(cause_group IS NOT NULL) AS with_cause_group, count(DISTINCT disease_group) AS disease_groups
FROM public_health.gold.dim_disease GROUP BY classification ORDER BY classification;

SELECT disease_code, disease_name, disease_group, is_focus_disease
FROM public_health.gold.dim_disease WHERE disease_code = 'ihme_589';