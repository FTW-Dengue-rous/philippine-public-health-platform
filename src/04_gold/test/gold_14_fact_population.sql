-- ========================================
-- Builds public_health.test_gold.fact_population
--   One row is: population of one area, period and source
--   Primary key: fact_population_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, period_key, source_key)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.population_silver
--   public_health.silver.workforce_area_denominator_silver
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_source
--
-- v3.1 columns: fact_population_key, area_key, period_key, source_key, population,
--   coverage_basis, population_type.
-- Extra column (proposed addition)
--   * value_status: says why population is null (missing, invalid, zero_no_data,
--     label_under_review ...). Null is not zero, and the reason must stay visible.
-- Rules
--   * Two sources, never summed: census counts from population_silver (source psa_psgc,
--     population_type census) and the population printed in the FHSIS tables
--     (workforce_area_denominator_silver, source doh_fhsis_demographic, type reported).
--   * Census rows are kept for areas in dim_geography. Barangay rows are left out.
--   * population is filled only when silver says the value is good: VALID and VALID_WITH_NOTE
--     become ok. FHSIS statuses are kept as they are. An FHSIS area whose label override is
--     still proposed or rejected gets label_under_review and a null population.
--   * coverage_basis for census provinces: province_excl_huc in 2024 (stated in the docs).
--     2015 and 2020 are province_coverage_unconfirmed until someone checks them.
--   * Gold never interpolates between census years. The 2-year alignment window is applied
--     in the marts, which record the population year they used.
--   * Census and FHSIS population are kept side by side. Silver check S99 compares them
--     (10 percent tolerance, regions, cities and municipalities). Provinces differ by design:
--     census provinces exclude HUCs, FHSIS provinces exclude their listed cities.
-- Column names are the ones psgc_population_silver_qc.py checks (2026-10-12): psgc_code,
-- population_year, population, population_parse_status, content_checksum, silver_processed_at.
-- The table grain is area x year x source_version: only the latest snapshot is read.
-- population_silver has no national row. A national census total is the sum of the regions.
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
CREATE OR REPLACE TABLE public_health.test_gold.fact_population__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.population_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.population_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.workforce_area_denominator_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.workforce_area_denominator_silver
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
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
-- The only place that names population_silver columns. Latest snapshot only.
CREATE OR REPLACE TEMP VIEW fact_population_census_src AS
SELECT psgc_code,
       CAST(population_year AS INT)               AS year,
       CAST(population AS BIGINT)                 AS population,
       upper(trim(population_parse_status))       AS silver_status
FROM public_health.silver.population_silver
WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at)
                          FROM public_health.silver.population_silver);

CREATE OR REPLACE TEMP VIEW fact_population_rows AS
SELECT g.area_key,
       xxhash64('calendar_year', CAST(s.year AS STRING)) AS period_key,
       xxhash64('psa_psgc')                       AS source_key,
       CASE WHEN s.silver_status IN ('VALID', 'VALID_WITH_NOTE') THEN s.population END AS population,
       CASE WHEN g.geographic_level = 'province' AND s.year = 2024 THEN 'province_excl_huc'
            WHEN g.geographic_level = 'province' THEN 'province_coverage_unconfirmed'
            ELSE g.geographic_level END           AS coverage_basis,
       'census'                                   AS population_type,
       CASE WHEN s.silver_status IN ('VALID', 'VALID_WITH_NOTE') THEN 'ok'
            ELSE coalesce(lower(s.silver_status), 'missing') END AS value_status
FROM fact_population_census_src AS s
INNER JOIN public_health.test_gold.dim_geography AS g ON g.psgc_code = s.psgc_code
UNION ALL
SELECT xxhash64(d.area_key),
       xxhash64('calendar_year', CAST(d.year AS STRING)),
       xxhash64(d._source_key),
       CASE WHEN d.population_status = 'ok' AND NOT coalesce(d.area_label_override_status IN ('proposed', 'rejected'), false)
            THEN CAST(round(d.reported_population) AS BIGINT) END,
       d.geo_coverage_basis,
       'reported',
       CASE WHEN d.area_label_override_status IN ('proposed', 'rejected') THEN 'label_under_review'
            ELSE d.population_status END
FROM public_health.silver.workforce_area_denominator_silver AS d;

CREATE OR REPLACE TABLE public_health.test_gold.fact_population__candidate AS
SELECT xxhash64(area_key, period_key, source_key) AS fact_population_key,
       area_key,
       period_key,
       source_key,
       population,
       coverage_basis,
       population_type,
       value_status,                              -- extra
       gold_build_id                              AS _gold_build_id
FROM fact_population_rows;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_population__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_population__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_population__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_population__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_population__candidate
WHERE fact_population_key IS NULL OR area_key IS NULL OR period_key IS NULL OR source_key IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_population__candidate GROUP BY fact_population_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_population__candidate
  GROUP BY area_key, period_key, source_key HAVING count(*) > 1)
UNION ALL
SELECT 'population filled without status ok, or null with status ok', count(*) FROM public_health.test_gold.fact_population__candidate WHERE (population IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'negative population', count(*) FROM public_health.test_gold.fact_population__candidate WHERE population < 0
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_population__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_population__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_population__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k
UNION ALL
SELECT 'census rows <> population_silver rows of the areas in dim_geography', abs((SELECT count(*) FROM public_health.test_gold.fact_population__candidate WHERE population_type = 'census') - count(*))
FROM fact_population_census_src AS s
LEFT SEMI JOIN public_health.test_gold.dim_geography AS g ON g.psgc_code = s.psgc_code
UNION ALL
SELECT 'reported rows <> workforce_area_denominator_silver rows', abs((SELECT count(*) FROM public_health.test_gold.fact_population__candidate WHERE population_type = 'reported') - count(*))
FROM public_health.silver.workforce_area_denominator_silver
UNION ALL
SELECT 'census population total <> silver total for the areas in dim_geography (phase 1 proof)', CAST(abs(coalesce((SELECT sum(population) FROM public_health.test_gold.fact_population__candidate WHERE population_type = 'census'), 0)
         - coalesce(sum(CASE WHEN s.silver_status IN ('VALID', 'VALID_WITH_NOTE') THEN s.population END), 0)) AS BIGINT)
FROM fact_population_census_src AS s
LEFT SEMI JOIN public_health.test_gold.dim_geography AS g ON g.psgc_code = s.psgc_code;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_population__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_population_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'population'                                      AS domain,
       'public_health.test_gold.fact_population'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_population__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_population__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_population_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_population was NOT published. ', error_message))
FROM fact_population_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_population AS
SELECT * FROM public_health.test_gold.fact_population__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_population));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_population),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_population_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_population', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_population__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_population__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_population__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_population__inputs;

-- Phase 1 proof: totals per type and year. Known gaps: the Negros Island Region has no 2015
-- or 2020 census rows, and Sulu has no 2024 rows.
SELECT f.population_type, p.year, f.value_status, count(*) AS areas, sum(f.population) AS population
FROM public_health.test_gold.fact_population AS f
INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key
GROUP BY f.population_type, p.year, f.value_status
ORDER BY f.population_type, p.year, f.value_status;
