-- =============================================================================
-- Builds public_health.silver.diseases_source_coverage_silver:
--   which periods each source holds in each year.
--   Key: (_source_key, disease_scope, geo_level, period_grain, year)
-- and the view public_health.silver.diseases_metric_wide_v.
--
-- Why it exists: annual comparisons must use the same months on both sides. For example, the
-- DOH FOI dengue file was extracted in September 2025, so its 2025 holds January to September
-- only (live: missing_periods); gold reads this table to compare like with like.
--
-- Reads the published public_health.silver.diseases_metric_silver, so run it after
-- diseases_silver_01_metric.sql. It has no bronze input and writes no row dispositions.
-- =============================================================================

-- [0] build id and settings
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;

-- Number of ISO weeks in ISO year y (52 or 53): 28 December is always in the last ISO week.
-- Same function as in diseases_silver_01_metric.sql (kept identical).
CREATE OR REPLACE TEMPORARY FUNCTION dz_iso_weeks_in_year(y INT) RETURNS INT
RETURN weekofyear(make_date(y, 12, 28));


-- =============================================================================
-- [1] input: the metric table (layout of quality.build_inputs)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver__inputs AS
SELECT silver_build_id AS build_id, 'public_health.silver.diseases_source_coverage_silver' AS target_table,
       'table' AS input_kind, 'public_health.silver.diseases_metric_silver' AS input_table,
       -- Delta version read. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_metric_silver)) AS input_table_version,
       CAST(NULL AS STRING) AS source_key, CAST(NULL AS STRING) AS source_file, CAST(NULL AS STRING) AS source_sheet,
       CAST(NULL AS STRING) AS load_batch_id, CAST(NULL AS STRING) AS content_checksum,
       CAST(NULL AS TIMESTAMP) AS ingested_at,
       (SELECT count(*) FROM public_health.silver.diseases_metric_silver) AS input_rows,
       CAST(NULL AS STRING) AS reference_version;


-- =============================================================================
-- [2] candidate rows
--   periods_expected  1 for annual rows, 12 for months, and for weekly sources the number of
--                     ISO weeks in the ISO year (52 or 53).
--   is_complete_year  the SOURCE holds every period of the year, counted over all areas.
--                     year: always. month: 12 months. week: every ISO week 1 to 52 / 53 of the
--                     ISO year, one period per week (D-44, D-46). Weekly rows carry the ISO week
--                     and ISO year from diseases_silver_01 (HDX: of the date that closes the
--                     week; UP NOAH: WN and YR). Changed 2026-10-19: before, HDX used a
--                     date-span test and UP NOAH needed 52 weeks.
--                     D-44 expects HDX 2016, 2017, 2018 and 2020 complete and 2019 without its
--                     week 1.
--   areas_complete    areas that hold every period THE SOURCE holds in that year (an area's
--                     distinct periods >= periods_present), so a year short by one week does not
--                     mark every area incomplete. HDX provinces cover different week ranges
--                     (Databricks 2026-10-14, calendar years: 208 to 261 weeks over 2016-2021;
--                     2020: 61 of 81 provinces held all weeks), so a year can be complete for the
--                     source and incomplete for some provinces. Live: areas_complete vs
--                     areas_present. Gold applies the per-area test on each fact row
--                     (fact_disease_metric).
--   all_areas_complete  areas_complete = areas_present.
--   missing_periods   month numbers (monthly sources) or ISO week numbers (weekly sources) not present
--   min / max_periods_per_area  areas do not all cover the same periods
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver__candidate AS
WITH m AS (
  SELECT _source_key,
         CASE WHEN _source_key IN ('doh_foi_dengue', 'upnoah', 'hdx_dengue') THEN 'dengue'
              WHEN _source_key LIKE 'psa_deaths%' THEN 'psa_causes_of_death'
              WHEN _source_key = 'doh_fhsis' THEN 'tuberculosis'
              WHEN _source_key = 'ihme_gbd' THEN 'ihme_gbd_causes' END AS disease_scope,
         geo_level, period_grain, period_basis, year, month, week, period_key, area_key,
         CASE period_grain WHEN 'year' THEN 1 WHEN 'month' THEN 12
                           WHEN 'week' THEN dz_iso_weeks_in_year(year) END AS periods_expected
  FROM public_health.silver.diseases_metric_silver
),
g AS (
  SELECT _source_key, disease_scope, geo_level, period_grain, max(period_basis) AS period_basis, year,
         max(periods_expected) AS periods_expected,
         count(DISTINCT period_key) AS periods_present,
         min(period_key) AS first_period, max(period_key) AS last_period,
         collect_set(month) AS months_present,
         collect_set(week) AS weeks_present            -- ISO week numbers (weekly sources)
  FROM m GROUP BY _source_key, disease_scope, geo_level, period_grain, year
),
per_area AS (
  SELECT _source_key, disease_scope, geo_level, period_grain, year, area_key,
         count(DISTINCT period_key) AS periods
  FROM m GROUP BY _source_key, disease_scope, geo_level, period_grain, year, area_key
),
a AS (
  SELECT pa._source_key, pa.disease_scope, pa.geo_level, pa.period_grain, pa.year,
         count(*) AS areas_present, min(pa.periods) AS min_periods_per_area, max(pa.periods) AS max_periods_per_area,
         count_if(pa.periods >= g.periods_present) AS areas_complete
  FROM per_area AS pa
  JOIN g ON g._source_key = pa._source_key AND g.disease_scope = pa.disease_scope AND g.geo_level = pa.geo_level
        AND g.period_grain = pa.period_grain AND g.year = pa.year
  GROUP BY pa._source_key, pa.disease_scope, pa.geo_level, pa.period_grain, pa.year
)
SELECT g._source_key, g.disease_scope, g.geo_level, g.period_grain, g.year,
       g.periods_expected,
       g.periods_present, g.first_period, g.last_period,
       CASE g.period_grain
            WHEN 'year'  THEN true
            WHEN 'month' THEN g.periods_present = 12
            -- every ISO week of the ISO year, one period per week (D-44, D-46)
            WHEN 'week'  THEN size(g.weeks_present) = g.periods_expected
                              AND g.periods_present = g.periods_expected
       END AS is_complete_year,
       CASE WHEN g.period_grain = 'month'
            THEN array_join(array_except(sequence(1, 12), g.months_present), ',')
            WHEN g.period_grain = 'week'
            THEN array_join(array_except(sequence(1, g.periods_expected), g.weeks_present), ',') END AS missing_periods,
       a.areas_present, a.min_periods_per_area, a.max_periods_per_area,
       a.areas_complete,
       (a.areas_complete = a.areas_present) AS all_areas_complete,
       silver_build_id AS _silver_build_id
FROM g
JOIN a
  ON a._source_key = g._source_key AND a.disease_scope = g.disease_scope AND a.geo_level = g.geo_level
 AND a.period_grain = g.period_grain AND a.year = g.year;


-- =============================================================================
-- [3] gates: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver__gates AS
SELECT 'key not unique' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.diseases_source_coverage_silver__candidate
  GROUP BY _source_key, disease_scope, geo_level, period_grain, year HAVING count(*) > 1)
UNION ALL
SELECT 'key column is null', count(*) FROM public_health.silver.diseases_source_coverage_silver__candidate
  WHERE _source_key IS NULL OR disease_scope IS NULL OR geo_level IS NULL OR period_grain IS NULL OR year IS NULL
UNION ALL
SELECT 'no rows: is the metric table empty?', CASE WHEN count(*) = 0 THEN 1 ELSE 0 END FROM public_health.silver.diseases_source_coverage_silver__candidate
UNION ALL
SELECT 'source in the metric table without a coverage row', count(*) FROM (
  SELECT DISTINCT _source_key FROM public_health.silver.diseases_metric_silver) s
  LEFT ANTI JOIN public_health.silver.diseases_source_coverage_silver__candidate c ON c._source_key = s._source_key
UNION ALL
SELECT 'periods_expected or is_complete_year is null (unknown period_grain?)', count(*)
  FROM public_health.silver.diseases_source_coverage_silver__candidate
  WHERE periods_expected IS NULL OR is_complete_year IS NULL
UNION ALL
SELECT 'areas_complete above areas_present', count(*)
  FROM public_health.silver.diseases_source_coverage_silver__candidate
  WHERE areas_complete > areas_present;


-- =============================================================================
-- [4] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW cov_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'diseases'                                     AS domain,
       'public_health.silver.diseases_source_coverage_silver' AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.diseases_source_coverage_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [7]
       code_version                                   AS code_version,
       to_json(named_struct('reads', 'public_health.silver.diseases_metric_silver')) AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.diseases_source_coverage_silver__gates) g;


-- =============================================================================
-- [5] stop here if a gate failed. The failed build is logged first; the published table stays
--     as it was. The staging tables are kept so you can see what failed:
--       SELECT * FROM public_health.silver.diseases_source_coverage_silver__gates WHERE failures <> 0
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM cov_build_log WHERE status = 'failed';

SELECT raise_error(concat('diseases_source_coverage_silver was NOT published. ', error_message))
FROM cov_build_log WHERE status = 'failed';


-- =============================================================================
-- [6] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver AS
SELECT * FROM public_health.silver.diseases_source_coverage_silver__candidate;


-- =============================================================================
-- [7] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.diseases_source_coverage_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_source_coverage_silver)),
       code_version, parameters, run_id, error_message
FROM cov_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.diseases_source_coverage_silver__inputs;


DROP TABLE IF EXISTS public_health.silver.diseases_source_coverage_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.diseases_source_coverage_silver__gates;
DROP TABLE IF EXISTS public_health.silver.diseases_source_coverage_silver__inputs;


-- =============================================================================
-- [8] view: measures side by side, INSIDE ONE SOURCE OBSERVATION only (plan 2.2).
--     It never combines sources: reported cases, registered deaths and modelled prevalence do
--     not share a row because disease, area and period happen to match. Bringing sources
--     together is a gold decision, through source_priority.
-- =============================================================================
CREATE OR REPLACE VIEW public_health.silver.diseases_metric_wide_v AS
SELECT disease_key, area_key, period_grain, period_key, _source_key,
       max(geo_level) AS geo_level, max(year) AS year, max(month) AS month, max(week) AS week,
       max(value_type) AS value_type, max(location_basis) AS location_basis,
       max(CASE WHEN measure = 'cases' THEN value END)                   AS cases,
       max(CASE WHEN measure = 'cases' THEN measure_definition END)      AS cases_definition,
       max(CASE WHEN measure = 'cases' THEN value_status END)            AS cases_status,
       max(CASE WHEN measure = 'deaths' THEN value END)                  AS deaths,
       max(CASE WHEN measure = 'deaths' THEN measure_definition END)     AS deaths_definition,
       max(CASE WHEN measure = 'deaths' THEN value_status END)           AS deaths_status,
       max(CASE WHEN measure = 'prevalence' THEN value END)              AS prevalence,
       max(CASE WHEN measure = 'prevalence' THEN measure_definition END) AS prevalence_definition,
       max(CASE WHEN measure = 'prevalence' THEN value_status END)       AS prevalence_status
FROM public_health.silver.diseases_metric_silver
GROUP BY disease_key, area_key, period_grain, period_key, _source_key;


-- [9] result. Databricks 2026-10-14, calendar years (before D-44): hdx province 2016 = 51 weeks,
--     2017 = 53, 2018 = 52, 2019 = 51, 2020 = 52 (61 of 81 provinces hold all 52), 2021 = 2.
--     Expected after D-44 (ISO years, to verify on the rebuild): 2016, 2017, 2018 and 2020
--     complete; 2019 missing_periods = 1. areas_complete below areas_present shows the provinces
--     that hold fewer weeks than the source.
SELECT _source_key, geo_level, period_grain, year, periods_expected, periods_present,
       is_complete_year, missing_periods, areas_present, areas_complete, all_areas_complete
FROM public_health.silver.diseases_source_coverage_silver
ORDER BY _source_key, geo_level, period_grain, year;
