-- ========================================
-- Builds public_health.gold.dim_data_source
--   One row is: one source dataset, keyed by the _source_key value that silver rows carry
--   Primary key: data_source_key = xxhash64(source_dataset). The same source gives the same key
--                on every rebuild, so silver _source_key values hash to the same keys in the
--                facts.
--   Natural key: source_dataset
--
-- Reads
--   the reviewed source list in this file (dim_data_source_list), copied by hand from the
--   config/sources_<domain>.yaml files. It reads no table.
--
-- Rules
--   * One row per source dataset that a gold table reads. When a YAML entry changes (name,
--     as-of date, licence, sharing), change its row here. [1] counts the rows of the list.
--   * source_dataset = the _source_key that silver rows carry. A new silver source without a
--     row here stops every fact build at its "data_source_key not in dim_data_source" gate.
--   * value_type uses the five Proposal v3.1 values: registered (civil registration), reported
--     (surveillance and administrative reports), modelled (IHME estimates), census, and
--     survey_estimate (PSA poverty). The marts use it to keep modelled and reported values
--     apart.
--   * sharing decides what may leave the platform:
--       open        may be exported, with the attribution its licence asks for
--       restricted  aggregates only, cells under 3 records or hospitals suppressed, raw files
--                   never redistributed. For the FOI and hospital sources this is our own
--                   request commitment (D-47); the release letters set no terms. IHME is
--                   restricted by its non-commercial user agreement (no row-level export).
--   * Source notes that change how a source is read (D-44, D-45, D-46) are in source_name, so
--     the dashboard's "about the data" page shows them.
--   * bed_occupancy (superseded on 2026-10-14 by doh_foi_hospital_beds) keeps its row for
--     lineage: older build records still name it.
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
--   2026-10-14  Written for the combined data model (from gold_13, v1).
--   2026-10-20  Moved to public_health.gold and renamed gold_03. The list is a temp view defined
--               before [1], and its row count is read from it (was typed as 25). Source names of
--               upnoah and hdx_dengue carry D-44 / D-45 / D-46. 'model' removed from the build log
--               parameters.
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
-- true : every silver input needs a succeeded build in quality.build_log.
-- false: a silver table written by a notebook is allowed. Gold inputs always need one.
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
-- true : a silver input whose latest QC (quality.v_table_health) has a FAIL stops the build.
--        This file reads no silver table, so the two settings above have nothing to check.
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job


-- Source list, reviewed by hand against config/sources_<domain>.yaml. [1] counts its rows.
CREATE OR REPLACE TEMP VIEW dim_data_source_list AS
SELECT source_dataset, source_name, source_organization, value_type, source_as_of_date, sharing, license,
       source_domain, used_in
FROM VALUES
  ('doh_foi_dengue', 'DOH dengue surveillance, cases and deaths by region and month (FOI)',
   'Department of Health', 'reported', DATE'2025-09-30', 'restricted', CAST(NULL AS STRING),
   'diseases', 'fact_disease_metric'),
  ('upnoah', 'UP NOAH dengue and environmental variables, regional weekly. Dengue counts are DOH-EB counts (FOI 2026-031) by ISO week, not approximated (D-46)',
   'UP Resilience Institute (NOAH)', 'reported', DATE'2026-10-02', 'open', 'ODbL v1.0 (attribution, share-alike)',
   'diseases', 'fact_disease_metric'),
  ('hdx_dengue', 'Dengue cases and deaths by province and week (HDX). Each date closes its ISO week (D-44); from 2018 the counts run 1-2 weeks behind and below DOH (D-45)',
   'Humanitarian Data Exchange (HDX)', 'reported', DATE'2026-10-02', 'open', 'CC BY',
   'diseases', 'fact_disease_metric'),
  ('psa_deaths_national_monthly', 'Registered deaths by cause and month of occurrence, Philippines',
   'Philippine Statistics Authority', 'registered', DATE'2026-10-04', 'open', 'CC BY 4.0',
   'diseases', 'fact_disease_metric'),
  ('psa_deaths_region_annual', 'Registered deaths by cause, region of usual residence and age group',
   'Philippine Statistics Authority', 'registered', DATE'2026-10-02', 'open', 'CC BY 4.0',
   'diseases', 'fact_disease_metric'),
  ('psa_deaths_national_annual', 'Registered deaths by cause, Philippines, 2015 to 2020 (2020 preliminary)',
   'Philippine Statistics Authority', 'registered', DATE'2021-02-26', 'open', CAST(NULL AS STRING),
   'diseases', 'fact_disease_metric'),
  ('doh_fhsis', 'FHSIS annual report tables: TB case notification (2024, 2025), TB preventive treatment and treatment success (2025)',
   'Department of Health', 'reported', DATE'2026-10-14', 'open', CAST(NULL AS STRING),
   'diseases', 'fact_disease_metric'),
  ('philhealth_foi_claims_hospital', 'PhilHealth claims count and amount claimed by admission year, hospital, case-rate package and claim status, 2016 to 2025 (FOI-REQ-2026-6223; published in gold as area aggregates only)',
   'Philippine Health Insurance Corporation', 'reported', DATE'2026-10-14', 'restricted', CAST(NULL AS STRING),
   'diseases', 'fact_disease_metric'),
  ('hdx_healthsites', 'Health facility points from OpenStreetMap via healthsites.io (HDX export, coordinates from the GeoJSON); map layer, never a facility count',
   'Healthsites.io / OpenStreetMap contributors', 'reported', DATE'2026-10-14', 'open', 'ODbL v1.0 (OpenStreetMap)',
   'facilities', 'ref_osm_healthsite_point'),
  ('ihme_gbd', 'IHME GBD 2023 modelled deaths and prevalence by cause, Philippine provinces',
   'Institute for Health Metrics and Evaluation (IHME)', 'modelled', DATE'2026-10-05', 'restricted', 'IHME Free-of-Charge Non-Commercial User Agreement',
   'diseases', 'fact_disease_metric'),
  ('facilities_registry', 'Facility registry: NHFR hospitals matched to the HFSRB licensed lists (facilities_registry_silver)',
   'Department of Health (NHFR and HFSRB)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING),
   'facilities', 'fact_facility_capacity, dim_facility'),
  ('psa_hospitals_region_annual', 'Number of regulated hospitals by type and region (PSA table 9.18)',
   'Philippine Statistics Authority (compiled from DOH HFSRB)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING),
   'facilities', 'fact_facility_capacity'),
  ('psa_beds_region_annual', 'Authorized bed capacity of hospitals by type and region (PSA table 9.17)',
   'Philippine Statistics Authority (compiled from DOH HFSRB)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING),
   'facilities', 'fact_facility_capacity'),
  ('psa_hospitals_national_annual', 'Government and private hospitals, Philippines, 2006 to 2015 (OpenSTAT)',
   'Philippine Statistics Authority', 'reported', DATE'2026-09-30', 'open', 'CC BY 4.0',
   'facilities', 'fact_facility_capacity'),
  ('psa_hospitals_beds_national_annual', 'Hospitals and bed capacity by ownership, Philippines (Yearbook table 9.16)',
   'Philippine Statistics Authority (from DOH)', 'reported', DATE'2026-10-06', 'open', CAST(NULL AS STRING),
   'facilities', 'fact_facility_capacity'),
  ('psa_hospitals_region_annual_legacy', 'Hospitals by type and region, older yearbook layout',
   'Philippine Statistics Authority (from DOH)', 'reported', DATE'2026-10-06', 'open', CAST(NULL AS STRING),
   'facilities', 'fact_facility_capacity'),
  ('psa_bhs_region_annual', 'Barangay health stations by region (PSA table 9.19)',
   'Philippine Statistics Authority (compiled from DOH FHSIS)', 'reported', DATE'2026-09-29', 'open', CAST(NULL AS STRING),
   'facilities', 'fact_facility_capacity'),
  ('bed_occupancy', 'Bed occupancy rate by hospital level and ownership, 2020-2025 (superseded by doh_foi_hospital_beds)',
   'Department of Health (HFSRB)', 'reported', DATE'2026-09-29', 'restricted', CAST(NULL AS STRING),
   'facilities', 'none (superseded 2026-10-14; kept for lineage)'),
  ('doh_foi_hospital_beds', 'Hospital beds and utilization per reporting hospital (no name), 2018-2025: authorized and implementing beds, bed occupancy rate, inpatient bed days (FOI DOH-984883683631)',
   'Department of Health (HFSRB)', 'reported', DATE'2026-10-14', 'restricted', CAST(NULL AS STRING),
   'facilities', 'fact_facility_capacity'),
  ('doh_fhsis_demographic', 'FHSIS Demographic Profile: health facilities, health workers and population by area',
   'Department of Health', 'reported', DATE'2026-10-05', 'open', CAST(NULL AS STRING),
   'workforce', 'fact_facility_capacity, fact_workforce_capacity, fact_area_indicator'),
  ('psa_gov_practitioners', 'Government medical practitioners by region (PSA table 9.14)',
   'Philippine Statistics Authority (compiled from DOH FHSIS)', 'reported', DATE'2026-10-05', 'open', CAST(NULL AS STRING),
   'workforce', 'fact_workforce_capacity'),
  ('psa_poverty', 'Official poverty statistics, full year 2021, 2023 and 2025',
   'Philippine Statistics Authority', 'survey_estimate', DATE'2026-08-26', 'open', CAST(NULL AS STRING),
   'socioeconomic', 'fact_area_indicator'),
  ('psa_psgc', 'Philippine Standard Geographic Code datafile with census population',
   'Philippine Statistics Authority', 'census', DATE'2026-07-13', 'open', CAST(NULL AS STRING),
   'geography', 'dim_geography, fact_area_indicator'),
  ('psa_health_expenditure_share_national_annual', 'Current health expenditure by financing agent, percent share, Philippines, 2016 to 2023 (PSA table 9.26)',
   'Philippine Statistics Authority (Philippine National Health Accounts)', 'reported', DATE'2026-10-05', 'open', CAST(NULL AS STRING),
   'socioeconomic', 'fact_area_indicator'),
  ('psa_health_expenditure_per_capita_national_annual', 'Per capita health expenditure and growth rate, Philippines, 2016 to 2023 (PSA table 9.24)',
   'Philippine Statistics Authority (Philippine National Health Accounts)', 'reported', DATE'2026-10-05', 'open', CAST(NULL AS STRING),
   'socioeconomic', 'fact_area_indicator')
  AS t (source_dataset, source_name, source_organization, value_type, source_as_of_date, sharing, license,
        source_domain, used_in);


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_data_source__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'reference' AS input_kind, CAST(NULL AS STRING) AS input_table, 'reviewed source list (dim_data_source_list), from sources_<domain>.yaml' AS source_file,
         (SELECT count(*) FROM dim_data_source_list) AS input_rows
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_data_source__candidate AS
SELECT xxhash64(source_dataset)                   AS data_source_key,
       source_name,
       source_organization,
       source_dataset,
       value_type,
       source_as_of_date,
       sharing,
       license,
       source_domain,
       used_in,
       gold_build_id                              AS _gold_build_id
FROM dim_data_source_list;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_data_source__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.dim_data_source__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.dim_data_source__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.dim_data_source__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.dim_data_source__candidate
WHERE data_source_key IS NULL OR source_dataset IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_data_source__candidate GROUP BY data_source_key HAVING count(*) > 1)
UNION ALL
SELECT 'natural key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.dim_data_source__candidate
  GROUP BY source_dataset HAVING count(*) > 1)
UNION ALL
SELECT 'value_type outside the five v3.1 values', count(*) FROM public_health.gold.dim_data_source__candidate
WHERE value_type NOT IN ('registered', 'reported', 'modelled', 'census', 'survey_estimate') OR value_type IS NULL
UNION ALL
SELECT 'sharing outside open, restricted', count(*) FROM public_health.gold.dim_data_source__candidate WHERE sharing NOT IN ('open', 'restricted') OR sharing IS NULL
UNION ALL
SELECT 'source_name or source_as_of_date missing', count(*) FROM public_health.gold.dim_data_source__candidate WHERE source_name IS NULL OR source_as_of_date IS NULL
UNION ALL
SELECT 'source_domain outside the six domains or used_in missing', count(*) FROM public_health.gold.dim_data_source__candidate
WHERE source_domain NOT IN ('diseases', 'facilities', 'workforce', 'population', 'socioeconomic', 'geography')
   OR source_domain IS NULL OR used_in IS NULL;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.dim_data_source__gates WHERE failures <> 0
--     approval: 'no silver input' (the list is a reviewed reference).
-- ========================================
CREATE OR REPLACE TEMP VIEW dim_data_source_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'shared'                                      AS domain,
       'public_health.gold.dim_data_source'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.dim_data_source__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.dim_data_source__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM dim_data_source_build_log WHERE status = 'failed';

SELECT raise_error(concat('dim_data_source was NOT published. ', error_message))
FROM dim_data_source_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.dim_data_source AS
SELECT * FROM public_health.gold.dim_data_source__candidate;


-- ========================================
-- [6] record the build, with the table version just written. If your runtime rejects this
--     SET VAR, delete it: the version stays null, and freshness checks (G06,
--     mart_evidence_readiness) cannot compare this table.
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.dim_data_source));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.dim_data_source),
       gold_target_version, code_version, parameters, run_id, error_message
FROM dim_data_source_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.dim_data_source', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.dim_data_source__inputs;


-- ========================================
-- [7] remove the staging tables, then show the summary
-- ========================================
DROP TABLE IF EXISTS public_health.gold.dim_data_source__candidate;
DROP TABLE IF EXISTS public_health.gold.dim_data_source__gates;
DROP TABLE IF EXISTS public_health.gold.dim_data_source__inputs;

-- Summary by domain, value type and sharing. Checked 2026-10-14: 25 sources.
SELECT source_domain, value_type, sharing, count(*) AS sources FROM public_health.gold.dim_data_source
GROUP BY source_domain, value_type, sharing ORDER BY source_domain, value_type, sharing;