-- =============================================================================
-- Fills public_health.quality.check_registry. Run AT THE END of the pipeline, once the
-- checks are settled. Not part of quality_setup.sql on purpose,
-- so a "Run All" of the setup never fills the registry early or updates qc_results.
--
-- How to run
--   Step by step, in order. Each step is safe to re-run:
--   Step 1 inserts only missing codes, Step 2 only codes still missing, and Step 3 only
--   fills values that are null.
--   Step 1  starter list (edit it first). Insert-only: re-run it after adding rows and only
--           the new codes are inserted (added 2026-10-12: S29, S51-S58, S97-S99)
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
    SELECT
        check_id,
        layer,
        domain,
        check_name,
        check_type,
        default_severity,
        cast(default_threshold AS DOUBLE) AS default_threshold,
        description
    FROM VALUES
    -- bronze (at rest, faithful to source; no business rules)
    (
        'B00', 'bronze', 'ALL', 'QC ran without error', 'EXECUTION', 'FAIL', 0,
        'Script error while checking a source; detail holds the error text'
    ),
    (
        'B01', 'bronze', 'ALL', 'table exists and has rows', 'COMPLETENESS', 'FAIL', 0,
        'Bronze table exists and row count > 0'
    ),
    (
        'B02', 'bronze', 'ALL', 'all listed files loaded', 'COMPLETENESS', 'FAIL', 0,
        'Every file listed in the YAML appears in _source_file'
    ),
    (
        'B03', 'bronze', 'ALL', 'row count matches expected', 'RECONCILIATION', 'FAIL', 0,
        'Rows per file equal qc.expected_rows'
    ),
    (
        'B04', 'bronze', 'ALL', 'required columns present', 'SCHEMA', 'FAIL', 0,
        'Columns from required_columns / columns / column_map exist in the table'
    ),
    (
        'B05', 'bronze', 'ALL', 'lineage columns not null', 'COMPLETENESS', 'FAIL', 0,
        '_source_key, _source_file, _source_row_num, _as_of_date, _ingested_at never null'
    ),
    (
        'B06', 'bronze', 'ALL', 'row number unique per file', 'UNIQUENESS', 'FAIL', 0,
        'One row per file, sheet and _source_row_num (catches double loads)'
    ),
    (
        'B07', 'bronze', 'ALL', 'no fully empty rows', 'COMPLETENESS', 'WARN', 0,
        'No rows where every data column is blank'
    ),
    (
        'B08', 'bronze', 'ALL', 'no exact duplicate rows', 'UNIQUENESS', 'WARN', 0,
        'No identical data rows within a file and sheet'
    ),
    (
        'B09', 'bronze', 'ALL', 'no rescued values', 'SCHEMA', 'WARN', 0,
        '_rescued_data is null (no rows wider than the header)'
    ),
    (
        'B10', 'bronze', 'ALL', 'numeric column parses', 'VALIDITY', 'WARN', 0,
        'qc.numeric_columns can be read as numbers'
    ),
    (
        'B11', 'bronze', 'ALL', 'control totals / values match', 'RECONCILIATION', 'FAIL', 0,
        'Sums or known values match numbers verified against the published source'
    ),
    (
        'B12', 'bronze', 'ALL', 'total equals sum of parts', 'CONSISTENCY', 'WARN', 0,
        'qc.row_sum total column equals the sum of its parts; WARN because the source itself may not add up'
    ),
    (
        'B13', 'bronze', 'ALL', 'rows match ingestion metadata', 'RECONCILIATION', 'FAIL', 0,
        'Rows per file equal record_count logged in ingestion_metadata for the same load'
    ),
    (
        'B14', 'bronze', 'ALL', 'no files outside the YAML', 'CONSISTENCY', 'WARN', 0,
        'No rows from files or source keys the YAML does not list (old file names left behind)'
    ),
    (
        'B15', 'bronze', 'ALL', 'data columns are STRING', 'SCHEMA', 'FAIL', 0,
        'Bronze contract: every data column is STRING'
    ),
    (
        'B16', 'bronze', 'ALL', 'nested JSON payload parses', 'VALIDITY', 'WARN', 0,
        'Non-null raw JSON string values parse into the expected nested schema'
    ),
    -- silver (business rules; starter set, edit thresholds as the team decides)
    (
        'S00', 'silver', 'ALL', 'QC ran without error', 'EXECUTION', 'FAIL', 0,
        'Script error while checking a table; detail holds the error text'
    ),
    (
        'S01', 'silver', 'ALL', 'table exists and has rows', 'COMPLETENESS', 'FAIL', 0,
        'Silver table exists and row count > 0'
    ),
    (
        'S02', 'silver', 'ALL', 'grain key not null', 'COMPLETENESS', 'FAIL', 0,
        'No nulls in any column of the documented grain'
    ),
    (
        'S03', 'silver', 'ALL', 'grain key unique', 'UNIQUENESS', 'FAIL', 0,
        'One row per documented grain, e.g. (psgc_code, census_year)'
    ),
    (
        'S04', 'silver', 'ALL', 'PSGC code found in geography', 'CONSISTENCY', 'WARN', 0,
        'psgc_code exists in the geography silver table; WARN because older files may use retired or renamed codes'
    ),
    (
        'S05', 'silver', 'ALL', 'admin level valid', 'VALIDITY', 'FAIL', 0,
        'admin_level in 0-4 and consistent with the PSGC code'
    ),
    (
        'S06', 'silver', 'ALL', 'counts non-negative', 'VALIDITY', 'FAIL', 0,
        'Count metrics (cases, deaths, beds, population) >= 0'
    ),
    (
        'S07', 'silver', 'ALL', 'rates within range', 'VALIDITY', 'WARN', 0,
        'Percentages / rates within their valid range, e.g. 0-100'
    ),
    (
        'S08', 'silver', 'ALL', 'period within expected range', 'VALIDITY', 'FAIL', 0,
        'Year / week / date within the range the source covers'
    ),
    (
        'S09', 'silver', 'ALL', 'bronze to silver rows reconcile', 'RECONCILIATION', 'FAIL', 0,
        'Bronze rows in = silver rows + quarantined + intentionally filtered (filtered count in detail)'
    ),
    (
        'S10', 'silver', 'ALL', 'metric totals preserved', 'RECONCILIATION', 'FAIL', 0,
        'Sum of a metric in silver equals the same sum from bronze (no rows lost or doubled)'
    ),
    (
        'S11', 'silver', 'ALL', 'accepted values', 'VALIDITY', 'WARN', 0,
        'Codes / categories are in the reference list (e.g. disease_key, ownership, service level)'
    ),
    (
        'S12', 'silver', 'ALL', 'metric null rate under threshold', 'COMPLETENESS', 'WARN', 0.05,
        'Share of null values in a key metric column stays under the threshold'
    ),
    -- silver, population (psgc_population_silver_qc.py runs with strict_registry=True,
    -- so its codes must be here before it runs; Step 2 cannot add them)
    (
        'S51', 'silver', 'population', 'population lineage columns not null', 'COMPLETENESS', 'FAIL', 0,
        'source_version, content_checksum, batch_id and silver_processed_at are filled on every row'
    ),
    (
        'S52', 'silver', 'population', 'population filled exactly when the status is valid', 'VALIDITY', 'FAIL', 0,
        'VALID / VALID_WITH_NOTE rows have a number; MISSING / INVALID rows are null, never 0; VALID_WITH_NOTE exactly when a note was moved out'
    ),
    (
        'S53', 'silver', 'population', 'rows without a usable population', 'COMPLETENESS', 'WARN', 0,
        'MISSING and INVALID rows, listed by status and year'
    ),
    (
        'S54', 'silver', 'population', 'every geography area has a row for every census year', 'COMPLETENESS', 'WARN', 0,
        'Areas of the latest geography snapshot without a 2015, 2020 or 2024 row'
    ),
    (
        'S55', 'silver', 'population', 'area total equals the sum of its cities and municipalities', 'CONSISTENCY', 'WARN', 0,
        'Province and region totals against the sum of their cities and municipalities (HUCs excluded from provinces)'
    ),
    (
        'S56', 'silver', 'population', 'national census total matches the PSA release', 'RECONCILIATION', 'WARN', 0,
        'Control: national total per census year within 0.1 percent of the PSA release; FAIL once confirmed'
    ),
    (
        'S57', 'silver', 'population', 'one population snapshot from the current PSGC release', 'CONSISTENCY', 'WARN', 0,
        'Population has one content_checksum and it equals the latest geography snapshot'
    ),
    (
        'S58', 'silver', 'population', 'change between census years above 30 percent', 'VALIDITY', 'WARN', 0,
        'Province, city or municipality population changed by more than 30 percent between census years, or is 0'
    ),
    -- silver, cross-domain (silver_cross_domain_qc.py)
    (
        'S29', 'silver', 'ALL', 'quarantined rows within the limit', 'COMPLETENESS', 'FAIL', 0.05,
        'Quarantined bronze rows per silver table and source: WARN above 0, FAIL above 5 percent and above 10 rows'
    ),
    (
        'S97', 'silver', 'ALL', 'ratio per population inside the plausible band', 'VALIDITY', 'WARN', 0,
        'Beds per 1,000 and doctors + nurses + midwives per 10,000 by region, against census population'
    ),
    (
        'S98', 'silver', 'ALL', 'latest data year of each source is recent', 'CONSISTENCY', 'WARN', 0,
        'Latest year per source no older than the configured age, unless the source is historical by design'
    ),
    (
        'S99', 'silver', 'ALL', 'reported population agrees with census population', 'CONSISTENCY', 'WARN', 0,
        'FHSIS reported population within 10 percent of the census for the same area and year'
    ),
    -- gold
    (
        'G00', 'gold', 'ALL', 'QC ran without error', 'EXECUTION', 'FAIL', 0,
        'Script error while checking a table; detail holds the error text'
    )
        AS v (
            check_id, layer, `domain`, check_name, check_type, default_severity, default_threshold, description
        )
) AS s
    ON t.check_id = s.check_id
WHEN NOT MATCHED THEN INSERT
    (
        check_id,
        layer,
        domain,
        check_name,
        check_type,
        default_severity,
        default_threshold,
        description,
        is_active,
        updated_at
    )
VALUES (
    s.check_id, s.layer, s.`domain`, s.check_name, s.check_type, s.default_severity, s.default_threshold,
    s.description, TRUE, current_timestamp()
);


-- -----------------------------------------------------------------------------
-- Step 2. Add every other code that appears in qc_results but is not registered yet
--         (most common name / type / severity per code). Review these rows afterwards.
-- -----------------------------------------------------------------------------
INSERT INTO public_health.quality.check_registry
SELECT
    r.check_id,
    max(r.layer) AS layer,
    'ALL' AS `domain`,
    mode(r.check_name) AS check_name,
    mode(r.check_type) AS check_type,
    coalesce(mode(r.severity), 'FAIL') AS default_severity,
    coalesce(mode(r.threshold), 0) AS default_threshold,
    'Added from qc_results; review description' AS description,
    TRUE AS is_active,
    current_timestamp() AS updated_at
FROM public_health.quality.qc_results AS r
WHERE
    r.check_id IS NOT NULL
    AND NOT EXISTS (
        SELECT 1 FROM public_health.quality.check_registry AS g
        WHERE g.check_id = r.check_id
    )
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
    r.severity = coalesce(r.severity, g.default_severity);


-- -----------------------------------------------------------------------------
-- Step 4. Review: codes used with more than one name or type (one meaning per code).
-- -----------------------------------------------------------------------------
SELECT
    check_id,
    layer,
    collect_set(check_name) AS check_names,
    collect_set(check_type) AS check_types
FROM public_health.quality.qc_results
GROUP BY check_id, layer
HAVING size(collect_set(check_name)) > 1 OR size(collect_set(check_type)) > 1
ORDER BY check_id;


-- -----------------------------------------------------------------------------
-- Step 5. Set strict_registry=True in DQRun(...) in every QC script, so codes that
--         are not in the registry are rejected from now on. (Nothing to run here.)
-- -----------------------------------------------------------------------------
