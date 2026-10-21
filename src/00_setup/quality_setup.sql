-- =============================================================================
-- Data quality schema (public_health.quality) shared by all layers: bronze, silver, gold.
-- Keeps QC output out of the bronze / silver / gold schemas.
--
-- Tables
--   quality.check_registry    one row per check code (B01, S03, ...). Created empty here;
--                             filled by quality_registry_seed.sql in the setup job
--   quality.run_log           one row per QC execution (validation session)
--   quality.qc_results        one row per check result (agreed 21-column team format)
--   quality.profile           one row per column per profiled table per QC execution
--   quality.table_stats       one row per table per QC execution (rows, Delta version, size)
--   quality.quarantine        rows rejected by silver checks, kept as JSON
--   quality.build_log         one row per silver or gold build (succeeded or failed)
--   quality.build_inputs      one row per input file, sheet or table read by a successful build
--   quality.row_disposition   bronze rows a build read but did not load: duplicate, quarantined, dropped
-- Views
--   quality.v_latest_results  results of the latest QC execution per table and QC script
--   quality.v_table_health    one status per table (worst status of the latest run of every script)
--   quality.v_open_issues     latest results that are not PASS
--   quality.v_run_errors      QC scripts whose latest run crashed (status ERROR)
--   quality.v_latest_build    latest successful build per silver or gold table
--   quality.v_build_lineage   inputs of every successful build, with the build time (join target
--                             for silver rows: load time, load id, file checksum)
--   quality.v_qc_results_identity  qc_results with build_id, content_checksum and checked version
--   quality.v_build_reconciliation rows read, not loaded (by kind) and loaded, per input of each build
--   quality.v_check_attribute_override  check_id -> quality attribute (edit this list only)
--   quality.v_qc_results_attribute      qc_results plus its quality attribute
--   quality.v_quality_scorecard         latest QC per table x quality attribute
--
-- How to run
--   This file only CREATEs objects (IF NOT EXISTS / OR REPLACE VIEW), so "Run All"
--   is safe and re-running it changes no data. The setup job runs it on every pipeline run
--   (task setup_quality). Run it by hand after editing a view here. Views are computed when
--   queried, so they never need a rerun after a QC run.
--   The other two quality files:
--     quality_registry_seed.sql       setup job, right after this file, on every run.
--                                     Insert-only, so a rerun only adds missing codes
--     quality_migrate_bronze_qc.sql   once, by hand, to move old public_health.bronze.qc_results rows
--   QC scripts append to these tables (see dq_utils.py), so several domains can run QC at
--   the same time without Delta write conflicts. The one exception is quarantine: a QC run
--   replaces its own slice (layer, table, check, source table), so reruns do not duplicate rows.
--   Silver and gold builds only append to build_log and build_inputs
--
-- Changes
--   2026-10-21  registry is filled by the setup job (not "at the end"); gold G codes added to
--               v_check_attribute_override, so gold results no longer show as 'unmapped'
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

-- The table starts empty. quality_registry_seed.sql fills it in the setup job, right after
-- this file, on every run (insert-only). Scripts with strict_registry=False also work without
-- a registry row; with strict_registry=True an unregistered code stops the run.


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
-- dq_utils.quarantine() replaces the rows of its own slice (layer, table_name, check_id,
-- source_table) on every QC run, so this table holds the latest quarantined rows, not a history.
-- History: counts per run in qc_results, row references per build in row_disposition.
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
-- 7. Build records (lineage-qc-contract.md, sections 3.3 and 5)
-- -----------------------------------------------------------------------------
-- Silver rows carry only their address (_source_key, _source_file, _source_sheet,
-- _source_row_num) and _silver_build_id. Facts that are the same for every row of a file
-- (load time, load id, file checksum) and of a build (build time, code version) are stored
-- here once per build. Without these two tables those facts are not recorded anywhere.
--
-- Both tables are append-only:
--   build_log     one row appended when a build ends, succeeded or failed
--   build_inputs  rows appended only after a build succeeded

CREATE TABLE IF NOT EXISTS public_health.quality.build_log (
  build_id             STRING    COMMENT 'One id per build of one table; equals _silver_build_id / _gold_build_id on the rows',
  layer                STRING    COMMENT 'silver | gold',
  domain               STRING    COMMENT 'geography | facilities | workforce | diseases | socioeconomic | ...',
  target_table         STRING    COMMENT 'Full name: public_health.<layer>.<table>',
  started_at           TIMESTAMP COMMENT 'Build start (UTC)',
  finished_at          TIMESTAMP COMMENT 'Build end (UTC). For a succeeded build this is when the table was written',
  status               STRING    COMMENT 'succeeded | failed. A failed build did not replace the target table',
  row_count            BIGINT    COMMENT 'Rows written to the target table; null for a failed build',
  target_table_version BIGINT    COMMENT 'Delta version written by this build; null for a failed build',
  code_version         STRING    COMMENT 'Git commit of the transformation',
  parameters           STRING    COMMENT 'JSON: source dates, scenario parameters, config version',
  run_id               STRING    COMMENT 'Job run id, when run from a job',
  error_message        STRING    COMMENT 'Why the build failed (first 500 chars); null when succeeded'
)
USING DELTA
COMMENT 'One row per silver or gold build, succeeded or failed';

CREATE TABLE IF NOT EXISTS public_health.quality.build_inputs (
  build_id             STRING    COMMENT 'Build that read this input; joins to build_log',
  target_table         STRING    COMMENT 'Full name of the table the build wrote',
  input_kind           STRING    COMMENT 'bronze_source (a file or sheet in a bronze table) | table (a silver or reference table) | reference (a reviewed file in the repo)',
  input_table          STRING    COMMENT 'Full name of the table read; null for reference files',
  input_table_version  BIGINT    COMMENT 'Delta version read',
  source_key           STRING    COMMENT 'bronze_source inputs: _source_key',
  source_file          STRING    COMMENT 'bronze_source inputs: _source_file. reference inputs: path in the repo',
  source_sheet         STRING    COMMENT 'bronze_source inputs: _source_sheet; null for CSV sources (compare with <=>)',
  load_batch_id        STRING    COMMENT 'bronze_source inputs: ingestion_metadata.batch_id of the load that wrote the rows read',
  content_checksum     STRING    COMMENT 'bronze_source inputs: sha256 of the source file (ingestion_metadata.content_checksum)',
  ingested_at          TIMESTAMP COMMENT 'bronze_source inputs: _ingested_at of the rows read',
  input_rows           BIGINT    COMMENT 'Rows read from this input',
  reference_version    STRING    COMMENT 'reference inputs: Git commit of the file'
)
USING DELTA
COMMENT 'One row per input (file, sheet or table) read by a successful build';


-- Input accounting (contract section 7.1): the bronze rows a build read but did NOT load.
-- One row per such bronze row per build and target table: dropped, duplicate, quarantined or
-- merged. Loaded rows are not stored here: the silver rows already carry their bronze row
-- reference, and rows loaded per input = build_inputs.input_rows minus the rows here
-- (view v_build_reconciliation). Row references only, no source values, so it is safe for
-- restricted sources.
CREATE TABLE IF NOT EXISTS public_health.quality.row_disposition (
  build_id          STRING    COMMENT 'Build that read the row; joins to build_log',
  target_table      STRING    COMMENT 'Full name of the table the build wrote',
  source_key        STRING    COMMENT 'Bronze row: _source_key',
  source_file       STRING    COMMENT 'Bronze row: _source_file',
  source_sheet      STRING    COMMENT 'Bronze row: _source_sheet; null for CSV sources (compare with <=>)',
  source_row_num    INT       COMMENT 'Bronze row: _source_row_num',
  load_batch_id     STRING    COMMENT 'Load that wrote the bronze row. Kept here because a failed build has no build_inputs rows',
  content_checksum  STRING    COMMENT 'File version the row reference belongs to',
  disposition       STRING    COMMENT 'merged_into | duplicate_of | quarantined | dropped_non_data. (loaded is not stored; older builds may have such rows)',
  reason            STRING    COMMENT 'Why the row was not loaded, e.g. footnote, hxl_tag_row, area_unresolved',
  target_key        STRING    COMMENT 'JSON. duplicate_of: the retained bronze row. merged_into: the silver key',
  recorded_at       TIMESTAMP COMMENT 'When the disposition was written (UTC)'
)
USING DELTA
COMMENT 'Bronze rows a build read but did not load, per build and target table';


-- -----------------------------------------------------------------------------
-- 8. Views
-- -----------------------------------------------------------------------------

-- Results of the latest QC execution for each table AND QC script. Some tables are checked
-- by two scripts (a domain QC and silver_cross_domain_qc.py); "latest per table" alone would
-- let the newer script's run hide the other script's results. Notebook QC that writes
-- qc_results without a run_log row counts as one script per table.
CREATE OR REPLACE VIEW public_health.quality.v_latest_results
COMMENT 'Results of the latest QC execution per table and QC script'
AS
WITH runs AS (
  SELECT r.layer, r.table_name, r.validation_id, max(r.executed_at) AS executed_at,
         coalesce(max(l.script_name), '') AS script_name
  FROM public_health.quality.qc_results r
  LEFT JOIN public_health.quality.run_log l ON l.validation_id = r.validation_id
  WHERE r.table_name IS NOT NULL
  GROUP BY r.layer, r.table_name, r.validation_id
),
latest AS (
  SELECT layer, table_name, script_name, max_by(validation_id, executed_at) AS validation_id
  FROM runs
  GROUP BY layer, table_name, script_name
)
SELECT r.*
FROM public_health.quality.qc_results r
JOIN latest l
  ON r.layer = l.layer AND r.table_name = l.table_name AND r.validation_id = l.validation_id;

-- One status per table: FAIL if any latest check failed, else WARN, else PASS, across the
-- latest run of every script that checks the table. validation_id is the most recent of them.
-- A status other than PASS / WARN / FAIL (e.g. ERROR, SKIP from older scripts) is counted
-- in checks_other and treated as FAIL, so it can never roll up to an overall PASS.
CREATE OR REPLACE VIEW public_health.quality.v_table_health
COMMENT 'One status per table, from the latest QC execution of every script that checks it'
AS
SELECT
  layer,
  table_name,
  max_by(validation_id, executed_at)                      AS validation_id,
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
GROUP BY layer, table_name;

-- Only what needs attention.
CREATE OR REPLACE VIEW public_health.quality.v_open_issues
COMMENT 'Latest results per table that are not PASS (WARN, FAIL or any other status)'
AS
SELECT layer, table_name, source_key, check_id, check_name, check_type, column_name, admin_level,
       status, fail_count, total_count, fail_pct, threshold, observed, expected, detail, executed_at
FROM public_health.quality.v_latest_results
WHERE coalesce(status, '') <> 'PASS';


-- QC scripts whose LATEST run crashed. A crash row (B00/S00/G00) has no table_name, so it
-- does not show in the views above. Once the script runs cleanly again it drops out of
-- this view; the full crash history stays in run_log.
CREATE OR REPLACE VIEW public_health.quality.v_run_errors
COMMENT 'QC scripts whose latest run crashed (run_log status ERROR)'
AS
WITH latest AS (
  SELECT script_name, max_by(validation_id, started_at) AS validation_id
  FROM public_health.quality.run_log
  WHERE script_name IS NOT NULL
  GROUP BY script_name
)
SELECT r.validation_id, r.run_id, r.layer, r.domain, r.script_name, r.started_at, r.error_message
FROM public_health.quality.run_log r
JOIN latest l ON r.validation_id = l.validation_id
WHERE r.status = 'ERROR';

-- Latest successful build of each silver or gold table. Failed builds are never selected.
CREATE OR REPLACE VIEW public_health.quality.v_latest_build
COMMENT 'Latest successful build per silver or gold table'
AS
SELECT layer, domain, target_table, build_id, started_at, finished_at, row_count,
       target_table_version, code_version, parameters, run_id
FROM (
  SELECT *, row_number() OVER (PARTITION BY target_table ORDER BY finished_at DESC, build_id DESC) AS rn
  FROM public_health.quality.build_log
  WHERE status = 'succeeded'
) t
WHERE rn = 1;

-- Inputs of every successful build, with the build time. Join target for silver rows:
--   ON  v.build_id = s._silver_build_id AND v.target_table = '<full table name>'
--   AND v.source_key = s._source_key AND v.source_file = s._source_file
--   AND v.source_sheet <=> s._source_sheet
-- gives ingested_at, load_batch_id, content_checksum and silver_loaded_at for the row.
CREATE OR REPLACE VIEW public_health.quality.v_build_lineage
COMMENT 'Inputs of successful builds with build time; gives load time, load id and file checksum for a silver row'
AS
SELECT i.build_id, i.target_table, b.layer, b.domain,
       i.input_kind, i.input_table, i.input_table_version,
       i.source_key, i.source_file, i.source_sheet,
       i.load_batch_id, i.content_checksum, i.ingested_at, i.input_rows, i.reference_version,
       b.finished_at AS silver_loaded_at, b.target_table_version, b.code_version
FROM public_health.quality.build_inputs i
JOIN public_health.quality.build_log b
  ON b.build_id = i.build_id AND b.target_table = i.target_table AND b.status = 'succeeded';

-- qc_results with its identifiers as columns (lineage-qc-contract.md, section 8.1).
--   batch_id 'build:<id>'            -> build_id from the prefix (candidate validation, table-level checks)
--   batch_id '<source_key>:<sha256>' -> content_checksum; build_id through the checked table version
CREATE OR REPLACE VIEW public_health.quality.v_qc_results_identity
COMMENT 'qc_results plus build_id, content_checksum and the table version checked'
AS
SELECT r.*,
       coalesce(CASE WHEN r.batch_id LIKE 'build:%' THEN substr(r.batch_id, 7) END,
                b.build_id)                                                             AS build_id,
       CASE WHEN r.batch_id NOT LIKE 'build:%' THEN split_part(r.batch_id, ':', 2) END AS content_checksum,
       s.checked_table_version
FROM public_health.quality.qc_results r
LEFT JOIN (
  SELECT validation_id, table_name, max(delta_version) AS checked_table_version
  FROM public_health.quality.table_stats
  GROUP BY validation_id, table_name
) s ON s.validation_id = r.validation_id AND s.table_name = r.table_name
LEFT JOIN public_health.quality.build_log b
  ON b.target_table = r.table_name
 AND b.target_table_version = s.checked_table_version
 AND b.status = 'succeeded';

-- Input accounting per input of each successful build: rows read = rows loaded + rows not loaded.
-- rows_loaded is derived, because row_disposition stores only the rows that were not loaded.
-- A build that also wrote 'loaded' rows (older builds) gives the same numbers: they are ignored.
-- A merged row contributed to a silver row, so it counts as loaded; rows_merged shows how many.
CREATE OR REPLACE VIEW public_health.quality.v_build_reconciliation
COMMENT 'Per input of each successful build: rows read, rows not loaded by kind, rows loaded'
AS
SELECT i.build_id, i.target_table, i.input_table, i.source_key, i.source_file, i.source_sheet,
       i.input_rows                                               AS rows_read,
       coalesce(d.dropped_non_data, 0)                            AS rows_dropped_non_data,
       coalesce(d.duplicates, 0)                                  AS rows_duplicate,
       coalesce(d.quarantined, 0)                                 AS rows_quarantined,
       coalesce(d.merged, 0)                                      AS rows_merged,
       i.input_rows - coalesce(d.not_loaded, 0)                   AS rows_loaded
FROM public_health.quality.build_inputs i
JOIN public_health.quality.build_log b
  ON b.build_id = i.build_id AND b.target_table = i.target_table AND b.status = 'succeeded'
LEFT JOIN (
  SELECT build_id, target_table, source_key, source_file, source_sheet,
         count_if(disposition = 'dropped_non_data') AS dropped_non_data,
         count_if(disposition = 'duplicate_of')     AS duplicates,
         count_if(disposition = 'quarantined')      AS quarantined,
         count_if(disposition = 'merged_into')      AS merged,
         count_if(disposition NOT IN ('loaded', 'merged_into')) AS not_loaded
  FROM public_health.quality.row_disposition
  GROUP BY build_id, target_table, source_key, source_file, source_sheet
) d ON d.build_id = i.build_id AND d.target_table = i.target_table AND d.source_key = i.source_key
   AND d.source_file = i.source_file AND d.source_sheet <=> i.source_sheet
WHERE i.input_kind = 'bronze_source';


-- -----------------------------------------------------------------------------
-- 8b. Quality attributes (no table change)
-- -----------------------------------------------------------------------------
-- Labels every QC result with one of the programme's data-quality attributes:
--   accuracy | completeness | validity | consistency | timeliness | uniqueness |
--   auditability | business_rule
-- QC scripts keep writing check_type; the attribute is derived here (first match wins):
--   1. v_check_attribute_override: a check_id listed there (the code decides). Used where
--      check_type does not say the attribute, e.g. lineage checks stored as COMPLETENESS are
--      auditability, freshness checks stored as CONSISTENCY are timeliness.
--   2. check_type: COMPLETENESS, VALIDITY, CONSISTENCY, UNIQUENESS map to the same attribute;
--      RECONCILIATION -> completeness (row accounting); SCHEMA -> validity; EXECUTION -> auditability.
--      Types the geography / admin boundaries files use: ACCEPTED_VALUES, RANGE -> validity;
--      VOLUME -> completeness; REFERENTIAL_INTEGRITY -> consistency.
--   3. anything else -> 'unmapped' (it shows in v_quality_scorecard, so it gets an entry here).
--   gold_qc.py writes INTEGRITY, AUDITABILITY, TIMELINESS and BUSINESS_RULE, which step 2 does
--   not map, so every gold code with one of those types is listed in the override (2026-10-21).

CREATE OR REPLACE VIEW public_health.quality.v_check_attribute_override
COMMENT 'check_id -> quality attribute where check_type does not give it'
AS
SELECT * FROM VALUES
  -- accuracy: control totals and values against a trusted figure
  ('B11', 'accuracy'), ('S10', 'accuracy'), ('S21', 'accuracy'), ('S34', 'accuracy'),
  ('S56', 'accuracy'), ('S64', 'accuracy'), ('S65', 'accuracy'), ('S78', 'accuracy'),
  ('S84', 'accuracy'), ('GS08', 'accuracy'),
  -- auditability: lineage columns, build records, ingestion metadata
  ('B05', 'auditability'), ('B13', 'auditability'),
  ('S13', 'auditability'), ('S14', 'auditability'), ('S15', 'auditability'), ('S17', 'auditability'),
  ('S19', 'auditability'), ('S20', 'auditability'),
  ('S30', 'auditability'), ('S31', 'auditability'), ('S32', 'auditability'),
  ('S51', 'auditability'),
  ('S60', 'auditability'), ('S61', 'auditability'), ('S62', 'auditability'), ('S74', 'auditability'),
  ('S75', 'auditability'),
  ('S80', 'auditability'), ('S81', 'auditability'), ('S82', 'auditability'), ('S85', 'auditability'),
  ('S89', 'auditability'),
  -- timeliness: silver built from the current loads, data recent enough
  ('S16', 'timeliness'), ('S33', 'timeliness'), ('S57', 'timeliness'), ('S63', 'timeliness'),
  ('S83', 'timeliness'), ('S98', 'timeliness'),
  -- consistency: totals vs parts that are typed RECONCILIATION
  ('S26', 'consistency'), ('S38', 'consistency'), ('S46', 'consistency'), ('S55', 'consistency'),
  ('S68', 'consistency'), ('S91', 'consistency'),
  -- business rules: team-owned rules and plausibility bands
  ('S23', 'business_rule'), ('S24', 'business_rule'), ('S25', 'business_rule'), ('S47', 'business_rule'),
  ('S58', 'business_rule'), ('S67', 'business_rule'), ('S72', 'business_rule'), ('S94', 'business_rule'),
  ('S95', 'business_rule'), ('S97', 'business_rule'),
  -- gold (gold_qc.py): codes whose check_type step 2 does not map, plus the control totals
  ('G04', 'consistency'), ('G05', 'auditability'), ('G06', 'timeliness'),
  ('G07', 'accuracy'), ('G10', 'business_rule'), ('G13', 'business_rule')
AS t(check_id, quality_attribute);

CREATE OR REPLACE VIEW public_health.quality.v_qc_results_attribute
COMMENT 'qc_results plus the quality attribute of each check (no table change)'
AS
SELECT r.*,
       coalesce(o.quality_attribute,
                CASE upper(r.check_type)
                  WHEN 'COMPLETENESS'   THEN 'completeness'
                  WHEN 'VALIDITY'       THEN 'validity'
                  WHEN 'CONSISTENCY'    THEN 'consistency'
                  WHEN 'UNIQUENESS'     THEN 'uniqueness'
                  WHEN 'RECONCILIATION' THEN 'completeness'
                  WHEN 'SCHEMA'         THEN 'validity'
                  WHEN 'EXECUTION'      THEN 'auditability'
                  -- types used by the geography and admin boundaries notebooks and QC
                  WHEN 'ACCEPTED_VALUES'       THEN 'validity'
                  WHEN 'RANGE'                 THEN 'validity'
                  WHEN 'VOLUME'                THEN 'completeness'
                  WHEN 'REFERENTIAL_INTEGRITY' THEN 'consistency'
                END,
                'unmapped')                                        AS quality_attribute,
       CASE WHEN o.check_id IS NOT NULL THEN 'override' ELSE 'check_type' END AS attribute_source
FROM public_health.quality.qc_results r
LEFT JOIN public_health.quality.v_check_attribute_override o ON o.check_id = r.check_id;

-- One row per table x attribute, from the latest QC execution of every script that checks the
-- table (v_latest_results). An attribute with no row for a table means no check covers it yet.
CREATE OR REPLACE VIEW public_health.quality.v_quality_scorecard
COMMENT 'Latest QC per table and quality attribute: checks and worst status'
AS
SELECT a.layer, a.table_name, a.quality_attribute,
       count(*)                                         AS checks_total,
       count_if(a.status = 'PASS')                      AS checks_pass,
       count_if(a.status = 'WARN')                      AS checks_warn,
       count_if(a.status = 'FAIL')                      AS checks_fail,
       CASE WHEN count_if(coalesce(a.status, '') NOT IN ('PASS', 'WARN')) > 0 THEN 'FAIL'
            WHEN count_if(a.status = 'WARN') > 0 THEN 'WARN'
            ELSE 'PASS' END                             AS attribute_status,
       concat_ws(', ', sort_array(collect_set(a.check_id))) AS check_ids,
       max(a.executed_at)                               AS last_checked_at
FROM public_health.quality.v_qc_results_attribute a
JOIN (SELECT DISTINCT validation_id, table_name FROM public_health.quality.v_latest_results) l
  ON l.validation_id = a.validation_id AND l.table_name = a.table_name
GROUP BY a.layer, a.table_name, a.quality_attribute;

-- Example: attributes no check covers yet, per silver table
-- WITH attrs AS (SELECT explode(array('accuracy','completeness','validity','consistency','timeliness',
--                                     'uniqueness','auditability','business_rule')) AS quality_attribute),
--      tables AS (SELECT DISTINCT table_name FROM public_health.quality.v_quality_scorecard WHERE layer = 'silver')
-- SELECT t.table_name, a.quality_attribute
-- FROM tables t CROSS JOIN attrs a
-- LEFT ANTI JOIN public_health.quality.v_quality_scorecard s
--   ON s.table_name = t.table_name AND s.quality_attribute = a.quality_attribute AND s.layer = 'silver'
-- ORDER BY 1, 2;


-- -----------------------------------------------------------------------------
-- 9. Notes (nothing to run)
-- -----------------------------------------------------------------------------
-- * Python QC scripts write through dq_utils.DQRun (same folder as the QC scripts).
-- * table_name is always the full name: public_health.<layer>.<table>. The views group
--   by it, so a short name and a full name for the same table would show up twice.
-- * A new check needs a code (B13, S14, ...) plus check_name and check_type passed to
--   dq.record(). Add the code to quality_registry_seed.sql in the same pull request: with
--   strict_registry=True an unregistered code stops the run. Keep codes unique per layer.
-- * A new check whose attribute is not clear from its check_type: add its code to
--   v_check_attribute_override (section 8b) and re-run this file.
-- * build_log.build_id is one id per build of ONE table. A job that builds three tables
--   writes three build_log rows.
-- * A build never updates or deletes rows here. A rebuilt table gets a new build_id; the
--   old build's rows stay as history.