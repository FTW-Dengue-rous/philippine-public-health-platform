-- =============================================================================
-- Data quality schema (public_health.quality) shared by all layers: bronze, silver, gold.
-- Run once to create tables and views for quality checks.

-- Tables
--   quality.check_registry    one row per check code (B01, S03, ...). Created empty;
--                             filled at the end by quality_registry_seed.sql
--   quality.run_log           one row per QC execution (validation session)
--   quality.qc_results        one row per check result (agreed 21-column team format)
--   quality.profile           one row per column per profiled table per QC execution
--   quality.table_stats       one row per table per QC execution (rows, Delta version, size)
--   quality.quarantine        rows rejected by silver checks, kept as JSON
-- Views
--   quality.v_latest_results  results of the latest QC execution per table
--   quality.v_table_health    one status per table (worst status of its latest checks)
--   quality.v_open_issues     latest results that are not PASS
--   quality.v_run_errors      QC scripts whose latest run crashed (status ERROR)
--
-- How to run
--   This file only CREATEs objects (IF NOT EXISTS / OR REPLACE VIEW), so "Run All"
--   is safe and re-running it changes no data.
--   The other two quality files are run separately, step by step (not "Run All"):
--     quality_migrate_bronze_qc.sql   once, to move old public_health.bronze.qc_results rows
--     quality_registry_seed.sql       at the end of the project, to fill check_registry
--   QC scripts only append to these tables (see dq_utils.py), so several domains
--   can run QC at the same time without Delta write conflicts.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Schema
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS public_health.quality
  COMMENT 'Data quality: check registry, QC results, profiling, table stats, quarantine (all layers)';


-- -----------------------------------------------------------------------------
-- 1. Check registry
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public_health.quality.check_registry (
  check_id           STRING    COMMENT 'Stable code: B## bronze, S## silver, G## gold. Never reuse a retired code',
  layer              STRING    COMMENT 'bronze | silver | gold',
  domain             STRING    COMMENT 'ALL, or a domain name for domain-specific checks',
  check_name         STRING    COMMENT 'Readable name',
  check_type         STRING    COMMENT 'COMPLETENESS | SCHEMA | UNIQUENESS | VALIDITY | CONSISTENCY | RECONCILIATION | EXECUTION',
  default_severity   STRING    COMMENT 'WARN | FAIL (outcome if the check fails)',
  default_threshold  DOUBLE    COMMENT 'Max allowed fail_pct before the check fails; 0 = no failing rows allowed',
  description        STRING    COMMENT 'What the check tests and why',
  is_active          BOOLEAN   COMMENT 'false = retired; with strict_registry=True, QC scripts reject inactive codes',
  updated_at         TIMESTAMP COMMENT 'Last change to this row (UTC)'
)
USING DELTA
COMMENT 'One row per data quality check code, all layers';

-- The table starts EMPTY. It is filled at the end (quality_registry_seed.sql), once the
-- checks are settled. QC scripts work without it until then.


-- -----------------------------------------------------------------------------
-- 2. Run log
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public_health.quality.run_log (
  validation_id   STRING    COMMENT 'DQ validation session (one per QC execution); joins to qc_results',
  run_id          STRING    COMMENT 'Notebook/job run that executed the process ({{job.run_id}} when run as a job)',
  layer           STRING    COMMENT 'bronze | silver | gold',
  domain          STRING    COMMENT 'geography | population | facilities | workforce | diseases | socioeconomic | vaccination | ...',
  script_name     STRING    COMMENT 'QC script that ran, e.g. diseases_bronze_qc.py',
  source_keys     STRING    COMMENT 'Comma-separated YAML source keys checked, or ALL',
  started_at      TIMESTAMP COMMENT 'QC start (UTC)',
  ended_at        TIMESTAMP COMMENT 'QC end (UTC)',
  status          STRING    COMMENT 'PASS | WARN | FAIL | ERROR (script crashed) | NO_CHECKS',
  checks_total    INT       COMMENT 'Check results written',
  checks_pass     INT       COMMENT 'Results with status PASS',
  checks_warn     INT       COMMENT 'Results with status WARN',
  checks_fail     INT       COMMENT 'Results with status FAIL',
  tables_checked  INT       COMMENT 'Distinct tables checked',
  code_version    STRING    COMMENT 'Git commit or tag of the QC code, if passed',
  error_message   STRING    COMMENT 'Error text (first 500 chars) when status = ERROR'
)
USING DELTA
COMMENT 'One row per QC execution (validation session), all layers';


-- -----------------------------------------------------------------------------
-- 3. QC results (agreed team format)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public_health.quality.qc_results (
  run_id        STRING    COMMENT 'Notebook/job run that executed the process',
  validation_id STRING    COMMENT 'DQ validation session (one per QC execution)',
  batch_id      STRING    COMMENT 'Source data version checked: source_key:sha256. Null for table-level checks',
  source_key    STRING    COMMENT 'YAML source key / dataset',
  table_name    STRING    COMMENT 'Table checked',
  layer         STRING    COMMENT 'bronze | silver | gold',
  executed_at   TIMESTAMP COMMENT 'When the check ran (UTC)',
  check_id      STRING    COMMENT 'Stable code from quality.check_registry, e.g. B06',
  check_name    STRING    COMMENT 'Readable name',
  check_type    STRING    COMMENT 'COMPLETENESS | SCHEMA | UNIQUENESS | VALIDITY | CONSISTENCY | RECONCILIATION | EXECUTION',
  column_name   STRING    COMMENT 'Column checked, null if not column-specific',
  admin_level   INT       COMMENT '0 national, 1 region, 2 province, 3 city/muni, 4 barangay; null if not per level',
  status        STRING    COMMENT 'PASS | WARN | FAIL',
  severity      STRING    COMMENT 'WARN | FAIL (outcome if the check fails)',
  fail_count    BIGINT    COMMENT 'Rows failing (count-based checks)',
  total_count   BIGINT    COMMENT 'Rows evaluated (count-based checks)',
  fail_pct      DOUBLE    COMMENT 'fail_count / total_count',
  threshold     DOUBLE    COMMENT 'Max allowed fail_pct; default 0',
  observed      STRING    COMMENT 'Actual value (value checks only)',
  expected      STRING    COMMENT 'Expected value (value checks only)',
  detail        STRING    COMMENT 'Free text incl. file/sheet subset, first 500 chars'
)
USING DELTA
COMMENT 'One row per data quality check result, all layers';


-- -----------------------------------------------------------------------------
-- 4. Column profile
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public_health.quality.profile (
  run_id          STRING    COMMENT 'Notebook/job run that executed the process',
  validation_id   STRING    COMMENT 'DQ validation session; joins to run_log and qc_results',
  layer           STRING    COMMENT 'bronze | silver | gold',
  table_name      STRING    COMMENT 'Table profiled',
  row_filter      STRING    COMMENT 'WHERE clause applied before profiling, null = whole table',
  column_name     STRING    COMMENT 'Column profiled',
  data_type       STRING    COMMENT 'Spark data type',
  row_count       BIGINT    COMMENT 'Rows profiled',
  null_count      BIGINT    COMMENT 'Null values',
  null_pct        DOUBLE    COMMENT 'null_count / row_count',
  blank_count     BIGINT    COMMENT 'Non-null values that are empty after trim (matters for string bronze columns)',
  distinct_count  BIGINT    COMMENT 'Approximate distinct values (approx_count_distinct)',
  min_value       STRING    COMMENT 'Minimum (as string, first 200 chars). String columns sort as text',
  max_value       STRING    COMMENT 'Maximum (as string, first 200 chars). String columns sort as text',
  profiled_at     TIMESTAMP COMMENT 'When the profile ran (UTC)'
)
USING DELTA
COMMENT 'One row per column per profiled table per QC execution';


-- -----------------------------------------------------------------------------
-- 5. Table stats (volume and version history)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public_health.quality.table_stats (
  run_id          STRING    COMMENT 'Notebook/job run that executed the process',
  validation_id   STRING    COMMENT 'DQ validation session',
  layer           STRING    COMMENT 'bronze | silver | gold',
  table_name      STRING    COMMENT 'Table measured',
  delta_version   BIGINT    COMMENT 'Delta table version at capture time (for time travel back to what was checked)',
  row_count       BIGINT    COMMENT 'Rows in the table',
  column_count    INT       COMMENT 'Columns in the table',
  num_files       BIGINT    COMMENT 'Data files (DESCRIBE DETAIL)',
  size_bytes      BIGINT    COMMENT 'Table size (DESCRIBE DETAIL)',
  captured_at     TIMESTAMP COMMENT 'When the stats were taken (UTC)'
)
USING DELTA
COMMENT 'One row per table per QC execution; used for row-count drift and bronze-to-silver reconciliation';


-- -----------------------------------------------------------------------------
-- 6. Quarantine (rejected silver rows)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public_health.quality.quarantine (
  run_id          STRING    COMMENT 'Notebook/job run that executed the process',
  validation_id   STRING    COMMENT 'DQ validation session',
  layer           STRING    COMMENT 'Layer of the target table (usually silver)',
  table_name      STRING    COMMENT 'Target table the row was kept out of',
  source_table    STRING    COMMENT 'Table the row came from (usually bronze)',
  check_id        STRING    COMMENT 'Check that rejected the row (from quality.check_registry)',
  reason          STRING    COMMENT 'Short reason, e.g. psgc_code not found',
  record_key      STRING    COMMENT 'Key columns as JSON, e.g. {"psgc_code":"0102800000","year":2024}',
  record          STRING    COMMENT 'Whole row as JSON',
  quarantined_at  TIMESTAMP COMMENT 'When the row was quarantined (UTC)'
)
USING DELTA
COMMENT 'Rows rejected by QC, kept as JSON so one table serves every domain';


-- -----------------------------------------------------------------------------
-- 7. Views
-- -----------------------------------------------------------------------------

-- Results of the latest QC execution for each table.
CREATE OR REPLACE VIEW public_health.quality.v_latest_results
COMMENT 'Results of the latest QC execution per table'
AS
WITH latest AS (
  SELECT layer, table_name, max_by(validation_id, executed_at) AS validation_id
  FROM public_health.quality.qc_results
  WHERE table_name IS NOT NULL
  GROUP BY layer, table_name
)
SELECT r.*
FROM public_health.quality.qc_results r
JOIN latest l
  ON r.layer = l.layer AND r.table_name = l.table_name AND r.validation_id = l.validation_id;

-- One status per table: FAIL if any latest check failed, else WARN, else PASS.
-- A status other than PASS / WARN / FAIL (e.g. ERROR, SKIP from older scripts) is counted
-- in checks_other and treated as FAIL, so it can never roll up to an overall PASS.
CREATE OR REPLACE VIEW public_health.quality.v_table_health
COMMENT 'One status per table, from its latest QC execution'
AS
SELECT
  layer,
  table_name,
  validation_id,
  max(executed_at)                                        AS last_checked_at,
  count(*)                                                AS checks_total,
  count_if(status = 'PASS')                               AS checks_pass,
  count_if(status = 'WARN')                               AS checks_warn,
  count_if(status = 'FAIL')                               AS checks_fail,
  count_if(coalesce(status, '') NOT IN ('PASS', 'WARN', 'FAIL')) AS checks_other,
  CASE WHEN count_if(coalesce(status, '') NOT IN ('PASS', 'WARN')) > 0 THEN 'FAIL'
       WHEN count_if(status = 'WARN') > 0 THEN 'WARN'
       ELSE 'PASS' END                                    AS overall_status
FROM public_health.quality.v_latest_results
GROUP BY layer, table_name, validation_id;

-- Only what needs attention.
CREATE OR REPLACE VIEW public_health.quality.v_open_issues
COMMENT 'Latest results per table that are not PASS (WARN, FAIL or any other status)'
AS
SELECT layer, table_name, source_key, check_id, check_name, check_type, column_name, admin_level,
       status, fail_count, total_count, fail_pct, threshold, observed, expected, detail, executed_at
FROM public_health.quality.v_latest_results
WHERE coalesce(status, '') <> 'PASS';

-- QC scripts whose latest run crashed. A crash row (B00 / S00 / G00) has no table_name,
-- so it never shows in the views above; this view reads run_log instead.
CREATE OR REPLACE VIEW public_health.quality.v_run_errors
COMMENT 'QC scripts whose latest run crashed (run_log status = ERROR)'
AS
WITH latest AS (
  SELECT layer, domain, script_name, max_by(validation_id, started_at) AS validation_id
  FROM public_health.quality.run_log
  GROUP BY layer, domain, script_name
)
SELECT r.validation_id, r.run_id, r.layer, r.domain, r.script_name, r.source_keys,
       r.started_at, r.ended_at, r.error_message
FROM public_health.quality.run_log r
JOIN latest l ON r.validation_id = l.validation_id
WHERE r.status = 'ERROR';


-- -----------------------------------------------------------------------------
-- 8. Notes (nothing to run)
-- -----------------------------------------------------------------------------
-- * Python QC scripts write through dq_utils.DQRun (same folder as the QC scripts).
-- * table_name is always the full name: public_health.<layer>.<table>. The views group
--   by it, so a short name and a full name for the same table would show up twice.
-- * Until quality_registry_seed.sql is run, a new check only needs a code (B13, S14, ...)
--   plus check_name and check_type passed to dq.record(). Keep codes unique per layer.
