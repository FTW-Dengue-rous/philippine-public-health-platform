-- ========================================
-- Builds public_health.test_gold.fact_area_facility_capacity_snapshot
--   One row is: listed facilities of one category, hospital level and ownership in one city or municipality at one registry snapshot
--   Primary key: fact_facility_capacity_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, period_key, source_key, facility_category, ownership, hospital_level)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.facilities_registry_silver
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_source
--
-- v3.1 columns: fact_facility_capacity_key, area_key, period_key, source_key,
--   facility_category, facility_count, authorized_beds, analysis_beds, ownership, hospital_level.
-- Extra columns (proposed additions)
--   * dialysis_stations, dialysis_facilities_stations_known, dialysis_facilities_stations_unknown:
--     K1. The Questions sheet lists these as the gap in v3.1.
--   * facilities_license_valid: A3 and A4 ask for licensed primary care facilities.
--   * facilities_without_beds: lets a low bed sum be read correctly (a null bed count is not 0).
--   * nhfr_as_of_date, hfsrb_as_of_date: A1 and A3 state the as-of date of each list.
-- Rules
--   * Only facility_status = listed is counted.
--   * period_key is the registry snapshot: the later of the NHFR and HFSRB as-of dates
--     (period_basis snapshot). source_key is facilities_registry, the merged registry.
--   * The grain is the city or municipality. A facility in a Manila submunicipality is counted
--     in the City of Manila.
--   * hospital_level is Level 1, Level 2, Level 3 or unknown for hospitals and null for the other
--     categories. The grain check is null-safe.
--   * dialysis_stations is the sum of known station counts, and null when no facility in the
--     group has one. Known = facilities of any category with a count. Unknown = free-standing
--     dialysis clinics with no count. A hospital with no count is not counted as unknown.
--   * A locality with no facility has no row here. "No hospital recorded" (A1) and "no primary
--     care recorded" (A3) come from dim_geography left joined to this fact, in the marts.
-- Facilities silver ran on Databricks on 2026-10-12, all gates 0. Registry 3,957 rows.
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
-- true : every silver input needs a succeeded build in quality.build_log.
-- false: a silver table written by a notebook is allowed. Gold inputs always need one.
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
-- true : a silver input whose latest QC (quality.v_table_health) has a FAIL stops the build.
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_area_facility_capacity_snapshot__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_registry_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_registry_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_period' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_period
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_source
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_capacity_src AS
SELECT coalesce(city.area_key, g.area_key, xxhash64(r.area_key)) AS area_key,
       r.facility_category,
       CASE WHEN r.facility_category = 'hospital'
            THEN coalesce(nullif(regexp_extract(r.service_level, '(Level [1-3])', 1), ''), 'unknown') END AS hospital_level,
       lower(trim(r.ownership))                   AS ownership,
       r.is_license_valid_on_as_of,
       r.authorized_beds, r.analysis_beds, r.dialysis_stations,
       r._nhfr_as_of_date, r._hfsrb_as_of_date
FROM public_health.silver.facilities_registry_silver AS r
LEFT JOIN public_health.test_gold.dim_geography AS g ON g.area_code = r.area_key
LEFT JOIN public_health.test_gold.dim_geography AS city
  ON g.geographic_level = 'submunicipality' AND city.area_key = g.parent_area_key
 AND city.geographic_level = 'city'
WHERE r.facility_status = 'listed';

CREATE OR REPLACE TABLE public_health.test_gold.fact_area_facility_capacity_snapshot__candidate AS
SELECT xxhash64(area_key, facility_category, ownership, coalesce(hospital_level, '-')) AS fact_facility_capacity_key,
       area_key,
       xxhash64('snapshot', date_format((SELECT max(greatest(_nhfr_as_of_date, _hfsrb_as_of_date)) FROM public_health.silver.facilities_registry_silver), 'yyyy-MM-dd')) AS period_key,
       xxhash64('facilities_registry')            AS source_key,
       facility_category,
       count(*)                                   AS facility_count,
       CAST(sum(authorized_beds) AS BIGINT)       AS authorized_beds,
       CAST(sum(analysis_beds) AS BIGINT)         AS analysis_beds,
       ownership,
       hospital_level,
       CAST(sum(dialysis_stations) AS BIGINT)     AS dialysis_stations,                      -- extra
       count_if(dialysis_stations IS NOT NULL)    AS dialysis_facilities_stations_known,     -- extra
       count_if(facility_category = 'dialysis_clinic' AND dialysis_stations IS NULL)
                                                  AS dialysis_facilities_stations_unknown,   -- extra
       count_if(is_license_valid_on_as_of)        AS facilities_license_valid,               -- extra
       count_if(facility_category IN ('hospital', 'infirmary') AND analysis_beds IS NULL)
                                                  AS facilities_without_beds,                -- extra
       max(_nhfr_as_of_date)                      AS nhfr_as_of_date,                        -- extra
       max(_hfsrb_as_of_date)                     AS hfsrb_as_of_date,                       -- extra
       gold_build_id                              AS _gold_build_id
FROM fact_capacity_src
GROUP BY area_key, facility_category, hospital_level, ownership;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_area_facility_capacity_snapshot__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_area_facility_capacity_snapshot__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_area_facility_capacity_snapshot__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate
WHERE fact_facility_capacity_key IS NULL OR area_key IS NULL OR period_key IS NULL OR source_key IS NULL OR facility_category IS NULL OR ownership IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate GROUP BY fact_facility_capacity_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate
  GROUP BY area_key, period_key, source_key, facility_category, ownership, hospital_level HAVING count(*) > 1)
UNION ALL
SELECT 'facility_category outside the four known values', count(*) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate WHERE facility_category NOT IN ('hospital', 'infirmary', 'primary_care', 'dialysis_clinic')
UNION ALL
SELECT 'ownership outside government, private', count(*) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate WHERE ownership NOT IN ('government', 'private')
UNION ALL
SELECT 'hospital_level missing for a hospital or filled for another category', count(*) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate WHERE (facility_category = 'hospital') <> (hospital_level IS NOT NULL)
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k
UNION ALL
SELECT 'area that is not a city or municipality', count(*) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate AS c
INNER JOIN public_health.test_gold.dim_geography AS g ON g.area_key = c.area_key
WHERE g.geographic_level NOT IN ('city', 'municipality')
UNION ALL
SELECT 'facility_count total <> listed registry rows', abs(coalesce((SELECT sum(facility_count) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate), 0) - count(*))
FROM public_health.silver.facilities_registry_silver WHERE facility_status = 'listed'
UNION ALL
SELECT 'analysis beds total <> listed registry total', CAST(abs(coalesce((SELECT sum(analysis_beds) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate), 0) - coalesce(sum(analysis_beds), 0)) AS BIGINT)
FROM public_health.silver.facilities_registry_silver WHERE facility_status = 'listed'
UNION ALL
SELECT 'dialysis stations total <> listed registry total', CAST(abs(coalesce((SELECT sum(dialysis_stations) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate), 0) - coalesce(sum(dialysis_stations), 0)) AS BIGINT)
FROM public_health.silver.facilities_registry_silver WHERE facility_status = 'listed'
UNION ALL
SELECT 'dialysis_stations filled where no facility has a known count', count(*) FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate WHERE dialysis_facilities_stations_known = 0 AND dialysis_stations IS NOT NULL;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_area_facility_capacity_snapshot__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_area_facility_capacity_snapshot_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'facilities'                                      AS domain,
       'public_health.test_gold.fact_area_facility_capacity_snapshot'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_area_facility_capacity_snapshot__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_area_facility_capacity_snapshot__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_area_facility_capacity_snapshot_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_area_facility_capacity_snapshot was NOT published. ', error_message))
FROM fact_area_facility_capacity_snapshot_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_area_facility_capacity_snapshot AS
SELECT * FROM public_health.test_gold.fact_area_facility_capacity_snapshot__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_area_facility_capacity_snapshot));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_area_facility_capacity_snapshot),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_area_facility_capacity_snapshot_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_area_facility_capacity_snapshot', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_area_facility_capacity_snapshot__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_area_facility_capacity_snapshot__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_area_facility_capacity_snapshot__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_area_facility_capacity_snapshot__inputs;

SELECT facility_category, hospital_level, ownership, count(*) AS localities,
       sum(facility_count) AS facilities, sum(analysis_beds) AS analysis_beds,
       sum(facilities_without_beds) AS without_beds, sum(dialysis_stations) AS dialysis_stations
FROM public_health.test_gold.fact_area_facility_capacity_snapshot
GROUP BY facility_category, hospital_level, ownership
ORDER BY facility_category, hospital_level, ownership;

-- Phase 2 proof (A1, A3): cities and municipalities with no hospital and no primary care
-- facility RECORDED on the as-of date. Recorded is not a confirmed absence.
SELECT count(*) AS localities,
       count_if(coalesce(c.hospitals, 0) = 0) AS no_hospital_recorded,
       count_if(coalesce(c.primary_care, 0) = 0) AS no_primary_care_recorded,
       count_if(coalesce(c.hospitals, 0) = 0 AND coalesce(c.primary_care, 0) = 0) AS neither_recorded
FROM public_health.test_gold.dim_geography AS g
LEFT JOIN (
  SELECT area_key,
         sum(CASE WHEN facility_category = 'hospital' THEN facility_count END) AS hospitals,
         sum(CASE WHEN facility_category = 'primary_care' THEN facility_count END) AS primary_care
  FROM public_health.test_gold.fact_area_facility_capacity_snapshot GROUP BY area_key
) AS c ON c.area_key = g.area_key
WHERE g.geographic_level IN ('city', 'municipality');
