-- ========================================
-- Creates the view public_health.test_gold2.mart_evidence_readiness
--   One row is: one silver or gold table, in its latest succeeded build
--   Key: table_name
--   Answers: is each table built, checked, and built from the latest inputs? (SUP6, platform
--   requirement: data readiness page)
-- Data model v2: gold_71 (v1) with the schema changed and two columns added: schema_name
--   (test_gold vs test_gold2 builds both have build_log rows) and model (build_log
--   parameters.model, 'v2' for every v2 file). Logic unchanged.
--
-- Reads: quality.v_latest_build, quality.build_inputs, quality.v_table_health
--
-- Rules
--   * Only tables on the build pattern appear (a row in quality.build_log). Tables written by
--     a notebook (geography, population, admin boundaries) and the VIEWS (marts, coverage map,
--     default views) have no build, so they have no row here.
--   * inputs = tables and files recorded for the build in quality.build_inputs.
--   * qc_pass, qc_warn, qc_fail come from the latest QC run of every script that checks the
--     table. They are null when no QC has run on it (gold has no QC script yet).
--   * is_fresh = no input table has a newer succeeded build than the version this build read.
--     Null when no input has a recorded version to compare.
--   * approval is read from the build log parameters (gold builds only): provisional until the
--     silver QC of every input has passed and its warnings are reviewed (proposal section 7).
-- ========================================

CREATE OR REPLACE VIEW public_health.test_gold2.mart_evidence_readiness AS
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
       h.overall_status AS qc_status,
       h.last_checked_at AS qc_checked_at,
       get_json_object(b.parameters, '$.approval') AS approval,
       CAST(i.stale_inputs AS INT) AS stale_inputs,
       element_at(split(b.target_table, '[.]'), -2) AS schema_name,          -- v2
       get_json_object(b.parameters, '$.model') AS model                     -- v2: 'v2' for gold_v2 files
FROM public_health.quality.v_latest_build AS b
LEFT JOIN inputs AS i ON i.build_id = b.build_id AND i.target_table = b.target_table
LEFT JOIN public_health.quality.v_table_health AS h ON h.table_name = b.target_table AND h.layer = b.layer
WHERE b.layer IN ('silver', 'gold');


SELECT layer, schema_name, count(*) AS tables,
       count_if(qc_status = 'PASS') AS qc_pass, count_if(qc_status = 'WARN') AS qc_warn,
       count_if(qc_status = 'FAIL') AS qc_fail, count_if(qc_status IS NULL) AS qc_not_run,
       count_if(NOT is_fresh) AS stale,
       count_if(model = 'v2') AS v2_builds
FROM public_health.test_gold2.mart_evidence_readiness
GROUP BY layer, schema_name
ORDER BY layer, schema_name;

-- Gold v2 tables whose build_log label is not v2 (e.g. 35 run from the old gold_v4 file)
SELECT table_name, latest_build_id, finished_at, model
FROM public_health.test_gold2.mart_evidence_readiness
WHERE schema_name = 'test_gold2' AND coalesce(model, '') <> 'v2';
