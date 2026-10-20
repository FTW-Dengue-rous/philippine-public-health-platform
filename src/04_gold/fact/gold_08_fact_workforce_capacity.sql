-- ========================================
-- Builds public_health.gold.fact_workforce_capacity
--   One row is: headcount of one profession in one area and year from one source
--   Primary key: fact_workforce_capacity_key = xxhash64 of the natural values of the grain.
--                Stable across rebuilds.
--   Grain: (area_key, date_key, profession_code, data_source_key)
--
-- Reads
--   public_health.silver.workforce_headcount_silver
--   profession names and groups (reviewed list in this file)
--   public_health.gold.dim_geography, dim_date, dim_data_source (gold 01-03)
--
-- Rules
--   * One gold row per silver row. Rows that are not analysis_eligible are KEPT.
--   * Null is not zero. A headcount is filled only when its own silver status is ok (silver
--     marks the 2018 legend "0 = No Data" as not ok).
--   * analysis_eligible refers to headcount_total. Use it to pick rows for a rate.
--   * source_role (preferred, cross_check): PSA and FHSIS overlap for 2018 to 2023; the PSA rows
--     of those years are cross_check (compared with FHSIS national totals, silver check S71,
--     never shown as the value). Filter source_role = 'preferred' or one source, or the query
--     double counts. v_workforce_preferred (gold 13) applies the filter.
--   * Country, region, province, city and municipality rows sit together. Never add a
--     province to its listed cities. The nurse series changes definition in 2019
--     (is_break_year; silver setting nurse_definition_break_year).
--   * core_clinical = doctors, nurses, midwives. A gate checks the list keeps exactly three:
--     the workforce gap rule (gold 19, "two of three") depends on it.
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
--   2026-10-14  Written for the combined data model (from gold_35, v1). source_role
--               cross_check (not alternate), to match source_priority.
--   2026-10-20  Moved to public_health.gold and renamed gold_08. The profession list is
--               defined before [1], and its row count is read from it (was typed as 9).
--               'model' removed from the build log parameters. No change to the table.
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


-- Profession names and groups, reviewed list. [1] counts its rows; a gate checks that
-- core_clinical keeps exactly doctors, nurses and midwives.
CREATE OR REPLACE TEMP VIEW fact_workforce_capacity_profession AS
SELECT profession_code, profession_name, profession_group
FROM VALUES
  ('doctors', 'Doctors', 'core_clinical'),
  ('nurses', 'Nurses', 'core_clinical'),
  ('midwives', 'Midwives', 'core_clinical'),
  ('bhw', 'Barangay health workers', 'community'),
  ('dentists', 'Dentists', 'other'),
  ('medtech', 'Medical technologists', 'other'),
  ('nutritionists', 'Nutritionists', 'other'),
  ('sanitary_engineers', 'Sanitary engineers', 'other'),
  ('sanitary_inspectors', 'Sanitary inspectors', 'other')
  AS t (profession_code, profession_name, profession_group);


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_workforce_capacity__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.workforce_headcount_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.workforce_headcount_silver
  UNION ALL
  SELECT 'reference' AS input_kind, CAST(NULL AS STRING) AS input_table, 'profession names and groups' AS source_file,
         (SELECT count(*) FROM fact_workforce_capacity_profession) AS input_rows
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_date' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_date
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_data_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_data_source
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_workforce_capacity__candidate AS
SELECT xxhash64(h.area_key, CAST(h.year AS STRING), h.profession, h._source_key) AS fact_workforce_capacity_key,
       xxhash64(h.area_key)                       AS area_key,
       xxhash64('calendar_year', CAST(h.year AS STRING)) AS date_key,
       xxhash64(h._source_key)                    AS data_source_key,
       h.profession                               AS profession_code,
       p.profession_name,
       p.profession_group,
       CASE WHEN h.total_status = 'ok' THEN CAST(h.headcount_total AS BIGINT) END         AS headcount_total,
       CASE WHEN h.lgu_hired_status = 'ok' THEN CAST(h.headcount_lgu_hired AS BIGINT) END AS headcount_lgu_hired,
       CASE WHEN h.doh_hired_status = 'ok' THEN CAST(h.headcount_doh_hired AS BIGINT) END AS headcount_doh_hired,
       h.analysis_eligible,
       h.exclusion_reason,
       h.source_role,                             -- preferred or cross_check, as in silver and source_priority
       h.geo_coverage_basis                       AS coverage_basis,
       h.is_break_year,
       gold_build_id                              AS _gold_build_id
FROM public_health.silver.workforce_headcount_silver AS h
LEFT JOIN fact_workforce_capacity_profession AS p ON p.profession_code = h.profession;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_workforce_capacity__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.fact_workforce_capacity__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.fact_workforce_capacity__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.fact_workforce_capacity__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.fact_workforce_capacity__candidate
WHERE fact_workforce_capacity_key IS NULL OR area_key IS NULL OR date_key IS NULL OR data_source_key IS NULL OR profession_code IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_workforce_capacity__candidate GROUP BY fact_workforce_capacity_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_workforce_capacity__candidate
  GROUP BY area_key, date_key, profession_code, data_source_key HAVING count(*) > 1)
UNION ALL
SELECT 'profession not in the reviewed list (no name or group)', count(*) FROM public_health.gold.fact_workforce_capacity__candidate WHERE profession_name IS NULL OR profession_group IS NULL
UNION ALL
SELECT 'core clinical professions in the list <> 3', abs(count_if(profession_group = 'core_clinical') - 3) FROM fact_workforce_capacity_profession
UNION ALL
SELECT 'rows <> workforce_headcount_silver rows', abs((SELECT count(*) FROM public_health.gold.fact_workforce_capacity__candidate) - count(*)) FROM public_health.silver.workforce_headcount_silver
UNION ALL
SELECT 'eligible row without a total', count(*) FROM public_health.gold.fact_workforce_capacity__candidate WHERE analysis_eligible AND headcount_total IS NULL
UNION ALL
SELECT 'row that is not eligible and has no exclusion_reason', count(*) FROM public_health.gold.fact_workforce_capacity__candidate WHERE NOT analysis_eligible AND exclusion_reason IS NULL
UNION ALL
SELECT 'source_role outside preferred, cross_check', count(*) FROM public_health.gold.fact_workforce_capacity__candidate WHERE source_role NOT IN ('preferred', 'cross_check') OR source_role IS NULL
UNION ALL
SELECT 'more than one preferred source for an area, year and profession', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_workforce_capacity__candidate WHERE source_role = 'preferred'
  GROUP BY area_key, date_key, profession_code HAVING count(*) > 1)
UNION ALL
SELECT 'negative headcount', count(*) FROM public_health.gold.fact_workforce_capacity__candidate WHERE least(headcount_total, headcount_lgu_hired, headcount_doh_hired) < 0
UNION ALL
SELECT 'eligible total <> silver eligible total', CAST(abs(coalesce((SELECT sum(headcount_total) FROM public_health.gold.fact_workforce_capacity__candidate WHERE analysis_eligible), 0)
         - coalesce(sum(CASE WHEN analysis_eligible THEN headcount_total END), 0)) AS BIGINT)
FROM public_health.silver.workforce_headcount_silver
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.gold.fact_workforce_capacity__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'date_key not in dim_date', count(*) FROM (
  SELECT DISTINCT date_key AS k FROM public_health.gold.fact_workforce_capacity__candidate WHERE date_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_date AS d ON d.date_key = c.k
UNION ALL
SELECT 'data_source_key not in dim_data_source', count(*) FROM (
  SELECT DISTINCT data_source_key AS k FROM public_health.gold.fact_workforce_capacity__candidate WHERE data_source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_data_source AS d ON d.data_source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.fact_workforce_capacity__gates WHERE failures <> 0
--     approval: provisional while a silver input has no QC run or has WARN findings to review.
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_workforce_capacity_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'workforce'                                      AS domain,
       'public_health.gold.fact_workforce_capacity'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.fact_workforce_capacity__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.fact_workforce_capacity__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_workforce_capacity_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_workforce_capacity was NOT published. ', error_message))
FROM fact_workforce_capacity_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_workforce_capacity AS
SELECT * FROM public_health.gold.fact_workforce_capacity__candidate;


-- ========================================
-- [6] record the build, with the table version just written. If your runtime rejects this
--     SET VAR, delete it: the version stays null, and freshness checks (G06,
--     mart_evidence_readiness) cannot compare this table.
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.fact_workforce_capacity));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.fact_workforce_capacity),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_workforce_capacity_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.fact_workforce_capacity', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.fact_workforce_capacity__inputs;


-- ========================================
-- [7] remove the staging tables, then show the summary
-- ========================================
DROP TABLE IF EXISTS public_health.gold.fact_workforce_capacity__candidate;
DROP TABLE IF EXISTS public_health.gold.fact_workforce_capacity__gates;
DROP TABLE IF EXISTS public_health.gold.fact_workforce_capacity__inputs;

-- Databricks 2026-10-14: 28,071 rows (FHSIS 27,207 and PSA 864). The local test with a silver stand-in gave 28,080.
-- Expected roles: FHSIS 2018-2025 preferred; PSA 2012-2017 preferred (432 rows), PSA 2018-2023 cross_check (432 rows).
SELECT s.source_dataset, f.source_role, f.profession_group, min(d.year) AS first_year, max(d.year) AS last_year,
       count(*) AS row_count, count_if(f.analysis_eligible) AS eligible_rows
FROM public_health.gold.fact_workforce_capacity AS f
INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
INNER JOIN public_health.gold.dim_date AS d ON d.date_key = f.date_key
GROUP BY s.source_dataset, f.source_role, f.profession_group
ORDER BY s.source_dataset, f.source_role, f.profession_group;