-- ========================================
-- Builds public_health.test_gold2.fact_disease_metric
--   One row is: one metric of one disease, area, period and age group from one source
--   Primary key: fact_disease_metric_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (disease_key, area_key, date_key, data_source_key, age_group, metric_name, metric_basis)
-- Data model v2 (combined, 14 Oct 2026): 5 dimensions, 4 facts, built from the v1 files.
-- Replaces: gold_34_fact_disease_metric.sql, gold_35_fact_registered_death_by_age.sql, gold_32_dim_age_group.sql
--
-- Write-audit-publish, as in v1: [1] inputs with their build and latest silver QC status,
-- [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish, [6] record in
-- quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.diseases_metric_silver
--   public_health.silver.diseases_source_coverage_silver
--   public_health.silver.diseases_deaths_age_silver
--   public_health.test_gold2.dim_disease
--   public_health.test_gold2.dim_geography
--   public_health.test_gold2.dim_date
--   public_health.test_gold2.dim_data_source
--
-- Change from v1
--   * Registered deaths by age (v1 fact_registered_death_by_age) are UNIONed in as rows with
--     metric_name = 'deaths', metric_definition = 'registered_deaths' and their own age group.
--   * dim_age_group is dropped. age_group (the silver code), age_group_name, age_min and
--     age_max sit on the fact. 'all_ages' is the age group of every diseases_metric_silver row.
--   * period_key -> date_key, source_key -> data_source_key (same hash values).
--   * fact_disease_metric_key keeps the v1 expression, so metric rows keep their v1 key.
-- Rules
--   * One gold row per silver row. Nothing is summed, re-mapped or de-duplicated.
--   * For totals filter age_group = 'all_ages'. The by-age rows of psa_deaths_region_annual
--     add up to a cause total: never add them to an all-ages row.
--   * metric_basis is number: silver holds counts only. Rates are computed in the marts.
--   * value stays null when value_status is not ok. It is never read as 0.
--   * is_complete_year (metric rows only) = the SOURCE holds every period of the year
--     (diseases_source_coverage_silver.is_complete_year) AND THIS AREA holds every period of
--     it (its own distinct periods >= the periods the source holds that year, periods_present;
--     not the nominal 52, because dated weeks straddle 31 December and a contiguous year can
--     hold 51 or 53). The second test was added 2026-10-14
--     for HDX dengue, whose provinces cover different week ranges: the source can have a full
--     2018 while one province has 40 weeks of it. Annual totals filter is_complete_year = true;
--     peaks and weekly series do not need it. It is null on the by-age rows, and so are
--     coverage_basis and is_preliminary (v1 did not carry them for deaths by age).
--   * The preferred source per measure comes from source_priority. Pick the source
--     explicitly in every query until then.
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
CREATE OR REPLACE TABLE public_health.test_gold2.fact_disease_metric__inputs AS
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
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_deaths_age_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_deaths_age_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold2.dim_disease' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold2.dim_disease
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold2.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold2.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold2.dim_date' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold2.dim_date
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold2.dim_data_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold2.dim_data_source
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_disease_metric_rows AS
SELECT 'metric'                                   AS row_source,
       m.disease_key                              AS disease_code,
       m.area_key                                 AS area_code,
       m.period_basis,
       m.period_key                               AS period_label,
       m._source_key,
       m.age_scope                                AS age_group,
       CAST(NULL AS SMALLINT)                     AS age_min,
       CAST(NULL AS SMALLINT)                     AS age_max,
       m.measure                                  AS metric_name,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value AS DECIMAL(20, 4)) END       AS value,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value_lower AS DECIMAL(20, 4)) END AS value_lower,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value_upper AS DECIMAL(20, 4)) END AS value_upper,
       m.value_status,
       m.measure_definition                       AS metric_definition,
       m.geo_coverage_basis                       AS coverage_basis,
       CASE WHEN m.period_grain = 'year' THEN c.is_complete_year
            ELSE c.is_complete_year AND ap.area_periods >= c.periods_present END AS is_complete_year,
       m.is_preliminary
FROM public_health.silver.diseases_metric_silver AS m
LEFT JOIN public_health.silver.diseases_source_coverage_silver AS c
  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
 AND c.period_grain = m.period_grain AND c.year = m.year
LEFT JOIN (
  -- periods this area holds in this year, per source and grain
  SELECT _source_key, area_key, period_grain, year, count(DISTINCT period_key) AS area_periods
  FROM public_health.silver.diseases_metric_silver
  GROUP BY _source_key, area_key, period_grain, year
) AS ap
  ON ap._source_key = m._source_key AND ap.area_key = m.area_key
 AND ap.period_grain = m.period_grain AND ap.year = m.year
UNION ALL
SELECT 'deaths_by_age',
       d.disease_key,
       d.area_key,
       'calendar_year',
       CAST(d.year AS STRING),
       d._source_key,
       d.age_group,
       CAST(d.age_from AS SMALLINT),
       CAST(d.age_to AS SMALLINT),
       'deaths',
       CASE WHEN d.value_status = 'ok' THEN CAST(d.deaths AS DECIMAL(20, 4)) END,
       CAST(NULL AS DECIMAL(20, 4)),
       CAST(NULL AS DECIMAL(20, 4)),
       d.value_status,
       'registered_deaths',
       CAST(NULL AS STRING),
       CAST(NULL AS BOOLEAN),
       CAST(NULL AS BOOLEAN)
FROM public_health.silver.diseases_deaths_age_silver AS d;

CREATE OR REPLACE TABLE public_health.test_gold2.fact_disease_metric__candidate AS
SELECT xxhash64(disease_code, area_code, period_basis, period_label, _source_key, age_group, metric_name)
                                                  AS fact_disease_metric_key,
       xxhash64(disease_code)                     AS disease_key,
       xxhash64(area_code)                        AS area_key,
       xxhash64(period_basis, period_label)       AS date_key,
       xxhash64(_source_key)                      AS data_source_key,
       age_group,
       CASE age_group WHEN 'all_ages' THEN 'All ages' WHEN 'under_1' THEN 'Under 1'
                      WHEN '85_over' THEN '85 and over' WHEN 'not_stated' THEN 'Not stated'
                      ELSE replace(age_group, '_', ' to ') END AS age_group_name,
       age_min,
       age_max,
       metric_name,
       'number'                                   AS metric_basis,
       value,
       value_lower,
       value_upper,
       value_status,
       metric_definition,
       coverage_basis,
       is_complete_year,
       is_preliminary,
       gold_build_id                              AS _gold_build_id
FROM fact_disease_metric_rows;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold2.fact_disease_metric__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold2.fact_disease_metric__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold2.fact_disease_metric__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold2.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold2.fact_disease_metric__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold2.fact_disease_metric__candidate
WHERE fact_disease_metric_key IS NULL OR disease_key IS NULL OR area_key IS NULL OR date_key IS NULL OR data_source_key IS NULL OR age_group IS NULL OR metric_name IS NULL OR metric_basis IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold2.fact_disease_metric__candidate GROUP BY fact_disease_metric_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold2.fact_disease_metric__candidate
  GROUP BY disease_key, area_key, date_key, data_source_key, age_group, metric_name, metric_basis HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> diseases_metric_silver rows + diseases_deaths_age_silver rows',
       abs((SELECT count(*) FROM public_health.test_gold2.fact_disease_metric__candidate)
           - (SELECT count(*) FROM public_health.silver.diseases_metric_silver)
           - (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver))
UNION ALL
SELECT 'sum of values <> silver sum of ok values (both inputs)',
       CAST(ceil(abs(coalesce((SELECT sum(value) FROM public_health.test_gold2.fact_disease_metric__candidate), 0)
         - coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN value END) FROM public_health.silver.diseases_metric_silver), 0)
         - coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN deaths END) FROM public_health.silver.diseases_deaths_age_silver), 0))) AS BIGINT)
UNION ALL
SELECT 'value filled without status ok, or null with status ok', count(*) FROM public_health.test_gold2.fact_disease_metric__candidate WHERE (value IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'value outside its bounds on a modelled row (value_lower <= value <= value_upper)', count(*) FROM public_health.test_gold2.fact_disease_metric__candidate WHERE value < value_lower OR value > value_upper
UNION ALL
SELECT 'bounds on a source that is not modelled', count(*) FROM public_health.test_gold2.fact_disease_metric__candidate AS c
INNER JOIN public_health.test_gold2.dim_data_source AS s ON s.data_source_key = c.data_source_key
WHERE s.value_type <> 'modelled' AND (c.value_lower IS NOT NULL OR c.value_upper IS NOT NULL)
UNION ALL
SELECT 'metric row without a coverage row in diseases_source_coverage_silver', count(*) FROM public_health.silver.diseases_metric_silver AS m
LEFT ANTI JOIN public_health.silver.diseases_source_coverage_silver AS c
  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
 AND c.period_grain = m.period_grain AND c.year = m.year
UNION ALL
SELECT 'metric row with is_complete_year null (coverage row missing periods_expected?)', count(*)
FROM fact_disease_metric_rows WHERE row_source = 'metric' AND is_complete_year IS NULL
UNION ALL
SELECT 'deaths by age: cause, area and year without exactly 20 age groups', count(*) FROM (
  SELECT 1 FROM fact_disease_metric_rows WHERE row_source = 'deaths_by_age'
  GROUP BY disease_code, area_code, period_label, _source_key HAVING count(*) <> 20)
UNION ALL
SELECT 'by-age row with age group all_ages, or metric row with a specific age group', count(*) FROM fact_disease_metric_rows
WHERE (row_source = 'deaths_by_age' AND age_group = 'all_ages')
   OR (row_source = 'metric' AND age_group <> 'all_ages')
UNION ALL
SELECT 'age_min above age_max', count(*) FROM public_health.test_gold2.fact_disease_metric__candidate WHERE age_min > age_max
UNION ALL
SELECT 'disease_key not in dim_disease', count(*) FROM (
  SELECT DISTINCT disease_key AS k FROM public_health.test_gold2.fact_disease_metric__candidate WHERE disease_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold2.dim_disease AS d ON d.disease_key = c.k
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold2.fact_disease_metric__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold2.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'date_key not in dim_date', count(*) FROM (
  SELECT DISTINCT date_key AS k FROM public_health.test_gold2.fact_disease_metric__candidate WHERE date_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold2.dim_date AS d ON d.date_key = c.k
UNION ALL
SELECT 'data_source_key not in dim_data_source', count(*) FROM (
  SELECT DISTINCT data_source_key AS k FROM public_health.test_gold2.fact_disease_metric__candidate WHERE data_source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold2.dim_data_source AS d ON d.data_source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold2.fact_disease_metric__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_disease_metric_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'diseases'                                      AS domain,
       'public_health.test_gold2.fact_disease_metric'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v2', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold2.fact_disease_metric__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold2.fact_disease_metric__inputs) AS q;

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
CREATE OR REPLACE TABLE public_health.test_gold2.fact_disease_metric AS
SELECT * FROM public_health.test_gold2.fact_disease_metric__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold2.fact_disease_metric));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold2.fact_disease_metric),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_disease_metric_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold2.fact_disease_metric', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold2.fact_disease_metric__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold2.fact_disease_metric__candidate;
DROP TABLE IF EXISTS public_health.test_gold2.fact_disease_metric__gates;
DROP TABLE IF EXISTS public_health.test_gold2.fact_disease_metric__inputs;

-- Databricks 2026-10-14: 131,887 metric rows and 90,480 by-age rows. Before the per-area change,
-- hdx_dengue showed completeness_unknown = 32,701 (both measures); expect 0 after silver 04 rerun.
SELECT s.source_dataset, s.value_type, f.metric_name, f.age_group = 'all_ages' AS is_all_ages,
       count(*) AS row_count, count_if(f.value_status <> 'ok') AS not_ok,
       count_if(f.is_complete_year IS NULL) AS completeness_unknown
FROM public_health.test_gold2.fact_disease_metric AS f
INNER JOIN public_health.test_gold2.dim_data_source AS s ON s.data_source_key = f.data_source_key
GROUP BY s.source_dataset, s.value_type, f.metric_name, f.age_group = 'all_ages'
ORDER BY s.source_dataset, f.metric_name;