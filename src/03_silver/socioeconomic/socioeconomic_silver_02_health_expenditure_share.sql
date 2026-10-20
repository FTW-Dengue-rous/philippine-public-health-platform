-- =============================================================================
-- Builds public_health.silver.socioeconomic_health_expenditure_share_silver:
--   percent share of current health expenditure of one financing agent in one year.
--   Key: (financing_agent, year)
-- Source: PSA Philippine Statistical Yearbook Table 9.26 (Philippine National Health Accounts),
--   national, 2016 to 2023. Each bronze row becomes 8 rows, one per year.
--
-- Same build sequence, staging tables, gates and logging as socioeconomic_silver_01_poverty.sql.
-- Needs: quality_setup.sql has been run.
--
-- The 16 financing agents and their hierarchy are an approved list written in this file
-- (view share_agent_map). The file shows the hierarchy only by indentation, and one child is
-- not indented, so indentation is never parsed.
--
-- Lineage on the silver row (7 columns): _silver_build_id, _source_key, _source_file,
--   _source_sheet (null, the source is a CSV), _source_row_num, _as_of_date,
--   _metric_source_columns ({share_pct: 'share_2023'}).
--
-- Rule 2a (2026-10-19)
--   - share_years (2016 to 2023) is a setting. The unpivot in [3] names the bronze columns
--     (share_2016, ...); a new gate stops the build when bronze holds a year column the setting
--     does not list, or the reverse.
--   - The row-count gate is derived: agents in share_agent_map x size(share_years) (was 128).
--   - share_level1_tolerance_pct (0.2): level-1 shares are rounded to one decimal in the source,
--     so their sum may miss 100 by a little. socioeconomic_silver_qc.py S91 reads it from build_log.
-- =============================================================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
-- true : every input needs exactly one processed ingestion_metadata row (contract 3.5).
-- false: a missing row is allowed, and that input gets a null load id and checksum.
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job
-- Years of the file loaded (psa_health_expenditure_share_national_annual_2016_2023.csv).
DECLARE OR REPLACE VARIABLE share_years ARRAY<INT> DEFAULT sequence(2016, 2023);
-- Level-1 agents may miss 100 by this much (percentage points; source rounds to 0.1).
DECLARE OR REPLACE VARIABLE share_level1_tolerance_pct DECIMAL(4,2) DEFAULT 0.2;

-- Label normalisation: line breaks and repeated spaces become one space, then upper case.
CREATE OR REPLACE TEMPORARY FUNCTION se_label(s STRING) RETURNS STRING
RETURN upper(trim(regexp_replace(s, '\\s+', ' ')));

-- Approved list of financing agents. label_norm is the label as printed, normalised by se_label.
-- label_column says which bronze column holds the label (agent_level1 or agent_level2).
CREATE OR REPLACE TEMP VIEW share_agent_map AS
SELECT * FROM VALUES
  ( 1, 'agent_level1', 'TOTAL CURRENT HEALTH EXPENDITURE', 'Total Current Health Expenditure', CAST(NULL AS STRING), 0),
  ( 2, 'agent_level1', 'GENERAL GOVERNMENT', 'General Government', 'Total Current Health Expenditure', 1),
  ( 3, 'agent_level2', 'CENTRAL GOVERNMENT', 'Central Government', 'General Government', 2),
  ( 4, 'agent_level2', 'DEPARTMENT OF HEALTH', 'Department of Health', 'Central Government', 3),
  ( 5, 'agent_level2', 'OTHER MINISTRIES AND PUBLIC UNITS (BELONGING TO CENTRAL GOVERNMENT)', 'Other ministries and public units (belonging to central government)', 'Central Government', 3),
  ( 6, 'agent_level2', 'STATE/REGIONAL/LOCAL GOVERNMENT', 'State/Regional/Local government', 'General Government', 2),
  ( 7, 'agent_level2', 'SOCIAL SECURITY AGENCY', 'Social security agency', 'General Government', 2),
  ( 8, 'agent_level2', 'SOCIAL HEALTH INSURANCE AGENCY (PHIC)', 'Social Health Insurance Agency (PHIC)', 'Social security agency', 3),
  ( 9, 'agent_level2', 'OTHER SOCIAL SECURITY AGENCY (GSIS, SSS)', 'Other social security agency (GSIS, SSS)', 'Social security agency', 3),
  (10, 'agent_level1', 'INSURANCE CORPORATIONS', 'Insurance corporations', 'Total Current Health Expenditure', 1),
  (11, 'agent_level2', 'COMMERCIAL INSURANCE COMPANIES', 'Commercial insurance companies', 'Insurance corporations', 2),
  (12, 'agent_level1', 'CORPORATIONS (OTHER THAN INSURANCE CORPORATIONS)', 'Corporations (Other than insurance corporations)', 'Total Current Health Expenditure', 1),
  (13, 'agent_level2', 'HEALTH MANAGEMENT AND PROVIDER CORPORATIONS', 'Health management and provider corporations', 'Corporations (Other than insurance corporations)', 2),
  (14, 'agent_level2', 'CORPORATIONS (OTHER THAN PROVIDERS OF HEALTH SERVICES)', 'Corporations (Other than providers of health services)', 'Corporations (Other than insurance corporations)', 2),
  (15, 'agent_level1', 'HOUSEHOLDS', 'Households', 'Total Current Health Expenditure', 1),
  (16, 'agent_level1', 'REST OF THE WORLD', 'Rest of the World', 'Total Current Health Expenditure', 1)
  AS t(agent_order, label_column, label_norm, financing_agent, parent_agent, agent_level);


-- =============================================================================
-- [1] classify every bronze row with the approved agent list
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_share_silver__classified AS
WITH r AS (
  SELECT b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._ingested_at,
         CASE WHEN b.agent_level1 IS NOT NULL AND b.agent_level2 IS NULL THEN 'agent_level1'
              WHEN b.agent_level1 IS NULL AND b.agent_level2 IS NOT NULL THEN 'agent_level2' END AS label_column,
         se_label(coalesce(b.agent_level1, b.agent_level2)) AS label_norm
  FROM public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze b
  WHERE b._source_key = 'psa_health_expenditure_share_national_annual'
)
SELECT 'public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze' AS input_table,
       r._source_key, r._source_file, r._source_sheet, r._source_row_num, r._ingested_at,
       a.agent_order,
       CASE WHEN a.agent_order IS NOT NULL THEN 'data'
            WHEN r.label_column = 'agent_level1' AND r.label_norm RLIKE '^[A-Z]/ ' THEN 'non_data'
            WHEN r.label_column = 'agent_level1' AND r.label_norm LIKE 'SOURCE:%'  THEN 'non_data'
            ELSE 'unclassified' END AS row_class,
       CASE WHEN a.agent_order IS NOT NULL THEN CAST(NULL AS STRING)
            WHEN r.label_column = 'agent_level1' AND r.label_norm RLIKE '^[A-Z]/ ' THEN 'footnote'
            WHEN r.label_column = 'agent_level1' AND r.label_norm LIKE 'SOURCE:%'  THEN 'source_line'
            ELSE 'agent_not_in_list' END AS reason
FROM r
LEFT JOIN share_agent_map a
  ON a.label_column = r.label_column AND a.label_norm = r.label_norm;


-- =============================================================================
-- [2] inputs (layout of quality.build_inputs)
-- =============================================================================
-- Delta version of the table read. If your runtime rejects DESCRIBE HISTORY in a subquery,
-- use the NULL version below instead (the build still works, versions are just not recorded).
CREATE OR REPLACE TEMP VIEW share_table_versions AS
SELECT 'public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze)) AS table_version;
-- NULL version (use this instead if the view above fails):
-- CREATE OR REPLACE TEMP VIEW share_table_versions AS
-- SELECT CAST(NULL AS STRING) AS table_name, CAST(NULL AS BIGINT) AS table_version WHERE 1 = 0

CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_share_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT silver_build_id      AS build_id,
       'public_health.silver.socioeconomic_health_expenditure_share_silver' AS target_table,
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
LEFT JOIN share_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows;


-- =============================================================================
-- [3] candidate rows: years to rows. 'a/' means the share is below 0.05 percent.
--     The bronze columns are named by year, so they are listed by name; the year column gate
--     keeps this list and share_years in step.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_share_silver__candidate AS
WITH u AS (
  SELECT a.financing_agent, a.parent_agent, a.agent_level, a.agent_order,
         b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date,
         stack(8,
           2016, b.share_2016, 'share_2016',  2017, b.share_2017, 'share_2017',
           2018, b.share_2018, 'share_2018',  2019, b.share_2019, 'share_2019',
           2020, b.share_2020, 'share_2020',  2021, b.share_2021, 'share_2021',
           2022, b.share_2022, 'share_2022',  2023, b.share_2023, 'share_2023'
         ) AS (year, raw, src_col)
  FROM public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze b
  JOIN public_health.silver.socioeconomic_health_expenditure_share_silver__classified c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  JOIN share_agent_map a ON a.agent_order = c.agent_order
  WHERE b._source_key = 'psa_health_expenditure_share_national_annual' AND c.row_class = 'data'
)
SELECT financing_agent, parent_agent, agent_level, agent_order,
       year,
       CASE WHEN trim(raw) = 'a/' THEN CAST(0 AS DECIMAL(5,1))
            ELSE try_cast(regexp_replace(trim(raw), '[ ,]', '') AS DECIMAL(5,1)) END AS share_pct,
       (trim(raw) <=> 'a/')                                                          AS is_below_0_05,
       CASE WHEN raw IS NULL OR trim(raw) = '' THEN 'missing'
            WHEN trim(raw) = 'a/' THEN 'below_threshold'
            WHEN try_cast(regexp_replace(trim(raw), '[ ,]', '') AS DECIMAL(5,1)) IS NOT NULL THEN 'ok'
            ELSE 'parse_error' END                                                   AS value_status,
       silver_build_id         AS _silver_build_id,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('share_pct', src_col) AS _metric_source_columns
FROM u;


-- =============================================================================
-- [4] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_share_silver__gates AS
SELECT 'inputs: file with more than one load time' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_health_expenditure_share_silver__inputs
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__inputs WHERE metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__inputs WHERE metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'inputs: not exactly one file', abs(count(*) - 1)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__inputs
UNION ALL
-- Years in the bronze column names (share_2016, ...) vs share_years, from one row of the source.
SELECT 'bronze year columns differ from share_years (update the setting and the unpivot in [3])',
       size(array_except(y.bronze_years, share_years)) + size(array_except(share_years, y.bronze_years))
FROM (SELECT array_distinct(collect_list(CAST(regexp_extract(k, '^share_([0-9]{4})$', 1) AS INT))) AS bronze_years
      FROM (SELECT explode(json_object_keys(to_json(struct(*), map('ignoreNullFields', 'false')))) AS k
            FROM (SELECT * FROM public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze
                  WHERE _source_key = 'psa_health_expenditure_share_national_annual' LIMIT 1))
      WHERE k RLIKE '^share_[0-9]{4}$') y
UNION ALL
SELECT 'unclassified bronze rows', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__classified WHERE row_class NOT IN ('data', 'non_data')
UNION ALL
SELECT 'agent of the approved list missing from the file, or listed twice', count(*) FROM (
  SELECT a.agent_order
  FROM share_agent_map a
  LEFT JOIN public_health.silver.socioeconomic_health_expenditure_share_silver__classified c
    ON c.agent_order = a.agent_order AND c.row_class = 'data'
  GROUP BY a.agent_order HAVING count(c.agent_order) <> 1)
UNION ALL
SELECT 'cell that is neither a number nor a documented marker', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate WHERE value_status = 'parse_error'
UNION ALL
SELECT 'agent-year without a published value', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate WHERE value_status = 'missing'
UNION ALL
SELECT 'share outside 0 to 100', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate WHERE share_pct < 0 OR share_pct > 100
UNION ALL
SELECT 'total is not 100', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate WHERE agent_level = 0 AND NOT (share_pct <=> 100)
UNION ALL
SELECT 'level-1 agents do not sum to 100 (tolerance share_level1_tolerance_pct)', count(*) FROM (
  SELECT year FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate
  WHERE agent_level = 1 GROUP BY year HAVING abs(sum(share_pct) - 100) > share_level1_tolerance_pct)
UNION ALL
SELECT 'key column is null', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate WHERE financing_agent IS NULL OR year IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate
  GROUP BY financing_agent, year HAVING count(*) > 1)
UNION ALL
SELECT 'lineage column is null', count(*)
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _source_row_num IS NULL
     OR _as_of_date IS NULL OR _metric_source_columns IS NULL
UNION ALL
SELECT 'classified rows <> bronze rows read',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__classified)
         - (SELECT coalesce(sum(input_rows), 0) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__inputs))
UNION ALL
SELECT 'silver rows <> agents in share_agent_map x share_years',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate)
         - (SELECT count(*) FROM share_agent_map) * size(share_years))
UNION ALL
SELECT 'reconciliation: bronze rows referenced by silver <> rows read - rows not loaded (data rows)',
       abs((SELECT count(DISTINCT _source_row_num) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate)
         - (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__classified WHERE row_class = 'data'));


-- =============================================================================
-- [5] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW share_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'socioeconomic'                                AS domain,
       'public_health.silver.socioeconomic_health_expenditure_share_silver' AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [8]
       code_version                                   AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'share_years', share_years,
                            'share_agent_count', (SELECT count(*) FROM share_agent_map),
                            'share_level1_tolerance_pct', share_level1_tolerance_pct,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__inputs WHERE metadata_matches = 0))) AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.socioeconomic_health_expenditure_share_silver__gates) g;


-- =============================================================================
-- [6] stop here if a gate failed. The failed build is logged first, and the published table
--     stays as it was. The staging tables are kept so you can see what failed.
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM share_build_log WHERE status = 'failed';

SELECT raise_error(concat('socioeconomic_health_expenditure_share_silver was NOT published. ', error_message))
FROM share_build_log WHERE status = 'failed';


-- =============================================================================
-- [7] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_health_expenditure_share_silver AS
SELECT * EXCEPT (value_status) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__candidate;

COMMENT ON TABLE public_health.silver.socioeconomic_health_expenditure_share_silver IS
  'Percent share of current health expenditure by financing agent, Philippines, 2016 to 2023 (PSA Yearbook Table 9.26). One row per financing_agent and year. The agents form a hierarchy: never add a parent to its children. Only agent_level = 1 rows add up to the total. Households = out-of-pocket payments.';
ALTER TABLE public_health.silver.socioeconomic_health_expenditure_share_silver ALTER COLUMN share_pct COMMENT 'Percent of current health expenditure. A 0.0 with is_below_0_05 = true means below 0.05 percent, not an exact zero';
ALTER TABLE public_health.silver.socioeconomic_health_expenditure_share_silver ALTER COLUMN agent_level COMMENT '0 = total, 1 = main agent, 2 and 3 = sub-agents of parent_agent';


-- =============================================================================
-- [8] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.socioeconomic_health_expenditure_share_silver)),
       code_version, parameters, run_id, error_message
FROM share_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.socioeconomic_health_expenditure_share_silver__inputs;

-- Bronze rows NOT loaded (lineage-qc-contract.md v1.3, section 7.1). Loaded rows are not written:
-- the silver rows carry their bronze row reference, and rows loaded per input = input_rows minus
-- the rows here (quality.v_build_reconciliation). Here only non-data rows are not loaded
-- (an unclassified row fails a gate, so it never reaches this step).
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.socioeconomic_health_expenditure_share_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       'dropped_non_data',
       c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.socioeconomic_health_expenditure_share_silver__classified c
LEFT JOIN public_health.silver.socioeconomic_health_expenditure_share_silver__inputs i
  ON i.source_key = c._source_key AND i.source_file = c._source_file AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [9] summary, then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW share_summary AS
SELECT (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__classified) AS bronze_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver__classified WHERE row_class = 'data') AS data_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver) AS silver_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_health_expenditure_share_silver WHERE is_below_0_05) AS rows_below_0_05,
       -- control values to read against the PSA table: the expected numbers are the
       -- qc.control_values of this source in sources_socioeconomic.yaml (S84 checks them)
       (SELECT max(share_pct) FROM public_health.silver.socioeconomic_health_expenditure_share_silver WHERE financing_agent = 'Households' AND year = 2023) AS households_2023_pct,
       (SELECT max(share_pct) FROM public_health.silver.socioeconomic_health_expenditure_share_silver WHERE financing_agent = 'Households' AND year = 2016) AS households_2016_pct;

SELECT * FROM share_summary;

DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_share_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_share_silver__gates;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_share_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_health_expenditure_share_silver__classified;
