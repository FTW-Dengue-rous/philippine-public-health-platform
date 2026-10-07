-- =============================================================================
-- Moves old QC results from public_health.bronze.qc_results into
-- public_health.quality.qc_results, and backfills quality.run_log.
--
-- How to run
--   Run STEP BY STEP, not "Run All". Run quality_setup.sql first.
--   Step 1  read-only checks: decide which option to use and confirm names / statuses
--   Step 2  remove the /* */ around ONE option (A or B) and run it
--   Step 3  backfill run_log
--   Step 4  verify, then drop the old table
--   Steps 2 and 3 are guarded (NOT EXISTS), so running them again does not duplicate
--   rows; a re-run only picks up old rows that were not copied yet.
--   Point every QC script to public_health.quality.qc_results before Step 4, so
--   nothing new lands in the old table after it is dropped.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Step 1. Checks (read-only)
-- -----------------------------------------------------------------------------

-- 1a. Format: 11 columns (checked_at, details) = Option A; 21 columns = Option B.
--     Also check the types: checked_at must cast to TIMESTAMP.
DESCRIBE public_health.bronze.qc_results;

-- 1b. Table names. The migration turns short names into full names
--     (diseases_x_bronze -> public_health.bronze.diseases_x_bronze). Compare with
--     the "migrated_as" column; it must match what the QC scripts write today.
SELECT DISTINCT
  layer,
  table_name,
  CASE WHEN table_name LIKE '%.%.%' THEN table_name
       WHEN table_name LIKE '%.%'   THEN concat('public_health.', table_name)
       ELSE concat('public_health.', layer, '.', table_name) END AS migrated_as
FROM public_health.bronze.qc_results
ORDER BY 1, 2;

-- 1c. Status values. Anything other than PASS / WARN / FAIL (ERROR, SKIP, lower case)
--     is shown here. The migration upper-cases and trims it; other values are kept
--     and the views treat them as FAIL.
SELECT status, count(*) AS n
FROM public_health.bronze.qc_results
GROUP BY status
ORDER BY status;

-- 1d. Domain that the run_log backfill (Step 3) will assign to each table.
--     Edit the domain list in Step 3 if a row shows the wrong domain.
SELECT DISTINCT
  table_name,
  CASE
    WHEN lower(table_name) RLIKE 'psgc|hdx' AND lower(table_name) NOT RLIKE
         'geography|population|facilities|workforce|diseases|socioeconomic|vaccination'
      THEN 'geography'
    ELSE coalesce(
      nullif(regexp_extract(lower(table_name),
        '(geography|population|facilities|workforce|diseases|socioeconomic|vaccination)', 1), ''),
      regexp_extract(lower(table_name), '([a-z0-9]+)_[^.]*$', 1))
  END AS domain
FROM public_health.bronze.qc_results
ORDER BY 1;

-- 1e. Rows with no run id. They cannot be guarded against re-runs and get no run_log row.
SELECT count(*) AS rows_without_run_id
FROM public_health.bronze.qc_results
WHERE run_id IS NULL;


-- -----------------------------------------------------------------------------
-- Step 2. Copy the rows. Remove the /* */ around ONE option, then run it.
-- -----------------------------------------------------------------------------

-- Option A: OLD script format (11 columns: run_id, checked_at, layer, source_key,
--   table_name, check_id, check_name, status, observed, expected, details).
--   The old run_id was one per QC execution, so it becomes validation_id too.
--   check_type is left null and filled later by quality_registry_seed.sql.
--   severity: WARN / FAIL rows keep their status; for PASS rows it is unknown (null).
/*
INSERT INTO public_health.quality.qc_results
SELECT
  CAST(o.run_id AS STRING)                                    AS run_id,
  CAST(o.run_id AS STRING)                                    AS validation_id,
  CAST(NULL AS STRING)                                        AS batch_id,
  CAST(o.source_key AS STRING)                                AS source_key,
  CASE WHEN o.table_name LIKE '%.%.%' THEN o.table_name
       WHEN o.table_name LIKE '%.%'   THEN concat('public_health.', o.table_name)
       ELSE concat('public_health.', o.layer, '.', o.table_name) END AS table_name,
  CAST(o.layer AS STRING)                                     AS layer,
  CAST(o.checked_at AS TIMESTAMP)                             AS executed_at,
  CAST(o.check_id AS STRING)                                  AS check_id,
  CAST(o.check_name AS STRING)                                AS check_name,
  CAST(NULL AS STRING)                                        AS check_type,
  CAST(NULL AS STRING)                                        AS column_name,
  CAST(NULL AS INT)                                           AS admin_level,
  upper(trim(CAST(o.status AS STRING)))                       AS status,
  CASE WHEN upper(trim(CAST(o.status AS STRING))) IN ('WARN', 'FAIL')
       THEN upper(trim(CAST(o.status AS STRING))) END         AS severity,
  CAST(NULL AS BIGINT)                                        AS fail_count,
  CAST(NULL AS BIGINT)                                        AS total_count,
  CAST(NULL AS DOUBLE)                                        AS fail_pct,
  CAST(0 AS DOUBLE)                                           AS threshold,
  CAST(o.observed AS STRING)                                  AS observed,
  CAST(o.expected AS STRING)                                  AS expected,
  left(CAST(o.details AS STRING), 500)                        AS detail
FROM public_health.bronze.qc_results o
WHERE o.run_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public_health.quality.qc_results q
                  WHERE q.validation_id = CAST(o.run_id AS STRING));
*/

-- Option B: the old table ALREADY has the 21-column format.
--   BY NAME matches columns by name, so column order does not matter (DBR 13.3+).
--   validation_id falls back to run_id when it is null, so the re-run guard still works.
/*
INSERT INTO public_health.quality.qc_results BY NAME
SELECT
  o.* EXCEPT (validation_id, table_name, status),
  coalesce(o.validation_id, o.run_id)                         AS validation_id,
  CASE WHEN o.table_name LIKE '%.%.%' THEN o.table_name
       WHEN o.table_name LIKE '%.%'   THEN concat('public_health.', o.table_name)
       ELSE concat('public_health.', o.layer, '.', o.table_name) END AS table_name,
  upper(trim(o.status))                                       AS status
FROM public_health.bronze.qc_results o
WHERE coalesce(o.validation_id, o.run_id) IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public_health.quality.qc_results q
                  WHERE q.validation_id = coalesce(o.validation_id, o.run_id));
*/


-- -----------------------------------------------------------------------------
-- Step 3. Backfill run_log for the migrated rows only
-- -----------------------------------------------------------------------------
-- Only validation sessions whose run_id came from the old table, and only those
-- without a run_log row yet. script_name = 'migration' marks these rows.
INSERT INTO public_health.quality.run_log
SELECT
  r.validation_id,
  max(r.run_id)                                               AS run_id,
  max(r.layer)                                                AS layer,
  CASE
    WHEN lower(max(r.table_name)) RLIKE 'psgc|hdx' AND lower(max(r.table_name)) NOT RLIKE
         'geography|population|facilities|workforce|diseases|socioeconomic|vaccination'
      THEN 'geography'
    ELSE coalesce(
      nullif(regexp_extract(lower(max(r.table_name)),
        '(geography|population|facilities|workforce|diseases|socioeconomic|vaccination)', 1), ''),
      regexp_extract(lower(max(r.table_name)), '([a-z0-9]+)_[^.]*$', 1))
  END                                                         AS domain,
  'migration'                                                 AS script_name,
  concat_ws(',', sort_array(collect_set(r.source_key)))       AS source_keys,
  min(r.executed_at)                                          AS started_at,
  max(r.executed_at)                                          AS ended_at,
  CASE WHEN count_if(coalesce(r.status, '') NOT IN ('PASS', 'WARN')) > 0 THEN 'FAIL'
       WHEN count_if(r.status = 'WARN') > 0 THEN 'WARN'
       ELSE 'PASS' END                                        AS status,
  CAST(count(*) AS INT)                                       AS checks_total,
  CAST(count_if(r.status = 'PASS') AS INT)                    AS checks_pass,
  CAST(count_if(r.status = 'WARN') AS INT)                    AS checks_warn,
  CAST(count_if(r.status = 'FAIL') AS INT)                    AS checks_fail,
  CAST(count(DISTINCT r.table_name) AS INT)                   AS tables_checked,
  CAST(NULL AS STRING)                                        AS code_version,
  CAST(NULL AS STRING)                                        AS error_message
FROM public_health.quality.qc_results r
WHERE r.validation_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM public_health.bronze.qc_results o
              WHERE CAST(o.run_id AS STRING) = r.run_id)
  AND NOT EXISTS (SELECT 1 FROM public_health.quality.run_log l
                  WHERE l.validation_id = r.validation_id)
GROUP BY r.validation_id;


-- -----------------------------------------------------------------------------
-- Step 4. Verify, then drop the old table
-- -----------------------------------------------------------------------------

-- Row counts should match (old rows without a run id are not copied, see 1e).
SELECT
  (SELECT count(*) FROM public_health.bronze.qc_results WHERE run_id IS NOT NULL) AS old_rows,
  (SELECT count(*) FROM public_health.quality.qc_results q
   WHERE EXISTS (SELECT 1 FROM public_health.bronze.qc_results o
                 WHERE CAST(o.run_id AS STRING) = q.run_id))                      AS migrated_rows;

-- Each table should appear once (no short-name / full-name duplicates).
SELECT * FROM public_health.quality.v_table_health ORDER BY overall_status, table_name;

-- Migrated sessions in run_log.
SELECT domain, status, count(*) AS runs
FROM public_health.quality.run_log
WHERE script_name = 'migration'
GROUP BY domain, status
ORDER BY domain, status;

-- When everything above looks right:
-- DROP TABLE public_health.bronze.qc_results;
