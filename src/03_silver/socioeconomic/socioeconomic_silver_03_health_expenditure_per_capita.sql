-- =============================================================================
-- Builds public_health.silver.socioeconomic_health_expenditure_per_capita_silver:
--   per capita health expenditure of the Philippines in one year, with its growth rate.
--   Key: year
-- Source: PSA Philippine Statistical Yearbook Table 9.24 (Philippine National Health Accounts),
--   national, 2016 to 2023. Two bronze rows (the amount row and the growth-rate row) become
--   8 rows, one per year.
--
-- Same build sequence, staging tables, gates and logging as socioeconomic_silver_01_poverty.sql.
-- Needs: quality_setup.sql has been run.
--
-- Rows are found by STRUCTURE, never by whether a value is a number:
--   amount row      : indicator = 'Per Capita Health Expenditure'
--   growth header   : no indicator, first value cell = 'Growth Rate'
--   period header   : the row after the growth header (2015-16, 2016-17, ...)
--   growth row      : the row after the period header
--   notes, source   : from the 'Notes:' line to the 'Source:' line
--
-- Lineage on the silver row (7 columns): _silver_build_id, _source_key, _source_file, _as_of_date,
--   _amount_source_row_num, _growth_source_row_num, _metric_source_columns
--   ({per_capita_health_expenditure_php: 'value_2023', growth_rate_pct: 'value_2023'}).
--   The source is a CSV, so there is no sheet column.
--
-- Rule 2a (2026-10-19)
--   - per_capita_years (2016 to 2023) is a setting, used by the year gate and recorded in
--     build_log.parameters (socioeconomic_silver_qc.py S08 / S88 read it). The unpivot in [3]
--     names the bronze columns (value_2016, ...); a new gate stops the build when bronze holds a
--     year column the setting does not list, or the reverse. Before, a value_2024 column would
--     have been left out without any gate failing (the year gate counted only the stacked years).
-- =============================================================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
-- true : every input needs exactly one processed ingestion_metadata row (contract 3.5).
-- false: a missing row is allowed, and that input gets a null load id and checksum.
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job
-- Years of the file loaded (psa_health_expenditure_per_capita_national_annual_2016_2023.csv).
DECLARE OR REPLACE VARIABLE per_capita_years ARRAY<INT> DEFAULT sequence(2016, 2023);

-- Label normalisation: repeated spaces become one space, then upper case.
CREATE OR REPLACE TEMPORARY FUNCTION se_label(s STRING) RETURNS STRING
RETURN upper(trim(regexp_replace(s, '\\s+', ' ')));


-- =============================================================================
-- [1] classify every bronze row by its position and label
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified AS
WITH tagged AS (
  SELECT b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._ingested_at,
         CASE WHEN se_label(b.indicator) = 'PER CAPITA HEALTH EXPENDITURE'               THEN 'amount'
              WHEN b.indicator IS NULL AND se_label(b.value_2016) = 'GROWTH RATE'        THEN 'growth_header'
              WHEN se_label(b.indicator) LIKE 'NOTES:%'                                  THEN 'notes_start'
              WHEN se_label(b.indicator) LIKE 'SOURCE:%'                                 THEN 'source_line'
         END AS tag,
         b.indicator
  FROM public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze b
  WHERE b._source_key = 'psa_health_expenditure_per_capita_national_annual'
),
placed AS (
  SELECT t.*,
         lag(t.tag, 1) OVER (PARTITION BY t._source_file ORDER BY t._source_row_num) AS tag_1_above,
         lag(t.tag, 2) OVER (PARTITION BY t._source_file ORDER BY t._source_row_num) AS tag_2_above,
         min(CASE WHEN t.tag = 'notes_start' THEN t._source_row_num END) OVER (PARTITION BY t._source_file) AS notes_row,
         min(CASE WHEN t.tag = 'source_line' THEN t._source_row_num END) OVER (PARTITION BY t._source_file) AS source_row
  FROM tagged t
),
classed AS (
  SELECT p.*,
         CASE WHEN p.tag = 'amount'        THEN 'amount'
              WHEN p.tag = 'growth_header' THEN 'growth_header'
              WHEN p.tag IS NULL AND p.indicator IS NULL AND p.tag_1_above = 'growth_header' THEN 'period_header'
              WHEN p.tag IS NULL AND p.indicator IS NULL AND p.tag_2_above = 'growth_header' THEN 'growth'
              WHEN p.tag = 'source_line'   THEN 'source_line'
              WHEN p.tag = 'notes_start'   THEN 'note'
              WHEN p.tag IS NULL AND p.indicator IS NOT NULL
                   AND p._source_row_num > p.notes_row
                   AND (p.source_row IS NULL OR p._source_row_num < p.source_row) THEN 'note'
         END AS row_role
  FROM placed p
)
SELECT 'public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze' AS input_table,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at,
       row_role,
       CASE WHEN row_role IN ('amount', 'growth') THEN 'data'
            WHEN row_role IS NOT NULL THEN 'non_data'
            ELSE 'unclassified' END AS row_class,
       CASE WHEN row_role IN ('amount', 'growth') THEN CAST(NULL AS STRING)
            WHEN row_role IN ('growth_header', 'period_header') THEN 'sub_header'
            WHEN row_role = 'note' THEN 'note'
            WHEN row_role = 'source_line' THEN 'source_line'
            ELSE 'row_not_recognised' END AS reason
FROM classed;


-- =============================================================================
-- [2] inputs (layout of quality.build_inputs)
-- =============================================================================
-- Delta version of the table read. If your runtime rejects DESCRIBE HISTORY in a subquery,
-- use the NULL version below instead (the build still works, versions are just not recorded).
CREATE OR REPLACE TEMP VIEW per_capita_table_versions AS
SELECT 'public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze)) AS table_version;
-- NULL version (use this instead if the view above fails):
-- CREATE OR REPLACE TEMP VIEW per_capita_table_versions AS
-- SELECT CAST(NULL AS STRING) AS table_name, CAST(NULL AS BIGINT) AS table_version WHERE 1 = 0

CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT silver_build_id      AS build_id,
       'public_health.silver.socioeconomic_health_expenditure_per_capita_silver' AS target_table,
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
LEFT JOIN per_capita_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows;


-- =============================================================================
-- [3] candidate rows: one per year, from the amount row, the growth row and the period header.
--     The bronze columns are named by year, so they are listed by name; the year column gate
--     keeps this list and per_capita_years in step.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate AS
WITH long AS (
  SELECT c.row_role, b._source_key, b._source_file, b._source_row_num, b._as_of_date,
         stack(8,
           2016, b.value_2016, 'value_2016',  2017, b.value_2017, 'value_2017',
           2018, b.value_2018, 'value_2018',  2019, b.value_2019, 'value_2019',
           2020, b.value_2020, 'value_2020',  2021, b.value_2021, 'value_2021',
           2022, b.value_2022, 'value_2022',  2023, b.value_2023, 'value_2023'
         ) AS (year, raw, src_col)
  FROM public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze b
  JOIN public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'psa_health_expenditure_per_capita_national_annual'
    AND c.row_role IN ('amount', 'growth', 'period_header')
),
wide AS (
  SELECT year,
         max(CASE WHEN row_role = 'amount'        THEN raw END) AS amount_raw,
         max(CASE WHEN row_role = 'growth'        THEN raw END) AS growth_raw,
         max(CASE WHEN row_role = 'period_header' THEN raw END) AS period_raw,
         max(CASE WHEN row_role = 'amount' THEN _source_row_num END) AS amount_row_num,
         max(CASE WHEN row_role = 'growth' THEN _source_row_num END) AS growth_row_num,
         max(CASE WHEN row_role = 'amount' THEN src_col END)         AS src_col,
         max(_source_key) AS _source_key, max(_source_file) AS _source_file, max(_as_of_date) AS _as_of_date
  FROM long
  GROUP BY year
)
SELECT year,
       try_cast(regexp_replace(trim(amount_raw), '[ ,]', '') AS DECIMAL(12,2)) AS per_capita_health_expenditure_php,
       try_cast(regexp_replace(trim(growth_raw), '[ ,%]', '') AS DECIMAL(6,1)) AS growth_rate_pct,
       -- the period the growth rate covers, as printed without the revision mark: 2015-16
       regexp_extract(trim(period_raw), '^([0-9]{4}-[0-9]{2})', 1)             AS growth_period,
       -- PSA marks revised figures with r in the period header (2020-21 r)
       (trim(period_raw) RLIKE '[0-9] *r$')                                    AS is_revised,
       CASE WHEN amount_raw IS NULL OR trim(amount_raw) = '' THEN 'missing'
            WHEN try_cast(regexp_replace(trim(amount_raw), '[ ,]', '') AS DECIMAL(12,2)) IS NOT NULL THEN 'ok'
            ELSE 'parse_error' END AS amount_status,
       CASE WHEN growth_raw IS NULL OR trim(growth_raw) = '' THEN 'missing'
            WHEN try_cast(regexp_replace(trim(growth_raw), '[ ,%]', '') AS DECIMAL(6,1)) IS NOT NULL THEN 'ok'
            ELSE 'parse_error' END AS growth_status,
       -- the growth rate under year Y must be the growth from Y-1 to Y
       (regexp_extract(trim(period_raw), '^([0-9]{4}-[0-9]{2})', 1)
          <=> concat(CAST(year - 1 AS STRING), '-', right(CAST(year AS STRING), 2))) AS period_matches_year,
       silver_build_id AS _silver_build_id,
       _source_key, _source_file, _as_of_date,
       amount_row_num  AS _amount_source_row_num,
       growth_row_num  AS _growth_source_row_num,
       map('per_capita_health_expenditure_php', src_col, 'growth_rate_pct', src_col) AS _metric_source_columns
FROM wide;


-- =============================================================================
-- [4] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver__gates AS
SELECT 'inputs: file with more than one load time' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs WHERE metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs WHERE metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'inputs: not exactly one file', abs(count(*) - 1)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs
UNION ALL
-- Years in the bronze column names (value_2016, ...) vs per_capita_years, from one row of the source.
SELECT 'bronze year columns differ from per_capita_years (update the setting and the unpivot in [3])',
       size(array_except(y.bronze_years, per_capita_years)) + size(array_except(per_capita_years, y.bronze_years))
FROM (SELECT array_distinct(collect_list(CAST(regexp_extract(k, '^value_([0-9]{4})$', 1) AS INT))) AS bronze_years
      FROM (SELECT explode(json_object_keys(to_json(struct(*), map('ignoreNullFields', 'false')))) AS k
            FROM (SELECT * FROM public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze
                  WHERE _source_key = 'psa_health_expenditure_per_capita_national_annual' LIMIT 1))
      WHERE k RLIKE '^value_[0-9]{4}$') y
UNION ALL
SELECT 'unclassified bronze rows', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified WHERE row_class NOT IN ('data', 'non_data')
UNION ALL
SELECT 'not exactly one amount row, growth header, period header and growth row', count(*) FROM (
  SELECT r.role
  FROM (SELECT explode(array('amount', 'growth_header', 'period_header', 'growth')) AS role) r
  LEFT JOIN public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified c ON c.row_role = r.role
  GROUP BY r.role HAVING count(c.row_role) <> 1)
UNION ALL
SELECT 'cell that is not a number', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate
  WHERE amount_status = 'parse_error' OR growth_status = 'parse_error'
UNION ALL
SELECT 'year without an amount or a growth rate', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate
  WHERE amount_status = 'missing' OR growth_status = 'missing'
UNION ALL
SELECT 'growth period under a year is not the growth into that year', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate WHERE NOT period_matches_year
UNION ALL
SELECT 'per capita amount is not positive', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate WHERE per_capita_health_expenditure_php <= 0
UNION ALL
SELECT 'years are not exactly per_capita_years, one row each',
       CASE WHEN count(*) = size(per_capita_years)
             AND sort_array(collect_set(year)) = sort_array(per_capita_years) THEN 0 ELSE 1 END
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate
UNION ALL
SELECT 'lineage column is null', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _as_of_date IS NULL
     OR _amount_source_row_num IS NULL OR _growth_source_row_num IS NULL OR _metric_source_columns IS NULL
UNION ALL
SELECT 'classified rows <> bronze rows read',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified)
         - (SELECT coalesce(sum(input_rows), 0) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs))
UNION ALL
SELECT 'reconciliation: bronze rows referenced by silver <> rows read - rows not loaded (data rows)',
       abs((SELECT count(DISTINCT _amount_source_row_num) + count(DISTINCT _growth_source_row_num)
            FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate)
         - (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified WHERE row_class = 'data'));


-- =============================================================================
-- [5] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW per_capita_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'socioeconomic'                                AS domain,
       'public_health.silver.socioeconomic_health_expenditure_per_capita_silver' AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [8]
       code_version                                   AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'per_capita_years', per_capita_years,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs WHERE metadata_matches = 0))) AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__gates) g;


-- =============================================================================
-- [6] stop here if a gate failed. The failed build is logged first, and the published table
--     stays as it was. The staging tables are kept so you can see what failed.
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM per_capita_build_log WHERE status = 'failed';

SELECT raise_error(concat('socioeconomic_health_expenditure_per_capita_silver was NOT published. ', error_message))
FROM per_capita_build_log WHERE status = 'failed';


-- =============================================================================
-- [7] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver AS
SELECT * EXCEPT (amount_status, growth_status, period_matches_year)
FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate;

COMMENT ON TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver IS
  'Per capita health expenditure of the Philippines and its annual growth rate, 2016 to 2023 (PSA Yearbook Table 9.24). One row per year. The population basis changes: 2015-based projections up to 2019, the 2020 census count in 2020, 2020-based projections from 2021, so growth across 2019 to 2021 is not like for like.';
ALTER TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver ALTER COLUMN per_capita_health_expenditure_php COMMENT 'Pesos per person, at current prices';
ALTER TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver ALTER COLUMN growth_rate_pct COMMENT 'Percent growth INTO this year (growth_period says from which year). Can be negative';
ALTER TABLE public_health.silver.socioeconomic_health_expenditure_per_capita_silver ALTER COLUMN is_revised COMMENT 'true where PSA marks the figure as revised (r)';


-- =============================================================================
-- [8] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.socioeconomic_health_expenditure_per_capita_silver)),
       code_version, parameters, run_id, error_message
FROM per_capita_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs;

-- Bronze rows NOT loaded (lineage-qc-contract.md v1.3, section 7.1). Loaded rows are not written:
-- the silver rows carry their bronze row reference, and rows loaded per input = input_rows minus
-- the rows here (quality.v_build_reconciliation). Here only non-data rows are not loaded
-- (an unclassified row fails a gate, so it never reaches this step).
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.socioeconomic_health_expenditure_per_capita_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       'dropped_non_data',
       c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified c
LEFT JOIN public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs i
  ON i.source_key = c._source_key AND i.source_file = c._source_file AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [9] summary, then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW per_capita_summary AS
SELECT (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified) AS bronze_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified WHERE row_class = 'data') AS data_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver) AS silver_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver WHERE is_revised) AS revised_years,
       -- control values to read against the PSA table: the expected numbers are the
       -- qc.control_values of this source in sources_socioeconomic.yaml (S84 checks them)
       (SELECT max(per_capita_health_expenditure_php) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver WHERE year = 2023) AS amount_2023_php,
       (SELECT max(per_capita_health_expenditure_php) FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver WHERE year = 2016) AS amount_2016_php;

SELECT * FROM per_capita_summary;

DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_per_capita_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_per_capita_silver__gates;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_per_capita_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_per_capita_silver__classified;