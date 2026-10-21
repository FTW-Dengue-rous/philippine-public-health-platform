-- ========================================
-- Builds public_health.test_gold.fact_registered_death_by_age
--   One row is: registered deaths of one cause, area, period and age group from one source
--   Primary key: fact_registered_death_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, period_key, disease_key, age_group_key, source_key)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.diseases_deaths_age_silver
--   public_health.test_gold.dim_disease
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_source
--   public_health.test_gold.dim_age_group
--
-- v3.1 columns: fact_registered_death_key, area_key, period_key, disease_key, age_group_key,
--   source_key, registered_death_count.
-- Extra column (proposed addition)
--   * value_status (ok, missing): a blank cell in the source is null here, not 0.
-- Rules
--   * One gold row per silver row. registered_death_count stays null when the status is not ok.
--   * The table holds every cause level, and the ph and foreign rows beside the regions. Never
--     sum a cause with its children, and leave ph and foreign out of regional sums.
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
CREATE OR REPLACE TABLE public_health.test_gold.fact_registered_death_by_age__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_deaths_age_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_deaths_age_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_disease' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_disease
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_period' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_period
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_source
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_age_group' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_age_group
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_registered_death_by_age__candidate AS
SELECT xxhash64(d.area_key, CAST(d.year AS STRING), d.disease_key, d.age_group, d._source_key)
                                                  AS fact_registered_death_key,
       xxhash64(d.area_key)                       AS area_key,
       xxhash64('calendar_year', CAST(d.year AS STRING)) AS period_key,
       xxhash64(d.disease_key)                    AS disease_key,
       a.age_group_key,
       xxhash64(d._source_key)                    AS source_key,
       CASE WHEN d.value_status = 'ok' THEN CAST(d.deaths AS BIGINT) END AS registered_death_count,
       d.value_status,                            -- extra
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.diseases_deaths_age_silver AS d
LEFT JOIN public_health.test_gold.dim_age_group AS a ON a.age_group_code = d.age_group;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_registered_death_by_age__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_registered_death_by_age__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_registered_death_by_age__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_registered_death_by_age__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_registered_death_by_age__candidate
WHERE fact_registered_death_key IS NULL OR area_key IS NULL OR period_key IS NULL OR disease_key IS NULL OR age_group_key IS NULL OR source_key IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_registered_death_by_age__candidate GROUP BY fact_registered_death_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_registered_death_by_age__candidate
  GROUP BY area_key, period_key, disease_key, age_group_key, source_key HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> diseases_deaths_age_silver rows', abs((SELECT count(*) FROM public_health.test_gold.fact_registered_death_by_age__candidate) - count(*)) FROM public_health.silver.diseases_deaths_age_silver
UNION ALL
SELECT 'sum of deaths <> silver sum of ok values', CAST(abs(coalesce((SELECT sum(registered_death_count) FROM public_health.test_gold.fact_registered_death_by_age__candidate), 0) - coalesce(sum(CASE WHEN value_status = 'ok' THEN deaths END), 0)) AS BIGINT)
FROM public_health.silver.diseases_deaths_age_silver
UNION ALL
SELECT 'count filled without status ok, or null with status ok', count(*) FROM public_health.test_gold.fact_registered_death_by_age__candidate WHERE (registered_death_count IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'cause, area and period without exactly 20 age groups', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_registered_death_by_age__candidate
  GROUP BY disease_key, area_key, period_key, source_key HAVING count(*) <> 20)
UNION ALL
SELECT 'disease_key not in dim_disease', count(*) FROM (
  SELECT DISTINCT disease_key AS k FROM public_health.test_gold.fact_registered_death_by_age__candidate WHERE disease_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_disease AS d ON d.disease_key = c.k
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_registered_death_by_age__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_registered_death_by_age__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_registered_death_by_age__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_registered_death_by_age__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_registered_death_by_age_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'diseases'                                      AS domain,
       'public_health.test_gold.fact_registered_death_by_age'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_registered_death_by_age__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_registered_death_by_age__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_registered_death_by_age_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_registered_death_by_age was NOT published. ', error_message))
FROM fact_registered_death_by_age_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_registered_death_by_age AS
SELECT * FROM public_health.test_gold.fact_registered_death_by_age__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_registered_death_by_age));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_registered_death_by_age),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_registered_death_by_age_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_registered_death_by_age', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_registered_death_by_age__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_registered_death_by_age__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_registered_death_by_age__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_registered_death_by_age__inputs;

SELECT p.year, count(*) AS row_count, count(DISTINCT f.area_key) AS areas,
       count(DISTINCT f.disease_key) AS causes, count_if(f.value_status <> 'ok') AS not_ok
FROM public_health.test_gold.fact_registered_death_by_age AS f
INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key
GROUP BY p.year ORDER BY p.year;
