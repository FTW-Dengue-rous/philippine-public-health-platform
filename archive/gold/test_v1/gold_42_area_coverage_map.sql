-- ========================================
-- Creates two views in public_health.test_gold
--
-- 1. huc_province_crosswalk
--      One row is: one highly urbanized city (HUC) outside NCR, with the province it sits in.
--      Key: huc_area_key
-- 2. area_coverage_map
--      One row is: one area published by one source in one year in one fact table, with how
--      it maps to a planning unit.
--      Key: (fact_table, source_key, geo_coverage_basis, area_key, period_key)
--
-- Why
--   Sources publish province values on different bases: with or without the highly urbanized
--   cities, with or without the cities listed apart. A planning unit is a province without its
--   HUCs, each HUC on its own, and NCR as one unit (open decision 2). This map says, for each
--   published row, whether it IS a planning unit, is ONE PART of one, or cannot be used.
--
-- mapping_outcome
--   direct         the row is the planning unit
--   aggregate      the row is one part. All parts of the unit add up to it (counts only)
--   not_separable  the row covers more or less than the planning unit and cannot be split
--   not_used       a lower row already inside a published province or region row
--   out_of_scope   not a planning unit level (country, region, district, historical area)
--
-- Rules, by the coverage basis of the PROVINCE row
--   province_excl_listed_cities...  aggregate. Every city listed in the same source and year
--                                   (not a HUC) is a part
--   province_excl_huc_icc           aggregate with its independent component cities (ICC).
--                                   Other cities and municipalities are already inside
--   province, province_excl_huc     direct, unless the source lists a city apart
--                                   (..listed_separately): then both are parts
--   province_incl...                not_separable (it holds a HUC, which is its own unit)
--   modelled_province_coverage_unconfirmed (IHME)
--                                   ASSUMED to include the HUCs (decision D5 is open):
--                                   direct when the province has no HUC, else not_separable
--   anything else                   not_separable
--   A HUC row and the NCR region row are direct. Rows of NCR cities are not_used.
--
-- Differences from the v3 column list
--   * This is a view worked out by rule, not a reviewed CSV. The rules above are the review
--     item. Nobody types area codes.
--   * It has one row per year (v3 has year_from and year_to), because the basis of a source
--     changes by year. fact_table is added because one source feeds several facts.
--   * unit_parts_present and unit_parts_expected are added so a mart can refuse a unit with a
--     missing part.
--
-- huc_province_crosswalk is a name list (17 HUCs outside NCR). Codes are looked up in
-- dim_geography by name, level and region. CHECK the last query of this file: every HUC
-- outside NCR must be matched.
--
-- Reads: dim_geography, dim_period, dim_source, fact_workforce, fact_population,
--        fact_facility_published, fact_poverty, fact_disease_metric
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold.huc_province_crosswalk AS
WITH seed AS (
  SELECT * FROM VALUES
    ('baguio', 'benguet'), ('angeles', 'pampanga'), ('olongapo', 'zambales'), ('lucena', 'quezon'),
    ('puerto princesa', 'palawan'), ('iloilo', 'iloilo'), ('bacolod', 'negros occidental'),
    ('cebu', 'cebu'), ('lapu lapu', 'cebu'), ('mandaue', 'cebu'), ('tacloban', 'leyte'),
    ('zamboanga', 'zamboanga del sur'), ('cagayan de oro', 'misamis oriental'), ('iligan', 'lanao del norte'),
    ('davao', 'davao del sur'), ('general santos', 'south cotabato'), ('butuan', 'agusan del norte')
    AS t (huc_name_norm, province_name_norm)
),

named AS (
  SELECT area_key, area_code, area_name, geographic_level, city_class, region_key,
         trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           lower(area_name), '[(][^)]*[)]', ' '), '[^a-z0-9]+', ' '), '^ *city of ', ''), ' city *$', '')) AS name_norm
  FROM public_health.test_gold.dim_geography
  WHERE geographic_level IN ('city', 'province')
)

SELECT h.area_key AS huc_area_key, h.area_code AS huc_area_code, h.area_name AS huc_name,
       p.area_key AS province_area_key, p.area_code AS province_area_code, p.area_name AS province_name,
       CASE WHEN s.huc_name_norm IS NULL THEN 'not_in_name_list'
            WHEN p.area_key IS NULL THEN 'province_not_found'
            ELSE 'matched' END AS match_status
FROM named AS h
LEFT JOIN seed AS s ON s.huc_name_norm = h.name_norm
LEFT JOIN named AS p
  ON p.geographic_level = 'province' AND p.name_norm = s.province_name_norm AND p.region_key = h.region_key
WHERE h.geographic_level = 'city' AND h.city_class = 'HUC' AND h.area_code NOT LIKE 'psgc:13%';


CREATE OR REPLACE VIEW public_health.test_gold.area_coverage_map AS
WITH published AS (
  SELECT 'fact_workforce' AS fact_table, source_key, area_key, period_key, coverage_basis
  FROM public_health.test_gold.fact_workforce
  UNION
  SELECT 'fact_population', source_key, area_key, period_key, coverage_basis
  FROM public_health.test_gold.fact_population
  WHERE population_type = 'reported'
  UNION
  SELECT 'fact_facility_published', source_key, area_key, period_key, coverage_basis
  FROM public_health.test_gold.fact_facility_published
  UNION
  SELECT 'fact_poverty', source_key, area_key, period_key, coverage_basis
  FROM public_health.test_gold.fact_poverty
  UNION
  SELECT 'fact_disease_metric', f.source_key, f.area_key, f.period_key, f.coverage_basis
  FROM public_health.test_gold.fact_disease_metric AS f
  INNER JOIN public_health.test_gold.dim_source AS s
    ON s.source_key = f.source_key AND s.source_dataset = 'ihme_gbd'
),

area_rows AS (
  SELECT p.fact_table, p.source_key, s.source_dataset, p.area_key, p.period_key, p.coverage_basis,
         CAST(d.year AS INT) AS year,
         g.area_code, g.area_name, g.geographic_level, g.city_class,
         g.planning_unit_key AS unit_key,
         (g.area_code LIKE 'psgc:13%') AS is_ncr,
         (g.geographic_level = 'city' AND coalesce(g.city_class, '') <> 'HUC'
          AND g.planning_unit_key <> g.area_key) AS is_city_inside_province
  FROM published AS p
  INNER JOIN public_health.test_gold.dim_source AS s ON s.source_key = p.source_key
  INNER JOIN public_health.test_gold.dim_period AS d ON d.period_key = p.period_key
  INNER JOIN public_health.test_gold.dim_geography AS g ON g.area_key = p.area_key
),

in_context AS (
  SELECT r.*,
         max(CASE WHEN r.geographic_level = 'province' THEN r.coverage_basis END) OVER unit_rows AS province_basis,
         count_if(r.is_city_inside_province) OVER unit_rows AS cities_listed,
         count_if(r.is_city_inside_province AND r.coverage_basis LIKE '%listed_separately%') OVER unit_rows
           AS cities_listed_separately
  FROM area_rows AS r
  WINDOW unit_rows AS (PARTITION BY r.fact_table, r.source_key, r.period_key, r.unit_key)
),

icc AS (
  SELECT planning_unit_key AS unit_key, count(*) AS icc_in_unit
  FROM public_health.test_gold.dim_geography
  WHERE geographic_level = 'city' AND city_class = 'ICC' AND planning_unit_key <> area_key
  GROUP BY planning_unit_key
),

huc AS (
  SELECT province_area_key, count(*) AS huc_in_province
  FROM public_health.test_gold.huc_province_crosswalk
  WHERE match_status = 'matched'
  GROUP BY province_area_key
),

mapped AS (
  SELECT c.*, coalesce(i.icc_in_unit, 0) AS icc_in_unit, coalesce(h.huc_in_province, 0) AS huc_in_province,
         CASE
           WHEN c.area_code = 'psgc:1300000000' THEN 'direct'
           WHEN c.is_ncr AND c.geographic_level IN ('city', 'municipality') THEN 'not_used'
           WHEN c.geographic_level NOT IN ('province', 'city', 'municipality') THEN 'out_of_scope'
           WHEN c.geographic_level = 'municipality'
             THEN CASE WHEN c.unit_key = c.area_key THEN 'direct' ELSE 'not_used' END
           WHEN c.geographic_level = 'city' AND NOT c.is_city_inside_province THEN 'direct'
           WHEN c.geographic_level = 'city' THEN
             CASE WHEN c.province_basis LIKE 'province_excl_listed_cities%' THEN 'aggregate'
                  WHEN c.province_basis = 'province_excl_huc_icc' AND c.city_class = 'ICC' THEN 'aggregate'
                  WHEN c.province_basis IN ('province', 'province_excl_huc')
                       AND c.coverage_basis LIKE '%listed_separately%' THEN 'aggregate'
                  ELSE 'not_used' END
           WHEN c.coverage_basis LIKE 'province_incl%' THEN 'not_separable'
           WHEN c.coverage_basis LIKE 'province_excl_listed_cities%'
             THEN CASE WHEN c.cities_listed > 0 THEN 'aggregate' ELSE 'direct' END
           WHEN c.coverage_basis = 'province_excl_huc_icc'
             THEN CASE WHEN coalesce(i.icc_in_unit, 0) > 0 THEN 'aggregate' ELSE 'direct' END
           WHEN c.coverage_basis IN ('province', 'province_excl_huc')
             THEN CASE WHEN c.cities_listed_separately > 0 THEN 'aggregate' ELSE 'direct' END
           WHEN c.coverage_basis = 'modelled_province_coverage_unconfirmed'
             THEN CASE WHEN coalesce(h.huc_in_province, 0) > 0 THEN 'not_separable' ELSE 'direct' END
           ELSE 'not_separable'
         END AS mapping_outcome
  FROM in_context AS c
  LEFT JOIN icc AS i ON i.unit_key = c.unit_key
  LEFT JOIN huc AS h ON h.province_area_key = c.area_key
),

counted AS (
  SELECT m.*,
         count_if(m.mapping_outcome IN ('direct', 'aggregate')) OVER unit_rows AS parts_present,
         array_join(array_sort(collect_list(
           CASE WHEN m.geographic_level = 'city' AND m.mapping_outcome = 'aggregate' THEN m.area_code END
         ) OVER unit_rows), ', ') AS cities_added
  FROM mapped AS m
  WINDOW unit_rows AS (PARTITION BY m.fact_table, m.source_key, m.period_key, m.unit_key)
)

SELECT c.fact_table,
       c.source_key,
       c.source_dataset,
       c.coverage_basis AS geo_coverage_basis,
       c.area_key,
       c.area_code,
       c.area_name,
       c.geographic_level,
       c.period_key,
       c.year,
       c.mapping_outcome,
       CASE WHEN c.mapping_outcome IN ('direct', 'aggregate') THEN c.unit_key END AS planning_unit_key,
       CASE WHEN c.geographic_level = 'province' OR c.area_code = 'psgc:1300000000' THEN c.area_key
            ELSE x.province_area_key END AS broad_unit_key,
       CASE WHEN c.mapping_outcome IN ('direct', 'aggregate') THEN c.parts_present END AS unit_parts_present,
       CASE WHEN c.mapping_outcome NOT IN ('direct', 'aggregate') THEN NULL
            WHEN c.province_basis = 'province_excl_huc_icc' THEN 1 + c.icc_in_unit
            ELSE c.parts_present END AS unit_parts_expected,
       CASE WHEN c.geographic_level = 'province' AND c.mapping_outcome = 'aggregate'
            THEN nullif(c.cities_added, '') END AS cities_included,
       CASE c.mapping_outcome
         WHEN 'direct' THEN
           CASE WHEN c.coverage_basis = 'modelled_province_coverage_unconfirmed'
                THEN 'Province has no HUC, so the open coverage question (D5) does not change it'
                ELSE 'The row is the planning unit' END
         WHEN 'aggregate' THEN 'One part of the planning unit. Add the parts, counts only'
         WHEN 'not_separable' THEN
           CASE WHEN c.coverage_basis LIKE 'province_incl%' THEN 'Province value includes its HUC'
                WHEN c.coverage_basis = 'modelled_province_coverage_unconfirmed'
                  THEN 'Assumed to include the HUC of the province. Not confirmed (D5)'
                ELSE 'Coverage of the row is not confirmed' END
         WHEN 'not_used' THEN 'Already inside a published province or region row'
         ELSE 'Not a planning unit level'
       END AS note
FROM counted AS c
LEFT JOIN public_health.test_gold.huc_province_crosswalk AS x
  ON x.huc_area_key = c.area_key AND x.match_status = 'matched';


-- Checks to read after creating the views (nothing is stopped)
-- 1. Every HUC outside NCR must be matched. Expected: 17 rows, all 'matched'.
SELECT match_status, count(*) AS hucs, array_join(collect_list(huc_name), '; ') AS names
FROM public_health.test_gold.huc_province_crosswalk
GROUP BY match_status;

-- 2. Rows per fact, source and outcome
SELECT fact_table, source_dataset, geo_coverage_basis, mapping_outcome, count(*) AS area_years
FROM public_health.test_gold.area_coverage_map
GROUP BY fact_table, source_dataset, geo_coverage_basis, mapping_outcome
ORDER BY fact_table, source_dataset, geo_coverage_basis, mapping_outcome;
