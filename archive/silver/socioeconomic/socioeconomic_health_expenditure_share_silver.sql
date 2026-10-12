-- =============================================================================
-- PSA Table 9.26 | Socioeconomic Health Expenditure Share Silver (DRAFT v3)
-- Bronze: public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze
-- Grain: (financing_agent, year), 2016-2023; 16 agents x 8 = 128 cells
-- NO DELTA WRITE. Run all statements sequentially using one Spark SQL session.
-- =============================================================================

-- [1] Classify using physical source positions verified from the PSA Bronze extract.
-- There are 18 Bronze rows: data rows 5,7-21; footnote 23; source credit 25.
-- Keep raw indentation in agent_level2 to distinguish nested subagents.
-- Source row positions are file-version specific: fail gates on any drift.
CREATE OR REPLACE TEMP VIEW share_source AS
SELECT
    b.*,
    nullif(trim(b.agent_level1), '') AS parent_label,
    nullif(trim(b.agent_level2), '') AS child_label,
    CASE
        WHEN
            b._source_row_num BETWEEN 5 AND 21
            AND nullif(trim(b.agent_level1), '') IS NOT NULL
            AND nullif(trim(b.agent_level2), '') IS NULL THEN 'parent'
        WHEN
            b._source_row_num BETWEEN 5 AND 21
            AND nullif(trim(b.agent_level2), '') IS NOT NULL
            AND nullif(trim(b.agent_level1), '') IS NULL THEN 'child'
        ELSE 'non_data'
    END AS row_class,
    coalesce(length(b.agent_level2) > length(ltrim(b.agent_level2)), FALSE) AS is_indented_child
FROM public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze AS b
WHERE b._source_key = 'psa_health_expenditure_share_national_annual';

-- [2] Carry the most recent top-level parent and its physical row number.
CREATE OR REPLACE TEMP VIEW share_hierarchy AS
SELECT
    *,
    last_value(CASE WHEN row_class = 'parent' THEN parent_label END, TRUE) OVER (
        PARTITION BY _source_key, _source_file, _ingested_at
        ORDER BY _source_row_num
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS parent_agent,
    max(CASE WHEN row_class = 'parent' THEN _source_row_num END) OVER (
        PARTITION BY _source_key, _source_file, _ingested_at
        ORDER BY _source_row_num
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS parent_row_num
FROM share_source;

-- [2b] Indented source rows belong to the nearest preceding non-indented
-- child within the SAME top-level parent (e.g., General Government /
-- Central Government / Department of Health).
CREATE OR REPLACE TEMP VIEW share_hierarchy_detail AS
SELECT
    *,
    last_value(CASE
        WHEN row_class = 'child' AND NOT is_indented_child
            THEN child_label
    END, TRUE) OVER (
        PARTITION BY _source_key, _source_file, _ingested_at, parent_row_num
        ORDER BY _source_row_num
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS immediate_child_group
FROM share_hierarchy;

-- [3] Unpivot the eight years; preserve 'a/' as an explicitly flagged
-- estimate (<0.05%), not zero. Preserve source lineage for every cell.
CREATE OR REPLACE TEMP VIEW share_cells AS
WITH cells AS (
    SELECT
        _source_key,
        _source_file,
        _source_sheet,
        _source_row_num,
        _as_of_date,
        _ingested_at,
        row_class,
        parent_agent,
        parent_label,
        child_label,
        is_indented_child,
        immediate_child_group,
        parent_row_num,
        stack(
            8,
            2016, share_2016, 2017, share_2017,
            2018, share_2018, 2019, share_2019,
            2020, share_2020, 2021, share_2021,
            2022, share_2022, 2023, share_2023
        ) AS (year, raw_share)
    FROM share_hierarchy_detail
    WHERE row_class IN ('parent', 'child')
)

SELECT
    *,
    CASE
        WHEN row_class = 'parent' THEN parent_label
        WHEN is_indented_child THEN concat(parent_agent, ' / ', immediate_child_group, ' / ', child_label)
        ELSE concat(parent_agent, ' / ', child_label)
    END AS financing_agent,
    CASE
        WHEN raw_share IS NULL OR trim(raw_share) = '' THEN 'not_published'
        WHEN lower(trim(raw_share)) = 'a/' THEN 'below_0_05_pct'
        WHEN try_cast(regexp_replace(trim(raw_share), '[ ,%]', '') AS DOUBLE) IS NOT NULL THEN 'ok'
        ELSE 'parse_error'
    END AS share_status,
    CASE
        WHEN lower(trim(raw_share)) = 'a/' THEN cast(NULL AS DOUBLE)
        ELSE try_cast(regexp_replace(trim(raw_share), '[ ,%]', '') AS DOUBLE)
    END AS share_pct
FROM cells;

-- [4] Validation gates. Every failure count must equal zero.
CREATE OR REPLACE TEMP VIEW share_gates AS
SELECT
    'bronze input count must be 18' AS gate,
    abs(count(*) - 18) AS failures
FROM share_source
UNION ALL
SELECT
    'exactly 16 source data rows' AS gate,
    abs(count(*) - 16) AS failures
FROM share_source
WHERE row_class IN ('parent', 'child')
UNION ALL
SELECT
    'exactly two non-data rows' AS gate,
    abs(count(*) - 2) AS failures
FROM share_source
WHERE row_class = 'non_data'
UNION ALL
SELECT
    'non-data positions are 23 and 25' AS gate,
    count(*) AS failures
FROM share_source
WHERE row_class = 'non_data' AND _source_row_num NOT IN (23, 25)
UNION ALL
SELECT
    'expected physical row positions each occur once' AS gate,
    (
        SELECT count(*) FROM share_source AS checked_rows
        WHERE
            checked_rows._source_row_num NOT IN (5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 23, 25)
            OR checked_rows._source_row_num IS NULL
    )
    + (SELECT count(*) FROM (
        SELECT _source_row_num FROM share_source
        GROUP BY _source_row_num
        HAVING count(*) <> 1
    ) AS duplicated_positions)
    + (18 - count(DISTINCT _source_row_num)) AS failures
FROM share_source
UNION ALL
SELECT
    'footnote 23 and source credit 25 each appear once' AS gate,
    abs(sum(CASE WHEN _source_row_num = 23 THEN 1 ELSE 0 END) - 1)
    + abs(sum(CASE WHEN _source_row_num = 25 THEN 1 ELSE 0 END) - 1) AS failures
FROM share_source
UNION ALL
SELECT
    'one source file with complete lineage' AS gate,
    CASE
        WHEN
            count(DISTINCT _source_file) = 1
            AND count(*) = count(_source_file)
            AND count(*) = count(_ingested_at)
            THEN 0
        ELSE 1
    END AS failures
FROM share_source
UNION ALL
SELECT
    'no ambiguously labelled data rows' AS gate,
    count(*) AS failures
FROM share_source
WHERE
    _source_row_num BETWEEN 5 AND 21
    AND parent_label IS NOT NULL AND child_label IS NOT NULL
UNION ALL
SELECT
    'no unclassified rows in source data range' AS gate,
    count(*) AS failures
FROM share_source
WHERE _source_row_num BETWEEN 5 AND 21 AND row_class = 'non_data'
UNION ALL
SELECT
    'no source data row with missing parent' AS gate,
    count(*) AS failures
FROM share_hierarchy_detail
WHERE row_class IN ('parent', 'child') AND parent_agent IS NULL
UNION ALL
SELECT
    'no nested child with missing subgroup' AS gate,
    count(*) AS failures
FROM share_hierarchy_detail
WHERE row_class = 'child' AND is_indented_child AND immediate_child_group IS NULL
UNION ALL
SELECT
    'no parse errors' AS gate,
    count(*) AS failures
FROM share_cells
WHERE share_status = 'parse_error'
UNION ALL
SELECT
    'shares in 0-100' AS gate,
    count(*) AS failures
FROM share_cells
WHERE share_pct IS NOT NULL AND (share_pct < 0 OR share_pct > 100)
UNION ALL
SELECT
    'no null or duplicate agent-year keys' AS gate,
    count(*) AS failures
FROM (
    SELECT
        financing_agent,
        year
    FROM share_cells
    GROUP BY financing_agent, year
    HAVING financing_agent IS NULL OR count(*) <> 1
) AS duplicate_or_null_keys
UNION ALL
SELECT
    '128 yearly values' AS gate,
    abs(count(*) - 128) AS failures
FROM share_cells
UNION ALL
SELECT
    '2023 households = 44.4' AS gate,
    CASE WHEN count(*) = 1 AND max(share_pct) = 44.4 THEN 0 ELSE 1 END AS failures
FROM share_cells
WHERE year = 2023 AND parent_label = 'Households' AND row_class = 'parent'
UNION ALL
SELECT
    '2023 national total = 100' AS gate,
    CASE WHEN count(*) = 1 AND max(share_pct) = 100.0 THEN 0 ELSE 1 END AS failures
FROM share_cells
WHERE year = 2023 AND parent_label = 'Total Current Health Expenditure' AND row_class = 'parent';

-- [5] Fail fast in a sequential error-stopping SQL runner.
SELECT
    assert_true(
        count(*) = 0,
        'Health expenditure share gates failed. Inspect share_gates.'
    ) AS validation_result
FROM share_gates
WHERE failures IS NULL OR failures <> 0;

-- [6] Candidate view ONLY. Parent / subgroup are preserved for safe analysis;
-- do not sum parent totals and child contributions together.
CREATE OR REPLACE TEMP VIEW share_final AS
SELECT
    financing_agent,
    parent_agent AS financing_agent_group,
    CASE WHEN is_indented_child THEN immediate_child_group END AS financing_agent_subgroup,
    child_label AS financing_agent_detail,
    CASE
        WHEN row_class = 'parent' THEN 'parent'
        WHEN is_indented_child THEN 'subagent'
        ELSE 'child'
    END AS financing_agent_level,
    year,
    share_pct,
    share_status,
    raw_share AS share_source_value,
    _source_key,
    _source_file,
    _source_sheet,
    _source_row_num,
    _as_of_date,
    _ingested_at,
    concat('share_', cast(year AS STRING)) AS _metric_source_column
FROM share_cells;

-- Review only:
-- SELECT * FROM share_gates;
-- SELECT financing_agent, financing_agent_level, year, share_pct
--   FROM share_final WHERE year=2023 ORDER BY _source_row_num;
-- NO CREATE TABLE or INSERT until lineage/disposition and DQRun are agreed.
-- This is still a draft: no local-Spark or Databricks execution completed.
