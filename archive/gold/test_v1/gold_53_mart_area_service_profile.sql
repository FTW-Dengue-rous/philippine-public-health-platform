-- ========================================
-- Creates the view public_health.test_gold.mart_area_service_profile
--   One row is: one planning unit, with its supply, workforce and poverty indicators
--   Key: planning_unit_key
--   Answers: S1, S3, A2, W1, W2, E1, E2
--
-- Reads: mart_base_planning_unit, mart_locality_service_presence, area_coverage_map,
--        dim_geography, dim_period, dim_profession, fact_area_facility_capacity_snapshot,
--        fact_facility_published, fact_population, fact_workforce, fact_poverty
--
-- Rules
--   * Hospitals, beds and licensed primary care come from the registry, summed over the
--     unit's cities and municipalities. A unit with no hospital recorded has 0 beds.
--     population_without_... adds only localities that have a census count.
--   * FHSIS counts (BHS, health centres, workforce) and poverty are published by province or
--     city. They reach a unit only through area_coverage_map: a direct row, or all the parts
--     of an aggregate. A unit with a missing or not eligible part gets null, never a part sum.
--   * Each indicator keeps its own year: workforce_year (latest year in which doctors, nurses
--     and midwives are all usable), bhw_year (latest usable BHW total; 2025 has none, it prints
--     LGU-hired only), fhsis_count_year (latest usable BHS counts and FHSIS population),
--     poverty_year (latest comparison-eligible estimate).
--   * Rates use the census population of the unit. The two FHSIS facility rates use the
--     population printed in the same FHSIS workbook.
--   * Alignment window = 2 years (open decision 7): a rate is null when its count year and
--     the population year are further apart.
--   * Poverty incidence is a published percentage: from a direct row only, never summed or
--     averaged. A province whose estimate includes its HUC is not used.
--   * Quintile 1 = lowest, 5 = highest, among units with the value. Equal values share one.
--   * poverty_band limits (10, 20, 30 percent) are a PROPOSAL for the team.
--
-- Added to the v3 list: area_code and the "extra columns" at the end of the SELECT.
-- Names follow model v3.1 (region_key). A view has no _gold_build_id.
--
-- CONFIRM on Databricks: ownership = 'government' is the literal in the fact.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold.mart_area_service_profile AS
WITH registry AS (
  SELECT planning_unit_key,
         sum(hospitals_recorded) AS hospitals,
         sum(hospital_beds) AS beds,
         sum(hospitals_without_bed_count) AS hospitals_without_bed_count,
         max(highest_hospital_level) AS highest_hospital_level,
         count_if(NOT has_hospital_recorded) AS localities_without_hospital,
         coalesce(sum(CASE WHEN NOT has_hospital_recorded THEN population END), 0) AS population_without_hospital,
         sum(licensed_primary_care_facilities_recorded) AS licensed_primary_care,
         count_if(NOT has_licensed_primary_care_recorded) AS localities_without_primary_care,
         coalesce(sum(CASE WHEN NOT has_licensed_primary_care_recorded THEN population END), 0)
           AS population_without_primary_care,
         max(registry_as_of_date) AS registry_as_of_date
  FROM public_health.test_gold.mart_locality_service_presence
  GROUP BY planning_unit_key
),

by_level AS (
  SELECT g.planning_unit_key,
         sum(CASE WHEN c.hospital_level = 'Level 1' THEN c.analysis_beds END) AS beds_level1,
         sum(CASE WHEN c.hospital_level = 'Level 2' THEN c.analysis_beds END) AS beds_level2,
         sum(CASE WHEN c.hospital_level = 'Level 3' THEN c.analysis_beds END) AS beds_level3,
         sum(CASE WHEN c.ownership = 'government' THEN c.analysis_beds END) AS government_beds,
         sum(CASE WHEN c.hospital_level = 'Level 3' THEN c.facility_count END) AS level3_hospitals
  FROM public_health.test_gold.fact_area_facility_capacity_snapshot AS c
  INNER JOIN public_health.test_gold.dim_geography AS g ON g.area_key = c.area_key
  WHERE c.facility_category = 'hospital'
    AND c.period_key = (SELECT max_by(period_key, period_start_date)
                        FROM public_health.test_gold.dim_period WHERE period_basis = 'snapshot')
  GROUP BY g.planning_unit_key
),

-- is_complete = every part of the unit present and usable
workforce AS (
  SELECT m.planning_unit_key, m.year, pr.profession_code,
         (count(*) = max(m.unit_parts_expected)
          AND count_if(w.analysis_eligible AND w.headcount_total IS NOT NULL) = count(*)) AS is_complete,
         count(*) AS parts,
         sum(w.headcount_total) AS headcount,
         sum(w.headcount_doh_hired) AS headcount_doh,
         count_if(w.headcount_doh_hired IS NOT NULL AND w.headcount_lgu_hired IS NOT NULL) AS parts_with_split,
         max(w.exclusion_reason) AS exclusion_reason
  FROM public_health.test_gold.fact_workforce AS w
  INNER JOIN public_health.test_gold.area_coverage_map AS m
    ON m.fact_table = 'fact_workforce' AND m.source_key = w.source_key AND m.area_key = w.area_key
   AND m.period_key = w.period_key AND m.geo_coverage_basis <=> w.coverage_basis
   AND m.mapping_outcome IN ('direct', 'aggregate')
  INNER JOIN public_health.test_gold.dim_profession AS pr ON pr.profession_key = w.profession_key
  WHERE m.source_dataset = 'doh_fhsis_demographic'
    AND coalesce(w.source_role, 'preferred') = 'preferred'
    AND pr.profession_code IN ('doctors', 'nurses', 'midwives', 'bhw')
  GROUP BY m.planning_unit_key, m.year, pr.profession_code
),

core_year AS (
  SELECT planning_unit_key, max(year) AS workforce_year
  FROM (SELECT planning_unit_key, year
        FROM workforce
        WHERE profession_code <> 'bhw' AND is_complete
        GROUP BY planning_unit_key, year
        HAVING count(*) = 3) AS complete_years
  GROUP BY planning_unit_key
),

core AS (
  SELECT w.planning_unit_key, w.year AS workforce_year,
         max(CASE WHEN w.profession_code = 'doctors' THEN w.headcount END) AS doctors,
         max(CASE WHEN w.profession_code = 'nurses' THEN w.headcount END) AS nurses,
         max(CASE WHEN w.profession_code = 'midwives' THEN w.headcount END) AS midwives,
         CASE WHEN sum(w.parts_with_split) = sum(w.parts) AND sum(w.headcount) > 0
              THEN sum(w.headcount_doh) / sum(w.headcount) END AS doh_deployed_share,
         CASE WHEN max(w.parts) > 1 THEN 'aggregate' ELSE 'direct' END AS mapping_outcome
  FROM workforce AS w
  INNER JOIN core_year AS y ON y.planning_unit_key = w.planning_unit_key AND y.workforce_year = w.year
  WHERE w.profession_code <> 'bhw'
  GROUP BY w.planning_unit_key, w.year
),

bhw AS (
  SELECT planning_unit_key, max(year) AS bhw_year, max_by(headcount, year) AS bhw
  FROM workforce
  WHERE profession_code = 'bhw' AND is_complete
  GROUP BY planning_unit_key
),

-- Why a unit has no workforce value
workforce_gap AS (
  SELECT planning_unit_key,
         max_by(coalesce(exclusion_reason, 'part_missing'), year) FILTER (WHERE profession_code <> 'bhw') AS core_reason,
         max_by(coalesce(exclusion_reason, 'part_missing'), year) FILTER (WHERE profession_code = 'bhw') AS bhw_reason
  FROM workforce
  WHERE NOT is_complete
  GROUP BY planning_unit_key
),

fhsis_facilities AS (
  SELECT m.planning_unit_key, m.year, f.facility_type,
         (count(*) = max(m.unit_parts_expected) AND count(f.published_facility_count) = count(*)) AS is_complete,
         count(*) AS parts,
         sum(f.published_facility_count) AS facilities
  FROM public_health.test_gold.fact_facility_published AS f
  INNER JOIN public_health.test_gold.area_coverage_map AS m
    ON m.fact_table = 'fact_facility_published' AND m.source_key = f.source_key AND m.area_key = f.area_key
   AND m.period_key = f.period_key AND m.geo_coverage_basis <=> f.coverage_basis
   AND m.mapping_outcome IN ('direct', 'aggregate')
  WHERE m.source_dataset = 'doh_fhsis_demographic' AND f.ownership = 'total'
    AND f.facility_type IN ('bhs', 'health_centers_total')
  GROUP BY m.planning_unit_key, m.year, f.facility_type
),

fhsis_population AS (
  SELECT m.planning_unit_key, m.year,
         (count(*) = max(m.unit_parts_expected) AND count(f.population) = count(*)) AS is_complete,
         count(*) AS parts,
         sum(f.population) AS population
  FROM public_health.test_gold.fact_population AS f
  INNER JOIN public_health.test_gold.area_coverage_map AS m
    ON m.fact_table = 'fact_population' AND m.source_key = f.source_key AND m.area_key = f.area_key
   AND m.period_key = f.period_key AND m.geo_coverage_basis <=> f.coverage_basis
   AND m.mapping_outcome IN ('direct', 'aggregate')
  WHERE f.population_type = 'reported' AND m.source_dataset = 'doh_fhsis_demographic'
  GROUP BY m.planning_unit_key, m.year
),

-- BHS and FHSIS population: complete in the same year, same number of parts
fhsis_year AS (
  SELECT b.planning_unit_key, max(b.year) AS fhsis_count_year
  FROM fhsis_facilities AS b
  INNER JOIN fhsis_population AS p ON p.planning_unit_key = b.planning_unit_key AND p.year = b.year
  WHERE b.facility_type = 'bhs' AND b.is_complete AND p.is_complete AND p.parts = b.parts
  GROUP BY b.planning_unit_key
),

fhsis AS (
  SELECT y.planning_unit_key, y.fhsis_count_year,
         max(CASE WHEN f.facility_type = 'bhs' THEN f.facilities END) AS reported_bhs,
         max(CASE WHEN f.facility_type = 'health_centers_total' AND f.is_complete THEN f.facilities END)
           AS reported_health_centers,
         max(p.population) AS fhsis_reported_population,
         CASE WHEN max(p.parts) > 1 THEN 'aggregate' ELSE 'direct' END AS mapping_outcome
  FROM fhsis_year AS y
  INNER JOIN fhsis_facilities AS f ON f.planning_unit_key = y.planning_unit_key AND f.year = y.fhsis_count_year
  INNER JOIN fhsis_population AS p ON p.planning_unit_key = y.planning_unit_key AND p.year = y.fhsis_count_year
  GROUP BY y.planning_unit_key, y.fhsis_count_year
),

fhsis_seen AS (SELECT DISTINCT planning_unit_key FROM fhsis_facilities),

poverty AS (
  SELECT m.planning_unit_key,
         max(m.year) AS poverty_year,
         max_by(f.poverty_incidence_pct, m.year) AS poverty_incidence_pct
  FROM public_health.test_gold.fact_poverty AS f
  INNER JOIN public_health.test_gold.area_coverage_map AS m
    ON m.fact_table = 'fact_poverty' AND m.source_key = f.source_key AND m.area_key = f.area_key
   AND m.period_key = f.period_key AND m.geo_coverage_basis <=> f.coverage_basis
  WHERE m.mapping_outcome = 'direct' AND f.comparison_eligible AND f.poverty_incidence_pct IS NOT NULL
  GROUP BY m.planning_unit_key
),

-- Why a unit has no poverty value
poverty_gap AS (
  SELECT f.area_key AS planning_unit_key,
         max_by(coalesce(f.exclusion_reason, m.mapping_outcome), m.year) AS reason
  FROM public_health.test_gold.fact_poverty AS f
  INNER JOIN public_health.test_gold.area_coverage_map AS m
    ON m.fact_table = 'fact_poverty' AND m.source_key = f.source_key AND m.area_key = f.area_key
   AND m.period_key = f.period_key AND m.geo_coverage_basis <=> f.coverage_basis
  WHERE NOT (m.mapping_outcome = 'direct' AND f.comparison_eligible AND f.poverty_incidence_pct IS NOT NULL)
  GROUP BY f.area_key
),

joined AS (
  SELECT u.planning_unit_key, u.area_code, u.area_name, u.region_key, u.unit_level, u.income_class,
         u.population, u.population_year, u.population_source_key, u.localities, u.localities_without_population,
         r.hospitals, r.beds, r.hospitals_without_bed_count, r.highest_hospital_level,
         r.localities_without_hospital, r.population_without_hospital, r.licensed_primary_care,
         r.localities_without_primary_care, r.population_without_primary_care, r.registry_as_of_date,
         l.beds_level1, l.beds_level2, l.beds_level3, l.government_beds, l.level3_hospitals,
         f.reported_bhs, f.reported_health_centers, f.fhsis_reported_population, f.fhsis_count_year,
         f.mapping_outcome AS fhsis_mapping_outcome,
         CASE WHEN f.planning_unit_key IS NOT NULL THEN NULL
              WHEN s.planning_unit_key IS NULL THEN 'no_source_row'
              ELSE 'fhsis_counts_or_population_incomplete' END AS fhsis_exclusion_reason,
         c.doctors, c.nurses, c.midwives, c.doh_deployed_share, c.workforce_year,
         c.mapping_outcome AS workforce_mapping_outcome,
         CASE WHEN c.planning_unit_key IS NULL THEN coalesce(g.core_reason, 'no_source_row') END
           AS workforce_exclusion_reason,
         b.bhw, b.bhw_year,
         CASE WHEN b.planning_unit_key IS NULL THEN coalesce(g.bhw_reason, 'no_source_row') END AS bhw_exclusion_reason,
         p.poverty_incidence_pct, p.poverty_year,
         CASE WHEN p.planning_unit_key IS NOT NULL THEN NULL
              WHEN pg.reason IS NOT NULL THEN pg.reason
              WHEN u.unit_level = 'HUC' THEN 'published_only_inside_the_province_estimate'
              ELSE 'no_source_row' END AS poverty_exclusion_reason,
         -- alignment window
         (abs(year(r.registry_as_of_date) - u.population_year) <= 2) AS registry_in_window,
         (abs(c.workforce_year - u.population_year) <= 2) AS workforce_in_window,
         (abs(b.bhw_year - u.population_year) <= 2) AS bhw_in_window
  FROM public_health.test_gold.mart_base_planning_unit AS u
  LEFT JOIN registry AS r ON r.planning_unit_key = u.planning_unit_key
  LEFT JOIN by_level AS l ON l.planning_unit_key = u.planning_unit_key
  LEFT JOIN fhsis AS f ON f.planning_unit_key = u.planning_unit_key
  LEFT JOIN fhsis_seen AS s ON s.planning_unit_key = u.planning_unit_key
  LEFT JOIN core AS c ON c.planning_unit_key = u.planning_unit_key
  LEFT JOIN bhw AS b ON b.planning_unit_key = u.planning_unit_key
  LEFT JOIN workforce_gap AS g ON g.planning_unit_key = u.planning_unit_key
  LEFT JOIN poverty AS p ON p.planning_unit_key = u.planning_unit_key
  LEFT JOIN poverty_gap AS pg ON pg.planning_unit_key = u.planning_unit_key
),

rated AS (
  SELECT j.*,
         CASE WHEN j.registry_in_window AND j.population > 0 THEN j.beds * 10000.0 / j.population END AS beds_per_10k,
         CASE WHEN j.fhsis_reported_population > 0
              THEN j.reported_bhs * 10000.0 / j.fhsis_reported_population END AS reported_bhs_per_10k,
         CASE WHEN j.fhsis_reported_population > 0
              THEN j.reported_health_centers * 10000.0 / j.fhsis_reported_population END AS reported_health_centers_per_10k,
         CASE WHEN j.workforce_in_window AND j.population > 0 THEN j.doctors * 10000.0 / j.population END AS doctors_per_10k,
         CASE WHEN j.workforce_in_window AND j.population > 0 THEN j.nurses * 10000.0 / j.population END AS nurses_per_10k,
         CASE WHEN j.workforce_in_window AND j.population > 0 THEN j.midwives * 10000.0 / j.population END AS midwives_per_10k,
         CASE WHEN j.bhw_in_window AND j.population > 0 THEN j.bhw * 10000.0 / j.population END AS bhw_per_10k
  FROM joined AS j
)

SELECT planning_unit_key,
       area_code,
       area_name,
       region_key,
       unit_level,
       income_class,
       population,
       population_year,
       population_source_key AS population_source,
       hospitals,
       beds,
       round(beds_per_10k, 2) AS beds_per_10k,
       CASE WHEN hospitals > 0 THEN coalesce(beds_level1, 0) END AS beds_level1,
       CASE WHEN hospitals > 0 THEN coalesce(beds_level2, 0) END AS beds_level2,
       CASE WHEN hospitals > 0 THEN coalesce(beds_level3, 0) END AS beds_level3,
       CASE WHEN hospitals > 0 THEN coalesce(government_beds, 0) END AS government_beds,
       CASE WHEN beds > 0 THEN round(coalesce(government_beds, 0) / beds, 4) END AS government_bed_share,
       coalesce(level3_hospitals, 0) AS level3_hospitals,
       highest_hospital_level,
       localities,
       localities_without_hospital,
       population_without_hospital,
       licensed_primary_care AS licensed_primary_care_facilities_recorded,
       localities_without_primary_care AS localities_without_licensed_primary_care_recorded,
       population_without_primary_care AS population_without_licensed_primary_care_recorded,
       reported_bhs,
       reported_health_centers,
       fhsis_reported_population,
       round(reported_bhs_per_10k, 2) AS reported_bhs_per_10k,
       round(reported_health_centers_per_10k, 2) AS reported_health_centers_per_10k,
       fhsis_count_year,
       fhsis_mapping_outcome,
       doctors,
       nurses,
       midwives,
       bhw,
       round(doctors_per_10k, 2) AS doctors_per_10k,
       round(nurses_per_10k, 2) AS nurses_per_10k,
       round(midwives_per_10k, 2) AS midwives_per_10k,
       round(bhw_per_10k, 2) AS bhw_per_10k,
       round(doh_deployed_share, 4) AS doh_deployed_share,
       workforce_year,
       poverty_incidence_pct,
       poverty_year,
       CASE WHEN poverty_incidence_pct IS NULL THEN NULL
            WHEN poverty_incidence_pct < 10 THEN 'under 10%'
            WHEN poverty_incidence_pct < 20 THEN '10% to under 20%'
            WHEN poverty_incidence_pct < 30 THEN '20% to under 30%'
            ELSE '30% or more' END AS poverty_band,
       CASE WHEN beds_per_10k IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_beds * 5) + 1) AS INT) END
         AS beds_per_10k_quintile,
       CASE WHEN reported_bhs_per_10k IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_bhs * 5) + 1) AS INT) END
         AS reported_bhs_per_10k_quintile,
       CASE WHEN reported_health_centers_per_10k IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_centres * 5) + 1) AS INT) END
         AS reported_health_centers_per_10k_quintile,
       CASE WHEN doctors_per_10k IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_doctors * 5) + 1) AS INT) END
         AS doctors_per_10k_quintile,
       CASE WHEN nurses_per_10k IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_nurses * 5) + 1) AS INT) END
         AS nurses_per_10k_quintile,
       CASE WHEN midwives_per_10k IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_midwives * 5) + 1) AS INT) END
         AS midwives_per_10k_quintile,
       CASE WHEN bhw_per_10k IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_bhw * 5) + 1) AS INT) END
         AS bhw_per_10k_quintile,
       CASE WHEN poverty_incidence_pct IS NOT NULL THEN CAST(least(5, floor(percent_rank() OVER w_poverty * 5) + 1) AS INT) END
         AS poverty_incidence_pct_quintile,
       -- extra columns
       hospitals_without_bed_count,
       registry_as_of_date,
       bhw_year,
       fhsis_exclusion_reason,
       workforce_mapping_outcome,
       workforce_exclusion_reason,
       bhw_exclusion_reason,
       poverty_exclusion_reason,
       localities_without_population
FROM rated
WINDOW
  w_beds AS (PARTITION BY beds_per_10k IS NOT NULL ORDER BY beds_per_10k),
  w_bhs AS (PARTITION BY reported_bhs_per_10k IS NOT NULL ORDER BY reported_bhs_per_10k),
  w_centres AS (PARTITION BY reported_health_centers_per_10k IS NOT NULL ORDER BY reported_health_centers_per_10k),
  w_doctors AS (PARTITION BY doctors_per_10k IS NOT NULL ORDER BY doctors_per_10k),
  w_nurses AS (PARTITION BY nurses_per_10k IS NOT NULL ORDER BY nurses_per_10k),
  w_midwives AS (PARTITION BY midwives_per_10k IS NOT NULL ORDER BY midwives_per_10k),
  w_bhw AS (PARTITION BY bhw_per_10k IS NOT NULL ORDER BY bhw_per_10k),
  w_poverty AS (PARTITION BY poverty_incidence_pct IS NOT NULL ORDER BY poverty_incidence_pct);


-- How many planning units have each indicator
SELECT count(*) AS units,
       count(beds_per_10k) AS with_beds_rate,
       count(reported_bhs_per_10k) AS with_bhs_rate,
       count(doctors_per_10k) AS with_doctor_rate,
       count(bhw_per_10k) AS with_bhw_rate,
       count(poverty_incidence_pct) AS with_poverty,
       max(workforce_year) AS workforce_year, max(fhsis_count_year) AS fhsis_count_year,
       max(poverty_year) AS poverty_year
FROM public_health.test_gold.mart_area_service_profile;