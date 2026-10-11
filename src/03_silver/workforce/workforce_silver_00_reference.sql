-- =============================================================================
-- Loads the three reviewed workforce reference CSVs into the silver schema. Run this first, and
-- again whenever a CSV changes. Every column is loaded as text (PSGC codes have leading zeros).
--
--   workforce_area_exceptions.csv       -> public_health.silver.workforce_area_exceptions
--   workforce_area_override.csv         -> public_health.silver.workforce_area_override
--   workforce_psmo_area_exceptions.csv  -> public_health.silver.workforce_psmo_area_exceptions
--
-- The CSVs are drafted by build_workforce_area_exceptions.py, reviewed by a person and kept in
-- the repo (config/reference/). This file only loads them. The build files record each table's
-- Delta version in quality.build_inputs (input_kind = 'table').
-- =============================================================================

-- [1] area exceptions (FHSIS and PSA labels the geography join cannot resolve)
CREATE OR REPLACE TABLE public_health.silver.workforce_area_exceptions AS
SELECT
    _source_key,
    year_from,
    year_to,
    match_role,
    area_label_norm,
    parent_label_norm,
    psgc_code,
    area_key,
    named_key_level,
    named_key_parent_psgc,
    child_region_codes,
    is_superseded_area,
    reason,
    note
FROM read_files(
    '/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/workforce/workforce_area_exceptions.csv',
    format => 'csv',
    header => true,
    multiline => true,
    schema => '_source_key STRING, year_from STRING, year_to STRING, match_role STRING, area_label_norm STRING, parent_label_norm STRING, psgc_code STRING, area_key STRING, named_key_level STRING, named_key_parent_psgc STRING, child_region_codes STRING, is_superseded_area STRING, reason STRING, note STRING'  -- noqa: LT05
);

-- [2] row overrides (G6, G10), each bound to the file version it was written for
CREATE OR REPLACE TABLE public_health.silver.workforce_area_override AS
SELECT
    _source_key,
    _source_file,
    _source_sheet,
    _source_row_num,
    _content_checksum,
    original_label,
    proposed_area_key,
    evidence,
    review_status,
    reviewed_by,
    reviewed_on
FROM read_files(
    '/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/workforce/workforce_area_override.csv',
    format => 'csv',
    header => true,
    multiline => true,
    schema => '_source_key STRING, _source_file STRING, _source_sheet STRING, _source_row_num STRING, _content_checksum STRING, original_label STRING, proposed_area_key STRING, evidence STRING, review_status STRING, reviewed_by STRING, reviewed_on STRING'  -- noqa: LT05
);

-- [3] PSMO exceptions (region labels, NCR districts, composite areas)
CREATE OR REPLACE TABLE public_health.silver.workforce_psmo_area_exceptions AS
SELECT
    _source_key,
    match_role,
    area_label_norm,
    parent_label_norm,
    psgc_code,
    area_key,
    named_key_level,
    named_key_parent_psgc,
    child_region_codes,
    is_composite_area,
    component_psgc_codes,
    reason,
    note
FROM read_files(
    '/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/workforce/workforce_psmo_area_exceptions.csv',
    format => 'csv',
    header => true,
    multiline => true,
    schema => '_source_key STRING, match_role STRING, area_label_norm STRING, parent_label_norm STRING, psgc_code STRING, area_key STRING, named_key_level STRING, named_key_parent_psgc STRING, child_region_codes STRING, is_composite_area STRING, component_psgc_codes STRING, reason STRING, note STRING'  -- noqa: LT05
);

-- [4] checks: each must return 0. A failure stops the run here.
CREATE OR REPLACE TEMP VIEW reference_checks AS
SELECT
    'area exceptions: duplicate key' AS check_name,
    count(*) AS failures
FROM (
    SELECT 1 AS dup
    FROM public_health.silver.workforce_area_exceptions
    GROUP BY _source_key, match_role, year_from, coalesce(parent_label_norm, ''), area_label_norm
    HAVING count(*) > 1
) AS d
UNION ALL
SELECT
    'area exceptions: not exactly one of psgc_code / area_key' AS check_name,
    count(*) AS failures
FROM public_health.silver.workforce_area_exceptions
WHERE (nullif(trim(psgc_code), '') IS null) = (nullif(trim(area_key), '') IS null)
UNION ALL
SELECT
    'area exceptions: year range not readable' AS check_name,
    count(*) AS failures
FROM public_health.silver.workforce_area_exceptions
WHERE
    try_cast(year_from AS INT) IS null
    OR try_cast(year_to AS INT) IS null
    OR try_cast(year_from AS INT) > try_cast(year_to AS INT)
UNION ALL
SELECT
    'area exceptions: region row without child_region_codes' AS check_name,
    count(*) AS failures
FROM public_health.silver.workforce_area_exceptions
WHERE match_role = 'region' AND nullif(trim(child_region_codes), '') IS null
UNION ALL
SELECT
    'override: duplicate bronze row' AS check_name,
    count(*) AS failures
FROM (
    SELECT 1 AS dup
    FROM public_health.silver.workforce_area_override
    GROUP BY _source_key, _source_file, coalesce(_source_sheet, ''), _source_row_num
    HAVING count(*) > 1
) AS d
UNION ALL
SELECT
    'override: review_status not proposed / accepted / rejected' AS check_name,
    count(*) AS failures
FROM public_health.silver.workforce_area_override
WHERE coalesce(lower(trim(review_status)), '') NOT IN ('proposed', 'accepted', 'rejected')
UNION ALL
SELECT
    'override: proposed_area_key is not psgc:<10 digits>' AS check_name,
    count(*) AS failures
FROM public_health.silver.workforce_area_override
WHERE NOT coalesce(proposed_area_key RLIKE '^psgc:[0-9]{10}$', false)
UNION ALL
SELECT
    'override: no checksum (an override must name the file version)' AS check_name,
    count(*) AS failures
FROM public_health.silver.workforce_area_override
WHERE nullif(trim(_content_checksum), '') IS null
UNION ALL
SELECT
    'PSMO exceptions: duplicate key' AS check_name,
    count(*) AS failures
FROM (
    SELECT 1 AS dup
    FROM public_health.silver.workforce_psmo_area_exceptions
    GROUP BY _source_key, match_role, coalesce(parent_label_norm, ''), area_label_norm
    HAVING count(*) > 1
) AS d
UNION ALL
SELECT
    'PSMO exceptions: not exactly one of psgc_code / area_key' AS check_name,
    count(*) AS failures
FROM public_health.silver.workforce_psmo_area_exceptions
WHERE (nullif(trim(psgc_code), '') IS null) = (nullif(trim(area_key), '') IS null)
UNION ALL
SELECT
    'a reference table is empty' AS check_name,
    count_if(n = 0) AS failures
FROM (
    SELECT count(*) AS n FROM public_health.silver.workforce_area_exceptions
    UNION ALL
    SELECT count(*) AS n FROM public_health.silver.workforce_psmo_area_exceptions
) AS t;

SELECT raise_error(concat('Reference check failed: ', check_name, ' = ', failures)) AS err
FROM reference_checks
WHERE failures > 0;

-- [5] result
-- SELECT * FROM reference_checks;
