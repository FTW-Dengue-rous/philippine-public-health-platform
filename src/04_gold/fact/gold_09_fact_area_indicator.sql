-- ========================================
-- Builds public_health.gold.fact_area_indicator
--   One row is: one population or socioeconomic indicator of one area and period from one source
--   Primary key: fact_area_indicator_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, date_key, data_source_key, indicator_name, indicator_category)
--
-- Reads
--   public_health.silver.population_silver
--   public_health.silver.workforce_area_denominator_silver
--   public_health.silver.socioeconomic_poverty_silver
--   public_health.silver.socioeconomic_health_expenditure_share_silver
--   public_health.silver.socioeconomic_health_expenditure_per_capita_silver
--   public_health.gold.dim_geography
--   public_health.gold.dim_date
--   public_health.gold.dim_data_source
--
-- Rules
--   * Never sum across indicator_name, indicator_category or data_source_key. Census and
--     FHSIS population are two sources and are never added together.
--   * value is filled only when value_status is ok. Null is not zero.
--   * Census: VALID and VALID_WITH_NOTE become ok. Only areas in dim_geography, latest
--     snapshot. coverage_basis for census provinces: province_excl_huc in 2024,
--     province_coverage_unconfirmed for 2015 and 2020.
--   * FHSIS population: an area whose label override is proposed or rejected gets
--     label_under_review and a null value
--   * Poverty: rows with comparison_eligible = false are KEPT. Do not compare them with
--     PSGC-based population or facilities as they are. Percentages are never summed or
--     averaged. comparison_eligible is null on non-poverty rows (not assessed).
--   * Health expenditure: never add a parent agent to its children. Only category_level 1
--     rows add up to 100. value_note below_0_05: a 0.0 share stands for below 0.05 percent.
--   * Gold never interpolates between census years. The marts apply the 2-year window.
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
CREATE OR REPLACE TABLE public_health.gold.fact_area_indicator__inputs AS
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
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_date' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_date
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_data_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_data_source
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
-- The only place that names population_silver columns. Latest snapshot only.
CREATE OR REPLACE TEMP VIEW fai_census_src AS
SELECT psgc_code,
       CAST(population_year AS INT)               AS year,
       CAST(population AS BIGINT)                 AS population,
       upper(trim(population_parse_status))       AS silver_status
FROM public_health.silver.population_silver
WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at)
                          FROM public_health.silver.population_silver);

CREATE OR REPLACE TEMP VIEW fai_rows AS
-- population, census (v1 gold_14)
SELECT g.area_key,
       xxhash64('calendar_year', CAST(s.year AS STRING)) AS date_key,
       xxhash64('psa_psgc')                       AS data_source_key,
       'population'                               AS indicator_name,
       'census'                                   AS indicator_category,
       CAST(NULL AS INT)                          AS category_level,
       CAST(NULL AS STRING)                       AS parent_category,
       'persons'                                  AS indicator_unit,
       CASE WHEN s.silver_status IN ('VALID', 'VALID_WITH_NOTE') THEN CAST(s.population AS DECIMAL(20, 4)) END AS value,
       CASE WHEN s.silver_status IN ('VALID', 'VALID_WITH_NOTE') THEN 'ok'
            ELSE coalesce(lower(s.silver_status), 'missing') END AS value_status,
       CAST(NULL AS STRING)                       AS value_note,
       CASE WHEN g.geographic_level = 'province' AND s.year = 2024 THEN 'province_excl_huc'
            WHEN g.geographic_level = 'province' THEN 'province_coverage_unconfirmed'
            ELSE g.geographic_level END           AS coverage_basis,
       CAST(NULL AS BOOLEAN)                      AS comparison_eligible,
       CAST(NULL AS STRING)                       AS exclusion_reason
FROM fai_census_src AS s
INNER JOIN public_health.gold.dim_geography AS g ON g.psgc_code = s.psgc_code
UNION ALL
-- population, printed in the FHSIS tables (v1 gold_14)
SELECT xxhash64(d.area_key),
       xxhash64('calendar_year', CAST(d.year AS STRING)),
       xxhash64(d._source_key),
       'population', 'reported', CAST(NULL AS INT), CAST(NULL AS STRING), 'persons',
       CASE WHEN d.population_status = 'ok' AND NOT coalesce(d.area_label_override_status IN ('proposed', 'rejected'), false)
            THEN CAST(round(d.reported_population) AS DECIMAL(20, 4)) END,
       CASE WHEN d.area_label_override_status IN ('proposed', 'rejected') THEN 'label_under_review'
            ELSE d.population_status END,
       CAST(NULL AS STRING),
       d.geo_coverage_basis,
       CAST(NULL AS BOOLEAN), CAST(NULL AS STRING)
FROM public_health.silver.workforce_area_denominator_silver AS d
UNION ALL
-- poverty incidence (v1 gold_37)
SELECT xxhash64(p.area_key),
       xxhash64('calendar_year', CAST(p.year AS STRING)),
       xxhash64(p._source_key),
       'poverty_incidence_pct', 'all', CAST(NULL AS INT), CAST(NULL AS STRING), 'percent',
       CAST(p.poverty_incidence_pct AS DECIMAL(20, 4)),
       CASE WHEN p.poverty_incidence_pct IS NOT NULL THEN 'ok' ELSE 'no_estimate' END,
       p.incidence_precision,
       p.geo_coverage_basis,
       p.comparison_eligible, p.exclusion_reason
FROM public_health.silver.socioeconomic_poverty_silver AS p
UNION ALL
-- poor population (v1 gold_37)
SELECT xxhash64(p.area_key),
       xxhash64('calendar_year', CAST(p.year AS STRING)),
       xxhash64(p._source_key),
       'poor_population', 'all', CAST(NULL AS INT), CAST(NULL AS STRING), 'persons',
       CAST(p.poor_population AS DECIMAL(20, 4)),
       CASE WHEN p.poor_population IS NOT NULL THEN 'ok' ELSE 'no_estimate' END,
       p.poor_population_precision,
       p.geo_coverage_basis,
       p.comparison_eligible, p.exclusion_reason
FROM public_health.silver.socioeconomic_poverty_silver AS p
UNION ALL
-- health expenditure share by financing agent (v1 gold_90), national
SELECT xxhash64('ph'),
       xxhash64('calendar_year', CAST(e.year AS STRING)),
       xxhash64(e._source_key),
       'health_expenditure_share_pct', e.financing_agent, CAST(e.agent_level AS INT), e.parent_agent, 'percent',
       CAST(e.share_pct AS DECIMAL(20, 4)),
       CASE WHEN e.share_pct IS NOT NULL THEN 'ok' ELSE 'missing' END,
       CASE WHEN e.is_below_0_05 THEN 'below_0_05' END,
       'national',
       CAST(NULL AS BOOLEAN), CAST(NULL AS STRING)
FROM public_health.silver.socioeconomic_health_expenditure_share_silver AS e
UNION ALL
-- per capita health expenditure (v1 gold_90), national, one row per year
SELECT xxhash64('ph'),
       xxhash64('calendar_year', CAST(c.year AS STRING)),
       xxhash64(c._source_key),
       'health_expenditure_per_capita_php', 'all', CAST(NULL AS INT), CAST(NULL AS STRING), 'PHP, current prices',
       CAST(c.per_capita_health_expenditure_php AS DECIMAL(20, 4)),
       CASE WHEN c.per_capita_health_expenditure_php IS NOT NULL THEN 'ok' ELSE 'missing' END,
       CASE WHEN c.is_revised THEN 'revised' END,
       'national',
       CAST(NULL AS BOOLEAN), CAST(NULL AS STRING)
FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver AS c
UNION ALL
-- growth of per capita health expenditure (v1 gold_90), national, one row per year
SELECT xxhash64('ph'),
       xxhash64('calendar_year', CAST(c.year AS STRING)),
       xxhash64(c._source_key),
       'health_expenditure_per_capita_growth_pct', 'all', CAST(NULL AS INT), CAST(NULL AS STRING), 'percent',
       CAST(c.growth_rate_pct AS DECIMAL(20, 4)),
       CASE WHEN c.growth_rate_pct IS NOT NULL THEN 'ok' ELSE 'missing' END,
       concat_ws('; ', CASE WHEN c.is_revised THEN 'revised' END, concat('growth period ', c.growth_period)),
       'national',
       CAST(NULL AS BOOLEAN), CAST(NULL AS STRING)
FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver AS c;

CREATE OR REPLACE TABLE public_health.gold.fact_area_indicator__candidate AS
SELECT xxhash64(area_key, date_key, data_source_key, indicator_name, indicator_category) AS fact_area_indicator_key,
       area_key,
       date_key,
       data_source_key,
       indicator_name,
       indicator_category,
       category_level,
       parent_category,
       indicator_unit,
       value,
       value_status,
       value_note,
       coverage_basis,
       comparison_eligible,
       exclusion_reason,
       gold_build_id                              AS _gold_build_id
FROM fai_rows;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_area_indicator__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.fact_area_indicator__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.fact_area_indicator__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.fact_area_indicator__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.fact_area_indicator__candidate
WHERE fact_area_indicator_key IS NULL OR area_key IS NULL OR date_key IS NULL OR data_source_key IS NULL OR indicator_name IS NULL OR indicator_category IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_area_indicator__candidate GROUP BY fact_area_indicator_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_area_indicator__candidate
  GROUP BY area_key, date_key, data_source_key, indicator_name, indicator_category HAVING count(*) > 1)
UNION ALL
SELECT 'indicator_name outside the known list', count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name NOT IN ('population', 'poverty_incidence_pct', 'poor_population', 'health_expenditure_share_pct', 'health_expenditure_per_capita_php', 'health_expenditure_per_capita_growth_pct')
UNION ALL
SELECT 'value filled without status ok, or null with status ok', count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE (value IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'negative value for a count', count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_unit = 'persons' AND value < 0
UNION ALL
SELECT 'percentage outside 0 to 100 (incidence, share)', count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name IN ('poverty_incidence_pct', 'health_expenditure_share_pct') AND value NOT BETWEEN 0 AND 100
UNION ALL
SELECT 'census rows <> population_silver rows of the areas in dim_geography', abs((SELECT count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name = 'population' AND indicator_category = 'census') - count(*))
FROM fai_census_src AS s
LEFT SEMI JOIN public_health.gold.dim_geography AS g ON g.psgc_code = s.psgc_code
UNION ALL
SELECT 'census population total <> silver total for the areas in dim_geography', CAST(abs(coalesce((SELECT sum(value) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name = 'population' AND indicator_category = 'census'), 0)
         - coalesce(sum(CASE WHEN s.silver_status IN ('VALID', 'VALID_WITH_NOTE') THEN s.population END), 0)) AS BIGINT)
FROM fai_census_src AS s
LEFT SEMI JOIN public_health.gold.dim_geography AS g ON g.psgc_code = s.psgc_code
UNION ALL
SELECT 'reported population rows <> workforce_area_denominator_silver rows', abs((SELECT count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name = 'population' AND indicator_category = 'reported') - count(*)) FROM public_health.silver.workforce_area_denominator_silver
UNION ALL
SELECT 'poverty rows <> 2 x socioeconomic_poverty_silver rows', abs((SELECT count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name IN ('poverty_incidence_pct', 'poor_population')) - 2 * count(*)) FROM public_health.silver.socioeconomic_poverty_silver
UNION ALL
SELECT 'poverty row with comparison_eligible null, or not eligible without a reason', count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name IN ('poverty_incidence_pct', 'poor_population') AND (comparison_eligible IS NULL OR (NOT comparison_eligible AND exclusion_reason IS NULL))
UNION ALL
SELECT 'share rows <> share silver rows', abs((SELECT count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name = 'health_expenditure_share_pct') - count(*)) FROM public_health.silver.socioeconomic_health_expenditure_share_silver
UNION ALL
SELECT 'per capita rows <> 2 x per capita silver rows', abs((SELECT count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name LIKE 'health_expenditure_per_capita%') - 2 * count(*)) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver
UNION ALL
SELECT 'level 1 shares of a year do not add up to 100 within 0.2', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_area_indicator__candidate
  WHERE indicator_name = 'health_expenditure_share_pct' AND category_level = 1
  GROUP BY date_key HAVING abs(sum(value) - 100) > 0.2)
UNION ALL
SELECT 'health expenditure row whose area is not ph', count(*) FROM public_health.gold.fact_area_indicator__candidate WHERE indicator_name LIKE 'health_expenditure%' AND area_key <> xxhash64('ph')
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.gold.fact_area_indicator__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'date_key not in dim_date', count(*) FROM (
  SELECT DISTINCT date_key AS k FROM public_health.gold.fact_area_indicator__candidate WHERE date_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_date AS d ON d.date_key = c.k
UNION ALL
SELECT 'data_source_key not in dim_data_source', count(*) FROM (
  SELECT DISTINCT data_source_key AS k FROM public_health.gold.fact_area_indicator__candidate WHERE data_source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_data_source AS d ON d.data_source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.fact_area_indicator__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_area_indicator_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'socioeconomic'                                      AS domain,
       'public_health.gold.fact_area_indicator'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v2', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.fact_area_indicator__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.fact_area_indicator__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_area_indicator_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_area_indicator was NOT published. ', error_message))
FROM fact_area_indicator_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_area_indicator AS
SELECT * FROM public_health.gold.fact_area_indicator__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.fact_area_indicator));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.fact_area_indicator),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_area_indicator_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.fact_area_indicator', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.fact_area_indicator__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.gold.fact_area_indicator__candidate;
DROP TABLE IF EXISTS public_health.gold.fact_area_indicator__gates;
DROP TABLE IF EXISTS public_health.gold.fact_area_indicator__inputs;

-- Controls: Negros Island Region has no 2015 or 2020 census rows and Sulu no 2024 rows;
-- poverty ph 2025 incidence 9.7; households share 2023 = 44.4; per capita 2023 = 11,082.68.
SELECT f.indicator_name, f.indicator_category = 'all' AS no_breakdown, s.source_dataset, min(d.year) AS first_year,
       max(d.year) AS last_year, count(*) AS row_count, count_if(f.value_status <> 'ok') AS not_ok,
       count_if(f.comparison_eligible = false) AS not_comparison_eligible
FROM public_health.gold.fact_area_indicator AS f
INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
INNER JOIN public_health.gold.dim_date AS d ON d.date_key = f.date_key
GROUP BY f.indicator_name, f.indicator_category = 'all', s.source_dataset
ORDER BY f.indicator_name, s.source_dataset;