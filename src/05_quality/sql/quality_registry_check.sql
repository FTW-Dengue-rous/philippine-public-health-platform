-- =============================================================================
-- quality_registry_check.sql
-- Compares public_health.quality.check_registry with what the QC scripts recorded in their
-- latest run (quality.v_latest_results: latest execution per table and script). Older
-- results are left out on purpose, so retired codes (for example the GEO_LB_ codes replaced
-- on 2026-10-19) never fail the check. It writes nothing.
--
-- Where it runs
--   Last task of the pipeline job (qc_registry, after qc_gold), so nobody runs it by hand.
--   By then every QC script of the run has written its results.
--
-- What makes the task fail
--   not_registered   a script records a code the registry does not hold. Add the code to
--                    Step 1b of quality_registry_seed.sql
--   layer_differs    registry layer <> the layer the script records. With
--                    strict_registry=True this code would stop its QC script. Fix the seed row
--   The task fails with raise_error and names the codes. Data and QC results of the run are
--   already written by then, so a failure here never loses or blocks data.
--
-- What only shows in the task output (never fails)
--   type_differs     registry check_type <> the type the script records (cosmetic)
--   severity_differs registry default severity <> the recorded severity. Expected for B03,
--                    B13, GB13, S16, S21, S63 and G07, which lower to WARN in named cases
--   several_names    the script recorded the code under more than one name or type
--
-- History
--   2026-10-21  first version (was the manual quality_registry_review.sql); runs in the job
-- =============================================================================

CREATE OR REPLACE TEMPORARY VIEW registry_issues AS
WITH recorded AS (
    SELECT
        check_id,
        max_by(layer, executed_at) AS layer,
        max_by(check_type, executed_at) AS check_type,
        max_by(severity, executed_at) AS severity,
        size(collect_set(check_name)) AS name_count,
        size(collect_set(check_type)) AS type_count
    FROM public_health.quality.v_latest_results
    WHERE check_id IS NOT NULL
    GROUP BY check_id
),

compared AS (
    SELECT
        r.check_id,
        r.name_count,
        r.type_count,
        g.layer AS registry_layer,
        r.layer AS recorded_layer,
        g.check_type AS registry_type,
        r.check_type AS recorded_type,
        g.default_severity AS registry_severity,
        r.severity AS recorded_severity,
        g.check_id IS NOT NULL AS is_registered
    FROM recorded AS r
    LEFT JOIN public_health.quality.check_registry AS g ON r.check_id = g.check_id
)

SELECT
    check_id,
    registry_layer,
    recorded_layer,
    registry_type,
    recorded_type,
    registry_severity,
    recorded_severity,
    CASE
        WHEN NOT is_registered THEN 'not_registered'
        WHEN NOT (registry_layer <=> recorded_layer) THEN 'layer_differs'
        WHEN NOT (registry_type <=> recorded_type) THEN 'type_differs'
        WHEN NOT (registry_severity <=> recorded_severity) THEN 'severity_differs'
        ELSE 'several_names'
    END AS issue
FROM compared
WHERE
    NOT is_registered
    OR NOT (registry_layer <=> recorded_layer)
    OR NOT (registry_type <=> recorded_type)
    OR NOT (registry_severity <=> recorded_severity)
    OR name_count > 1
    OR type_count > 1;

-- Every difference, for the task output.
SELECT
    issue,
    check_id,
    registry_layer,
    recorded_layer,
    registry_type,
    recorded_type,
    registry_severity,
    recorded_severity
FROM registry_issues
ORDER BY issue, check_id;

-- Fail only on the two issues that matter.
SELECT
    CASE
        WHEN count(*) > 0
            THEN
                raise_error(
                    concat(
                        'check_registry is missing or has the wrong layer for: ',
                        array_join(sort_array(collect_list(concat(check_id, ' (', issue, ')'))), ', '),
                        '. Fix Step 1b of quality_registry_seed.sql.'
                    )
                )
    END AS registry_gate
FROM registry_issues
WHERE issue IN ('not_registered', 'layer_differs');