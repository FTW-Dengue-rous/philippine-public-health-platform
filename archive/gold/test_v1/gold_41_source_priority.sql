-- ========================================
-- gold_41_source_priority.sql
-- Builds public_health.test_gold.source_priority (seed table)
--   One row is: one source for one measure, disease scope, geographic level, period grain
--   and range of years, with its role
--   Key: (metric, disease_scope, geo_level, period_grain, year_from, year_to, source_key)
--
-- What it is for
--   Sources overlap on purpose. This table says which source gold shows for each measure.
--   The marts join it, so a source is never picked by hand inside a query.
--
-- Where the rows come from
--   diseases-silver-plan.md section 7 (source preference) and section 11 (replay eligibility),
--   workforce-silver-plan.md (PSA to 2017, FHSIS from 2018) and gold_14_fact_population.sql.
--
-- Differences from the v3 column list
--   * disease_scope replaces disease_key. The rules are written per group of causes
--     (dengue, tuberculosis, every PSA cause, every IHME cause), not per cause.
--     It holds a dim_disease.disease_group, a dim_disease.classification, or not_applicable.
--   * source_dataset is added beside source_key so the table can be read without a join.
--   * No _gold_build_id: this is a plain seed, not yet on the build pattern.
--
-- Roles: preferred (the row gold shows), cross_check (kept, compared, never shown as the
-- value), fallback (used only when the preferred source has no row).
--
-- Fix 2026-10-13: the duplicate-key check raised a false error on Databricks
--   (duplicate key for cases / dengue / upnoah). raise_error sat in the SELECT list of a
--   GROUP BY ... HAVING query, so Spark evaluated it inside the aggregate for EVERY group,
--   before HAVING filtered. The check now filters in a subquery first, then raises.
--   Rule for all checks: never put raise_error in the same SELECT as GROUP BY / HAVING.
-- ========================================

CREATE OR REPLACE TABLE public_health.test_gold.source_priority AS
SELECT metric, disease_scope, geo_level, period_grain, year_from, year_to,
       xxhash64(source_dataset) AS source_key,
       source_dataset, priority, role, replay_eligibility, reason
FROM VALUES
  ('cases', 'dengue', 'region', 'week', 2016, 2019, 'upnoah', 1, 'preferred', 'no: week rule not confirmed', 'Only regional weekly source. Every row is approximated by the source'),
  ('cases', 'dengue', 'region', 'week', 2022, 2025, 'upnoah', 1, 'preferred', 'no: week rule not confirmed', 'Only regional weekly source. Every row is approximated by the source'),
  ('cases', 'dengue', 'region', 'month', 2021, 2025, 'doh_foi_dengue', 1, 'preferred', 'scenario input only', 'Official surveillance counts. 2025 holds January to September'),
  ('deaths', 'dengue', 'region', 'month', 2021, 2025, 'doh_foi_dengue', 1, 'preferred', 'not applicable', 'Official surveillance counts. 2025 holds January to September'),
  ('cases', 'dengue', 'province', 'week', 2016, 2020, 'hdx_dengue', 1, 'preferred', 'no: date meaning and coverage not confirmed', 'Only province source. Province coverage is not confirmed'),
  ('deaths', 'dengue', 'province', 'week', 2016, 2020, 'hdx_dengue', 1, 'preferred', 'not applicable', 'Only province source. Province coverage is not confirmed'),
  ('deaths', 'psa_tabulation_list', 'country', 'month', 2020, 2024, 'psa_deaths_national_monthly', 1, 'preferred', 'not applicable', 'Only monthly registered deaths'),
  ('deaths', 'psa_tabulation_list', 'country', 'year', 2015, 2019, 'psa_deaths_national_annual', 1, 'preferred', 'not applicable', 'Final annual figures'),
  ('deaths', 'psa_tabulation_list', 'country', 'year', 2020, 2024, 'psa_deaths_national_monthly', 1, 'preferred', 'not applicable', 'Year rows of the monthly files'),
  ('deaths', 'psa_tabulation_list', 'country', 'year', 2020, 2020, 'psa_deaths_national_annual', 2, 'fallback', 'not applicable', '2020 is preliminary in this file'),
  ('deaths', 'psa_tabulation_list', 'country', 'year', 2023, 2024, 'psa_deaths_region_annual', 2, 'cross_check', 'not applicable', 'Philippines row of the region file'),
  ('deaths', 'psa_tabulation_list', 'region', 'year', 2023, 2024, 'psa_deaths_region_annual', 1, 'preferred', 'not applicable', 'Only source by region of usual residence'),
  ('cases', 'tuberculosis', 'country', 'year', 2024, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TB notifications. Reflects detection and reporting'),
  ('cases', 'tuberculosis', 'region', 'year', 2024, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TB notifications. Reflects detection and reporting'),
  ('cases', 'tuberculosis', 'province', 'year', 2024, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TB notifications. Reflects detection and reporting'),
  ('cases', 'tuberculosis', 'city', 'year', 2024, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TB notifications. Reflects detection and reporting'),
  ('cases', 'tuberculosis', 'municipality', 'year', 2024, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TB notifications. Reflects detection and reporting'),
  ('deaths', 'ihme_gbd', 'province', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'Modelled. Never mixed with registered or reported values'),
  ('prevalence', 'ihme_gbd', 'province', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'Modelled. Never mixed with registered or reported values'),
  ('deaths', 'ihme_gbd', 'region', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'NCR only: IHME lists NCR as one location'),
  ('prevalence', 'ihme_gbd', 'region', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'NCR only: IHME lists NCR as one location'),
  ('headcount', 'not_applicable', 'any', 'year', 2012, 2017, 'psa_gov_practitioners', 1, 'preferred', 'not applicable', 'History source before FHSIS'),
  ('headcount', 'not_applicable', 'any', 'year', 2018, 2025, 'doh_fhsis_demographic', 1, 'preferred', 'not applicable', 'More professions and lower geographic levels'),
  ('headcount', 'not_applicable', 'any', 'year', 2018, 2023, 'psa_gov_practitioners', 2, 'cross_check', 'not applicable', 'Compared with FHSIS national totals (silver check S71)'),
  ('population', 'not_applicable', 'any', 'year', 2015, 2024, 'psa_psgc', 1, 'preferred', 'not applicable', 'Census counts. Denominator for rates'),
  ('population', 'not_applicable', 'any', 'year', 2018, 2025, 'doh_fhsis_demographic', 2, 'fallback', 'not applicable', 'Population printed in the FHSIS tables. Denominator for FHSIS facility counts only')
  AS t (metric, disease_scope, geo_level, period_grain, year_from, year_to, source_dataset, priority, role,
        replay_eligibility, reason);

-- Checks: each must return no row. A failure stops the run here.
-- Duplicate key: filter in the subquery first, raise outside it (see the fix note above).
SELECT raise_error(concat('source_priority: duplicate key for ', metric, ' / ', disease_scope, ' / ',
                          geo_level, ' / ', period_grain, ' / ', year_from, '-', year_to, ' / ', source_dataset))
FROM (
  SELECT metric, disease_scope, geo_level, period_grain, year_from, year_to, source_dataset
  FROM public_health.test_gold.source_priority
  GROUP BY metric, disease_scope, geo_level, period_grain, year_from, year_to, source_dataset
  HAVING count(*) > 1
) AS dup;

SELECT raise_error(concat('source_priority: source not in dim_source: ', p.source_dataset))
FROM public_health.test_gold.source_priority AS p
LEFT ANTI JOIN public_health.test_gold.dim_source AS s ON s.source_key = p.source_key;

SELECT raise_error(concat('source_priority: two preferred sources overlap for ', a.metric, ' / ', a.disease_scope, ' / ',
                          a.geo_level, ' / ', a.period_grain))
FROM public_health.test_gold.source_priority AS a
INNER JOIN public_health.test_gold.source_priority AS b
  ON a.metric = b.metric AND a.disease_scope = b.disease_scope AND a.geo_level = b.geo_level
 AND a.period_grain = b.period_grain AND a.source_dataset < b.source_dataset
 AND a.year_from <= b.year_to AND b.year_from <= a.year_to
WHERE a.role = 'preferred' AND b.role = 'preferred';

SELECT role, count(*) AS rules FROM public_health.test_gold.source_priority GROUP BY role ORDER BY role;