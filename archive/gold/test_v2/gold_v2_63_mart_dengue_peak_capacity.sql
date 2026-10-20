-- ========================================
-- Creates the view public_health.test_gold2.mart_dengue_peak_capacity
--   One row is: one area as one dengue source publishes it, in one year: the highest period of
--   reported dengue cases, set beside the hospital beds recorded there today and the latest
--   bed-day-weighted occupancy reported there.
--   Key: (area_key, data_source_key, year)
--   Answers: DP (core) "Where were historical dengue peaks largest relative to current recorded
--   hospital capacity?" and N3 (when and where dengue peaks, concentration, repeat high burden).
--   It does NOT answer BQ2 "which areas would exceed capacity": that needs the replay
--   (stretch 2, D1-D5) with admission and length-of-stay assumptions. Nothing here converts
--   cases to beds. (Review point 4, 2026-10-14 night.)
--
-- Reads: fact_disease_metric, fact_facility_capacity, fact_area_indicator, area_coverage_map,
--        mart_locality_service_presence, dim_geography, dim_date, dim_data_source, dim_disease
--
-- Rules
--   * Three dengue sources, never mixed: hdx_dengue (province or HUC x dated week, 2016-2021),
--     upnoah (region x week number, 2016-2019 and 2022-2025, every value approximated by the
--     source), doh_foi_dengue (region x month, 2021-2025). The grain keeps data_source_key, so
--     weekly peaks and monthly peaks never sit in one ranking; the dashboard filters one source.
--   * Peak = the period with the most reported cases in the year. When the year is not complete
--     for that area (is_complete_year false on any row), peak_label says 'highest observed
--     period': the missing weeks could hold the true peak. Weeks are labelled by week number or
--     dated week label, never a calendar date, until D4 (week start or end) is decided.
--   * Concentration: peak_period_share_pct = peak / annual; top4_periods_share_pct = the four
--     highest weeks / annual (weekly sources only; null for monthly).
--   * Repeat high burden (per source): a complete or near-complete year (>= 50 weeks or 12
--     months reported) is 'high' when the area's annual cases per 100,000 census population are
--     in the top fifth of that source and year; high_burden_years counts them;
--     repeat_high_burden = 2 or more. Near-complete covers the HDX years short by a week at a
--     year edge (F14); the strict flag is_complete_year still drives peak_label.
--   * D4 evidence (first Databricks run, 2026-10-14): every HDX peak date is a Sunday, the start
--     of a DOH morbidity week. Until the dataset page confirms it, labels stay as dated weeks.
--   * Coverage: HDX province rows pass through area_coverage_map (fact_disease_metric rows keyed
--     by calendar year). comparison_eligible = mapping_outcome in (direct, aggregate); a
--     province with a HUC the source does not list apart is not_separable (D5 open) and keeps
--     its peak but is excluded from the capacity comparison. Region rows (DOH FOI, UP NOAH) are
--     compared with the beds of the same region as published (coverage note 'region as
--     published').
--   * Capacity: hospital_beds_recorded = registry analysis beds of the SAME COVERAGE as the
--     published row (capacity_coverage): region; the city itself; the province excl. HUC; or,
--     when HDX lists component cities apart (mapping_outcome aggregate), the province excl.
--     those cities (their beds subtracted via area_coverage_map.cities_included). From
--     mart_locality_service_presence (2026 snapshot: label the as-of date).
--     Occupancy = fact_facility_capacity occupancy_report, ownership total, hospital_level all,
--     coverage_basis province_excl_huc (province) / region (region) / the HUC's own row, latest
--     year with any record; suppressed cells stay null with occupancy_value_status.
--   * peak_cases_per_100_beds = peak cases / recorded beds x 100 (a relative pressure figure
--     for ranking, not a bed demand). Null when beds are 0 or the row is not comparison_eligible.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold2.mart_dengue_peak_capacity AS
WITH dengue AS (
  SELECT f.area_key, f.data_source_key, s.source_dataset, t.period_grain, t.period_basis,
         CAST(t.year AS INT) AS year, t.period_label, t.week, t.month,
         f.value, f.is_complete_year, f.is_preliminary, f.coverage_basis
  FROM public_health.test_gold2.fact_disease_metric AS f
  INNER JOIN public_health.test_gold2.dim_disease AS d ON d.disease_key = f.disease_key
  INNER JOIN public_health.test_gold2.dim_data_source AS s ON s.data_source_key = f.data_source_key
  INNER JOIN public_health.test_gold2.dim_date AS t ON t.date_key = f.date_key
  WHERE d.disease_code = 'dengue' AND f.metric_name = 'cases'
    AND f.age_group = 'all_ages' AND f.sex = 'both_sexes' AND f.value_status = 'ok'
    AND s.source_dataset IN ('hdx_dengue', 'upnoah', 'doh_foi_dengue')
    AND t.period_grain IN ('week', 'month')
),

ranked AS (
  SELECT d.*, row_number() OVER (PARTITION BY area_key, data_source_key, year ORDER BY value DESC, period_label) AS rn
  FROM dengue AS d
),

per_year AS (
  SELECT area_key, data_source_key, max(source_dataset) AS source_dataset, max(period_grain) AS period_grain,
         max(period_basis) AS period_basis, year,
         count(*) AS periods_reported,
         sum(value) AS annual_cases,
         max(value) AS peak_cases,
         max_by(period_label, value) AS peak_period_label,
         max_by(coalesce(week, month), value) AS peak_period_number,
         sum(CASE WHEN rn <= 4 THEN value END) AS top4_cases,
         bool_and(coalesce(is_complete_year, false)) AS is_complete_year,
         bool_or(coalesce(is_preliminary, false)) AS is_preliminary,
         max(coverage_basis) AS coverage_basis
  FROM ranked
  GROUP BY area_key, data_source_key, year
),

census AS (
  SELECT area_key, max_by(value, t.year) AS population, CAST(max(t.year) AS INT) AS population_year
  FROM public_health.test_gold2.fact_area_indicator AS f
  INNER JOIN public_health.test_gold2.dim_date AS t ON t.date_key = f.date_key
  WHERE f.indicator_name = 'population' AND f.indicator_category = 'census' AND f.value_status = 'ok'
  GROUP BY area_key
),

rated AS (
  SELECT p.*, c.population, c.population_year,
         CASE WHEN c.population > 0 THEN p.annual_cases / c.population * 100000 END AS annual_cases_per_100k,
         -- near-complete: a year short by a week or two at its edge (HDX 2016, 2019, 2021: F14)
         -- still ranks for repeat high burden; the strict flag stays on peak_label
         (p.is_complete_year OR (p.period_grain = 'week' AND p.periods_reported >= 50)
                             OR (p.period_grain = 'month' AND p.periods_reported >= 12)) AS is_near_complete
  FROM per_year AS p
  LEFT JOIN census AS c ON c.area_key = p.area_key
),

high AS (
  SELECT r.*,
         CASE WHEN r.is_near_complete AND r.annual_cases_per_100k IS NOT NULL
              THEN percent_rank() OVER (PARTITION BY r.data_source_key, r.year, r.is_near_complete
                                        ORDER BY r.annual_cases_per_100k DESC) < 0.2 END AS is_high_burden_year
  FROM rated AS r
),

repeat_flag AS (
  SELECT h.*,
         count_if(h.is_high_burden_year) OVER (PARTITION BY h.area_key, h.data_source_key) AS high_burden_years
  FROM high AS h
),

beds_unit AS (
  SELECT planning_unit_key AS unit_key, sum(hospital_beds) AS beds, sum(hospitals_recorded) AS hospitals,
         max(registry_as_of_date) AS registry_as_of_date
  FROM public_health.test_gold2.mart_locality_service_presence
  GROUP BY planning_unit_key
),

beds_locality AS (
  SELECT area_key, area_code, hospital_beds AS beds, hospitals_recorded AS hospitals, registry_as_of_date
  FROM public_health.test_gold2.mart_locality_service_presence
),

-- beds of the cities an HDX province row lists apart (area_coverage_map.cities_included), so a
-- province row is compared with the beds of its own coverage, not of the whole unit
listed_apart AS (
  SELECT m.data_source_key, m.area_key, m.date_key, x.city_code
  FROM public_health.test_gold2.area_coverage_map AS m
  LATERAL VIEW explode(split(m.cities_included, ', ')) x AS city_code
  WHERE m.fact_table = 'fact_disease_metric' AND m.mapping_outcome = 'aggregate' AND m.cities_included IS NOT NULL
),

beds_listed_apart AS (
  SELECT la.data_source_key, la.area_key, la.date_key,
         sum(bl.beds) AS beds, sum(bl.hospitals) AS hospitals
  FROM listed_apart AS la
  INNER JOIN beds_locality AS bl ON bl.area_code = la.city_code
  GROUP BY la.data_source_key, la.area_key, la.date_key
),

beds_region AS (
  SELECT region_key AS unit_key, sum(hospital_beds) AS beds, sum(hospitals_recorded) AS hospitals,
         max(registry_as_of_date) AS registry_as_of_date
  FROM public_health.test_gold2.mart_locality_service_presence
  GROUP BY region_key
),

occupancy AS (
  SELECT o.area_key, o.coverage_basis,
         CAST(max(t.year) AS INT) AS occupancy_year,
         max_by(o.bor_weighted_pct, t.year) AS bor_weighted_pct,
         max_by(o.bor_reporting_record_count, t.year) AS bor_reporting_record_count,
         max_by(o.value_status, t.year) AS occupancy_value_status
  FROM public_health.test_gold2.fact_facility_capacity AS o
  INNER JOIN public_health.test_gold2.dim_date AS t ON t.date_key = o.date_key
  WHERE o.capacity_basis = 'occupancy_report' AND o.ownership = 'total' AND o.hospital_level = 'all'
  GROUP BY o.area_key, o.coverage_basis
)

SELECT r.area_key,
       g.area_code,
       g.area_name,
       g.geographic_level,
       r.data_source_key,
       r.source_dataset,
       r.period_grain,
       r.period_basis,
       r.year,
       r.periods_reported,
       r.is_complete_year,
       r.is_near_complete,
       r.is_preliminary,
       CASE WHEN r.is_complete_year THEN 'peak'
            WHEN r.is_near_complete THEN 'highest observed period (year short by 1-2 periods at its edge)'
            ELSE 'highest observed period (year incomplete)' END AS peak_label,
       r.peak_period_label,
       r.peak_period_number,
       r.peak_cases,
       r.annual_cases,
       round(r.peak_cases / nullif(r.annual_cases, 0) * 100, 1)                        AS peak_period_share_pct,
       CASE WHEN r.period_grain = 'week' THEN round(r.top4_cases / nullif(r.annual_cases, 0) * 100, 1) END
                                                                                       AS top4_periods_share_pct,
       r.population,
       r.population_year,
       round(r.annual_cases_per_100k, 1)                                               AS annual_cases_per_100k,
       r.is_high_burden_year,
       r.high_burden_years,
       (r.high_burden_years >= 2)                                                      AS repeat_high_burden,
       -- coverage
       CASE WHEN g.geographic_level = 'region' THEN 'region_as_published' ELSE m.mapping_outcome END AS mapping_outcome,
       CASE WHEN g.geographic_level = 'region' THEN true
            ELSE m.mapping_outcome IN ('direct', 'aggregate') END                       AS comparison_eligible,
       CASE WHEN g.geographic_level = 'region' THEN 'Region compared with the registry beds of the same region'
            ELSE m.note END                                                            AS coverage_note,
       -- capacity today (registry snapshot)
       CASE g.geographic_level WHEN 'region' THEN b_r.hospitals WHEN 'city' THEN b_c.hospitals ELSE b_u.hospitals - coalesce(b_x.hospitals, 0) END AS hospitals_recorded,
       CASE g.geographic_level WHEN 'region' THEN b_r.beds WHEN 'city' THEN b_c.beds ELSE b_u.beds - coalesce(b_x.beds, 0) END AS hospital_beds_recorded,
       CASE g.geographic_level WHEN 'region' THEN 'region' WHEN 'city' THEN 'city itself'
            WHEN 'province' THEN CASE WHEN m.mapping_outcome = 'aggregate' THEN 'province excl. the cities listed apart'
                                      ELSE 'province excl. HUC (planning unit)' END END AS capacity_coverage,
       coalesce(b_u.registry_as_of_date, b_r.registry_as_of_date, b_c.registry_as_of_date) AS registry_as_of_date,
       CASE WHEN (CASE g.geographic_level WHEN 'region' THEN b_r.beds WHEN 'city' THEN b_c.beds ELSE b_u.beds - coalesce(b_x.beds, 0) END) > 0
             AND (g.geographic_level = 'region' OR m.mapping_outcome IN ('direct', 'aggregate'))
            THEN round(r.peak_cases / (CASE g.geographic_level WHEN 'region' THEN b_r.beds WHEN 'city' THEN b_c.beds ELSE b_u.beds - coalesce(b_x.beds, 0) END) * 100, 1) END AS peak_cases_per_100_beds,
       -- occupancy (latest year reported)
       o.occupancy_year,
       o.bor_weighted_pct,
       o.bor_reporting_record_count,
       o.occupancy_value_status
FROM repeat_flag AS r
INNER JOIN public_health.test_gold2.dim_geography AS g ON g.area_key = r.area_key
LEFT JOIN public_health.test_gold2.area_coverage_map AS m
  ON m.fact_table = 'fact_disease_metric' AND m.data_source_key = r.data_source_key
 AND m.area_key = r.area_key AND m.date_key = xxhash64('calendar_year', CAST(r.year AS STRING))
LEFT JOIN beds_unit AS b_u ON g.geographic_level = 'province' AND b_u.unit_key = g.planning_unit_key
LEFT JOIN beds_region AS b_r ON g.geographic_level = 'region' AND b_r.unit_key = r.area_key
LEFT JOIN beds_locality AS b_c ON g.geographic_level = 'city' AND b_c.area_key = r.area_key
LEFT JOIN beds_listed_apart AS b_x
  ON g.geographic_level = 'province' AND b_x.data_source_key = r.data_source_key
 AND b_x.area_key = r.area_key AND b_x.date_key = xxhash64('calendar_year', CAST(r.year AS STRING))
LEFT JOIN occupancy AS o
  ON o.area_key = r.area_key
 AND o.coverage_basis = CASE g.geographic_level WHEN 'province' THEN 'province_excl_huc'
                                                WHEN 'region' THEN 'region'
                                                ELSE o.coverage_basis END;


-- Checks to read after creating the view
-- 1. Rows per source: HDX about 81 provinces + listed cities x 6 years; UP NOAH 17 regions x 8;
--    DOH FOI 18 regions x 5. Eligible share tells how many provinces the D5 rule blocks.
SELECT source_dataset, period_grain, count(*) AS area_years, count(DISTINCT area_key) AS areas,
       count_if(is_complete_year) AS complete_years, count_if(comparison_eligible) AS eligible,
       count_if(peak_cases_per_100_beds IS NOT NULL) AS with_capacity_ratio,
       count_if(bor_weighted_pct IS NOT NULL) AS with_occupancy
FROM public_health.test_gold2.mart_dengue_peak_capacity
GROUP BY source_dataset, period_grain ORDER BY source_dataset;

-- 2. The core answer, one source at a time: largest peaks relative to recorded beds
SELECT area_name, year, peak_label, peak_period_label, peak_cases, hospital_beds_recorded,
       peak_cases_per_100_beds, bor_weighted_pct, occupancy_year, repeat_high_burden
FROM public_health.test_gold2.mart_dengue_peak_capacity
WHERE source_dataset = 'hdx_dengue' AND comparison_eligible
ORDER BY peak_cases_per_100_beds DESC
LIMIT 20;
