-- ========================================
-- Builds public_health.test_gold.context_health_expenditure
--   One row is: one financing agent in one year, national. A context table outside the star schema
--   Primary key: context_health_expenditure_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (financing_agent, year)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.socioeconomic_health_expenditure_share_silver
--   public_health.silver.socioeconomic_health_expenditure_per_capita_silver
--
-- NOT part of model v3.1. Open decision 4 proposes to keep health expenditure outside the
-- star schema as a small national context table for the story slides (out-of-pocket share
-- 2016 to 2023, a Supporting question). Drop this file if the team decides against it.
-- It has no dimension keys: it is national only and joins to nothing.
-- Rules
--   * The share table gives the rows (16 agents x 8 years). The per capita table has one row
--     per year. Its three columns are REPEATED on every agent row of that year: never sum them.
--   * Never add a parent agent to its children. Only agent_level = 1 rows add up to the total.
--   * is_below_0_05 = true means share_pct 0.0 stands for a share below 0.05 percent.
--   * Per capita values are pesos at current prices. Households is out-of-pocket spending.


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
CREATE OR REPLACE TABLE public_health.test_gold.context_health_expenditure__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.socioeconomic_health_expenditure_share_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.socioeconomic_health_expenditure_share_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.socioeconomic_health_expenditure_per_capita_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.socioeconomic_health_expenditure_per_capita_silver
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.context_health_expenditure__candidate AS
SELECT xxhash64(s.financing_agent, CAST(s.year AS STRING)) AS context_health_expenditure_key,
       s.financing_agent,
       CAST(s.year AS SMALLINT)                   AS year,
       CAST(s.share_pct AS DECIMAL(5, 1))         AS share_pct,
       s.is_below_0_05,
       CAST(s.agent_level AS INT)                 AS agent_level,
       s.parent_agent,
       CAST(c.per_capita_health_expenditure_php AS DECIMAL(12, 2)) AS per_capita_health_expenditure_php,
       CAST(c.growth_rate_pct AS DECIMAL(6, 1))   AS growth_rate_pct,
       c.is_revised,
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.socioeconomic_health_expenditure_share_silver AS s
LEFT JOIN public_health.silver.socioeconomic_health_expenditure_per_capita_silver AS c ON c.year = s.year;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.context_health_expenditure__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.context_health_expenditure__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.context_health_expenditure__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.context_health_expenditure__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.context_health_expenditure__candidate
WHERE context_health_expenditure_key IS NULL OR financing_agent IS NULL OR year IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.context_health_expenditure__candidate GROUP BY context_health_expenditure_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.context_health_expenditure__candidate
  GROUP BY financing_agent, year HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> share silver rows', abs((SELECT count(*) FROM public_health.test_gold.context_health_expenditure__candidate) - count(*))
FROM public_health.silver.socioeconomic_health_expenditure_share_silver
UNION ALL
SELECT 'year without a per capita row', count(*) FROM public_health.test_gold.context_health_expenditure__candidate WHERE per_capita_health_expenditure_php IS NULL
UNION ALL
SELECT 'share outside 0 to 100', count(*) FROM public_health.test_gold.context_health_expenditure__candidate WHERE share_pct NOT BETWEEN 0 AND 100 OR share_pct IS NULL
UNION ALL
SELECT 'level 1 shares of a year do not add up to 100 within 0.2', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.context_health_expenditure__candidate WHERE agent_level = 1
  GROUP BY year HAVING abs(sum(share_pct) - 100) > 0.2);


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.context_health_expenditure__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW context_health_expenditure_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'socioeconomic'                                      AS domain,
       'public_health.test_gold.context_health_expenditure'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.context_health_expenditure__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.context_health_expenditure__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM context_health_expenditure_build_log WHERE status = 'failed';

SELECT raise_error(concat('context_health_expenditure was NOT published. ', error_message))
FROM context_health_expenditure_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.context_health_expenditure AS
SELECT * FROM public_health.test_gold.context_health_expenditure__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.context_health_expenditure));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.context_health_expenditure),
       gold_target_version, code_version, parameters, run_id, error_message
FROM context_health_expenditure_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.context_health_expenditure', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.context_health_expenditure__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.context_health_expenditure__candidate;
DROP TABLE IF EXISTS public_health.test_gold.context_health_expenditure__gates;
DROP TABLE IF EXISTS public_health.test_gold.context_health_expenditure__inputs;

SELECT year, count(*) AS agents,
       max(CASE WHEN financing_agent = 'Households' THEN share_pct END) AS households_share_pct,
       max(per_capita_health_expenditure_php) AS per_capita_php
FROM public_health.test_gold.context_health_expenditure GROUP BY year ORDER BY year;
