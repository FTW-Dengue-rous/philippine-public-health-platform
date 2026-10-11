-- =============================================================================
-- Builds public_health.silver.socioeconomic_child_mortality_silver:
--   early childhood mortality rates of one background characteristic in one survey.
--   Key: (characteristic_group, characteristic, survey_year)
-- Source: PSA Philippine Statistical Yearbook Table 9.9 (National Demographic and Health Survey
--   2017 and 2022). Each bronze row becomes 2 rows, one per survey.
--
-- Same build sequence, staging tables, gates and logging as socioeconomic_silver_01_poverty.sql.
-- Needs: quality_setup.sql has been run.
--
-- The 30 characteristics are an approved list written in this file (view mortality_characteristic_map).
--
-- Units differ by measure:
--   infant_mortality_rate   deaths before the first birthday, per 1,000 live births
--   child_mortality_rate    deaths between the first and fifth birthday, per 1,000 children
--                           surviving to their first birthday
--   under5_mortality_rate   deaths before the fifth birthday, per 1,000 live births
-- survey_year is the survey, not the year the deaths occurred. The window before the survey that
-- the rates cover is NOT confirmed (reference_period is null until it is).
-- Regions are the 17 regions of the old definition (no Negros Island Region).
--
-- Lineage on the silver row (7 columns): _silver_build_id, _source_key, _source_file,
--   _source_sheet (null, the source is a CSV), _source_row_num, _as_of_date,
--   _metric_source_columns ({infant_mortality_rate: 'imr_2022', ...})
-- =============================================================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
-- true : every input needs exactly one processed ingestion_metadata row (contract 3.5).
-- false: a missing row is allowed, and that input gets a null load id and checksum.
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job

-- Label normalisation: apostrophes removed (straight \x27 and curly \u2019), repeated spaces become
-- one space, then upper case. So the header "Mother's Education" has the key MOTHERS EDUCATION.
-- No string in this file contains an apostrophe: a doubled quote inside a SQL string is not read
-- the same way on every runtime (that stopped the first Databricks run of this file).
CREATE OR REPLACE TEMPORARY FUNCTION se_label(s STRING) RETURNS STRING
RETURN upper(trim(regexp_replace(regexp_replace(s, '[\\x27\\u2019]', ''), '\\s+', ' ')));

-- A rate as printed: 26, (26) or *. Returns the number, null for * and for anything else.
CREATE OR REPLACE TEMPORARY FUNCTION se_rate(s STRING) RETURNS INT
RETURN try_cast(regexp_extract(trim(s), '^[(]?([0-9]+)[)]?$', 1) AS INT);

-- Reliability of a rate. (26) = based on 250 to 499 children. * = fewer than 250, suppressed.
CREATE OR REPLACE TEMPORARY FUNCTION se_rate_reliability(s STRING) RETURNS STRING
RETURN CASE WHEN s IS NULL OR trim(s) = ''          THEN 'missing'
            WHEN trim(s) = '*'                       THEN 'suppressed'
            WHEN trim(s) RLIKE '^[(][0-9]+[)]$'      THEN 'low_precision'
            WHEN trim(s) RLIKE '^[0-9]+$'            THEN 'ok'
            ELSE 'parse_error' END;

-- Approved list of characteristics. group_key and label_norm are the group header and the label
-- as printed, normalised by se_label. The group name shown in silver comes from the file header.
CREATE OR REPLACE TEMP VIEW mortality_characteristic_map AS
SELECT * FROM VALUES
  ( 1, 'REGION', 'NCR', 'NCR'),
  ( 2, 'REGION', 'CAR', 'CAR'),
  ( 3, 'REGION', 'I - ILOCOS REGION', 'I - Ilocos Region'),
  ( 4, 'REGION', 'II - CAGAYAN VALLEY', 'II - Cagayan Valley'),
  ( 5, 'REGION', 'III - CENTRAL LUZON', 'III - Central Luzon'),
  ( 6, 'REGION', 'IV-A CALABARZON', 'IV-A CALABARZON'),
  ( 7, 'REGION', 'MIMAROPA', 'MIMAROPA'),
  ( 8, 'REGION', 'V - BICOL REGION', 'V - Bicol Region'),
  ( 9, 'REGION', 'VI - WESTERN VISAYAS', 'VI - Western Visayas'),
  (10, 'REGION', 'VII - CENTRAL VISAYAS', 'VII - Central Visayas'),
  (11, 'REGION', 'VIII - EASTERN VISAYAS', 'VIII - Eastern Visayas'),
  (12, 'REGION', 'IX - ZAMBOANGA PENINSULA', 'IX - Zamboanga Peninsula'),
  (13, 'REGION', 'X - NORTHERN MINDANAO', 'X - Northern Mindanao'),
  (14, 'REGION', 'XI - DAVAO REGION', 'XI - Davao Region'),
  (15, 'REGION', 'XII - SOCCSKSARGEN', 'XII - SOCCSKSARGEN'),
  (16, 'REGION', 'XIII - CARAGA', 'XIII - Caraga'),
  (17, 'REGION', 'BARMM', 'BARMM'),
  (18, 'RESIDENCE', 'URBAN', 'Urban'),
  (19, 'RESIDENCE', 'RURAL', 'Rural'),
  (20, 'MOTHERS EDUCATION', 'NO EDUCATION', 'No Education'),
  (21, 'MOTHERS EDUCATION', 'GRADES 1-6', 'Grades 1-6'),
  (22, 'MOTHERS EDUCATION', 'GRADES 7-10', 'Grades 7-10'),
  (23, 'MOTHERS EDUCATION', 'GRADE 11-12', 'Grade 11-12'),
  (24, 'MOTHERS EDUCATION', 'POST-SECONDARY', 'Post-secondary'),
  (25, 'MOTHERS EDUCATION', 'COLLEGE', 'College'),
  (26, 'WEALTH QUINTILE', 'LOWEST', 'Lowest'),
  (27, 'WEALTH QUINTILE', 'SECOND', 'Second'),
  (28, 'WEALTH QUINTILE', 'MIDDLE', 'Middle'),
  (29, 'WEALTH QUINTILE', 'FOURTH', 'Fourth'),
  (30, 'WEALTH QUINTILE', 'HIGHEST', 'Highest')
  AS t(characteristic_order, group_key, label_norm, characteristic);


-- =============================================================================
-- [1] classify every bronze row. The group of a data row is the last group header above it.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_child_mortality_silver__classified AS
WITH tagged AS (
  SELECT b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._ingested_at,
         b.characteristic_group AS group_cell, b.characteristic AS characteristic_cell,
         CASE WHEN b.characteristic IS NULL
               AND se_label(b.characteristic_group) IN ('REGION', 'RESIDENCE', 'MOTHERS EDUCATION', 'WEALTH QUINTILE')
              THEN trim(b.characteristic_group) END AS header_group
  FROM public_health.bronze.socioeconomic_psa_child_mortality_bronze b
  WHERE b._source_key = 'psa_child_mortality'
),
carried AS (
  SELECT t.*,
         last_value(t.header_group, true) OVER (PARTITION BY t._source_file ORDER BY t._source_row_num
                                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS group_above
  FROM tagged t
)
SELECT 'public_health.bronze.socioeconomic_psa_child_mortality_bronze' AS input_table,
       c._source_key, c._source_file, c._source_sheet, c._source_row_num, c._ingested_at,
       m.characteristic_order,
       c.group_above AS characteristic_group,          -- the group header above the row, as printed
       CASE WHEN c.header_group IS NOT NULL THEN 'non_data'
            WHEN c.characteristic_cell IS NOT NULL AND c.group_cell IS NULL AND m.characteristic_order IS NOT NULL THEN 'data'
            WHEN c.characteristic_cell IS NULL AND se_label(c.group_cell) LIKE 'NOTE:%' THEN 'non_data'
            WHEN c.characteristic_cell IS NULL AND se_label(c.group_cell) RLIKE '^[0-9] THE PROBABILITY' THEN 'non_data'
            WHEN c.characteristic_cell IS NULL AND se_label(c.group_cell) LIKE 'SOURCE:%' THEN 'non_data'
            ELSE 'unclassified' END AS row_class,
       CASE WHEN c.header_group IS NOT NULL THEN 'group_header'
            WHEN c.characteristic_cell IS NOT NULL AND c.group_cell IS NULL AND m.characteristic_order IS NOT NULL THEN CAST(NULL AS STRING)
            WHEN c.characteristic_cell IS NULL AND se_label(c.group_cell) LIKE 'NOTE:%' THEN 'note'
            WHEN c.characteristic_cell IS NULL AND se_label(c.group_cell) RLIKE '^[0-9] THE PROBABILITY' THEN 'note'
            WHEN c.characteristic_cell IS NULL AND se_label(c.group_cell) LIKE 'SOURCE:%' THEN 'source_line'
            ELSE 'characteristic_not_in_list' END AS reason
FROM carried c
LEFT JOIN mortality_characteristic_map m
  ON m.group_key = se_label(c.group_above)
 AND m.label_norm = se_label(c.characteristic_cell);


-- =============================================================================
-- [2] inputs (layout of quality.build_inputs)
-- =============================================================================
-- Delta version of the table read. If your runtime rejects DESCRIBE HISTORY in a subquery,
-- use the NULL version below instead (the build still works, versions are just not recorded).
CREATE OR REPLACE TEMP VIEW mortality_table_versions AS
SELECT 'public_health.bronze.socioeconomic_psa_child_mortality_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.socioeconomic_psa_child_mortality_bronze)) AS table_version;
-- NULL version (use this instead if the view above fails):
-- CREATE OR REPLACE TEMP VIEW mortality_table_versions AS
-- SELECT CAST(NULL AS STRING) AS table_name, CAST(NULL AS BIGINT) AS table_version WHERE 1 = 0

CREATE OR REPLACE TABLE public_health.silver.socioeconomic_child_mortality_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.socioeconomic_child_mortality_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT silver_build_id      AS build_id,
       'public_health.silver.socioeconomic_child_mortality_silver' AS target_table,
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
LEFT JOIN mortality_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows;


-- =============================================================================
-- [3] candidate rows: survey years to rows. Bronze columns are named by year, and in the
--     file 2022 comes BEFORE 2017, so nothing here relies on column position.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_child_mortality_silver__candidate AS
WITH u AS (
  SELECT c.characteristic_group, a.characteristic, a.characteristic_order,
         b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date,
         stack(2,
           2022, b.imr_2022, b.cmr_2022, b.u5mr_2022, 'imr_2022', 'cmr_2022', 'u5mr_2022',
           2017, b.imr_2017, b.cmr_2017, b.u5mr_2017, 'imr_2017', 'cmr_2017', 'u5mr_2017'
         ) AS (survey_year, imr_raw, cmr_raw, u5mr_raw, imr_col, cmr_col, u5mr_col)
  FROM public_health.bronze.socioeconomic_psa_child_mortality_bronze b
  JOIN public_health.silver.socioeconomic_child_mortality_silver__classified c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  JOIN mortality_characteristic_map a ON a.characteristic_order = c.characteristic_order
  WHERE b._source_key = 'psa_child_mortality' AND c.row_class = 'data'
)
SELECT characteristic_group, characteristic, characteristic_order,
       survey_year,
       CAST(NULL AS STRING)          AS reference_period,            -- not confirmed, see the guide (D7)
       se_rate(imr_raw)              AS infant_mortality_rate,
       se_rate(cmr_raw)              AS child_mortality_rate,
       se_rate(u5mr_raw)             AS under5_mortality_rate,
       se_rate_reliability(imr_raw)  AS infant_mortality_reliability,
       se_rate_reliability(cmr_raw)  AS child_mortality_reliability,
       se_rate_reliability(u5mr_raw) AS under5_mortality_reliability,
       silver_build_id               AS _silver_build_id,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('infant_mortality_rate', imr_col, 'child_mortality_rate', cmr_col,
           'under5_mortality_rate', u5mr_col) AS _metric_source_columns
FROM u;


-- =============================================================================
-- [4] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_child_mortality_silver__gates AS
SELECT 'inputs: file with more than one load time' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_child_mortality_silver__inputs
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__inputs WHERE metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__inputs WHERE metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'inputs: not exactly one file', abs(count(*) - 1)
  FROM public_health.silver.socioeconomic_child_mortality_silver__inputs
UNION ALL
SELECT 'unclassified bronze rows', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__classified WHERE row_class NOT IN ('data', 'non_data')
UNION ALL
SELECT 'characteristic of the approved list missing from the file, or listed twice', count(*) FROM (
  SELECT a.characteristic_order
  FROM mortality_characteristic_map a
  LEFT JOIN public_health.silver.socioeconomic_child_mortality_silver__classified c
    ON c.characteristic_order = a.characteristic_order AND c.row_class = 'data'
  GROUP BY a.characteristic_order HAVING count(c.characteristic_order) <> 1)
UNION ALL
SELECT 'not exactly four group header rows',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__classified WHERE reason = 'group_header') - 4)
UNION ALL
SELECT 'cell that is neither a rate nor a documented marker', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__candidate
  WHERE 'parse_error' IN (infant_mortality_reliability, child_mortality_reliability, under5_mortality_reliability)
UNION ALL
SELECT 'characteristic-year with an empty rate cell', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__candidate
  WHERE 'missing' IN (infant_mortality_reliability, child_mortality_reliability, under5_mortality_reliability)
UNION ALL
SELECT 'rate is null but not suppressed, or suppressed but not null', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__candidate
  WHERE (infant_mortality_rate IS NULL) <> (infant_mortality_reliability = 'suppressed')
     OR (child_mortality_rate  IS NULL) <> (child_mortality_reliability  = 'suppressed')
     OR (under5_mortality_rate IS NULL) <> (under5_mortality_reliability = 'suppressed')
UNION ALL
SELECT 'negative rate', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__candidate
  WHERE infant_mortality_rate < 0 OR child_mortality_rate < 0 OR under5_mortality_rate < 0
UNION ALL
SELECT 'key column is null', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__candidate
  WHERE characteristic_group IS NULL OR characteristic IS NULL OR survey_year IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_child_mortality_silver__candidate
  GROUP BY characteristic_group, characteristic, survey_year HAVING count(*) > 1)
UNION ALL
SELECT 'lineage column is null', count(*)
  FROM public_health.silver.socioeconomic_child_mortality_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _source_row_num IS NULL
     OR _as_of_date IS NULL OR _metric_source_columns IS NULL
UNION ALL
SELECT 'classified rows <> bronze rows read',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__classified)
         - (SELECT coalesce(sum(input_rows), 0) FROM public_health.silver.socioeconomic_child_mortality_silver__inputs))
UNION ALL
SELECT 'silver rows <> 30 characteristics x 2 surveys',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__candidate) - 60)
UNION ALL
SELECT 'reconciliation: bronze rows referenced by silver <> rows read - rows not loaded (data rows)',
       abs((SELECT count(DISTINCT _source_row_num) FROM public_health.silver.socioeconomic_child_mortality_silver__candidate)
         - (SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__classified WHERE row_class = 'data'));


-- =============================================================================
-- [5] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW mortality_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'socioeconomic'                                AS domain,
       'public_health.silver.socioeconomic_child_mortality_silver' AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [8]
       code_version                                   AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__inputs WHERE metadata_matches = 0))) AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.socioeconomic_child_mortality_silver__gates) g;


-- =============================================================================
-- [6] stop here if a gate failed. The failed build is logged first, and the published table
--     stays as it was. The staging tables are kept so you can see what failed.
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM mortality_build_log WHERE status = 'failed';

SELECT raise_error(concat('socioeconomic_child_mortality_silver was NOT published. ', error_message))
FROM mortality_build_log WHERE status = 'failed';


-- =============================================================================
-- [7] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_child_mortality_silver AS
SELECT * FROM public_health.silver.socioeconomic_child_mortality_silver__candidate;

COMMENT ON TABLE public_health.silver.socioeconomic_child_mortality_silver IS
  'Early childhood mortality rates by region, residence, education of the mother and wealth quintile, from the 2017 and 2022 National Demographic and Health Surveys (PSA Yearbook Table 9.9). One row per characteristic and survey. survey_year is the survey, not the year of death. Regions are the 17 regions of the old definition (no Negros Island Region): regional context only, do not join to current-region data.';
ALTER TABLE public_health.silver.socioeconomic_child_mortality_silver ALTER COLUMN infant_mortality_rate COMMENT 'Deaths before the first birthday, per 1,000 live births';
ALTER TABLE public_health.silver.socioeconomic_child_mortality_silver ALTER COLUMN child_mortality_rate COMMENT 'Deaths between the first and fifth birthday, per 1,000 children surviving to their first birthday';
ALTER TABLE public_health.silver.socioeconomic_child_mortality_silver ALTER COLUMN under5_mortality_rate COMMENT 'Deaths before the fifth birthday, per 1,000 live births';
ALTER TABLE public_health.silver.socioeconomic_child_mortality_silver ALTER COLUMN infant_mortality_reliability COMMENT 'ok | low_precision (printed in parentheses: based on 250 to 499 children) | suppressed (printed as *: fewer than 250 children, rate is null)';
ALTER TABLE public_health.silver.socioeconomic_child_mortality_silver ALTER COLUMN reference_period COMMENT 'Window before the survey that the rates cover. Null: not confirmed yet';


-- =============================================================================
-- [8] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.socioeconomic_child_mortality_silver)),
       code_version, parameters, run_id, error_message
FROM mortality_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.socioeconomic_child_mortality_silver__inputs;

-- Bronze rows NOT loaded (lineage-qc-contract.md v1.3, section 7.1). Loaded rows are not written:
-- the silver rows carry their bronze row reference, and rows loaded per input = input_rows minus
-- the rows here (quality.v_build_reconciliation). Here only non-data rows are not loaded
-- (an unclassified row fails a gate, so it never reaches this step).
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.socioeconomic_child_mortality_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       'dropped_non_data',
       c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.socioeconomic_child_mortality_silver__classified c
LEFT JOIN public_health.silver.socioeconomic_child_mortality_silver__inputs i
  ON i.source_key = c._source_key AND i.source_file = c._source_file AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [9] summary, then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW mortality_summary AS
SELECT (SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__classified) AS bronze_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver__classified WHERE row_class = 'data') AS data_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_child_mortality_silver) AS silver_rows,
       (SELECT count_if(infant_mortality_reliability = 'suppressed') + count_if(child_mortality_reliability = 'suppressed')
             + count_if(under5_mortality_reliability = 'suppressed') FROM public_health.silver.socioeconomic_child_mortality_silver) AS suppressed_rates,
       (SELECT count_if(infant_mortality_reliability = 'low_precision') + count_if(child_mortality_reliability = 'low_precision')
             + count_if(under5_mortality_reliability = 'low_precision') FROM public_health.silver.socioeconomic_child_mortality_silver) AS low_precision_rates,
       -- control values to read against the PSA table (expected 8 and 55)
       (SELECT max(infant_mortality_rate) FROM public_health.silver.socioeconomic_child_mortality_silver WHERE characteristic = 'NCR' AND survey_year = 2022) AS ncr_infant_2022,
       (SELECT max(under5_mortality_rate) FROM public_health.silver.socioeconomic_child_mortality_silver WHERE characteristic = 'BARMM' AND survey_year = 2017) AS barmm_under5_2017;

SELECT * FROM mortality_summary;

DROP TABLE IF EXISTS public_health.silver.socioeconomic_child_mortality_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_child_mortality_silver__gates;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_child_mortality_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_child_mortality_silver__classified;