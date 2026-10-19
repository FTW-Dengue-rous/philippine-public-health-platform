-- ========================================
-- gold_22_mart_kidney_case_study.sql
-- Creates the view public_health.gold.mart_kidney_case_study
--   One row is: one province (or NCR), as IHME publishes it
--   Key: (kidney_unit_key, unit_basis). unit_basis follows from the key, one value per unit.
--   Answers: K1. Which provinces have high estimated chronic kidney disease mortality but few
--   dialysis stations recorded per population?
--   Story placement: SPECIALIST TREATMENT CAPACITY. Dialysis is treatment, not prevention
--   (review point 5, 2026-10-14 night). Prevention is the TB case study (gold 21).
-- Previous file name: gold_v2_62_mart_kidney_case_study.sql (gold_62 in v1, rewritten for the
--   v2 tables: fact_facility_capacity with capacity_basis = 'registry_snapshot', dim_date,
--   dim_data_source).
--
-- Reads: mart_locality_service_presence (gold 14), huc_province_crosswalk (gold 11),
--        dim_disease, dim_geography, dim_date, dim_data_source, fact_disease_metric (gold 07),
--        fact_facility_capacity (gold 06)
--
-- Unit of each row (unit_basis)
--   planning  the province has no highly urbanized city (HUC), or the row is NCR. The IHME
--             province is the planning unit.
--   broad     the province has one or more HUCs. IHME province estimates include their HUCs
--             (D-42), so population and dialysis stations are those of the province PLUS its
--             HUCs. The row is the broad unit, not a planning unit (mapping_outcome =
--             not_separable).
--
-- Rules
--   * Burden = IHME modelled deaths from chronic kidney disease (cause ihme_589), all ages, both
--     sexes, latest year, with its bounds. Only value_status = 'ok' rows. Modelled: never mixed
--     with registered deaths.
--   * IHME licence: no row-level export. Put the IHME attribution line on every chart.
--   * Dialysis = registry facilities (latest snapshot) with a recorded station count
--     (hospital-based and free-standing), and free-standing clinics without one. A hospital
--     with no station count is not counted: the registry does not say it has a dialysis unit.
--   * Missing is not zero. dialysis_stations_reported is null when no facility of the unit has
--     a station count. has_dialysis_facility_recorded says whether any dialysis facility is
--     listed at all.
--   * Population = sum of the census population of the unit's cities and municipalities. It is
--     null when any locality lacks a population or the localities have different census years.
--   * Rates are per 100,000 population.
--
-- Comparison gates. A row that fails a gate keeps all its numbers. exclusion_reason names the
-- first failed gate, in this order:
--   1. Population: the unit has a population (no_population).
--   2. Alignment window: burden year and census year at most 2 years apart
--      (outside_alignment_window).
--   3. Geographic match: unit_basis = planning, or ihme_includes_huc_confirmed = true
--      (ihme_province_coverage_not_confirmed).
--   4. Station completeness: at least 80 percent of the unit's dialysis facilities have a
--      station count, or no dialysis facility is recorded (station_counts_incomplete).
--      80 percent is a data-quality gate agreed by the team (D-56): stations per 100,000 is
--      not compared when more than a fifth of a unit's dialysis facilities have no station
--      count. Evidence: gold_o13_evidence.sql Q3/Q4 (comparable units at 70/80/90%).
--
-- SETTING (D-42). D-42 confirmed that IHME provinces include their HUCs, so
-- ihme_includes_huc_confirmed is true. Broad rows pass gate 3 and are compared at the broad unit
-- (province plus its HUCs). The reason ihme_province_coverage_not_confirmed no longer appears.
-- Set it back to false only if D-42 is reversed.
--
-- Not in the view: undivided Maguindanao (hist:maguindanao). IHME still publishes it, but it is
-- a named key, not a province, in dim_geography. The registry and the census use its two
-- successor provinces.
--
-- History
--   2026-10-14  Written for data model v2 (from gold_62, v1).
--   2026-10-18  Moved to public_health.gold and renamed gold_22. Comments updated for D-42.
--               ihme_includes_huc_confirmed set to true (D-42): broad rows can now be
--               comparison_eligible.
--   2026-10-20  Reason for the 80% gate recorded from D-56 (closes O-13). No logic change.
-- ========================================

CREATE OR REPLACE VIEW public_health.gold.mart_kidney_case_study AS
-- settings: geographic-match switch (D-42, see SETTING) and the station completeness threshold
WITH settings AS (
  SELECT true AS ihme_includes_huc_confirmed, 0.8 AS min_stations_known_share
),

-- IHME CKD deaths, all ages, both sexes, with the latest year of the source
burden_rows AS (
  SELECT f.area_key, CAST(t.year AS INT) AS year, f.value, f.value_lower, f.value_upper,
         max(t.year) OVER () AS latest_year
  FROM public_health.gold.fact_disease_metric AS f
  INNER JOIN public_health.gold.dim_disease AS d ON d.disease_key = f.disease_key AND d.disease_code = 'ihme_589'
  INNER JOIN public_health.gold.dim_data_source AS s
    ON s.data_source_key = f.data_source_key AND s.source_dataset = 'ihme_gbd'
  INNER JOIN public_health.gold.dim_date AS t ON t.date_key = f.date_key AND t.period_grain = 'year'
  WHERE f.metric_name = 'deaths' AND f.age_group = 'all_ages' AND f.sex = 'both_sexes' AND f.value_status = 'ok'
),

-- one row per IHME province (or NCR) in the latest year, with its number of matched HUCs
unit AS (
  SELECT b.area_key AS kidney_unit_key, g.area_code, g.area_name, g.region_key,
         b.year AS burden_year, b.value, b.value_lower, b.value_upper,
         coalesce(h.hucs, 0) AS hucs
  FROM burden_rows AS b
  INNER JOIN public_health.gold.dim_geography AS g
    ON g.area_key = b.area_key AND (g.geographic_level = 'province' OR g.area_code = 'psgc:1300000000')
  LEFT JOIN (SELECT province_area_key, count(*) AS hucs
             FROM public_health.gold.huc_province_crosswalk
             WHERE match_status = 'matched'
             GROUP BY province_area_key) AS h ON h.province_area_key = b.area_key
  WHERE b.year = b.latest_year
),

-- Cities and municipalities of each unit: its own, plus the HUCs of the province
unit_locality AS (
  SELECT planning_unit_key AS kidney_unit_key, area_key
  FROM public_health.gold.mart_locality_service_presence
  UNION ALL
  SELECT province_area_key, huc_area_key
  FROM public_health.gold.huc_province_crosswalk
  WHERE match_status = 'matched'
),

-- population per unit: null unless every locality has one, all from the same census year
people AS (
  SELECT ul.kidney_unit_key,
         CASE WHEN count(l.population) = count(*) AND count(DISTINCT l.population_year) = 1 THEN sum(l.population) END
           AS population,
         max(l.population_year) AS population_year,
         max(l.registry_as_of_date) AS registry_as_of_date
  FROM unit_locality AS ul
  INNER JOIN public_health.gold.mart_locality_service_presence AS l ON l.area_key = ul.area_key
  GROUP BY ul.kidney_unit_key
),

-- the latest snapshot date in dim_date
snapshot AS (
  SELECT max_by(date_key, period_start_date) AS date_key
  FROM public_health.gold.dim_date
  WHERE period_basis = 'snapshot'
),

-- dialysis facilities and stations per unit, from the registry snapshot
dialysis AS (
  SELECT ul.kidney_unit_key,
         sum(c.dialysis_facilities_stations_known) AS stations_known,
         sum(c.dialysis_facilities_stations_unknown) AS stations_unknown,
         sum(c.dialysis_stations) AS stations,
         sum(CASE WHEN c.facility_category = 'hospital' THEN c.dialysis_stations END) AS stations_hospital,
         sum(CASE WHEN c.facility_category = 'dialysis_clinic' THEN c.dialysis_stations END) AS stations_freestanding
  FROM unit_locality AS ul
  INNER JOIN public_health.gold.fact_facility_capacity AS c ON c.area_key = ul.area_key
  INNER JOIN snapshot AS s ON s.date_key = c.date_key
  WHERE c.capacity_basis = 'registry_snapshot' AND c.facility_category IN ('hospital', 'dialysis_clinic')
  GROUP BY ul.kidney_unit_key
),

-- burden, population and dialysis per unit; unit_basis from the HUC count
joined AS (
  SELECT u.*, p.population, p.population_year, p.registry_as_of_date,
         coalesce(d.stations_known, 0) AS stations_known, coalesce(d.stations_unknown, 0) AS stations_unknown,
         d.stations, d.stations_hospital, d.stations_freestanding,
         CASE WHEN u.hucs > 0 THEN 'broad' ELSE 'planning' END AS unit_basis,
         s.ihme_includes_huc_confirmed, s.min_stations_known_share
  FROM unit AS u
  CROSS JOIN settings AS s
  LEFT JOIN people AS p ON p.kidney_unit_key = u.kidney_unit_key
  LEFT JOIN dialysis AS d ON d.kidney_unit_key = u.kidney_unit_key
),

-- station completeness: share of dialysis facilities with a station count (null = none recorded)
checked AS (
  SELECT j.*,
         j.stations_known + j.stations_unknown AS dialysis_facilities,
         CASE WHEN j.stations_known + j.stations_unknown > 0
              THEN j.stations_known / (j.stations_known + j.stations_unknown) END AS stations_known_share
  FROM joined AS j
)

SELECT kidney_unit_key,
       unit_basis,
       area_name,
       region_key,
       value AS ckd_deaths,
       value_lower AS ckd_deaths_lower,
       value_upper AS ckd_deaths_upper,
       CASE WHEN population > 0 THEN round(CAST(value AS DOUBLE) * 100000.0 / population, 2) END AS ckd_deaths_per_100k,
       burden_year,
       dialysis_facilities,
       stations_known AS dialysis_facilities_stations_known,
       stations_unknown AS dialysis_facilities_stations_unknown,
       stations AS dialysis_stations_reported,
       stations_hospital AS dialysis_stations_hospital,
       stations_freestanding AS dialysis_stations_freestanding,
       CASE WHEN population > 0 THEN round(stations * 100000.0 / population, 2) END AS dialysis_stations_per_100k,
       registry_as_of_date,
       population,
       population_year,
       CASE WHEN unit_basis = 'planning' THEN 'direct' ELSE 'not_separable' END AS mapping_outcome,
       -- the four gates of the header
       (population IS NOT NULL
        AND abs(burden_year - population_year) <= 2
        AND coalesce(stations_known_share >= min_stations_known_share, true)
        AND (unit_basis = 'planning' OR ihme_includes_huc_confirmed)) AS comparison_eligible,
       CASE WHEN population IS NULL THEN 'no_population'
            WHEN abs(burden_year - population_year) > 2 THEN 'outside_alignment_window'
            WHEN unit_basis = 'broad' AND NOT ihme_includes_huc_confirmed THEN 'ihme_province_coverage_not_confirmed'
            WHEN stations_known_share < min_stations_known_share THEN 'station_counts_incomplete'
       END AS exclusion_reason,
       area_code,
       (dialysis_facilities > 0) AS has_dialysis_facility_recorded,
       round(stations_known_share, 3) AS stations_known_share
FROM checked;


-- Checks after creating the view.
-- 1. Units by basis and status. Expect no ihme_province_coverage_not_confirmed rows (D-42).
--    Broad rows now show comparable, or another gate's reason.
SELECT unit_basis, coalesce(exclusion_reason, 'comparable') AS status, count(*) AS units,
       count(dialysis_stations_reported) AS with_station_count,
       count_if(NOT has_dialysis_facility_recorded) AS without_dialysis_facility_recorded
FROM public_health.gold.mart_kidney_case_study
GROUP BY unit_basis, coalesce(exclusion_reason, 'comparable')
ORDER BY unit_basis, units DESC;

-- 2. K1 answer among comparable units: high CKD mortality, few stations
SELECT area_name, ckd_deaths_per_100k, dialysis_stations_per_100k, dialysis_facilities, stations_known_share
FROM public_health.gold.mart_kidney_case_study
WHERE comparison_eligible
ORDER BY ckd_deaths_per_100k DESC, dialysis_stations_per_100k
LIMIT 20;