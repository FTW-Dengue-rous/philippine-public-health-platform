-- PSA Poverty Statistics - Table 2
-- Bronze table: poverty_threshold_incidence_bronze
--
-- Source sheet: tab2
-- Grain: one row per physical source row from tab2.
--
-- Batch behavior:
--   Same source file rerun = replace existing batch.
--   New source file = retain previous batches and add new batch.
--
-- Bronze principle:
--   Preserve source values as strings.
--   Cleaning and interpretation belong in Silver.

CREATE TABLE IF NOT EXISTS public_health.bronze.poverty_threshold_incidence_bronze
(
    c0 STRING,
    c1 STRING,
    c2 STRING,
    c3 STRING,
    c4 STRING,
    c5 STRING,
    c6 STRING,
    c7 STRING,
    c8 STRING,
    c9 STRING,
    c10 STRING,
    c11 STRING,
    c12 STRING,
    c13 STRING,
    c14 STRING,
    c15 STRING,
    c16 STRING,
    c17 STRING,
    c18 STRING,
    c19 STRING,
    _rescued_data STRING,
    _source_file STRING,
    _source_sheet STRING,
    _source_row_num INT,
    _as_of_date DATE,
    _ingested_at TIMESTAMP
)
USING DELTA;

INSERT INTO public_health.bronze.poverty_threshold_incidence_bronze
REPLACE USING (_source_file)

SELECT
    _c0 AS c0,
    _c1 AS c1,
    _c2 AS c2,
    _c3 AS c3,
    _c4 AS c4,
    _c5 AS c5,
    _c6 AS c6,
    _c7 AS c7,
    _c8 AS c8,
    _c9 AS c9,
    _c10 AS c10,
    _c11 AS c11,
    _c12 AS c12,
    _c13 AS c13,
    _c14 AS c14,
    _c15 AS c15,
    _c16 AS c16,
    _c17 AS c17,
    _c18 AS c18,
    _c19 AS c19,
    CAST(NULL AS STRING) AS _rescued_data,
    _metadata.file_name AS _source_file,
    'tab2' AS _source_sheet,
    CAST(NULL AS INT) AS _source_row_num,
    TRY_TO_DATE(
        REGEXP_EXTRACT(
            _metadata.file_name,
            'asof_([0-9]{8})',
            1
        ),
        'yyyyMMdd'
    ) AS _as_of_date,
    CURRENT_TIMESTAMP() AS _ingested_at

FROM READ_FILES(
    '<R2_SOURCE_FILE_PATH>',
    format => 'excel',
    schema => '
        _c0 STRING,
        _c1 STRING,
        _c2 STRING,
        _c3 STRING,
        _c4 STRING,
        _c5 STRING,
        _c6 STRING,
        _c7 STRING,
        _c8 STRING,
        _c9 STRING,
        _c10 STRING,
        _c11 STRING,
        _c12 STRING,
        _c13 STRING,
        _c14 STRING,
        _c15 STRING,
        _c16 STRING,
        _c17 STRING,
        _c18 STRING,
        _c19 STRING
    ',
    dataaddress => 'tab2',
    headerrows => 0,
    schemaevolutionmode => 'none'
);
