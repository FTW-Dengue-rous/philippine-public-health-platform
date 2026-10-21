-- =============================================================================
-- quality_registry_seed.sql
-- Fills public_health.quality.check_registry: one row per check code, with its layer,
-- domain, name, type, default severity and default threshold.
--
-- Where it runs
--   The setup job runs this whole file on every pipeline run (task setup_quality_registry,
--   after setup_quality and setup_ingestion_metadata). That is safe: a rerun adds
--   only missing codes. The one update (Step 1b) fills rows that still hold the old Step 2
--   placeholder description, so after one run it changes nothing. It stays out of
--   quality_setup.sql, so the table DDL and the code list change separately.
--   quality_registry_check.sql (last pipeline task, qc_registry) compares this registry with
--   what the scripts recorded and fails on a missing code or a wrong layer.
--
-- What each step does
--   Step 1   starter list: bronze B codes, the shared silver codes, population S51-S58,
--            cross-domain S29 and S97-S99, gold G00.
--   Step 1b  every other code the QC scripts use (added 2026-10-21; closes the code gap of
--            O-17): GB, HB, SG, GS, AB, AS/ASB, the per-domain silver codes, S59 and
--            G01-G13. Names, types and severities are copied from each script's CHECKS
--            dictionary or dq.record call. Where qc_results already holds a result for the
--            code, its recorded layer, type and severity win over the list, so the registry
--            always matches what the scripts write.
--
-- Rules for a registry row (dq_utils.DQRun)
--   - layer must equal the layer of the script that records the code; DQRun raises otherwise.
--     Step 1b takes the recorded layer when one exists, so this cannot drift. SG and AB are
--     written by the silver builds straight into qc_results, not through DQRun.
--   - When a script passes no severity or threshold, DQRun takes them from here. Every row in
--     Step 1b has threshold 0 on purpose: scripts that need another threshold (for example
--     S29) pass it themselves, so registering a code changes no result.
--   - check_type uses the scripts' vocabulary: EXECUTION, COMPLETENESS, UNIQUENESS, VALIDITY,
--     CONSISTENCY, RECONCILIATION, SCHEMA. quality_setup.sql maps these to the quality
--     attributes (v_qc_results_attribute, v_check_attribute_override). gold_qc.py also uses
--     INTEGRITY, AUDITABILITY, TIMELINESS and BUSINESS_RULE; they are registered as written
--     and mapped by the override view.
--   - A new check code goes into Step 1b in the same pull request as the script change.
--   - Insert-only: to change an existing row, UPDATE it on purpose and record why in the
--     decision log. Never reuse a code for a new meaning.
--
-- History
--   2026-10-07  first version: B codes, shared S codes, G00
--   2026-10-12  added S29, S51-S58, S97-S99
--   2026-10-21  Step 1b with every remaining code, copied from the scripts and aligned with the
--               recorded results; it also fills the domain and description of rows the old
--               Step 2 added. Steps 2-5 removed: the review is the qc_registry job task
--               (quality_registry_check.sql)
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Step 1. Starter list: bronze checks already in *_bronze_qc.py and a planned silver set.
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
        'VALID / VALID_WITH_NOTE rows have a number; MISSING / INVALID rows are null, never 0; VALID_WITH_NOTE exactly when a note was moved out' -- noqa: LT05
    ),
    (
        'S53', 'silver', 'population', 'rows without a usable population', 'COMPLETENESS', 'WARN', 0,
        'MISSING and INVALID rows, listed by status and year'
    ),
    (
        'S54',
        'silver',
        'population',
        'every geography area has a row for every census year',
        'COMPLETENESS',
        'WARN',
        0,
        'Areas of the latest geography snapshot without a 2015, 2020 or 2024 row'
    ),
    (
        'S55',
        'silver',
        'population',
        'area total equals the sum of its cities and municipalities',
        'CONSISTENCY',
        'WARN',
        0,
        'Province and region totals against the sum of their cities and municipalities (HUCs excluded from provinces)'
    ),
    (
        'S56', 'silver', 'population', 'national census total matches the PSA release', 'RECONCILIATION', 'WARN', 0,
        'Control: national total per census year within 0.1 percent of the PSA release; FAIL once confirmed'
    ),
    (
        'S57',
        'silver',
        'population',
        'one population snapshot from the current PSGC release',
        'CONSISTENCY',
        'WARN',
        0,
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
-- Step 1b. Every remaining code (2026-10-21). Threshold 0 everywhere: a script that needs
--          another threshold passes it. Layer, type and severity come from the code's
--          recorded results when they exist, else from the list below.
--          New codes are inserted. An existing row is updated only while it still has the
--          placeholder description the old Step 2 wrote ('Added from qc_results; review
--          description'): its domain and description are filled in. Layer, name, type,
--          severity and threshold of an existing row are never touched.
-- -----------------------------------------------------------------------------
MERGE INTO public_health.quality.check_registry AS t
USING (
    WITH recorded AS (
        SELECT
            check_id,
            max_by(layer, executed_at) AS layer,
            mode(check_type) AS check_type,
            mode(severity) AS severity
        FROM public_health.quality.qc_results
        WHERE check_id IS NOT NULL
        GROUP BY check_id
    )

    SELECT
        v.check_id,
        coalesce(r.layer, v.layer) AS layer,
        v.domain,
        v.check_name,
        coalesce(r.check_type, v.check_type) AS check_type,
        coalesce(r.severity, v.default_severity) AS default_severity,
        cast(v.default_threshold AS DOUBLE) AS default_threshold,
        v.description
    FROM
        VALUES
        -- bronze, PSGC snapshot (geography_bronze_qc.py CHECKS)
        (
            'GB00', 'bronze', 'geography', 'QC ran without error', 'EXECUTION', 'FAIL', 0,
            'Script error while checking the PSGC snapshot; detail holds the error text'
        ),
        (
            'GB01', 'bronze', 'geography', 'landing batch matches handoff', 'CONSISTENCY', 'FAIL', 0,
            'Landing batch is complete; manifest checksum and record count equal the loader handoff'
        ),
        (
            'GB02', 'bronze', 'geography', 'required columns present', 'SCHEMA', 'FAIL', 0,
            'Bronze has every required PSGC column'
        ),
        (
            'GB03', 'bronze', 'geography', 'landing records parse to expected count', 'RECONCILIATION', 'FAIL', 0,
            'Landed records parse to the manifest record count'
        ),
        (
            'GB04', 'bronze', 'geography', 'snapshot has rows', 'COMPLETENESS', 'FAIL', 0,
            'The bronze snapshot has rows'
        ),
        (
            'GB05', 'bronze', 'geography', 'snapshot row count matches landing', 'RECONCILIATION', 'FAIL', 0,
            'Bronze rows for the snapshot equal the landed records'
        ),
        (
            'GB06', 'bronze', 'geography', 'psgc_code not blank', 'COMPLETENESS', 'FAIL', 0,
            'psgc_code is never blank'
        ),
        (
            'GB07', 'bronze', 'geography', 'psgc_code unique', 'UNIQUENESS', 'FAIL', 0,
            'psgc_code is unique within the snapshot'
        ),
        (
            'GB08', 'bronze', 'geography', 'no landing codes missing from bronze', 'RECONCILIATION', 'FAIL', 0,
            'Every landed code is in bronze'
        ),
        (
            'GB09', 'bronze', 'geography', 'no bronze codes missing from landing', 'RECONCILIATION', 'FAIL', 0,
            'Bronze holds no code that was not landed'
        ),
        (
            'GB10', 'bronze', 'geography', 'source JSON matches landing', 'CONSISTENCY', 'FAIL', 0,
            'The stored source JSON equals the landed JSON for every code'
        ),
        (
            'GB11', 'bronze', 'geography', 'projected attributes match', 'CONSISTENCY', 'FAIL', 0,
            'Bronze attributes equal the loader extraction from the JSON'
        ),
        (
            'GB12', 'bronze', 'geography', 'snapshot lineage complete', 'COMPLETENESS', 'FAIL', 0,
            'Batch id, raw path and load time are filled'
        ),
        (
            'GB13', 'bronze', 'geography', 'rows match ingestion metadata', 'RECONCILIATION', 'FAIL', 0,
            'Rows equal the loader processed log row; WARN when the log table cannot be read'
        ),
        -- bronze, HDX boundaries (admin_boundaries_bronze_qc.py CHECKS)
        (
            'HB00', 'bronze', 'admin_boundaries', 'QC ran without error', 'EXECUTION', 'FAIL', 0,
            'Script error while checking the HDX boundaries; detail holds the error text'
        ),
        (
            'HB01', 'bronze', 'admin_boundaries', 'Total row reconciliation', 'RECONCILIATION', 'FAIL', 0,
            'Total rows equal the staging manifest'
        ),
        (
            'HB02',
            'bronze',
            'admin_boundaries',
            'Administrative-level row reconciliation',
            'RECONCILIATION',
            'FAIL',
            0,
            'Rows per admin level equal the staging manifest'
        ),
        (
            'HB03',
            'bronze',
            'admin_boundaries',
            'Required lineage and fingerprint completeness',
            'COMPLETENESS',
            'FAIL',
            0,
            'Required lineage and fingerprint columns are filled'
        ),
        (
            'HB04',
            'bronze',
            'admin_boundaries',
            'Record fingerprint uniqueness by administrative level',
            'UNIQUENESS',
            'FAIL',
            0,
            'One row per record fingerprint within an admin level'
        ),
        (
            'HB05', 'bronze', 'admin_boundaries', 'Batch identity consistency', 'CONSISTENCY', 'FAIL', 0,
            'One batch id and source version across the loaded rows'
        ),
        (
            'HB06', 'bronze', 'admin_boundaries', 'Raw record fingerprint integrity', 'CONSISTENCY', 'FAIL', 0,
            'The stored fingerprint matches the raw feature'
        ),
        (
            'HB07', 'bronze', 'admin_boundaries', 'Raw feature JSON parsing', 'VALIDITY', 'FAIL', 0,
            'Every raw feature JSON parses'
        ),
        (
            'HB08', 'bronze', 'admin_boundaries', 'Nonblank administrative p-code', 'COMPLETENESS', 'FAIL', 0,
            'Administrative p-code is never blank'
        ),
        (
            'HB09', 'bronze', 'admin_boundaries', 'Nonblank administrative name', 'COMPLETENESS', 'FAIL', 0,
            'Administrative name is never blank'
        ),
        (
            'HB10',
            'bronze',
            'admin_boundaries',
            'P-code uniqueness within administrative level',
            'UNIQUENESS',
            'FAIL',
            0,
            'One row per p-code within an admin level'
        ),
        (
            'HB11', 'bronze', 'admin_boundaries', 'GeoJSON feature type', 'VALIDITY', 'FAIL', 0,
            'Every feature is a GeoJSON Feature'
        ),
        (
            'HB12', 'bronze', 'admin_boundaries', 'Polygon geometry type', 'VALIDITY', 'FAIL', 0,
            'Every geometry is a Polygon or MultiPolygon'
        ),
        (
            'HB13', 'bronze', 'admin_boundaries', 'Administrative parent reference', 'CONSISTENCY', 'FAIL', 0,
            'Every parent p-code exists at the level above'
        ),
        (
            'HB14', 'bronze', 'admin_boundaries', 'Required source property keys', 'SCHEMA', 'FAIL', 0,
            'Every feature carries the required property keys'
        ),
        -- silver, geography build checks (geography_silver.py; written to qc_results directly, not through DQRun)
        (
            'SG01', 'silver', 'geography', 'Required geography fields', 'COMPLETENESS', 'FAIL', 0,
            'Build check before the write: required geography fields are filled'
        ),
        (
            'SG02', 'silver', 'geography', 'Geography grain uniqueness', 'UNIQUENESS', 'FAIL', 0,
            'Build check before the write: one row per geography grain'
        ),
        (
            'SG03', 'silver', 'geography', 'Geographic level accepted values', 'VALIDITY', 'FAIL', 0,
            'Build check before the write: geographic level is in the accepted list'
        ),
        (
            'SG04', 'silver', 'geography', 'PSGC hierarchy consistency', 'CONSISTENCY', 'WARN', 0,
            'Build check before the write: PSGC hierarchy components agree'
        ),
        (
            'SG05',
            'silver',
            'geography',
            'Bronze to Silver candidate volume reconciliation',
            'RECONCILIATION',
            'FAIL',
            0,
            'Build check before the write: candidate rows reconcile with bronze'
        ),
        (
            'SG06', 'silver', 'geography', 'Area name encoding', 'VALIDITY', 'FAIL', 0,
            'Build check before the write: area names hold no broken characters'
        ),
        (
            'SG07', 'silver', 'geography', 'PSGC code is 10 digits', 'VALIDITY', 'FAIL', 0,
            'Build check before the write: psgc_code has 10 digits'
        ),
        -- silver, geography QC (geography_silver_qc.py)
        (
            'GS01', 'silver', 'geography', 'Snapshot exists and has rows', 'COMPLETENESS', 'FAIL', 0,
            'Bronze and silver geography snapshots exist and have rows'
        ),
        (
            'GS02', 'silver', 'geography', 'Required geography fields complete', 'COMPLETENESS', 'FAIL', 0,
            'Required geography fields are filled'
        ),
        (
            'GS03', 'silver', 'geography', 'Geography logical key unique', 'UNIQUENESS', 'FAIL', 0,
            'One row per psgc_code and content_checksum'
        ),
        (
            'GS04', 'silver', 'geography', 'Non-null geographic levels accepted', 'VALIDITY', 'FAIL', 0,
            'Non-null geographic levels are in the list from the YAML'
        ),
        (
            'GS05', 'silver', 'geography', 'Bronze to Silver row counts reconcile', 'RECONCILIATION', 'FAIL', 0,
            'Silver rows equal the bronze snapshot rows'
        ),
        (
            'GS06', 'silver', 'geography', 'PSGC hierarchy components reconstruct code', 'CONSISTENCY', 'WARN', 0,
            'Hierarchy components rebuild the PSGC code'
        ),
        (
            'GS07', 'silver', 'geography', 'PSGC code is 10 digits', 'VALIDITY', 'FAIL', 0,
            'psgc_code has 10 digits'
        ),
        (
            'GS08', 'silver', 'geography', 'null-level codes are documented placeholders', 'VALIDITY', 'WARN', 0,
            'Codes without a level are the documented placeholders'
        ),
        -- silver, boundary build checks (admin_boundaries_silver.py; written to qc_results directly, not through DQRun)
        (
            'AB01', 'silver', 'admin_boundaries', 'Required field completeness', 'COMPLETENESS', 'FAIL', 0,
            'Build check before the write: required boundary fields are filled'
        ),
        (
            'AB02', 'silver', 'admin_boundaries', 'logical key unique', 'UNIQUENESS', 'FAIL', 0,
            'Build check before the write: one row per boundary key'
        ),
        (
            'AB03',
            'silver',
            'admin_boundaries',
            'accepted administrative and geometry values',
            'VALIDITY',
            'FAIL',
            0,
            'Build check before the write: admin level and geometry type are accepted values'
        ),
        (
            'AB04',
            'silver',
            'admin_boundaries',
            'bronze to silver row-count reconciliation',
            'RECONCILIATION',
            'FAIL',
            0,
            'Build check before the write: candidate rows reconcile with bronze'
        ),
        (
            'AB05', 'silver', 'admin_boundaries', 'PSGC reconciliation integrity', 'CONSISTENCY', 'WARN', 0,
            'Build check before the write: boundary to PSGC matches are consistent'
        ),
        (
            'AB06', 'silver', 'admin_boundaries', 'spatial attribute validity', 'VALIDITY', 'FAIL', 0,
            'Build check before the write: area, latitude and longitude are valid'
        ),
        (
            'AB07', 'silver', 'admin_boundaries', 'one boundary per PSGC code per level', 'UNIQUENESS', 'FAIL', 0,
            'Build check before the write: a PSGC code matches one boundary per level; stops the run'
        ),
        -- silver, boundary QC (admin_boundaries_silver_qc.py)
        (
            'AS01', 'silver', 'admin_boundaries', 'Snapshot exists and has rows', 'COMPLETENESS', 'FAIL', 0,
            'Bronze and silver boundary snapshots exist and have rows'
        ),
        (
            'AS02', 'silver', 'admin_boundaries', 'Required boundary fields complete', 'COMPLETENESS', 'FAIL', 0,
            'Required boundary fields are filled'
        ),
        (
            'AS03', 'silver', 'admin_boundaries', 'Boundary logical key unique', 'UNIQUENESS', 'FAIL', 0,
            'One row per admin_level, boundary_pcode and source_version'
        ),
        (
            'AS04',
            'silver',
            'admin_boundaries',
            'administrative and geometry values accepted',
            'VALIDITY',
            'FAIL',
            0,
            'Admin level and geometry type are accepted values'
        ),
        (
            'ASB05',
            'silver',
            'admin_boundaries',
            'bronze and silver total rows reconcile',
            'RECONCILIATION',
            'FAIL',
            0,
            'Silver rows equal the bronze rows of the source version'
        ),
        (
            'AS07', 'silver', 'admin_boundaries', 'spatial attributes valid', 'VALIDITY', 'FAIL', 0,
            'Area, latitude and longitude are valid'
        ),
        (
            'AS08',
            'silver',
            'admin_boundaries',
            'PSGC match status and special structures valid',
            'VALIDITY',
            'FAIL',
            0,
            'Match status values and special structures follow the rules'
        ),
        (
            'AS09',
            'silver',
            'admin_boundaries',
            'PSGC reference snapshot and level valid',
            'CONSISTENCY',
            'FAIL',
            0,
            'Matches point to the current PSGC snapshot at the right level'
        ),
        -- silver, facilities (facilities_silver_qc.py CHECKS)
        (
            'S13', 'silver', 'facilities', 'lineage columns not null', 'COMPLETENESS', 'FAIL', 0,
            'Silver lineage columns are filled on every row'
        ),
        (
            'S14',
            'silver',
            'facilities',
            'every lineage reference has one build input',
            'CONSISTENCY',
            'FAIL',
            0,
            'Every file or sheet referenced by a row has exactly one build_inputs row'
        ),
        (
            'S15', 'silver', 'facilities', 'table written by a succeeded build', 'CONSISTENCY', 'FAIL', 0,
            'The published table is the one its latest succeeded build wrote'
        ),
        (
            'S16',
            'silver',
            'facilities',
            'silver built from the current bronze loads and reference versions',
            'CONSISTENCY',
            'FAIL',
            0,
            'Inputs are the current bronze loads and reference versions; WARN when only the reference version changed'
        ),
        (
            'S17',
            'silver',
            'facilities',
            'one processed ingestion_metadata row and one load time per input',
            'CONSISTENCY',
            'FAIL',
            0,
            'Each input has one load time and one processed ingestion_metadata row'
        ),
        (
            'S18',
            'silver',
            'facilities',
            'each NHFR id in at most one registry facility',
            'UNIQUENESS',
            'FAIL',
            0,
            'An NHFR id belongs to at most one facility'
        ),
        (
            'S19',
            'silver',
            'facilities',
            'registry lineage groups follow in_nhfr / in_hfsrb',
            'COMPLETENESS',
            'FAIL',
            0,
            'Registry lineage groups agree with the in_nhfr and in_hfsrb flags'
        ),
        (
            'S20', 'silver', 'facilities', 'every MAP key has a lineage group', 'CONSISTENCY', 'FAIL', 0,
            'Every metric source key has a lineage group'
        ),
        (
            'S21', 'silver', 'facilities', 'control totals match', 'RECONCILIATION', 'FAIL', 0,
            'Control totals equal the published values; WARN on a new file'
        ),
        (
            'S22', 'silver', 'facilities', 'id map and registry keys agree', 'CONSISTENCY', 'FAIL', 0,
            'Id map and registry facility keys agree'
        ),
        (
            'S23', 'silver', 'facilities', 'bed columns follow their definitions', 'CONSISTENCY', 'FAIL', 0,
            'Authorized and analysis bed columns follow their definitions'
        ),
        (
            'S24',
            'silver',
            'facilities',
            'bed occupancy eligibility follows the named rules',
            'CONSISTENCY',
            'FAIL',
            0,
            'Occupancy eligibility and exclusion reasons follow the named rules'
        ),
        (
            'S25',
            'silver',
            'facilities',
            'bed occupancy rate above 100 or above the baseline maximum',
            'VALIDITY',
            'WARN',
            0,
            'Bed occupancy rate above 100 percent'
        ),
        (
            'S26',
            'silver',
            'facilities',
            'FHSIS region equals its provinces and listed cities',
            'RECONCILIATION',
            'WARN',
            0,
            'FHSIS region totals equal their provinces plus listed cities'
        ),
        (
            'S27',
            'silver',
            'facilities',
            'OSM points placed by city tag only, or tag disagrees with coordinates',
            'COMPLETENESS',
            'WARN',
            0,
            'OSM points placed by the city tag alone, or where the tag disagrees with the polygon'
        ),
        (
            'S28', 'silver', 'facilities', 'quarantined bronze rows', 'COMPLETENESS', 'WARN', 0,
            'Bronze rows set aside with a reason'
        ),
        -- silver, diseases (diseases_silver_qc.py CHECKS)
        (
            'S30', 'silver', 'diseases', 'lineage columns not null', 'COMPLETENESS', 'FAIL', 0,
            'Silver lineage columns are filled on every row'
        ),
        (
            'S31', 'silver', 'diseases', 'every lineage reference has one build input', 'CONSISTENCY', 'FAIL', 0,
            'Every lineage reference has exactly one build_inputs row'
        ),
        (
            'S32', 'silver', 'diseases', 'table written by one succeeded build', 'CONSISTENCY', 'FAIL', 0,
            'The published table is the one its latest succeeded build wrote'
        ),
        (
            'S33', 'silver', 'diseases', 'silver built from the current bronze loads', 'CONSISTENCY', 'FAIL', 0,
            'Inputs are the current bronze loads'
        ),
        (
            'S34', 'silver', 'diseases', 'control values match', 'RECONCILIATION', 'FAIL', 0,
            'Control values from the YAML equal the silver values'
        ),
        (
            'S35', 'silver', 'diseases', 'modelled value within its bounds', 'VALIDITY', 'FAIL', 0,
            'Modelled values lie between their lower and upper bounds'
        ),
        (
            'S36', 'silver', 'diseases', 'value, status and definitions consistent', 'VALIDITY', 'FAIL', 0,
            'Value, value_status and definition columns agree'
        ),
        (
            'S37', 'silver', 'diseases', 'disease and area keys resolve', 'VALIDITY', 'FAIL', 0,
            'Disease and area keys exist in their reference tables'
        ),
        (
            'S38', 'silver', 'diseases', 'aggregation set sums to all causes', 'RECONCILIATION', 'FAIL', 0,
            'The cause aggregation set adds up to all causes'
        ),
        (
            'S39', 'silver', 'diseases', 'aggregation set members do not overlap', 'CONSISTENCY', 'FAIL', 0,
            'No cause appears twice in an aggregation set'
        ),
        (
            'S40', 'silver', 'diseases', 'months sum to the published year total', 'CONSISTENCY', 'WARN', 0,
            'Monthly values add up to the published year total'
        ),
        (
            'S41', 'silver', 'diseases', 'country equals regions plus foreign', 'CONSISTENCY', 'WARN', 0,
            'The country row equals its regions plus the foreign row'
        ),
        (
            'S42', 'silver', 'diseases', 'national totals agree between PSA tables', 'CONSISTENCY', 'WARN', 0,
            'National totals agree across the PSA death tables'
        ),
        (
            'S43', 'silver', 'diseases', 'weekly series has no gaps', 'COMPLETENESS', 'WARN', 0,
            'Weekly series have no missing weeks'
        ),
        (
            'S44', 'silver', 'diseases', 'dengue sources agree on a common basis', 'CONSISTENCY', 'WARN', 0,
            'Dengue sources agree when compared on a common basis'
        ),
        (
            'S45', 'silver', 'diseases', 'quarantined rows are the reviewed kind only', 'VALIDITY', 'FAIL', 0,
            'Only reviewed kinds of rows are quarantined'
        ),
        (
            'S46', 'silver', 'diseases', 'age groups sum to the metric total', 'RECONCILIATION', 'FAIL', 0,
            'Age groups add up to the metric total'
        ),
        (
            'S47', 'silver', 'diseases', 'hospital encounter review flags', 'VALIDITY', 'WARN', 0,
            'Hospital encounters flagged for review'
        ),
        (
            'S48', 'silver', 'diseases', 'coverage table matches the metric table', 'CONSISTENCY', 'FAIL', 0,
            'The source coverage table agrees with the metric table'
        ),
        (
            'S49', 'silver', 'diseases', 'mapped area codes exist in geography silver', 'VALIDITY', 'FAIL', 0,
            'Mapped area codes exist in geography_silver'
        ),
        (
            'S50',
            'silver',
            'diseases',
            'source-printed area codes agree with geography silver',
            'CONSISTENCY',
            'WARN',
            0,
            'Codes printed in the source agree with geography_silver'
        ),
        -- silver, population (psgc_population_silver_qc.py)
        (
            'S59', 'silver', 'population', 'years are the configured census years', 'VALIDITY', 'FAIL', 0,
            'population_year is one of the census years in the YAML'
        ),
        -- silver, workforce (workforce_silver_qc.py CHECKS)
        (
            'S60', 'silver', 'workforce', 'lineage columns not null', 'COMPLETENESS', 'FAIL', 0,
            'Silver lineage columns are filled on every row'
        ),
        (
            'S61', 'silver', 'workforce', 'every lineage reference has one build input', 'CONSISTENCY', 'FAIL', 0,
            'Every lineage reference has exactly one build_inputs row'
        ),
        (
            'S62', 'silver', 'workforce', 'table written by one succeeded build', 'CONSISTENCY', 'FAIL', 0,
            'The published table is the one its latest succeeded build wrote'
        ),
        (
            'S63',
            'silver',
            'workforce',
            'silver built from the current bronze loads and reference versions',
            'CONSISTENCY',
            'FAIL',
            0,
            'Inputs are the current bronze loads and reference versions; WARN when only the reference version changed'
        ),
        (
            'S64', 'silver', 'workforce', 'national control values match', 'RECONCILIATION', 'FAIL', 0,
            'National control values from the YAML equal the silver values'
        ),
        (
            'S65', 'silver', 'workforce', 'area control values match', 'RECONCILIATION', 'FAIL', 0,
            'Area control values from the YAML equal the silver values'
        ),
        (
            'S66', 'silver', 'workforce', 'accepted values', 'VALIDITY', 'FAIL', 0,
            'Professions, roles and statuses are in their accepted lists'
        ),
        (
            'S67', 'silver', 'workforce', 'eligibility follows the named rules', 'CONSISTENCY', 'FAIL', 0,
            'analysis_eligible and its reasons follow the named rules'
        ),
        (
            'S68',
            'silver',
            'workforce',
            'totals equal their mutually exclusive components',
            'RECONCILIATION',
            'WARN',
            0,
            'Total columns equal the sum of their components'
        ),
        (
            'S69', 'silver', 'workforce', 'split fields add up to the published total', 'CONSISTENCY', 'WARN', 0,
            'LGU and DOH splits add up to the total'
        ),
        (
            'S70',
            'silver',
            'workforce',
            '2025 province vs its municipalities and cities',
            'CONSISTENCY',
            'WARN',
            0,
            '2025 province totals against the sum of their municipalities and cities'
        ),
        (
            'S71',
            'silver',
            'workforce',
            'PSA and FHSIS national totals agree 2018-2023',
            'CONSISTENCY',
            'WARN',
            0,
            'PSA and FHSIS national totals agree in overlapping years'
        ),
        (
            'S72',
            'silver',
            'workforce',
            'province year-on-year change above 50% outside break years',
            'CONSISTENCY',
            'WARN',
            0,
            'Province headcount changed by more than 50 percent outside a break year'
        ),
        (
            'S73', 'silver', 'workforce', 'quarantined bronze rows', 'COMPLETENESS', 'WARN', 0,
            'Bronze rows set aside with a reason'
        ),
        (
            'S74',
            'silver',
            'workforce',
            'denominator lineage groups follow source contribution',
            'COMPLETENESS',
            'FAIL',
            0,
            'Denominator lineage groups match the sources that contributed'
        ),
        (
            'S75', 'silver', 'workforce', 'every MAP key has a lineage group', 'CONSISTENCY', 'FAIL', 0,
            'Every metric source key has a lineage group'
        ),
        (
            'S76',
            'silver',
            'workforce',
            'population agrees across sheets of the same workbook',
            'CONSISTENCY',
            'WARN',
            0,
            'Printed population agrees across the sheets of one workbook'
        ),
        (
            'S77',
            'silver',
            'workforce',
            'PSMO label matched to a city by name (no province of that name)',
            'CONSISTENCY',
            'WARN',
            0,
            'A PSMO area label matched to a city by name only'
        ),
        (
            'S78', 'silver', 'workforce', 'listed oncologist control total', 'RECONCILIATION', 'FAIL', 0,
            'Listed oncologists equal the control total'
        ),
        (
            'S79', 'silver', 'workforce', 'area label overrides not yet reviewed', 'CONSISTENCY', 'WARN', 0,
            'Area label overrides still marked proposed'
        ),
        -- silver, socioeconomic (socioeconomic_silver_qc.py CHECKS)
        (
            'S80', 'silver', 'socioeconomic', 'lineage columns not null', 'COMPLETENESS', 'FAIL', 0,
            'Silver lineage columns are filled on every row'
        ),
        (
            'S81',
            'silver',
            'socioeconomic',
            'every lineage reference has one build input',
            'CONSISTENCY',
            'FAIL',
            0,
            'Every lineage reference has exactly one build_inputs row'
        ),
        (
            'S82', 'silver', 'socioeconomic', 'table written by one succeeded build', 'CONSISTENCY', 'FAIL', 0,
            'The published table is the one its latest succeeded build wrote'
        ),
        (
            'S83',
            'silver',
            'socioeconomic',
            'silver built from the current bronze loads and reference tables',
            'CONSISTENCY',
            'FAIL',
            0,
            'Inputs are the current bronze loads and reference tables'
        ),
        (
            'S84', 'silver', 'socioeconomic', 'control values match', 'RECONCILIATION', 'FAIL', 0,
            'Control values from the YAML equal the silver values'
        ),
        (
            'S85',
            'silver',
            'socioeconomic',
            'build inputs carry a load id and file checksum',
            'COMPLETENESS',
            'WARN',
            0,
            'Every build input has a load id and a file checksum'
        ),
        (
            'S86', 'silver', 'socioeconomic', 'measure within its hard limits', 'VALIDITY', 'FAIL', 0,
            'Measures stay within their hard limits'
        ),
        (
            'S87', 'silver', 'socioeconomic', 'value agrees with its flag or status', 'VALIDITY', 'FAIL', 0,
            'Values agree with their flag or status columns'
        ),
        (
            'S88', 'silver', 'socioeconomic', 'expected rows present, no others', 'COMPLETENESS', 'FAIL', 0,
            'Every expected row is present and no other row exists'
        ),
        (
            'S89',
            'silver',
            'socioeconomic',
            'metric source columns complete and valid',
            'CONSISTENCY',
            'FAIL',
            0,
            '_metric_source_columns is filled and names real source columns'
        ),
        (
            'S90', 'silver', 'socioeconomic', 'area attributes match the area map', 'CONSISTENCY', 'FAIL', 0,
            'Area attributes equal the reviewed area map'
        ),
        (
            'S91', 'silver', 'socioeconomic', 'level-1 shares sum to the total', 'RECONCILIATION', 'FAIL', 0,
            'Level-1 financing agent shares add up to the total'
        ),
        (
            'S92', 'silver', 'socioeconomic', 'financing agent hierarchy resolves', 'CONSISTENCY', 'FAIL', 0,
            'Every financing agent parent exists'
        ),
        (
            'S93',
            'silver',
            'socioeconomic',
            'PSGC code unique in geography, at the same level',
            'CONSISTENCY',
            'FAIL',
            0,
            'A mapped PSGC code is unique in geography at the same level'
        ),
        (
            'S94',
            'silver',
            'socioeconomic',
            'incidence fell by more than 15 points or reached zero',
            'CONSISTENCY',
            'WARN',
            0,
            'Poverty incidence fell by more than 15 points between rounds, or reached zero'
        ),
        (
            'S95',
            'silver',
            'socioeconomic',
            'rows not eligible for comparison with PSGC-based data',
            'CONSISTENCY',
            'WARN',
            0,
            'Rows marked not comparable with PSGC-based data, with a reason'
        ),
        (
            'S96', 'silver', 'socioeconomic', 'definition not confirmed yet', 'COMPLETENESS', 'WARN', 0,
            'Rows whose definition is not confirmed yet'
        ),
        -- gold (gold_qc.py)
        (
            'G01', 'gold', 'ALL', 'Table has rows', 'COMPLETENESS', 'FAIL', 0,
            'The model table has rows'
        ),
        (
            'G02', 'gold', 'ALL', 'Primary key complete and unique', 'UNIQUENESS', 'FAIL', 0,
            'Primary key and required key columns are filled; the primary key is unique'
        ),
        (
            'G03', 'gold', 'ALL', 'Grain unique', 'UNIQUENESS', 'FAIL', 0,
            'One row per natural key or grain'
        ),
        (
            'G04', 'gold', 'ALL', 'Foreign key resolves', 'INTEGRITY', 'FAIL', 0,
            'Every foreign key exists in its dimension'
        ),
        (
            'G05', 'gold', 'ALL', 'Published table = latest succeeded build', 'AUDITABILITY', 'FAIL', 0,
            'Rows and Delta version match the latest succeeded build; no data write after it (OPTIMIZE, VACUUM ignored)'
        ),
        (
            'G06', 'gold', 'ALL', 'Built from the latest build of every input', 'TIMELINESS', 'FAIL', 0,
            'No input was rebuilt after this build'
        ),
        (
            'G07', 'gold', 'ALL', 'Control total gold = silver', 'RECONCILIATION', 'FAIL', 0,
            'Gold totals equal silver totals; claims are WARN when gold is lower because of suppressed cells'
        ),
        (
            'G08', 'gold', 'ALL', 'Value, status and basis consistent', 'CONSISTENCY', 'FAIL', 0,
            'Value filled only when status is ok; measures only on their own basis'
        ),
        (
            'G09', 'gold', 'ALL', 'View, mart or seed readable and not empty', 'COMPLETENESS', 'FAIL', 0,
            'Each default view, mart and seed can be read and has rows'
        ),
        (
            'G10', 'gold', 'ALL', 'One preferred source per disease series', 'BUSINESS_RULE', 'FAIL', 0,
            'Selection contract: one preferred source per disease, area, period, metric and coverage'
        ),
        (
            'G11', 'gold', 'ALL', 'Measure values in a valid range', 'VALIDITY', 'FAIL', 0,
            'Counts, beds and headcounts are not negative; occupancy, incidence and shares are in range'
        ),
        (
            'G12',
            'gold',
            'ALL',
            'Content unchanged since previous QC run (idempotency)',
            'CONSISTENCY',
            'WARN',
            0,
            'Idempotency fingerprint equals the previous QC run; WARN when the content changed'
        ),
        (
            'G13', 'gold', 'ALL', 'Census population change plausible', 'BUSINESS_RULE', 'WARN', 0,
            'An area halved or more than doubled between censuses'
        )
            AS v (
                check_id, layer, `domain`, check_name, check_type, default_severity, default_threshold, description
            )
    LEFT JOIN recorded AS r ON v.check_id = r.check_id
) AS s
    ON t.check_id = s.check_id
WHEN MATCHED AND t.description = 'Added from qc_results; review description'
THEN
    UPDATE SET
        t.domain = s.`domain`,
        t.description = s.description,
        t.updated_at = current_timestamp()
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
