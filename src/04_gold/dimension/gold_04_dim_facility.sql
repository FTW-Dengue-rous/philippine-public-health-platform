-- ========================================
-- Builds public_health.gold.dim_facility
--   One row is: one facility establishment in facilities_registry_silver (listed, or carried
--   as not_listed)
--   Primary key: facility_key = xxhash64(facility_source_id). The same facility gives the same
--                key on every rebuild.
--   Natural key: facility_source_id (the registry facility_key)
--
-- Reads
--   public_health.silver.facilities_registry_silver
--   public_health.gold.dim_geography (gold 01, for the area check)
--
-- Columns (Proposal v3.1): facility_key, facility_source_id, facility_name, area_key,
--   facility_category, hospital_level, ownership.
-- Extra columns
--   * facility_status (listed, not_listed): only listed facilities are counted. Closure is
--     never inferred from a carried row.
--   * authorized_beds, analysis_beds, analysis_beds_basis: beds per facility, with the basis
--     shown next to analysis_beds.
--   * dialysis_stations: K1. Null means not reported, never zero.
--   * is_license_valid_on_as_of: A3 and A4 count licensed primary care facilities.
--
-- Rules
--   * No matching, keys or area resolution are redone here. Silver owns them.
--   * ownership = government or private (lower case of the registry column).
--   * hospital_level = Level 1, Level 2 or Level 3, read from service_level. A hospital whose
--     service level names no level gets 'unknown'. Other categories get null.
--   * area_key = the registry area (a city, municipality or Manila submunicipality). Null when
--     silver has no area; a listed facility without an area stops the build.
--   * This dimension joins dim_geography only. It is never joined to fact_facility_capacity
--     (that fact is at group grain, not facility grain).
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
--   2026-10-14  Written for the combined data model (from gold_21, v1).
--   2026-10-20  Moved to public_health.gold and renamed gold_04. area_key is null (not the hash
--               of null) when silver has no area, so the gate "listed facility without an
--               area" can fire. 'model' removed from the build log parameters.
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


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_facility__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_registry_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_registry_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_geography
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_facility__candidate AS
SELECT xxhash64(r.facility_key)                   AS facility_key,
       r.facility_key                             AS facility_source_id,
       r.facility_name,
       nvl2(r.area_key, xxhash64(r.area_key), NULL) AS area_key,   -- null area stays null (xxhash64(NULL) is not null)
       r.facility_category,
       CASE WHEN r.facility_category = 'hospital'
            THEN coalesce(nullif(regexp_extract(r.service_level, '(Level [1-3])', 1), ''), 'unknown') END AS hospital_level,
       lower(trim(r.ownership))                   AS ownership,
       r.facility_status,                         -- extra
       CAST(r.authorized_beds AS BIGINT)          AS authorized_beds,       -- extra
       CAST(r.analysis_beds AS BIGINT)            AS analysis_beds,         -- extra
       r.analysis_beds_basis,                     -- extra
       CAST(r.dialysis_stations AS BIGINT)        AS dialysis_stations,     -- extra
       r.is_license_valid_on_as_of,               -- extra
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.facilities_registry_silver AS r;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_facility__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.dim_facility__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.dim_facility__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.dim_facility__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.dim_facility__candidate
WHERE facility_key IS NULL OR facility_source_id IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_facility__candidate GROUP BY facility_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_facility__candidate
  GROUP BY facility_source_id HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> registry rows', abs((SELECT count(*) FROM public_health.gold.dim_facility__candidate) - count(*)) FROM public_health.silver.facilities_registry_silver
UNION ALL
SELECT 'facility_category outside the four known values', count(*) FROM public_health.gold.dim_facility__candidate
WHERE facility_category NOT IN ('hospital', 'infirmary', 'primary_care', 'dialysis_clinic') OR facility_category IS NULL
UNION ALL
SELECT 'ownership outside government, private', count(*) FROM public_health.gold.dim_facility__candidate WHERE ownership NOT IN ('government', 'private') OR ownership IS NULL
UNION ALL
SELECT 'hospital_level missing for a hospital or filled for another category', count(*) FROM public_health.gold.dim_facility__candidate WHERE (facility_category = 'hospital') <> (hospital_level IS NOT NULL)
UNION ALL
SELECT 'listed facility without an area', count(*) FROM public_health.gold.dim_facility__candidate WHERE facility_status = 'listed' AND area_key IS NULL
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.gold.dim_facility__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'analysis beds total <> registry total', CAST(abs(coalesce((SELECT sum(analysis_beds) FROM public_health.gold.dim_facility__candidate), 0) - coalesce(sum(analysis_beds), 0)) AS BIGINT)
FROM public_health.silver.facilities_registry_silver;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.dim_facility__gates WHERE failures <> 0
--     approval: provisional while a silver input has no QC run or has WARN findings to review.
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_facility_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'facilities'                                      AS domain,
       'public_health.gold.dim_facility'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.dim_facility__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.dim_facility__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_facility_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_facility was NOT published. ', error_message))
FROM dim_facility_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_facility AS
SELECT * FROM public_health.gold.dim_facility__candidate;


-- ========================================
-- [6] record the build, with the table version just written. If your runtime rejects this
--     SET VAR, delete it: the version stays null, and freshness checks (G06,
--     mart_evidence_readiness) cannot compare this table.
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.dim_facility));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.dim_facility),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_facility_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.dim_facility', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.dim_facility__inputs;


-- ========================================
-- [7] remove the staging tables, then show the summary
-- ========================================
DROP TABLE IF EXISTS public_health.gold.dim_facility__candidate;
DROP TABLE IF EXISTS public_health.gold.dim_facility__gates;
DROP TABLE IF EXISTS public_health.gold.dim_facility__inputs;

SELECT facility_category, hospital_level, ownership, facility_status, count(*) AS facilities,
       sum(analysis_beds) AS analysis_beds, count_if(dialysis_stations IS NOT NULL) AS with_station_count
FROM public_health.gold.dim_facility
GROUP BY facility_category, hospital_level, ownership, facility_status
ORDER BY facility_category, hospital_level, ownership;