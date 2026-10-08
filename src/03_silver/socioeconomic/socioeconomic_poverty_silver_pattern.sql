-- =============================================================================
-- socioeconomic_poverty_silver_pattern.sql
-- Tested pattern for socioeconomic_poverty_silver (see socioeconomic-silver-guide.md, section 4).
--
-- What it does
--   [1] poverty_rows      classify every bronze row (data / junk_row / footnote / unclassified)
--   [2] poverty_cells     one row per area, year and metric, with the parsed value and a status
--   [3] poverty_expected  the area-years that must exist (area map x years >= first_estimate_year)
--   [3b] poverty_inputs   one row per input sheet consumed, with its load batch and file checksum
--   [4] poverty_gates     nine checks, and every one must return 0 before the table is published
--   [5] poverty_silver    combine tab2 and tab6 by area_key and year
--   [6] poverty_final     add the area contract, definitions, precision, flags and lineage
--   [7] poverty_dispositions  one row per bronze row, for public_health.quality.row_disposition
--   poverty_inputs is also what gets appended to the build-inputs log (lineage contract, section 5)
--
-- Needs
--   public_health.bronze.socioeconomic_psa_poverty_bronze
--   public_health.silver.socioeconomic_poverty_area_map   (socioeconomic_poverty_area_map.csv, 108 rows)
--   public_health.bronze.ingestion_metadata
--
-- Status
--   Ran on local Spark against the landing file: 322 rows, all gates 0.
--   Not yet run on Databricks. Still to add: the CREATE OR REPLACE TABLE write, the
--   append of poverty_dispositions, and the DQRun checks.
--
-- Lineage (lineage-qc-contract.md)
--   _silver_build_id      = this build, set once below (in a job, pass the job run id)
--   _<side>_load_batch_id = ingestion_metadata.batch_id (the ingestion execution), per sheet
--   _<side>_content_checksum = sha256 of the file bytes, per sheet
--   _metric_source_columns = MAP<STRING,STRING> {silver column: bronze column}
--     For comparisons in QC use: to_json(sort_array(map_entries(_metric_source_columns)))
--
-- How to use
--   Run [1]-[4], then: SELECT * FROM poverty_gates WHERE failures > 0
--   Stop if that returns any row. Otherwise run [5]-[6] and write poverty_final.
-- =============================================================================

-- [0] build id: one value for the whole build
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();

-- [1] classify
CREATE OR REPLACE TEMP VIEW poverty_rows AS
SELECT b.*, trim(b.area_name) AS geo_name_source, m.area_key,
       CASE
         WHEN m.area_key IS NOT NULL THEN 'data'
         WHEN b.area_name IS NULL
              AND coalesce(b.threshold_2021, b.threshold_2023, b.threshold_2025,
                           b.incidence_2021, b.incidence_2023, b.incidence_2025,
                           b.poor_pop_2021,  b.poor_pop_2023,  b.poor_pop_2025) IS NULL THEN 'junk_row'
         WHEN trim(b.area_name) RLIKE '^(Notes:|r[0-9]+ -|[0-9]+/|[a-z]/)' THEN 'footnote'
         ELSE 'unclassified'
       END AS row_class
FROM public_health.bronze.socioeconomic_psa_poverty_bronze b
LEFT JOIN public_health.silver.socioeconomic_poverty_area_map m
       ON trim(b.area_name) = m.geo_name_source
WHERE b._source_key = 'psa_poverty';

-- [2] cells
CREATE OR REPLACE TEMP VIEW poverty_cells AS
WITH long AS (
  SELECT area_key, _source_sheet, _source_row_num,
         stack(18,
           2021, 'threshold', threshold_2021,  2023, 'threshold', threshold_2023,  2025, 'threshold', threshold_2025,
           2021, 'incidence', incidence_2021,  2023, 'incidence', incidence_2023,  2025, 'incidence', incidence_2025,
           2021, 'incidence_cv', incidence_cv_2021,  2023, 'incidence_cv', incidence_cv_2023,  2025, 'incidence_cv', incidence_cv_2025,
           2021, 'incidence_se', incidence_se_2021,  2023, 'incidence_se', incidence_se_2023,  2025, 'incidence_se', incidence_se_2025,
           2021, 'incidence_ci_low', incidence_ci_low_2021,  2023, 'incidence_ci_low', incidence_ci_low_2023,  2025, 'incidence_ci_low', incidence_ci_low_2025,
           2021, 'incidence_ci_high', incidence_ci_high_2021, 2023, 'incidence_ci_high', incidence_ci_high_2023, 2025, 'incidence_ci_high', incidence_ci_high_2025
         ) AS (year, metric, raw)
  FROM poverty_rows WHERE row_class = 'data' AND _source_sheet = 'tab2'
  UNION ALL
  SELECT area_key, _source_sheet, _source_row_num,
         stack(15,
           2021, 'poor_pop', poor_pop_2021,  2023, 'poor_pop', poor_pop_2023,  2025, 'poor_pop', poor_pop_2025,
           2021, 'poor_pop_cv', poor_pop_cv_2021,  2023, 'poor_pop_cv', poor_pop_cv_2023,  2025, 'poor_pop_cv', poor_pop_cv_2025,
           2021, 'poor_pop_se', poor_pop_se_2021,  2023, 'poor_pop_se', poor_pop_se_2023,  2025, 'poor_pop_se', poor_pop_se_2025,
           2021, 'poor_pop_ci_low', poor_pop_ci_low_2021,  2023, 'poor_pop_ci_low', poor_pop_ci_low_2023,  2025, 'poor_pop_ci_low', poor_pop_ci_low_2025,
           2021, 'poor_pop_ci_high', poor_pop_ci_high_2021, 2023, 'poor_pop_ci_high', poor_pop_ci_high_2023, 2025, 'poor_pop_ci_high', poor_pop_ci_high_2025
         ) AS (year, metric, raw)
  FROM poverty_rows WHERE row_class = 'data' AND _source_sheet = 'tab6'
)
SELECT *, concat(metric, '_', year) AS source_column,
       element_at(map(
         'threshold', 'annual_per_capita_poverty_threshold_php',
         'incidence', 'poverty_incidence_pct',
         'incidence_cv', 'incidence_cv_pct',
         'incidence_se', 'incidence_se_pp',
         'incidence_ci_low', 'incidence_ci_low_pct',
         'incidence_ci_high', 'incidence_ci_high_pct',
         'poor_pop', 'poor_population',
         'poor_pop_cv', 'poor_population_cv_pct',
         'poor_pop_se', 'poor_population_se',
         'poor_pop_ci_low', 'poor_population_ci_low',
         'poor_pop_ci_high', 'poor_population_ci_high'), metric) AS silver_column,
       try_cast(regexp_replace(raw, '[ ,]', '') AS DOUBLE) AS value,
       CASE
         WHEN raw IS NULL OR trim(raw) = ''  THEN 'not_published'
         WHEN trim(raw) = '-'                THEN 'not_computed'
         WHEN try_cast(regexp_replace(raw, '[ ,]', '') AS DOUBLE) IS NOT NULL THEN 'ok'
         ELSE 'parse_error'
       END AS value_status
FROM long;

-- [3] expected
CREATE OR REPLACE TEMP VIEW poverty_expected AS
SELECT m.area_key, y.year
FROM public_health.silver.socioeconomic_poverty_area_map m
CROSS JOIN (SELECT explode(array(2021, 2023, 2025)) AS year) y
WHERE y.year >= m.first_estimate_year;

-- [3b] inputs: each sheet must have exactly one processed row in the ingestion log for its load
CREATE OR REPLACE TEMP VIEW poverty_inputs AS
WITH sheets AS (
  SELECT _source_key, _source_file, _source_sheet, _as_of_date, _ingested_at, count(*) AS bronze_rows
  FROM poverty_rows
  GROUP BY _source_key, _source_file, _source_sheet, _as_of_date, _ingested_at
)
SELECT silver_build_id AS _silver_build_id,
       'public_health.silver.socioeconomic_poverty_silver' AS target_table,
       s._source_key, s._source_file, s._source_sheet, s._as_of_date, s._ingested_at,
       s.bronze_rows,
       count(m.batch_id)       AS metadata_matches,
       max(m.batch_id)         AS _load_batch_id,
       max(m.content_checksum) AS _content_checksum
FROM sheets s
LEFT JOIN public_health.bronze.ingestion_metadata m
       ON m.source_name = s._source_key
      AND m.retrieved_at = s._ingested_at
      AND lower(m.status) = 'processed'
      AND coalesce(m.source_sheet, '') = coalesce(s._source_sheet, '')
      AND endswith(m.raw_file_path, concat('/', s._source_file))
GROUP BY s._source_key, s._source_file, s._source_sheet, s._as_of_date, s._ingested_at, s.bronze_rows;

-- [4] gates
CREATE OR REPLACE TEMP VIEW poverty_gates AS
SELECT 'unclassified bronze rows' AS gate, count(*) AS failures
  FROM poverty_rows WHERE row_class = 'unclassified'
UNION ALL
SELECT 'area listed twice in a sheet', count(*) FROM (
  SELECT 1 FROM poverty_rows WHERE row_class = 'data'
  GROUP BY _source_sheet, area_key HAVING count(*) > 1)
UNION ALL
SELECT 'map area missing from a sheet', count(*) FROM (
  SELECT m.area_key, s.sheet
  FROM public_health.silver.socioeconomic_poverty_area_map m
  CROSS JOIN (SELECT explode(array('tab2', 'tab6')) AS sheet) s
  LEFT ANTI JOIN poverty_rows r
    ON r.area_key = m.area_key AND r._source_sheet = s.sheet AND r.row_class = 'data')
UNION ALL
SELECT 'cell that is not a number or a known marker', count(*)
  FROM poverty_cells WHERE value_status = 'parse_error'
UNION ALL
SELECT 'expected area-year without a published estimate', count(*) FROM (
  SELECT e.area_key, e.year, k.metric
  FROM poverty_expected e
  CROSS JOIN (SELECT explode(array('threshold', 'incidence', 'poor_pop')) AS metric) k
  LEFT ANTI JOIN poverty_cells c
    ON c.area_key = e.area_key AND c.year = e.year AND c.metric = k.metric AND c.value_status = 'ok')
UNION ALL
SELECT 'published estimate for an area-year not expected', count(*) FROM (
  SELECT c.area_key, c.year FROM poverty_cells c
  LEFT ANTI JOIN poverty_expected e ON e.area_key = c.area_key AND e.year = c.year
  WHERE c.value_status = 'ok')
UNION ALL
SELECT 'input sheet without exactly one ingestion log row', count(*)
  FROM poverty_inputs WHERE metadata_matches <> 1
UNION ALL
SELECT 'input sheets loaded (must be tab2 and tab6, once each)', abs(count(*) - 2)
  FROM poverty_inputs
UNION ALL
SELECT 'sheets come from different versions of the file', count(DISTINCT _content_checksum) - 1
  FROM poverty_inputs;

-- [5] build
CREATE OR REPLACE TEMP VIEW poverty_silver AS
SELECT
  e.area_key, e.year,
  max(CASE WHEN c.metric = 'threshold'         THEN c.value END) AS annual_per_capita_poverty_threshold_php,
  max(CASE WHEN c.metric = 'incidence'         THEN c.value END) AS poverty_incidence_pct,
  max(CASE WHEN c.metric = 'incidence_cv'      THEN c.value END) AS incidence_cv_pct,
  max(CASE WHEN c.metric = 'incidence_se'      THEN c.value END) AS incidence_se_pp,
  max(CASE WHEN c.metric = 'incidence_ci_low'  THEN c.value END) AS incidence_ci_low_pct,
  max(CASE WHEN c.metric = 'incidence_ci_high' THEN c.value END) AS incidence_ci_high_pct,
  CAST(round(max(CASE WHEN c.metric = 'poor_pop'         THEN c.value END) * 1000) AS BIGINT) AS poor_population,
  max(CASE WHEN c.metric = 'poor_pop_cv'       THEN c.value END) AS poor_population_cv_pct,
  CAST(round(max(CASE WHEN c.metric = 'poor_pop_se'      THEN c.value END) * 1000) AS BIGINT) AS poor_population_se,
  CAST(round(max(CASE WHEN c.metric = 'poor_pop_ci_low'  THEN c.value END) * 1000) AS BIGINT) AS poor_population_ci_low,
  CAST(round(max(CASE WHEN c.metric = 'poor_pop_ci_high' THEN c.value END) * 1000) AS BIGINT) AS poor_population_ci_high,
  max(CASE WHEN c.metric = 'incidence_cv' THEN c.value_status END) AS incidence_cv_status,
  max(CASE WHEN c.metric = 'poor_pop_cv'  THEN c.value_status END) AS poor_population_cv_status,
  max(CASE WHEN c._source_sheet = 'tab2' THEN c._source_row_num END) AS _incidence_source_row_num,
  max(CASE WHEN c._source_sheet = 'tab6' THEN c._source_row_num END) AS _magnitude_source_row_num,
  map_from_entries(collect_list(struct(c.silver_column, c.source_column))) AS _metric_source_columns
FROM poverty_expected e
JOIN poverty_cells c ON c.area_key = e.area_key AND c.year = e.year
GROUP BY e.area_key, e.year;

-- [6] final
CREATE OR REPLACE TEMP VIEW poverty_final AS
SELECT
  m.area_key, m.geo_name_source, m.geo_level, m.psgc_code, m.parent_geo_name_source,
  m.geo_coverage_basis, m.coverage_confirmed, m.comparison_eligible, m.exclusion_reason, m.is_superseded_area,
  s.year,
  'population' AS poverty_population_basis,
  'full_year'  AS reporting_period,
  s.annual_per_capita_poverty_threshold_php,
  s.poverty_incidence_pct, s.incidence_cv_pct, s.incidence_se_pp, s.incidence_ci_low_pct, s.incidence_ci_high_pct,
  s.poor_population, s.poor_population_cv_pct, s.poor_population_se, s.poor_population_ci_low, s.poor_population_ci_high,
  CASE WHEN s.incidence_cv_pct IS NULL THEN 'unknown'
       WHEN s.incidence_cv_pct > 10    THEN 'use_with_caution' ELSE 'ok' END AS incidence_precision,
  CASE WHEN s.poor_population_cv_pct IS NULL THEN 'unknown'
       WHEN s.poor_population_cv_pct > 10    THEN 'use_with_caution' ELSE 'ok' END AS poor_population_precision,
  CASE s.year WHEN 2023 THEN coalesce(r2.notes, '') RLIKE '(^|[ ,])1/'
              WHEN 2025 THEN coalesce(r2.notes, '') RLIKE '(^|[ ,])2/' END AS is_incidence_change_significant,
  CASE s.year WHEN 2023 THEN coalesce(r6.notes, '') RLIKE '(^|[ ,])1/'
              WHEN 2025 THEN coalesce(r6.notes, '') RLIKE '(^|[ ,])2/' END AS is_poor_population_change_significant,
  (coalesce(r2.notes, '') RLIKE '(^|[ ,])c/' AND s.poverty_incidence_pct = 0) AS is_incidence_below_0_05,
  (coalesce(r6.notes, '') RLIKE '(^|[ ,])c/' AND s.poor_population = 0)       AS is_poor_population_below_50,
  r2.notes AS incidence_source_notes,
  r6.notes AS poor_population_source_notes,
  silver_build_id AS _silver_build_id,
  r2._source_key, r2._source_file, r2._as_of_date,
  r2._source_sheet AS _incidence_source_sheet, s._incidence_source_row_num,
  r2._ingested_at  AS _incidence_ingested_at,  i2._load_batch_id AS _incidence_load_batch_id,
  i2._content_checksum AS _incidence_content_checksum,
  r6._source_sheet AS _magnitude_source_sheet, s._magnitude_source_row_num,
  r6._ingested_at  AS _magnitude_ingested_at,  i6._load_batch_id AS _magnitude_load_batch_id,
  i6._content_checksum AS _magnitude_content_checksum,
  s._metric_source_columns,
  current_timestamp() AS _silver_loaded_at
FROM poverty_silver s
JOIN public_health.silver.socioeconomic_poverty_area_map m ON m.area_key = s.area_key
JOIN poverty_rows r2 ON r2.area_key = s.area_key AND r2._source_sheet = 'tab2' AND r2.row_class = 'data'
JOIN poverty_rows r6 ON r6.area_key = s.area_key AND r6._source_sheet = 'tab6' AND r6.row_class = 'data'
JOIN poverty_inputs i2 ON i2._source_sheet = 'tab2'
JOIN poverty_inputs i6 ON i6._source_sheet = 'tab6';

-- [7] dispositions: one row per bronze row (append to public_health.quality.row_disposition)
--     The bronze row reference carries the load and the file version, not only file / sheet / row.
--     _source_sheet is null for CSV sources, so it is joined with <=> (null-safe).
CREATE OR REPLACE TEMP VIEW poverty_dispositions AS
SELECT i._silver_build_id, r._source_key, r._source_file, r._source_sheet, r._source_row_num,
       i._load_batch_id, i._content_checksum,
       i.target_table,
       CASE WHEN r.row_class = 'data' THEN 'loaded' ELSE 'dropped_non_data' END AS disposition,
       r.area_key AS target_key,
       CASE WHEN r.row_class = 'data' THEN NULL ELSE r.row_class END AS reason
FROM poverty_rows r
JOIN poverty_inputs i
  ON i._source_key = r._source_key AND i._source_file = r._source_file AND i._source_sheet <=> r._source_sheet;
