-- ========================================
-- Builds public_health.test_gold.fact_facility_published
--   One row is: published counts of one facility type and ownership in one area and year from one source
--   Primary key: fact_facility_published_key (BIGINT, xxhash64 of the natural key or grain, stable across rebuilds)
--   Grain: (area_key, period_key, source_key, facility_type, ownership)
--
-- Write-audit-publish, as in diseases_silver_01_metric.sql: [1] inputs with their build and
-- latest silver QC status, [2] candidate, [3] gates, [4] stop if a gate failed, [5] publish,
-- [6] record in quality.build_log and quality.build_inputs, [7] summary.
--
-- Reads
--   public_health.silver.facilities_metric_silver
--   public_health.test_gold.dim_geography
--   public_health.test_gold.dim_period
--   public_health.test_gold.dim_source
--
-- v3.1 columns: fact_facility_published_key, area_key, period_key, source_key, facility_type,
--   published_facility_count, published_authorized_beds, ownership.
-- Extra columns (proposed additions)
--   * value_status (ok, no_report): a null count the source marked * or - is not a zero.
--   * coverage_basis: what the area covers (FHSIS provinces exclude the cities listed apart).
--   * series_definition, is_break_year: the hospital definition changes in 2013. Do not trend
--     hospitals across it without the break.
-- Rules
--   * Silver is wide (one column per measure). Gold is long: one row per facility_type
--     (hospitals, bhs, rhu, mhc, chc, health_centers_total). A row exists when the source
--     published the measure or marked it as not reported.
--   * published_authorized_beds is filled on hospitals rows only. In 2020 to 2024 hospitals and
--     beds come from two PSA tables, so they sit on two rows with different source_key.
--   * Sources overlap on purpose. Filter on source_key before adding anything up. total rows
--     sit beside government and private rows: never sum across ownership.
--   * Never add ph, region and child rows together. National rows are area ph.
--   * For 2025 health_centers_total holds the FHSIS column printed as RHU and rhu has no row.
--   * barangays and the FHSIS population are not carried: population is in fact_population.
-- Facilities silver ran on Databricks on 2026-10-12, all gates 0. Metric 2,988 rows.
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


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_facility_published__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.facilities_metric_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.facilities_metric_silver
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
CREATE OR REPLACE TEMP VIEW fact_facility_published_long AS
SELECT m.area_key AS area_code, CAST(m.year AS INT) AS year, m._source_key, m.ownership,
       m.geo_coverage_basis, m.series_definition, m.is_break_year, m.no_report_measures,
       CAST(m.authorized_beds AS BIGINT) AS beds,
       stack(6, 'hospitals', CAST(m.hospitals AS BIGINT), 'bhs', CAST(m.bhs AS BIGINT),
                'rhu', CAST(m.rhu AS BIGINT), 'mhc', CAST(m.mhc AS BIGINT), 'chc', CAST(m.chc AS BIGINT),
                'health_centers_total', CAST(m.health_centers_total AS BIGINT)) AS (facility_type, facility_count)
FROM public_health.silver.facilities_metric_silver AS m;

CREATE OR REPLACE TABLE public_health.test_gold.fact_facility_published__candidate AS
SELECT xxhash64(area_code, CAST(year AS STRING), _source_key, facility_type, ownership) AS fact_facility_published_key,
       xxhash64(area_code)                        AS area_key,
       xxhash64('calendar_year', CAST(year AS STRING)) AS period_key,
       xxhash64(_source_key)                      AS source_key,
       facility_type,
       facility_count                             AS published_facility_count,
       CASE WHEN facility_type = 'hospitals' THEN beds END AS published_authorized_beds,
       ownership,
       CASE WHEN facility_count IS NOT NULL OR (facility_type = 'hospitals' AND beds IS NOT NULL) THEN 'ok'
            ELSE 'no_report' END                  AS value_status,          -- extra
       geo_coverage_basis                         AS coverage_basis,        -- extra
       CASE WHEN facility_type = 'hospitals' THEN series_definition END AS series_definition,   -- extra
       (facility_type = 'hospitals' AND coalesce(is_break_year, false)) AS is_break_year,       -- extra
       gold_build_id                              AS _gold_build_id
FROM fact_facility_published_long
WHERE facility_count IS NOT NULL
   OR (facility_type = 'hospitals' AND beds IS NOT NULL)
   OR array_contains(no_report_measures, facility_type)
   OR (facility_type = 'hospitals' AND array_contains(no_report_measures, 'authorized_beds'));


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_facility_published__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.test_gold.fact_facility_published__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.test_gold.fact_facility_published__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.test_gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.test_gold.fact_facility_published__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.test_gold.fact_facility_published__candidate
WHERE fact_facility_published_key IS NULL OR area_key IS NULL OR period_key IS NULL OR source_key IS NULL OR facility_type IS NULL OR ownership IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_facility_published__candidate GROUP BY fact_facility_published_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.test_gold.fact_facility_published__candidate
  GROUP BY area_key, period_key, source_key, facility_type, ownership HAVING count(*) > 1)
UNION ALL
SELECT 'facility_type outside the six known values', count(*) FROM public_health.test_gold.fact_facility_published__candidate
WHERE facility_type NOT IN ('hospitals', 'bhs', 'rhu', 'mhc', 'chc', 'health_centers_total')
UNION ALL
SELECT 'ownership outside total, government, private', count(*) FROM public_health.test_gold.fact_facility_published__candidate WHERE ownership NOT IN ('total', 'government', 'private')
UNION ALL
SELECT 'beds on a row that is not hospitals, or a negative value', count(*) FROM public_health.test_gold.fact_facility_published__candidate
WHERE (facility_type <> 'hospitals' AND published_authorized_beds IS NOT NULL)
   OR published_facility_count < 0 OR published_authorized_beds < 0
UNION ALL
SELECT 'hospitals total <> silver total', CAST(abs(coalesce((SELECT sum(published_facility_count) FROM public_health.test_gold.fact_facility_published__candidate WHERE facility_type = 'hospitals'), 0)
         - coalesce(sum(hospitals), 0)) AS BIGINT) FROM public_health.silver.facilities_metric_silver
UNION ALL
SELECT 'bhs total <> silver total', CAST(abs(coalesce((SELECT sum(published_facility_count) FROM public_health.test_gold.fact_facility_published__candidate WHERE facility_type = 'bhs'), 0)
         - coalesce(sum(bhs), 0)) AS BIGINT) FROM public_health.silver.facilities_metric_silver
UNION ALL
SELECT 'authorized beds total <> silver total', CAST(abs(coalesce((SELECT sum(published_authorized_beds) FROM public_health.test_gold.fact_facility_published__candidate), 0)
         - coalesce(sum(authorized_beds), 0)) AS BIGINT) FROM public_health.silver.facilities_metric_silver
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.test_gold.fact_facility_published__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'period_key not in dim_period', count(*) FROM (
  SELECT DISTINCT period_key AS k FROM public_health.test_gold.fact_facility_published__candidate WHERE period_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_period AS d ON d.period_key = c.k
UNION ALL
SELECT 'source_key not in dim_source', count(*) FROM (
  SELECT DISTINCT source_key AS k FROM public_health.test_gold.fact_facility_published__candidate WHERE source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.test_gold.dim_source AS d ON d.source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.test_gold.fact_facility_published__gates WHERE failures <> 0
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_facility_published_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'facilities'                                      AS domain,
       'public_health.test_gold.fact_facility_published'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('model', 'v3.1', 'approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.test_gold.fact_facility_published__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.test_gold.fact_facility_published__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_facility_published_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_facility_published was NOT published. ', error_message))
FROM fact_facility_published_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.test_gold.fact_facility_published AS
SELECT * FROM public_health.test_gold.fact_facility_published__candidate;


-- ========================================
-- [6] record the build. If your runtime rejects this SET VAR, delete it (version = null).
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.test_gold.fact_facility_published));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.test_gold.fact_facility_published),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_facility_published_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.test_gold.fact_facility_published', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.test_gold.fact_facility_published__inputs;


-- ========================================
-- [7] summary, then remove the staging tables
-- ========================================
DROP TABLE IF EXISTS public_health.test_gold.fact_facility_published__candidate;
DROP TABLE IF EXISTS public_health.test_gold.fact_facility_published__gates;
DROP TABLE IF EXISTS public_health.test_gold.fact_facility_published__inputs;

-- Silver control values (area ph, ownership total): PSA 9.18 hospitals 2024 = 1,312,
-- PSA 9.17 beds 2024 = 114,623, FHSIS BHS 2024 = 25,532 and 2025 = 26,944.
SELECT s.source_dataset, f.facility_type, min(p.year) AS first_year, max(p.year) AS last_year,
       count(*) AS row_count, count_if(f.value_status <> 'ok') AS no_report,
       max(CASE WHEN g.area_code = 'ph' AND f.ownership = 'total' AND p.year = 2024
                THEN coalesce(f.published_facility_count, f.published_authorized_beds) END) AS ph_total_2024
FROM public_health.test_gold.fact_facility_published AS f
INNER JOIN public_health.test_gold.dim_source AS s ON s.source_key = f.source_key
INNER JOIN public_health.test_gold.dim_period AS p ON p.period_key = f.period_key
INNER JOIN public_health.test_gold.dim_geography AS g ON g.area_key = f.area_key
GROUP BY s.source_dataset, f.facility_type ORDER BY s.source_dataset, f.facility_type;