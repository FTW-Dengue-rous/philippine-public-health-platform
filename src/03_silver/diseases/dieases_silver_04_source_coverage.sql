-- =============================================================================
-- diseases_silver_04_source_coverage.sql
-- Builds public_health.silver.diseases_source_coverage_silver:
-- which periods each source holds in each year.
-- Key: (_source_key, disease_scope, geo_level, period_grain, year)
-- and the view public_health.silver.diseases_metric_wide_v.
--
-- Why it exists: annual comparisons must use the same months on both sides. DOH FOI dengue 2025
-- holds January to September only; gold reads this table to compare like with like.
--
-- Reads the published public_health.silver.diseases_metric_silver, so run it after
-- diseases_silver_01_metric.sql. It has no bronze input and writes no row dispositions.
-- =============================================================================

-- [0] build id and settings
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;

-- =============================================================================
-- [1] input: the metric table (layout of quality.build_inputs)
-- =============================================================================
-- Delta version read. If your runtime rejects DESCRIBE HISTORY in a subquery, delete the
-- SET VAR statement below (the version stays NULL). sqlfluff cannot parse it, hence the noqa.
DECLARE OR REPLACE VARIABLE metric_table_version BIGINT DEFAULT NULL;
SET VAR metric_table_version = ( -- noqa: PRS
    SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_metric_silver) -- noqa: PRS
); -- noqa: PRS

CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver__inputs AS
SELECT
    silver_build_id AS build_id,
    'public_health.silver.diseases_source_coverage_silver' AS target_table,
    'table' AS input_kind,
    'public_health.silver.diseases_metric_silver' AS input_table,
    metric_table_version AS input_table_version,
    cast(NULL AS STRING) AS source_key,
    cast(NULL AS STRING) AS source_file,
    cast(NULL AS STRING) AS source_sheet,
    cast(NULL AS STRING) AS load_batch_id,
    cast(NULL AS STRING) AS content_checksum,
    cast(NULL AS TIMESTAMP) AS ingested_at,
    (SELECT count(*) FROM public_health.silver.diseases_metric_silver) AS input_rows,
    cast(NULL AS STRING) AS reference_version;

-- =============================================================================
-- [2] candidate rows
-- periods_expected 1 for annual rows, 12 for months, 52 for week-number sources.
-- Null for date-based weeks (HDX): the week rule is not confirmed (D4).
-- missing_periods month numbers not present (monthly sources only)
-- min / max_periods_per_area areas do not all cover the same periods (HDX: 208 to 261 weeks)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver__candidate AS
WITH m AS (
    SELECT
        _source_key,
        CASE
            WHEN _source_key IN ('doh_foi_dengue', 'upnoah', 'hdx_dengue') THEN 'dengue'
            WHEN _source_key LIKE 'psa_deaths%' THEN 'psa_causes_of_death'
            WHEN _source_key = 'doh_fhsis' THEN 'tuberculosis'
            WHEN _source_key = 'ihme_gbd' THEN 'ihme_gbd_causes'
        END AS disease_scope,
        geo_level,
        period_grain,
        period_basis,
        year,
        month,
        period_key,
        area_key
    FROM public_health.silver.diseases_metric_silver
),

per_area AS (
    SELECT
        _source_key,
        disease_scope,
        geo_level,
        period_grain,
        year,
        area_key,
        count(DISTINCT period_key) AS periods
    FROM m
    GROUP BY _source_key, disease_scope, geo_level, period_grain, year, area_key
),

a AS (
    SELECT
        _source_key,
        disease_scope,
        geo_level,
        period_grain,
        year,
        count(*) AS areas_present,
        min(periods) AS min_periods_per_area,
        max(periods) AS max_periods_per_area
    FROM per_area
    GROUP BY _source_key, disease_scope, geo_level, period_grain, year
),

g AS (
    SELECT
        _source_key,
        disease_scope,
        geo_level,
        period_grain,
        max(period_basis) AS period_basis,
        year,
        count(DISTINCT period_key) AS periods_present,
        min(period_key) AS first_period,
        max(period_key) AS last_period,
        collect_set(month) AS months_present
    FROM m
    GROUP BY _source_key, disease_scope, geo_level, period_grain, year
)

SELECT
    g._source_key,
    g.disease_scope,
    g.geo_level,
    g.period_grain,
    g.year,
    CASE g.period_grain
        WHEN 'year' THEN 1 WHEN 'month' THEN 12
        WHEN 'week' THEN CASE WHEN g.period_basis = 'week_number_unconfirmed' THEN 52 END
    END AS periods_expected,
    g.periods_present,
    g.first_period,
    g.last_period,
    CASE g.period_grain
        WHEN 'year' THEN TRUE WHEN 'month' THEN g.periods_present = 12
        WHEN 'week' THEN CASE WHEN g.period_basis = 'week_number_unconfirmed' THEN g.periods_present >= 52 END
    END AS is_complete_year,
    CASE
        WHEN g.period_grain = 'month'
            THEN array_join(array_except(sequence(1, 12), g.months_present), ',')
    END AS missing_periods,
    a.areas_present,
    a.min_periods_per_area,
    a.max_periods_per_area,
    silver_build_id AS _silver_build_id -- noqa: RF02
FROM g
INNER JOIN a
    ON
        g._source_key = a._source_key AND g.disease_scope = a.disease_scope AND g.geo_level = a.geo_level
        AND g.period_grain = a.period_grain AND g.year = a.year;

-- =============================================================================
-- [3] gates: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver__gates AS
SELECT
    'key not unique' AS gate,
    count(*) AS failures
FROM (
    SELECT 1 FROM public_health.silver.diseases_source_coverage_silver__candidate
    GROUP BY _source_key, disease_scope, geo_level, period_grain, year
    HAVING count(*) > 1
) AS dup
UNION ALL
SELECT
    'key column is null' AS gate,
    count(*) AS failures
FROM public_health.silver.diseases_source_coverage_silver__candidate
WHERE _source_key IS NULL OR disease_scope IS NULL OR geo_level IS NULL OR period_grain IS NULL OR year IS NULL
UNION ALL
SELECT
    'no rows: is the metric table empty?' AS gate,
    CASE WHEN count(*) = 0 THEN 1 ELSE 0 END AS failures
FROM public_health.silver.diseases_source_coverage_silver__candidate
UNION ALL
SELECT
    'source in the metric table without a coverage row' AS gate,
    count(*) AS failures
FROM (
    SELECT DISTINCT _source_key FROM public_health.silver.diseases_metric_silver
) AS s
LEFT ANTI JOIN public_health.silver.diseases_source_coverage_silver__candidate AS c ON s._source_key = c._source_key;

-- =============================================================================
-- [4] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW cov_build_log AS
SELECT
    silver_build_id AS build_id,
    'silver' AS layer,
    'diseases' AS domain, -- noqa: RF04
    'public_health.silver.diseases_source_coverage_silver' AS target_table,
    silver_build_started_at AS started_at,
    current_timestamp() AS finished_at,
    CASE WHEN failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
    CASE
        WHEN
            failed_gates = 0
            THEN (SELECT count(*) FROM public_health.silver.diseases_source_coverage_silver__candidate)
    END AS row_count, -- noqa: RF04
    cast(NULL AS BIGINT) AS target_table_version, -- filled in [7]
    code_version,
    to_json(named_struct('reads', 'public_health.silver.diseases_metric_silver')) AS parameters, -- noqa: RF04
    job_run_id AS run_id,
    CASE WHEN failed_gates > 0 THEN substr(concat('gates failed: ', failed_names), 1, 500) END AS error_message
FROM (SELECT
    count_if(failures <> 0) AS failed_gates,
    concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
FROM public_health.silver.diseases_source_coverage_silver__gates) AS g;

-- =============================================================================
-- [5] stop here if a gate failed. The failed build is logged first; the published table stays
-- as it was. The staging tables are kept so you can see what failed:
-- SELECT * FROM public_health.silver.diseases_source_coverage_silver__gates WHERE failures <> 0
-- =============================================================================
INSERT INTO public_health.quality.build_log
(
    build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
    target_table_version, code_version, parameters, run_id, error_message
)
SELECT
    build_id,
    layer,
    domain,
    target_table,
    started_at,
    finished_at,
    status,
    row_count,
    target_table_version,
    code_version,
    parameters,
    run_id,
    error_message
FROM cov_build_log
WHERE status = 'failed';

SELECT raise_error(concat('diseases_source_coverage_silver was NOT published. ', error_message))
FROM cov_build_log
WHERE status = 'failed';

-- =============================================================================
-- [6] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_source_coverage_silver AS
SELECT * FROM public_health.silver.diseases_source_coverage_silver__candidate;

-- =============================================================================
-- [7] record the build
-- =============================================================================
-- Delta version just written. If your runtime rejects this, delete the SET VAR statement.
DECLARE OR REPLACE VARIABLE written_table_version BIGINT DEFAULT NULL;
SET VAR written_table_version = ( -- noqa: PRS
    SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_source_coverage_silver) -- noqa: PRS
); -- noqa: PRS

INSERT INTO public_health.quality.build_log
(
    build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
    target_table_version, code_version, parameters, run_id, error_message
)
SELECT
    build_id,
    layer,
    domain,
    target_table,
    started_at,
    finished_at,
    status,
    (SELECT count(*) FROM public_health.silver.diseases_source_coverage_silver) AS row_count, -- noqa: RF04
    written_table_version AS target_table_version,
    code_version,
    parameters,
    run_id,
    error_message
FROM cov_build_log;

INSERT INTO public_health.quality.build_inputs
(
    build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
    source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
)
SELECT
    build_id,
    target_table,
    input_kind,
    input_table,
    input_table_version,
    source_key,
    source_file,
    source_sheet,
    load_batch_id,
    content_checksum,
    ingested_at,
    input_rows,
    reference_version
FROM public_health.silver.diseases_source_coverage_silver__inputs;

DROP TABLE IF EXISTS public_health.silver.diseases_source_coverage_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.diseases_source_coverage_silver__gates;
DROP TABLE IF EXISTS public_health.silver.diseases_source_coverage_silver__inputs;

-- =============================================================================
-- [8] view: measures side by side, INSIDE ONE SOURCE OBSERVATION only (plan 2.2).
-- It never combines sources: reported cases, registered deaths and modelled prevalence do
-- not share a row because disease, area and period happen to match. Bringing sources
-- together is a gold decision, through source_priority.
-- =============================================================================
CREATE OR REPLACE VIEW public_health.silver.diseases_metric_wide_v AS
SELECT
    disease_key,
    area_key,
    period_grain,
    period_key,
    _source_key,
    max(geo_level) AS geo_level,
    max(year) AS year, -- noqa: RF04
    max(month) AS month, -- noqa: RF04
    max(week) AS week, -- noqa: RF04
    max(value_type) AS value_type,
    max(location_basis) AS location_basis,
    max(CASE WHEN measure = 'cases' THEN value END) AS cases,
    max(CASE WHEN measure = 'cases' THEN measure_definition END) AS cases_definition,
    max(CASE WHEN measure = 'cases' THEN value_status END) AS cases_status,
    max(CASE WHEN measure = 'deaths' THEN value END) AS deaths,
    max(CASE WHEN measure = 'deaths' THEN measure_definition END) AS deaths_definition,
    max(CASE WHEN measure = 'deaths' THEN value_status END) AS deaths_status,
    max(CASE WHEN measure = 'prevalence' THEN value END) AS prevalence,
    max(CASE WHEN measure = 'prevalence' THEN measure_definition END) AS prevalence_definition,
    max(CASE WHEN measure = 'prevalence' THEN value_status END) AS prevalence_status
FROM public_health.silver.diseases_metric_silver
GROUP BY disease_key, area_key, period_grain, period_key, _source_key;

-- [9] result
-- SELECT _source_key, geo_level, period_grain, year, periods_expected, periods_present,
-- is_complete_year, missing_periods, areas_present
--FROM public_health.silver.diseases_source_coverage_silver
--ORDER BY _source_key, geo_level, period_grain, year;
