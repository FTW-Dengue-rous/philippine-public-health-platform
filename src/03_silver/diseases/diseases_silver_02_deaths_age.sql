-- =============================================================================
-- Builds public_health.silver.diseases_deaths_age_silver:
--   registered deaths of one cause in one area in one year in one age group.
--   Key: (disease_key, area_key, year, age_group, _source_key)
-- Source: PSA deaths by region, annual (files on hand 2026-10-19: 2023 and 2024; the year comes
-- from each file name). It is the only source with age groups.
-- Each bronze row becomes 20 rows: 19 age bands plus "not stated" (the layout of the PSA table;
-- the gate "silver rows <> data rows x 20" stops the build if the layout changes).
--
-- Lineage on the silver row (7 columns): _silver_build_id, _source_key, _source_file,
--   _source_sheet, _source_row_num, _as_of_date, _metric_source_columns ({deaths: 'age_25_29'}).
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
-- [1] classify the bronze rows with the cause map (code, then label, then documented note prefix)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_deaths_age_silver__classified AS
WITH r AS (
  SELECT 'public_health.bronze.diseases_psa_deaths_region_annual_bronze' AS input_table,
         _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at,
         cause_of_death, dz_norm(cause_of_death) AS cause_norm,
         CASE WHEN regexp_extract(cause_of_death, '^[^0-9A-Za-z]*([0-9])[^0-9A-Za-z]{1,3}([0-9]{3}[a-d]?)', 1) <> ''
              THEN concat(regexp_extract(cause_of_death, '^[^0-9A-Za-z]*([0-9])[^0-9A-Za-z]{1,3}([0-9]{3}[a-d]?)', 1), '-',
                          regexp_extract(cause_of_death, '^[^0-9A-Za-z]*([0-9])[^0-9A-Za-z]{1,3}([0-9]{3}[a-d]?)', 2))
         END AS cause_code,
         dz_file_year(_source_file) AS file_year
  FROM public_health.bronze.diseases_psa_deaths_region_annual_bronze
  WHERE _source_key = 'psa_deaths_region_annual'
)
SELECT r.input_table, r._source_key, r._source_file, r._source_sheet, r._source_row_num, r._ingested_at,
       r.cause_code, r.file_year,
       coalesce(c1.row_class, c2.row_class, c3.row_class, 'unclassified') AS row_class,
       coalesce(c2.reason, c3.reason)                                     AS reason,
       coalesce(c1.disease_key, c2.disease_key)                           AS disease_key,
       trim(regexp_replace(r.cause_of_death, '^[^0-9A-Za-z]+', ''))       AS source_cause_label
FROM r
LEFT JOIN public_health.silver.diseases_cause_map c1
  ON c1._source_key = r._source_key AND c1.match_type = 'psa_code' AND c1.match_value = r.cause_code
LEFT JOIN public_health.silver.diseases_cause_map c2
  ON c2._source_key = r._source_key AND c2.match_type = 'label'
 AND r.cause_code IS NULL AND c2.match_value = r.cause_norm
LEFT JOIN public_health.silver.diseases_cause_map c3
  ON c3._source_key = r._source_key AND c3.match_type = 'label_prefix'
 AND r.cause_code IS NULL AND c2.match_value IS NULL AND startswith(r.cause_norm, c3.match_value);


-- =============================================================================
-- [2] inputs (layout of quality.build_inputs)
-- =============================================================================
-- Delta version of each table read. If your runtime rejects DESCRIBE HISTORY in a subquery,
-- use the NULL version below instead (the build still works; versions are just not recorded).
CREATE OR REPLACE TEMP VIEW age_table_versions AS
SELECT 'public_health.bronze.diseases_psa_deaths_region_annual_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_psa_deaths_region_annual_bronze)) AS table_version
UNION ALL SELECT 'public_health.silver.diseases_cause_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_cause_map))
UNION ALL SELECT 'public_health.silver.diseases_area_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_area_map));
-- CREATE OR REPLACE TEMP VIEW age_table_versions AS
-- SELECT CAST(NULL AS STRING) AS table_name, CAST(NULL AS BIGINT) AS table_version WHERE 1 = 0;

CREATE OR REPLACE TABLE public_health.silver.diseases_deaths_age_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.diseases_deaths_age_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT silver_build_id      AS build_id,
       'public_health.silver.diseases_deaths_age_silver' AS target_table,
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
LEFT JOIN age_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
-- the reference tables that shaped the build
SELECT silver_build_id, 'public_health.silver.diseases_deaths_age_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.diseases_cause_map' AS table_name, count(*) AS n FROM public_health.silver.diseases_cause_map
      UNION ALL SELECT 'public_health.silver.diseases_area_map', count(*) FROM public_health.silver.diseases_area_map) t
LEFT JOIN age_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] candidate rows. The area is joined before the unpivot.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_deaths_age_silver__candidate AS
WITH u AS (
  SELECT c.disease_key, c.cause_code, c.source_cause_label, c.file_year,
         a.area_key, a.geo_level, a.psgc_code, a.parent_area_key, a.geo_coverage_basis,
         b.geolocation, b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date,
         stack(20,
           'under_1', 0, 0, b.under_1, 'under_1',
           '1_4', 1, 4, b.age_1_4, 'age_1_4',
           '5_9', 5, 9, b.age_5_9, 'age_5_9',
           '10_14', 10, 14, b.age_10_14, 'age_10_14',
           '15_19', 15, 19, b.age_15_19, 'age_15_19',
           '20_24', 20, 24, b.age_20_24, 'age_20_24',
           '25_29', 25, 29, b.age_25_29, 'age_25_29',
           '30_34', 30, 34, b.age_30_34, 'age_30_34',
           '35_39', 35, 39, b.age_35_39, 'age_35_39',
           '40_44', 40, 44, b.age_40_44, 'age_40_44',
           '45_49', 45, 49, b.age_45_49, 'age_45_49',
           '50_54', 50, 54, b.age_50_54, 'age_50_54',
           '55_59', 55, 59, b.age_55_59, 'age_55_59',
           '60_64', 60, 64, b.age_60_64, 'age_60_64',
           '65_69', 65, 69, b.age_65_69, 'age_65_69',
           '70_74', 70, 74, b.age_70_74, 'age_70_74',
           '75_79', 75, 79, b.age_75_79, 'age_75_79',
           '80_84', 80, 84, b.age_80_84, 'age_80_84',
           '85_over', 85, CAST(NULL AS INT), b.age_85_over, 'age_85_over',
           'not_stated', CAST(NULL AS INT), CAST(NULL AS INT), b.age_not_stated, 'age_not_stated'
         ) AS (age_group, age_from, age_to, raw, src_col)
  FROM public_health.bronze.diseases_psa_deaths_region_annual_bronze b
  JOIN public_health.silver.diseases_deaths_age_silver__classified c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  LEFT JOIN public_health.silver.diseases_area_map a
    ON a._source_key = 'psa_deaths_region_annual' AND a.match_type = 'label' AND a.parent_label_norm IS NULL
   AND a.match_value = dz_norm(b.geolocation)
   AND (a.year_from IS NULL OR c.file_year >= try_cast(a.year_from AS INT))
   AND (a.year_to   IS NULL OR c.file_year <= try_cast(a.year_to   AS INT))
  WHERE b._source_key = 'psa_deaths_region_annual' AND c.row_class = 'data'
)
SELECT disease_key, cause_code AS source_cause_code, source_cause_label,
       area_key, trim(regexp_replace(geolocation, '^[^0-9A-Za-z]+', '')) AS area_label_source,
       geo_level, psgc_code, parent_area_key, geo_coverage_basis,
       'usual_residence'                  AS location_basis,
       file_year                          AS year,
       age_group, age_from, age_to,
       CAST(dz_num(raw) AS BIGINT)        AS deaths,
       dz_status(raw, NULL, 'missing')    AS value_status,
       'registered_deaths'                AS measure_definition,
       silver_build_id                    AS _silver_build_id,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('deaths', src_col)             AS _metric_source_columns
FROM u;


-- =============================================================================
-- [4] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_deaths_age_silver__gates AS
SELECT 'inputs: file or sheet with more than one load time' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.diseases_deaths_age_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.diseases_deaths_age_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.diseases_deaths_age_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'unclassified bronze rows', count(*)
  FROM public_health.silver.diseases_deaths_age_silver__classified WHERE row_class NOT IN ('data', 'non_data', 'duplicate', 'quarantined')
UNION ALL
SELECT 'cell that is neither a number nor a documented marker', count(*)
  FROM public_health.silver.diseases_deaths_age_silver__candidate WHERE value_status = 'parse_error'
UNION ALL
SELECT 'data row whose cause is not in the cause map', count(*) FROM public_health.silver.diseases_deaths_age_silver__candidate WHERE disease_key IS NULL
UNION ALL
SELECT 'data row whose area is not in the area map', count(*) FROM public_health.silver.diseases_deaths_age_silver__candidate WHERE area_key IS NULL
UNION ALL
SELECT 'negative value', count(*) FROM public_health.silver.diseases_deaths_age_silver__candidate WHERE deaths < 0
UNION ALL
SELECT 'age groups do not sum to the published total', count(*) FROM (
  SELECT c._source_file, c._source_row_num
  FROM public_health.silver.diseases_deaths_age_silver__candidate c
  JOIN public_health.bronze.diseases_psa_deaths_region_annual_bronze b
    ON b._source_key = c._source_key AND b._source_file = c._source_file AND b._source_row_num = c._source_row_num
  GROUP BY c._source_file, c._source_row_num
  HAVING NOT (sum(c.deaths) <=> CAST(max(dz_num(b.total)) AS BIGINT)))
UNION ALL
SELECT 'key column is null', count(*) FROM public_health.silver.diseases_deaths_age_silver__candidate
  WHERE disease_key IS NULL OR area_key IS NULL OR year IS NULL OR age_group IS NULL OR _source_key IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_deaths_age_silver__candidate
  GROUP BY disease_key, area_key, year, age_group, _source_key HAVING count(*) > 1)
UNION ALL
SELECT 'classified rows <> bronze rows read',
       abs((SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__classified)
         - (SELECT coalesce(sum(input_rows), 0) FROM public_health.silver.diseases_deaths_age_silver__inputs WHERE input_kind = 'bronze_source'))
UNION ALL
SELECT 'silver rows <> data rows x 20',
       abs((SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__candidate)
         - 20 * (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__classified WHERE row_class = 'data'))
UNION ALL
SELECT 'bronze rows referenced by silver lineage <> data rows',
       abs((SELECT count(*) FROM (SELECT DISTINCT _source_file, _source_sheet, _source_row_num FROM public_health.silver.diseases_deaths_age_silver__candidate))
         - (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__classified WHERE row_class = 'data'));


-- =============================================================================
-- [5] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW age_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'diseases'                                     AS domain,
       'public_health.silver.diseases_deaths_age_silver' AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [8]
       code_version                                   AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches = 0))) AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.diseases_deaths_age_silver__gates) g;


-- =============================================================================
-- [6] stop here if a gate failed. The failed build is logged first; the published table stays
--     as it was. The staging tables are kept so you can see what failed:
--       SELECT * FROM public_health.silver.diseases_deaths_age_silver__gates WHERE failures <> 0
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM age_build_log WHERE status = 'failed';

SELECT raise_error(concat('diseases_deaths_age_silver was NOT published. ', error_message))
FROM age_build_log WHERE status = 'failed';


-- =============================================================================
-- [7] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_deaths_age_silver AS
SELECT * FROM public_health.silver.diseases_deaths_age_silver__candidate;


-- =============================================================================
-- [8] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_deaths_age_silver)),
       code_version, parameters, run_id, error_message
FROM age_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.diseases_deaths_age_silver__inputs;

-- Exceptions only: bronze rows that were NOT loaded. Every row of this source is loaded today,
-- so this inserts nothing; it is here so a future non-data row is recorded.
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.diseases_deaths_age_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       CASE c.row_class WHEN 'data' THEN 'loaded' WHEN 'non_data' THEN 'dropped_non_data'
                        WHEN 'duplicate' THEN 'duplicate_of' WHEN 'quarantined' THEN 'quarantined' END,
       c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.diseases_deaths_age_silver__classified c
LEFT JOIN public_health.silver.diseases_deaths_age_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [9] summary, then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW age_summary AS
SELECT (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__classified) AS bronze_rows,
       (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver__classified WHERE row_class = 'data') AS data_rows,
       (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver) AS silver_rows,
       (SELECT count(DISTINCT age_group) FROM public_health.silver.diseases_deaths_age_silver) AS age_groups;

SELECT * FROM age_summary;

DROP TABLE IF EXISTS public_health.silver.diseases_deaths_age_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.diseases_deaths_age_silver__gates;
DROP TABLE IF EXISTS public_health.silver.diseases_deaths_age_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.diseases_deaths_age_silver__classified;
