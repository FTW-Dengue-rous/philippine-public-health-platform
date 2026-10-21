-- ========================================
-- Builds public_health.gold.dim_date
--   One row is: one reporting period under one period convention (year, month, week or
--   snapshot date)
--   Primary key: date_key = xxhash64(period_basis, period_label). The same period gives the
--                same key on every rebuild.
--   Natural key: (period_basis, period_label)
--
-- Reads
--   public_health.silver.diseases_metric_silver          every period, with its dates (weeks too)
--   public_health.silver.diseases_deaths_age_silver      years
--   public_health.silver.population_silver               census years
--   public_health.silver.workforce_headcount_silver      years
--   public_health.silver.workforce_area_denominator_silver years
--   public_health.silver.facilities_metric_silver        years
--   public_health.silver.facilities_bed_occupancy_silver years
--   public_health.silver.facilities_registry_silver      one snapshot date
--   public_health.silver.socioeconomic_poverty_silver    years
--   public_health.silver.socioeconomic_health_expenditure_share_silver      years
--   public_health.silver.socioeconomic_health_expenditure_per_capita_silver years
--
-- Period conventions (period_basis)
--   calendar_year         1 January to 31 December. period_label = 'yyyy'.
--   calendar_month        one calendar month (DOH FOI dengue).
--   iso_week              UP NOAH: one ISO week, Monday to Sunday. period_label = 'yyyy-Www'.
--                         Not approximated (D-46).
--   iso_week_ending_date  HDX dengue: the date closes its week, which runs from the date minus
--                         6 days to the date (D-44). period_label = the date ('yyyy-MM-dd').
--                         Show it as "week ending <date>" (gold 23 does).
--   snapshot              the facility registry as of one date.
--   For both weekly bases, year and week are the ISO year and ISO week, so a few edge weeks
--   belong to the year before (HDX week ending 2021-01-03 is ISO 2020 week 53).
--
-- Rules
--   * Periods come from the silver tables: every period of diseases_metric_silver (with the
--     start and end dates silver writes), every year of the yearly silver tables, and one
--     snapshot date for the facility registry.
--   * period_label is the silver period_key unchanged. The facts build date_key from the same
--     two values, so never reformat the label here.
--   * The registry snapshot is its latest as-of date (the later of the NHFR and HFSRB dates).
--   * is_pandemic_period = year between pandemic_year_from and pandemic_year_to (settings in
--     [0], recorded in build_log.parameters). The team agreed 2020-2022 on 2026-10-19 (O-14).
--     The COVID flag on PhilHealth claims in silver (2020-2021) is a separate setting.
--
-- Build steps (write-audit-publish)
--   [0] build id and settings
--   [1] __inputs     every input, with the build that wrote it and its latest silver QC
--   [2] __candidate  the candidate rows
--   [3] __gates      every gate must have failures = 0
--   [4] stop if a gate failed: the failed build is logged, the published table is not touched
--   [5] write the table from the candidate (full rebuild)
--   [6] record the build in quality.build_log and quality.build_inputs
--   [7] drop the staging tables, then show the summary
--
-- History
--   2026-10-14  Written for the combined data model (from gold_12, v1).
--   2026-10-20  Moved to public_health.gold and renamed gold_02. Weekly conventions of D-44 and
--               D-46: the gate accepts iso_week and iso_week_ending_date (the two *_unconfirmed
--               values are gone); weekly dates come from silver; new gate for weekly dates.
--               'model' removed from the build log parameters. The weekly date_key values
--               change with the new period_basis, so G12 differs once after this rebuild.
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
-- true : every silver input needs a succeeded build in quality.build_log.
-- false: a silver table written by a notebook is allowed. Gold inputs always need one.
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
-- true : a silver input whose latest QC (quality.v_table_health) has a FAIL stops the build.
--        No QC run does not stop it; it makes the approval provisional (step [4]).
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job
-- Pandemic period (O-14, agreed 2026-10-19). Recorded in build_log.parameters.
DECLARE OR REPLACE VARIABLE pandemic_year_from INT DEFAULT 2020;
DECLARE OR REPLACE VARIABLE pandemic_year_to INT DEFAULT 2022;


-- ========================================
-- [1] inputs: one row per table read, with the version its latest succeeded build wrote and
--     the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_date__inputs AS
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
-- every year that a yearly silver table holds
CREATE OR REPLACE TEMP VIEW dim_date_years AS
SELECT CAST(population_year AS INT) AS y FROM public_health.silver.population_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.workforce_headcount_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.workforce_area_denominator_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.facilities_metric_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.facilities_bed_occupancy_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.socioeconomic_poverty_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.diseases_deaths_age_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.socioeconomic_health_expenditure_share_silver

UNION

SELECT CAST(year AS INT) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver;

-- disease periods as silver writes them (weekly start and end dates included), calendar years,
-- and the registry snapshot
CREATE OR REPLACE TEMP VIEW dim_date_all AS
SELECT DISTINCT period_basis, period_grain, period_key AS period_label, CAST(year AS INT) AS year,
       CAST(month AS INT) AS month, CAST(week AS INT) AS week, period_start, period_end
FROM public_health.silver.diseases_metric_silver
UNION
SELECT 'calendar_year', 'year', CAST(y AS STRING), y, CAST(NULL AS INT), CAST(NULL AS INT),
       make_date(y, 1, 1), make_date(y, 12, 31)
FROM dim_date_years WHERE y IS NOT NULL
UNION
SELECT 'snapshot', 'snapshot', date_format(d, 'yyyy-MM-dd'), year(d), month(d), CAST(NULL AS INT),
       d AS period_start, d AS period_end
FROM (SELECT max(greatest(_nhfr_as_of_date, _hfsrb_as_of_date)) AS d
      FROM public_health.silver.facilities_registry_silver) AS r
WHERE d IS NOT NULL;

CREATE OR REPLACE TABLE public_health.gold.dim_date__candidate AS
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
-- [3] gates: every row must have failures = 0.
--     "natural key not unique" also catches silver writing two different date sets for one
--     period. The weekly gate repeats the silver ISO rule for the dates gold publishes.
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_date__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.dim_date__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.dim_date__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.dim_date__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.dim_date__candidate
WHERE date_key IS NULL OR period_basis IS NULL OR period_label IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_date__candidate GROUP BY date_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_date__candidate
  GROUP BY period_basis, period_label HAVING count(*) > 1)
UNION ALL
SELECT 'period_grain outside year, month, week, snapshot', count(*) FROM public_health.gold.dim_date__candidate WHERE period_grain NOT IN ('year', 'month', 'week', 'snapshot') OR period_grain IS NULL
UNION ALL
SELECT 'period_basis outside the known conventions', count(*) FROM public_health.gold.dim_date__candidate
WHERE period_basis NOT IN ('calendar_year', 'calendar_month', 'iso_week', 'iso_week_ending_date', 'snapshot')
   OR period_basis IS NULL
UNION ALL
SELECT 'weekly period without dates, not 7 days, or not its ISO week and year (D-44, D-46)', count(*)
FROM public_health.gold.dim_date__candidate
WHERE period_grain = 'week'
  AND (period_start_date IS NULL OR period_end_date IS NULL
       OR period_end_date <> date_add(period_start_date, 6)
       OR weekofyear(period_end_date) <> week
       OR extract(yearofweek FROM period_end_date) <> year)
UNION ALL
SELECT 'year missing, month outside 1 to 12 or week outside 1 to 53', count(*) FROM public_health.gold.dim_date__candidate WHERE year IS NULL OR month NOT BETWEEN 1 AND 12 OR week NOT BETWEEN 1 AND 53
UNION ALL
SELECT 'period_start_date after period_end_date', count(*) FROM public_health.gold.dim_date__candidate WHERE period_start_date > period_end_date
UNION ALL
SELECT 'no registry snapshot period', CAST(count_if(period_basis = 'snapshot') = 0 AS INT) FROM public_health.gold.dim_date__candidate;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.dim_date__gates WHERE failures <> 0
--     approval: provisional while a silver input has no QC run or has WARN findings to review.
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_date_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'shared'                                      AS domain,
       'public_health.gold.dim_date'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds, 'pandemic_year_from', pandemic_year_from, 'pandemic_year_to', pandemic_year_to)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.dim_date__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.dim_date__inputs) AS q;

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
CREATE OR REPLACE TABLE public_health.gold.dim_date AS
SELECT * FROM public_health.gold.dim_date__candidate;


-- ========================================
-- [6] record the build, with the table version just written. If your runtime rejects this
--     SET VAR, delete it: the version stays null, and freshness checks (G06,
--     mart_evidence_readiness) cannot compare this table.
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.dim_date));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.dim_date),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_date_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.dim_date', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.dim_date__inputs;


-- ========================================
-- [7] remove the staging tables, then show the summary
-- ========================================
DROP TABLE IF EXISTS public_health.gold.dim_date__candidate;
DROP TABLE IF EXISTS public_health.gold.dim_date__gates;
DROP TABLE IF EXISTS public_health.gold.dim_date__inputs;

-- Summary by convention. Expect without_dates = 0 for every basis (weekly dates now come from
-- silver), and the bases calendar_year, calendar_month, iso_week, iso_week_ending_date, snapshot.
SELECT period_basis, period_grain, count(*) AS periods, min(year) AS first_year, max(year) AS last_year,
       count_if(period_start_date IS NULL) AS without_dates, min(period_label) AS first_label
FROM public_health.gold.dim_date
GROUP BY period_basis, period_grain ORDER BY period_basis;
