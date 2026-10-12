-- ========================================
-- Builds public_health.test_gold.fact_bed_occupancy
--   One row is: bed occupancy of the reporting hospitals of one area, year, ownership and hospital level (aggregate of anonymous records)
--   Primary key: fact_bed_occupancy_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, period_key, source_key, ownership, hospital_level)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.facilities_bed_occupancy_silver
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_source
--
-- v3.1 columns: fact_bed_occupancy_key, area_key, period_key, source_key,
--   reporting_record_count, eligible_record_count, bor_weighted_pct, bor_median_pct,
--   weighted_beds_sum.
-- Extra columns (proposed additions)
--   * ownership, hospital_level (part of the grain): S2 compares government and private
--     hospitals, and D3 needs spare capacity by ownership. The proposal lists both as
--     degenerate dimensions. Without them the fact has one row per area and year.
--   * is_suppressed: the rule "small cells are suppressed" must be visible on the row.
--   * baseline_validated: false until the bed basis and the reporting period are confirmed.
--     The dengue replay (D3) must not start before that.
--   * coverage_basis, area_level_published: the 2025 sheet is by province, and a province
--     there includes its cities. Use area_level_published for the level of the area.
-- Rules
--   * RESTRICTED source. Aggregates only. Records are never matched to facilities (D-18).
--   * A group built from fewer than suppression_min_records records is suppressed: its
--     measures are null. 3 is the proposal in open decision 6.
--   * bor_weighted_pct uses eligible records (baseline_eligible in silver) that have an
--     authorized bed count. weighted_beds_sum is their bed total. Authorized beds exist for
--     2025 only, so 2020 to 2024 have no weighted rate (private hospitals only, not a trend).
--   * Roll-up: sum(bor_weighted_pct * weighted_beds_sum) / sum(weighted_beds_sum). Never
--     average bor_weighted_pct or bor_median_pct.
--   * hospital_level is Level 1, Level 2, Level 3, or unknown when the record names no level.
-- Facilities silver ran on Databricks on 2026-10-12, all gates 0. Bed occupancy 1,977 rows.
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
-- Smallest number of hospital records a published group may be built from (open decision 6).
DECLARE OR REPLACE VARIABLE suppression_min_records INT DEFAULT 3;

-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_bed_occupancy__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_bed_occupancy_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_bed_occupancy_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_period' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_period
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.test_gold.dim_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.test_gold.dim_source
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_bed_occupancy_grouped AS
SELECT area_key AS area_code,
       CAST(year AS INT)                          AS year,
       _source_key,
       ownership,
       coalesce(nullif(trim(service_level), ''), 'unknown') AS hospital_level,
       geo_coverage_basis,
       area_level_published,
       count(*)                                   AS records,
       count_if(baseline_eligible)                AS eligible_records,
       sum(CASE WHEN baseline_eligible AND authorized_beds IS NOT NULL
                THEN CAST(bor_pct AS DOUBLE) * authorized_beds END) AS bor_x_beds_sum,
       sum(CASE WHEN baseline_eligible AND bor_pct IS NOT NULL
                THEN CAST(authorized_beds AS DOUBLE) END)           AS weight_beds_sum,
       percentile(CASE WHEN baseline_eligible THEN CAST(bor_pct AS DOUBLE) END, 0.5) AS bor_median,
       coalesce(bool_and(bor_basis_confirmed), false) AND coalesce(bool_and(period_confirmed), false) AS baseline_validated
FROM public_health.silver.facilities_bed_occupancy_silver
GROUP BY area_key, CAST(year AS INT), _source_key, ownership,
         coalesce(nullif(trim(service_level), ''), 'unknown'), geo_coverage_basis, area_level_published;

CREATE OR REPLACE TABLE public_health.test_gold.fact_bed_occupancy__candidate AS
SELECT xxhash64(area_code, CAST(year AS STRING), _source_key, ownership, hospital_level) AS fact_bed_occupancy_key,
       xxhash64(area_code)                        AS area_key,
       xxhash64('calendar_year', CAST(year AS STRING)) AS period_key,
       xxhash64(_source_key)                      AS source_key,
       records                                    AS reporting_record_count,
       CASE WHEN records >= suppression_min_records THEN eligible_records END AS eligible_record_count,
       CASE WHEN records >= suppression_min_records AND weight_beds_sum > 0
            THEN CAST(bor_x_beds_sum / weight_beds_sum AS DECIMAL(9, 4)) END AS bor_weighted_pct,
       CASE WHEN records >= suppression_min_records THEN CAST(bor_median AS DECIMAL(9, 4)) END AS bor_median_pct,
       CASE WHEN records >= suppression_min_records THEN CAST(weight_beds_sum AS DECIMAL(18, 2)) END AS weighted_beds_sum,
       ownership,                                 -- extra, part of the grain
       hospital_level,                            -- extra, part of the grain
       (records < suppression_min_records)        AS is_suppressed,         -- extra
       baseline_validated,                        -- extra
       geo_coverage_basis                         AS coverage_basis,        -- extra
       area_level_published,                      -- extra
       gold_build_id                              AS _gold_build_id
FROM fact_bed_occupancy_grouped;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_bed_occupancy__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_bed_occupancy__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_bed_occupancy__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_bed_occupancy__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_bed_occupancy__candidate
WHERE fact_bed_occupancy_key IS NULL OR area_key IS NULL OR period_key IS NULL OR source_key IS NULL OR ownership IS NULL OR hospital_level IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_bed_occupancy__candidate GROUP BY fact_bed_occupancy_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_bed_occupancy__candidate
  GROUP BY area_key, period_key, source_key, ownership, hospital_level HAVING count(*) > 1)
UNION ALL
SELECT 'reporting_record_count total <> silver rows', abs(coalesce((SELECT sum(reporting_record_count) FROM public_health.test_gold.fact_bed_occupancy__candidate), 0) - count(*))
FROM public_health.silver.facilities_bed_occupancy_silver
UNION ALL
SELECT 'ownership outside government, private', count(*) FROM public_health.test_gold.fact_bed_occupancy__candidate WHERE ownership NOT IN ('government', 'private')
UNION ALL
SELECT 'suppressed group that still shows a measure', count(*) FROM public_health.test_gold.fact_bed_occupancy__candidate
WHERE is_suppressed AND (eligible_record_count IS NOT NULL OR bor_weighted_pct IS NOT NULL
   OR bor_median_pct IS NOT NULL OR weighted_beds_sum IS NOT NULL)
UNION ALL
SELECT 'group below the suppression threshold that is not suppressed', count(*) FROM public_health.test_gold.fact_bed_occupancy__candidate WHERE reporting_record_count < suppression_min_records AND NOT is_suppressed
UNION ALL
SELECT 'weighted rate without a positive bed weight', count(*) FROM public_health.test_gold.fact_bed_occupancy__candidate WHERE bor_weighted_pct IS NOT NULL AND NOT (weighted_beds_sum > 0)
UNION ALL
SELECT 'weighted or median rate outside 0 to 150', count(*) FROM public_health.test_gold.fact_bed_occupancy__candidate WHERE bor_weighted_pct NOT BETWEEN 0 AND 150 OR bor_median_pct NOT BETWEEN 0 AND 150
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_bed_occupancy__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_bed_occupancy__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_bed_occupancy__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_bed_occupancy__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_bed_occupancy_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'facilities'                                      AS domain,
       'public_health.test_gold.fact_bed_occupancy'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds, 'suppression_min_records', suppression_min_records)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_bed_occupancy__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_bed_occupancy__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_bed_occupancy_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_bed_occupancy was NOT published. ', error_message))
FROM fact_bed_occupancy_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_bed_occupancy AS
SELECT * FROM public_health.test_gold.fact_bed_occupancy__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_bed_occupancy));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_bed_occupancy),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_bed_occupancy_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_bed_occupancy', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_bed_occupancy__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_bed_occupancy__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_bed_occupancy__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_bed_occupancy__inputs;

-- Silver control values for 2025: 1,162 records (418 government, 744 private).
SELECT p.year, f.ownership, count(*) AS row_groups, sum(f.reporting_record_count) AS records,
       count_if(f.is_suppressed) AS suppressed_groups, sum(f.eligible_record_count) AS eligible_records_shown,
       round(sum(f.bor_weighted_pct * f.weighted_beds_sum) / sum(f.weighted_beds_sum), 1) AS bor_weighted_pct_shown,
       bool_or(f.baseline_validated) AS any_baseline_validated
FROM public_health.test_gold.fact_bed_occupancy AS f
INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key
GROUP BY p.year, f.ownership ORDER BY p.year, f.ownership;