-- ========================================
-- Builds public_health.test_gold.fact_poverty
--   One row is: poverty estimate of one area and year (PSA full-year estimates among the population)
--   Primary key: fact_poverty_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, period_key, source_key)

-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.socioeconomic_poverty_silver
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_source
--   public_health.test_gold.fact_population
--
-- v3.1 columns: fact_poverty_key, area_key, period_key, source_key, poverty_incidence_pct,
--   poor_population, comparison_eligible.
-- Extra columns (proposed additions)
--   * exclusion_reason: why an area is not comparison eligible (21 of 108 areas today).
--   * coverage_basis: province, province_incl_huc, ncr_district ... what the estimate covers.
--   * incidence_precision (ok, use_with_caution, unknown): PSA flags estimates with a CV above
--     10. Show the label, do not hide the row.
-- Rules
--   * One gold row per silver row. Nothing is re-parsed or re-classified.
--   * Rows with comparison_eligible = false are KEPT. Do not compare them with PSGC-based
--     population or facilities as they are.
--   * poverty_incidence_pct is a published percentage. It is never summed or averaged.
--   * A published 0.0 can mean below 0.05 (silver flag is_incidence_below_0_05, not carried).
--     The summary counts those rows.
--   * hist:maguindanao has 2023 and 2025 values beside its two successor provinces. Leave it
--     out of province sums.
-- Silver QC gate: a silver input whose latest QC has a FAIL stops this build. The build log
-- records the approval state (parameters.approval): provisional while an input has no QC run
-- or has WARN findings to review (proposal section 7).
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
CREATE OR REPLACE TABLE public_health.test_gold.fact_poverty__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.socioeconomic_poverty_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.socioeconomic_poverty_silver
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
CREATE OR REPLACE TABLE public_health.test_gold.fact_poverty__candidate AS
SELECT xxhash64(p.area_key, CAST(p.year AS STRING), p._source_key) AS fact_poverty_key,
       xxhash64(p.area_key)                       AS area_key,
       xxhash64('calendar_year', CAST(p.year AS STRING)) AS period_key,
       xxhash64(p._source_key)                    AS source_key,
       CAST(p.poverty_incidence_pct AS DECIMAL(5, 1)) AS poverty_incidence_pct,
       CAST(p.poor_population AS BIGINT)          AS poor_population,
       p.comparison_eligible,
       p.exclusion_reason,                        -- extra
       p.geo_coverage_basis                       AS coverage_basis,        -- extra
       p.incidence_precision,                     -- extra
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.socioeconomic_poverty_silver AS p;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_poverty__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_poverty__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_poverty__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_poverty__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_poverty__candidate
WHERE fact_poverty_key IS NULL OR area_key IS NULL OR period_key IS NULL OR source_key IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_poverty__candidate GROUP BY fact_poverty_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_poverty__candidate
  GROUP BY area_key, period_key, source_key HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> socioeconomic_poverty_silver rows', abs((SELECT count(*) FROM public_health.test_gold.fact_poverty__candidate) - count(*)) FROM public_health.silver.socioeconomic_poverty_silver
UNION ALL
SELECT 'incidence outside 0 to 100', count(*) FROM public_health.test_gold.fact_poverty__candidate WHERE poverty_incidence_pct NOT BETWEEN 0 AND 100
UNION ALL
SELECT 'row that is not comparison eligible and has no exclusion_reason', count(*) FROM public_health.test_gold.fact_poverty__candidate WHERE NOT comparison_eligible AND exclusion_reason IS NULL
UNION ALL
SELECT 'comparison_eligible is null', count(*) FROM public_health.test_gold.fact_poverty__candidate WHERE comparison_eligible IS NULL
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_poverty__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_poverty__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_poverty__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_poverty__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_poverty_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'socioeconomic'                                      AS domain,
       'public_health.test_gold.fact_poverty'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_poverty__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_poverty__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_poverty_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_poverty was NOT published. ', error_message))
FROM fact_poverty_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_poverty AS
SELECT * FROM public_health.test_gold.fact_poverty__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_poverty));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_poverty),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_poverty_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_poverty', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_poverty__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_poverty__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_poverty__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_poverty__inputs;

SELECT pr.year, f.coverage_basis, f.comparison_eligible, count(*) AS areas,
       count_if(f.incidence_precision <> 'ok') AS not_precise
FROM public_health.test_gold.fact_poverty AS f
INNER JOIN public_health.test_gold.dim_period AS pr ON pr.period_key = f.period_key
GROUP BY pr.year, f.coverage_basis, f.comparison_eligible ORDER BY pr.year, f.coverage_basis;

-- Phase 3 proof: one poverty comparison on matching coverage. Comparison-eligible provinces,
-- latest poverty year, with the census population of the nearest year within 2 years.
SELECT pr.year AS poverty_year, pp.year AS population_year, count(*) AS provinces,
       round(avg(abs(pr.year - pp.year)), 1) AS years_apart,
       sum(f.poor_population) AS poor_population, sum(pop.population) AS census_population
FROM public_health.test_gold.fact_poverty AS f
INNER JOIN public_health.test_gold.dim_period AS pr ON pr.period_key = f.period_key
INNER JOIN public_health.test_gold.dim_geography AS g ON g.area_key = f.area_key AND g.geographic_level = 'province'
INNER JOIN public_health.test_gold.fact_population AS pop
  ON pop.area_key = f.area_key AND pop.population_type = 'census' AND pop.value_status = 'ok'
INNER JOIN public_health.test_gold.dim_period AS pp ON pp.period_key = pop.period_key
WHERE f.comparison_eligible AND pr.year = 2025 AND pp.year = 2024
GROUP BY pr.year, pp.year;
