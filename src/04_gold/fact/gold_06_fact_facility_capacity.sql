-- ========================================
-- Builds public_health.gold.fact_facility_capacity
--   One row is: one capacity measurement of one facility group (category, ownership,
--   hospital level) in one area and period, from one source and capacity basis
--   Primary key: fact_facility_capacity_key = xxhash64 of the grain (hospital_level null
--                hashed as '-'). Stable across rebuilds.
--   Grain: (area_key, date_key, data_source_key, capacity_basis, facility_category, ownership,
--          hospital_level)
--
-- Reads
--   public_health.silver.facilities_registry_silver
--   public_health.silver.facilities_metric_silver
--   public_health.silver.facilities_bed_occupancy_silver
--   public_health.gold.dim_geography, dim_date, dim_data_source (gold 01-03)
--
-- Three capacity bases (capacity_basis)
--   registry_snapshot    the facility registry today, counted per city / municipality and group
--   published_statistic  PSA and FHSIS published counts by year
--   occupancy_report     DOH/HFSRB bed occupancy by year (restricted source)
--
-- Rules
--   * ALWAYS filter capacity_basis before adding anything up. The three bases overlap on
--     purpose: a hospital is counted in the registry and in the PSA tables.
--   * Each basis fills only its own measure columns. The others are null (a gate checks it).
--   * Registry: only facility_status = listed is counted. A facility in a Manila
--     submunicipality is counted in the City of Manila. hospital_level is Level 1, 2, 3 or
--     unknown for hospitals and null for the other categories. dialysis_stations is null
--     when no facility in the group has a known count. The date is the registry snapshot
--     (the later of the NHFR and HFSRB as-of dates), the same label as dim_date.
--   * Published: sources overlap on purpose, so filter data_source_key too. total rows sit
--     beside government and private rows: never sum across ownership. Never add ph, region
--     and child rows together. hospital_level is null (not published by level).
--   * Occupancy: restricted source (D-47: academic use, aggregates only, suppress small cells).
--     Never matched to facilities. Source doh_foi_hospital_beds, 2018-2025, both ownerships,
--     city / municipality, authorized beds every year. A group of fewer than
--     suppression_min_records records is suppressed (value_status suppressed, bor measures
--     null). Roll up with sum(bor_weighted_pct * bor_weighted_beds_sum) /
--     sum(bor_weighted_beds_sum). Never average a rate.
--     baseline_validated stays false until HFSRB confirms the bed basis and the reporting
--     period (O-12).
--   * Occupancy is published at THREE geographic levels, told apart by coverage_basis, each
--     suppressed at its own level (first run, 2026-10-14: 89% of city / municipality groups had
--     fewer than 3 hospitals):
--       - the silver level (city / municipality; coverage_basis as silver gives it),
--       - province_excl_huc: the parent province of municipalities and component cities
--         (HUCs and ICCs hang on the region and are not in a province row),
--       - region: every record, by region.
--     Each level is a complete pass over the same silver records (gates check it). Never add
--     levels together, and always filter coverage_basis with capacity_basis = occupancy_report.
--   * Occupancy also carries THREE breakdowns at every geographic level (second run: province
--     rows were still 61% suppressed because ownership x level cells are small):
--       - ownership and hospital_level as reported (government / private x Level 1 / 2 / 3 / unknown),
--       - ownership with hospital_level 'all',
--       - ownership 'total' with hospital_level 'all' (every hospital of the area-year).
--     As with the published rows, total sits beside government and private: filter ownership
--     (and hospital_level) before adding anything. For "capacity pressure of a province" read
--     coverage_basis = 'province_excl_huc', ownership = 'total', hospital_level = 'all'.
--   * A locality with no facility has no registry row. "No hospital recorded" (A1) comes
--     from dim_geography left joined to this fact, in the marts (gold 14).
--   * Safe totals: v_facility_capacity_totals (gold 13) applies these filters.
--
-- Build steps (write-audit-publish)
--   [0] build id and settings
--   [1] __inputs     every input, with the build that wrote it and its latest silver QC
--   [2] __candidate  the candidate rows
--   [3] __gates      every gate must have failures = 0
--   [4] stop if a gate failed: the failed build is logged, the published table is not touched
--   [5] write the table from the candidate (full rebuild)
--   [6] record the build in quality.build_log and quality.build_inputs
--   [7] drop the staging tables, then show the summary
--
-- History
--   2026-10-14  Written for the combined data model (from gold_20, v1). Occupancy source
--               changed to doh_foi_hospital_beds; three geographic levels and three
--               breakdowns added after the first two runs.
--   2026-10-20  Moved to public_health.gold and renamed gold_06. Comments updated (D-47, O-12).
--               'model' removed from the build log parameters. No change to the table.
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
-- true : every silver input needs a succeeded build in quality.build_log.
-- false: a silver table written by a notebook is allowed. Gold inputs always need one.
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
-- true : a silver input whose latest QC (quality.v_table_health) has a FAIL stops the build.
--        No QC run does not stop it; it makes the approval provisional (step [4]).
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job
-- Smallest number of hospital records a published occupancy group may be built from
-- (D-47: suppress cells under 3). Recorded in build_log.parameters.
DECLARE OR REPLACE VARIABLE suppression_min_records INT DEFAULT 3;


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_facility_capacity__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_registry_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_registry_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_metric_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_metric_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_bed_occupancy_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_bed_occupancy_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_date' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_date
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_data_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_data_source
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
-- registry_snapshot (v1 gold_22) ------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW fcap_registry_snapshot AS
SELECT max(greatest(_nhfr_as_of_date, _hfsrb_as_of_date)) AS snapshot_date
FROM public_health.silver.facilities_registry_silver;

CREATE OR REPLACE TEMP VIEW fcap_registry_src AS
SELECT coalesce(city.area_key, g.area_key, xxhash64(r.area_key)) AS area_key,
       r.facility_category,
       CASE WHEN r.facility_category = 'hospital'
            THEN coalesce(nullif(regexp_extract(r.service_level, '(Level [1-3])', 1), ''), 'unknown') END AS hospital_level,
       lower(trim(r.ownership))                   AS ownership,
       r.is_license_valid_on_as_of,
       r.authorized_beds, r.analysis_beds, r.dialysis_stations,
       r._nhfr_as_of_date, r._hfsrb_as_of_date
FROM public_health.silver.facilities_registry_silver AS r
LEFT JOIN public_health.gold.dim_geography AS g ON g.area_code = r.area_key
LEFT JOIN public_health.gold.dim_geography AS city
  ON g.geographic_level = 'submunicipality' AND city.area_key = g.parent_area_key
 AND city.geographic_level = 'city'
WHERE r.facility_status = 'listed';

CREATE OR REPLACE TEMP VIEW fcap_registry AS
SELECT area_key,
       xxhash64('snapshot', date_format(max(s.snapshot_date), 'yyyy-MM-dd')) AS date_key,
       xxhash64('facilities_registry')            AS data_source_key,
       'registry_snapshot'                        AS capacity_basis,
       facility_category,
       ownership,
       hospital_level,
       CAST(count(*) AS BIGINT)                   AS facility_count,
       CAST(sum(authorized_beds) AS BIGINT)       AS authorized_beds,
       CAST(sum(analysis_beds) AS BIGINT)         AS analysis_beds,
       CAST(sum(dialysis_stations) AS BIGINT)     AS dialysis_stations,
       CAST(count_if(dialysis_stations IS NOT NULL) AS BIGINT) AS dialysis_facilities_stations_known,
       CAST(count_if(facility_category = 'dialysis_clinic' AND dialysis_stations IS NULL) AS BIGINT)
                                                  AS dialysis_facilities_stations_unknown,
       CAST(count_if(is_license_valid_on_as_of) AS BIGINT) AS facilities_license_valid,
       CAST(count_if(facility_category IN ('hospital', 'infirmary') AND analysis_beds IS NULL) AS BIGINT)
                                                  AS facilities_without_beds,
       max(_nhfr_as_of_date)                      AS nhfr_as_of_date,
       max(_hfsrb_as_of_date)                     AS hfsrb_as_of_date,
       'ok'                                       AS value_status,
       'city_municipality'                        AS coverage_basis
FROM fcap_registry_src
CROSS JOIN fcap_registry_snapshot AS s
GROUP BY area_key, facility_category, hospital_level, ownership;

-- published_statistic ----------------------------------------------------------
CREATE OR REPLACE TEMP VIEW fcap_published_long AS
SELECT m.area_key AS area_code, CAST(m.year AS INT) AS year, m._source_key, m.ownership,
       m.geo_coverage_basis, m.series_definition, m.is_break_year, m.no_report_measures,
       CAST(m.authorized_beds AS BIGINT) AS beds,
       stack(6, 'hospitals', CAST(m.hospitals AS BIGINT), 'bhs', CAST(m.bhs AS BIGINT),
                'rhu', CAST(m.rhu AS BIGINT), 'mhc', CAST(m.mhc AS BIGINT), 'chc', CAST(m.chc AS BIGINT),
                'health_centers_total', CAST(m.health_centers_total AS BIGINT)) AS (facility_type, facility_count)
FROM public_health.silver.facilities_metric_silver AS m;

CREATE OR REPLACE TEMP VIEW fcap_published AS
SELECT xxhash64(area_code)                        AS area_key,
       xxhash64('calendar_year', CAST(year AS STRING)) AS date_key,
       xxhash64(_source_key)                      AS data_source_key,
       'published_statistic'                      AS capacity_basis,
       CASE facility_type WHEN 'hospitals' THEN 'hospital' WHEN 'bhs' THEN 'barangay_health_station'
                          WHEN 'rhu' THEN 'rural_health_unit' WHEN 'mhc' THEN 'main_health_center'
                          WHEN 'chc' THEN 'city_health_center' WHEN 'health_centers_total' THEN 'health_center_total'
       END                                        AS facility_category,
       ownership,
       CAST(NULL AS STRING)                       AS hospital_level,
       facility_count,
       CASE WHEN facility_type = 'hospitals' THEN beds END AS authorized_beds,
       CASE WHEN facility_count IS NOT NULL OR (facility_type = 'hospitals' AND beds IS NOT NULL) THEN 'ok'
            ELSE 'no_report' END                  AS value_status,
       geo_coverage_basis                         AS coverage_basis,
       CASE WHEN facility_type = 'hospitals' THEN series_definition END AS series_definition,
       (facility_type = 'hospitals' AND coalesce(is_break_year, false)) AS is_break_year
FROM fcap_published_long
WHERE facility_count IS NOT NULL
   OR (facility_type = 'hospitals' AND beds IS NOT NULL)
   OR array_contains(no_report_measures, facility_type)
   OR (facility_type = 'hospitals' AND array_contains(no_report_measures, 'authorized_beds'));

-- occupancy_report -------------------------------------------------------------
-- One silver row = one reporting hospital in one year. Each row is given its own area, its
-- province (municipalities and component cities only) and its region from dim_geography, then
-- counted once at each level. Suppression is applied per level after grouping.
CREATE OR REPLACE TEMP VIEW fcap_occupancy_src AS
SELECT o.area_key                                 AS area_code,
       CAST(o.year AS INT)                        AS year,
       o._source_key,
       o.ownership,
       coalesce(nullif(trim(o.service_level), ''), 'unknown') AS hospital_level,
       o.geo_coverage_basis,
       o.baseline_eligible, o.authorized_beds, o.bor_pct, o.bor_basis_confirmed, o.period_confirmed,
       coalesce(g.area_key, xxhash64(o.area_key)) AS base_key,
       CASE WHEN p.geographic_level = 'province' THEN p.area_key END AS province_key,
       CASE WHEN p.geographic_level = 'region' THEN p.area_key
            WHEN pp.geographic_level = 'region' THEN pp.area_key END AS region_key
FROM public_health.silver.facilities_bed_occupancy_silver AS o
LEFT JOIN public_health.gold.dim_geography AS g ON g.area_code = o.area_key
LEFT JOIN public_health.gold.dim_geography AS p ON p.area_key = g.parent_area_key
LEFT JOIN public_health.gold.dim_geography AS pp ON pp.area_key = p.parent_area_key;

-- Two roll-up axes, crossed: geography (3 levels) x breakdown (3: ownership and level as reported,
-- ownership with hospital_level 'all', and ownership 'total' with hospital_level 'all'). Every
-- record is counted once in each of the 9 combinations that apply to it.
CREATE OR REPLACE TEMP VIEW fcap_occupancy_levels AS
SELECT s.area_code, s.year, s._source_key, s.geo_coverage_basis,
       s.baseline_eligible, s.authorized_beds, s.bor_pct, s.bor_basis_confirmed, s.period_confirmed,
       s.base_key, s.province_key, s.region_key,
       lvl.roll_level, lvl.roll_area_key, lvl.coverage_basis,
       brk.breakdown, brk.ownership, brk.hospital_level
FROM fcap_occupancy_src AS s
LATERAL VIEW explode(array(
  named_struct('roll_level', 'base',     'roll_area_key', s.base_key,     'coverage_basis', s.geo_coverage_basis),
  named_struct('roll_level', 'province', 'roll_area_key', s.province_key, 'coverage_basis', 'province_excl_huc'),
  named_struct('roll_level', 'region',   'roll_area_key', s.region_key,   'coverage_basis', 'region')
)) l AS lvl
LATERAL VIEW explode(array(
  named_struct('breakdown', 'ownership_level', 'ownership', s.ownership, 'hospital_level', s.hospital_level),
  named_struct('breakdown', 'ownership',       'ownership', s.ownership, 'hospital_level', 'all'),
  named_struct('breakdown', 'total',           'ownership', 'total',     'hospital_level', 'all')
)) b AS brk
WHERE lvl.roll_area_key IS NOT NULL;

CREATE OR REPLACE TEMP VIEW fcap_occupancy_grouped AS
SELECT roll_level,
       breakdown,
       roll_area_key                              AS area_key,
       year,
       _source_key,
       ownership,
       hospital_level,
       coverage_basis,
       count(*)                                   AS records,
       count_if(baseline_eligible)                AS eligible_records,
       sum(CASE WHEN baseline_eligible AND authorized_beds IS NOT NULL
                THEN CAST(bor_pct AS DOUBLE) * authorized_beds END) AS bor_x_beds_sum,
       sum(CASE WHEN baseline_eligible AND bor_pct IS NOT NULL
                THEN CAST(authorized_beds AS DOUBLE) END)           AS weight_beds_sum,
       percentile(CASE WHEN baseline_eligible THEN CAST(bor_pct AS DOUBLE) END, 0.5) AS bor_median,
       coalesce(bool_and(bor_basis_confirmed), false) AND coalesce(bool_and(period_confirmed), false) AS baseline_validated
FROM fcap_occupancy_levels
GROUP BY roll_level, breakdown, roll_area_key, year, _source_key, ownership, hospital_level, coverage_basis;

CREATE OR REPLACE TEMP VIEW fcap_occupancy AS
SELECT area_key,
       xxhash64('calendar_year', CAST(year AS STRING)) AS date_key,
       xxhash64(_source_key)                      AS data_source_key,
       'occupancy_report'                         AS capacity_basis,
       'hospital'                                 AS facility_category,
       ownership,
       hospital_level,
       CAST(records AS BIGINT)                    AS bor_reporting_record_count,
       CASE WHEN records >= suppression_min_records THEN CAST(eligible_records AS BIGINT) END AS bor_eligible_record_count,
       CASE WHEN records >= suppression_min_records AND weight_beds_sum > 0
            THEN CAST(bor_x_beds_sum / weight_beds_sum AS DECIMAL(9, 4)) END AS bor_weighted_pct,
       CASE WHEN records >= suppression_min_records THEN CAST(bor_median AS DECIMAL(9, 4)) END AS bor_median_pct,
       CASE WHEN records >= suppression_min_records THEN CAST(weight_beds_sum AS DECIMAL(18, 2)) END AS bor_weighted_beds_sum,
       baseline_validated,
       CASE WHEN records < suppression_min_records THEN 'suppressed' ELSE 'ok' END AS value_status,
       coverage_basis
FROM fcap_occupancy_grouped;

-- one table ---------------------------------------------------------------------------------
CREATE OR REPLACE TEMP VIEW fcap_all AS
SELECT area_key, date_key, data_source_key, capacity_basis, facility_category, ownership, hospital_level,
       facility_count, authorized_beds, analysis_beds, dialysis_stations,
       dialysis_facilities_stations_known, dialysis_facilities_stations_unknown,
       facilities_license_valid, facilities_without_beds,
       CAST(NULL AS DECIMAL(9, 4)) AS bor_weighted_pct, CAST(NULL AS DECIMAL(9, 4)) AS bor_median_pct,
       CAST(NULL AS BIGINT) AS bor_reporting_record_count, CAST(NULL AS BIGINT) AS bor_eligible_record_count,
       CAST(NULL AS DECIMAL(18, 2)) AS bor_weighted_beds_sum,
       value_status, coverage_basis,
       CAST(NULL AS STRING) AS series_definition, CAST(NULL AS BOOLEAN) AS is_break_year,
       CAST(NULL AS BOOLEAN) AS baseline_validated,
       nhfr_as_of_date, hfsrb_as_of_date
FROM fcap_registry
UNION ALL
SELECT area_key, date_key, data_source_key, capacity_basis, facility_category, ownership, hospital_level,
       facility_count, authorized_beds, CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
       CAST(NULL AS DECIMAL(9, 4)), CAST(NULL AS DECIMAL(9, 4)),
       CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
       CAST(NULL AS DECIMAL(18, 2)),
       value_status, coverage_basis,
       series_definition, is_break_year,
       CAST(NULL AS BOOLEAN),
       CAST(NULL AS DATE), CAST(NULL AS DATE)
FROM fcap_published
UNION ALL
SELECT area_key, date_key, data_source_key, capacity_basis, facility_category, ownership, hospital_level,
       CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), CAST(NULL AS BIGINT),
       bor_weighted_pct, bor_median_pct,
       bor_reporting_record_count, bor_eligible_record_count,
       bor_weighted_beds_sum,
       value_status, coverage_basis,
       CAST(NULL AS STRING), CAST(NULL AS BOOLEAN),
       baseline_validated,
       CAST(NULL AS DATE), CAST(NULL AS DATE)
FROM fcap_occupancy;

CREATE OR REPLACE TABLE public_health.gold.fact_facility_capacity__candidate AS
SELECT xxhash64(area_key, date_key, data_source_key, capacity_basis, facility_category, ownership,
                coalesce(hospital_level, '-'))    AS fact_facility_capacity_key,
       area_key,
       date_key,
       data_source_key,
       capacity_basis,
       facility_category,
       ownership,
       hospital_level,
       facility_count,
       authorized_beds,
       analysis_beds,
       dialysis_stations,
       dialysis_facilities_stations_known,
       dialysis_facilities_stations_unknown,
       facilities_license_valid,
       facilities_without_beds,
       bor_weighted_pct,
       bor_median_pct,
       bor_reporting_record_count,
       bor_eligible_record_count,
       bor_weighted_beds_sum,
       value_status,
       coverage_basis,
       series_definition,
       is_break_year,
       baseline_validated,
       nhfr_as_of_date,
       hfsrb_as_of_date,
       gold_build_id                              AS _gold_build_id
FROM fcap_all;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_facility_capacity__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.fact_facility_capacity__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.fact_facility_capacity__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.fact_facility_capacity__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.fact_facility_capacity__candidate
WHERE fact_facility_capacity_key IS NULL OR area_key IS NULL OR date_key IS NULL OR data_source_key IS NULL OR capacity_basis IS NULL OR facility_category IS NULL OR ownership IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_facility_capacity__candidate GROUP BY fact_facility_capacity_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_facility_capacity__candidate
  GROUP BY area_key, date_key, data_source_key, capacity_basis, facility_category, ownership, hospital_level HAVING count(*) > 1)
UNION ALL
SELECT 'capacity_basis outside the three bases', count(*) FROM public_health.gold.fact_facility_capacity__candidate WHERE capacity_basis NOT IN ('registry_snapshot', 'published_statistic', 'occupancy_report')
UNION ALL
SELECT 'facility_category not allowed for its capacity_basis', count(*) FROM public_health.gold.fact_facility_capacity__candidate
WHERE NOT ((capacity_basis = 'registry_snapshot' AND facility_category IN ('hospital', 'infirmary', 'primary_care', 'dialysis_clinic'))
        OR (capacity_basis = 'published_statistic' AND facility_category IN ('hospital', 'barangay_health_station', 'rural_health_unit',
                                                                             'main_health_center', 'city_health_center', 'health_center_total'))
        OR (capacity_basis = 'occupancy_report' AND facility_category = 'hospital'))
UNION ALL
SELECT 'ownership not allowed for its capacity_basis', count(*) FROM public_health.gold.fact_facility_capacity__candidate
WHERE NOT ((capacity_basis = 'published_statistic' AND ownership IN ('total', 'government', 'private'))
        OR (capacity_basis = 'occupancy_report' AND ownership IN ('total', 'government', 'private'))
        OR (capacity_basis = 'registry_snapshot' AND ownership IN ('government', 'private')))
UNION ALL
SELECT 'occupancy total row without hospital_level all, or level all with unknown breakdown', count(*) FROM public_health.gold.fact_facility_capacity__candidate
WHERE capacity_basis = 'occupancy_report'
  AND ((ownership = 'total' AND hospital_level <> 'all')
    OR (hospital_level = 'all' AND ownership NOT IN ('total', 'government', 'private')))
UNION ALL
SELECT 'hospital_level wrong for its basis (registry: hospitals only; published: none; occupancy: always)', count(*)
FROM public_health.gold.fact_facility_capacity__candidate
WHERE (capacity_basis = 'registry_snapshot' AND (facility_category = 'hospital') <> (hospital_level IS NOT NULL))
   OR (capacity_basis = 'published_statistic' AND hospital_level IS NOT NULL)
   OR (capacity_basis = 'occupancy_report' AND hospital_level IS NULL)
UNION ALL
SELECT 'measure filled on a row of another capacity_basis', count(*) FROM public_health.gold.fact_facility_capacity__candidate
WHERE (capacity_basis <> 'registry_snapshot' AND coalesce(CAST(analysis_beds AS STRING), CAST(dialysis_stations AS STRING), CAST(dialysis_facilities_stations_known AS STRING), CAST(dialysis_facilities_stations_unknown AS STRING), CAST(facilities_license_valid AS STRING), CAST(facilities_without_beds AS STRING), CAST(nhfr_as_of_date AS STRING), CAST(hfsrb_as_of_date AS STRING)) IS NOT NULL)
   OR (capacity_basis <> 'occupancy_report' AND coalesce(CAST(bor_weighted_pct AS STRING), CAST(bor_median_pct AS STRING), CAST(bor_reporting_record_count AS STRING), CAST(bor_eligible_record_count AS STRING), CAST(bor_weighted_beds_sum AS STRING), CAST(baseline_validated AS STRING)) IS NOT NULL)
   OR (capacity_basis <> 'published_statistic' AND coalesce(CAST(series_definition AS STRING), CAST(is_break_year AS STRING)) IS NOT NULL)
   OR (capacity_basis = 'occupancy_report' AND (facility_count IS NOT NULL OR authorized_beds IS NOT NULL))
UNION ALL
SELECT 'registry area that is not a city or municipality', count(*) FROM public_health.gold.fact_facility_capacity__candidate AS c
INNER JOIN public_health.gold.dim_geography AS g ON g.area_key = c.area_key
WHERE c.capacity_basis = 'registry_snapshot' AND g.geographic_level NOT IN ('city', 'municipality')
UNION ALL
SELECT 'registry facility_count total <> listed registry rows', abs(coalesce((SELECT sum(facility_count) FROM public_health.gold.fact_facility_capacity__candidate WHERE capacity_basis = 'registry_snapshot'), 0) - count(*))
FROM public_health.silver.facilities_registry_silver WHERE facility_status = 'listed'
UNION ALL
SELECT 'registry analysis beds total <> listed registry total', CAST(abs(coalesce((SELECT sum(analysis_beds) FROM public_health.gold.fact_facility_capacity__candidate), 0) - coalesce(sum(analysis_beds), 0)) AS BIGINT)
FROM public_health.silver.facilities_registry_silver WHERE facility_status = 'listed'
UNION ALL
SELECT 'registry dialysis stations total <> listed registry total', CAST(abs(coalesce((SELECT sum(dialysis_stations) FROM public_health.gold.fact_facility_capacity__candidate), 0) - coalesce(sum(dialysis_stations), 0)) AS BIGINT)
FROM public_health.silver.facilities_registry_silver WHERE facility_status = 'listed'
UNION ALL
SELECT 'dialysis_stations filled where no facility has a known count', count(*) FROM public_health.gold.fact_facility_capacity__candidate WHERE dialysis_facilities_stations_known = 0 AND dialysis_stations IS NOT NULL
UNION ALL
SELECT 'published hospitals total <> silver total', CAST(abs(coalesce((SELECT sum(facility_count) FROM public_health.gold.fact_facility_capacity__candidate WHERE capacity_basis = 'published_statistic' AND facility_category = 'hospital'), 0)
         - coalesce(sum(hospitals), 0)) AS BIGINT) FROM public_health.silver.facilities_metric_silver
UNION ALL
SELECT 'published bhs total <> silver total', CAST(abs(coalesce((SELECT sum(facility_count) FROM public_health.gold.fact_facility_capacity__candidate WHERE capacity_basis = 'published_statistic' AND facility_category = 'barangay_health_station'), 0)
         - coalesce(sum(bhs), 0)) AS BIGINT) FROM public_health.silver.facilities_metric_silver
UNION ALL
SELECT 'published authorized beds total <> silver total', CAST(abs(coalesce((SELECT sum(authorized_beds) FROM public_health.gold.fact_facility_capacity__candidate WHERE capacity_basis = 'published_statistic'), 0)
         - coalesce(sum(authorized_beds), 0)) AS BIGINT) FROM public_health.silver.facilities_metric_silver
UNION ALL
SELECT 'published beds on a row that is not hospital, or a negative value', count(*) FROM public_health.gold.fact_facility_capacity__candidate
WHERE (capacity_basis = 'published_statistic' AND facility_category <> 'hospital' AND authorized_beds IS NOT NULL)
   OR facility_count < 0 OR authorized_beds < 0
UNION ALL
SELECT 'occupancy base-level records total <> silver rows', abs(coalesce((SELECT sum(records) FROM fcap_occupancy_grouped WHERE roll_level = 'base' AND breakdown = 'ownership_level'), 0) - count(*))
FROM public_health.silver.facilities_bed_occupancy_silver
UNION ALL
SELECT 'occupancy region-level records total <> silver rows', abs(coalesce((SELECT sum(records) FROM fcap_occupancy_grouped WHERE roll_level = 'region' AND breakdown = 'ownership_level'), 0) - count(*))
FROM public_health.silver.facilities_bed_occupancy_silver
UNION ALL
SELECT 'occupancy province-level records total <> silver rows whose area is in a province', abs(coalesce((SELECT sum(records) FROM fcap_occupancy_grouped WHERE roll_level = 'province' AND breakdown = 'ownership_level'), 0) - count_if(province_key IS NOT NULL))
FROM fcap_occupancy_src
UNION ALL
SELECT 'occupancy breakdown (ownership, total) whose records differ from the ownership-level breakdown at the same geographic level', count(*) FROM (
  SELECT roll_level FROM fcap_occupancy_grouped GROUP BY roll_level HAVING count(DISTINCT breakdown) <> 3
      OR min(CASE WHEN breakdown = 'ownership_level' THEN records END) IS NULL
      OR sum(CASE WHEN breakdown = 'ownership_level' THEN records END) <> sum(CASE WHEN breakdown = 'ownership' THEN records END)
      OR sum(CASE WHEN breakdown = 'ownership_level' THEN records END) <> sum(CASE WHEN breakdown = 'total' THEN records END))
UNION ALL
SELECT 'occupancy record whose area has no region in dim_geography', count_if(region_key IS NULL) FROM fcap_occupancy_src
UNION ALL
SELECT 'occupancy roll-up row that collides with a silver-level row (same area, year, source, ownership, level)', count(*) FROM (
  SELECT 1 FROM fcap_occupancy_grouped GROUP BY area_key, year, _source_key, ownership, hospital_level HAVING count(DISTINCT roll_level) > 1)
UNION ALL
SELECT 'suppressed occupancy group that still shows a measure', count(*) FROM public_health.gold.fact_facility_capacity__candidate
WHERE value_status = 'suppressed' AND (bor_eligible_record_count IS NOT NULL OR bor_weighted_pct IS NOT NULL
   OR bor_median_pct IS NOT NULL OR bor_weighted_beds_sum IS NOT NULL)
UNION ALL
SELECT 'occupancy group below the suppression threshold that is not suppressed', count(*) FROM public_health.gold.fact_facility_capacity__candidate WHERE bor_reporting_record_count < suppression_min_records AND value_status <> 'suppressed'
UNION ALL
SELECT 'weighted occupancy rate without a positive bed weight', count(*) FROM public_health.gold.fact_facility_capacity__candidate WHERE bor_weighted_pct IS NOT NULL AND NOT (bor_weighted_beds_sum > 0)
UNION ALL
SELECT 'weighted or median occupancy rate outside 0 to 150', count(*) FROM public_health.gold.fact_facility_capacity__candidate WHERE bor_weighted_pct NOT BETWEEN 0 AND 150 OR bor_median_pct NOT BETWEEN 0 AND 150
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.gold.fact_facility_capacity__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'date_key not in dim_date', count(*) FROM (
  SELECT DISTINCT date_key AS k FROM public_health.gold.fact_facility_capacity__candidate WHERE date_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_date AS d ON d.date_key = c.k
UNION ALL
SELECT 'data_source_key not in dim_data_source', count(*) FROM (
  SELECT DISTINCT data_source_key AS k FROM public_health.gold.fact_facility_capacity__candidate WHERE data_source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_data_source AS d ON d.data_source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.fact_facility_capacity__gates WHERE failures <> 0
--     approval: provisional while a silver input has no QC run or has WARN findings to review.
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_facility_capacity_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'facilities'                                      AS domain,
       'public_health.gold.fact_facility_capacity'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds, 'suppression_min_records', suppression_min_records)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.fact_facility_capacity__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.fact_facility_capacity__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_facility_capacity_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_facility_capacity was NOT published. ', error_message))
FROM fact_facility_capacity_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_facility_capacity AS
SELECT * FROM public_health.gold.fact_facility_capacity__candidate;


-- ========================================
-- [6] record the build, with the table version just written. If your runtime rejects this
--     SET VAR, delete it: the version stays null, and freshness checks (G06,
--     mart_evidence_readiness) cannot compare this table.
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.fact_facility_capacity));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.fact_facility_capacity),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_facility_capacity_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.fact_facility_capacity', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.fact_facility_capacity__inputs;


-- ========================================
-- [7] remove the staging tables, then show the summary
-- ========================================
DROP TABLE IF EXISTS public_health.gold.fact_facility_capacity__candidate;
DROP TABLE IF EXISTS public_health.gold.fact_facility_capacity__gates;
DROP TABLE IF EXISTS public_health.gold.fact_facility_capacity__inputs;

-- Silver controls: registry 3,957 rows; published PSA 9.18 hospitals 2024 = 1,312, PSA 9.17 beds
-- 2024 = 114,623, FHSIS BHS 2024 = 25,532; occupancy (doh_foi_hospital_beds since 2026-10-14) 2018-2025 =
-- 9,145 records, 2025 = 1,209 (427 government, 782 private). Databricks 2026-10-14 (before the
-- three-level occupancy): 6,345 occupancy rows, 5,661 suppressed at city / municipality level.
-- Second run (three geographic levels, one breakdown): city 6,345 rows / 5,661 suppressed,
-- province 2,010 / 1,234, region 920 / 324. occupancy_records repeats the 9,145 once per
-- coverage_basis level and per breakdown: that is expected.
SELECT f.capacity_basis, s.source_dataset, f.facility_category, f.coverage_basis,
       CASE WHEN f.capacity_basis = 'occupancy_report'
            THEN CASE WHEN f.ownership = 'total' THEN 'total' WHEN f.hospital_level = 'all' THEN 'ownership' ELSE 'ownership_level' END END AS occupancy_breakdown,
       min(d.year) AS first_year, max(d.year) AS last_year,
       count(*) AS row_count, sum(f.facility_count) AS facilities, sum(f.authorized_beds) AS authorized_beds,
       sum(f.bor_reporting_record_count) AS occupancy_records, count_if(f.value_status <> 'ok') AS not_ok
FROM public_health.gold.fact_facility_capacity AS f
INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
INNER JOIN public_health.gold.dim_date AS d ON d.date_key = f.date_key
GROUP BY f.capacity_basis, s.source_dataset, f.facility_category, f.coverage_basis,
         CASE WHEN f.capacity_basis = 'occupancy_report'
              THEN CASE WHEN f.ownership = 'total' THEN 'total' WHEN f.hospital_level = 'all' THEN 'ownership' ELSE 'ownership_level' END END
ORDER BY f.capacity_basis, s.source_dataset, f.facility_category, f.coverage_basis, occupancy_breakdown;

-- Proof (A1, A3): cities and municipalities with no hospital and no primary care facility
-- RECORDED in the registry snapshot. Recorded is not a confirmed absence.
SELECT count(*) AS localities,
       count_if(coalesce(c.hospitals, 0) = 0) AS no_hospital_recorded,
       count_if(coalesce(c.primary_care, 0) = 0) AS no_primary_care_recorded
FROM public_health.gold.dim_geography AS g
LEFT JOIN (
  SELECT area_key,
         sum(CASE WHEN facility_category = 'hospital' THEN facility_count END) AS hospitals,
         sum(CASE WHEN facility_category = 'primary_care' THEN facility_count END) AS primary_care
  FROM public_health.gold.fact_facility_capacity WHERE capacity_basis = 'registry_snapshot' GROUP BY area_key
) AS c ON c.area_key = g.area_key
WHERE g.geographic_level IN ('city', 'municipality');
