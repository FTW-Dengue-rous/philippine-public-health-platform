-- ========================================
-- Creates the view public_health.test_gold2.mart_kidney_case_study
--   One row is: one province (or NCR) as IHME publishes it
--   Key: (kidney_unit_key, unit_basis)
--   Answers: K1. Which provinces have high estimated chronic kidney disease mortality but few
--   dialysis stations recorded per population?
--   Story placement: SPECIALIST TREATMENT CAPACITY (dialysis is treatment, not prevention;
--   review point 5, 2026-10-14 night). Prevention is the TB case study (61).
-- Data model v2: gold_62 (v1) rewritten for the v2 tables.
--   v1 -> v2: fact_area_facility_capacity_snapshot -> fact_facility_capacity WHERE
--   capacity_basis = 'registry_snapshot' (dialysis columns unchanged); dim_period -> dim_date
--   (snapshot period = max period_start_date of period_basis snapshot); dim_source ->
--   dim_data_source.
--
-- Reads: mart_locality_service_presence, huc_province_crosswalk, dim_disease, dim_geography,
--        dim_date, dim_data_source, fact_disease_metric, fact_facility_capacity
--
-- Unit of each row (unit_basis)
--   planning  the province has no highly urbanized city (HUC), or the row is NCR. The province
--             is the planning unit, so the open coverage question does not change it.
--   broad     the province has one or more HUCs. Population and dialysis stations are those of
--             the province PLUS its HUCs, because IHME provinces are ASSUMED to include them
--             (decision D5, not confirmed).
--
-- Rules
--   * Burden = IHME modelled deaths from chronic kidney disease (cause ihme_589), latest year,
--     with its bounds. Modelled, never mixed with registered deaths. IHME attribution on charts.
--   * Dialysis = registry facilities with a recorded station count (hospital-based and
--     free-standing) and free-standing clinics without one. A hospital with no station count
--     is not counted: the registry does not say it has a dialysis unit.
--   * Missing is not zero. dialysis_stations_reported is null when no facility of the unit has
--     a station count. has_dialysis_facility_recorded says whether any is listed at all.
--   * Rates use the census population of the unit's cities and municipalities.
--
-- The two gates of the proposal
--   1. Station completeness: at least 80 percent of the unit's dialysis facilities have a
--      station count (PROPOSED threshold), or no dialysis facility is recorded.
--   2. Geographic match: unit_basis = planning. A broad row stays comparison_eligible = false
--      until IHME confirms that its provinces include their HUCs. To switch after the
--      confirmation, change ihme_includes_huc_confirmed below to true.
--   A row that fails a gate keeps all its numbers. exclusion_reason says which gate.
--
-- Not in the list: undivided Maguindanao (hist:maguindanao). IHME still publishes it, the
-- registry and the census use its two successor provinces.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold2.mart_kidney_case_study AS
WITH settings AS (
  SELECT false AS ihme_includes_huc_confirmed, 0.8 AS min_stations_known_share
),

burden_rows AS (
  SELECT f.area_key, CAST(t.year AS INT) AS year, f.value, f.value_lower, f.value_upper,
         max(t.year) OVER () AS latest_year
  FROM public_health.test_gold2.fact_disease_metric AS f
  INNER JOIN public_health.test_gold2.dim_disease AS d ON d.disease_key = f.disease_key AND d.disease_code = 'ihme_589'
  INNER JOIN public_health.test_gold2.dim_data_source AS s
    ON s.data_source_key = f.data_source_key AND s.source_dataset = 'ihme_gbd'
  INNER JOIN public_health.test_gold2.dim_date AS t ON t.date_key = f.date_key AND t.period_grain = 'year'
  WHERE f.metric_name = 'deaths' AND f.age_group = 'all_ages' AND f.sex = 'both_sexes' AND f.value_status = 'ok'
),

unit AS (
  SELECT b.area_key AS kidney_unit_key, g.area_code, g.area_name, g.region_key,
         b.year AS burden_year, b.value, b.value_lower, b.value_upper,
         coalesce(h.hucs, 0) AS hucs
  FROM burden_rows AS b
  INNER JOIN public_health.test_gold2.dim_geography AS g
    ON g.area_key = b.area_key AND (g.geographic_level = 'province' OR g.area_code = 'psgc:1300000000')
  LEFT JOIN (SELECT province_area_key, count(*) AS hucs
             FROM public_health.test_gold2.huc_province_crosswalk
             WHERE match_status = 'matched'
             GROUP BY province_area_key) AS h ON h.province_area_key = b.area_key
  WHERE b.year = b.latest_year
),

-- Cities and municipalities of each unit: its own, plus the HUCs of the province
unit_locality AS (
  SELECT planning_unit_key AS kidney_unit_key, area_key
  FROM public_health.test_gold2.mart_locality_service_presence
  UNION ALL
  SELECT province_area_key, huc_area_key
  FROM public_health.test_gold2.huc_province_crosswalk
  WHERE match_status = 'matched'
),

people AS (
  SELECT ul.kidney_unit_key,
         CASE WHEN count(l.population) = count(*) AND count(DISTINCT l.population_year) = 1 THEN sum(l.population) END
           AS population,
         max(l.population_year) AS population_year,
         max(l.registry_as_of_date) AS registry_as_of_date
  FROM unit_locality AS ul
  INNER JOIN public_health.test_gold2.mart_locality_service_presence AS l ON l.area_key = ul.area_key
  GROUP BY ul.kidney_unit_key
),

snapshot AS (
  SELECT max_by(date_key, period_start_date) AS date_key
  FROM public_health.test_gold2.dim_date
  WHERE period_basis = 'snapshot'
),

dialysis AS (
  SELECT ul.kidney_unit_key,
         sum(c.dialysis_facilities_stations_known) AS stations_known,
         sum(c.dialysis_facilities_stations_unknown) AS stations_unknown,
         sum(c.dialysis_stations) AS stations,
         sum(CASE WHEN c.facility_category = 'hospital' THEN c.dialysis_stations END) AS stations_hospital,
         sum(CASE WHEN c.facility_category = 'dialysis_clinic' THEN c.dialysis_stations END) AS stations_freestanding
  FROM unit_locality AS ul
  INNER JOIN public_health.test_gold2.fact_facility_capacity AS c ON c.area_key = ul.area_key
  INNER JOIN snapshot AS s ON s.date_key = c.date_key
  WHERE c.capacity_basis = 'registry_snapshot' AND c.facility_category IN ('hospital', 'dialysis_clinic')
  GROUP BY ul.kidney_unit_key
),

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


SELECT unit_basis, coalesce(exclusion_reason, 'comparable') AS status, count(*) AS units,
       count(dialysis_stations_reported) AS with_station_count,
       count_if(NOT has_dialysis_facility_recorded) AS without_dialysis_facility_recorded
FROM public_health.test_gold2.mart_kidney_case_study
GROUP BY unit_basis, coalesce(exclusion_reason, 'comparable')
ORDER BY unit_basis, units DESC;

-- K1 answer among comparable units: high CKD mortality, few stations
SELECT area_name, ckd_deaths_per_100k, dialysis_stations_per_100k, dialysis_facilities, stations_known_share
FROM public_health.test_gold2.mart_kidney_case_study
WHERE comparison_eligible
ORDER BY ckd_deaths_per_100k DESC, dialysis_stations_per_100k
LIMIT 20;