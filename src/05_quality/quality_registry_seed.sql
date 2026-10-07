-- =============================================================================
-- Fills public_health.quality.check_registry. Run AT THE END of the pipeline, once the
-- checks are settled. Not part of quality_setup.sql on purpose,
-- so a "Run All" of the setup never fills the registry early or updates qc_results.
--
-- How to run
--   Step by step, in order. Each step is safe to re-run:
--   Step 1 inserts only missing codes, Step 2 only codes still missing, and Step 3 only
--   fills values that are null.
--   Step 1  starter list (edit it first)
--   Step 2  add any other code found in qc_results
--   Step 3  fill check_type / severity gaps in past results (e.g. migrated rows)
--   Step 4  review codes used with more than one meaning
--   Step 5  switch QC scripts to strict_registry=True
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Step 1. Starter list: bronze checks already in *_bronze_qc.py and a planned silver set.
--         Edit names, types, severities and thresholds here before running.
--         Insert-only, so edits already made in the table are not overwritten.
-- -----------------------------------------------------------------------------
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


-- -----------------------------------------------------------------------------
-- Step 2. Add every other code that appears in qc_results but is not registered yet
--         (most common name / type / severity per code). Review these rows afterwards.
-- -----------------------------------------------------------------------------
INSERT INTO public_health.quality.check_registry
SELECT
  r.check_id,
  max(r.layer)                                       AS layer,
  'ALL'                                              AS domain,
  mode(r.check_name)                                 AS check_name,
  mode(r.check_type)                                 AS check_type,
  coalesce(mode(r.severity), 'FAIL')                 AS default_severity,
  coalesce(mode(r.threshold), 0)                     AS default_threshold,
  'Added from qc_results; review description'        AS description,
  true                                               AS is_active,
  current_timestamp()                                AS updated_at
FROM public_health.quality.qc_results r
WHERE r.check_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public_health.quality.check_registry g
                  WHERE g.check_id = r.check_id)
GROUP BY r.check_id;


-- -----------------------------------------------------------------------------
-- Step 3. Fill gaps in past results from the registry (e.g. migrated rows with no
--         check_type). Only null values are filled; nothing else is changed.
-- -----------------------------------------------------------------------------
MERGE INTO public_health.quality.qc_results AS r
USING public_health.quality.check_registry AS g
ON r.check_id = g.check_id AND (r.check_type IS NULL OR r.severity IS NULL)
WHEN MATCHED THEN UPDATE SET
  r.check_type = coalesce(r.check_type, g.check_type),
  r.severity   = coalesce(r.severity, g.default_severity);


-- -----------------------------------------------------------------------------
-- Step 4. Review: codes used with more than one name or type (one meaning per code).
-- -----------------------------------------------------------------------------
SELECT check_id, layer, collect_set(check_name) AS names, collect_set(check_type) AS types
FROM public_health.quality.qc_results
GROUP BY check_id, layer
HAVING size(collect_set(check_name)) > 1 OR size(collect_set(check_type)) > 1
ORDER BY check_id;


-- -----------------------------------------------------------------------------
-- Step 5. Set strict_registry=True in DQRun(...) in every QC script, so codes that
--         are not in the registry are rejected from now on. (Nothing to run here.)
-- -----------------------------------------------------------------------------
