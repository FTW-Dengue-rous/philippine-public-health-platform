-- ========================================
-- Builds public_health.test_gold.fact_workforce
--   One row is: headcount of one profession in one area and year from one source
--   Primary key: fact_workforce_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, period_key, profession_key, source_key)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.workforce_headcount_silver
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_profession
--   public_health.test_gold.dim_source
--   public_health.test_gold.fact_population
--
-- v3.1 columns: fact_workforce_key, area_key, period_key, profession_key, source_key,
--   headcount_total, headcount_lgu_hired, headcount_doh_hired, analysis_eligible.
-- Extra columns (proposed additions)
--   * exclusion_reason: why a row is not eligible, so the dashboard can say it and not show 0.
--   * source_role (preferred, alternate): PSA and FHSIS overlap for 2018 to 2023. Without it
--     a query double counts. preferred leaves PSA for 2012 to 2017 and FHSIS for 2018 to 2025.
--     The silver value cross_check is written as alternate.
--   * coverage_basis: province coverage changes in 2023 (province_excl_listed_cities to
--     province_excl_huc_icc).
--   * is_break_year: the nurse series changes definition in 2019.
-- Rules
--   * One gold row per silver row. Rows that are not analysis_eligible are KEPT.
--   * Null is not zero. A headcount is filled only when its own silver status is ok. Silver
--     stores a 0 for the 2018 legend "0 = No Data": that becomes null.
--   * analysis_eligible refers to headcount_total. Use it to pick rows for a rate.
--   * Country, region, province, city and municipality rows sit together. Never add a
--     province to its listed cities, or a 2025 province to its municipalities.
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
CREATE OR REPLACE TABLE public_health.test_gold.fact_workforce__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.workforce_headcount_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.workforce_headcount_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_period' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_period
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_profession' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_profession
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_source
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.fact_population' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.fact_population
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_workforce__candidate AS
SELECT xxhash64(h.area_key, CAST(h.year AS STRING), h.profession, h._source_key) AS fact_workforce_key,
       xxhash64(h.area_key)                       AS area_key,
       xxhash64('calendar_year', CAST(h.year AS STRING)) AS period_key,
       xxhash64(h.profession)                     AS profession_key,
       xxhash64(h._source_key)                    AS source_key,
       CASE WHEN h.total_status = 'ok' THEN CAST(h.headcount_total AS BIGINT) END         AS headcount_total,
       CASE WHEN h.lgu_hired_status = 'ok' THEN CAST(h.headcount_lgu_hired AS BIGINT) END AS headcount_lgu_hired,
       CASE WHEN h.doh_hired_status = 'ok' THEN CAST(h.headcount_doh_hired AS BIGINT) END AS headcount_doh_hired,
       h.analysis_eligible,
       h.exclusion_reason,                        -- extra
       CASE h.source_role WHEN 'cross_check' THEN 'alternate' ELSE h.source_role END AS source_role,   -- extra
       h.geo_coverage_basis                       AS coverage_basis,        -- extra
       h.is_break_year,                           -- extra
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.workforce_headcount_silver AS h;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_workforce__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_workforce__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_workforce__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_workforce__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_workforce__candidate
WHERE fact_workforce_key IS NULL OR area_key IS NULL OR period_key IS NULL OR profession_key IS NULL OR source_key IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_workforce__candidate GROUP BY fact_workforce_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_workforce__candidate
  GROUP BY area_key, period_key, profession_key, source_key HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> workforce_headcount_silver rows', abs((SELECT count(*) FROM public_health.test_gold.fact_workforce__candidate) - count(*)) FROM public_health.silver.workforce_headcount_silver
UNION ALL
SELECT 'eligible row without a total', count(*) FROM public_health.test_gold.fact_workforce__candidate WHERE analysis_eligible AND headcount_total IS NULL
UNION ALL
SELECT 'row that is not eligible and has no exclusion_reason', count(*) FROM public_health.test_gold.fact_workforce__candidate WHERE NOT analysis_eligible AND exclusion_reason IS NULL
UNION ALL
SELECT 'source_role outside preferred, alternate', count(*) FROM public_health.test_gold.fact_workforce__candidate WHERE source_role NOT IN ('preferred', 'alternate') OR source_role IS NULL
UNION ALL
SELECT 'more than one preferred source for an area, year and profession', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_workforce__candidate WHERE source_role = 'preferred'
  GROUP BY area_key, period_key, profession_key HAVING count(*) > 1)
UNION ALL
SELECT 'negative headcount', count(*) FROM public_health.test_gold.fact_workforce__candidate WHERE least(headcount_total, headcount_lgu_hired, headcount_doh_hired) < 0
UNION ALL
SELECT 'eligible total <> silver eligible total', CAST(abs(coalesce((SELECT sum(headcount_total) FROM public_health.test_gold.fact_workforce__candidate WHERE analysis_eligible), 0)
         - coalesce(sum(CASE WHEN analysis_eligible THEN headcount_total END), 0)) AS BIGINT)
FROM public_health.silver.workforce_headcount_silver
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_workforce__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_workforce__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'profession_key not in dim_profession', count(*) FROM (
  SELECT DISTINCT profession_key AS k FROM public_health.test_gold.fact_workforce__candidate WHERE profession_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_profession AS d ON d.profession_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_workforce__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_workforce__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_workforce_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'workforce'                                      AS domain,
       'public_health.test_gold.fact_workforce'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_workforce__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_workforce__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_workforce_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_workforce was NOT published. ', error_message))
FROM fact_workforce_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_workforce AS
SELECT * FROM public_health.test_gold.fact_workforce__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_workforce));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_workforce),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_workforce_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_workforce', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_workforce__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_workforce__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_workforce__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_workforce__inputs;

SELECT s.source_dataset, f.source_role, min(p.year) AS first_year, max(p.year) AS last_year,
       count(*) AS row_count, count_if(f.analysis_eligible) AS eligible_rows
FROM public_health.test_gold.fact_workforce AS f
INNER JOIN public_health.test_gold.dim_source AS s ON s.source_key = f.source_key
INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key
GROUP BY s.source_dataset, f.source_role ORDER BY s.source_dataset, f.source_role;

-- Phase 3 proof: one workforce rate on matching coverage. National doctors per 10,000 on
-- the FHSIS population of the same year. Numerator, denominator and both years are kept.
SELECT p.year AS workforce_year, p.year AS population_year, f.headcount_total AS doctors,
       pop.population, round(f.headcount_total / pop.population * 10000, 2) AS doctors_per_10k
FROM public_health.test_gold.fact_workforce AS f
INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key
INNER JOIN public_health.test_gold.fact_population AS pop
  ON pop.area_key = f.area_key AND pop.period_key = f.period_key AND pop.population_type = 'reported'
WHERE f.area_key = xxhash64('ph') AND f.profession_key = xxhash64('doctors')
  AND f.analysis_eligible AND f.source_role = 'preferred' AND pop.population > 0
ORDER BY p.year;