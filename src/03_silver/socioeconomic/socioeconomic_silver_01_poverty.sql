-- =============================================================================
-- Builds public_health.silver.socioeconomic_poverty_silver:
--   official poverty statistics of one area in one reporting year.
--   Key: (area_key, year)
-- Source: PSA official poverty statistics, sheets tab2 (annual per capita poverty threshold and
--   poverty incidence among POPULATION) and tab6 (magnitude of poor POPULATION), full year,
--   2021 / 2023 / 2025. One row of each sheet becomes up to three silver rows (one per year),
--   and the two sheets are combined by area and year.
--
-- Build sequence (lineage-qc-contract.md v1.3, section 5.1)
--   [0] build id and settings
--   [1] classify every bronze row with the area map       -> ..._silver__classified
--   [2] capture the inputs (sheets, loads, table versions)  -> ..._silver__inputs
--   [3] cells: one row per area, year and metric            -> ..._silver__cells
--   [4] candidate rows                                      -> ..._silver__candidate
--   [5] gates and output validation                         -> ..._silver__gates
--   [6] build log row. [7] stop if a gate failed
--   [8] write the table. [9] record the build. [10] summary, remove the staging tables
--
-- Needs: socioeconomic_silver_00_reference.sql and quality_setup.sql have been run.
--
-- Lineage on the silver row (9 columns): _silver_build_id, _source_key, _source_file, _as_of_date,
--   _incidence_source_sheet, _incidence_source_row_num, _magnitude_source_sheet,
--   _magnitude_source_row_num, _metric_source_columns ({poverty_incidence_pct: 'incidence_2025', ...}).
--   Load time, load id and file checksum are NOT on the row. They are in quality.build_inputs:
--     JOIN public_health.quality.v_build_lineage v
--       ON  v.build_id = s._silver_build_id
--       AND v.target_table = 'public_health.silver.socioeconomic_poverty_silver'
--       AND v.source_key = s._source_key AND v.source_file = s._source_file
--       AND v.source_sheet <=> s._incidence_source_sheet       (or _magnitude_source_sheet)
-- =============================================================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
-- true : every input needs exactly one processed ingestion_metadata row (contract 3.5).
-- false: a missing row is allowed, and that input gets a null load id and checksum.
--        Use false only while the bronze B13 warnings are open.
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job

-- Text to number: spaces and thousands separators removed. Null when it is not a number.
CREATE OR REPLACE TEMPORARY FUNCTION se_num(s STRING) RETURNS DECIMAL(20,4)
RETURN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4));

-- Status of one poverty cell. Blank = no estimate published. '-' = not computed by PSA.
-- Anything else that is not a number is a parse_error.
CREATE OR REPLACE TEMPORARY FUNCTION se_poverty_status(s STRING) RETURNS STRING
RETURN CASE WHEN s IS NULL OR trim(s) = '' THEN 'not_published'
            WHEN trim(s) = '-' THEN 'not_computed'
            WHEN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4)) IS NOT NULL THEN 'ok'
            ELSE 'parse_error' END;

-- Which lineage group (sheet) each silver metric column belongs to.
-- Same content as metric_groups in the table config (contract section 3.6).
CREATE OR REPLACE TEMP VIEW poverty_metric_groups AS
SELECT * FROM VALUES
  ('threshold',         'annual_per_capita_poverty_threshold_php', 'incidence', 'tab2'),
  ('incidence',         'poverty_incidence_pct',   'incidence', 'tab2'),
  ('incidence_cv',      'incidence_cv_pct',        'incidence', 'tab2'),
  ('incidence_se',      'incidence_se_pp',         'incidence', 'tab2'),
  ('incidence_ci_low',  'incidence_ci_low_pct',    'incidence', 'tab2'),
  ('incidence_ci_high', 'incidence_ci_high_pct',   'incidence', 'tab2'),
  ('poor_pop',          'poor_population',         'magnitude', 'tab6'),
  ('poor_pop_cv',       'poor_population_cv_pct',  'magnitude', 'tab6'),
  ('poor_pop_se',       'poor_population_se',      'magnitude', 'tab6'),
  ('poor_pop_ci_low',   'poor_population_ci_low',  'magnitude', 'tab6'),
  ('poor_pop_ci_high',  'poor_population_ci_high', 'magnitude', 'tab6')
  AS t(metric, silver_column, lineage_group, source_sheet);


-- =============================================================================
-- [1] classify every bronze row. A row is a data row because its area is in the approved
--     area map, never because its values happen to be numbers.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_poverty_silver__classified AS
SELECT 'public_health.bronze.socioeconomic_psa_poverty_bronze' AS input_table,
       b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._ingested_at,
       m.area_key,
       CASE
         WHEN m.area_key IS NOT NULL THEN 'data'
         WHEN b.area_name IS NULL
              AND coalesce(b.threshold_2021, b.threshold_2023, b.threshold_2025,
                           b.incidence_2021, b.incidence_2023, b.incidence_2025,
                           b.poor_pop_2021,  b.poor_pop_2023,  b.poor_pop_2025) IS NULL THEN 'non_data'
         WHEN trim(b.area_name) RLIKE '^(Notes:|r[0-9]+ -|[0-9]+/|[a-z]/)' THEN 'non_data'
         ELSE 'unclassified'
       END AS row_class,
       CASE
         WHEN m.area_key IS NOT NULL THEN CAST(NULL AS STRING)
         WHEN b.area_name IS NULL
              AND coalesce(b.threshold_2021, b.threshold_2023, b.threshold_2025,
                           b.incidence_2021, b.incidence_2023, b.incidence_2025,
                           b.poor_pop_2021,  b.poor_pop_2023,  b.poor_pop_2025) IS NULL THEN 'junk_row'
         WHEN trim(b.area_name) RLIKE '^(Notes:|r[0-9]+ -|[0-9]+/|[a-z]/)' THEN 'footnote'
         ELSE 'area_not_in_map'
       END AS reason
FROM public_health.bronze.socioeconomic_psa_poverty_bronze b
LEFT JOIN public_health.silver.socioeconomic_poverty_area_map m
       ON trim(b.area_name) = m.geo_name_source
WHERE b._source_key = 'psa_poverty';


-- =============================================================================
-- [2] inputs (layout of quality.build_inputs). The ingestion log is looked up once per sheet.
-- =============================================================================
-- Delta version of each table read. If your runtime rejects DESCRIBE HISTORY in a subquery,
-- use the NULL version below instead (the build still works, versions are just not recorded).
CREATE OR REPLACE TEMP VIEW poverty_table_versions AS
SELECT 'public_health.bronze.socioeconomic_psa_poverty_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.socioeconomic_psa_poverty_bronze)) AS table_version
UNION ALL SELECT 'public_health.silver.socioeconomic_poverty_area_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.socioeconomic_poverty_area_map));
-- NULL version (use this instead if the view above fails):
-- CREATE OR REPLACE TEMP VIEW poverty_table_versions AS
-- SELECT CAST(NULL AS STRING) AS table_name, CAST(NULL AS BIGINT) AS table_version WHERE 1 = 0

CREATE OR REPLACE TABLE public_health.silver.socioeconomic_poverty_silver__inputs AS
WITH sheets AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.socioeconomic_poverty_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT silver_build_id      AS build_id,
       'public_health.silver.socioeconomic_poverty_silver' AS target_table,
       'bronze_source'      AS input_kind,
       f.input_table,
       max(v.table_version) AS input_table_version,
       f._source_key        AS source_key,
       f._source_file       AS source_file,
       f._source_sheet      AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END         AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at       AS ingested_at,
       f.input_rows,
       CAST(NULL AS STRING) AS reference_version,
       count(m.batch_id)    AS metadata_matches      -- gate only, not appended
FROM sheets f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key
 AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet
 AND m.retrieved_at = f._ingested_at
LEFT JOIN poverty_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
-- the reference table that shaped the build
SELECT silver_build_id, 'public_health.silver.socioeconomic_poverty_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.socioeconomic_poverty_area_map' AS table_name, count(*) AS n
      FROM public_health.silver.socioeconomic_poverty_area_map) t
LEFT JOIN poverty_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] cells: one row per area, year and metric, with the parsed value and its status
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_poverty_silver__cells AS
WITH long AS (
  SELECT c.area_key, b._source_sheet, b._source_row_num,
         stack(18,
           2021, 'threshold', b.threshold_2021,  2023, 'threshold', b.threshold_2023,  2025, 'threshold', b.threshold_2025,
           2021, 'incidence', b.incidence_2021,  2023, 'incidence', b.incidence_2023,  2025, 'incidence', b.incidence_2025,
           2021, 'incidence_cv', b.incidence_cv_2021,  2023, 'incidence_cv', b.incidence_cv_2023,  2025, 'incidence_cv', b.incidence_cv_2025,
           2021, 'incidence_se', b.incidence_se_2021,  2023, 'incidence_se', b.incidence_se_2023,  2025, 'incidence_se', b.incidence_se_2025,
           2021, 'incidence_ci_low', b.incidence_ci_low_2021,  2023, 'incidence_ci_low', b.incidence_ci_low_2023,  2025, 'incidence_ci_low', b.incidence_ci_low_2025,
           2021, 'incidence_ci_high', b.incidence_ci_high_2021, 2023, 'incidence_ci_high', b.incidence_ci_high_2023, 2025, 'incidence_ci_high', b.incidence_ci_high_2025
         ) AS (year, metric, raw)
  FROM public_health.bronze.socioeconomic_psa_poverty_bronze b
  JOIN public_health.silver.socioeconomic_poverty_silver__classified c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'psa_poverty' AND c.row_class = 'data' AND b._source_sheet = 'tab2'
  UNION ALL
  SELECT c.area_key, b._source_sheet, b._source_row_num,
         stack(15,
           2021, 'poor_pop', b.poor_pop_2021,  2023, 'poor_pop', b.poor_pop_2023,  2025, 'poor_pop', b.poor_pop_2025,
           2021, 'poor_pop_cv', b.poor_pop_cv_2021,  2023, 'poor_pop_cv', b.poor_pop_cv_2023,  2025, 'poor_pop_cv', b.poor_pop_cv_2025,
           2021, 'poor_pop_se', b.poor_pop_se_2021,  2023, 'poor_pop_se', b.poor_pop_se_2023,  2025, 'poor_pop_se', b.poor_pop_se_2025,
           2021, 'poor_pop_ci_low', b.poor_pop_ci_low_2021,  2023, 'poor_pop_ci_low', b.poor_pop_ci_low_2023,  2025, 'poor_pop_ci_low', b.poor_pop_ci_low_2025,
           2021, 'poor_pop_ci_high', b.poor_pop_ci_high_2021, 2023, 'poor_pop_ci_high', b.poor_pop_ci_high_2023, 2025, 'poor_pop_ci_high', b.poor_pop_ci_high_2025
         ) AS (year, metric, raw)
  FROM public_health.bronze.socioeconomic_psa_poverty_bronze b
  JOIN public_health.silver.socioeconomic_poverty_silver__classified c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'psa_poverty' AND c.row_class = 'data' AND b._source_sheet = 'tab6'
)
SELECT l.area_key, l._source_sheet, l._source_row_num, l.year, l.metric,
       concat(l.metric, '_', l.year) AS source_column,
       g.silver_column, g.lineage_group, g.source_sheet AS expected_sheet,
       l.raw,
       se_num(l.raw)            AS value,
       se_poverty_status(l.raw) AS value_status
FROM long l
LEFT JOIN poverty_metric_groups g ON g.metric = l.metric;


-- =============================================================================
-- [4] candidate rows. The two sheets are combined by area_key and year with an aggregation,
--     so the combination cannot multiply rows. Expected area-years come from the area map.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_poverty_silver__candidate AS
WITH expected AS (
  SELECT m.area_key, y.year
  FROM public_health.silver.socioeconomic_poverty_area_map m
  CROSS JOIN (SELECT explode(array(2021, 2023, 2025)) AS year) y
  WHERE y.year >= try_cast(m.first_estimate_year AS INT)
),
wide AS (
  SELECT e.area_key, e.year,
         max(CASE WHEN c.metric = 'threshold'         THEN c.value END) AS threshold,
         max(CASE WHEN c.metric = 'incidence'         THEN c.value END) AS incidence,
         max(CASE WHEN c.metric = 'incidence_cv'      THEN c.value END) AS incidence_cv,
         max(CASE WHEN c.metric = 'incidence_se'      THEN c.value END) AS incidence_se,
         max(CASE WHEN c.metric = 'incidence_ci_low'  THEN c.value END) AS incidence_ci_low,
         max(CASE WHEN c.metric = 'incidence_ci_high' THEN c.value END) AS incidence_ci_high,
         max(CASE WHEN c.metric = 'poor_pop'          THEN c.value END) AS poor_pop,
         max(CASE WHEN c.metric = 'poor_pop_cv'       THEN c.value END) AS poor_pop_cv,
         max(CASE WHEN c.metric = 'poor_pop_se'       THEN c.value END) AS poor_pop_se,
         max(CASE WHEN c.metric = 'poor_pop_ci_low'   THEN c.value END) AS poor_pop_ci_low,
         max(CASE WHEN c.metric = 'poor_pop_ci_high'  THEN c.value END) AS poor_pop_ci_high,
         max(CASE WHEN c._source_sheet = 'tab2' THEN c._source_row_num END) AS incidence_row_num,
         max(CASE WHEN c._source_sheet = 'tab6' THEN c._source_row_num END) AS magnitude_row_num,
         map_from_entries(collect_list(struct(c.silver_column, c.source_column))) AS metric_source_columns
  FROM expected e
  JOIN public_health.silver.socioeconomic_poverty_silver__cells c
    ON c.area_key = e.area_key AND c.year = e.year
  GROUP BY e.area_key, e.year
),
notes AS (                     -- the notes text and shared lineage of each area's two bronze rows
  SELECT c.area_key,
         max(CASE WHEN b._source_sheet = 'tab2' THEN b.notes END) AS incidence_notes,
         max(CASE WHEN b._source_sheet = 'tab6' THEN b.notes END) AS magnitude_notes,
         max(b._source_key)  AS _source_key,
         max(b._source_file) AS _source_file,
         max(b._as_of_date)  AS _as_of_date
  FROM public_health.bronze.socioeconomic_psa_poverty_bronze b
  JOIN public_health.silver.socioeconomic_poverty_silver__classified c
    ON c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'psa_poverty' AND c.row_class = 'data'
  GROUP BY c.area_key
)
SELECT
  -- area (from the area map)
  m.area_key, m.geo_name_source, m.geo_level, m.psgc_code, m.parent_geo_name_source,
  m.geo_coverage_basis,
  CAST(m.coverage_confirmed  AS BOOLEAN) AS coverage_confirmed,
  CAST(m.comparison_eligible AS BOOLEAN) AS comparison_eligible,
  m.exclusion_reason,
  CAST(m.is_superseded_area  AS BOOLEAN) AS is_superseded_area,
  -- period and basis
  w.year,
  'population' AS poverty_population_basis,
  'full_year'  AS reporting_period,
  -- incidence (tab2)
  CAST(w.threshold         AS DECIMAL(12,2)) AS annual_per_capita_poverty_threshold_php,
  CAST(w.incidence         AS DECIMAL(5,1))  AS poverty_incidence_pct,
  CAST(w.incidence_cv      AS DECIMAL(7,2))  AS incidence_cv_pct,
  CAST(w.incidence_se      AS DECIMAL(7,2))  AS incidence_se_pp,
  CAST(w.incidence_ci_low  AS DECIMAL(5,1))  AS incidence_ci_low_pct,
  CAST(w.incidence_ci_high AS DECIMAL(5,1))  AS incidence_ci_high_pct,
  -- magnitude (tab6). The source is in thousands, silver is in persons.
  CAST(round(w.poor_pop * 1000)         AS BIGINT) AS poor_population,
  CAST(w.poor_pop_cv                    AS DECIMAL(7,2)) AS poor_population_cv_pct,
  CAST(round(w.poor_pop_se * 1000)      AS BIGINT) AS poor_population_se,
  CAST(round(w.poor_pop_ci_low * 1000)  AS BIGINT) AS poor_population_ci_low,
  CAST(round(w.poor_pop_ci_high * 1000) AS BIGINT) AS poor_population_ci_high,
  -- precision: unknown when the CV is not available, never assumed to be ok
  CASE WHEN w.incidence_cv IS NULL THEN 'unknown'
       WHEN w.incidence_cv > 10    THEN 'use_with_caution' ELSE 'ok' END AS incidence_precision,
  CASE WHEN w.poor_pop_cv IS NULL THEN 'unknown'
       WHEN w.poor_pop_cv > 10    THEN 'use_with_caution' ELSE 'ok' END AS poor_population_precision,
  -- notes 1/ (2021 to 2023) and 2/ (2023 to 2025): the change is statistically significant
  CASE w.year WHEN 2023 THEN coalesce(n.incidence_notes, '') RLIKE '(^|[ ,])1/'
              WHEN 2025 THEN coalesce(n.incidence_notes, '') RLIKE '(^|[ ,])2/' END AS is_incidence_change_significant,
  CASE w.year WHEN 2023 THEN coalesce(n.magnitude_notes, '') RLIKE '(^|[ ,])1/'
              WHEN 2025 THEN coalesce(n.magnitude_notes, '') RLIKE '(^|[ ,])2/' END AS is_poor_population_change_significant,
  -- note c/: the published 0 means "below 0.05", not an exact zero
  (coalesce(n.incidence_notes, '') RLIKE '(^|[ ,])c/' AND w.incidence = 0) AS is_incidence_below_0_05,
  (coalesce(n.magnitude_notes, '') RLIKE '(^|[ ,])c/' AND w.poor_pop = 0)  AS is_poor_population_below_50,
  n.incidence_notes AS incidence_source_notes,
  n.magnitude_notes AS poor_population_source_notes,
  -- lineage (9 columns)
  silver_build_id     AS _silver_build_id,
  n._source_key, n._source_file, n._as_of_date,
  'tab2'              AS _incidence_source_sheet,
  w.incidence_row_num AS _incidence_source_row_num,
  'tab6'              AS _magnitude_source_sheet,
  w.magnitude_row_num AS _magnitude_source_row_num,
  w.metric_source_columns AS _metric_source_columns
FROM wide w
JOIN public_health.silver.socioeconomic_poverty_area_map m ON m.area_key = w.area_key
JOIN notes n ON n.area_key = w.area_key;


-- =============================================================================
-- [5] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_poverty_silver__gates AS
SELECT 'inputs: sheet with more than one load time' AS gate, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_poverty_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'inputs: sheets read are not exactly tab2 and tab6',
       CASE WHEN count(DISTINCT source_sheet) = 2 AND count_if(source_sheet NOT IN ('tab2', 'tab6')) = 0
                 AND count_if(source_sheet IS NULL) = 0 THEN 0 ELSE 1 END
  FROM public_health.silver.socioeconomic_poverty_silver__inputs WHERE input_kind = 'bronze_source'
UNION ALL
SELECT 'inputs: sheets come from different versions of the file',
       CASE WHEN count(DISTINCT content_checksum) > 1 THEN 1 ELSE 0 END
  FROM public_health.silver.socioeconomic_poverty_silver__inputs WHERE input_kind = 'bronze_source'
UNION ALL
SELECT 'unclassified bronze rows', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__classified WHERE row_class NOT IN ('data', 'non_data')
UNION ALL
SELECT 'area listed twice in a sheet', count(*) FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_poverty_silver__classified WHERE row_class = 'data'
  GROUP BY _source_sheet, area_key HAVING count(*) > 1)
UNION ALL
SELECT 'map area missing from a sheet', count(*) FROM (
  SELECT m.area_key, s.sheet
  FROM public_health.silver.socioeconomic_poverty_area_map m
  CROSS JOIN (SELECT explode(array('tab2', 'tab6')) AS sheet) s
  LEFT ANTI JOIN public_health.silver.socioeconomic_poverty_silver__classified r
    ON r.area_key = m.area_key AND r._source_sheet = s.sheet AND r.row_class = 'data')
UNION ALL
SELECT 'cell that is neither a number nor a documented marker', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__cells WHERE value_status = 'parse_error'
UNION ALL
SELECT 'expected area-year without a published estimate', count(*) FROM (
  SELECT m.area_key, y.year, k.metric
  FROM public_health.silver.socioeconomic_poverty_area_map m
  CROSS JOIN (SELECT explode(array(2021, 2023, 2025)) AS year) y
  CROSS JOIN (SELECT explode(array('threshold', 'incidence', 'poor_pop')) AS metric) k
  LEFT ANTI JOIN public_health.silver.socioeconomic_poverty_silver__cells c
    ON c.area_key = m.area_key AND c.year = y.year AND c.metric = k.metric AND c.value_status = 'ok'
  WHERE y.year >= try_cast(m.first_estimate_year AS INT))
UNION ALL
SELECT 'published estimate for an area-year not expected', count(*) FROM (
  SELECT c.area_key, c.year
  FROM public_health.silver.socioeconomic_poverty_silver__cells c
  JOIN public_health.silver.socioeconomic_poverty_area_map m ON m.area_key = c.area_key
  WHERE c.value_status = 'ok' AND c.year < try_cast(m.first_estimate_year AS INT))
UNION ALL
SELECT 'metric without a lineage group, or on the wrong sheet', count(*) FROM (
  SELECT DISTINCT metric, _source_sheet FROM public_health.silver.socioeconomic_poverty_silver__cells
  WHERE lineage_group IS NULL OR NOT (expected_sheet <=> _source_sheet))
UNION ALL
SELECT 'value outside its valid range', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__candidate
  WHERE poverty_incidence_pct < 0 OR poverty_incidence_pct > 100
     OR annual_per_capita_poverty_threshold_php <= 0
     OR incidence_cv_pct < 0 OR incidence_se_pp < 0
     OR poor_population < 0 OR poor_population_cv_pct < 0 OR poor_population_se < 0
UNION ALL
SELECT 'superseded area is marked comparison-eligible', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__candidate
  WHERE is_superseded_area AND comparison_eligible
UNION ALL
SELECT 'key column is null', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__candidate WHERE area_key IS NULL OR year IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.socioeconomic_poverty_silver__candidate GROUP BY area_key, year HAVING count(*) > 1)
UNION ALL
SELECT 'lineage column is null', count(*)
  FROM public_health.silver.socioeconomic_poverty_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _as_of_date IS NULL
     OR _incidence_source_row_num IS NULL OR _magnitude_source_row_num IS NULL OR _metric_source_columns IS NULL
UNION ALL
SELECT 'classified rows <> bronze rows read',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__classified)
         - (SELECT coalesce(sum(input_rows), 0) FROM public_health.silver.socioeconomic_poverty_silver__inputs WHERE input_kind = 'bronze_source'))
UNION ALL
SELECT 'silver rows <> expected area-years of the area map',
       abs((SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__candidate)
         - (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_area_map m
            CROSS JOIN (SELECT explode(array(2021, 2023, 2025)) AS year) y
            WHERE y.year >= try_cast(m.first_estimate_year AS INT)))
UNION ALL
SELECT 'reconciliation: bronze rows referenced by silver <> rows read - rows not loaded (data rows, tab2)',
       abs((SELECT count(DISTINCT _incidence_source_row_num) FROM public_health.silver.socioeconomic_poverty_silver__candidate)
         - (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__classified WHERE row_class = 'data' AND _source_sheet = 'tab2'))
UNION ALL
SELECT 'reconciliation: bronze rows referenced by silver <> rows read - rows not loaded (data rows, tab6)',
       abs((SELECT count(DISTINCT _magnitude_source_row_num) FROM public_health.silver.socioeconomic_poverty_silver__candidate)
         - (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__classified WHERE row_class = 'data' AND _source_sheet = 'tab6'));


-- =============================================================================
-- [6] build log row (status is 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW poverty_build_log AS
SELECT silver_build_id                                AS build_id,
       'silver'                                       AS layer,
       'socioeconomic'                                AS domain,
       'public_health.silver.socioeconomic_poverty_silver' AS target_table,
       silver_build_started_at                        AS started_at,
       current_timestamp()                            AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                           AS target_table_version,     -- filled in [9]
       code_version                                   AS code_version,
       to_json(named_struct('poverty_population_basis', 'population', 'reporting_period', 'full_year',
                            'strict_load_lookup', strict_load_lookup,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches = 0))) AS parameters,
       job_run_id                                     AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.socioeconomic_poverty_silver__gates) g;


-- =============================================================================
-- [7] stop here if a gate failed. The failed build is logged first, and the published table
--     stays as it was. The staging tables are kept so you can see what failed:
--       SELECT * FROM public_health.silver.socioeconomic_poverty_silver__gates WHERE failures <> 0
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM poverty_build_log WHERE status = 'failed';

SELECT raise_error(concat('socioeconomic_poverty_silver was NOT published. ', error_message))
FROM poverty_build_log WHERE status = 'failed';


-- =============================================================================
-- [8] write the table from the validated candidate (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.socioeconomic_poverty_silver AS
SELECT * FROM public_health.silver.socioeconomic_poverty_silver__candidate;

COMMENT ON TABLE public_health.silver.socioeconomic_poverty_silver IS
  'PSA official poverty statistics among POPULATION, FULL YEAR, by area and year (2021, 2023, 2025). One row per area_key and year. Do not mix with family-based or first-semester statistics. Province rows marked comparison_eligible = false cover a different population than PSGC province figures (see socioeconomic-silver-guide.md, D2). 2021 and 2023 were revised by PSA for Region IX, Region XII and BARMM.';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN annual_per_capita_poverty_threshold_php COMMENT 'Pesos per person per year';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN poverty_incidence_pct COMMENT 'Percent of population below the poverty threshold. A 0.0 with is_incidence_below_0_05 = true means below 0.05, not an exact zero';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN incidence_cv_pct COMMENT 'Coefficient of variation of the incidence, in percent. Can exceed 100';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN incidence_se_pp COMMENT 'Standard error of the incidence, in percentage points';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN poor_population COMMENT 'Persons (the source is in thousands). Provinces and regions may not add up to the national figure because of rounding';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN incidence_precision COMMENT 'ok (CV up to 10) | use_with_caution (CV above 10) | unknown (CV not available)';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN comparison_eligible COMMENT 'false = do not compare with PSGC-based population or facilities figures as is. See exclusion_reason';
ALTER TABLE public_health.silver.socioeconomic_poverty_silver ALTER COLUMN parent_geo_name_source COMMENT 'Region the source lists the area under, as published. Not necessarily the current PSGC parent';


-- =============================================================================
-- [9] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.socioeconomic_poverty_silver)),
       code_version, parameters, run_id, error_message
FROM poverty_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.socioeconomic_poverty_silver__inputs;

-- Bronze rows NOT loaded (lineage-qc-contract.md v1.3, section 7.1). Loaded rows are not written:
-- the silver rows carry their bronze row reference, and rows loaded per input = input_rows minus
-- the rows here (quality.v_build_reconciliation). Here only non-data rows are not loaded
-- (an unclassified row fails a gate, so it never reaches this step).
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.socioeconomic_poverty_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       'dropped_non_data',
       c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.socioeconomic_poverty_silver__classified c
LEFT JOIN public_health.silver.socioeconomic_poverty_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [10] summary, then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW poverty_summary AS
SELECT (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__classified) AS bronze_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver__classified WHERE row_class = 'data') AS data_rows,
       (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver) AS silver_rows,
       (SELECT count(DISTINCT area_key) FROM public_health.silver.socioeconomic_poverty_silver) AS areas,
       (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver WHERE NOT comparison_eligible) AS rows_not_comparison_eligible,
       (SELECT count(*) FROM public_health.silver.socioeconomic_poverty_silver WHERE incidence_precision <> 'ok') AS rows_incidence_not_ok_precision,
       -- control values to read against the PSA release (expected 9.7, 35120.89 and 11083030)
       (SELECT max(poverty_incidence_pct) FROM public_health.silver.socioeconomic_poverty_silver WHERE area_key = 'ph' AND year = 2025) AS ph_2025_incidence_pct,
       (SELECT max(annual_per_capita_poverty_threshold_php) FROM public_health.silver.socioeconomic_poverty_silver WHERE area_key = 'ph' AND year = 2025) AS ph_2025_threshold_php,
       (SELECT max(poor_population) FROM public_health.silver.socioeconomic_poverty_silver WHERE area_key = 'ph' AND year = 2025) AS ph_2025_poor_population;

SELECT * FROM poverty_summary;

DROP TABLE IF EXISTS public_health.silver.socioeconomic_poverty_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_poverty_silver__cells;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_poverty_silver__gates;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_poverty_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.socioeconomic_poverty_silver__classified;
