-- Child Mortality Silver publication candidate (Databricks SQL)
-- Based on the supplied read-only 23-gate validation query.
-- This is a SINGLE statement: all gates must pass before any rows qualify for CTAS.
-- Destination uses the team v1.2 naming convention.
-- Review before executing. Does not write to shared quality tables.
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_child_mortality_silver
USING DELTA
AS
WITH source_rows AS (
    SELECT
        b.*,
        CASE
            WHEN b._source_row_num IN (5, 23, 26, 33) THEN 'group_header'
            WHEN
                b._source_row_num BETWEEN 6 AND 22 OR b._source_row_num BETWEEN 24 AND 25
                OR b._source_row_num BETWEEN 27 AND 32 OR b._source_row_num BETWEEN 34 AND 38 THEN 'data'
            WHEN b._source_row_num IN (41, 42, 43, 44, 46) THEN 'source_note'
            ELSE 'unexpected'
        END AS row_class
    FROM public_health.bronze.socioeconomic_psa_child_mortality_bronze AS b
    WHERE b._source_key = 'psa_child_mortality'
),

with_groups AS (
    SELECT
        *,
        last_value(CASE WHEN row_class = 'group_header' THEN trim(characteristic_group) END, true)
            OVER (
                PARTITION BY _source_key, _source_file, _ingested_at
                ORDER BY _source_row_num ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )
            AS group_name
    FROM source_rows
),

metric_cells AS (
    SELECT
        _source_key,
        _source_file,
        _source_sheet,
        _source_row_num,
        _as_of_date,
        _ingested_at,
        group_name AS characteristic_group,
        trim(characteristic) AS characteristic,
        survey_year,
        mortality_metric,
        raw_value,
        CASE
            WHEN trim(raw_value) = '*' THEN 'suppressed'
            WHEN trim(raw_value) RLIKE '^[(][0-9]+([.][0-9]+)?[)]$' THEN 'low_precision'
            WHEN trim(raw_value) RLIKE '^[0-9]+([.][0-9]+)?$' THEN 'ok'
            WHEN raw_value IS null OR trim(raw_value) = '' THEN 'missing'
            ELSE 'unexpected'
        END AS value_status,
        try_cast(regexp_replace(trim(raw_value), '[()]', '') AS DOUBLE) AS mortality_rate_per_1000
    FROM (
        SELECT
            _source_key,
            _source_file,
            _source_sheet,
            _source_row_num,
            _as_of_date,
            _ingested_at,
            group_name,
            characteristic,
            stack(
                6,
                2022, 'infant', imr_2022,
                2017, 'infant', imr_2017,
                2022, 'child', cmr_2022,
                2017, 'child', cmr_2017,
                2022, 'under_five', u5mr_2022,
                2017, 'under_five', u5mr_2017
            ) AS (survey_year, mortality_metric, raw_value)
        FROM with_groups
        WHERE row_class = 'data'
    ) AS x
),

silver_candidate AS (
    SELECT
        characteristic_group,
        characteristic,
        survey_year,
        max(CASE
            WHEN mortality_metric = 'infant'
                THEN mortality_rate_per_1000
        END) AS infant_mortality_rate,
        max(CASE
            WHEN mortality_metric = 'child'
                THEN mortality_rate_per_1000
        END) AS child_mortality_rate,
        max(CASE
            WHEN mortality_metric = 'under_five'
                THEN mortality_rate_per_1000
        END) AS under5_mortality_rate,
        max(CASE
            WHEN mortality_metric = 'infant'
                THEN value_status
        END) AS infant_mortality_reliability,
        max(CASE
            WHEN mortality_metric = 'child'
                THEN value_status
        END) AS child_mortality_reliability,
        max(CASE
            WHEN mortality_metric = 'under_five'
                THEN value_status
        END) AS under5_mortality_reliability,
        max(CASE
            WHEN mortality_metric = 'infant'
                THEN raw_value
        END) AS infant_mortality_raw,
        max(CASE
            WHEN mortality_metric = 'child'
                THEN raw_value
        END) AS child_mortality_raw,
        max(CASE
            WHEN mortality_metric = 'under_five'
                THEN raw_value
        END) AS under5_mortality_raw,
        max(_source_key) AS _source_key,
        max(_source_file) AS _source_file,
        max(_source_sheet) AS _source_sheet,
        max(_source_row_num) AS _source_row_num,
        max(_as_of_date) AS _as_of_date,
        max(_ingested_at) AS _ingested_at
    FROM metric_cells
    GROUP BY characteristic_group, characteristic, survey_year
),

validation_gates AS (
    SELECT
        '01 | Bronze has exactly 39 physical rows' AS gate,
        abs(count(*) - 39) AS failures
    FROM source_rows
    UNION ALL
    SELECT
        '02 | Physical positions exactly match source' AS gate,
        (
            SELECT count(*) FROM source_rows AS checked_rows
            WHERE checked_rows._source_row_num IS null OR NOT (
                checked_rows._source_row_num BETWEEN 5 AND 38
                OR checked_rows._source_row_num IN (41, 42, 43, 44, 46)
            )
        )
        + abs(count(DISTINCT _source_row_num) - 39) AS failures
    FROM source_rows
    UNION ALL
    SELECT
        '03 | Exactly four group headers' AS gate,
        abs(count(*) - 4) AS failures
    FROM source_rows
    WHERE row_class = 'group_header'
    UNION ALL
    SELECT
        '04 | Exactly thirty data rows' AS gate,
        abs(count(*) - 30) AS failures
    FROM source_rows
    WHERE row_class = 'data'
    UNION ALL
    SELECT
        '05 | Exactly five notes/source rows' AS gate,
        abs(count(*) - 5) AS failures
    FROM source_rows
    WHERE row_class = 'source_note'
    UNION ALL
    SELECT
        '06 | No unexpected source rows' AS gate,
        count(*) AS failures
    FROM source_rows
    WHERE row_class = 'unexpected'
    UNION ALL
    SELECT
        '07 | One source file and ingestion version' AS gate,
        CASE WHEN count(DISTINCT _source_file) = 1 AND count(DISTINCT _ingested_at) = 1 THEN 0 ELSE 1 END AS failures
    FROM source_rows
    UNION ALL
    SELECT
        '08 | Group header labels recognized' AS gate,
        count(*) AS failures
    FROM source_rows
    WHERE
        row_class = 'group_header' AND (
            trim(characteristic_group) NOT IN
            ('Region', 'Residence', "Mother's Education", 'Wealth quintile') OR characteristic IS NOT null
        )
    UNION ALL
    SELECT
        '09 | Data rows have characteristic' AS gate,
        count(*) AS failures
    FROM with_groups
    WHERE row_class = 'data' AND (characteristic IS null OR trim(characteristic) = '')
    UNION ALL
    SELECT
        '10 | Data rows carry correct group' AS gate,
        count(*) AS failures
    FROM with_groups
    WHERE
        row_class = 'data' AND (
            group_name IS null
            OR CASE
                WHEN _source_row_num BETWEEN 6 AND 22 THEN group_name <> 'Region'
                WHEN _source_row_num BETWEEN 24 AND 25 THEN group_name <> 'Residence'
                WHEN _source_row_num BETWEEN 27 AND 32 THEN group_name <> "Mother's Education"
                ELSE group_name <> 'Wealth quintile'
            END
        )
    UNION ALL
    SELECT
        '11 | Exactly 180 metric cells' AS gate,
        abs(count(*) - 180) AS failures
    FROM metric_cells
    UNION ALL
    SELECT
        '12 | All metric formats recognized' AS gate,
        count(*) AS failures
    FROM metric_cells
    WHERE value_status IN ('missing', 'unexpected')
    UNION ALL
    SELECT
        '13 | Precisely 165 ordinary numeric cells' AS gate,
        abs(count(*) - 165) AS failures
    FROM metric_cells
    WHERE value_status = 'ok'
    UNION ALL
    SELECT
        '14 | Precisely 10 low-precision cells' AS gate,
        abs(count(*) - 10) AS failures
    FROM metric_cells
    WHERE value_status = 'low_precision'
    UNION ALL
    SELECT
        '15 | Precisely 5 suppressed cells' AS gate,
        abs(count(*) - 5) AS failures
    FROM metric_cells
    WHERE value_status = 'suppressed'
    UNION ALL
    SELECT
        '16 | Numeric/null handling is faithful' AS gate,
        count(*) AS failures
    FROM metric_cells
    WHERE
        (value_status = 'suppressed' AND mortality_rate_per_1000 IS NOT null)
        OR (value_status IN ('ok', 'low_precision') AND mortality_rate_per_1000 IS null)
    UNION ALL
    SELECT
        '17 | Unique complete grain and valid survey years/metrics' AS gate,
        (SELECT count(*) FROM (
            SELECT
                characteristic_group,
                characteristic,
                survey_year,
                mortality_metric,
                count(*) AS n
            FROM metric_cells
            GROUP BY characteristic_group, characteristic, survey_year, mortality_metric
            HAVING
                count(*) <> 1 OR characteristic_group IS null OR characteristic IS null
                OR survey_year NOT IN (2017, 2022) OR mortality_metric NOT IN ('infant', 'child', 'under_five')
        ) AS duplicate_keys)
        + abs(count(*) - 180) AS failures
    FROM metric_cells
    UNION ALL
    SELECT
        '18 | Exactly 60 wide Silver records' AS gate,
        abs(count(*) - 60) AS failures
    FROM silver_candidate
    UNION ALL
    SELECT
        '19 | Unique, non-null wide Silver keys' AS gate,
        (SELECT count(*) FROM (
            SELECT
                characteristic_group,
                characteristic,
                survey_year,
                count(*) AS n
            FROM silver_candidate
            GROUP BY characteristic_group, characteristic, survey_year
            HAVING
                count(*) <> 1
                OR characteristic_group IS null
                OR characteristic IS null
                OR survey_year NOT IN (2017, 2022)
        ) AS bad_keys) AS failures
    UNION ALL
    SELECT
        '20 | All three reliability statuses present' AS gate,
        count(*) AS failures
    FROM silver_candidate
    WHERE
        infant_mortality_reliability IS null
        OR child_mortality_reliability IS null
        OR under5_mortality_reliability IS null
    UNION ALL
    SELECT
        '21 | Wide raw values match source metric cells' AS gate,
        count(*) AS failures
    FROM metric_cells AS m
    INNER JOIN silver_candidate AS s
        ON
            m.characteristic_group = s.characteristic_group
            AND m.characteristic = s.characteristic
            AND m.survey_year = s.survey_year
    WHERE
        NOT (
            m.raw_value <=> CASE m.mortality_metric
                WHEN 'infant' THEN s.infant_mortality_raw
                WHEN 'child' THEN s.child_mortality_raw
                WHEN 'under_five' THEN s.under5_mortality_raw
            END
        )
    UNION ALL
    SELECT
        '22 | Consistent source lineage within each Silver key' AS gate,
        count(*) AS failures
    FROM (
        SELECT
            characteristic_group,
            characteristic,
            survey_year
        FROM metric_cells
        GROUP BY characteristic_group, characteristic, survey_year
        HAVING count(DISTINCT named_struct(
            'source_key', _source_key,
            'source_file', _source_file,
            'source_sheet', _source_sheet,
            'source_row_num', _source_row_num,
            'as_of_date', _as_of_date,
            'ingested_at', _ingested_at
        )) <> 1
    ) AS inconsistent_lineage
    UNION ALL
    SELECT
        '23 | PSA control values: NCR 2022 IMR=8, BARMM 2017 U5MR=55' AS gate,
        CASE WHEN (
            SELECT count(*)
            FROM metric_cells
            WHERE
                characteristic_group = 'Region' AND characteristic = 'NCR'
                AND survey_year = 2022 AND mortality_metric = 'infant' AND mortality_rate_per_1000 = 8
        ) = 1
        AND (
            SELECT count(*)
            FROM metric_cells
            WHERE
                characteristic_group = 'Region' AND characteristic = 'BARMM'
                AND survey_year = 2017 AND mortality_metric = 'under_five' AND mortality_rate_per_1000 = 55
        ) = 1
            THEN 0
        ELSE 1 END AS failures
),

validated AS (
    SELECT
        assert_true(
            coalesce(sum(CASE WHEN failures IS null OR failures <> 0 THEN 1 ELSE 0 END), 0) = 0
            AND count(*) = 23,
            'Child mortality Silver publication blocked: one or more validation gates failed'
        ) AS assertion_result
    FROM validation_gates
)

SELECT s.*
FROM silver_candidate AS s
CROSS JOIN validated AS v
WHERE v.assertion_result IS null;
