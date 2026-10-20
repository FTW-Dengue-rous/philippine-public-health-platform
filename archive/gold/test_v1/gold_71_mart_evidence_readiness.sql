-- ========================================
-- Creates the view public_health.test_gold.mart_evidence_readiness
--   One row is: one silver or gold table, in its latest succeeded build
--   Key: table_name
--   Answers: is each table built, checked, and built from the latest inputs?
--
-- Reads: quality.v_latest_build, quality.build_inputs, quality.v_table_health
--
-- Rules
--   * Only tables on the build pattern appear (a row in quality.build_log). Tables written by
--     a notebook (geography, population, admin boundaries) and the mart VIEWS have no build,
--     so they have no row here.
--   * inputs = tables and files recorded for the build in quality.build_inputs.
--   * qc_pass, qc_warn, qc_fail come from the latest QC run of every script that checks the
--     table. They are null when no QC has run on it (gold has no QC script yet).
--   * is_fresh = no input table has a newer succeeded build than the version this build read.
--     Null when no input has a recorded version to compare.
--   * approval is read from the build log parameters (gold builds only): provisional until the
--     silver QC of every input has passed and its warnings are reviewed (proposal section 7).
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold.mart_evidence_readiness AS
WITH inputs AS (
  SELECT i.build_id, i.target_table,
         count(*) AS inputs,
         count_if(i.input_table_version IS NOT NULL AND l.target_table_version IS NOT NULL) AS comparable_inputs,
         count_if(l.target_table_version > i.input_table_version) AS stale_inputs
  FROM public_health.quality.build_inputs AS i
  LEFT JOIN public_health.quality.v_latest_build AS l ON l.target_table = i.input_table
  GROUP BY i.build_id, i.target_table
)

SELECT b.target_table AS table_name,
       b.layer,
       b.domain,
       b.build_id AS latest_build_id,
       b.finished_at,
       b.row_count,
       CAST(coalesce(i.inputs, 0) AS INT) AS inputs,
       CAST(h.checks_pass AS INT) AS qc_pass,
       CAST(h.checks_warn AS INT) AS qc_warn,
       CAST(h.checks_fail AS INT) AS qc_fail,
       CASE WHEN i.comparable_inputs > 0 THEN i.stale_inputs = 0 END AS is_fresh,
       h.overall_status AS qc_status,                            -- extra
       h.last_checked_at AS qc_checked_at,                       -- extra
       get_json_object(b.parameters, '$.approval') AS approval,  -- extra
       CAST(i.stale_inputs AS INT) AS stale_inputs               -- extra
FROM public_health.quality.v_latest_build AS b
LEFT JOIN inputs AS i ON i.build_id = b.build_id AND i.target_table = b.target_table
LEFT JOIN public_health.quality.v_table_health AS h ON h.table_name = b.target_table AND h.layer = b.layer
WHERE b.layer IN ('silver', 'gold');


SELECT layer, count(*) AS tables,
       count_if(qc_status = 'PASS') AS qc_pass, count_if(qc_status = 'WARN') AS qc_warn,
       count_if(qc_status = 'FAIL') AS qc_fail, count_if(qc_status IS NULL) AS qc_not_run,
       count_if(NOT is_fresh) AS stale
FROM public_health.test_gold.mart_evidence_readiness
GROUP BY layer
ORDER BY layer;
