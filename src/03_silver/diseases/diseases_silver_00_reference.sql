-- =============================================================================
-- Loads the four reviewed reference CSVs into the silver schema. Run this first, and again
-- whenever a CSV changes. Every column is loaded as text (PSGC codes have leading zeros).
--
-- diseases_area_map.csv -> public_health.silver.diseases_area_map
-- diseases_cause_map.csv -> public_health.silver.diseases_cause_map
-- diseases_directory.csv -> public_health.silver.diseases_directory_silver
-- diseases_cause_aggregation.csv -> public_health.silver.diseases_cause_aggregation
--
-- The CSVs are drafted by build_diseases_reference_maps.py, which are stored in g5_landing/reference/diseases
-- =============================================================================

-- [1] area map
CREATE OR REPLACE TABLE public_health.silver.diseases_area_map AS
SELECT
    _source_key,
    match_type,
    match_value,
    parent_label_norm,
    year_from,
    year_to,
    area_label_source,
    area_key,
    psgc_code,
    geo_level,
    parent_area_key,
    geo_coverage_basis,
    is_superseded_area,
    override_source_file,
    override_source_sheet,
    override_source_row_num,
    override_content_checksum,
    review_note
FROM read_files(
    '/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/diseases/diseases_area_map.csv',
    format => 'csv', header => true, multiline => true,
    schema => '_source_key STRING, match_type STRING, match_value STRING, parent_label_norm STRING, year_from STRING, year_to STRING, area_label_source STRING, area_key STRING, psgc_code STRING, geo_level STRING, parent_area_key STRING, geo_coverage_basis STRING, is_superseded_area STRING, override_source_file STRING, override_source_sheet STRING, override_source_row_num STRING, override_content_checksum STRING, review_note STRING'  -- noqa: LT05
);

-- [2] cause map
CREATE OR REPLACE TABLE public_health.silver.diseases_cause_map AS
SELECT
    _source_key,
    match_type,
    match_value,
    row_class,
    reason,
    disease_key,
    source_cause_code,
    review_note
FROM read_files(
    '/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/diseases/diseases_cause_map.csv',
    format => 'csv', header => true, multiline => true,
    schema => '_source_key STRING, match_type STRING, match_value STRING, row_class STRING, reason STRING, disease_key STRING, source_cause_code STRING, review_note STRING'  -- noqa: LT05
);

-- [3] directory
CREATE OR REPLACE TABLE public_health.silver.diseases_directory_silver AS
SELECT
    disease_key,
    disease_name,
    classification,
    psa_cause_code,
    icd10_range,
    ihme_cause_id,
    cause_level,
    parent_disease_key,
    has_children_in_source,
    related_condition_group,
    is_focus_disease,
    review_note
FROM read_files(
    '/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/diseases/diseases_directory.csv',
    format => 'csv', header => true, multiline => true,
    schema => 'disease_key STRING, disease_name STRING, classification STRING, psa_cause_code STRING, icd10_range STRING, ihme_cause_id STRING, cause_level STRING, parent_disease_key STRING, has_children_in_source STRING, related_condition_group STRING, is_focus_disease STRING, review_note STRING'  -- noqa: LT05
);

-- [4] aggregation sets
CREATE OR REPLACE TABLE public_health.silver.diseases_cause_aggregation AS
SELECT
    aggregation_set,
    disease_key,
    category,
    year_from,
    year_to,
    reconciles_to,
    review_note
FROM read_files(
    '/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/diseases/diseases_cause_aggregation.csv',
    format => 'csv', header => true, multiline => true,
    schema => 'aggregation_set STRING, disease_key STRING, category STRING, year_from STRING, year_to STRING, reconciles_to STRING, review_note STRING'  -- noqa: LT05
);

-- [5] checks: each must return 0. A failure stops the run here.
CREATE OR REPLACE TEMP VIEW reference_checks AS
SELECT
    'area map: duplicate key' AS check_name,
    count(*) AS failures
FROM (
    SELECT 1 FROM public_health.silver.diseases_area_map
    GROUP BY _source_key, match_type, match_value, coalesce(parent_label_norm, ''), coalesce(year_from, '')
    HAVING count(*) > 1
) AS dup
UNION ALL
SELECT
    'cause map: duplicate key' AS check_name,
    count(*) AS failures
FROM (
    SELECT 1 FROM public_health.silver.diseases_cause_map
    GROUP BY _source_key, match_type, match_value
    HAVING count(*) > 1
) AS dup
UNION ALL
SELECT
    'directory: duplicate disease_key' AS check_name,
    count(*) AS failures
FROM (
    SELECT 1 FROM public_health.silver.diseases_directory_silver
    GROUP BY disease_key
    HAVING count(*) > 1
) AS dup
UNION ALL
SELECT
    'aggregation: duplicate key' AS check_name,
    count(*) AS failures
FROM (
    SELECT 1 FROM public_health.silver.diseases_cause_aggregation
    GROUP BY aggregation_set, disease_key
    HAVING count(*) > 1
) AS dup
UNION ALL
SELECT
    'cause map: disease_key missing from the directory' AS check_name,
    count(*) AS failures
FROM (
    SELECT DISTINCT disease_key FROM public_health.silver.diseases_cause_map
    WHERE disease_key IS NOT null
) AS c
LEFT ANTI JOIN public_health.silver.diseases_directory_silver AS d ON c.disease_key = d.disease_key
UNION ALL
SELECT
    'aggregation: disease_key missing from the directory' AS check_name,
    count(*) AS failures
FROM public_health.silver.diseases_cause_aggregation AS a
LEFT ANTI JOIN public_health.silver.diseases_directory_silver AS d ON a.disease_key = d.disease_key
UNION ALL
SELECT
    'a reference table is empty' AS check_name,
    count_if(n = 0) AS failures
FROM (
    SELECT count(*) AS n FROM public_health.silver.diseases_area_map
    UNION ALL
    SELECT count(*) AS n FROM public_health.silver.diseases_cause_map
    UNION ALL
    SELECT count(*) FROM public_health.silver.diseases_directory_silver
    UNION ALL
    SELECT count(*) FROM public_health.silver.diseases_cause_aggregation
) AS counts;

SELECT raise_error(concat('Reference check failed: ', check_name, ' = ', failures))
FROM reference_checks
WHERE failures > 0;

-- [6] result
SELECT * FROM reference_checks;
