-- ========================================
-- Creates the view public_health.test_gold2.mart_area_evidence
--   One row is: one planning unit with one indicator, also when the unit has no value
--   Key: (planning_unit_key, indicator_key)
--   Answers: why an area is missing from a comparison, and where the platform's evidence is
--   not enough (Supporting)
-- Data model v2 (combined): same view as gold_55 (v1); dim_source -> dim_data_source
--   (source_key -> data_source_key). The two marts it reads keep their v1 column names.
--
-- Reads: mart_area_service_profile, mart_area_burden_indicator, mart_base_planning_unit,
--        dim_data_source
--
-- Rules
--   * Indicators: the eight rates of the service profile, plus every burden indicator.
--   * value_available      the unit has a value for the indicator
--   * coverage_compatible  the source's area could be mapped to the unit (direct or aggregate)
--   * comparison_eligible  the unit enters comparisons and rankings on this indicator
--   * exclusion_reason     why not, in the words of the mart that owns the indicator
--   * Nothing is computed here. The view only turns the two marts into one long list.
--
-- Columns added to the v3 list: area_code, area_name, unit_level, indicator_group, value.
-- A view has no _gold_build_id.
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold2.mart_area_evidence AS
WITH profile AS (
  SELECT p.planning_unit_key, p.area_code, p.area_name, p.unit_level,
         -- reason shared by every census-based rate
         CASE WHEN p.population IS NULL THEN 'no_population' END AS population_reason,
         stack(8,
           'beds_per_10k', 'hospital', CAST(p.beds_per_10k AS DOUBLE), CAST(year(p.registry_as_of_date) AS INT),
             'facilities_registry', 'aggregate', CAST(NULL AS STRING), true,
           'reported_bhs_per_10k', 'primary_care', CAST(p.reported_bhs_per_10k AS DOUBLE), CAST(p.fhsis_count_year AS INT),
             'doh_fhsis_demographic', p.fhsis_mapping_outcome, p.fhsis_exclusion_reason, false,
           'reported_health_centers_per_10k', 'primary_care', CAST(p.reported_health_centers_per_10k AS DOUBLE),
             CAST(p.fhsis_count_year AS INT), 'doh_fhsis_demographic', p.fhsis_mapping_outcome,
             coalesce(p.fhsis_exclusion_reason, 'no_report'), false,
           'doctors_per_10k', 'workforce', CAST(p.doctors_per_10k AS DOUBLE), CAST(p.workforce_year AS INT),
             'doh_fhsis_demographic', p.workforce_mapping_outcome, p.workforce_exclusion_reason, true,
           'nurses_per_10k', 'workforce', CAST(p.nurses_per_10k AS DOUBLE), CAST(p.workforce_year AS INT),
             'doh_fhsis_demographic', p.workforce_mapping_outcome, p.workforce_exclusion_reason, true,
           'midwives_per_10k', 'workforce', CAST(p.midwives_per_10k AS DOUBLE), CAST(p.workforce_year AS INT),
             'doh_fhsis_demographic', p.workforce_mapping_outcome, p.workforce_exclusion_reason, true,
           'bhw_per_10k', 'workforce', CAST(p.bhw_per_10k AS DOUBLE), CAST(p.bhw_year AS INT),
             'doh_fhsis_demographic', CASE WHEN p.bhw IS NOT NULL THEN p.workforce_mapping_outcome END,
             p.bhw_exclusion_reason, true,
           'poverty_incidence_pct', 'socioeconomic', CAST(p.poverty_incidence_pct AS DOUBLE), CAST(p.poverty_year AS INT),
             'psa_poverty', CASE WHEN p.poverty_incidence_pct IS NOT NULL THEN 'direct' END,
             p.poverty_exclusion_reason, false
         ) AS (indicator_key, indicator_group, value, reference_year, source_dataset, mapping_outcome,
               owner_reason, uses_census_population)
  FROM public_health.test_gold2.mart_area_service_profile AS p
),

long_list AS (
  SELECT planning_unit_key, area_code, area_name, unit_level, indicator_key, indicator_group, value,
         reference_year, source_dataset, mapping_outcome,
         CASE WHEN value IS NOT NULL THEN NULL
              ELSE coalesce(owner_reason, CASE WHEN uses_census_population THEN population_reason END,
                            'outside_alignment_window') END AS exclusion_reason
  FROM profile
  UNION ALL
  SELECT b.planning_unit_key, b.area_code, b.area_name, u.unit_level, b.burden_indicator_key, 'burden',
         b.rate_per_100k, b.reference_year, b.source_dataset, b.mapping_outcome, b.exclusion_reason
  FROM public_health.test_gold2.mart_area_burden_indicator AS b
  INNER JOIN public_health.test_gold2.mart_base_planning_unit AS u ON u.planning_unit_key = b.planning_unit_key
)

SELECT l.planning_unit_key,
       l.indicator_key,
       (l.value IS NOT NULL) AS value_available,
       l.reference_year,
       s.data_source_key,
       l.mapping_outcome,
       coalesce(l.mapping_outcome IN ('direct', 'aggregate'), false) AS coverage_compatible,
       (l.value IS NOT NULL) AS comparison_eligible,
       l.exclusion_reason,
       l.area_code,           -- extra
       l.area_name,           -- extra
       l.unit_level,          -- extra
       l.indicator_group,     -- extra
       l.value                -- extra
FROM long_list AS l
LEFT JOIN public_health.test_gold2.dim_data_source AS s ON s.source_dataset = l.source_dataset;


-- Where the evidence is not enough: share of planning units without each indicator.
-- Expect 109 units per indicator; beds 1 missing (Sulu, no 2024 population), poverty 42 missing.
SELECT indicator_group, indicator_key, count(*) AS units, count_if(value_available) AS with_value,
       round(100.0 * count_if(NOT value_available) / count(*), 1) AS pct_missing,
       array_join(array_sort(collect_set(exclusion_reason)), '; ') AS exclusion_reasons
FROM public_health.test_gold2.mart_area_evidence
GROUP BY indicator_group, indicator_key
ORDER BY indicator_group, indicator_key;