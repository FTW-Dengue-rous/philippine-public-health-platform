-- ========================================
-- Builds public_health.test_gold.fact_disease_metric
--   One row is: one metric of one disease, area, period, age group and source
--   Primary key: fact_disease_metric_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (disease_key, area_key, period_key, source_key, age_group_key, metric_name, metric_basis)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.diseases_metric_silver
--   public_health.silver.diseases_source_coverage_silver
--   public_health.test_gold.dim_disease
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_source
--   public_health.test_gold.dim_age_group
--
-- v3.1 columns: fact_disease_metric_key, disease_key, area_key, period_key, source_key,
--   age_group_key, metric_name, metric_basis, value, value_lower, value_upper.
-- Extra columns (proposed additions)
--   * value_status (ok, missing, no_report, not_applicable): why a value is null.
--   * metric_definition (registered_deaths, notified_tb_cases_all_forms ...): two metrics with
--     the same name can measure different things and must not share a chart unlabelled.
--   * coverage_basis: what the area covers (Regions VI and VII before and after the Negros
--     Island Region).
--   * is_complete_year, is_preliminary: N3 and D1 pick waves by completeness. Year on year
--     comparisons need to know a partial or preliminary year.
-- Rules
--   * One gold row per silver row. Nothing is summed, re-mapped or de-duplicated.
--   * period_key = xxhash64(period_basis, silver period key), the dim_period key.
--   * age_group_key is the All ages row today (silver age_scope).
--   * metric_basis is number: silver holds counts only. Rates are computed in the marts.
--   * value stays null when value_status is not ok. It is never read as 0.
--   * is_complete_year comes from diseases_source_coverage_silver, joined on source, level,
--     grain and year (unique there, so rows cannot multiply). It describes the source as a
--     whole, not each area.
--   * The preferred source per measure comes from the source_priority seed (phase 1). Until
--     it exists, pick the source explicitly in every query.
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
CREATE OR REPLACE TABLE public_health.test_gold.fact_disease_metric__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_metric_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_metric_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_source_coverage_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_source_coverage_silver
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
CREATE OR REPLACE TABLE public_health.test_gold.fact_disease_metric__candidate AS
SELECT xxhash64(m.disease_key, m.area_key, m.period_basis, m.period_key, m._source_key, m.age_scope, m.measure)
                                                  AS fact_disease_metric_key,
       xxhash64(m.disease_key)                    AS disease_key,
       xxhash64(m.area_key)                       AS area_key,
       xxhash64(m.period_basis, m.period_key)     AS period_key,
       xxhash64(m._source_key)                    AS source_key,
       a.age_group_key,
       m.measure                                  AS metric_name,
       'number'                                   AS metric_basis,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value AS DECIMAL(20, 4)) END       AS value,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value_lower AS DECIMAL(20, 4)) END AS value_lower,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value_upper AS DECIMAL(20, 4)) END AS value_upper,
       m.value_status,                            -- extra
       m.measure_definition                       AS metric_definition,     -- extra
       m.geo_coverage_basis                       AS coverage_basis,        -- extra
       c.is_complete_year,                        -- extra
       m.is_preliminary,                          -- extra
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.diseases_metric_silver AS m
LEFT JOIN public_health.test_gold.dim_age_group AS a ON a.age_group_code = m.age_scope
LEFT JOIN public_health.silver.diseases_source_coverage_silver AS c
  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
 AND c.period_grain = m.period_grain AND c.year = m.year;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_disease_metric__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_disease_metric__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_disease_metric__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_disease_metric__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_disease_metric__candidate
WHERE fact_disease_metric_key IS NULL OR disease_key IS NULL OR area_key IS NULL OR period_key IS NULL OR source_key IS NULL OR age_group_key IS NULL OR metric_name IS NULL OR metric_basis IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_disease_metric__candidate GROUP BY fact_disease_metric_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_disease_metric__candidate
  GROUP BY disease_key, area_key, period_key, source_key, age_group_key, metric_name, metric_basis HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> diseases_metric_silver rows', abs((SELECT count(*) FROM public_health.test_gold.fact_disease_metric__candidate) - count(*)) FROM public_health.silver.diseases_metric_silver
UNION ALL
SELECT 'sum of values <> silver sum of ok values', CAST(ceil(abs(coalesce((SELECT sum(value) FROM public_health.test_gold.fact_disease_metric__candidate), 0) - coalesce(sum(CASE WHEN value_status = 'ok' THEN value END), 0))) AS BIGINT)
FROM public_health.silver.diseases_metric_silver
UNION ALL
SELECT 'value filled without status ok, or null with status ok', count(*) FROM public_health.test_gold.fact_disease_metric__candidate WHERE (value IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'value outside its bounds on a modelled row (value_lower <= value <= value_upper)', count(*) FROM public_health.test_gold.fact_disease_metric__candidate WHERE value < value_lower OR value > value_upper
UNION ALL
SELECT 'bounds on a source that is not modelled', count(*) FROM public_health.test_gold.fact_disease_metric__candidate AS c
INNER JOIN public_health.test_gold.dim_source AS s ON s.source_key = c.source_key
WHERE s.value_type <> 'modelled' AND (c.value_lower IS NOT NULL OR c.value_upper IS NOT NULL)
UNION ALL
SELECT 'row without a coverage row in diseases_source_coverage_silver', count(*) FROM public_health.silver.diseases_metric_silver AS m
LEFT ANTI JOIN public_health.silver.diseases_source_coverage_silver AS c
  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
 AND c.period_grain = m.period_grain AND c.year = m.year
UNION ALL
SELECT 'disease_key not in dim_disease', count(*) FROM (
  SELECT DISTINCT disease_key AS k FROM public_health.test_gold.fact_disease_metric__candidate WHERE disease_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_disease AS d ON d.disease_key = c.k
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_disease_metric__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_disease_metric__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_disease_metric__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_disease_metric__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_disease_metric_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'diseases'                                      AS domain,
       'public_health.test_gold.fact_disease_metric'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_disease_metric__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_disease_metric__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_disease_metric_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_disease_metric was NOT published. ', error_message))
FROM fact_disease_metric_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_disease_metric AS
SELECT * FROM public_health.test_gold.fact_disease_metric__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_disease_metric));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_disease_metric),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_disease_metric_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_disease_metric', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_disease_metric__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_disease_metric__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_disease_metric__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_disease_metric__inputs;

-- Compare with silver (2026-10-11): 131,887 rows over eight sources.
SELECT s.source_dataset, s.value_type, f.metric_name, count(*) AS row_count,
       count_if(f.value_status <> 'ok') AS not_ok, count_if(f.is_complete_year IS NULL) AS completeness_unknown
FROM public_health.test_gold.fact_disease_metric AS f
INNER JOIN public_health.test_gold.dim_source AS s ON s.source_key = f.source_key
GROUP BY s.source_dataset, s.value_type, f.metric_name ORDER BY s.source_dataset, f.metric_name;
