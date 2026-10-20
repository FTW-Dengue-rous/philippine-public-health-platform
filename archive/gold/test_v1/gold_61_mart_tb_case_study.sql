-- ========================================
-- Creates the view public_health.test_gold.mart_tb_case_study
--   One row is: one city or municipality
--   Key: area_key
--   Answers: T1. Do places with higher reported TB notification rates also have fewer public
--   health workers per population, and how many have no recorded primary care facility (A3)
--   or hospital (A1)?
--
-- Reads: mart_locality_service_presence, dim_disease, dim_period, dim_profession, dim_source,
--        fact_disease_metric, fact_workforce
--
-- Rules
--   * TB = notified cases, all forms (FHSIS, disease tb_all_forms), 2024 and 2025. They are
--     notifications: they reflect detection and reporting, not only disease.
--   * Both rates use the 2024 census population of the locality (T1 as written in the
--     proposal). A locality whose latest census count is not 2024 has no rate.
--   * Workforce = FHSIS 2025, the first year published by city and municipality. Only rows
--     with analysis_eligible = true are used. A value that is not eligible is null, never 0.
--   * BHW: FHSIS 2025 prints LGU-hired BHW only and no total. bhw_per_10k is therefore null
--     for 2025. bhw_lgu_hired_per_10k is added and must be labelled "LGU-hired only".
--   * comparison_eligible = the locality has 2025 notifications, a 2024 population, and usable
--     doctors, nurses and midwives. exclusion_reason gives the first thing that is missing.
--   * programme_indicator_key and programme_indicator_value stay null until a TB programme
--     dataset passes its feasibility check (T2).
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold.mart_tb_case_study AS
WITH tb AS (
  SELECT f.area_key,
         max(CASE WHEN p.year = 2024 THEN f.value END) AS tb_2024,
         max(CASE WHEN p.year = 2025 THEN f.value END) AS tb_2025
  FROM public_health.test_gold.fact_disease_metric AS f
  INNER JOIN public_health.test_gold.dim_disease AS d
    ON d.disease_key = f.disease_key AND d.disease_code = 'tb_all_forms'
  INNER JOIN public_health.test_gold.dim_source AS s ON s.source_key = f.source_key AND s.source_dataset = 'doh_fhsis'
  INNER JOIN public_health.test_gold.dim_period AS p
    ON p.period_key = f.period_key AND p.period_grain = 'year' AND p.year IN (2024, 2025)
  WHERE f.metric_name = 'cases'
  GROUP BY f.area_key
),

workforce AS (
  SELECT w.area_key,
         max(CASE WHEN pr.profession_code = 'doctors' AND w.analysis_eligible THEN w.headcount_total END) AS doctors,
         max(CASE WHEN pr.profession_code = 'nurses' AND w.analysis_eligible THEN w.headcount_total END) AS nurses,
         max(CASE WHEN pr.profession_code = 'midwives' AND w.analysis_eligible THEN w.headcount_total END) AS midwives,
         max(CASE WHEN pr.profession_code = 'bhw' AND w.analysis_eligible THEN w.headcount_total END) AS bhw,
         max(CASE WHEN pr.profession_code = 'bhw' THEN w.headcount_lgu_hired END) AS bhw_lgu_hired,
         max(CASE WHEN pr.profession_code IN ('doctors', 'nurses', 'midwives') THEN w.exclusion_reason END)
           AS exclusion_reason
  FROM public_health.test_gold.fact_workforce AS w
  INNER JOIN public_health.test_gold.dim_profession AS pr ON pr.profession_key = w.profession_key
  INNER JOIN public_health.test_gold.dim_source AS s
    ON s.source_key = w.source_key AND s.source_dataset = 'doh_fhsis_demographic'
  INNER JOIN public_health.test_gold.dim_period AS p
    ON p.period_key = w.period_key AND p.period_basis = 'calendar_year' AND p.year = 2025
  GROUP BY w.area_key
),

joined AS (
  SELECT l.area_key, l.area_code, l.area_name, l.planning_unit_key, l.region_key,
         CASE WHEN l.population_year = 2024 THEN l.population END AS population,
         CASE WHEN l.population_year = 2024 THEN l.population_year END AS population_year,
         CAST(t.tb_2024 AS BIGINT) AS tb_2024, CAST(t.tb_2025 AS BIGINT) AS tb_2025,
         w.doctors, w.nurses, w.midwives, w.bhw, w.bhw_lgu_hired,
         l.has_licensed_primary_care_recorded, l.has_hospital_recorded,
         CASE WHEN t.area_key IS NULL THEN 'no_tb_row'
              WHEN t.tb_2025 IS NULL THEN 'tb_2025_not_reported'
              WHEN l.population IS NULL OR l.population_year <> 2024 THEN 'no_2024_population'
              WHEN w.area_key IS NULL THEN 'no_workforce_row'
              WHEN w.doctors IS NULL OR w.nurses IS NULL OR w.midwives IS NULL
                THEN coalesce(w.exclusion_reason, 'workforce_not_usable')
         END AS exclusion_reason
  FROM public_health.test_gold.mart_locality_service_presence AS l
  LEFT JOIN tb AS t ON t.area_key = l.area_key
  LEFT JOIN workforce AS w ON w.area_key = l.area_key
)

SELECT area_key,
       tb_2024 AS tb_notifications_2024,
       tb_2025 AS tb_notifications_2025,
       tb_2025 - tb_2024 AS tb_change,
       CASE WHEN population > 0 THEN round(tb_2024 * 100000.0 / population, 1) END AS tb_notifications_per_100k_2024,
       CASE WHEN population > 0 THEN round(tb_2025 * 100000.0 / population, 1) END AS tb_notifications_per_100k_2025,
       population,
       population_year,
       CASE WHEN population > 0 THEN round(doctors * 10000.0 / population, 2) END AS doctors_per_10k,
       CASE WHEN population > 0 THEN round(nurses * 10000.0 / population, 2) END AS nurses_per_10k,
       CASE WHEN population > 0 THEN round(midwives * 10000.0 / population, 2) END AS midwives_per_10k,
       CASE WHEN population > 0 THEN round(bhw * 10000.0 / population, 2) END AS bhw_per_10k,
       2025 AS workforce_year,
       has_licensed_primary_care_recorded,
       has_hospital_recorded,
       (exclusion_reason IS NULL) AS comparison_eligible,
       exclusion_reason,
       CAST(NULL AS STRING) AS programme_indicator_key,
       CAST(NULL AS DOUBLE) AS programme_indicator_value,
       area_code,                                   -- extra
       area_name,                                   -- extra
       planning_unit_key,                           -- extra
       region_key,                                  -- extra
       CASE WHEN population > 0 THEN round(bhw_lgu_hired * 10000.0 / population, 2) END AS bhw_lgu_hired_per_10k   -- extra
FROM joined;


-- T1 in one table: comparable localities by fifth of the 2025 TB notification rate
SELECT tb_rate_fifth, count(*) AS localities,
       round(avg(tb_notifications_per_100k_2025), 1) AS mean_tb_rate_per_100k,
       round(percentile_approx(doctors_per_10k, 0.5), 2) AS median_doctors_per_10k,
       round(percentile_approx(nurses_per_10k, 0.5), 2) AS median_nurses_per_10k,
       round(percentile_approx(midwives_per_10k, 0.5), 2) AS median_midwives_per_10k,
       count_if(NOT has_licensed_primary_care_recorded) AS without_licensed_primary_care_recorded,
       count_if(NOT has_hospital_recorded) AS without_hospital_recorded
FROM (SELECT t.*, ntile(5) OVER (ORDER BY tb_notifications_per_100k_2025, area_key) AS tb_rate_fifth
      FROM public_health.test_gold.mart_tb_case_study AS t
      WHERE comparison_eligible) AS ranked
GROUP BY tb_rate_fifth
ORDER BY tb_rate_fifth;

SELECT coalesce(exclusion_reason, 'comparable') AS status, count(*) AS localities
FROM public_health.test_gold.mart_tb_case_study
GROUP BY coalesce(exclusion_reason, 'comparable')
ORDER BY localities DESC;
