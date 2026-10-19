-- ========================================
-- Creates the view public_health.test_gold.mart_area_burden_indicator
--   One row is: one planning unit with one burden indicator (a disease, a measure and a
--   source), in the latest year the source has. Every unit has a row for every indicator,
--   also when it has no value: the row then says why.
--   Key: (planning_unit_key, burden_indicator_key)
--   Answers: N2 (modelled deaths and prevalence by province), N4 (TB notifications)
--
-- Reads: mart_base_planning_unit, area_coverage_map, source_priority, dim_disease,
--        dim_geography, dim_period, dim_source, fact_disease_metric
--
-- Indicators today
--   * TB notifications, all forms (FHSIS, reported). Published by city and municipality, so
--     the unit value is the sum of its cities and municipalities. The count is kept when a
--     locality has no report, but the rate is then null: a part sum is not a rate.
--   * IHME modelled deaths and prevalence of the focus diseases and chronic kidney disease.
--     Published by province and for NCR. Used only where area_coverage_map says direct.
--     IHME provinces are ASSUMED to include their HUCs (decision D5 is open), so a province
--     with a HUC, and the HUC itself, have no value here.
--   Not here: dengue. The province source ends in 2020 and its coverage is not confirmed.
--   Dengue by region and month is read from fact_disease_metric directly (N3).
--
-- Rules
--   * The source of each indicator is the preferred row of source_priority.
--   * Sources are never mixed: a reported count and a modelled number are two indicators.
--   * rate_per_100k = value / census population of the unit x 100,000. Null when the value
--     year and the population year are more than 2 years apart, or the population is missing.
--   * Bounds (value_lower, value_upper) stay with their estimate and are never summed.
--   * quintile 1 = lowest rate, 5 = highest, among units with a rate, per indicator.
--     Units with the same rate get the same quintile.
--   * IHME licence: no row-level export. Put the attribution line on every chart.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold.mart_area_burden_indicator AS
WITH preferred AS (
  SELECT * FROM public_health.test_gold.source_priority WHERE role = 'preferred'
),

tb_rows AS (
  SELECT g.planning_unit_key, CAST(p.year AS INT) AS year, f.disease_key, f.metric_name, f.source_key, f.value
  FROM public_health.test_gold.fact_disease_metric AS f
  INNER JOIN public_health.test_gold.dim_disease AS d
    ON d.disease_key = f.disease_key AND d.disease_code = 'tb_all_forms'
  INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key AND p.period_grain = 'year'
  INNER JOIN public_health.test_gold.dim_geography AS g
    ON g.area_key = f.area_key AND g.geographic_level IN ('city', 'municipality')
  INNER JOIN preferred AS sp
    ON sp.source_key = f.source_key AND sp.metric = f.metric_name AND sp.disease_scope = d.disease_group
   AND sp.geo_level = g.geographic_level AND sp.period_grain = 'year' AND p.year BETWEEN sp.year_from AND sp.year_to
  WHERE f.metric_name = 'cases'
),

tb AS (
  SELECT planning_unit_key, year, disease_key, metric_name, source_key,
         CAST(sum(value) AS DECIMAL(20, 4)) AS value,
         CAST(NULL AS DECIMAL(20, 4)) AS value_lower, CAST(NULL AS DECIMAL(20, 4)) AS value_upper,
         count(value) AS localities_reporting
  FROM tb_rows
  WHERE year = (SELECT max(year) FROM tb_rows)
  GROUP BY planning_unit_key, year, disease_key, metric_name, source_key
),

ihme_rows AS (
  SELECT m.planning_unit_key, m.year, f.disease_key, f.metric_name, f.source_key,
         f.value, f.value_lower, f.value_upper,
         max(m.year) OVER (PARTITION BY f.disease_key, f.metric_name, f.source_key) AS latest_year
  FROM public_health.test_gold.fact_disease_metric AS f
  INNER JOIN public_health.test_gold.area_coverage_map AS m
    ON m.fact_table = 'fact_disease_metric' AND m.source_key = f.source_key AND m.area_key = f.area_key
   AND m.period_key = f.period_key AND m.geo_coverage_basis <=> f.coverage_basis
   AND m.mapping_outcome = 'direct'
  INNER JOIN public_health.test_gold.dim_disease AS d
    ON d.disease_key = f.disease_key AND (d.is_focus_disease OR d.disease_code = 'ihme_589')
  INNER JOIN preferred AS sp
    ON sp.source_key = f.source_key AND sp.metric = f.metric_name AND sp.disease_scope = d.classification
   AND sp.geo_level = m.geographic_level AND sp.period_grain = 'year' AND m.year BETWEEN sp.year_from AND sp.year_to
),

unit_values AS (
  SELECT planning_unit_key, year, disease_key, metric_name, source_key, value, value_lower, value_upper,
         localities_reporting
  FROM tb
  UNION ALL
  SELECT planning_unit_key, year, disease_key, metric_name, source_key, value, value_lower, value_upper,
         CAST(NULL AS BIGINT)
  FROM ihme_rows
  WHERE year = latest_year
),

indicators AS (
  SELECT DISTINCT disease_key, metric_name, source_key, year AS reference_year FROM unit_values
),

-- IHME rows that could not be given to a planning unit (province with a HUC)
blocked AS (
  SELECT DISTINCT area_key AS planning_unit_key, source_key
  FROM public_health.test_gold.area_coverage_map
  WHERE fact_table = 'fact_disease_metric' AND mapping_outcome = 'not_separable'
),

grid AS (
  SELECT u.planning_unit_key, u.area_code, u.area_name, u.unit_level, u.localities, u.population, u.population_year,
         i.disease_key, i.metric_name, i.source_key, i.reference_year,
         d.disease_code, d.disease_name, s.source_dataset, s.value_type,
         v.value, v.value_lower, v.value_upper, v.localities_reporting,
         (s.source_dataset = 'doh_fhsis') AS is_locality_sum,
         (b.planning_unit_key IS NOT NULL) AS is_blocked
  FROM public_health.test_gold.mart_base_planning_unit AS u
  CROSS JOIN indicators AS i
  INNER JOIN public_health.test_gold.dim_disease AS d ON d.disease_key = i.disease_key
  INNER JOIN public_health.test_gold.dim_source AS s ON s.source_key = i.source_key
  LEFT JOIN unit_values AS v
    ON v.planning_unit_key = u.planning_unit_key AND v.disease_key = i.disease_key
   AND v.metric_name = i.metric_name AND v.source_key = i.source_key
  LEFT JOIN blocked AS b ON b.planning_unit_key = u.planning_unit_key AND b.source_key = i.source_key
),

rated AS (
  SELECT g.*,
         CASE WHEN g.value IS NULL THEN
                CASE WHEN g.is_locality_sum AND g.localities_reporting IS NOT NULL THEN 'locality_without_report'
                     WHEN g.is_locality_sum THEN 'no_source_row'
                     WHEN g.is_blocked THEN 'province_estimate_assumed_to_include_its_huc'
                     WHEN g.unit_level = 'HUC' THEN 'published_only_inside_the_province_estimate'
                     ELSE 'no_source_row' END
              WHEN g.is_locality_sum AND g.localities_reporting < g.localities THEN 'locality_without_report'
              WHEN g.population IS NULL THEN 'no_population'
              WHEN abs(g.reference_year - g.population_year) > 2 THEN 'outside_alignment_window'
         END AS exclusion_reason
  FROM grid AS g
),

final AS (
  SELECT r.*,
         CASE WHEN r.exclusion_reason IS NULL AND r.population > 0
              THEN CAST(r.value AS DOUBLE) * 100000.0 / r.population END AS rate
  FROM rated AS r
)

SELECT planning_unit_key,
       concat(disease_code, ':', metric_name, ':', source_dataset) AS burden_indicator_key,
       disease_key,
       metric_name,
       'number' AS metric_basis,
       source_key,
       value,
       population,
       round(rate, 2) AS rate_per_100k,
       reference_year,
       value_lower,
       value_upper,
       CASE WHEN rate IS NOT NULL
            THEN CAST(least(5, floor(percent_rank() OVER (
                   PARTITION BY disease_key, metric_name, source_key, rate IS NOT NULL ORDER BY rate) * 5) + 1) AS INT)
       END AS quintile,
       area_code,                 -- extra
       area_name,                 -- extra
       disease_code,              -- extra
       disease_name,              -- extra
       source_dataset,            -- extra
       value_type,                -- extra
       population_year,           -- extra
       localities_reporting,      -- extra
       CASE WHEN is_locality_sum THEN CASE WHEN localities_reporting IS NOT NULL THEN 'aggregate' END
            WHEN value IS NOT NULL THEN 'direct'
            WHEN is_blocked THEN 'not_separable' END AS mapping_outcome,   -- extra
       exclusion_reason           -- extra
FROM final;


SELECT burden_indicator_key, max(reference_year) AS reference_year, count(*) AS units,
       count(value) AS with_value, count(rate_per_100k) AS with_rate,
       array_join(array_sort(collect_set(exclusion_reason)), '; ') AS exclusion_reasons
FROM public_health.test_gold.mart_area_burden_indicator
GROUP BY burden_indicator_key
ORDER BY burden_indicator_key;