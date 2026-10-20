-- ========================================
-- Creates four thin views in public_health.gold, one per fact, that apply the fact's
-- SELECTION CONTRACT: the filters every total must carry so that valid rows are never added
-- twice. Nothing is computed here; no new table. A view has no _gold_build_id.
--
--   v_facility_capacity_totals   fact_facility_capacity  one row per area x date x source x
--                                 basis x category, ownership total, all hospital levels
--   v_disease_metric_totals      fact_disease_metric     all ages, both sexes, with
--                                 is_preferred_source from source_priority
--   v_workforce_preferred        fact_workforce_capacity preferred source, analysis eligible
--   v_area_indicator_latest      fact_area_indicator     value ok, with is_latest_period
--
-- Reads: the four facts (gold 06-09), dim_disease, dim_data_source, dim_date, dim_geography,
--        source_priority (gold 10)
--
-- Why
--   The four facts carry overlapping rows on purpose: fact_facility_capacity holds three
--   capacity bases, three geographic levels of occupancy and three ownership breakdowns;
--   fact_disease_metric holds several sources per disease, age bands beside the all-ages row
--   and sexes beside both_sexes; fact_workforce_capacity holds PSA beside FHSIS for 2018-2023;
--   fact_area_indicator holds several years and two population categories. A SUM over the raw
--   fact without the contract double counts. The marts follow the contract already; these
--   views give the dashboard (and Genie) a safe entry point for ad hoc totals.
--
-- Selection contract per fact (also in 04_gold/README.md)
--   fact_facility_capacity   capacity_basis AND coverage_basis AND ownership AND hospital_level
--                            AND value_status = 'ok'. Registry rows have no 'total' row: sum
--                            them over ownership and level. Published and occupancy rows have
--                            ownership = 'total' (and hospital_level = 'all' for occupancy).
--   fact_disease_metric      one data_source_key (source_priority preferred) AND metric_name
--                            AND age_group = 'all_ages' AND sex = 'both_sexes' AND one
--                            coverage_basis (claims: one facility_location* level).
--   fact_workforce_capacity  source_role = 'preferred' AND profession_code AND analysis_eligible.
--   fact_area_indicator      indicator_name AND indicator_category AND value_status = 'ok';
--                            one date_key per area for a snapshot (is_latest_period).
--
-- Restricted rows (occupancy, claims) stay aggregates with small cells suppressed (D-47). The
-- views keep suppressed rows (value null) so a blank is explained.
--
-- History
--   2026-10-14  Written the same night as review point 2 (selection contract per fact).
--   2026-10-20  Moved to public_health.gold and renamed gold_13. Comments updated. No logic
--               change.
-- ========================================

-- [1] Facility capacity totals ---------------------------------------------------------------
CREATE OR REPLACE VIEW public_health.gold.v_facility_capacity_totals AS
-- registry snapshot: one row per city/municipality x category, summed over ownership and level
SELECT f.area_key, f.date_key, f.data_source_key, f.capacity_basis, f.coverage_basis, f.facility_category,
       'total'                                    AS ownership,
       'all'                                      AS hospital_level,
       sum(f.facility_count)                      AS facility_count,
       sum(f.authorized_beds)                     AS authorized_beds,
       sum(f.analysis_beds)                       AS analysis_beds,
       sum(f.dialysis_stations)                   AS dialysis_stations,
       sum(f.facilities_license_valid)            AS facilities_license_valid,
       CAST(NULL AS DOUBLE)                       AS bor_weighted_pct,
       CAST(NULL AS BIGINT)                       AS bor_reporting_record_count,
       'ok'                                       AS value_status,
       max(f.nhfr_as_of_date)                     AS nhfr_as_of_date,
       max(f.hfsrb_as_of_date)                    AS hfsrb_as_of_date
FROM public_health.gold.fact_facility_capacity AS f
WHERE f.capacity_basis = 'registry_snapshot' AND f.value_status = 'ok'
GROUP BY f.area_key, f.date_key, f.data_source_key, f.capacity_basis, f.coverage_basis, f.facility_category
UNION ALL
-- published statistics: the source's own total row
SELECT f.area_key, f.date_key, f.data_source_key, f.capacity_basis, f.coverage_basis, f.facility_category,
       f.ownership, 'all', f.facility_count, f.authorized_beds, f.analysis_beds, f.dialysis_stations,
       f.facilities_license_valid, CAST(NULL AS DOUBLE), CAST(NULL AS BIGINT), f.value_status,
       f.nhfr_as_of_date, f.hfsrb_as_of_date
FROM public_health.gold.fact_facility_capacity AS f
WHERE f.capacity_basis = 'published_statistic' AND f.ownership = 'total' AND f.value_status = 'ok'
UNION ALL
-- occupancy: ownership total, all levels, every geographic level (coverage_basis tells them apart)
SELECT f.area_key, f.date_key, f.data_source_key, f.capacity_basis, f.coverage_basis, f.facility_category,
       f.ownership, f.hospital_level, f.facility_count, f.authorized_beds, f.analysis_beds, f.dialysis_stations,
       f.facilities_license_valid, f.bor_weighted_pct, f.bor_reporting_record_count, f.value_status,
       f.nhfr_as_of_date, f.hfsrb_as_of_date
FROM public_health.gold.fact_facility_capacity AS f
WHERE f.capacity_basis = 'occupancy_report' AND f.ownership = 'total' AND f.hospital_level = 'all';
-- occupancy keeps suppressed rows (value null, value_status = 'suppressed') so a blank is explained

-- [2] Disease metric totals -------------------------------------------------------------------
CREATE OR REPLACE VIEW public_health.gold.v_disease_metric_totals AS
WITH base AS (
  SELECT f.fact_disease_metric_key, f.disease_key, f.area_key, f.date_key, f.data_source_key,
         f.metric_name, f.value, f.value_lower, f.value_upper, f.value_status, f.metric_definition,
         f.coverage_basis, f.is_complete_year, f.is_preliminary,
         d.disease_code, d.disease_name, d.classification,
         s.source_dataset, s.value_type,
         t.period_basis, t.period_grain, t.period_label, t.year,
         g.geographic_level
  FROM public_health.gold.fact_disease_metric AS f
  INNER JOIN public_health.gold.dim_disease AS d ON d.disease_key = f.disease_key
  INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
  INNER JOIN public_health.gold.dim_date AS t ON t.date_key = f.date_key
  INNER JOIN public_health.gold.dim_geography AS g ON g.area_key = f.area_key
  WHERE f.age_group = 'all_ages' AND f.sex = 'both_sexes'
),

preferred AS (
  SELECT DISTINCT b.fact_disease_metric_key
  FROM base AS b
  INNER JOIN public_health.gold.source_priority AS p
    ON p.role = 'preferred'
   AND p.data_source_key = b.data_source_key
   AND p.metric = b.metric_name
   AND p.period_grain = b.period_grain
   AND b.year BETWEEN p.year_from AND p.year_to
   AND (p.geo_level = 'any' OR p.geo_level = b.geographic_level)
   AND (p.disease_scope = b.disease_code OR p.disease_scope = b.classification
        OR (p.disease_scope = 'tuberculosis' AND b.disease_code LIKE 'tb%'))
)

SELECT b.*, (pr.fact_disease_metric_key IS NOT NULL) AS is_preferred_source
FROM base AS b
LEFT JOIN preferred AS pr ON pr.fact_disease_metric_key = b.fact_disease_metric_key;
-- For one series: WHERE is_preferred_source AND value_status = 'ok' AND metric_name = ... AND one
-- coverage_basis. Suppressed claims cells stay (value null) so a blank is explained.

-- [3] Workforce, preferred source ------------------------------------------------------------
CREATE OR REPLACE VIEW public_health.gold.v_workforce_preferred AS
SELECT f.fact_workforce_capacity_key, f.area_key, f.date_key, f.data_source_key,
       f.profession_code, f.profession_name, f.profession_group,
       f.headcount_total, f.headcount_lgu_hired, f.headcount_doh_hired,
       f.coverage_basis, f.is_break_year, f.exclusion_reason,
       t.year, s.source_dataset
FROM public_health.gold.fact_workforce_capacity AS f
INNER JOIN public_health.gold.dim_date AS t ON t.date_key = f.date_key
INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
WHERE f.source_role = 'preferred' AND f.analysis_eligible;
-- Rates still need the planning-unit mapping (area_coverage_map) and a census denominator.

-- [4] Area indicators with the latest-period flag ---------------------------------------------
CREATE OR REPLACE VIEW public_health.gold.v_area_indicator_latest AS
SELECT f.fact_area_indicator_key, f.area_key, f.date_key, f.data_source_key,
       f.indicator_name, f.indicator_category, f.category_level, f.parent_category, f.indicator_unit,
       f.value, f.value_note, f.coverage_basis, f.comparison_eligible, f.exclusion_reason,
       t.year, s.source_dataset,
       row_number() OVER (PARTITION BY f.area_key, f.data_source_key, f.indicator_name, f.indicator_category,
                                       coalesce(f.parent_category, ''), f.category_level
                          ORDER BY t.year DESC) = 1 AS is_latest_period
FROM public_health.gold.fact_area_indicator AS f
INNER JOIN public_health.gold.dim_date AS t ON t.date_key = f.date_key
INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
WHERE f.value_status = 'ok';
-- Census population of an area today: WHERE indicator_name = 'population' AND indicator_category =
-- 'census' AND is_latest_period. Poverty comparisons: AND comparison_eligible.


-- Checks to read after creating the views (nothing is stopped)
-- 1. Registry totals in the view equal the registry rows of gold 06 summed per locality and
--    category (2,575 rows on 2026-10-14). Facilities and beds equal the fact's registry totals.
SELECT capacity_basis, facility_category, count(*) AS rows_, sum(facility_count) AS facilities, sum(analysis_beds) AS beds
FROM public_health.gold.v_facility_capacity_totals
GROUP BY capacity_basis, facility_category
ORDER BY capacity_basis, facility_category;

-- 2. Share of all-ages rows with a preferred source, per source: a source with 0% needs a
--    source_priority row (or is cross_check only)
SELECT source_dataset, metric_name, count(*) AS rows_, count_if(is_preferred_source) AS preferred_rows
FROM public_health.gold.v_disease_metric_totals
GROUP BY source_dataset, metric_name
ORDER BY source_dataset, metric_name;