-- ========================================
-- Creates the view public_health.gold.mart_evidence_readiness
--   One row is: one silver or gold table, in its latest succeeded build
--   Key: table_name
--   Answers: is each table built, checked, and built from the latest inputs? (SUP6, platform
--   requirement: data readiness page)
-- Previous file name: gold_v2_71_mart_evidence_readiness.sql
--
-- Reads: quality.v_latest_build, quality.build_inputs, quality.v_table_health
--
-- Rules
--   * Only silver and gold tables on the build pattern appear (a row in quality.build_log).
--     These have no row here:
--       - tables written by a notebook (geography, population, admin boundaries)
--       - seed tables written by a plain CREATE OR REPLACE TABLE (source_priority,
--         priority_weight_params)
--       - VIEWS (marts, coverage map, default views)
--     gold_qc.py check G09 covers the views and seeds instead: each one must be readable and
--     not empty.
--   * schema_name = the schema part of catalog.schema.table. quality.build_log keeps the rows of
--     the old test schemas (test_gold, test_gold2), so filter schema_name = 'gold' for the
--     published gold layer.
--   * inputs = tables and files recorded for the build in quality.build_inputs.
--   * qc_pass, qc_warn, qc_fail = the latest QC run of every script that checks the table
--     (silver QC, and gold_qc.py for gold, D-48). Null when no QC has run on the table.
--   * is_fresh = no input table has a newer succeeded build than the version this build read.
--     Null when no input has a recorded version to compare. gold_qc.py check G06 applies the
--     same rule.
--   * stale_inputs = number of inputs with a newer succeeded build.
--   * approval comes from the build log parameters (gold builds only). It is provisional until
--     the silver QC of every input has passed and its warnings are reviewed (proposal section 7).
--
-- History
--   2026-10-14  Written for the combined data model (from gold_71, v1). Added schema_name and a
--               model label column to tell the test builds apart during the migration.
--   2026-10-18  Moved to public_health.gold and renamed gold_24. Dropped the model column and
--               its check: gold has one final model, and schema_name already separates the old
--               test builds. Comments updated (gold QC exists, seeds have no build).
-- ========================================

CREATE OR REPLACE VIEW public_health.gold.mart_evidence_readiness AS
-- per build: inputs recorded, inputs with a version to compare, and inputs rebuilt since
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
       element_at(split(b.target_table, '[.]'), -2) AS schema_name
FROM public_health.quality.v_latest_build AS b
LEFT JOIN inputs AS i ON i.build_id = b.build_id AND i.target_table = b.target_table
LEFT JOIN public_health.quality.v_table_health AS h ON h.table_name = b.target_table AND h.layer = b.layer
WHERE b.layer IN ('silver', 'gold');


-- Check after creating the view: readiness per layer and schema.
-- After a full run plus gold_qc.py, expect qc_not_run = 0 and stale = 0 for schema gold.
SELECT layer, schema_name, count(*) AS tables,
       count_if(qc_status = 'PASS') AS qc_pass, count_if(qc_status = 'WARN') AS qc_warn,
       count_if(qc_status = 'FAIL') AS qc_fail, count_if(qc_status IS NULL) AS qc_not_run,
       count_if(NOT is_fresh) AS stale
FROM public_health.gold.mart_evidence_readiness
GROUP BY layer, schema_name
ORDER BY layer, schema_name;