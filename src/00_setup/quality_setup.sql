-- =============================================================================
-- Data quality schema (public_health.quality) shared by all layers.
-- Keeps QC output out of the bronze / silver / gold schemas.
-- RUN once only to setup QC tables.
--
-- Tables
--   quality.check_registry    one row per check code (B01, S03, ...). Created empty now,
--                             filled at the end (section 10) from the checks actually used
--   quality.run_log           one row per QC execution (validation session)
--   quality.qc_results        one row per check result (agreed team format, moved from bronze)
--   quality.profile           one row per column per profiled table per QC execution
--   quality.table_stats       one row per table per QC execution (rows, Delta version, size)
--   quality.quarantine        rows rejected by silver checks, kept as JSON
-- Views
--   quality.v_latest_results  results of the latest QC execution per table
--   quality.v_table_health    one status per table (worst status of its latest checks)
--   quality.v_open_issues     latest WARN / FAIL results only
--
-- How to run
--   Now:     run sections 0-7 once (safe to re-run). Run section 8 once to move the old
--            public_health.bronze.qc_results rows. Section 9 is notes.
--   At the end (checks settled): run section 10 to fill the registry, then set
--            strict_registry=True in the QC scripts.
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

-- The table starts EMPTY. It is filled at the end (section 10), once the checks
--  are settled. QC scripts work without it until then.


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
CREATE OR REPLACE VIEW public_health.quality.v_table_health
COMMENT 'One status per table, from its latest QC execution'
AS
SELECT
  layer,
  table_name,
  validation_id,
  max(executed_at)          AS last_checked_at,
  count(*)                  AS checks_total,
  count_if(status = 'PASS') AS checks_pass,
  count_if(status = 'WARN') AS checks_warn,
  count_if(status = 'FAIL') AS checks_fail,
  CASE WHEN count_if(status = 'FAIL') > 0 THEN 'FAIL'
       WHEN count_if(status = 'WARN') > 0 THEN 'WARN'
       ELSE 'PASS' END      AS overall_status
FROM public_health.quality.v_latest_results
GROUP BY layer, table_name, validation_id;

-- Only what needs attention.
CREATE OR REPLACE VIEW public_health.quality.v_open_issues
COMMENT 'Latest WARN / FAIL results per table'
AS
SELECT layer, table_name, source_key, check_id, check_name, check_type, column_name, admin_level,
       status, fail_count, total_count, fail_pct, threshold, observed, expected, detail, executed_at
FROM public_health.quality.v_latest_results
WHERE status <> 'PASS';




-- -----------------------------------------------------------------------------
-- 8. After setup
-- -----------------------------------------------------------------------------
-- * QC scripts write through dq_utils.DQRun (same folder as the QC scripts).
-- * In each sources_*.yaml, point defaults.qc_results_table to public_health.quality.qc_results
--   (only needed while a script still writes results itself).
-- * Until section 10 is run, a new check only needs a code (B13, S14, ...) plus
--   check_name and check_type passed to dq.record(). Keep codes unique per layer.
-- * Grant the team read access to the dashboard if a data-health page is added:
--   GRANT SELECT ON SCHEMA public_health.quality TO `<group>`;


-- -----------------------------------------------------------------------------
-- 10. Fill the check registry (run AT THE END, once the checks are settled)
-- -----------------------------------------------------------------------------

-- 10a. Starter list: bronze checks already in *_bronze_qc.py and a planned silver set.
--      Edit names, types, severities and thresholds here before running.
--      Insert-only, so later edits made in the table are not overwritten on re-run.
MERGE INTO public_health.quality.check_registry AS t
USING (
  SELECT check_id, layer, domain, check_name, check_type, default_severity,
         CAST(default_threshold AS DOUBLE) AS default_threshold, description
  FROM VALUES
    -- bronze (at rest, faithful to source; no business rules)
    ('B00', 'bronze', 'ALL', 'QC ran without error',             'EXECUTION',      'FAIL', 0, 'Script error while checking a source; detail holds the error text'),
    ('B01', 'bronze', 'ALL', 'table exists and has rows',        'COMPLETENESS',   'FAIL', 0, 'Bronze table exists and row count > 0'),
    ('B02', 'bronze', 'ALL', 'all listed files loaded',          'COMPLETENESS',   'FAIL', 0, 'Every file listed in the YAML appears in _source_file'),
    ('B03', 'bronze', 'ALL', 'row count matches expected',       'RECONCILIATION', 'FAIL', 0, 'Rows per file equal qc.expected_rows'),
    ('B04', 'bronze', 'ALL', 'required columns present',         'SCHEMA',         'FAIL', 0, 'Columns from columns / column_map exist in the table'),
    ('B05', 'bronze', 'ALL', 'lineage columns not null',         'COMPLETENESS',   'FAIL', 0, '_source_key, _source_file, _source_row_num, _as_of_date, _ingested_at never null'),
    ('B06', 'bronze', 'ALL', 'row number unique per file',       'UNIQUENESS',     'FAIL', 0, 'One row per file, sheet and _source_row_num (catches double loads)'),
    ('B07', 'bronze', 'ALL', 'no fully empty rows',              'COMPLETENESS',   'WARN', 0, 'No rows where every data column is blank'),
    ('B08', 'bronze', 'ALL', 'no exact duplicate rows',          'UNIQUENESS',     'WARN', 0, 'No identical data rows within a file and sheet'),
    ('B09', 'bronze', 'ALL', 'no rescued values',                'SCHEMA',         'WARN', 0, '_rescued_data is null (no rows wider than the header)'),
    ('B10', 'bronze', 'ALL', 'numeric column parses',            'VALIDITY',       'WARN', 0, 'qc.numeric_columns can be read as numbers'),
    ('B11', 'bronze', 'ALL', 'control totals / values match',    'RECONCILIATION', 'FAIL', 0, 'Sums or known values match the published source (latest version)'),
    ('B12', 'bronze', 'ALL', 'total equals sum of parts',        'CONSISTENCY',    'FAIL', 0, 'qc.row_sum total column equals the sum of its parts'),
    -- silver (business rules; starter set, edit thresholds as the team decides)
    ('S00', 'silver', 'ALL', 'QC ran without error',             'EXECUTION',      'FAIL', 0, 'Script error while checking a table; detail holds the error text'),
    ('S01', 'silver', 'ALL', 'table exists and has rows',        'COMPLETENESS',   'FAIL', 0, 'Silver table exists and row count > 0'),
    ('S02', 'silver', 'ALL', 'grain key not null',               'COMPLETENESS',   'FAIL', 0, 'No nulls in any column of the documented grain'),
    ('S03', 'silver', 'ALL', 'grain key unique',                 'UNIQUENESS',     'FAIL', 0, 'One row per documented grain, e.g. (psgc_code, census_year)'),
    ('S04', 'silver', 'ALL', 'PSGC code found in geography',     'CONSISTENCY',    'WARN', 0, 'psgc_code exists in the geography silver table; WARN because older files may use retired or renamed codes'),
    ('S05', 'silver', 'ALL', 'admin level valid',                'VALIDITY',       'FAIL', 0, 'admin_level in 0-4 and consistent with the PSGC code'),
    ('S06', 'silver', 'ALL', 'counts non-negative',              'VALIDITY',       'FAIL', 0, 'Count metrics (cases, deaths, beds, population) >= 0'),
    ('S07', 'silver', 'ALL', 'rates within range',               'VALIDITY',       'WARN', 0, 'Percentages / rates within their valid range, e.g. 0-100'),
    ('S08', 'silver', 'ALL', 'period within expected range',     'VALIDITY',       'FAIL', 0, 'Year / week / date within the range the source covers'),
    ('S09', 'silver', 'ALL', 'bronze to silver rows reconcile',  'RECONCILIATION', 'FAIL', 0, 'Bronze rows in = silver rows + quarantined + intentionally filtered (filtered count in detail)'),
    ('S10', 'silver', 'ALL', 'metric totals preserved',          'RECONCILIATION', 'FAIL', 0, 'Sum of a metric in silver equals the same sum from bronze (no rows lost or doubled)'),
    ('S11', 'silver', 'ALL', 'accepted values',                  'VALIDITY',       'WARN', 0, 'Codes / categories are in the reference list (e.g. disease_key, ownership, service level)'),
    ('S12', 'silver', 'ALL', 'metric null rate under threshold', 'COMPLETENESS',   'WARN', 0.05, 'Share of null values in a key metric column stays under the threshold'),
    -- gold
    ('G00', 'gold',   'ALL', 'QC ran without error',             'EXECUTION',      'FAIL', 0, 'Script error while checking a table; detail holds the error text')
  AS v(check_id, layer, domain, check_name, check_type, default_severity, default_threshold, description)
) AS s
ON t.check_id = s.check_id
WHEN NOT MATCHED THEN INSERT
  (check_id, layer, domain, check_name, check_type, default_severity, default_threshold, description, is_active, updated_at)
VALUES
  (s.check_id, s.layer, s.domain, s.check_name, s.check_type, s.default_severity, s.default_threshold, s.description, true, current_timestamp());

-- 10b. Add every other code that appears in qc_results but is not in the list above
--      (most common name / type / severity per code). Review these rows afterwards.
INSERT INTO public_health.quality.check_registry
SELECT
  check_id,
  max(layer)                                         AS layer,
  'ALL'                                              AS domain,
  mode(check_name)                                   AS check_name,
  mode(check_type)                                   AS check_type,
  coalesce(mode(severity), 'FAIL')                   AS default_severity,
  coalesce(mode(threshold), 0)                       AS default_threshold,
  'Added from qc_results; review description'        AS description,
  true                                               AS is_active,
  current_timestamp()                                AS updated_at
FROM public_health.quality.qc_results
WHERE check_id IS NOT NULL
  AND check_id NOT IN (SELECT check_id FROM public_health.quality.check_registry)
GROUP BY check_id;

-- 10c. Fill gaps in past results from the registry (e.g. migrated rows with no check_type).
MERGE INTO public_health.quality.qc_results AS r
USING public_health.quality.check_registry AS g
ON r.check_id = g.check_id AND (r.check_type IS NULL OR r.severity IS NULL)
WHEN MATCHED THEN UPDATE SET
  r.check_type = coalesce(r.check_type, g.check_type),
  r.severity   = coalesce(r.severity, g.default_severity);

-- 10d. Review: codes used with more than one name or type (should be one meaning per code).
SELECT check_id, collect_set(check_name) AS names, collect_set(check_type) AS types
FROM public_health.quality.qc_results
GROUP BY check_id
HAVING size(collect_set(check_name)) > 1 OR size(collect_set(check_type)) > 1;

-- 10e. Then set strict_registry=True in DQRun(...) so unknown codes are rejected from now on.