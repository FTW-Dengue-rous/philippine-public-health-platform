-- ========================================
-- Builds public_health.test_gold2.dim_date
--   One row is: one reporting period under one period convention (year, month, week or snapshot date)
--   Primary key: date_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Natural key: (period_basis, period_label)
-- Data model v2 (combined, 14 Oct 2026): 5 dimensions, 4 facts, built from the v1 files.
-- Replaces: gold_12_dim_period.sql (dim_period)
--
-- Write-audit-publish, as in v1: [1] inputs with their build and latest silver QC status,
-- [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish, [6] record in
-- quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.diseases_metric_silver
--   public_health.silver.diseases_deaths_age_silver
--   public_health.silver.population_silver
--   public_health.silver.workforce_headcount_silver
--   public_health.silver.workforce_area_denominator_silver
--   public_health.silver.facilities_metric_silver
--   public_health.silver.facilities_bed_occupancy_silver
--   public_health.silver.facilities_registry_silver
--   public_health.silver.socioeconomic_poverty_silver
--   public_health.silver.socioeconomic_health_expenditure_share_silver
--   public_health.silver.socioeconomic_health_expenditure_per_capita_silver
--
-- Change from v1 (dim_period)
--   * Renamed to dim_date and period_key to date_key (mentor comment: should be dim_date).
--     date_key keeps the v1 hash, xxhash64(period_basis, period_label), so the key values
--     are the same as the v1 period_key values.
--   * Still one row per reporting period, not per day: the sources report by year, month,
--     week or snapshot, and the dashboard shows trends over these periods.
--   * Adds the years of the two health expenditure tables (fact_area_indicator reads them).
-- Rules (as in v1)
--   * Periods come from the silver facts: every period of diseases_metric_silver, every year
--     of the yearly silver tables, and one snapshot date for the facility registry.
--   * The registry snapshot is its latest as-of date (the later of the NHFR and HFSRB dates).
--   * period_basis source_date_unconfirmed: HDX weekly dengue rows whose date meaning (week
--     start or end) is not confirmed. Start and end dates stay null for weekly dengue until
--     the week convention is confirmed.
--   * is_pandemic_period is set by the two variables below (open decision 5).
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
DECLARE OR REPLACE VARIABLE pandemic_year_from INT DEFAULT 2020;   -- open decision 5
DECLARE OR REPLACE VARIABLE pandemic_year_to INT DEFAULT 2022;


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold2.dim_date__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_metric_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_metric_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_deaths_age_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_deaths_age_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.population_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.population_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.workforce_headcount_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.workforce_headcount_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.workforce_area_denominator_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.workforce_area_denominator_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_metric_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_metric_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_bed_occupancy_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_bed_occupancy_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_registry_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_registry_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.socioeconomic_poverty_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.socioeconomic_poverty_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.socioeconomic_health_expenditure_share_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.socioeconomic_health_expenditure_per_capita_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_date_years AS
SELECT CAST(population_year AS INT) AS y FROM public_health.silver.population_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.workforce_headcount_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.workforce_area_denominator_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.facilities_metric_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.facilities_bed_occupancy_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.socioeconomic_poverty_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.diseases_deaths_age_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.socioeconomic_health_expenditure_share_silver
UNION SELECT CAST(year AS INT) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver;

CREATE OR REPLACE TEMP VIEW dim_date_all AS
SELECT DISTINCT period_basis, period_grain, period_key AS period_label, CAST(year AS INT) AS year,
       CAST(month AS INT) AS month, CAST(week AS INT) AS week, period_start, period_end
FROM public_health.silver.diseases_metric_silver
UNION
SELECT 'calendar_year', 'year', CAST(y AS STRING), y, CAST(NULL AS INT), CAST(NULL AS INT),
       make_date(y, 1, 1), make_date(y, 12, 31)
FROM dim_date_years WHERE y IS NOT NULL
UNION
SELECT 'snapshot', 'snapshot', date_format(d, 'yyyy-MM-dd'), year(d), month(d), CAST(NULL AS INT), d, d
FROM (SELECT max(greatest(_nhfr_as_of_date, _hfsrb_as_of_date)) AS d
      FROM public_health.silver.facilities_registry_silver) AS r
WHERE d IS NOT NULL;

CREATE OR REPLACE TABLE public_health.test_gold2.dim_date__candidate AS
SELECT xxhash64(period_basis, period_label)       AS date_key,
       period_basis,
       period_grain,
       period_label,
       CAST(year AS SMALLINT)                     AS year,
       month,
       week,
       period_start                               AS period_start_date,
       period_end                                 AS period_end_date,
       (year BETWEEN pandemic_year_from AND pandemic_year_to) AS is_pandemic_period,
       gold_build_id                              AS _gold_build_id
FROM dim_date_all;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold2.dim_date__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold2.dim_date__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold2.dim_date__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold2.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold2.dim_date__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold2.dim_date__candidate
WHERE date_key IS NULL OR period_basis IS NULL OR period_label IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold2.dim_date__candidate GROUP BY date_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold2.dim_date__candidate
  GROUP BY period_basis, period_label HAVING count(*) > 1)
UNION ALL
SELECT 'period_grain outside year, month, week, snapshot', count(*) FROM public_health.test_gold2.dim_date__candidate WHERE period_grain NOT IN ('year', 'month', 'week', 'snapshot') OR period_grain IS NULL
UNION ALL
SELECT 'period_basis outside the known conventions', count(*) FROM public_health.test_gold2.dim_date__candidate
WHERE period_basis NOT IN ('calendar_year', 'calendar_month', 'week_number_unconfirmed',
                           'source_date_unconfirmed', 'snapshot')
UNION ALL
SELECT 'year missing, month outside 1 to 12 or week outside 1 to 53', count(*) FROM public_health.test_gold2.dim_date__candidate WHERE year IS NULL OR month NOT BETWEEN 1 AND 12 OR week NOT BETWEEN 1 AND 53
UNION ALL
SELECT 'period_start_date after period_end_date', count(*) FROM public_health.test_gold2.dim_date__candidate WHERE period_start_date > period_end_date
UNION ALL
SELECT 'no registry snapshot period', CAST(count_if(period_basis = 'snapshot') = 0 AS INT) FROM public_health.test_gold2.dim_date__candidate;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold2.dim_date__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_date_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'shared'                                      AS domain,
       'public_health.test_gold2.dim_date'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v2', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds, 'pandemic_year_from', pandemic_year_from, 'pandemic_year_to', pandemic_year_to)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold2.dim_date__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold2.dim_date__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_date_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_date was NOT published. ', error_message))
FROM dim_date_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold2.dim_date AS
SELECT * FROM public_health.test_gold2.dim_date__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold2.dim_date));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold2.dim_date),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_date_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold2.dim_date', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold2.dim_date__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold2.dim_date__candidate;
DROP TABLE IF EXISTS public_health.test_gold2.dim_date__gates;
DROP TABLE IF EXISTS public_health.test_gold2.dim_date__inputs;

SELECT period_basis, period_grain, count(*) AS periods, min(year) AS first_year, max(year) AS last_year,
       count_if(period_start_date IS NULL) AS without_dates, min(period_label) AS first_label
FROM public_health.test_gold2.dim_date
GROUP BY period_basis, period_grain ORDER BY period_basis;