-- ========================================
-- Creates the view public_health.gold.mart_dengue_peak_capacity
--   One row is: one area as one dengue source publishes it, in one year. The row holds the
--   period with the most reported dengue cases, the hospital beds recorded there today, and the
--   latest bed-day-weighted occupancy reported there.
--   Key: (area_key, data_source_key, year)
--   Answers:
--     DP (core)  Where were historical dengue peaks largest relative to current recorded
--                hospital capacity?
--     N3         When and where does dengue peak, how concentrated is it, and where is the
--                burden high year after year?
--   It does NOT answer BQ2 ("which areas would exceed capacity"). That needs the replay
--   (stretch 2) with admission and length-of-stay assumptions. Nothing here converts cases to
--   beds (review point 4, 2026-10-14 night).
-- Previous file name: gold_v2_63_mart_dengue_peak_capacity.sql
--
-- Reads: fact_disease_metric (gold 07), fact_facility_capacity (gold 06),
--        fact_area_indicator (gold 09), area_coverage_map (gold 11),
--        mart_locality_service_presence (gold 14), dim_geography, dim_date, dim_data_source,
--        dim_disease
--
-- Sources. Three dengue sources, never mixed. data_source_key is part of the key, so weekly and
-- monthly peaks never sit in one ranking. The dashboard filters one source at a time.
--   hdx_dengue      province or city x dated week, 2016-2021. Province rows exclude the cities
--                   the source lists apart (D-43). From 2018 its counts run 1-2 weeks behind and
--                   below the DOH counts (D-45).
--   upnoah          region x ISO week, 2016-2019 and 2022-2025. The counts are DOH-EB counts
--                   (FOI 2026-031) by ISO week, not approximated (D-46).
--   doh_foi_dengue  region x month, 2021-2025. 2025 holds January to September.
--                   Restricted source: aggregates only (D-47).
--   This view reads every row of each source. It does not filter by source_priority.
--   Use upnoah or doh_foi_dengue for the timing of regional peaks (D-45). Use hdx_dengue to
--   compare provinces, and treat its peak weeks from 2018 as 1-2 weeks late.
--
-- Rules
--   * Peak = the period with the most reported cases in the year.
--     peak_label says how far to trust it:
--       'peak'                       the year is complete (is_complete_year true on every row)
--       'highest observed period ...' the year is incomplete: a missing period could hold the
--                                    true peak
--   * Concentration:
--       peak_period_share_pct   = peak / annual cases x 100
--       top4_periods_share_pct  = the four highest weeks / annual cases x 100 (weekly sources
--                                 only; null for monthly)
--   * Repeat high burden (per source):
--       - A year counts when it is complete or near-complete (at least 50 weeks or 12 months
--         reported). Near-complete covers the HDX source gaps of one week (F14; checked
--         2026-10-19: 2019 misses ISO week 1 in every area; 2016, 2017 and 2020 miss one week in
--         some provinces). The strict is_complete_year still drives peak_label.
--       - The year is 'high' when the area's annual cases per 100,000 are in the top fifth of
--         that source and year.
--       - high_burden_years counts the high years. repeat_high_burden = 2 or more.
--       - The rate uses the area's LATEST census population for every year. There is no
--         alignment window here. Ranks within a year stay comparable, but early-year rates are
--         approximate.
--   * Coverage:
--       - HDX rows pass through area_coverage_map (fact_disease_metric rows keyed by calendar
--         year). comparison_eligible = mapping_outcome in (direct, aggregate).
--       - A province whose HUC the source does not list apart is not_separable: its row cannot
--         be split from the HUC. It keeps its peak but is left out of the capacity comparison.
--       - Region rows (DOH FOI, UP NOAH) are compared with the beds of the same region
--         (mapping_outcome 'region_as_published').
--   * Capacity: hospital_beds_recorded = registry analysis beds of the SAME COVERAGE as the
--     published row (capacity_coverage):
--       - region: the region
--       - city: the city itself
--       - province: the planning unit (province excluding HUCs)
--       - province with cities listed apart (mapping_outcome aggregate): the planning unit
--         minus the beds of those cities (area_coverage_map.cities_included). cities_included
--         holds component cities only (gold 11 never lists a HUC there), so no HUC's beds are
--         removed twice.
--     Beds come from mart_locality_service_presence (registry snapshot). Show the as-of date.
--   * Occupancy: fact_facility_capacity occupancy_report, ownership total, hospital_level all,
--     latest year with any record. Coverage: province_excl_huc for a province, region for a
--     region, and the city's own row for a city. Restricted source (D-47): suppressed cells stay
--     null, and occupancy_value_status says why.
--   * peak_cases_per_100_beds = peak cases / recorded beds x 100. It is a relative pressure
--     figure for ranking, not a bed demand. Null when beds are 0 or the row is not
--     comparison_eligible.
--
-- Week convention (D-44, D-46). Each HDX date closes its week: the week runs from the date
-- minus 6 days to the date, and takes the ISO week and ISO year of the date. UP NOAH weeks are
-- ISO weeks (Monday to Sunday). The evidence: every HDX date is a Sunday, the last day of an
-- ISO week, and in 2016 the HDX regional sums match UP NOAH in 714 region-weeks at the ISO week
-- of the date (21 under the week-start reading). Silver applies it since 2026-10-19
-- (period_basis iso_week_ending_date and iso_week). Because year is the ISO year, a few edge
-- weeks belong to the previous year (e.g. 2021-01-03 is in 2020). peak_period_label is the
-- dim_date label (gold 02), for example 'yyyy-Www' for UP NOAH. For HDX it reads
-- "week ending <date>": this view adds the words, and dim_date keeps the bare date because it
-- is part of the key.
--
-- History
--   2026-10-14  Written for data model v2.
--   2026-10-18  Moved to public_health.gold and renamed gold_23. Comments updated for D-43,
--               D-44 (decided, pending), D-45, D-46 and D-47. The old D4 note (date = week
--               start) is replaced. No logic change.
--   2026-10-19  Added check 3 (one row per key). A city takes any occupancy row of its own, so
--               two coverage_basis rows for one city would duplicate the key.
--   2026-10-20  D-44 note updated: silver applies the ISO week convention. HDX gap note dated.
--               HDX peak_period_label reads "week ending <date>".
-- ========================================

CREATE OR REPLACE VIEW public_health.gold.mart_dengue_peak_capacity AS
-- weekly and monthly dengue cases of the three sources, all ages, both sexes, ok rows only
WITH dengue AS (
  SELECT f.area_key, f.data_source_key, s.source_dataset, t.period_grain, t.period_basis,
         CAST(t.year AS INT) AS year, t.period_label, t.week, t.month,
         f.value, f.is_complete_year, f.is_preliminary, f.coverage_basis
  FROM public_health.gold.fact_disease_metric AS f
  INNER JOIN public_health.gold.dim_disease AS d ON d.disease_key = f.disease_key
  INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
  INNER JOIN public_health.gold.dim_date AS t ON t.date_key = f.date_key
  WHERE d.disease_code = 'dengue' AND f.metric_name = 'cases'
    AND f.age_group = 'all_ages' AND f.sex = 'both_sexes' AND f.value_status = 'ok'
    AND s.source_dataset IN ('hdx_dengue', 'upnoah', 'doh_foi_dengue')
    AND t.period_grain IN ('week', 'month')
),

-- periods ranked within each area, source and year (rn 1 = highest), for the top-4 share
ranked AS (
  SELECT d.*, row_number() OVER (PARTITION BY area_key, data_source_key, year ORDER BY value DESC, period_label) AS rn
  FROM dengue AS d
),

-- one row per area, source and year: annual cases, peak, top-4 cases and completeness
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

-- latest census population per area (used for every year, see header)
census AS (
  SELECT area_key, max_by(value, t.year) AS population, CAST(max(t.year) AS INT) AS population_year
  FROM public_health.gold.fact_area_indicator AS f
  INNER JOIN public_health.gold.dim_date AS t ON t.date_key = f.date_key
  WHERE f.indicator_name = 'population' AND f.indicator_category = 'census' AND f.value_status = 'ok'
  GROUP BY area_key
),

rated AS (
  SELECT p.*, c.population, c.population_year,
         CASE WHEN c.population > 0 THEN p.annual_cases / c.population * 100000 END AS annual_cases_per_100k,
         -- near-complete: a year short by one or two weeks (HDX source gaps, F14)
         -- still ranks for repeat high burden; the strict flag stays on peak_label
         (p.is_complete_year OR (p.period_grain = 'week' AND p.periods_reported >= 50)
                             OR (p.period_grain = 'month' AND p.periods_reported >= 12)) AS is_near_complete
  FROM per_year AS p
  LEFT JOIN census AS c ON c.area_key = p.area_key
),

-- high-burden year: top fifth of the annual rate within the source and year, counted from the top
high AS (
  SELECT r.*,
         CASE WHEN r.is_near_complete AND r.annual_cases_per_100k IS NOT NULL
              THEN percent_rank() OVER (PARTITION BY r.data_source_key, r.year, r.is_near_complete
                                        ORDER BY r.annual_cases_per_100k DESC) < 0.2 END AS is_high_burden_year
  FROM rated AS r
),

-- number of high-burden years per area and source
repeat_flag AS (
  SELECT h.*,
         count_if(h.is_high_burden_year) OVER (PARTITION BY h.area_key, h.data_source_key) AS high_burden_years
  FROM high AS h
),

-- recorded beds per planning unit (province excluding HUCs, each HUC, NCR)
beds_unit AS (
  SELECT planning_unit_key AS unit_key, sum(hospital_beds) AS beds, sum(hospitals_recorded) AS hospitals,
         max(registry_as_of_date) AS registry_as_of_date
  FROM public_health.gold.mart_locality_service_presence
  GROUP BY planning_unit_key
),

-- recorded beds per city or municipality
beds_locality AS (
  SELECT area_key, area_code, hospital_beds AS beds, hospitals_recorded AS hospitals, registry_as_of_date
  FROM public_health.gold.mart_locality_service_presence
),

-- beds of the cities an HDX province row lists apart (area_coverage_map.cities_included), so a
-- province row is compared with the beds of its own coverage, not of the whole unit
listed_apart AS (
  SELECT m.data_source_key, m.area_key, m.date_key, x.city_code
  FROM public_health.gold.area_coverage_map AS m
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

-- recorded beds per region
beds_region AS (
  SELECT region_key AS unit_key, sum(hospital_beds) AS beds, sum(hospitals_recorded) AS hospitals,
         max(registry_as_of_date) AS registry_as_of_date
  FROM public_health.gold.mart_locality_service_presence
  GROUP BY region_key
),

-- latest reported occupancy per area and coverage basis (restricted source, D-47)
occupancy AS (
  SELECT o.area_key, o.coverage_basis,
         CAST(max(t.year) AS INT) AS occupancy_year,
         max_by(o.bor_weighted_pct, t.year) AS bor_weighted_pct,
         max_by(o.bor_reporting_record_count, t.year) AS bor_reporting_record_count,
         max_by(o.value_status, t.year) AS occupancy_value_status
  FROM public_health.gold.fact_facility_capacity AS o
  INNER JOIN public_health.gold.dim_date AS t ON t.date_key = o.date_key
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
       -- HDX: the date closes its week (D-44), so show it as "week ending <date>"
       CASE WHEN r.period_basis = 'iso_week_ending_date' THEN concat('week ending ', r.peak_period_label)
            ELSE r.peak_period_label END                                               AS peak_period_label,
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
       -- coverage: regions compare as published; HDX rows follow area_coverage_map
       CASE WHEN g.geographic_level = 'region' THEN 'region_as_published' ELSE m.mapping_outcome END AS mapping_outcome,
       CASE WHEN g.geographic_level = 'region' THEN true
            ELSE m.mapping_outcome IN ('direct', 'aggregate') END                       AS comparison_eligible,
       CASE WHEN g.geographic_level = 'region' THEN 'Region compared with the registry beds of the same region'
            ELSE m.note END                                                            AS coverage_note,
       -- capacity today (registry snapshot), with the same coverage as the published row
       CASE g.geographic_level WHEN 'region' THEN b_r.hospitals WHEN 'city' THEN b_c.hospitals ELSE b_u.hospitals - coalesce(b_x.hospitals, 0) END AS hospitals_recorded,
       CASE g.geographic_level WHEN 'region' THEN b_r.beds WHEN 'city' THEN b_c.beds ELSE b_u.beds - coalesce(b_x.beds, 0) END AS hospital_beds_recorded,
       CASE g.geographic_level WHEN 'region' THEN 'region' WHEN 'city' THEN 'city itself'
            WHEN 'province' THEN CASE WHEN m.mapping_outcome = 'aggregate' THEN 'province excl. the cities listed apart'
                                      ELSE 'province excl. HUC (planning unit)' END END AS capacity_coverage,
       coalesce(b_u.registry_as_of_date, b_r.registry_as_of_date, b_c.registry_as_of_date) AS registry_as_of_date,
       -- relative pressure for ranking, not a bed demand; comparison_eligible rows with beds > 0 only
       CASE WHEN (CASE g.geographic_level WHEN 'region' THEN b_r.beds WHEN 'city' THEN b_c.beds ELSE b_u.beds - coalesce(b_x.beds, 0) END) > 0
             AND (g.geographic_level = 'region' OR m.mapping_outcome IN ('direct', 'aggregate'))
            THEN round(r.peak_cases / (CASE g.geographic_level WHEN 'region' THEN b_r.beds WHEN 'city' THEN b_c.beds ELSE b_u.beds - coalesce(b_x.beds, 0) END) * 100, 1) END AS peak_cases_per_100_beds,
       -- occupancy (latest year reported)
       o.occupancy_year,
       o.bor_weighted_pct,
       o.bor_reporting_record_count,
       o.occupancy_value_status
FROM repeat_flag AS r
INNER JOIN public_health.gold.dim_geography AS g ON g.area_key = r.area_key
LEFT JOIN public_health.gold.area_coverage_map AS m
  ON m.fact_table = 'fact_disease_metric' AND m.data_source_key = r.data_source_key
 AND m.area_key = r.area_key AND m.date_key = xxhash64('calendar_year', CAST(r.year AS STRING))
LEFT JOIN beds_unit AS b_u ON g.geographic_level = 'province' AND b_u.unit_key = g.planning_unit_key
LEFT JOIN beds_region AS b_r ON g.geographic_level = 'region' AND b_r.unit_key = r.area_key
LEFT JOIN beds_locality AS b_c ON g.geographic_level = 'city' AND b_c.area_key = r.area_key
LEFT JOIN beds_listed_apart AS b_x
  ON g.geographic_level = 'province' AND b_x.data_source_key = r.data_source_key
 AND b_x.area_key = r.area_key AND b_x.date_key = xxhash64('calendar_year', CAST(r.year AS STRING))
-- a city takes its own occupancy row, whatever its coverage_basis
LEFT JOIN occupancy AS o
  ON o.area_key = r.area_key
 AND o.coverage_basis = CASE g.geographic_level WHEN 'province' THEN 'province_excl_huc'
                                                WHEN 'region' THEN 'region'
                                                ELSE o.coverage_basis END;


-- Checks after creating the view.
-- 1. Rows per source. Expect HDX about 81 provinces + the listed cities x 6 years, UP NOAH
--    17 regions x 8 years, DOH FOI 18 regions x 5 years. eligible < area_years for HDX shows
--    the not_separable provinces (a HUC the source does not list apart).
SELECT source_dataset, period_grain, count(*) AS area_years, count(DISTINCT area_key) AS areas,
       count_if(is_complete_year) AS complete_years, count_if(comparison_eligible) AS eligible,
       count_if(peak_cases_per_100_beds IS NOT NULL) AS with_capacity_ratio,
       count_if(bor_weighted_pct IS NOT NULL) AS with_occupancy
FROM public_health.gold.mart_dengue_peak_capacity
GROUP BY source_dataset, period_grain ORDER BY source_dataset;

-- 2. The core answer, one source at a time: largest peaks relative to recorded beds.
--    HDX compares provinces. Its peak weeks from 2018 run 1-2 weeks late (D-45).
SELECT area_name, year, peak_label, peak_period_label, peak_cases, hospital_beds_recorded,
       peak_cases_per_100_beds, bor_weighted_pct, occupancy_year, repeat_high_burden
FROM public_health.gold.mart_dengue_peak_capacity
WHERE source_dataset = 'hdx_dengue' AND comparison_eligible
ORDER BY peak_cases_per_100_beds DESC
LIMIT 20;

-- 3. Key check. Expect no row. A row means a city matched two occupancy rows (two
--    coverage_basis values): fix the city branch of the occupancy join.
SELECT area_key, data_source_key, year, count(*) AS rows_per_key
FROM public_health.gold.mart_dengue_peak_capacity
GROUP BY area_key, data_source_key, year
HAVING count(*) > 1;