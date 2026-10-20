-- =============================================================================
-- Builds public_health.silver.workforce_area_denominator_silver:
--   one area in one year: population and households as printed by FHSIS (cross-check only;
--   A5 and W1 rates use the population domain, decision D4).
--   Key: (_source_key, area_key, year)
--
-- Combined lineage (contract 3.4): population and households can come from different sheets of the
-- same workbook. Shared: _silver_build_id, _source_key, _source_file, _as_of_date,
-- _metric_source_columns. Per side: _population_source_sheet / _row_num, _households_source_sheet /
-- _row_num. A side's columns are filled when the source contributes (households_source_present),
-- whatever the cell value. metric_groups (contract 3.6): reported_population -> population,
-- household_estimates -> households.
--
-- Where each side comes from
--   population: 2018 Table 3B.2; 2019-2023 Part 1; 2024-2025 Health Workers
--   households: 2019-2020 Part 3; 2022 Part 2; 2024-2025 the same row; none in 2018, 2021, 2023
--
-- Build sequence: the same four contract steps as workforce_silver_02_headcount.sql ([0] ... [8]).
-- Dispositions (only rows not loaded are stored, as in diseases): separate households rows are
-- 'merged_into' the area-year row (target_key = the silver key); population-side rows are loaded
-- and not stored; 2024-2025 rows give both sides and count once, as loaded.
--
-- Rule 2a (2026-10-19)
--   - province_coverage_change_year is read from workforce_fhsis__settings (set in
--     workforce_silver_01 [0]; was "year <= 2022" here).
--   - New gate: an FHSIS file year in bronze without a population sheet in wf_denominator_layout.
--     Before, the layout join dropped such a year without any gate failing.
--   - The layout (year, side, sheet) is recorded in build_log.parameters; workforce_silver_qc.py
--     reads it instead of its own copy of the sheet list and the households years.
-- =============================================================================

-- [0] build id, settings, helpers, layout
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;   -- see workforce_silver_02
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;
-- Shared FHSIS setting, written by workforce_silver_01 (gate 'settings missing' if absent).
DECLARE OR REPLACE VARIABLE province_coverage_change_year INT;
SET VARIABLE province_coverage_change_year = (SELECT max(province_coverage_change_year) FROM public_health.silver.workforce_fhsis__settings);

-- Text to number; fractions allowed (the 2019 workbook prints population with decimals).
CREATE OR REPLACE TEMPORARY FUNCTION wf_dbl(x STRING) RETURNS DOUBLE
RETURN CASE WHEN regexp_replace(trim(x), '[ ,]', '') RLIKE '^-?[0-9]+([.][0-9]+)?$'
            THEN try_cast(regexp_replace(trim(x), '[ ,]', '') AS DOUBLE) END;

CREATE OR REPLACE TEMPORARY FUNCTION wf_den_status(raw STRING, zero_means_no_data BOOLEAN) RETURNS STRING
RETURN CASE WHEN raw IS NULL OR trim(raw) = '' THEN 'blank'
            WHEN trim(raw) = '*'  THEN 'no_report'
            WHEN wf_dbl(raw) IS NULL THEN 'parse_error'
            WHEN coalesce(zero_means_no_data, false) AND wf_dbl(raw) = 0 THEN 'zero_no_data'
            ELSE 'ok' END;

CREATE OR REPLACE TEMP VIEW wf_denominator_layout AS
SELECT * FROM VALUES
  (2018, 'population', 'Table 3B.2', 'population'),
  (2019, 'population', 'HEALTH WORKERS PART1', 'population'),
  (2020, 'population', 'HEALTH WORKERS PART1', 'population'),
  (2021, 'population', 'HEALTH WORKERS PART1', 'population'),
  (2022, 'population', 'HEALTH WORKERS PART1', 'population'),
  (2023, 'population', 'HEALTH WORKERS PART1', 'population'),
  (2024, 'population', 'Health Workers', 'population'),
  (2025, 'population', 'Health Workers', 'population'),
  (2019, 'households', 'HEALTH WORKERS PART3', 'household_estimates'),
  (2020, 'households', 'HEALTH WORKERS PART3', 'household_estimates'),
  (2022, 'households', 'HEALTH WORKERS PART2', 'household_estimates'),
  (2024, 'households', 'Health Workers', 'household_estimates'),
  (2025, 'households', 'Health Workers', 'household_estimates')
AS t(year, side, sheet, bronze_column);

-- metric_groups from the table config (contract 3.6): silver metric -> lineage group
CREATE OR REPLACE TEMP VIEW wf_denominator_metric_groups AS
SELECT * FROM VALUES ('reported_population', 'population'), ('household_estimates', 'households')
AS t(metric, lineage_group);


-- =============================================================================
-- [1] classified bronze rows of the 11 denominator sheets (staging table)
--     role: population when the sheet is that year's population sheet, else households
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_area_denominator_silver__classified AS
WITH sides AS (
  SELECT r._source_file, r._source_sheet, r._source_row_num,
         bool_or(l.side = 'population') AS on_population_sheet,
         max(CASE WHEN l.side = 'population' THEN l.bronze_column END) AS population_column,
         max(CASE WHEN l.side = 'households' THEN l.bronze_column END) AS households_column
  FROM public_health.silver.workforce_fhsis__resolved r
  JOIN wf_denominator_layout l ON l.year = r.year AND l.sheet = r._source_sheet
  GROUP BY r._source_file, r._source_sheet, r._source_row_num),
x AS (
  SELECT r.*, s.on_population_sheet, s.population_column, s.households_column,
         CASE WHEN s.on_population_sheet THEN 'population' ELSE 'households' END AS role,
         wf_dbl(r.cells[CASE WHEN s.on_population_sheet THEN s.population_column ELSE s.households_column END]) IS NOT NULL AS has_value
  FROM public_health.silver.workforce_fhsis__resolved r
  JOIN sides s ON s._source_file = r._source_file AND s._source_sheet <=> r._source_sheet AND s._source_row_num = r._source_row_num)
SELECT 'public_health.bronze.workforce_fhsis_health_workers_bronze' AS input_table,
       x._source_key, x._source_file, x._source_sheet, x._source_row_num, x._ingested_at, x._as_of_date,
       x.year, x.role, x.population_column, x.households_column, x.cells, x.zero_means_no_data,
       x.area_key, x.area_label_source, x.geo_level, x.psgc_code, x.parent_area_key, x.city_class,
       x.region_as_published, x.is_superseded_area, x.resolve_method, x.override_status,
       CASE WHEN x.label_kind = 'legend' THEN 'non_data'
            WHEN x.label_kind = 'blank' AND NOT x.has_value THEN 'non_data'
            WHEN x.label_kind = 'blank' THEN 'quarantined'
            WHEN x.resolve_method = 'code_not_in_geography' THEN 'quarantined'
            WHEN x.resolve_method IN ('override', 'exception', 'psgc_code', 'name_join') AND x.area_in_geography THEN 'data'
            ELSE 'unclassified' END AS row_class,
       CASE WHEN x.label_kind = 'legend' THEN 'legend'
            WHEN x.label_kind = 'blank' AND NOT x.has_value THEN 'blank_row'
            WHEN x.label_kind = 'blank' THEN 'area_label_missing'
            WHEN x.resolve_method = 'code_not_in_geography' THEN 'psgc_code_not_in_geography'
            WHEN x.resolve_method IN ('override', 'exception', 'psgc_code', 'name_join') AND x.area_in_geography THEN NULL
            ELSE coalesce(x.resolve_method, 'unresolved') END AS reason
FROM x;

-- Separate households rows (2019, 2020, 2022) matched to the population row of the same area and year
CREATE OR REPLACE TABLE public_health.silver.workforce_area_denominator_silver__households AS
SELECT h._source_file, h._source_sheet, h._source_row_num, h.year, h.area_key,
       h.cells[h.households_column] AS raw,
       count(p._source_row_num) AS n_population_rows
FROM public_health.silver.workforce_area_denominator_silver__classified h
LEFT JOIN public_health.silver.workforce_area_denominator_silver__classified p
  ON p.role = 'population' AND p.row_class = 'data' AND p.year = h.year AND p.area_key = h.area_key
WHERE h.role = 'households' AND h.row_class = 'data'
GROUP BY h._source_file, h._source_sheet, h._source_row_num, h.year, h.area_key, h.cells[h.households_column];


-- =============================================================================
-- [2] inputs (11 sheets + geography and reference tables, versions as read by 01)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_area_denominator_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.workforce_area_denominator_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at)
SELECT silver_build_id                                              AS build_id,
       'public_health.silver.workforce_area_denominator_silver'     AS target_table,
       'bronze_source'                                              AS input_kind,
       f.input_table,
       max(v.table_version)                                         AS input_table_version,
       f._source_key AS source_key, f._source_file AS source_file, f._source_sheet AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END         AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at AS ingested_at, f.input_rows,
       CAST(NULL AS STRING)                                         AS reference_version,
       count(m.batch_id)                                            AS metadata_matches      -- gate only
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet AND m.retrieved_at = f._ingested_at
LEFT JOIN public_health.silver.workforce_fhsis__versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
SELECT silver_build_id, 'public_health.silver.workforce_area_denominator_silver', 'table', v.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), v.content_checksum,
       CAST(NULL AS TIMESTAMP), v.table_rows, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM public_health.silver.workforce_fhsis__versions v
WHERE v.table_name LIKE 'public_health.silver.%';


-- =============================================================================
-- [3] candidate (staging table)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_area_denominator_silver__candidate AS
WITH p AS (SELECT * FROM public_health.silver.workforce_area_denominator_silver__classified
           WHERE role = 'population' AND row_class = 'data'),
hl AS (SELECT year, sheet FROM wf_denominator_layout WHERE side = 'households'),
x AS (
  SELECT p.*,
         CASE WHEN hl.sheet IS NULL THEN 'none'
              WHEN hl.sheet = p._source_sheet THEN 'same_row' ELSE 'separate_sheet' END AS households_layout,
         hh._source_sheet AS hh_sheet, hh._source_row_num AS hh_row, hh.raw AS hh_raw
  FROM p
  LEFT JOIN hl ON hl.year = p.year
  LEFT JOIN public_health.silver.workforce_area_denominator_silver__households hh
    ON hh.year = p.year AND hh.area_key = p.area_key AND hl.sheet <> p._source_sheet),
y AS (
  SELECT x.*,
         x.cells[x.population_column] AS pop_raw,
         CASE x.households_layout WHEN 'same_row' THEN x.cells['household_estimates']
                                  WHEN 'separate_sheet' THEN x.hh_raw END AS hh_value_raw,
         CASE x.households_layout WHEN 'same_row' THEN true
                                  WHEN 'separate_sheet' THEN x.hh_row IS NOT NULL ELSE false END AS households_source_present
  FROM x)
SELECT y.area_key, y.area_label_source, y.geo_level, y.psgc_code, y.parent_area_key, y.city_class,
       y.region_as_published,
       CASE y.geo_level WHEN 'province' THEN CASE WHEN y.year < province_coverage_change_year THEN 'province_excl_listed_cities'
                                                  ELSE 'province_excl_huc_icc' END
            ELSE y.geo_level END                                                        AS geo_coverage_basis,
       y.is_superseded_area, y.resolve_method AS area_resolution_method,
       y.override_status AS area_label_override_status,
       y.year,
       CASE WHEN wf_den_status(y.pop_raw, y.zero_means_no_data) IN ('ok', 'zero_no_data') THEN wf_dbl(y.pop_raw) END AS reported_population,
       wf_den_status(y.pop_raw, y.zero_means_no_data)                                     AS population_status,
       CASE WHEN y.households_source_present AND wf_den_status(y.hh_value_raw, y.zero_means_no_data) IN ('ok', 'zero_no_data')
            THEN wf_dbl(y.hh_value_raw) END                                               AS household_estimates,
       CASE WHEN y.households_layout = 'none' THEN 'not_published'
            WHEN NOT y.households_source_present THEN 'no_source_row'
            ELSE wf_den_status(y.hh_value_raw, y.zero_means_no_data) END                  AS households_status,
       true                                                                               AS population_source_present,
       y.households_source_present,
       silver_build_id                                                                    AS _silver_build_id,
       y._source_key, y._source_file, y._as_of_date,
       CASE WHEN y.households_source_present
            THEN map('reported_population', y.population_column, 'household_estimates', 'household_estimates')
            ELSE map('reported_population', y.population_column) END                      AS _metric_source_columns,
       y._source_sheet                                                                    AS _population_source_sheet,
       y._source_row_num                                                                  AS _population_source_row_num,
       CASE y.households_layout WHEN 'same_row' THEN y._source_sheet WHEN 'separate_sheet' THEN y.hh_sheet END AS _households_source_sheet,
       CASE y.households_layout WHEN 'same_row' THEN y._source_row_num WHEN 'separate_sheet' THEN y.hh_row END AS _households_source_row_num
FROM y;


-- =============================================================================
-- [4] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_area_denominator_silver__gates AS
SELECT 'workforce_silver_01 gates are not all 0: rerun 01' AS gate, count(*) AS failures
  FROM public_health.silver.workforce_fhsis__gates WHERE failures <> 0
UNION ALL
SELECT 'settings from workforce_fhsis__settings missing: rerun 01',
       CASE WHEN province_coverage_change_year IS NULL THEN 1 ELSE 0 END
UNION ALL
SELECT 'FHSIS file year without a population sheet in wf_denominator_layout (add the year to the layout)', count(*) FROM (
  SELECT DISTINCT year FROM public_health.silver.workforce_fhsis__resolved WHERE year IS NOT NULL) r
  LEFT ANTI JOIN (SELECT year FROM wf_denominator_layout WHERE side = 'population') l ON l.year = r.year
UNION ALL
SELECT 'FHSIS bronze changed after workforce_silver_01 ran: rerun 01', count(*) FROM (
  SELECT coalesce(b._source_file, r._source_file) AS f
  FROM (SELECT _source_file, _source_sheet, _ingested_at, count(*) AS n
        FROM public_health.bronze.workforce_fhsis_health_workers_bronze WHERE _source_key = 'doh_fhsis_demographic'
        GROUP BY _source_file, _source_sheet, _ingested_at) b
  FULL OUTER JOIN (SELECT _source_file, _source_sheet, _ingested_at, count(*) AS n
                   FROM public_health.silver.workforce_fhsis__resolved
                   GROUP BY _source_file, _source_sheet, _ingested_at) r
    ON r._source_file = b._source_file AND r._source_sheet <=> b._source_sheet
   AND r._ingested_at = b._ingested_at AND r.n = b.n
  WHERE b._source_file IS NULL OR r._source_file IS NULL)
UNION ALL
SELECT 'inputs: file or sheet with more than one load time', count(*) FROM (
  SELECT 1 FROM public_health.silver.workforce_area_denominator_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__inputs
  WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'inputs: a declared population or households sheet is missing from bronze', count(*) FROM (
  SELECT DISTINCT year, sheet FROM wf_denominator_layout) l
  LEFT ANTI JOIN (SELECT DISTINCT try_cast(regexp_extract(source_file, '_([0-9]{4})[.]xlsx$', 1) AS INT) AS year,
                         source_sheet AS sheet
                  FROM public_health.silver.workforce_area_denominator_silver__inputs WHERE input_kind = 'bronze_source') i
    ON i.year = l.year AND i.sheet = l.sheet
UNION ALL
SELECT 'unclassified bronze rows (area unresolved)', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__classified WHERE row_class NOT IN ('data', 'non_data', 'quarantined')
UNION ALL
SELECT 'households row that matches no population row, or several', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__households WHERE n_population_rows <> 1
UNION ALL
SELECT 'population row that gets more than one households row', count(*) FROM (
  SELECT 1 FROM public_health.silver.workforce_area_denominator_silver__households
  GROUP BY year, area_key HAVING count(*) > 1)
UNION ALL
SELECT 'cell that is neither a number nor a documented marker', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__candidate
  WHERE population_status = 'parse_error' OR households_status = 'parse_error'
UNION ALL
SELECT 'negative population or households', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__candidate
  WHERE reported_population < 0 OR household_estimates < 0
UNION ALL
SELECT 'key column is null', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__candidate
  WHERE _source_key IS NULL OR area_key IS NULL OR year IS NULL OR geo_level IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.workforce_area_denominator_silver__candidate
  GROUP BY _source_key, area_key, year HAVING count(*) > 1)
UNION ALL
SELECT 'lineage: shared column null, or a side''s columns not filled exactly when the source contributes', count(*)
  FROM public_health.silver.workforce_area_denominator_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_file IS NULL OR _as_of_date IS NULL OR _metric_source_columns IS NULL
     OR (population_source_present AND (_population_source_sheet IS NULL OR _population_source_row_num IS NULL))
     OR (households_source_present AND (_households_source_sheet IS NULL OR _households_source_row_num IS NULL))
     OR (NOT households_source_present AND (_households_source_sheet IS NOT NULL OR _households_source_row_num IS NOT NULL))
UNION ALL
SELECT 'MAP key without a lineage group in metric_groups', count(*) FROM (
  SELECT DISTINCT metric FROM (SELECT explode(map_keys(_metric_source_columns)) AS metric
                               FROM public_health.silver.workforce_area_denominator_silver__candidate)) k
  LEFT ANTI JOIN wf_denominator_metric_groups g ON g.metric = k.metric
UNION ALL
SELECT 'classified rows <> bronze rows read', abs(c.n - i.n)
  FROM (SELECT count(*) AS n FROM public_health.silver.workforce_area_denominator_silver__classified) c,
       (SELECT coalesce(sum(input_rows), 0) AS n FROM public_health.silver.workforce_area_denominator_silver__inputs
        WHERE input_kind = 'bronze_source') i
UNION ALL
SELECT 'silver rows <> data rows on the population sheets', abs(c.n - s.n)
  FROM (SELECT count(*) AS n FROM public_health.silver.workforce_area_denominator_silver__classified
        WHERE role = 'population' AND row_class = 'data') c,
       (SELECT count(*) AS n FROM public_health.silver.workforce_area_denominator_silver__candidate) s
UNION ALL
SELECT 'bronze rows referenced by lineage <> loaded + merged_into', abs(r.n - (c.loaded + h.merged))
  FROM (SELECT count(*) AS n FROM (
          SELECT _source_file, _population_source_sheet AS s, _population_source_row_num AS rn
          FROM public_health.silver.workforce_area_denominator_silver__candidate
          UNION
          SELECT _source_file, _households_source_sheet, _households_source_row_num
          FROM public_health.silver.workforce_area_denominator_silver__candidate WHERE households_source_present)) r,
       (SELECT count(*) AS loaded FROM public_health.silver.workforce_area_denominator_silver__classified
        WHERE role = 'population' AND row_class = 'data') c,
       (SELECT count(*) AS merged FROM public_health.silver.workforce_area_denominator_silver__households
        WHERE n_population_rows = 1) h;


-- =============================================================================
-- [5] build log row; STOP if a gate failed (the failed build is logged first)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW denominator_build_log AS
SELECT silver_build_id                                              AS build_id,
       'silver'                                                     AS layer,
       'workforce'                                                  AS domain,
       'public_health.silver.workforce_area_denominator_silver'     AS target_table,
       silver_build_started_at                                      AS started_at,
       current_timestamp()                                          AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.workforce_area_denominator_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                                         AS target_table_version,
       code_version                                                 AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'province_coverage_change_year', province_coverage_change_year,
                            -- [{year, side, sheet}], the sheets this build reads (QC scopes S09 / S63 with it)
                            'denominator_sheets',
                            (SELECT sort_array(collect_list(named_struct('year', year, 'side', side, 'sheet', sheet)))
                             FROM wf_denominator_layout),
                            'households_years',
                            (SELECT sort_array(collect_set(year)) FROM wf_denominator_layout WHERE side = 'households'),
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.workforce_area_denominator_silver__inputs
                             WHERE input_kind = 'bronze_source' AND metadata_matches = 0))) AS parameters,
       job_run_id                                                   AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.workforce_area_denominator_silver__gates) g;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM denominator_build_log WHERE status = 'failed';

SELECT raise_error(concat('workforce_area_denominator_silver was NOT published. ', error_message))
FROM denominator_build_log WHERE status = 'failed';


-- =============================================================================
-- [6] write the table (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_area_denominator_silver AS
SELECT * FROM public_health.silver.workforce_area_denominator_silver__candidate;


-- =============================================================================
-- [7] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.workforce_area_denominator_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.workforce_area_denominator_silver)),
       code_version, parameters, run_id, error_message
FROM denominator_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.workforce_area_denominator_silver__inputs;

-- Loaded rows are not stored (same as diseases; quality.v_build_reconciliation derives them).
-- merged_into rows ARE stored: they carry target_key, the area-year row they were merged into.
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.workforce_area_denominator_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       CASE WHEN c.row_class = 'data' AND c.role = 'population' THEN 'loaded'
            WHEN c.row_class = 'data' THEN 'merged_into'
            WHEN c.row_class = 'non_data' THEN 'dropped_non_data'
            WHEN c.row_class = 'quarantined' THEN 'quarantined' END,
       CASE WHEN c.row_class = 'data' AND c.role = 'households' THEN 'households_side_of_area_year' ELSE c.reason END,
       CASE WHEN c.row_class = 'data' AND c.role = 'households'
            THEN to_json(named_struct('_source_key', c._source_key, 'area_key', c.area_key, 'year', c.year)) END,
       current_timestamp()
FROM public_health.silver.workforce_area_denominator_silver__classified c
LEFT JOIN public_health.silver.workforce_area_denominator_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE NOT (c.row_class = 'data' AND c.role = 'population');


-- =============================================================================
-- [8] summary, then remove the staging tables (__classified is kept until the next run)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW denominator_summary AS
SELECT year, count(*) AS silver_rows, count_if(households_source_present) AS with_households,
       count_if(population_status = 'ok') AS population_ok
FROM public_health.silver.workforce_area_denominator_silver GROUP BY year;

DROP TABLE IF EXISTS public_health.silver.workforce_area_denominator_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.workforce_area_denominator_silver__gates;
DROP TABLE IF EXISTS public_health.silver.workforce_area_denominator_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.workforce_area_denominator_silver__households;

SELECT * FROM denominator_summary ORDER BY year;
