-- =============================================================================
-- evidence_queries.sql
-- Queries for the three evidence runs (docs/06-evidence/README.md, section 3).
--   After EACH run:      B1, S1, S2, G1  -> <session folder>/run-N/
--   After run 3 only:    I1, I2, I3      -> <session folder>/ (comparison in its README.md)
-- Read-only. Run them right after the job run finishes, before anything else builds, so
-- "latest" means that run. Export each result (CSV or screenshot) into
-- docs/06-evidence/<session folder>/run-N/ as <n>_run<N>.png, numbered in query order:
-- 1 B1, 2 S1, 3 S2, 4 G1, 5 I1, 6 I2, 7 I3 (a, b for parts), e.g. 3a_run1.png.
-- Restricted data: these return QC results and counts only (D-47).
-- =============================================================================

-- B1. Bronze checks that are not PASS, from the LATEST QC run of each source (what the gate
--     reads). Older runs are left out, so a fixed failure no longer shows.
--     Expected: only the WARNs listed in bronze-quality-checks.md (B08 philhealth claims,
--     B08 doh_fhsis_demographic, B10 psgc_population, B03 where no expected count is set).
--     run_bronze.py only re-runs QC for loaded or not-cleared sources, so an unchanged
--     source keeps the date of its last QC run.
WITH latest AS (
    SELECT
        r.domain,
        q.source_key,
        max_by(q.validation_id, q.executed_at) AS validation_id,
        max(q.executed_at) AS last_checked_at
    FROM public_health.quality.qc_results AS q
    INNER JOIN public_health.quality.run_log AS r ON q.validation_id = r.validation_id
    WHERE q.layer = 'bronze'
    GROUP BY r.domain, q.source_key
)

SELECT
    l.domain,
    q.source_key,
    q.check_id,
    q.status,
    q.detail,
    l.last_checked_at
FROM public_health.quality.qc_results AS q
INNER JOIN latest AS l ON q.validation_id = l.validation_id AND q.source_key = l.source_key
WHERE q.status <> 'PASS'
ORDER BY q.status, l.domain, q.source_key;

-- S1. Every QC script's last run, all layers. Expected: no FAIL, no ERROR.
--     Bronze dates stay old when nothing reloaded (QC is not re-run for cleared sources).
--     population_silver_qc.py is an old script name; the current one is
--     psgc_population_silver_qc.py.
SELECT
    layer,
    script_name,
    status,
    checks_total,
    checks_pass,
    checks_warn,
    checks_fail,
    started_at,
    validation_id
FROM public_health.quality.run_log
QUALIFY row_number() OVER (PARTITION BY script_name ORDER BY started_at DESC) = 1
ORDER BY layer, script_name;

-- S2. Latest succeeded build of every silver and gold table (test schemas left out).
--     Expected: every table listed, finished during this run. Geography, boundaries and
--     population silver are MERGE builds without a build_log row.
SELECT
    layer,
    target_table,
    status,
    row_count,
    target_table_version,
    finished_at
FROM public_health.quality.build_log
WHERE
    status = 'succeeded'
    AND split_part(target_table, '.', 2) IN ('silver', 'gold')
QUALIFY row_number() OVER (PARTITION BY target_table ORDER BY finished_at DESC) = 1
ORDER BY layer, target_table;

-- G1. Gold QC results that are not PASS, latest gold QC run. Expected: no FAIL. Run 1 may
--     show G12 WARN (content changed since the run before the gold pass); runs 2 and 3: none.
SELECT
    table_name,
    check_id,
    check_name,
    status,
    observed,
    expected,
    detail
FROM public_health.quality.qc_results
WHERE
    layer = 'gold'
    AND validation_id = (
        SELECT max_by(rl.validation_id, rl.started_at) FROM public_health.quality.run_log AS rl
        WHERE rl.layer = 'gold'
    )
    AND status <> 'PASS'
ORDER BY status, table_name, check_id;

-- I1. Row counts per silver and gold table, last three builds (= runs 1, 2, 3).
--     Run right after run 3. Expected: the same count in all three columns.
--     Don't rebuild a table by hand between runs: an extra build shifts the columns.
--     Geography, boundaries and population silver are MERGE builds outside build_log; their
--     rerun evidence is 0 inserts and 0 updates in the task output.
WITH builds AS (
    SELECT
        target_table,
        row_count,
        row_number() OVER (PARTITION BY target_table ORDER BY finished_at DESC) AS rn
    FROM public_health.quality.build_log
    WHERE
        status = 'succeeded'
        AND split_part(target_table, '.', 2) IN ('silver', 'gold')
)

SELECT
    target_table,
    max(CASE WHEN rn = 3 THEN row_count END) AS run_1,
    max(CASE WHEN rn = 2 THEN row_count END) AS run_2,
    max(CASE WHEN rn = 1 THEN row_count END) AS run_3,
    count_if(rn <= 3) = 3 AND min(CASE WHEN rn <= 3 THEN row_count END)
    = max(CASE WHEN rn <= 3 THEN row_count END) AS same_count
FROM builds
WHERE rn <= 3
GROUP BY target_table
ORDER BY same_count, target_table;

-- I2. G12 (content fingerprint) per gold table, last three gold QC runs.
--     Expected: run_2 and run_3 PASS for all 9 tables, detail "same as previous".
--     run_1 may be WARN (content changed since the run before the gold pass).
WITH gold_runs AS (
    SELECT
        validation_id,
        dense_rank() OVER (ORDER BY started_at DESC) AS run_rank
    FROM public_health.quality.run_log
    WHERE layer = 'gold'
),

g12 AS (
    SELECT
        q.table_name,
        q.status,
        q.detail,
        r.run_rank
    FROM public_health.quality.qc_results AS q
    INNER JOIN gold_runs AS r ON q.validation_id = r.validation_id
    WHERE q.check_id = 'G12' AND r.run_rank <= 3
)

SELECT
    table_name,
    max(CASE WHEN run_rank = 3 THEN status END) AS run_1,
    max(CASE WHEN run_rank = 2 THEN status END) AS run_2,
    max(CASE WHEN run_rank = 1 THEN status END) AS run_3,
    max(CASE WHEN run_rank = 1 THEN detail END) AS run_3_detail
FROM g12
GROUP BY table_name
ORDER BY table_name;

-- I3. Bronze does not load again: what each source's loader logged in its last three runs.
--     The file loaders compare every file with its last processed load (sha256, as_of_date,
--     rows in bronze) and log an unchanged file as skipped_duplicate instead of reloading it.
--     Expected: run_2 and run_3 show "loaded 0, failed 0" for every source; no_reload = true.
--     run_1 may show loads if a file was new or changed before run 1.
--     Geography (PSGC) and HDX boundaries do not log skips here: their evidence is the task
--     output ("unchanged", 0 inserts, 0 updates). API sources log one row per attempt.
WITH loader_log AS (
    SELECT
        source_name,
        retrieved_at,
        lower(status) AS status,
        coalesce(batch_id, cast(retrieved_at AS STRING)) AS batch_key
    FROM public_health.bronze.ingestion_metadata
    WHERE lower(status) IN ('processed', 'skipped_duplicate', 'failed')
),

batches AS (
    SELECT
        source_name,
        batch_key,
        max(retrieved_at) AS logged_at,
        count_if(status = 'processed') AS loaded,
        count_if(status = 'skipped_duplicate') AS skipped,
        count_if(status = 'failed') AS failed
    FROM loader_log
    GROUP BY source_name, batch_key
),

ranked AS (
    SELECT
        source_name,
        logged_at,
        loaded,
        failed,
        concat('loaded ', loaded, ', skipped ', skipped, ', failed ', failed) AS summary,
        row_number() OVER (PARTITION BY source_name ORDER BY logged_at DESC) AS rn
    FROM batches
)

SELECT
    source_name,
    max(CASE WHEN rn = 3 THEN summary END) AS run_1,
    max(CASE WHEN rn = 2 THEN summary END) AS run_2,
    max(CASE WHEN rn = 1 THEN summary END) AS run_3,
    max(CASE WHEN rn = 1 THEN logged_at END) AS run_3_logged_at,
    coalesce(sum(CASE WHEN rn <= 2 THEN loaded + failed END), 0) = 0 AS no_reload
FROM ranked
WHERE rn <= 3
GROUP BY source_name
ORDER BY no_reload, source_name;
