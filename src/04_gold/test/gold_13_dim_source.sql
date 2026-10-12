-- ========================================
-- Builds public_health.test_gold.dim_source
--   One row is: one source dataset, keyed by the _source_key that silver rows carry
--   Primary key: source_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Natural key: (source_dataset)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   sources_<domain>.yaml (20 source datasets) (reviewed list in this file)
--
-- v3.1 columns: source_key, source_name, source_organization, source_dataset, value_type,
--   source_as_of_date.
-- Extra columns (proposed additions)
--   * sharing (open or restricted) and license: the rule "no row-level export of restricted
--     data, small cells suppressed" needs to know which sources are restricted.
-- Rules
--   * A reviewed list kept in this file, copied by hand from the four sources_<domain>.yaml
--     files (2026-10-12). When a YAML entry changes, change the row here.
--   * source_dataset is the value silver rows carry in _source_key. doh_fhsis covers the YAML
--     entries doh_fhsis_tb and doh_fhsis_morbidity. doh_fhsis_demographic is one key used by the
--     facilities and the workforce YAML.
--   * facilities_registry is one row for facilities_registry_silver, which merges the NHFR
--     list and the four HFSRB lists. Its as-of date is the NHFR date. The capacity snapshot
--     fact carries both as-of dates.
--   * value_type uses the five v3.1 values. Registries and published administrative counts are
--     written as reported.
--   * Sources that no v3.1 gold table reads are not listed (health expenditure, child
--     mortality, PSMO oncologists, OSM points, bronze-only sources).
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
CREATE OR REPLACE TABLE public_health.test_gold.dim_source__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'reference' AS input_kind, CAST(NULL AS STRING) AS input_table, 'sources_<domain>.yaml (20 source datasets)' AS source_file,
         CAST(20 AS BIGINT) AS input_rows
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_source__candidate AS
SELECT xxhash64(source_dataset)                   AS source_key,
       source_name,
       source_organization,
       source_dataset,
       value_type,
       source_as_of_date,
       sharing,                                   -- extra
       license,                                   -- extra
       gold_build_id                              AS _gold_build_id
FROM VALUES
  ('doh_foi_dengue', 'DOH dengue surveillance, cases and deaths by region and month (FOI)',
   'Department of Health', 'reported', DATE'2025-09-30', 'restricted', CAST(NULL AS STRING)),
  ('upnoah', 'UP NOAH dengue and environmental variables, regional weekly',
   'UP Resilience Institute (NOAH)', 'reported', DATE'2026-10-02', 'open', 'ODbL v1.0 (attribution, share-alike)'),
  ('hdx_dengue', 'Dengue cases and deaths by province and week (HDX)',
   'Humanitarian Data Exchange (HDX)', 'reported', DATE'2026-10-02', 'open', 'CC BY'),
  ('psa_deaths_national_monthly', 'Registered deaths by cause and month of occurrence, Philippines',
   'Philippine Statistics Authority', 'registered', DATE'2026-10-04', 'open', 'CC BY 4.0'),
  ('psa_deaths_region_annual', 'Registered deaths by cause, region of usual residence and age group',
   'Philippine Statistics Authority', 'registered', DATE'2026-10-02', 'open', 'CC BY 4.0'),
  ('psa_deaths_national_annual', 'Registered deaths by cause, Philippines, 2015 to 2020 (2020 preliminary)',
   'Philippine Statistics Authority', 'registered', DATE'2021-02-26', 'open', CAST(NULL AS STRING)),
  ('doh_fhsis', 'FHSIS annual report tables: TB case notification',
   'Department of Health', 'reported', DATE'2026-10-02', 'open', CAST(NULL AS STRING)),
  ('ihme_gbd', 'IHME GBD 2023 modelled deaths and prevalence by cause, Philippine provinces',
   'Institute for Health Metrics and Evaluation (IHME)', 'modelled', DATE'2026-10-05', 'restricted', 'IHME Free-of-Charge Non-Commercial User Agreement'),
  ('facilities_registry', 'Facility registry: NHFR hospitals matched to the HFSRB licensed lists (facilities_registry_silver)',
   'Department of Health (NHFR and HFSRB)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING)),
  ('psa_hospitals_region_annual', 'Number of regulated hospitals by type and region (PSA table 9.18)',
   'Philippine Statistics Authority (compiled from DOH HFSRB)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING)),
  ('psa_beds_region_annual', 'Authorized bed capacity of hospitals by type and region (PSA table 9.17)',
   'Philippine Statistics Authority (compiled from DOH HFSRB)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING)),
  ('psa_hospitals_national_annual', 'Government and private hospitals, Philippines, 2006 to 2015 (OpenSTAT)',
   'Philippine Statistics Authority', 'reported', DATE'2026-09-30', 'open', 'CC BY 4.0'),
  ('psa_hospitals_beds_national_annual', 'Hospitals and bed capacity by ownership, Philippines (Yearbook table 9.16)',
   'Philippine Statistics Authority (from DOH)', 'reported', DATE'2026-10-06', 'open', CAST(NULL AS STRING)),
  ('psa_hospitals_region_annual_legacy', 'Hospitals by type and region, older yearbook layout',
   'Philippine Statistics Authority (from DOH)', 'reported', DATE'2026-10-06', 'open', CAST(NULL AS STRING)),
  ('psa_bhs_region_annual', 'Barangay health stations by region (PSA table 9.19)',
   'Philippine Statistics Authority (compiled from DOH FHSIS)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING)),
  ('bed_occupancy', 'Bed occupancy rate by hospital level and ownership (agency not confirmed)',
   CAST(NULL AS STRING), 'reported', DATE'2026-09-29', 'restricted', CAST(NULL AS STRING)),
  ('doh_fhsis_demographic', 'FHSIS Demographic Profile: health facilities, health workers and population by area',
   'Department of Health', 'reported', DATE'2026-10-05', 'open', CAST(NULL AS STRING)),
  ('psa_gov_practitioners', 'Government medical practitioners by region (PSA table 9.14)',
   'Philippine Statistics Authority (compiled from DOH FHSIS)', 'reported', DATE'2026-10-05', 'open', CAST(NULL AS STRING)),
  ('psa_poverty', 'Official poverty statistics, full year 2021, 2023 and 2025',
   'Philippine Statistics Authority', 'survey_estimate', DATE'2026-08-26', 'open', CAST(NULL AS STRING)),
  ('psa_psgc', 'Philippine Standard Geographic Code datafile with census population',
   'Philippine Statistics Authority', 'census', DATE'2026-07-13', 'open', CAST(NULL AS STRING))
  AS t (source_dataset, source_name, source_organization, value_type, source_as_of_date, sharing, license);


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_source__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.dim_source__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.dim_source__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.dim_source__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.dim_source__candidate
WHERE source_key IS NULL OR source_dataset IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_source__candidate GROUP BY source_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.dim_source__candidate
  GROUP BY source_dataset HAVING count(*) > 1)
UNION ALL
SELECT 'value_type outside the five v3.1 values', count(*) FROM public_health.test_gold.dim_source__candidate
WHERE value_type NOT IN ('registered', 'reported', 'modelled', 'census', 'survey_estimate') OR value_type IS NULL
UNION ALL
SELECT 'sharing outside open, restricted', count(*) FROM public_health.test_gold.dim_source__candidate WHERE sharing NOT IN ('open', 'restricted') OR sharing IS NULL
UNION ALL
SELECT 'source_name or source_as_of_date missing', count(*) FROM public_health.test_gold.dim_source__candidate WHERE source_name IS NULL OR source_as_of_date IS NULL;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.dim_source__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_source_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'shared'                                      AS domain,
       'public_health.test_gold.dim_source'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.dim_source__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.dim_source__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_source_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_source was NOT published. ', error_message))
FROM dim_source_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.dim_source AS
SELECT * FROM public_health.test_gold.dim_source__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.dim_source));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.dim_source),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_source_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.dim_source', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.dim_source__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.dim_source__candidate;
DROP TABLE IF EXISTS public_health.test_gold.dim_source__gates;
DROP TABLE IF EXISTS public_health.test_gold.dim_source__inputs;

SELECT value_type, sharing, count(*) AS sources FROM public_health.test_gold.dim_source
GROUP BY value_type, sharing ORDER BY value_type, sharing;