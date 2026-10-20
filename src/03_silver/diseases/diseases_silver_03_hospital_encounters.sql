-- =============================================================================
-- Builds public_health.silver.diseases_hospital_encounters_silver:
--   one de-identified hospital encounter. RESTRICTED: keep access to this table limited.
--   Key: the bronze row reference (_source_key, _source_file, _source_sheet, _source_row_num).
--
-- Restricted-data rules
--   * Dropped: EncounterID, Brgy, Height, Weight, Total_Bill, PhilHealth_Coverage,
--     Guarantee_Letter_Coverage, Final_Diagnosis, PHIC_Description, and all times of day.
--   * Exact age becomes an age band.
--   * Gates are counts, and dispositions are row references: no patient value leaves this table.
--   * The staging table ..__candidate holds the same de-identified rows and is dropped at the end.
--     If a gate fails it is kept for inspection: treat it as restricted too.
--   * Why restricted (D-47): our own commitment when the data was requested, not a release term.
--     Academic use only, reported in aggregate form. Gold publishes aggregates only, suppresses
--     cells built from fewer than 3 records, and does not name the hospital. The raw file is never
--     redistributed or committed to the repository.
--
-- What is not established
--   * The file has no column that confirms an inpatient admission: is_inpatient_confirmed = false.
--   * Occupancy convention: a bed is occupied on each date from the admission date up to, but not
--     including, the discharge date (midnight census). Use admission_date and discharge_date,
--     not the published length of stay.
-- =============================================================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
-- true : every input needs exactly one processed ingestion_metadata row (contract 3.5).
-- false: a missing row is allowed; that input gets a null load id and checksum.
--        Use false only while the bronze B13 warnings are open.
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job

-- area_key of the hospital's province, e.g. 'psgc:<code>'. Left out of the repo on purpose so the
-- code does not identify the hospital. NULL leaves is_same_province_as_hospital null.
DECLARE OR REPLACE VARIABLE hospital_province_area_key STRING DEFAULT NULL;

-- Review threshold for is_long_stay (published length of stay in days). A review rule, not a
-- data fact; recorded in build_log.parameters so the QC count (S47) can be read against it.
DECLARE OR REPLACE VARIABLE long_stay_days INT DEFAULT 60;

-- Label normalisation, the same rule as norm() in build_diseases_reference_maps.py:
-- upper case, N for N-tilde, anything that is not A-Z or 0-9 becomes a space, single spaces.
CREATE OR REPLACE TEMPORARY FUNCTION dz_norm(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(translate(upper(s), 'Ñ', 'N'), '[^A-Z0-9]', ' '), ' +', ' '));

-- Text to number: spaces and thousands separators removed. Null when it is not a number.
CREATE OR REPLACE TEMPORARY FUNCTION dz_num(s STRING) RETURNS DECIMAL(20,4)
RETURN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4));

-- Status of one cell. star_status: what '*' means in this source (null = not a marker here).
-- blank_status: what an empty cell means. Anything else that is not a number is a parse_error.
CREATE OR REPLACE TEMPORARY FUNCTION dz_status(s STRING, star_status STRING, blank_status STRING) RETURNS STRING
RETURN CASE WHEN s IS NULL OR trim(s) = '' THEN blank_status
            WHEN trim(s) = '*' AND star_status IS NOT NULL THEN star_status
            WHEN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4)) IS NOT NULL THEN 'ok'
            ELSE 'parse_error' END;

-- Year at the end of a file name: ..._2024.csv -> 2024
CREATE OR REPLACE TEMPORARY FUNCTION dz_file_year(f STRING) RETURNS INT
RETURN try_cast(regexp_extract(f, '_([0-9]{4})[.][A-Za-z]+$', 1) AS INT);


-- =============================================================================
-- [1] classify: every row of the extract is a data row
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_encounters_silver__classified AS
SELECT 'public_health.bronze.diseases_davao_hospital_pneumonia_bronze' AS input_table,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at,
       'data' AS row_class, CAST(NULL AS STRING) AS reason
FROM public_health.bronze.diseases_davao_hospital_pneumonia_bronze
WHERE _source_key = 'davao_hospital_pneumonia';


-- =============================================================================
-- [2] inputs (layout of quality.build_inputs)
-- =============================================================================
-- Delta version of each table read. If your runtime rejects DESCRIBE HISTORY in a subquery,
-- use the NULL version below instead (the build still works; versions are just not recorded).
CREATE OR REPLACE TEMP VIEW enc_table_versions AS
SELECT 'public_health.bronze.diseases_davao_hospital_pneumonia_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_davao_hospital_pneumonia_bronze)) AS table_version
UNION ALL SELECT 'public_health.silver.diseases_area_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_area_map));
-- NULL version (use this instead if the view above fails):
-- CREATE OR REPLACE TEMP VIEW enc_table_versions AS
-- SELECT CAST(NULL AS STRING) AS table_name, CAST(NULL AS BIGINT) AS table_version WHERE 1 = 0;

CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_encounters_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.diseases_hospital_encounters_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT silver_build_id      AS build_id,
       'public_health.silver.diseases_hospital_encounters_silver' AS target_table,
       'bronze_source'      AS input_kind,
       f.input_table,
       max(v.table_version) AS input_table_version,
       f._source_key        AS source_key,
       f._source_file       AS source_file,
       f._source_sheet      AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END         AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at       AS ingested_at,
       f.input_rows,
       CAST(NULL AS STRING) AS reference_version,
       count(m.batch_id)    AS metadata_matches      -- gate only, not appended
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key
 AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet
 AND m.retrieved_at = f._ingested_at
LEFT JOIN enc_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
-- the reference tables that shaped the build
SELECT silver_build_id, 'public_health.silver.diseases_hospital_encounters_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.diseases_area_map' AS table_name, count(*) AS n FROM public_health.silver.diseases_area_map) t
LEFT JOIN enc_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] candidate rows
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_encounters_silver__candidate AS
WITH s AS (
  SELECT e.*,
         try_to_timestamp(AdmissionDate) AS adm_ts, try_to_timestamp(DischargeDate) AS dis_ts,
         to_date(try_to_timestamp(AdmissionDate)) AS adm, to_date(try_to_timestamp(DischargeDate)) AS dis,
         try_cast(trim(Age) AS DOUBLE) AS age_n,
         try_cast(trim(Length_Of_Stay_Day) AS INT) AS los_n
  FROM public_health.bronze.diseases_davao_hospital_pneumonia_bronze e
  WHERE _source_key = 'davao_hospital_pneumonia'
)
SELECT
  s.adm AS admission_date,                       -- dates only; the time of day is not kept
  s.dis AS discharge_date,
  -- the order check uses the full timestamps
  CASE WHEN s.adm_ts IS NULL THEN 'admission_missing' WHEN s.dis_ts IS NULL THEN 'discharge_missing'
       WHEN s.dis_ts < s.adm_ts THEN 'discharge_before_admission' ELSE 'ok' END AS date_status,
  (s.adm_ts IS NOT NULL AND s.dis_ts IS NOT NULL AND s.dis_ts >= s.adm_ts)      AS occupancy_eligible,
  (s.adm = s.dis)                                AS is_same_day,          -- adds no bed-day under the midnight census
  s.los_n                                        AS length_of_stay_days_published,   -- whole elapsed days, as published
  datediff(s.dis, s.adm)                         AS stay_days_by_date,               -- discharge date minus admission date
  (s.los_n > long_stay_days)                     AS is_long_stay,         -- kept; on a review list
  false                                          AS is_inpatient_confirmed,
  (upper(trim(s.Result)) = 'DIED')               AS died_in_hospital,
  ((upper(trim(s.Result)) = 'DIED') = (s.DeathDate IS NOT NULL AND trim(s.DeathDate) <> '')) AS death_fields_consistent,
  CASE WHEN s.age_n IS NULL OR s.age_n < 0 THEN 'unknown' WHEN s.age_n < 1 THEN 'under_1'
       WHEN s.age_n < 5 THEN '1_4' WHEN s.age_n >= 85 THEN '85_over'
       ELSE concat(CAST(floor(s.age_n / 5) * 5 AS INT), '_', CAST(floor(s.age_n / 5) * 5 + 4 AS INT)) END AS age_group,
  upper(trim(s.Gender))                          AS sex,
  upper(trim(s.ICD))                             AS icd_code,
  trim(s.LevelofCare)                            AS level_of_care,
  trim(s.Patient_Classification)                 AS patient_classification,
  trim(s.PHIC_Class)                             AS phic_class,
  upper(trim(s.Disposition))                     AS disposition,
  upper(trim(s.Result))                          AS result,
  p.area_key                                     AS patient_province_area_key,
  c.area_key                                     AS patient_city_area_key,
  CASE WHEN s.Province IS NULL OR trim(s.Province) = '' THEN 'province_blank'
       WHEN p.match_value IS NULL THEN 'province_not_in_area_map'
       WHEN s.City IS NULL OR trim(s.City) = '' THEN 'city_blank'
       WHEN c.match_value IS NULL THEN 'city_not_in_area_map'
       WHEN c.area_key IS NULL THEN 'city_unresolved'       -- label is in the map but has no reviewed code yet
       ELSE 'ok' END                             AS patient_location_status,
  CASE WHEN hospital_province_area_key IS NULL OR p.area_key IS NULL THEN CAST(NULL AS BOOLEAN)
       ELSE p.area_key = hospital_province_area_key END AS is_same_province_as_hospital,
  'patient_origin'                               AS location_basis,
  silver_build_id                                AS _silver_build_id,
  s._source_key, s._source_file, s._source_sheet, s._source_row_num, s._as_of_date
FROM s
LEFT JOIN public_health.silver.diseases_area_map p
  ON p._source_key = 'davao_hospital_pneumonia' AND p.match_type = 'label'
 AND p.parent_label_norm IS NULL AND p.match_value = dz_norm(s.Province)
LEFT JOIN public_health.silver.diseases_area_map c
  ON c._source_key = 'davao_hospital_pneumonia' AND c.match_type = 'label'
 AND c.parent_label_norm = dz_norm(s.Province) AND c.match_value = dz_norm(s.City);


-- =============================================================================
-- [4] gates and output validation: every row must have failures = 0 (counts only)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_encounters_silver__gates AS
SELECT 'inputs: file or sheet with more than one load time' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.diseases_hospital_encounters_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.diseases_hospital_encounters_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.diseases_hospital_encounters_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'unclassified bronze rows', count(*)
  FROM public_health.silver.diseases_hospital_encounters_silver__classified WHERE row_class NOT IN ('data', 'non_data', 'duplicate', 'quarantined')
UNION ALL
SELECT 'EncounterID not unique in bronze (checked before the column is dropped)', count(*) FROM (
  SELECT 1 FROM public_health.bronze.diseases_davao_hospital_pneumonia_bronze
  WHERE _source_key = 'davao_hospital_pneumonia' GROUP BY EncounterID HAVING count(*) > 1)
UNION ALL
SELECT 'EncounterID is null', count(*)
  FROM public_health.bronze.diseases_davao_hospital_pneumonia_bronze
  WHERE _source_key = 'davao_hospital_pneumonia' AND EncounterID IS NULL
UNION ALL
SELECT 'admission or discharge date does not parse', count(*)
  FROM public_health.bronze.diseases_davao_hospital_pneumonia_bronze
  WHERE _source_key = 'davao_hospital_pneumonia'
    AND ((AdmissionDate IS NOT NULL AND try_to_timestamp(AdmissionDate) IS NULL)
      OR (DischargeDate IS NOT NULL AND try_to_timestamp(DischargeDate) IS NULL))
UNION ALL
SELECT 'province label not in the area map (blank provinces are allowed)', count(*)
  FROM public_health.silver.diseases_hospital_encounters_silver__candidate WHERE patient_location_status = 'province_not_in_area_map'
UNION ALL
SELECT 'city label not in the area map', count(*)
  FROM public_health.silver.diseases_hospital_encounters_silver__candidate WHERE patient_location_status = 'city_not_in_area_map'
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_hospital_encounters_silver__candidate
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'silver rows <> bronze rows',
       abs((SELECT count(*) FROM public_health.silver.diseases_hospital_encounters_silver__candidate)
         - (SELECT coalesce(sum(input_rows), 0) FROM public_health.silver.diseases_hospital_encounters_silver__inputs WHERE input_kind = 'bronze_source'));


-- =============================================================================
-- [5] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW enc_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'diseases'                                     AS domain,
       'public_health.silver.diseases_hospital_encounters_silver' AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.diseases_hospital_encounters_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [8]
       code_version                                   AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'long_stay_days', long_stay_days,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.diseases_hospital_encounters_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches = 0))) AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.diseases_hospital_encounters_silver__gates) g;


-- =============================================================================
-- [6] stop here if a gate failed. The failed build is logged first; the published table stays
--     as it was. The staging tables are kept so you can see what failed:
--       SELECT * FROM public_health.silver.diseases_hospital_encounters_silver__gates WHERE failures <> 0
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM enc_build_log WHERE status = 'failed';

SELECT raise_error(concat('diseases_hospital_encounters_silver was NOT published. ', error_message))
FROM enc_build_log WHERE status = 'failed';


-- =============================================================================
-- [7] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_encounters_silver AS
SELECT * FROM public_health.silver.diseases_hospital_encounters_silver__candidate;


-- =============================================================================
-- [8] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.diseases_hospital_encounters_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_hospital_encounters_silver)),
       code_version, parameters, run_id, error_message
FROM enc_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.diseases_hospital_encounters_silver__inputs;

-- Exceptions only: bronze rows that were NOT loaded. Every row of this source is loaded today,
-- so this inserts nothing; it is here so a future non-data row is recorded.
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.diseases_hospital_encounters_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       CASE c.row_class WHEN 'data' THEN 'loaded' WHEN 'non_data' THEN 'dropped_non_data'
                        WHEN 'duplicate' THEN 'duplicate_of' WHEN 'quarantined' THEN 'quarantined' END,
       c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.diseases_hospital_encounters_silver__classified c
LEFT JOIN public_health.silver.diseases_hospital_encounters_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [9] summary (counts only), then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW enc_summary AS
SELECT count(*) AS silver_rows,
       count_if(date_status <> 'ok') AS date_status_not_ok,
       count_if(is_same_day) AS same_day,
       count_if(is_long_stay) AS long_stay,
       count_if(patient_location_status <> 'ok') AS location_not_ok
FROM public_health.silver.diseases_hospital_encounters_silver;

SELECT * FROM enc_summary;

DROP TABLE IF EXISTS public_health.silver.diseases_hospital_encounters_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.diseases_hospital_encounters_silver__gates;
DROP TABLE IF EXISTS public_health.silver.diseases_hospital_encounters_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.diseases_hospital_encounters_silver__classified;
