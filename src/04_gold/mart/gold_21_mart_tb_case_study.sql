-- ========================================
-- Creates the view public_health.gold.mart_tb_case_study
--   One row is: one city or municipality
--   Key: area_key
--   Answers:
--     T1  Do places with higher reported TB notification rates also have fewer public health
--         workers per population? How many have no licensed primary care facility recorded (A3)
--         or no hospital recorded (A1)?
--     T2  How much TB preventive treatment (TPT) reaches eligible contacts, and what share of
--         treated TB cases succeed, by area? (programme columns, FHSIS 2025)
--
-- Reads: mart_locality_service_presence (gold 14), dim_disease, dim_date, dim_data_source,
--        fact_disease_metric (gold 07), fact_workforce_capacity (gold 08)
--
-- Sources: this mart names its sources directly (doh_fhsis, doh_fhsis_demographic). It does not
-- join source_priority. Both match the preferred rules there (TB 2024-2025, headcount
-- 2018-2025). If those rules change, update this file too.
--
-- Rules
--   * TB = notified cases, all forms (FHSIS, disease tb_all_forms, metric cases), 2024 and 2025.
--     Only rows with value_status = 'ok' are used. They are notifications: they reflect detection
--     and reporting, not only disease.
--   * Every rate in this view uses the 2024 census population of the locality (T1 as written in
--     the proposal). That includes the 2025 notification rate and the 2025 workforce rates.
--     A locality whose latest census year is not 2024 has no population and no rates.
--   * Workforce = FHSIS 2025 (doh_fhsis_demographic), source_role = preferred. 2025 is the first
--     year FHSIS publishes it by city and municipality. Doctors, nurses, midwives and the BHW
--     total use analysis_eligible rows only. Not eligible = null, never 0.
--   * BHW: FHSIS 2025 prints LGU-hired BHW only and no total, so bhw_per_10k is null for 2025.
--     bhw_lgu_hired_per_10k does not check analysis_eligible. Label it "LGU-hired only".
--   * Programme (T2): FHSIS 2025, all ages, both sexes, from fact_disease_metric.
--       tpt_coverage_pct               = tpt_given / tpt_eligible_contacts x 100 (tb_all_forms)
--       ds_treatment_success_rate_pct  = treatment_success / treatment_cohort x 100
--                                        (tb_all_forms = drug-susceptible TB)
--       mdr_treatment_success_rate_pct = treatment_success / treatment_cohort x 100
--                                        (tb_drug_resistant)
--     tpt_eligible_contacts is an FHSIS ESTIMATE (notified cases x 4 x 70%). Label it.
--     The treatment cohort is the cases with an outcome reported in 2025. It is not the 2025
--     notifications.
--     The view computes the rates. It never copies the printed percentages.
--     A rate is null when its denominator is null or 0.
--   * Small cohorts are flagged, not hidden.
--       ds_small_cohort         the DS cohort is under 10. Use it with ds_treatment_success_rate_pct.
--       mdr_small_cohort        the MDR cohort is under 10. Use it with mdr_treatment_success_rate_pct.
--       Both are null when the cohort is missing (the rate is null too).
--       programme_small_cohort  older locality flag: true when BOTH cohorts are under 10 (a
--                               missing cohort counts as 0). Kept so existing charts keep
--                               working. Prefer the two flags above.
--   * comparison_eligible (T1) = the locality has 2025 notifications, a 2024 population, and
--     usable doctors, nurses and midwives. exclusion_reason names the first missing item, in
--     that order.
--   * programme_available (T2) = at least one programme denominator above 0 for the locality.
--
-- History
--   2026-10-14  Written for data model v2. TB programme columns (T2) added the same day.
--   2026-10-18  Moved to public_health.gold and renamed gold_21. Comments corrected (scope of
--               programme_small_cohort, population year of the workforce rates, source note).
--   2026-10-19  Added ds_small_cohort and mdr_small_cohort, one flag per success rate.
--               programme_small_cohort is unchanged.
-- ========================================

CREATE OR REPLACE VIEW public_health.gold.mart_tb_case_study AS
-- TB notifications per locality, 2024 and 2025 side by side
WITH tb AS (
  SELECT f.area_key,
         max(CASE WHEN t.year = 2024 THEN f.value END) AS tb_2024,
         max(CASE WHEN t.year = 2025 THEN f.value END) AS tb_2025
  FROM public_health.gold.fact_disease_metric AS f
  INNER JOIN public_health.gold.dim_disease AS d
    ON d.disease_key = f.disease_key AND d.disease_code = 'tb_all_forms'
  INNER JOIN public_health.gold.dim_data_source AS s
    ON s.data_source_key = f.data_source_key AND s.source_dataset = 'doh_fhsis'
  INNER JOIN public_health.gold.dim_date AS t
    ON t.date_key = f.date_key AND t.period_grain = 'year' AND t.year IN (2024, 2025)
  WHERE f.metric_name = 'cases' AND f.age_group = 'all_ages' AND f.sex = 'both_sexes' AND f.value_status = 'ok'
  GROUP BY f.area_key
),

-- TB programme counts per locality, 2025: TPT, and DS and MDR treatment outcomes
programme AS (
  SELECT f.area_key,
         max(CASE WHEN d.disease_code = 'tb_all_forms' AND f.metric_name = 'tpt_given' THEN f.value END) AS tpt_given,
         max(CASE WHEN d.disease_code = 'tb_all_forms' AND f.metric_name = 'tpt_eligible_contacts' THEN f.value END) AS tpt_eligible_contacts,
         max(CASE WHEN d.disease_code = 'tb_all_forms' AND f.metric_name = 'treatment_cohort' THEN f.value END) AS ds_treatment_cohort,
         max(CASE WHEN d.disease_code = 'tb_all_forms' AND f.metric_name = 'treatment_success' THEN f.value END) AS ds_treatment_success,
         max(CASE WHEN d.disease_code = 'tb_drug_resistant' AND f.metric_name = 'treatment_cohort' THEN f.value END) AS mdr_treatment_cohort,
         max(CASE WHEN d.disease_code = 'tb_drug_resistant' AND f.metric_name = 'treatment_success' THEN f.value END) AS mdr_treatment_success,
         CAST(max(t.year) AS INT) AS programme_year
  FROM public_health.gold.fact_disease_metric AS f
  INNER JOIN public_health.gold.dim_disease AS d ON d.disease_key = f.disease_key
  INNER JOIN public_health.gold.dim_data_source AS s
    ON s.data_source_key = f.data_source_key AND s.source_dataset = 'doh_fhsis'
  INNER JOIN public_health.gold.dim_date AS t
    ON t.date_key = f.date_key AND t.period_basis = 'calendar_year' AND t.year = 2025
  WHERE f.metric_name IN ('tpt_given', 'tpt_eligible_contacts', 'treatment_cohort', 'treatment_success')
    AND f.age_group = 'all_ages' AND f.sex = 'both_sexes' AND f.value_status = 'ok'
  GROUP BY f.area_key
),

-- FHSIS 2025 headcounts per locality (preferred rows). exclusion_reason comes from the fact
-- for doctors, nurses and midwives.
workforce AS (
  SELECT w.area_key,
         max(CASE WHEN w.profession_code = 'doctors' AND w.analysis_eligible THEN w.headcount_total END) AS doctors,
         max(CASE WHEN w.profession_code = 'nurses' AND w.analysis_eligible THEN w.headcount_total END) AS nurses,
         max(CASE WHEN w.profession_code = 'midwives' AND w.analysis_eligible THEN w.headcount_total END) AS midwives,
         max(CASE WHEN w.profession_code = 'bhw' AND w.analysis_eligible THEN w.headcount_total END) AS bhw,
         max(CASE WHEN w.profession_code = 'bhw' THEN w.headcount_lgu_hired END) AS bhw_lgu_hired,
         max(CASE WHEN w.profession_code IN ('doctors', 'nurses', 'midwives') THEN w.exclusion_reason END)
           AS exclusion_reason
  FROM public_health.gold.fact_workforce_capacity AS w
  INNER JOIN public_health.gold.dim_data_source AS s
    ON s.data_source_key = w.data_source_key AND s.source_dataset = 'doh_fhsis_demographic'
  INNER JOIN public_health.gold.dim_date AS t
    ON t.date_key = w.date_key AND t.period_basis = 'calendar_year' AND t.year = 2025
  WHERE w.source_role = 'preferred'
  GROUP BY w.area_key
),

-- every locality, with TB, workforce and programme values, and the first reason it is not
-- comparable for T1 (null = comparable)
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
         END AS exclusion_reason,
         CAST(p.tpt_given AS BIGINT) AS tpt_given,
         p.tpt_eligible_contacts,
         CAST(p.ds_treatment_cohort AS BIGINT) AS ds_treatment_cohort,
         CAST(p.ds_treatment_success AS BIGINT) AS ds_treatment_success,
         CAST(p.mdr_treatment_cohort AS BIGINT) AS mdr_treatment_cohort,
         CAST(p.mdr_treatment_success AS BIGINT) AS mdr_treatment_success,
         p.programme_year
  FROM public_health.gold.mart_locality_service_presence AS l
  LEFT JOIN tb AS t ON t.area_key = l.area_key
  LEFT JOIN workforce AS w ON w.area_key = l.area_key
  LEFT JOIN programme AS p ON p.area_key = l.area_key
)

SELECT area_key,
       -- T1: notifications and rates (2024 census population)
       tb_2024 AS tb_notifications_2024,
       tb_2025 AS tb_notifications_2025,
       tb_2025 - tb_2024 AS tb_change,
       CASE WHEN population > 0 THEN round(tb_2024 * 100000.0 / population, 1) END AS tb_notifications_per_100k_2024,
       CASE WHEN population > 0 THEN round(tb_2025 * 100000.0 / population, 1) END AS tb_notifications_per_100k_2025,
       population,
       population_year,
       -- T1: workforce per 10,000 (FHSIS 2025 headcount over the 2024 census population)
       CASE WHEN population > 0 THEN round(doctors * 10000.0 / population, 2) END AS doctors_per_10k,
       CASE WHEN population > 0 THEN round(nurses * 10000.0 / population, 2) END AS nurses_per_10k,
       CASE WHEN population > 0 THEN round(midwives * 10000.0 / population, 2) END AS midwives_per_10k,
       CASE WHEN population > 0 THEN round(bhw * 10000.0 / population, 2) END AS bhw_per_10k,
       CASE WHEN population > 0 THEN round(bhw_lgu_hired * 10000.0 / population, 2) END AS bhw_lgu_hired_per_10k,
       2025 AS workforce_year,
       has_licensed_primary_care_recorded,
       has_hospital_recorded,
       (exclusion_reason IS NULL) AS comparison_eligible,
       exclusion_reason,
       -- T2 programme indicators (FHSIS 2025)
       tpt_given,
       round(tpt_eligible_contacts, 1) AS tpt_eligible_contacts_estimate,
       CASE WHEN tpt_eligible_contacts > 0 THEN round(tpt_given * 100.0 / tpt_eligible_contacts, 1) END AS tpt_coverage_pct,
       ds_treatment_cohort,
       ds_treatment_success,
       CASE WHEN ds_treatment_cohort > 0 THEN round(ds_treatment_success * 100.0 / ds_treatment_cohort, 1) END
         AS ds_treatment_success_rate_pct,
       mdr_treatment_cohort,
       mdr_treatment_success,
       CASE WHEN mdr_treatment_cohort > 0 THEN round(mdr_treatment_success * 100.0 / mdr_treatment_cohort, 1) END
         AS mdr_treatment_success_rate_pct,
       -- true only when both cohorts are under 10 (see header)
       (coalesce(ds_treatment_cohort, 0) < 10 AND coalesce(mdr_treatment_cohort, 0) < 10) AS programme_small_cohort,
       -- one flag per success rate: the cohort is under 10 (null when there is no cohort)
       (ds_treatment_cohort < 10) AS ds_small_cohort,
       (mdr_treatment_cohort < 10) AS mdr_small_cohort,
       (tpt_eligible_contacts > 0 OR ds_treatment_cohort > 0 OR mdr_treatment_cohort > 0) AS programme_available,
       programme_year,
       area_code,
       area_name,
       planning_unit_key,
       region_key
FROM joined;


-- Checks after creating the view.
-- 1. T1 in one table: comparable localities by fifth of the 2025 TB notification rate.
--    ntile(5) gives equal-size fifths; area_key splits ties.
SELECT tb_rate_fifth, count(*) AS localities,
       round(avg(tb_notifications_per_100k_2025), 1) AS mean_tb_rate_per_100k,
       round(percentile_approx(doctors_per_10k, 0.5), 2) AS median_doctors_per_10k,
       round(percentile_approx(nurses_per_10k, 0.5), 2) AS median_nurses_per_10k,
       round(percentile_approx(midwives_per_10k, 0.5), 2) AS median_midwives_per_10k,
       count_if(NOT has_licensed_primary_care_recorded) AS without_licensed_primary_care_recorded,
       count_if(NOT has_hospital_recorded) AS without_hospital_recorded,
       round(percentile_approx(tpt_coverage_pct, 0.5), 1) AS median_tpt_coverage_pct,
       round(percentile_approx(ds_treatment_success_rate_pct, 0.5), 1) AS median_ds_success_rate_pct
FROM (SELECT t.*, ntile(5) OVER (ORDER BY tb_notifications_per_100k_2025, area_key) AS tb_rate_fifth
      FROM public_health.gold.mart_tb_case_study AS t
      WHERE comparison_eligible) AS ranked
GROUP BY tb_rate_fifth
ORDER BY tb_rate_fifth;

-- 2. Why localities are not comparable, and how many of them still have programme data
SELECT coalesce(exclusion_reason, 'comparable') AS status, count(*) AS localities,
       count_if(programme_available) AS with_programme_data
FROM public_health.gold.mart_tb_case_study
GROUP BY coalesce(exclusion_reason, 'comparable')
ORDER BY localities DESC;

-- 3. T2 control totals: locality programme values add up to the national figures in the
--    gold_07 fact_disease_metric check (was gold_v2_30): TPT 120,108 / 1,498,711.2;
--    DS-TB 382,547 / 414,185; MDR 5,030 / 7,721. Expect equal or lower: localities with no row
--    are missing.
SELECT sum(tpt_given) AS tpt_given, round(sum(tpt_eligible_contacts_estimate), 1) AS tpt_eligible,
       sum(ds_treatment_success) AS ds_success, sum(ds_treatment_cohort) AS ds_cohort,
       sum(mdr_treatment_success) AS mdr_success, sum(mdr_treatment_cohort) AS mdr_cohort,
       count_if(programme_available) AS localities_with_programme_data
FROM public_health.gold.mart_tb_case_study;