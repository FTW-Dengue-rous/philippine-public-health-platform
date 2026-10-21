-- =============================================================================
-- PSA Table 9.24 | Socioeconomic Health Expenditure Per Capita Silver (DRAFT v1)
-- Source: config/sources_socioeconomic.yaml
-- Bronze: public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze
-- Grain: one national record per year, 2016-2023 (expected 8 records)
-- VALIDATION ONLY: no Delta write; no DQRun; no shared lineage-ledger writes.
-- Run ALL statements sequentially in ONE Databricks SQL editor session.
-- =============================================================================

-- [1] Preserve all eight original Bronze rows and distinguish data vs notes.
CREATE OR REPLACE TEMP VIEW per_capita_source AS
SELECT
    b.*,
    CASE
        WHEN b._source_row_num = 4 THEN 'amount'
        WHEN b._source_row_num = 7 THEN 'growth'
        WHEN b._source_row_num IN (5, 6) THEN 'subheader'
        WHEN b._source_row_num IN (10, 11, 12) THEN 'population_note'
        WHEN b._source_row_num = 14 THEN 'source_credit'
        ELSE 'unexpected'
    END AS row_class
FROM public_health.bronze.socioeconomic_psa_health_expenditure_per_capita_bronze AS b
WHERE b._source_key = 'psa_health_expenditure_per_capita_national_annual';

-- [2] Unpivot the two actual data rows by annual VALUE columns, not header offsets.
--     The row-7 growth value under value_2016 describes 2015-16 growth.
CREATE OR REPLACE TEMP VIEW per_capita_cells AS
SELECT
    _source_key,
    _source_file,
    _source_sheet,
    _source_row_num,
    _as_of_date,
    _ingested_at,
    row_class,
    year,
    raw_value,
    try_cast(regexp_replace(trim(raw_value), '[,% ]', '') AS DOUBLE) AS metric_value,
    CASE
        WHEN raw_value IS NULL OR trim(raw_value) = '' THEN 'not_published'
        WHEN try_cast(regexp_replace(trim(raw_value), '[,% ]', '') AS DOUBLE) IS NOT NULL THEN 'ok'
        ELSE 'parse_error'
    END AS value_status
FROM (
    SELECT
        _source_key,
        _source_file,
        _source_sheet,
        _source_row_num,
        _as_of_date,
        _ingested_at,
        row_class,
        stack(
            8,
            2016, value_2016, 2017, value_2017,
            2018, value_2018, 2019, value_2019,
            2020, value_2020, 2021, value_2021,
            2022, value_2022, 2023, value_2023
        ) AS (year, raw_value)
    FROM per_capita_source
    WHERE row_class IN ('amount', 'growth')
) AS unpivoted;

-- [3] Pair the amount and corresponding annual-growth cell without double counting.
--     Both physical row numbers and raw source values remain traceable.
CREATE OR REPLACE TEMP VIEW per_capita_final AS
SELECT
    year,
    max(CASE WHEN row_class = 'amount' THEN metric_value END) AS expenditure_per_capita_php,
    max(CASE WHEN row_class = 'growth' THEN metric_value END) AS growth_rate_pct,
    max(CASE WHEN row_class = 'amount' THEN raw_value END) AS amount_source_value,
    max(CASE WHEN row_class = 'growth' THEN raw_value END) AS growth_source_value,
    max(CASE WHEN row_class = 'amount' THEN value_status END) AS amount_status,
    max(CASE WHEN row_class = 'growth' THEN value_status END) AS growth_status,
    max(CASE WHEN row_class = 'amount' THEN _source_row_num END) AS amount_source_row_num,
    max(CASE WHEN row_class = 'growth' THEN _source_row_num END) AS growth_source_row_num,
    max(_source_key) AS _source_key,
    max(_source_file) AS _source_file,
    max(_source_sheet) AS _source_sheet,
    max(_as_of_date) AS _as_of_date,
    max(_ingested_at) AS _ingested_at,
    coalesce(year IN (2021, 2022), FALSE) AS source_year_revised,
    CASE
        WHEN year <= 2019 THEN '2015_based_projections'
        WHEN year = 2020 THEN '2020_census_actual'
        ELSE 'updated_2020_based_projections'
    END AS population_basis,
    concat(cast(year - 1 AS STRING), '-', cast(year AS STRING)) AS growth_reference_period
FROM per_capita_cells
GROUP BY year;

-- [4] Fail-closed validation: source is eight physical rows (2 data + 6 text).
--     Source row 6 holds period labels; positions 10-12 explain population basis.
CREATE OR REPLACE TEMP VIEW per_capita_gates AS
SELECT
    'Bronze source exactly 8 rows' AS gate,
    abs(count(*) - 8) AS failures
FROM per_capita_source
UNION ALL
SELECT
    'source positions exactly 4,5,6,7,10,11,12,14' AS gate,
    (
        SELECT count(*) FROM per_capita_source AS checked_rows
        WHERE checked_rows._source_row_num NOT IN (4, 5, 6, 7, 10, 11, 12, 14)
    )
    + abs(count(DISTINCT _source_row_num) - 8) AS failures
FROM per_capita_source
UNION ALL
SELECT
    'amount row exactly once' AS gate,
    abs(count(*) - 1) AS failures
FROM per_capita_source
WHERE row_class = 'amount'
UNION ALL
SELECT
    'growth row exactly once' AS gate,
    abs(count(*) - 1) AS failures
FROM per_capita_source
WHERE row_class = 'growth'
UNION ALL
SELECT
    'six nondata source rows' AS gate,
    abs(count(*) - 6) AS failures
FROM per_capita_source
WHERE row_class IN ('subheader', 'population_note', 'source_credit')
UNION ALL
SELECT
    'no unexpected source rows' AS gate,
    count(*) AS failures
FROM per_capita_source
WHERE row_class = 'unexpected'
UNION ALL
SELECT
    'one original source file/version' AS gate,
    CASE
        WHEN
            count(DISTINCT _source_file) = 1
            AND count(DISTINCT _ingested_at) = 1 THEN 0
        ELSE 1
    END AS failures
FROM per_capita_source
UNION ALL
SELECT
    'amount label matches PSA indicator' AS gate,
    count(*) AS failures
FROM per_capita_source
WHERE row_class = 'amount' AND coalesce(trim(indicator), '') <> 'Per Capita Health Expenditure'
UNION ALL
SELECT
    'unpivot creates 16 metric cells' AS gate,
    abs(count(*) - 16) AS failures
FROM per_capita_cells
UNION ALL
SELECT
    'no numeric parse errors' AS gate,
    count(*) AS failures
FROM per_capita_cells
WHERE value_status = 'parse_error'
UNION ALL
SELECT
    'no unpublished annual amount or growth value' AS gate,
    count(*) AS failures
FROM per_capita_cells
WHERE value_status <> 'ok'
UNION ALL
SELECT
    'positive annual expenditure amounts' AS gate,
    count(*) AS failures
FROM per_capita_cells
WHERE row_class = 'amount' AND (metric_value IS NULL OR metric_value <= 0)
UNION ALL
SELECT
    'growth percentages between -100 and 100' AS gate,
    count(*) AS failures
FROM per_capita_cells
WHERE
    row_class = 'growth'
    AND (metric_value IS NULL OR metric_value < -100 OR metric_value > 100)
UNION ALL
SELECT
    'exactly eight unique year records' AS gate,
    abs(count(*) - 8) + abs(count(DISTINCT year) - 8) AS failures
FROM per_capita_final
UNION ALL
SELECT
    'years only 2016 through 2023' AS gate,
    count(*) AS failures
FROM per_capita_final
WHERE year NOT BETWEEN 2016 AND 2023 OR year IS NULL
UNION ALL
SELECT
    'every year paired with both physical source rows' AS gate,
    count(*) AS failures
FROM per_capita_final
WHERE
    amount_source_row_num <> 4 OR growth_source_row_num <> 7
    OR amount_source_row_num IS NULL OR growth_source_row_num IS NULL
UNION ALL
SELECT
    '2023 PSA expenditure control = PHP 11082.68' AS gate,
    CASE
        WHEN count(*) = 1 AND abs(max(expenditure_per_capita_php) - 11082.68) < 0.00001
            THEN 0
        ELSE 1
    END AS failures
FROM per_capita_final
WHERE year = 2023
UNION ALL
SELECT
    '2022 negative growth source control = -2.8%' AS gate,
    CASE
        WHEN count(*) = 1 AND abs(max(growth_rate_pct) - (-2.8)) < 0.00001
            THEN 0
        ELSE 1
    END AS failures
FROM per_capita_final
WHERE year = 2022;

-- [5] Gate failures must be zero before any downstream publication work.
--     Execute this statement in the same session as the temporary views.
SELECT
    assert_true(
        count(*) = 0,
        'Per capita Silver validation gates failed; inspect per_capita_gates.'
    ) AS validation_result
FROM per_capita_gates
WHERE failures IS NULL OR failures <> 0;

-- Manual review (same session):
-- SELECT gate, failures FROM per_capita_gates ORDER BY gate;
-- SELECT * FROM per_capita_final ORDER BY year;
-- PENDING: approved row_disposition and build-input contract; DQRun Silver QC.
-- DO NOT CREATE OR REPLACE TABLE until that integration is approved.
