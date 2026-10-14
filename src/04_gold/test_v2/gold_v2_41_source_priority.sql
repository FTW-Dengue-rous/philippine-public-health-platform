-- ========================================
-- Builds public_health.test_gold2.source_priority (seed table)
--   One row is: one source for one metric, disease scope, geographic level, period grain
--   and range of years, with its role
--   Key: (metric, disease_scope, geo_level, period_grain, year_from, year_to, data_source_key)
-- Data model v2: same seed as gold_41 (v1) with source_key renamed data_source_key, plus the
-- rows for the TB programme indicators and the PhilHealth claims metrics (2026-10-14 evening).
--
-- What it is for
--   Sources overlap on purpose. This table says which source gold shows for each metric.
--   The marts join it, so a source is never picked by hand inside a query.
--
-- Where the rows come from
--   diseases-silver-plan.md section 7 (source preference) and section 11 (replay eligibility),
--   workforce-silver-plan.md (PSA to 2017, FHSIS from 2018) and the population rules.
--
-- Roles: preferred (the row gold shows), cross_check (kept, compared, never shown as the
-- value), fallback (used only when the preferred source has no row).
-- Rule for all checks: never put raise_error in the same SELECT as GROUP BY / HAVING (filter in
-- a subquery first; the aggregate would otherwise raise for every group).
-- ========================================

CREATE OR REPLACE TABLE public_health.test_gold2.source_priority AS
SELECT metric, disease_scope, geo_level, period_grain, year_from, year_to,
       xxhash64(source_dataset) AS data_source_key,
       source_dataset, priority, role, replay_eligibility, reason
FROM VALUES
  ('cases', 'dengue', 'region', 'week', 2016, 2019, 'upnoah', 1, 'preferred', 'no: week rule not confirmed', 'Only regional weekly source. Every row is approximated by the source'),
  ('cases', 'dengue', 'region', 'week', 2022, 2025, 'upnoah', 1, 'preferred', 'no: week rule not confirmed', 'Only regional weekly source. Every row is approximated by the source'),
  ('cases', 'dengue', 'region', 'month', 2021, 2025, 'doh_foi_dengue', 1, 'preferred', 'scenario input only', 'Official surveillance counts. 2025 holds January to September'),
  ('deaths', 'dengue', 'region', 'month', 2021, 2025, 'doh_foi_dengue', 1, 'preferred', 'not applicable', 'Official surveillance counts. 2025 holds January to September'),
  ('cases', 'dengue', 'province', 'week', 2016, 2020, 'hdx_dengue', 1, 'preferred', 'no: date meaning and coverage not confirmed', 'Only province source. Province coverage is not confirmed. 2016 and 2019 are one week short (F14)'),
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
  ('tpt_given', 'tuberculosis', 'any', 'year', 2025, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TB-TPT sheet: contacts given preventive treatment. Only source'),
  ('tpt_eligible_contacts', 'tuberculosis', 'any', 'year', 2025, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS estimate (notified cases x 4 x 70%). Coverage denominator; label as an estimate'),
  ('treatment_cohort', 'tuberculosis', 'any', 'year', 2025, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TSR sheets: cases with an outcome reported in the year, not the notifications of that year'),
  ('treatment_success', 'tuberculosis', 'any', 'year', 2025, 2025, 'doh_fhsis', 1, 'preferred', 'not applicable', 'FHSIS TSR sheets: cured + treatment completed. Rate = success / cohort, both sexes'),
  ('deaths', 'ihme_gbd', 'province', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'Modelled. Never mixed with registered or reported values'),
  ('prevalence', 'ihme_gbd', 'province', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'Modelled. Never mixed with registered or reported values'),
  ('deaths', 'ihme_gbd', 'region', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'NCR only: IHME lists NCR as one location'),
  ('prevalence', 'ihme_gbd', 'region', 'year', 2019, 2023, 'ihme_gbd', 1, 'preferred', 'not applicable', 'NCR only: IHME lists NCR as one location'),
  ('claims_filed', 'phic_case_rate_package', 'any', 'year', 2016, 2025, 'philhealth_foi_claims_hospital', 1, 'preferred', 'not applicable', 'PhilHealth FOI, area of the hospital. Utilisation = every status. Aggregates only; small cells suppressed'),
  ('claims_paid', 'phic_case_rate_package', 'any', 'year', 2016, 2025, 'philhealth_foi_claims_hospital', 1, 'preferred', 'not applicable', 'PhilHealth FOI, area of the hospital. Paid claims only'),
  ('claims_amount_claimed_php', 'phic_case_rate_package', 'any', 'year', 2016, 2025, 'philhealth_foi_claims_hospital', 1, 'preferred', 'not applicable', 'Amount claimed, not paid. Not comparable across the 2024 case-rate change'),
  ('claims_paid_amount_claimed_php', 'phic_case_rate_package', 'any', 'year', 2016, 2025, 'philhealth_foi_claims_hospital', 1, 'preferred', 'not applicable', 'Amount claimed on paid claims. Not comparable across the 2024 case-rate change'),
  ('headcount', 'not_applicable', 'any', 'year', 2012, 2017, 'psa_gov_practitioners', 1, 'preferred', 'not applicable', 'History source before FHSIS'),
  ('headcount', 'not_applicable', 'any', 'year', 2018, 2025, 'doh_fhsis_demographic', 1, 'preferred', 'not applicable', 'More professions and lower geographic levels'),
  ('headcount', 'not_applicable', 'any', 'year', 2018, 2023, 'psa_gov_practitioners', 2, 'cross_check', 'not applicable', 'Compared with FHSIS national totals (silver check S71)'),
  ('population', 'not_applicable', 'any', 'year', 2015, 2024, 'psa_psgc', 1, 'preferred', 'not applicable', 'Census counts. Denominator for rates'),
  ('population', 'not_applicable', 'any', 'year', 2018, 2025, 'doh_fhsis_demographic', 2, 'fallback', 'not applicable', 'Population printed in the FHSIS tables. Denominator for FHSIS facility counts only')
  AS t (metric, disease_scope, geo_level, period_grain, year_from, year_to, source_dataset, priority, role,
        replay_eligibility, reason);

-- Checks: each must return no row. A failure stops the run here.
SELECT raise_error(concat('source_priority: duplicate key for ', metric, ' / ', disease_scope, ' / ',
                          geo_level, ' / ', period_grain, ' / ', year_from, '-', year_to, ' / ', source_dataset))
FROM (
  SELECT metric, disease_scope, geo_level, period_grain, year_from, year_to, source_dataset
  FROM public_health.test_gold2.source_priority
  GROUP BY metric, disease_scope, geo_level, period_grain, year_from, year_to, source_dataset
  HAVING count(*) > 1
) AS dup;

SELECT raise_error(concat('source_priority: source not in dim_data_source: ', p.source_dataset))
FROM public_health.test_gold2.source_priority AS p
LEFT ANTI JOIN public_health.test_gold2.dim_data_source AS s ON s.data_source_key = p.data_source_key;

SELECT raise_error(concat('source_priority: two preferred sources overlap for ', a.metric, ' / ', a.disease_scope, ' / ',
                          a.geo_level, ' / ', a.period_grain))
FROM public_health.test_gold2.source_priority AS a
INNER JOIN public_health.test_gold2.source_priority AS b
  ON a.metric = b.metric AND a.disease_scope = b.disease_scope AND a.geo_level = b.geo_level
 AND a.period_grain = b.period_grain AND a.source_dataset < b.source_dataset
 AND a.year_from <= b.year_to AND b.year_from <= a.year_to
WHERE a.role = 'preferred' AND b.role = 'preferred';

SELECT role, count(*) AS rules FROM public_health.test_gold2.source_priority GROUP BY role ORDER BY role;