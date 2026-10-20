-- =============================================================================
-- Builds public_health.silver.diseases_metric_silver:
--   one measure of one disease in one area in one period from one source.
--   Key: (disease_key, area_key, period_grain, period_key, measure, _source_key)
--
-- Build sequence (contract section 5.1)
--   Step 1, inputs
--     [0]  build id, settings, helper functions
--     [1]  cls_*               classify every bronze row of each source: data / non_data /
--                              duplicate / quarantined / unclassified
--     [2]  ..__classified      all classified rows, saved to a staging table
--     [3]  ..__inputs          one row per file or sheet read, with load id and checksum
--   Step 2, transform
--     [4]  part_*              one view per source, all with the same columns
--     [5]  ..__candidate       the candidate rows, saved to a staging table
--   Step 3, validate
--     [6]  ..__gates           every row must have failures = 0
--     [7]  metric_build_log    the row for quality.build_log (succeeded or failed)
--     [8]  STOP if a gate failed: the failed build is logged, nothing else is written
--   Step 4, record
--     [9]  write the table from the validated candidate
--     [10] append build_log, build_inputs, and row_disposition (rows not loaded only)
--     [11] summary per source; drop the staging tables
--
-- Needs
--   diseases_silver_00_reference.sql has been run (area map, cause map, directory)
--   quality_setup.sql has been run (build_log, build_inputs, row_disposition)
--   geography_silver is built (FHSIS TB region prefixes, latest snapshot; since 2026-10-19)
--   Bronze QC passed for the eight sources read here
--
-- Lineage on the silver row (contract 3.3, 7 columns)
--   _silver_build_id, _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
--   _metric_source_columns. Load time, load id and file checksum are in quality.build_inputs;

--   build time is in quality.build_log. One join gets them: quality.v_build_lineage.
--
-- Weekly dengue periods (2026-10-19, D-44 and D-46; replaces the open D4 / O-07 reading)
--   source   period_basis           period_key   year / week          period_start .. period_end
--   HDX      iso_week_ending_date   2016-01-10   ISO year / ISO week  date - 6 .. date
--   UP NOAH  iso_week               2016-W01     YR / WN (ISO)        Monday .. Sunday of the ISO week
--   UP NOAH is_approximated is false: FLAG_DEKADAL_APPROX is a rainfall flag (D-46).
--   Gate [6] checks every weekly row is a consistent ISO week. Gold dim_date must accept the two
--   new period_basis values (it listed week_number_unconfirmed and source_date_unconfirmed).
--   2026-10-21: the HDX date comparison in that gate uses try_cast (CAST_INVALID_INPUT on
--   '2016-W01' under ANSI mode: Spark does not short-circuit AND / OR). Same result on valid keys.
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

-- Source facts the classification depends on (rule 2a: named here, guarded by a gate).
-- HDX: the file that repeats the 2021 rows of the main file (finding F1), and the date pattern of
-- each file. If the repeat file is renamed, its rows load as data and the gate "key not unique"
-- stops the build.
DECLARE OR REPLACE VARIABLE hdx_repeat_file STRING DEFAULT 'hdx_dengue_province_weekly_2021.csv';
DECLARE OR REPLACE VARIABLE hdx_repeat_file_date_format STRING DEFAULT 'd/M/yyyy';
DECLARE OR REPLACE VARIABLE hdx_main_date_format STRING DEFAULT 'M/d/yyyy';

-- FHSIS TB region prefixes come from geography_silver (latest snapshot), not a typed list:
-- a code whose first two digits are not a region there stays 'unclassified' and fails a gate.
DECLARE OR REPLACE VARIABLE geography_checksum STRING;
SET VARIABLE geography_checksum =
  (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

CREATE OR REPLACE TEMP VIEW metric_region_prefixes AS
SELECT DISTINCT substr(lpad(trim(CAST(psgc_code AS STRING)), 10, '0'), 1, 2) AS region_prefix
FROM public_health.silver.geography_silver
WHERE content_checksum = geography_checksum AND geographic_level = 'Reg';

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

-- ISO 8601 weeks (D-44, D-46). Week 1 is the week with 4 January; weeks run Monday to Sunday.
-- Monday of week 1 of ISO year y, and the number of ISO weeks in y (52 or 53: 28 December is
-- always in the last week). weekofyear() and extract(YEAROFWEEK ...) are ISO in Spark.
CREATE OR REPLACE TEMPORARY FUNCTION dz_iso_week1_monday(y INT) RETURNS DATE
RETURN date_sub(make_date(y, 1, 4), weekday(make_date(y, 1, 4)));

CREATE OR REPLACE TEMPORARY FUNCTION dz_iso_weeks_in_year(y INT) RETURNS INT
RETURN weekofyear(make_date(y, 12, 28));


-- =============================================================================
-- [1] classify
-- Every view has: row_class, reason, and for duplicates the row that was kept
-- (kept_file, kept_sheet, kept_row).
-- =============================================================================

-- [1a] DOH FOI dengue: every row is data
CREATE OR REPLACE TEMP VIEW cls_doh_foi_dengue AS
SELECT t.*, 'data' AS row_class, CAST(NULL AS STRING) AS reason,
       CAST(NULL AS STRING) AS kept_file, CAST(NULL AS STRING) AS kept_sheet, CAST(NULL AS INT) AS kept_row
FROM public_health.bronze.diseases_doh_foi_dengue_bronze t
WHERE _source_key = 'doh_foi_dengue';

-- [1b] UP NOAH: every row is data
CREATE OR REPLACE TEMP VIEW cls_upnoah AS
SELECT t.*, 'data' AS row_class, CAST(NULL AS STRING) AS reason,
       CAST(NULL AS STRING) AS kept_file, CAST(NULL AS STRING) AS kept_sheet, CAST(NULL AS INT) AS kept_row
FROM public_health.bronze.diseases_upnoah_dengue_regional_bronze t
WHERE _source_key = 'upnoah';

-- [1c] HDX dengue
--   * the HXL tag row (loc starts with #) is not data
--   * the 2021 file repeats the 2021 rows of the main file (finding F1): its rows are duplicates.
--     dup_equal says whether the kept row has the same area, date, cases and deaths after parsing.
--   * the two files write dates differently: M/d/yyyy in the main file, d/M/yyyy in the 2021 file
CREATE OR REPLACE TEMP VIEW cls_hdx_dengue AS
WITH r AS (
  SELECT t.*,
         dz_norm(loc) AS loc_norm,
         endswith(_source_file, hdx_repeat_file) AS is_dup_file,
         CASE WHEN endswith(_source_file, hdx_repeat_file)
              THEN to_date(try_to_timestamp(`date`, hdx_repeat_file_date_format))
              ELSE to_date(try_to_timestamp(`date`, hdx_main_date_format)) END AS obs_date,
         dz_num(cases) AS cases_n, dz_num(deaths) AS deaths_n
  FROM public_health.bronze.diseases_hdx_dengue_bronze t
  WHERE _source_key = 'hdx_dengue'
),
kept AS (SELECT * FROM r WHERE NOT is_dup_file AND loc NOT LIKE '#%')
SELECT r.*,
       CASE WHEN r.loc LIKE '#%' THEN 'non_data' WHEN r.is_dup_file THEN 'duplicate' ELSE 'data' END AS row_class,
       CASE WHEN r.loc LIKE '#%' THEN 'hxl_tag_row' WHEN r.is_dup_file THEN 'repeats_main_file' END AS reason,
       k._source_file AS kept_file, k._source_sheet AS kept_sheet, k._source_row_num AS kept_row,
       (k._source_row_num IS NOT NULL AND k.cases_n <=> r.cases_n AND k.deaths_n <=> r.deaths_n) AS dup_equal
FROM r
LEFT JOIN kept k
  ON r.is_dup_file AND r.loc NOT LIKE '#%' AND k.loc_norm = r.loc_norm AND k.obs_date = r.obs_date;

-- [1d] PSA deaths (three tables). The cause map decides which rows are data:
--      tabulation code first, then the whole label, then a documented prefix for notes.
--      A row that matches nothing is 'unclassified' and fails a gate.
CREATE OR REPLACE TEMP VIEW psa_rows AS
SELECT _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, cause_of_death
FROM public_health.bronze.diseases_psa_deaths_national_monthly_bronze WHERE _source_key = 'psa_deaths_national_monthly'
UNION ALL
SELECT _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, cause_of_death
FROM public_health.bronze.diseases_psa_deaths_region_annual_bronze WHERE _source_key = 'psa_deaths_region_annual'
UNION ALL
SELECT _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, cause_of_death
FROM public_health.bronze.diseases_psa_deaths_national_annual_bronze WHERE _source_key = 'psa_deaths_national_annual';

CREATE OR REPLACE TEMP VIEW cls_psa AS
WITH r AS (
  SELECT p.*,
         dz_norm(cause_of_death) AS cause_norm,
         -- a digit, one to three separator characters (any dash, spaces), three digits, optional letter
         CASE WHEN regexp_extract(cause_of_death, '^[^0-9A-Za-z]*([0-9])[^0-9A-Za-z]{1,3}([0-9]{3}[a-d]?)', 1) <> ''
              THEN concat(regexp_extract(cause_of_death, '^[^0-9A-Za-z]*([0-9])[^0-9A-Za-z]{1,3}([0-9]{3}[a-d]?)', 1), '-',
                          regexp_extract(cause_of_death, '^[^0-9A-Za-z]*([0-9])[^0-9A-Za-z]{1,3}([0-9]{3}[a-d]?)', 2))
         END AS cause_code,
         dz_file_year(_source_file) AS file_year
  FROM psa_rows p
)
SELECT r.*,
       coalesce(c1.row_class, c2.row_class, c3.row_class, 'unclassified') AS row_class,
       coalesce(c2.reason, c3.reason)                                     AS reason,
       coalesce(c1.disease_key, c2.disease_key)                           AS disease_key,
       trim(regexp_replace(r.cause_of_death, '^[^0-9A-Za-z]+', ''))       AS source_cause_label,
       CAST(NULL AS STRING) AS kept_file, CAST(NULL AS STRING) AS kept_sheet, CAST(NULL AS INT) AS kept_row
FROM r
LEFT JOIN public_health.silver.diseases_cause_map c1
  ON c1._source_key = r._source_key AND c1.match_type = 'psa_code' AND c1.match_value = r.cause_code
LEFT JOIN public_health.silver.diseases_cause_map c2
  ON c2._source_key = r._source_key AND c2.match_type = 'label'
 AND r.cause_code IS NULL AND c2.match_value = r.cause_norm
LEFT JOIN public_health.silver.diseases_cause_map c3
  ON c3._source_key = r._source_key AND c3.match_type = 'label_prefix'
 AND r.cause_code IS NULL AND c2.match_value IS NULL AND startswith(r.cause_norm, c3.match_value);

-- [1e] FHSIS TB. Areas come from the row's own PSGC code (9 digits in the 2024 sheet: left-padded).
--   data         Philippines row; rows with a valid 10-digit code
--   non_data     hospital section (code 0); legend and source lines
--   quarantined  special geographic area codes 19999..... (finding F9: unresolved until reviewed)
--   F7: in the 2024 sheet the Philippines row carries NCR's code. A row_override in the area map,
--       matched on file, sheet, row, printed label and printed code, turns it into the country row.
CREATE OR REPLACE TEMP VIEW cls_fhsis_tb AS
WITH r AS (
  SELECT t.*,
         dz_norm(area_name) AS area_norm,
         CASE WHEN psgc_code RLIKE '^[0-9]{9,10}$' THEN lpad(psgc_code, 10, '0') END AS code10,
         dz_file_year(_source_file) AS file_year
  FROM public_health.bronze.diseases_fhsis_tb_bronze t
  WHERE _source_key = 'doh_fhsis'
),
o AS (
  SELECT * FROM public_health.silver.diseases_area_map
  WHERE _source_key = 'doh_fhsis' AND match_type = 'row_override'
),
j AS (
  SELECT r.*, (o.area_key IS NOT NULL) AS override_applied,
         (r.area_norm = 'PHILIPPINES' AND r.psgc_code IS NULL) AS is_country_row
  FROM r
  LEFT JOIN o
    ON o.override_source_file = r._source_file AND o.override_source_sheet <=> r._source_sheet
   AND try_cast(o.override_source_row_num AS INT) = r._source_row_num
   AND o.match_value = r.area_norm AND o.parent_label_norm <=> r.code10
)
SELECT j.*,
       CASE WHEN override_applied OR is_country_row THEN 'data'
            WHEN trim(psgc_code) = '0' THEN 'non_data'
            WHEN area_name IS NULL AND code10 IS NULL THEN 'non_data'
            WHEN code10 LIKE '19999%' THEN 'quarantined'
            -- region prefix of a region in the geography snapshot (was a typed list to 2026-10-19)
            WHEN rp.region_prefix IS NOT NULL THEN 'data'
            ELSE 'unclassified' END AS row_class,
       CASE WHEN override_applied OR is_country_row THEN NULL
            WHEN trim(psgc_code) = '0' THEN 'hospital_section'
            WHEN area_name IS NULL AND code10 IS NULL
                 THEN CASE WHEN upper(psgc_code) LIKE 'SOURCE%' THEN 'source_line' ELSE 'legend' END
            WHEN code10 LIKE '19999%' THEN 'area_unresolved' END AS reason,
       CASE WHEN override_applied OR is_country_row THEN 'ph' ELSE concat('psgc:', code10) END AS tb_area_key,
       CAST(NULL AS STRING) AS kept_file, CAST(NULL AS STRING) AS kept_sheet, CAST(NULL AS INT) AS kept_row
FROM j
LEFT JOIN metric_region_prefixes rp ON rp.region_prefix = substr(j.code10, 1, 2);

-- [1f] IHME GBD. A (location, measure, cause, year) held by two files is kept once (finding F2):
--      the neoplasms file wins. dup_equal says whether the dropped row has the same values.
CREATE OR REPLACE TEMP VIEW cls_ihme_gbd AS
WITH r AS (
  SELECT t.*,
         row_number() OVER (
           PARTITION BY location_id, measure_id, cause_id, year, sex_id, age_id, metric_id, population_group_id
           ORDER BY CASE WHEN _source_file LIKE '%ihme_gbd_neoplasms_%' THEN 0 ELSE 1 END,
                    _source_file, _source_row_num) AS rn
  FROM public_health.bronze.diseases_ihme_gbd_bronze t
  WHERE _source_key = 'ihme_gbd'
)
SELECT r.*,
       CASE WHEN r.rn = 1 THEN 'data' ELSE 'duplicate' END AS row_class,
       CASE WHEN r.rn > 1 THEN 'repeats_preferred_file' END AS reason,
       k._source_file AS kept_file, k._source_sheet AS kept_sheet, k._source_row_num AS kept_row,
       (r.rn > 1 AND try_cast(k.val AS DOUBLE)   <=> try_cast(r.val AS DOUBLE)
                 AND try_cast(k.lower AS DOUBLE) <=> try_cast(r.lower AS DOUBLE)
                 AND try_cast(k.upper AS DOUBLE) <=> try_cast(r.upper AS DOUBLE)) AS dup_equal
FROM r
LEFT JOIN r k
  ON r.rn > 1 AND k.rn = 1
 AND k.location_id = r.location_id AND k.measure_id = r.measure_id AND k.cause_id = r.cause_id
 AND k.year = r.year AND k.sex_id = r.sex_id AND k.age_id = r.age_id
 AND k.metric_id = r.metric_id AND k.population_group_id = r.population_group_id;


-- =============================================================================
-- [2] all classified rows, one line per bronze row, saved to a staging table so the gates,
--     the inputs and the dispositions all read the same result.
--     measures_per_row = silver rows one data row must produce (the unpivot rule)
--     row_issue        = a row-level problem found while classifying (must be null everywhere)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_metric_silver__classified AS
SELECT 'public_health.bronze.diseases_doh_foi_dengue_bronze' AS input_table,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, kept_file, kept_sheet, kept_row,
       2 AS measures_per_row, CAST(NULL AS STRING) AS row_issue, false AS override_applied
FROM cls_doh_foi_dengue
UNION ALL
SELECT 'public_health.bronze.diseases_upnoah_dengue_regional_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, kept_file, kept_sheet, kept_row, 1, CAST(NULL AS STRING), false
FROM cls_upnoah
UNION ALL
SELECT 'public_health.bronze.diseases_hdx_dengue_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, kept_file, kept_sheet, kept_row, 2,
       CASE WHEN row_class = 'duplicate' AND NOT coalesce(dup_equal, false) THEN 'hdx_duplicate_not_equal'
            WHEN row_class = 'data' AND obs_date IS NULL THEN 'hdx_date_not_parsed' END,
       false
FROM cls_hdx_dengue
UNION ALL
SELECT CASE _source_key WHEN 'psa_deaths_national_monthly' THEN 'public_health.bronze.diseases_psa_deaths_national_monthly_bronze'
                        WHEN 'psa_deaths_region_annual'    THEN 'public_health.bronze.diseases_psa_deaths_region_annual_bronze'
                        WHEN 'psa_deaths_national_annual'  THEN 'public_health.bronze.diseases_psa_deaths_national_annual_bronze' END,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, CAST(NULL AS DATE),
       row_class, reason, kept_file, kept_sheet, kept_row,
       CASE _source_key WHEN 'psa_deaths_national_monthly' THEN 13      -- 12 months + the published Total
                        WHEN 'psa_deaths_region_annual'    THEN 1
                        WHEN 'psa_deaths_national_annual'  THEN 6 END,  -- 6 year columns
       CAST(NULL AS STRING), false
FROM cls_psa
UNION ALL
SELECT 'public_health.bronze.diseases_fhsis_tb_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, kept_file, kept_sheet, kept_row, 2, CAST(NULL AS STRING), override_applied
FROM cls_fhsis_tb
UNION ALL
SELECT 'public_health.bronze.diseases_ihme_gbd_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, kept_file, kept_sheet, kept_row, 1,
       CASE WHEN row_class = 'duplicate' AND NOT coalesce(dup_equal, false) THEN 'ihme_duplicate_not_equal'
            WHEN NOT (metric_id = '1' AND age_id = '22' AND sex_id = '3' AND population_group_id = '1'
                      AND measure_id IN ('1', '5')) THEN 'ihme_scope_outside_verified_constants' END,
       false
FROM cls_ihme_gbd;


-- =============================================================================
-- [3] inputs: everything this build reads, in the column layout of quality.build_inputs.
--     Each file or sheet is looked up ONCE in the ingestion log. The result is never joined
--     onto the silver rows.
-- =============================================================================

-- Delta version of each table read. If your runtime rejects DESCRIBE HISTORY in a subquery,
-- use the NULL version below instead (the build still works; versions are just not recorded).
CREATE OR REPLACE TEMP VIEW metric_table_versions AS
SELECT 'public_health.bronze.diseases_doh_foi_dengue_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_doh_foi_dengue_bronze)) AS table_version
UNION ALL SELECT 'public_health.bronze.diseases_upnoah_dengue_regional_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_upnoah_dengue_regional_bronze))
UNION ALL SELECT 'public_health.bronze.diseases_hdx_dengue_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_hdx_dengue_bronze))
UNION ALL SELECT 'public_health.bronze.diseases_psa_deaths_national_monthly_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_psa_deaths_national_monthly_bronze))
UNION ALL SELECT 'public_health.bronze.diseases_psa_deaths_region_annual_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_psa_deaths_region_annual_bronze))
UNION ALL SELECT 'public_health.bronze.diseases_psa_deaths_national_annual_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_psa_deaths_national_annual_bronze))
UNION ALL SELECT 'public_health.bronze.diseases_fhsis_tb_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_fhsis_tb_bronze))
UNION ALL SELECT 'public_health.bronze.diseases_ihme_gbd_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_ihme_gbd_bronze))
UNION ALL SELECT 'public_health.silver.diseases_cause_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_cause_map))
UNION ALL SELECT 'public_health.silver.diseases_area_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_area_map))
UNION ALL SELECT 'public_health.silver.diseases_directory_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_directory_silver))
UNION ALL SELECT 'public_health.silver.geography_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.geography_silver));
-- NULL version (use this instead if the view above fails):
-- CREATE OR REPLACE TEMP VIEW metric_table_versions AS
-- SELECT CAST(NULL AS STRING) AS table_name, CAST(NULL AS BIGINT) AS table_version WHERE 1 = 0;

CREATE OR REPLACE TABLE public_health.silver.diseases_metric_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.diseases_metric_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT silver_build_id                                   AS build_id,
       'public_health.silver.diseases_metric_silver'     AS target_table,
       'bronze_source'                                   AS input_kind,
       f.input_table,
       max(v.table_version)                              AS input_table_version,
       f._source_key                                     AS source_key,
       f._source_file                                    AS source_file,
       f._source_sheet                                   AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END         AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at                                    AS ingested_at,
       f.input_rows,
       CAST(NULL AS STRING)                              AS reference_version,
       count(m.batch_id)                                 AS metadata_matches      -- gate only, not appended
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key
 AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet
 AND m.retrieved_at = f._ingested_at
LEFT JOIN metric_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
-- the reference tables that shaped the build
SELECT silver_build_id, 'public_health.silver.diseases_metric_silver', 'table', t.table_name,
       v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CASE WHEN t.table_name LIKE '%geography_silver' THEN geography_checksum END,   -- snapshot read
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.diseases_cause_map' AS table_name, count(*) AS n FROM public_health.silver.diseases_cause_map
      UNION ALL SELECT 'public_health.silver.diseases_area_map', count(*) FROM public_health.silver.diseases_area_map
      UNION ALL SELECT 'public_health.silver.diseases_directory_silver', count(*) FROM public_health.silver.diseases_directory_silver
      -- region prefixes only (FHSIS TB classification); input_rows = regions in the snapshot
      UNION ALL SELECT 'public_health.silver.geography_silver', count(*) FROM metric_region_prefixes) t
LEFT JOIN metric_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [4] one view per source. All eight have the same columns in the same order; the list after
--     each view name gives them. Each SELECT fills those columns by position.
-- raw is the cell as text; [5] turns it into value and value_status.
-- Areas are joined BEFORE the unpivot, so one bronze row cannot be multiplied by the join.
-- =============================================================================

-- [4a] DOH FOI dengue: region, month; cases and deaths
CREATE OR REPLACE TEMP VIEW part_doh_foi_dengue
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
WITH s AS (
  SELECT r.*, try_cast(trim(r.Year) AS INT) AS y, try_cast(trim(r.Month) AS INT) AS m,
         a.area_key, a.geo_level, a.psgc_code, a.parent_area_key, a.geo_coverage_basis, a.is_superseded_area
  FROM cls_doh_foi_dengue r
  LEFT JOIN public_health.silver.diseases_area_map a
    ON a._source_key = 'doh_foi_dengue' AND a.match_type = 'label' AND a.parent_label_norm IS NULL
   AND a.match_value = dz_norm(r.Region)
  WHERE r.row_class = 'data'
),
u AS (
  SELECT s.*, stack(2, 'cases', Cases, 'Cases', 'deaths', Deaths, 'Deaths') AS (measure, raw, src_col) FROM s
)
SELECT 'dengue' AS disease_key, CAST(NULL AS STRING) AS source_cause_code, CAST(NULL AS STRING) AS source_cause_label,
       area_key, trim(Region) AS area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis,
       'reporting_unconfirmed' AS location_basis,
       'month' AS period_grain, concat(y, '-M', lpad(CAST(m AS STRING), 2, '0')) AS period_key,
       y AS year, m AS month, CAST(NULL AS INT) AS week,
       CASE WHEN m BETWEEN 1 AND 12 THEN make_date(y, m, 1) END AS period_start,
       CASE WHEN m BETWEEN 1 AND 12 THEN last_day(make_date(y, m, 1)) END AS period_end,
       'calendar_month' AS period_basis,
       measure, concat('reported_dengue_', measure) AS measure_definition,
       raw, CAST(NULL AS STRING) AS raw_lower, CAST(NULL AS STRING) AS raw_upper,
       'reported' AS value_type, CAST(NULL AS STRING) AS star_status, 'missing' AS blank_status,
       false AS is_partial_period, false AS is_preliminary, false AS is_approximated,
       false AS source_plausibility_flag, coalesce(is_superseded_area = 'true', false) AS is_superseded_area,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('value', src_col) AS _metric_source_columns
FROM u;

-- [4b] UP NOAH: region, ISO week; cases only.
--      DC_DOH holds DOH-EB counts released under FOI 2026-031, by ISO week (WN) and ISO year (YR).
--      They are NOT approximated (D-46): FLAG_DEKADAL_APPROX belongs to the rainfall column
--      (RF_HDX, CHIRPS 10-day totals split into weeks), so it is not read here.
--      period_start / period_end = Monday to Sunday of that ISO week. DOH counts by Sunday to
--      Saturday weeks, so a week can sit one day off the DOH week; peaks and totals do not change.
CREATE OR REPLACE TEMP VIEW part_upnoah
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
WITH s AS (
  SELECT r.*, try_cast(trim(r.YR) AS INT) AS y, try_cast(trim(r.WN) AS INT) AS w,
         a.area_key, a.geo_level, a.psgc_code, a.parent_area_key, a.geo_coverage_basis, a.is_superseded_area
  FROM cls_upnoah r
  LEFT JOIN public_health.silver.diseases_area_map a
    ON a._source_key = 'upnoah' AND a.match_type = 'label' AND a.parent_label_norm IS NULL
   AND a.match_value = dz_norm(r.REGION)
  WHERE r.row_class = 'data'
)
SELECT 'dengue', CAST(NULL AS STRING), CAST(NULL AS STRING),
       area_key, trim(REGION), geo_level, psgc_code, parent_area_key, geo_coverage_basis,
       'reporting_unconfirmed',
       'week', concat(y, '-W', lpad(CAST(w AS STRING), 2, '0')),
       y, CAST(NULL AS INT), w,
       date_add(dz_iso_week1_monday(y), (w - 1) * 7),   -- ISO week, Monday (D-46)
       date_add(dz_iso_week1_monday(y), (w - 1) * 7 + 6),  -- Sunday
       'iso_week',
       'cases', 'reported_dengue_cases',
       DC_DOH, CAST(NULL AS STRING), CAST(NULL AS STRING),
       'reported', CAST(NULL AS STRING), 'missing',
       false, false, false, (trim(FLAG_PLAUSIBILITY) = '1'),   -- is_approximated false (D-46)
       coalesce(is_superseded_area = 'true', false),
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('value', 'DC_DOH')
FROM s;

-- [4c] HDX dengue: province or city, weekly date; cases and deaths
--      The date CLOSES its week (D-44): the week is date - 6 to date, and its week number and year
--      are the ISO week and ISO year of the date. period_key keeps the date (yyyy-MM-dd); label it
--      "week ending <date>". year is the ISO year, so a date in early January can belong to the
--      year before (2021-01-03 is 2020-W53).
CREATE OR REPLACE TEMP VIEW part_hdx_dengue
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
WITH s AS (
  SELECT r.*,
         a.area_key, a.geo_level, a.psgc_code, a.parent_area_key, a.geo_coverage_basis, a.is_superseded_area
  FROM cls_hdx_dengue r
  LEFT JOIN public_health.silver.diseases_area_map a
    ON a._source_key = 'hdx_dengue' AND a.match_type = 'label' AND a.parent_label_norm IS NULL
   AND a.match_value = r.loc_norm
  WHERE r.row_class = 'data'
),
u AS (
  SELECT s.*, stack(2, 'cases', cases, 'cases', 'deaths', deaths, 'deaths') AS (measure, raw, src_col) FROM s
)
SELECT 'dengue', CAST(NULL AS STRING), CAST(NULL AS STRING),
       area_key, trim(loc), geo_level, psgc_code, parent_area_key, geo_coverage_basis,
       'reporting_unconfirmed',
       'week', date_format(obs_date, 'yyyy-MM-dd'),
       CAST(extract(YEAROFWEEK FROM obs_date) AS INT), CAST(NULL AS INT), weekofyear(obs_date),
       date_sub(obs_date, 6), obs_date,                 -- the date closes its week (D-44)
       'iso_week_ending_date',
       measure, concat('reported_dengue_', measure),
       raw, CAST(NULL AS STRING), CAST(NULL AS STRING),
       'reported', CAST(NULL AS STRING), 'missing',
       false, false, false, false, coalesce(is_superseded_area = 'true', false),
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('value', src_col)
FROM u;

-- [4d] PSA deaths, national by month: 12 month rows, and the published Total as a year row
CREATE OR REPLACE TEMP VIEW part_psa_monthly
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
WITH u AS (
  SELECT c.disease_key, c.cause_code, c.source_cause_label, c.file_year,
         b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date,
         stack(13,
           'year',  0, b.total,     'total',
           'month', 1, b.january,   'january',   'month', 2,  b.february, 'february',
           'month', 3, b.march,     'march',     'month', 4,  b.april,    'april',
           'month', 5, b.may,       'may',       'month', 6,  b.june,     'june',
           'month', 7, b.july,      'july',      'month', 8,  b.august,   'august',
           'month', 9, b.september, 'september', 'month', 10, b.october,  'october',
           'month', 11, b.november, 'november',  'month', 12, b.december, 'december'
         ) AS (grain, m, raw, src_col)
  FROM public_health.bronze.diseases_psa_deaths_national_monthly_bronze b
  JOIN cls_psa c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'psa_deaths_national_monthly' AND c.row_class = 'data'
)
SELECT disease_key, cause_code, source_cause_label,
       'ph', 'Philippines', 'country', CAST(NULL AS STRING), CAST(NULL AS STRING), 'country',
       'usual_residence',
       grain,
       CASE WHEN grain = 'year' THEN CAST(file_year AS STRING)
            ELSE concat(file_year, '-M', lpad(CAST(m AS STRING), 2, '0')) END,
       file_year, CASE WHEN grain = 'month' THEN m END, CAST(NULL AS INT),
       CASE WHEN grain = 'year' THEN make_date(file_year, 1, 1)   ELSE make_date(file_year, m, 1) END,
       CASE WHEN grain = 'year' THEN make_date(file_year, 12, 31) ELSE last_day(make_date(file_year, m, 1)) END,
       CASE WHEN grain = 'year' THEN 'calendar_year' ELSE 'calendar_month' END,
       'deaths', 'registered_deaths',
       raw, CAST(NULL AS STRING), CAST(NULL AS STRING),
       'registered', CAST(NULL AS STRING), 'missing',
       false, false, false, false, false,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('value', src_col)
FROM u;

-- [4e] PSA deaths by region, annual: the Total column (the age columns go to the age table)
CREATE OR REPLACE TEMP VIEW part_psa_region
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
SELECT c.disease_key, c.cause_code, c.source_cause_label,
       a.area_key, trim(regexp_replace(b.geolocation, '^[^0-9A-Za-z]+', '')), a.geo_level, a.psgc_code,
       a.parent_area_key, a.geo_coverage_basis,
       'usual_residence',
       'year', CAST(c.file_year AS STRING),
       c.file_year, CAST(NULL AS INT), CAST(NULL AS INT),
       make_date(c.file_year, 1, 1), make_date(c.file_year, 12, 31), 'calendar_year',
       'deaths', 'registered_deaths',
       b.total, CAST(NULL AS STRING), CAST(NULL AS STRING),
       'registered', CAST(NULL AS STRING), 'missing',
       false, false, false, false, coalesce(a.is_superseded_area = 'true', false),
       b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date,
       map('value', 'total')
FROM public_health.bronze.diseases_psa_deaths_region_annual_bronze b
JOIN cls_psa c
  ON c._source_key = b._source_key AND c._source_file = b._source_file
 AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
LEFT JOIN public_health.silver.diseases_area_map a
  ON a._source_key = 'psa_deaths_region_annual' AND a.match_type = 'label' AND a.parent_label_norm IS NULL
 AND a.match_value = dz_norm(b.geolocation)
 -- Regions VI and VII have one map row per year: before and after the Negros Island Region
 AND (a.year_from IS NULL OR c.file_year >= try_cast(a.year_from AS INT))
 AND (a.year_to   IS NULL OR c.file_year <= try_cast(a.year_to   AS INT))
WHERE b._source_key = 'psa_deaths_region_annual' AND c.row_class = 'data';

-- [4f] PSA deaths, national annual 2015-2020: one row per year column. 2020 is preliminary.
--      '*' means not applicable (the COVID rows before 2020).
CREATE OR REPLACE TEMP VIEW part_psa_annual
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
WITH u AS (
  SELECT c.disease_key, c.cause_code, c.source_cause_label,
         b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date,
         stack(6,
           2015, b.deaths_2015, 'deaths_2015',  2016, b.deaths_2016, 'deaths_2016',
           2017, b.deaths_2017, 'deaths_2017',  2018, b.deaths_2018, 'deaths_2018',
           2019, b.deaths_2019, 'deaths_2019',  2020, b.deaths_2020_prelim, 'deaths_2020_prelim'
         ) AS (y, raw, src_col)
  FROM public_health.bronze.diseases_psa_deaths_national_annual_bronze b
  JOIN cls_psa c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'psa_deaths_national_annual' AND c.row_class = 'data'
)
SELECT disease_key, cause_code, source_cause_label,
       'ph', 'Philippines', 'country', CAST(NULL AS STRING), CAST(NULL AS STRING), 'country',
       'usual_residence',
       'year', CAST(y AS STRING),
       y, CAST(NULL AS INT), CAST(NULL AS INT),
       make_date(y, 1, 1), make_date(y, 12, 31), 'calendar_year',
       'deaths', 'registered_deaths',
       raw, CAST(NULL AS STRING), CAST(NULL AS STRING),
       'registered', 'not_applicable', 'missing',
       false, (src_col LIKE '%prelim%'), false, false, false,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('value', src_col)
FROM u;

-- [4g] FHSIS TB: two notification counts per area; '*' and blank mean no report.
--      geo_level and parent come from the PSGC code pattern. PROVISIONAL until geography silver
--      is joined: ........00000000 region; .....00000 province, or city when the name says so;
--      anything else city_municipality.
CREATE OR REPLACE TEMP VIEW part_fhsis_tb
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
WITH u AS (
  SELECT s.*,
         stack(2,
           'tb_all_forms',      'notified_tb_cases_all_forms',      cases_total,    'cases_total',
           'tb_drug_resistant', 'notified_tb_cases_drug_resistant', dr_cases_total, 'dr_cases_total'
         ) AS (disease_key, definition, raw, src_col)
  FROM cls_fhsis_tb s WHERE row_class = 'data'
)
SELECT disease_key, CAST(NULL AS STRING), CAST(NULL AS STRING),
       tb_area_key, trim(area_name),
       CASE WHEN tb_area_key = 'ph' THEN 'country'
            WHEN code10 LIKE '%00000000' THEN 'region'
            WHEN code10 LIKE '%00000' THEN
                 CASE WHEN area_norm LIKE 'CITY OF %' OR area_norm LIKE '% CITY' THEN 'city' ELSE 'province' END
            ELSE 'city_municipality' END,
       CASE WHEN tb_area_key <> 'ph' THEN code10 END,
       CASE WHEN tb_area_key = 'ph' THEN NULL
            WHEN code10 LIKE '%00000000' THEN 'ph'
            WHEN code10 LIKE '%00000' THEN concat('psgc:', substr(code10, 1, 2), '00000000')
            ELSE concat('psgc:', substr(code10, 1, 5), '00000') END,
       CASE WHEN tb_area_key = 'ph' THEN 'country' ELSE 'psgc_unit_as_reported' END,
       'reporting_unit',
       'year', CAST(file_year AS STRING),
       file_year, CAST(NULL AS INT), CAST(NULL AS INT),
       make_date(file_year, 1, 1), make_date(file_year, 12, 31), 'calendar_year',
       'cases', definition,
       raw, CAST(NULL AS STRING), CAST(NULL AS STRING),
       'reported', 'no_report', 'no_report',
       false, false, false, false, false,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('value', src_col)
FROM u;

-- [4h] IHME GBD: province, year; deaths and prevalence, with lower and upper bounds.
--      Modelled numbers; prevalence is a number of prevalent cases, not a percentage.
CREATE OR REPLACE TEMP VIEW part_ihme_gbd
  (disease_key, source_cause_code, source_cause_label,
   area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
   period_grain, period_key, year, month, week, period_start, period_end, period_basis,
   measure, measure_definition, raw, raw_lower, raw_upper, value_type, star_status, blank_status,
   is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns)
AS
SELECT c.disease_key, s.cause_id, s.cause_name,
       a.area_key, s.location_name, a.geo_level, a.psgc_code, a.parent_area_key, a.geo_coverage_basis,
       'modelled_population',
       'year', trim(s.year),
       try_cast(trim(s.year) AS INT), CAST(NULL AS INT), CAST(NULL AS INT),
       make_date(try_cast(trim(s.year) AS INT), 1, 1), make_date(try_cast(trim(s.year) AS INT), 12, 31), 'calendar_year',
       CASE s.measure_id WHEN '1' THEN 'deaths' WHEN '5' THEN 'prevalence' END,
       CASE s.measure_id WHEN '1' THEN 'modelled_deaths_number' WHEN '5' THEN 'modelled_prevalent_cases_number' END,
       s.val, s.lower, s.upper,
       'modelled', CAST(NULL AS STRING), 'missing',
       false, false, false, false, coalesce(a.is_superseded_area = 'true', false),
       s._source_key, s._source_file, s._source_sheet, s._source_row_num, s._as_of_date,
       map('value', 'val', 'value_lower', 'lower', 'value_upper', 'upper')
FROM cls_ihme_gbd s
LEFT JOIN public_health.silver.diseases_cause_map c
  ON c._source_key = 'ihme_gbd' AND c.match_type = 'ihme_cause_id' AND c.match_value = s.cause_id
LEFT JOIN public_health.silver.diseases_area_map a
  ON a._source_key = 'ihme_gbd' AND a.match_type = 'source_id' AND a.match_value = s.location_id
WHERE s.row_class = 'data';


-- =============================================================================
-- [5] candidate rows
-- =============================================================================
CREATE OR REPLACE TEMP VIEW metric_parts AS
SELECT * FROM part_doh_foi_dengue
UNION ALL SELECT * FROM part_upnoah
UNION ALL SELECT * FROM part_hdx_dengue
UNION ALL SELECT * FROM part_psa_monthly
UNION ALL SELECT * FROM part_psa_region
UNION ALL SELECT * FROM part_psa_annual
UNION ALL SELECT * FROM part_fhsis_tb
UNION ALL SELECT * FROM part_ihme_gbd;

-- Saved to a staging table: the rows validated in [6] are exactly the rows published in [9].
CREATE OR REPLACE TABLE public_health.silver.diseases_metric_silver__candidate AS
SELECT
  disease_key, source_cause_code, source_cause_label,
  area_key, area_label_source, geo_level, psgc_code, parent_area_key, geo_coverage_basis, location_basis,
  period_grain, period_key, year, month, week, period_start, period_end, period_basis,
  measure, measure_definition,
  dz_num(raw)                                AS value,          -- DECIMAL(20,4): IHME values are not whole numbers
  'count'                                    AS value_unit,     -- no rates in silver; rates are computed in gold
  dz_num(raw_lower)                          AS value_lower,
  dz_num(raw_upper)                          AS value_upper,
  value_type,
  dz_status(raw, star_status, blank_status)  AS value_status,   -- ok / missing / no_report / not_applicable / parse_error
  'all_ages'                                 AS age_scope,      -- gated for IHME in [6]
  'both_sexes'                               AS sex_scope,
  is_partial_period, is_preliminary, is_approximated, source_plausibility_flag, is_superseded_area,
  silver_build_id                            AS _silver_build_id,
  _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
  _metric_source_columns
FROM metric_parts;


-- =============================================================================
-- [6] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_metric_silver__gates AS
SELECT 'inputs: file or sheet with more than one load time' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.diseases_metric_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.diseases_metric_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.diseases_metric_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'unclassified bronze rows', count(*)
  FROM public_health.silver.diseases_metric_silver__classified WHERE row_class NOT IN ('data', 'non_data', 'duplicate', 'quarantined')
UNION ALL
SELECT 'bronze row classified more than once', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_metric_silver__classified GROUP BY _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'HDX duplicate-file row not equal to the kept row after parsing (F1)', count(*)
  FROM public_health.silver.diseases_metric_silver__classified WHERE row_issue = 'hdx_duplicate_not_equal'
UNION ALL
SELECT 'HDX data row with a date that does not parse', count(*)
  FROM public_health.silver.diseases_metric_silver__classified WHERE row_issue = 'hdx_date_not_parsed'
UNION ALL
SELECT 'IHME duplicate row not equal to the kept row (F2)', count(*)
  FROM public_health.silver.diseases_metric_silver__classified WHERE row_issue = 'ihme_duplicate_not_equal'
UNION ALL
SELECT 'IHME scope outside the verified constants: Number, All ages, Both, All Population, deaths or prevalence', count(*)
  FROM public_health.silver.diseases_metric_silver__classified WHERE row_issue = 'ihme_scope_outside_verified_constants'
UNION ALL
SELECT 'IHME: more than one as-of date across files', count(DISTINCT _as_of_date) - 1
  FROM public_health.silver.diseases_metric_silver__classified WHERE _source_key = 'ihme_gbd'
UNION ALL
SELECT 'FHSIS TB override does not match its row any more: file revised? (F7)', count(*)
  FROM public_health.silver.diseases_area_map m
  WHERE m._source_key = 'doh_fhsis' AND m.match_type = 'row_override'
    AND EXISTS (SELECT 1 FROM public_health.silver.diseases_metric_silver__classified r
                WHERE r._source_key = 'doh_fhsis' AND r._source_file = m.override_source_file)
    AND NOT EXISTS (SELECT 1 FROM public_health.silver.diseases_metric_silver__classified r
                    WHERE r._source_key = 'doh_fhsis' AND r._source_file = m.override_source_file AND r.override_applied
                      AND r._source_row_num = try_cast(m.override_source_row_num AS INT))
UNION ALL
SELECT 'FHSIS TB override bound to a different file checksum (F7)', count(*)
  FROM public_health.silver.diseases_area_map m
  JOIN public_health.silver.diseases_metric_silver__inputs i
    ON i.source_key = m._source_key AND i.source_file = m.override_source_file
   AND i.source_sheet <=> m.override_source_sheet
  WHERE m._source_key = 'doh_fhsis' AND m.match_type = 'row_override'
    AND m.override_content_checksum IS NOT NULL AND NOT (m.override_content_checksum <=> i.content_checksum)
UNION ALL
SELECT 'cell that is neither a number nor a documented marker', count(*)
  FROM public_health.silver.diseases_metric_silver__candidate WHERE value_status = 'parse_error'
UNION ALL
SELECT 'null value with status ok, or a value with another status', count(*)
  FROM public_health.silver.diseases_metric_silver__candidate WHERE (value IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'data row whose cause is not in the cause map', count(*) FROM public_health.silver.diseases_metric_silver__candidate WHERE disease_key IS NULL
UNION ALL
SELECT 'disease_key not in the directory', count(*) FROM (
  SELECT DISTINCT disease_key FROM public_health.silver.diseases_metric_silver__candidate WHERE disease_key IS NOT NULL) c
  LEFT ANTI JOIN public_health.silver.diseases_directory_silver d ON d.disease_key = c.disease_key
UNION ALL
SELECT 'data row whose area is not in the area map', count(*) FROM public_health.silver.diseases_metric_silver__candidate WHERE area_key IS NULL
UNION ALL
SELECT 'period that does not parse (year, month 1-12, week 1-53)', count(*)
  FROM public_health.silver.diseases_metric_silver__candidate
  WHERE year IS NULL OR period_key IS NULL
     OR (period_grain = 'month' AND (month IS NULL OR month NOT BETWEEN 1 AND 12))
     OR (period_grain = 'week' AND (week IS NULL OR week NOT BETWEEN 1 AND dz_iso_weeks_in_year(year)))
UNION ALL
-- D-44 / D-46: every weekly row spans 7 days and carries the ISO week and ISO year of its last day.
-- UP NOAH weeks run Monday to Sunday; an HDX week ends on its own date.
SELECT 'weekly row not a consistent ISO week (D-44, D-46)', count(*)
  FROM public_health.silver.diseases_metric_silver__candidate
  WHERE period_grain = 'week'
    AND (period_basis NOT IN ('iso_week', 'iso_week_ending_date')
         OR period_start IS NULL OR period_end IS NULL
         OR period_end <> date_add(period_start, 6)
         OR (period_basis = 'iso_week' AND weekday(period_start) <> 0)
         OR weekofyear(period_end) <> week
         OR extract(YEAROFWEEK FROM period_end) <> year
         -- try_cast: Spark does not short-circuit AND / OR, so with ANSI mode on, to_date() would
         -- also run on UP NOAH keys ('2016-W01') and fail. A malformed HDX key still counts (<=>).
         OR (period_basis = 'iso_week_ending_date' AND NOT (period_end <=> try_cast(period_key AS DATE))))
UNION ALL
SELECT 'negative value', count(*) FROM public_health.silver.diseases_metric_silver__candidate WHERE value < 0
UNION ALL
SELECT 'key column is null', count(*)
  FROM public_health.silver.diseases_metric_silver__candidate
  WHERE disease_key IS NULL OR area_key IS NULL OR period_grain IS NULL OR period_key IS NULL
     OR measure IS NULL OR _source_key IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_metric_silver__candidate
  GROUP BY disease_key, area_key, period_grain, period_key, measure, _source_key HAVING count(*) > 1)
UNION ALL
-- output validation, per source
SELECT concat(c.source_key, ': classified rows <> bronze rows read'), abs(c.bronze_rows - coalesce(i.input_rows, 0))
  FROM (SELECT _source_key AS source_key, count(*) AS bronze_rows FROM public_health.silver.diseases_metric_silver__classified GROUP BY _source_key) c
  LEFT JOIN (SELECT source_key, sum(input_rows) AS input_rows FROM public_health.silver.diseases_metric_silver__inputs
             WHERE input_kind = 'bronze_source' GROUP BY source_key) i ON i.source_key = c.source_key
UNION ALL
SELECT concat(c.source_key, ': silver rows <> data rows x measures per row'), abs(c.expected_rows - coalesce(s.silver_rows, 0))
  FROM (SELECT _source_key AS source_key, sum(CASE WHEN row_class = 'data' THEN measures_per_row ELSE 0 END) AS expected_rows
        FROM public_health.silver.diseases_metric_silver__classified GROUP BY _source_key) c
  LEFT JOIN (SELECT _source_key AS source_key, count(*) AS silver_rows FROM public_health.silver.diseases_metric_silver__candidate GROUP BY _source_key) s
    ON s.source_key = c.source_key
UNION ALL
SELECT concat(c.source_key, ': bronze rows referenced by silver lineage <> data rows'), abs(c.data_rows - coalesce(s.referenced, 0))
  FROM (SELECT _source_key AS source_key, count_if(row_class = 'data') AS data_rows FROM public_health.silver.diseases_metric_silver__classified GROUP BY _source_key) c
  LEFT JOIN (SELECT _source_key AS source_key, count(*) AS referenced
             FROM (SELECT DISTINCT _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.silver.diseases_metric_silver__candidate)
             GROUP BY _source_key) s ON s.source_key = c.source_key;


-- =============================================================================
-- [7] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW metric_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'diseases'                                     AS domain,
       'public_health.silver.diseases_metric_silver'  AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.diseases_metric_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [10]
       code_version                                   AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.diseases_metric_silver__inputs
                             WHERE input_kind = 'bronze_source' AND metadata_matches = 0)))
                                                      AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.diseases_metric_silver__gates) g;


-- =============================================================================
-- [8] stop here if a gate failed. The failed build is logged first; the published table stays
--     as it was. The staging tables are kept so you can see what failed:
--       SELECT * FROM public_health.silver.diseases_metric_silver__gates WHERE failures <> 0
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM metric_build_log WHERE status = 'failed';

SELECT raise_error(concat('diseases_metric_silver was NOT published. ', error_message))
FROM metric_build_log WHERE status = 'failed';


-- =============================================================================
-- [9] write the table (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_metric_silver AS
SELECT * FROM public_health.silver.diseases_metric_silver__candidate;


-- =============================================================================
-- [10] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.diseases_metric_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_metric_silver)),
       code_version, parameters, run_id, error_message
FROM metric_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.diseases_metric_silver__inputs;

-- Exceptions only: one row for every bronze row that was NOT loaded (dropped, duplicate, quarantined).
-- Loaded rows are not stored: the silver rows already carry their bronze row reference, and
-- rows loaded per file = build_inputs.input_rows minus these rows (view quality.v_build_reconciliation).
-- For a duplicate, target_key names the row that was kept.
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.diseases_metric_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       CASE c.row_class WHEN 'data' THEN 'loaded' WHEN 'non_data' THEN 'dropped_non_data'
                        WHEN 'duplicate' THEN 'duplicate_of' WHEN 'quarantined' THEN 'quarantined' END,
       c.reason,
       CASE WHEN c.row_class = 'duplicate' THEN to_json(named_struct(
              '_source_key', c._source_key, '_source_file', c.kept_file, '_source_sheet', c.kept_sheet,
              '_source_row_num', c.kept_row, '_content_checksum', k.content_checksum)) END,
       current_timestamp()
FROM public_health.silver.diseases_metric_silver__classified c
LEFT JOIN public_health.silver.diseases_metric_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
LEFT JOIN public_health.silver.diseases_metric_silver__inputs k
  ON k.input_kind = 'bronze_source' AND k.source_key = c._source_key AND k.source_file = c.kept_file
 AND k.source_sheet <=> c.kept_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [11] summary (compare with section 3.6 of the plan), then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW metric_summary AS
SELECT c.source_key, c.bronze_rows, c.data_rows, c.non_data, c.duplicates, c.quarantined, s.silver_rows
FROM (SELECT _source_key AS source_key, count(*) AS bronze_rows,
             count_if(row_class = 'data') AS data_rows, count_if(row_class = 'non_data') AS non_data,
             count_if(row_class = 'duplicate') AS duplicates, count_if(row_class = 'quarantined') AS quarantined
      FROM public_health.silver.diseases_metric_silver__classified GROUP BY _source_key) c
LEFT JOIN (SELECT _source_key AS source_key, count(*) AS silver_rows
           FROM public_health.silver.diseases_metric_silver GROUP BY _source_key) s ON s.source_key = c.source_key;

DROP TABLE IF EXISTS public_health.silver.diseases_metric_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.diseases_metric_silver__gates;
DROP TABLE IF EXISTS public_health.silver.diseases_metric_silver__inputs;
-- public_health.silver.diseases_metric_silver__classified is kept until the next run:
-- it shows how every bronze row was classified.

SELECT * FROM metric_summary ORDER BY source_key;