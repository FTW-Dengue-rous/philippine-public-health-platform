-- =============================================================================
-- Builds public_health.silver.diseases_tb_programme_silver:
--   one TB programme count for one area, year, age group and sex, from the FHSIS TB tables.
--   Key: (indicator, drug_resistance, area_key, year, age_group, sex, _source_key)
-- Follows lineage-qc-contract.md v1.3 and the pattern of diseases_silver_01_metric.sql
-- (classified -> inputs -> candidate -> gates -> build log -> write -> record).
--
-- Sources (bronze, sources_diseases.yaml entries 17 and 18; same 2025 workbook as doh_fhsis_tb)
--   diseases_fhsis_tb_tpt_bronze                 sheet TB-TPT      Table 2.F.7.3
--   diseases_fhsis_tb_treatment_success_bronze   sheets TSR-DSTB   Table 2.F.7.4 (drug-susceptible)
--                                                       TSR-MDRTB  Table 2.F.7.5 (RR / MDR-TB)
--
-- Indicators (counts only; rates and percentages are computed in gold)
--   indicator               drug_resistance                     ages                    sexes
--   tpt_given               not_applicable                      0_14, 15_over, all_ages male, female, both
--   tpt_eligible_contacts   not_applicable                      all_ages                both_sexes
--   treatment_cohort        drug_susceptible | drug_resistant   0_14, 15_over, age_unknown, all_ages   both_sexes
--   treatment_success       drug_susceptible | drug_resistant   0_14, 15_over, age_unknown, all_ages   male, female, both
--   * tpt_given = TB contacts given TB preventive treatment.
--   * tpt_eligible_contacts is the ESTIMATE FHSIS prints (notified TB cases x 4 contacts x 70%),
--     value_type 'estimated', DECIMAL (it has decimals in the file). Coverage % rests on it.
--   * treatment_success = cured + treatment completed, of the treatment_cohort: the cases whose
--     outcome is reported in the year, NOT the notifications of that year. The cohort is not split
--     by sex in the source.
--   * The printed % columns are not loaded. Gate [6] warns when the printed % differs from
--     success / cohort (or TPT / eligible) by more than 0.05 points.
--   * disease_key: tb_all_forms (TPT and drug-susceptible), tb_drug_resistant (RR / MDR-TB),
--     the same keys diseases_metric_silver uses for FHSIS TB notifications.
--
-- Areas (rule shared with workforce_silver_01: geography_silver is the only source of codes)
--   * The row's own PSGC code (10 digits), looked up in the latest geography_silver snapshot:
--     Reg / Prov / City / Mun -> region / province / city / municipality; 1999900000 ->
--     special_geographic_area. Parent: the province with the same 5-digit prefix for municipalities
--     and component cities, else the region; regions hang on 'ph'.
--   * The Philippines row has no code: area_key 'ph'.
--   * A code that is not in geography is QUARANTINED (reason psgc_not_in_geography), not guessed.
--     The 19999..... special geographic area municipalities therefore load when geography has them.
--     diseases_silver_01 still quarantines them for the TB notification table (finding F9); align
--     both when F9 is closed.
--   * Source and legend lines at the bottom (no area name) are non_data.
--
-- Values
--   '*' (incomplete / no data submitted) and blank cells -> value null, value_status 'no_report'.
--   Anything else that is not a number stops the build (parse_error gate).
--
-- Year: from the file name (..._2025.xlsx). period_basis 'reporting_year'.
-- Needs: diseases_silver_00_reference.sql (directory), quality_setup.sql, geography_silver,
--   bronze QC passed for doh_fhsis_tb_tpt and doh_fhsis_tb_treatment_success.
-- =============================================================================

-- [0] settings and helpers
DECLARE OR REPLACE VARIABLE tbp_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE tbp_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE geography_checksum STRING;
SET VARIABLE geography_checksum =
  (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

-- Same helpers as diseases_silver_01_metric.sql (kept identical)
CREATE OR REPLACE TEMPORARY FUNCTION dz_norm(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(translate(upper(s), 'Ñ', 'N'), '[^A-Z0-9]', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION dz_num(s STRING) RETURNS DECIMAL(20,4)
RETURN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4));

CREATE OR REPLACE TEMPORARY FUNCTION dz_status(s STRING, star_status STRING, blank_status STRING) RETURNS STRING
RETURN CASE WHEN s IS NULL OR trim(s) = '' THEN blank_status
            WHEN trim(s) = '*' AND star_status IS NOT NULL THEN star_status
            WHEN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4)) IS NOT NULL THEN 'ok'
            ELSE 'parse_error' END;

CREATE OR REPLACE TEMPORARY FUNCTION dz_file_year(f STRING) RETURNS INT
RETURN try_cast(regexp_extract(f, '_([0-9]{4})[.][A-Za-z]+$', 1) AS INT);

-- Areas of the latest geography snapshot, with level and parent (same rule as wf_geo)
CREATE OR REPLACE TEMP VIEW tbp_geo AS
WITH g AS (
  SELECT lpad(trim(CAST(psgc_code AS STRING)), 10, '0') AS psgc_code,
         CASE geographic_level WHEN 'Reg' THEN 'region' WHEN 'Prov' THEN 'province'
                               WHEN 'City' THEN 'city' WHEN 'Mun' THEN 'municipality'
              ELSE CASE WHEN geographic_level IS NULL
                         AND lpad(trim(CAST(psgc_code AS STRING)), 10, '0') = '1999900000'
                        THEN 'special_geographic_area' END END AS geo_level,
         CASE WHEN geographic_level = 'City' THEN nullif(upper(trim(city_class)), '') END AS city_class
  FROM public_health.silver.geography_silver
  WHERE content_checksum = geography_checksum)
SELECT g.psgc_code, g.geo_level,
       CASE WHEN g.geo_level = 'region' THEN 'ph'
            WHEN (g.geo_level = 'municipality'
                  OR (g.geo_level = 'city' AND coalesce(g.city_class, 'CC') NOT IN ('HUC', 'ICC')))
                 AND p.psgc_code IS NOT NULL THEN concat('psgc:', p.psgc_code)
            ELSE concat('psgc:', substr(g.psgc_code, 1, 2), '00000000') END AS parent_area_key
FROM g
LEFT JOIN g p
  ON p.psgc_code = concat(substr(g.psgc_code, 1, 5), '00000') AND p.geo_level IN ('province', 'special_geographic_area')
WHERE g.geo_level IS NOT NULL;


-- =============================================================================
-- [1] classify every bronze row of the three sheets
-- =============================================================================
CREATE OR REPLACE TEMP VIEW tbp_rows AS
SELECT 'public_health.bronze.diseases_fhsis_tb_tpt_bronze' AS input_table,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       psgc_code, area_name
FROM public_health.bronze.diseases_fhsis_tb_tpt_bronze WHERE _source_key = 'doh_fhsis'
UNION ALL
SELECT 'public_health.bronze.diseases_fhsis_tb_treatment_success_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       psgc_code, area_name
FROM public_health.bronze.diseases_fhsis_tb_treatment_success_bronze WHERE _source_key = 'doh_fhsis';

CREATE OR REPLACE TABLE public_health.silver.diseases_tb_programme_silver__classified AS
WITH r AS (
  SELECT t.*, dz_norm(area_name) AS area_norm,
         CASE WHEN trim(psgc_code) RLIKE '^[0-9]{9,10}$' THEN lpad(trim(psgc_code), 10, '0') END AS code10,
         dz_file_year(_source_file) AS file_year
  FROM tbp_rows t)
SELECT r.*,
       g.geo_level, g.parent_area_key,
       CASE WHEN r.area_norm = 'PHILIPPINES' AND r.code10 IS NULL THEN 'ph'
            WHEN g.psgc_code IS NOT NULL THEN concat('psgc:', r.code10) END AS area_key,
       CASE WHEN r.area_name IS NULL THEN 'non_data'
            WHEN r.area_norm = 'PHILIPPINES' AND r.code10 IS NULL THEN 'data'
            WHEN r.code10 IS NULL THEN 'unclassified'
            WHEN g.psgc_code IS NULL THEN 'quarantined'
            ELSE 'data' END AS row_class,
       CASE WHEN r.area_name IS NULL THEN CASE WHEN upper(r.psgc_code) LIKE 'SOURCE%' THEN 'source_line' ELSE 'legend' END
            WHEN r.area_norm = 'PHILIPPINES' AND r.code10 IS NULL THEN NULL
            WHEN r.code10 IS NULL THEN 'area_code_not_readable'
            WHEN g.psgc_code IS NULL THEN 'psgc_not_in_geography' END AS reason,
       CASE r._source_sheet WHEN 'TB-TPT' THEN 10 WHEN 'TSR-DSTB' THEN 16 WHEN 'TSR-MDRTB' THEN 16 END AS measures_per_row
FROM r
LEFT JOIN tbp_geo g ON g.psgc_code = r.code10;


-- =============================================================================
-- [2] inputs: the three sheets, geography and the directory (layout of quality.build_inputs)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW tbp_table_versions AS
SELECT 'public_health.bronze.diseases_fhsis_tb_tpt_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_fhsis_tb_tpt_bronze)) AS table_version
UNION ALL SELECT 'public_health.bronze.diseases_fhsis_tb_treatment_success_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_fhsis_tb_treatment_success_bronze))
UNION ALL SELECT 'public_health.silver.geography_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.geography_silver))
UNION ALL SELECT 'public_health.silver.diseases_directory_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_directory_silver));

CREATE OR REPLACE TABLE public_health.silver.diseases_tb_programme_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.diseases_tb_programme_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at)
SELECT tbp_build_id AS build_id, 'public_health.silver.diseases_tb_programme_silver' AS target_table,
       'bronze_source' AS input_kind, f.input_table, max(v.table_version) AS input_table_version,
       f._source_key AS source_key, f._source_file AS source_file, f._source_sheet AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at AS ingested_at, f.input_rows, CAST(NULL AS STRING) AS reference_version,
       count(m.batch_id) AS metadata_matches
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet AND m.retrieved_at = f._ingested_at
 AND m.bronze_table = f.input_table
LEFT JOIN tbp_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
SELECT tbp_build_id, 'public_health.silver.diseases_tb_programme_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CASE WHEN t.table_name LIKE '%geography_silver' THEN geography_checksum END,
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.geography_silver' AS table_name, count(*) AS n FROM tbp_geo
      UNION ALL SELECT 'public_health.silver.diseases_directory_silver', count(*)
                FROM public_health.silver.diseases_directory_silver) t
LEFT JOIN tbp_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] unpivot: one view per layout, same columns
--     (indicator, indicator_definition, drug_resistance, disease_key, age_group, sex, value_type,
--      raw, src_col, + the row's lineage and area)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW tbp_part_tpt AS
WITH s AS (
  SELECT c.area_key, c.geo_level, c.parent_area_key, c.code10, c.file_year,
         b.*
  FROM public_health.bronze.diseases_fhsis_tb_tpt_bronze b
  JOIN public_health.silver.diseases_tb_programme_silver__classified c
    ON c.input_table = 'public_health.bronze.diseases_fhsis_tb_tpt_bronze'
   AND c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'doh_fhsis' AND c.row_class = 'data')
SELECT area_key, geo_level, parent_area_key, code10, area_name, file_year,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       'not_applicable' AS drug_resistance, 'tb_all_forms' AS disease_key,
       stack(10,
         'tpt_given', '0_14',    'male',       'reported',  tpt_0_14_male,         'tpt_0_14_male',
         'tpt_given', '0_14',    'female',     'reported',  tpt_0_14_female,       'tpt_0_14_female',
         'tpt_given', '0_14',    'both_sexes', 'reported',  tpt_0_14_total,        'tpt_0_14_total',
         'tpt_given', '15_over', 'male',       'reported',  tpt_15_over_male,      'tpt_15_over_male',
         'tpt_given', '15_over', 'female',     'reported',  tpt_15_over_female,    'tpt_15_over_female',
         'tpt_given', '15_over', 'both_sexes', 'reported',  tpt_15_over_total,     'tpt_15_over_total',
         'tpt_given', 'all_ages', 'male',      'reported',  tpt_all_male,          'tpt_all_male',
         'tpt_given', 'all_ages', 'female',    'reported',  tpt_all_female,        'tpt_all_female',
         'tpt_given', 'all_ages', 'both_sexes', 'reported', tpt_all_total,         'tpt_all_total',
         'tpt_eligible_contacts', 'all_ages', 'both_sexes', 'estimated', tpt_eligible_population, 'tpt_eligible_population'
       ) AS (indicator, age_group, sex, value_type, raw, src_col)
FROM s;

CREATE OR REPLACE TEMP VIEW tbp_part_tsr AS
WITH s AS (
  SELECT c.area_key, c.geo_level, c.parent_area_key, c.code10, c.file_year,
         b.*
  FROM public_health.bronze.diseases_fhsis_tb_treatment_success_bronze b
  JOIN public_health.silver.diseases_tb_programme_silver__classified c
    ON c.input_table = 'public_health.bronze.diseases_fhsis_tb_treatment_success_bronze'
   AND c._source_key = b._source_key AND c._source_file = b._source_file
   AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num
  WHERE b._source_key = 'doh_fhsis' AND c.row_class = 'data')
SELECT area_key, geo_level, parent_area_key, code10, area_name, file_year,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       CASE _source_sheet WHEN 'TSR-DSTB' THEN 'drug_susceptible' WHEN 'TSR-MDRTB' THEN 'drug_resistant' END AS drug_resistance,
       CASE _source_sheet WHEN 'TSR-DSTB' THEN 'tb_all_forms' WHEN 'TSR-MDRTB' THEN 'tb_drug_resistant' END AS disease_key,
       stack(16,
         'treatment_cohort',  '0_14',        'both_sexes', 'reported', cohort_cases_0_14,          'cohort_cases_0_14',
         'treatment_cohort',  '15_over',     'both_sexes', 'reported', cohort_cases_15_over,       'cohort_cases_15_over',
         'treatment_cohort',  'age_unknown', 'both_sexes', 'reported', cohort_cases_age_unknown,   'cohort_cases_age_unknown',
         'treatment_cohort',  'all_ages',    'both_sexes', 'reported', cohort_cases_all,           'cohort_cases_all',
         'treatment_success', '0_14',        'male',       'reported', success_0_14_male,          'success_0_14_male',
         'treatment_success', '0_14',        'female',     'reported', success_0_14_female,        'success_0_14_female',
         'treatment_success', '0_14',        'both_sexes', 'reported', success_0_14_total,         'success_0_14_total',
         'treatment_success', '15_over',     'male',       'reported', success_15_over_male,       'success_15_over_male',
         'treatment_success', '15_over',     'female',     'reported', success_15_over_female,     'success_15_over_female',
         'treatment_success', '15_over',     'both_sexes', 'reported', success_15_over_total,      'success_15_over_total',
         'treatment_success', 'age_unknown', 'male',       'reported', success_age_unknown_male,   'success_age_unknown_male',
         'treatment_success', 'age_unknown', 'female',     'reported', success_age_unknown_female, 'success_age_unknown_female',
         'treatment_success', 'age_unknown', 'both_sexes', 'reported', success_age_unknown_total,  'success_age_unknown_total',
         'treatment_success', 'all_ages',    'male',       'reported', success_all_male,           'success_all_male',
         'treatment_success', 'all_ages',    'female',     'reported', success_all_female,         'success_all_female',
         'treatment_success', 'all_ages',    'both_sexes', 'reported', success_all_total,          'success_all_total'
       ) AS (indicator, age_group, sex, value_type, raw, src_col)
FROM s;


-- =============================================================================
-- [4] candidate rows
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_tb_programme_silver__candidate AS
SELECT
  p.indicator,
  CASE p.indicator
    WHEN 'tpt_given'             THEN 'tb_contacts_given_preventive_treatment'
    WHEN 'tpt_eligible_contacts' THEN 'tb_contacts_eligible_for_tpt_estimated_cases_x4_x70pct'
    WHEN 'treatment_cohort'      THEN 'tb_cases_in_treatment_outcome_cohort'
    WHEN 'treatment_success'     THEN 'tb_cases_cured_or_treatment_completed' END AS indicator_definition,
  p.drug_resistance, p.disease_key,
  p.area_key, trim(p.area_name) AS area_label_source,
  CASE WHEN p.area_key = 'ph' THEN 'country' ELSE p.geo_level END AS geo_level,
  p.code10 AS psgc_code,
  CASE WHEN p.area_key = 'ph' THEN NULL ELSE p.parent_area_key END AS parent_area_key,
  'year' AS period_grain, CAST(p.file_year AS STRING) AS period_key, p.file_year AS year,
  make_date(p.file_year, 1, 1) AS period_start, make_date(p.file_year, 12, 31) AS period_end,
  'reporting_year' AS period_basis,
  p.age_group, p.sex,
  dz_num(p.raw) AS value,
  CASE WHEN p.indicator = 'tpt_eligible_contacts' THEN 'persons_estimated' ELSE 'count' END AS value_unit,
  p.value_type,
  dz_status(p.raw, 'no_report', 'no_report') AS value_status,
  'reporting_unit' AS location_basis,
  tbp_build_id AS _silver_build_id,
  p._source_key, p._source_file, p._source_sheet, p._source_row_num, p._as_of_date,
  map('value', p.src_col) AS _metric_source_columns
FROM (SELECT * FROM tbp_part_tpt UNION ALL SELECT * FROM tbp_part_tsr) p;


-- =============================================================================
-- [4b] rows not loaded (contract v1.3, 7.1), saved before the gates
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_tb_programme_silver__dispositions AS
SELECT tbp_build_id AS build_id, 'public_health.silver.diseases_tb_programme_silver' AS target_table,
       c._source_key AS source_key, c._source_file AS source_file, c._source_sheet AS source_sheet,
       c._source_row_num AS source_row_num, i.load_batch_id, i.content_checksum,
       CASE c.row_class WHEN 'non_data' THEN 'dropped_non_data' ELSE 'quarantined' END AS disposition,
       c.reason,
       to_json(named_struct('psgc_code', c.psgc_code, 'area_name', c.area_name)) AS target_key,
       current_timestamp() AS recorded_at
FROM public_health.silver.diseases_tb_programme_silver__classified c
LEFT JOIN public_health.silver.diseases_tb_programme_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.input_table = c.input_table AND i.source_key = c._source_key
 AND i.source_file = c._source_file AND i.source_sheet <=> c._source_sheet
WHERE c.row_class IN ('non_data', 'quarantined');


-- =============================================================================
-- [5] percentages printed by the source, for the warning gate only (never published)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW tbp_printed_pct AS
SELECT c._source_sheet, c._source_row_num, 'tpt_coverage' AS what,
       dz_num(b.tpt_coverage_pct) AS printed,
       CASE WHEN dz_num(b.tpt_eligible_population) > 0
            THEN dz_num(b.tpt_all_total) / dz_num(b.tpt_eligible_population) * 100 END AS recomputed
FROM public_health.bronze.diseases_fhsis_tb_tpt_bronze b
JOIN public_health.silver.diseases_tb_programme_silver__classified c
  ON c.input_table = 'public_health.bronze.diseases_fhsis_tb_tpt_bronze' AND c._source_file = b._source_file
 AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num AND c.row_class = 'data'
UNION ALL
SELECT c._source_sheet, c._source_row_num, concat('success_', x.age),
       dz_num(x.pct),
       CASE WHEN dz_num(x.cohort) > 0 THEN dz_num(x.success) / dz_num(x.cohort) * 100 END
FROM public_health.bronze.diseases_fhsis_tb_treatment_success_bronze b
JOIN public_health.silver.diseases_tb_programme_silver__classified c
  ON c.input_table = 'public_health.bronze.diseases_fhsis_tb_treatment_success_bronze' AND c._source_file = b._source_file
 AND c._source_sheet <=> b._source_sheet AND c._source_row_num = b._source_row_num AND c.row_class = 'data'
LATERAL VIEW stack(3,
  '0_14',     b.success_0_14_pct,    b.success_0_14_total,    b.cohort_cases_0_14,
  '15_over',  b.success_15_over_pct, b.success_15_over_total, b.cohort_cases_15_over,
  'all_ages', b.success_all_pct,     b.success_all_total,     b.cohort_cases_all) x AS age, pct, success, cohort;


-- =============================================================================
-- [6] gates. severity 'fail' stops the build; 'warn' is reported in build_log.parameters.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_tb_programme_silver__gates AS
SELECT 'inputs: not exactly the three sheets TB-TPT, TSR-DSTB, TSR-MDRTB' AS gate, 'fail' AS severity,
       CASE WHEN (SELECT count(*) FROM public_health.silver.diseases_tb_programme_silver__inputs WHERE input_kind = 'bronze_source') = 3
             AND (SELECT count(DISTINCT source_sheet) FROM public_health.silver.diseases_tb_programme_silver__inputs
                  WHERE input_kind = 'bronze_source' AND source_sheet IN ('TB-TPT', 'TSR-DSTB', 'TSR-MDRTB')) = 3
            THEN 0 ELSE 1 END AS failures
UNION ALL
SELECT 'inputs: no processed ingestion log match, or more than one', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__inputs
  WHERE input_kind = 'bronze_source' AND (metadata_matches > 1 OR (metadata_matches = 0 AND strict_load_lookup))
UNION ALL
SELECT 'inputs: year not readable from the file name', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__classified WHERE file_year IS NULL
UNION ALL
SELECT 'unclassified bronze rows (an area name without a readable code)', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__classified WHERE row_class = 'unclassified'
UNION ALL
SELECT 'bronze row classified more than once', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_tb_programme_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'one Philippines row per sheet', 'fail', count(*) FROM (
  SELECT _source_sheet FROM public_health.silver.diseases_tb_programme_silver__classified
  GROUP BY _source_sheet HAVING count_if(area_key = 'ph') <> 1)
UNION ALL
SELECT 'cell that is neither a number nor * / blank', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__candidate WHERE value_status = 'parse_error'
UNION ALL
SELECT 'null value with status ok, or a value with another status', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__candidate WHERE (value IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'negative value', 'fail', count(*) FROM public_health.silver.diseases_tb_programme_silver__candidate WHERE value < 0
UNION ALL
SELECT 'count that is not a whole number (all but tpt_eligible_contacts)', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__candidate
  WHERE value_unit = 'count' AND value <> floor(value)
UNION ALL
SELECT 'disease_key not in the directory', 'fail', count(*) FROM (
  SELECT DISTINCT disease_key FROM public_health.silver.diseases_tb_programme_silver__candidate) c
  LEFT ANTI JOIN public_health.silver.diseases_directory_silver d ON d.disease_key = c.disease_key
UNION ALL
SELECT 'key column null', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__candidate
  WHERE indicator IS NULL OR drug_resistance IS NULL OR area_key IS NULL OR year IS NULL
     OR age_group IS NULL OR sex IS NULL OR _source_key IS NULL
UNION ALL
SELECT 'key not unique', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_tb_programme_silver__candidate
  GROUP BY indicator, drug_resistance, area_key, year, age_group, sex, _source_key HAVING count(*) > 1)
UNION ALL
SELECT 'lineage: a lineage column is null', 'fail', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _source_sheet IS NULL
     OR _source_row_num IS NULL OR _as_of_date IS NULL OR _metric_source_columns IS NULL
UNION ALL
-- output validation (contract 7.2), per sheet
SELECT concat(c._source_sheet, ': silver rows <> data rows x measures per row'), 'fail',
       abs(c.expected - coalesce(s.n, 0))
  FROM (SELECT _source_sheet, sum(CASE WHEN row_class = 'data' THEN measures_per_row ELSE 0 END) AS expected
        FROM public_health.silver.diseases_tb_programme_silver__classified GROUP BY _source_sheet) c
  LEFT JOIN (SELECT _source_sheet, count(*) AS n FROM public_health.silver.diseases_tb_programme_silver__candidate
             GROUP BY _source_sheet) s ON s._source_sheet = c._source_sheet
UNION ALL
SELECT 'reconciliation: rows read - rows not loaded <> rows referenced by silver', 'fail', count(*)
FROM public_health.silver.diseases_tb_programme_silver__inputs i
LEFT JOIN (SELECT _source_key, _source_file, _source_sheet, count(*) AS n FROM (
             SELECT DISTINCT _source_key, _source_file, _source_sheet, _source_row_num
             FROM public_health.silver.diseases_tb_programme_silver__candidate)
           GROUP BY _source_key, _source_file, _source_sheet) ref
  ON ref._source_key = i.source_key AND ref._source_file = i.source_file AND ref._source_sheet <=> i.source_sheet
LEFT JOIN (SELECT source_key, source_file, source_sheet, count(*) AS n
           FROM public_health.silver.diseases_tb_programme_silver__dispositions
           GROUP BY source_key, source_file, source_sheet) nl
  ON nl.source_key = i.source_key AND nl.source_file = i.source_file AND nl.source_sheet <=> i.source_sheet
WHERE i.input_kind = 'bronze_source' AND i.input_rows - coalesce(nl.n, 0) <> coalesce(ref.n, 0)
UNION ALL
-- warnings: reported, never block
SELECT 'warn: area rows quarantined (code not in geography)', 'warn', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__dispositions WHERE disposition = 'quarantined'
UNION ALL
SELECT 'warn: area rows with no report (every value * or blank)', 'warn', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_tb_programme_silver__candidate
  GROUP BY _source_sheet, _source_row_num HAVING count_if(value_status = 'ok') = 0)
UNION ALL
SELECT 'warn: treatment success above the cohort', 'warn', count(*)
  FROM public_health.silver.diseases_tb_programme_silver__candidate s
  JOIN public_health.silver.diseases_tb_programme_silver__candidate c
    ON c.indicator = 'treatment_cohort' AND c.drug_resistance = s.drug_resistance AND c.area_key = s.area_key
   AND c.year = s.year AND c.age_group = s.age_group
  WHERE s.indicator = 'treatment_success' AND s.sex = 'both_sexes' AND s.value > c.value
UNION ALL
SELECT 'warn: TPT coverage above 100 percent of the estimated eligible contacts', 'warn', count(*)
  FROM tbp_printed_pct WHERE what = 'tpt_coverage' AND recomputed > 100
UNION ALL
SELECT 'warn: printed percentage differs from the recomputed one by more than 0.05 points', 'warn', count(*)
  FROM tbp_printed_pct WHERE printed IS NOT NULL AND recomputed IS NOT NULL AND abs(printed - recomputed) > 0.05;


-- =============================================================================
-- [7] build log row; stop if a gate failed (the failed build is logged first)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW tbp_build_log AS
SELECT tbp_build_id AS build_id, 'silver' AS layer, 'diseases' AS domain,
       'public_health.silver.diseases_tb_programme_silver' AS target_table,
       tbp_build_started_at AS started_at, current_timestamp() AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.diseases_tb_programme_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT) AS target_table_version, code_version AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup, 'geography_checksum', geography_checksum,
                            'warnings', g.warn_names)) AS parameters,
       job_run_id AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0 AND severity = 'fail') AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'fail' THEN concat(gate, ' = ', failures) END)) AS failed_names,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'warn' THEN concat(gate, ' = ', failures) END)) AS warn_names
      FROM public_health.silver.diseases_tb_programme_silver__gates) g;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM tbp_build_log WHERE status = 'failed';

SELECT raise_error(concat('diseases_tb_programme_silver was NOT published. ', error_message))
FROM tbp_build_log WHERE status = 'failed';


-- =============================================================================
-- [8] write (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_tb_programme_silver AS
SELECT * FROM public_health.silver.diseases_tb_programme_silver__candidate;


-- =============================================================================
-- [9] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.diseases_tb_programme_silver),
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_tb_programme_silver)),
       code_version, parameters, run_id, error_message
FROM tbp_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.diseases_tb_programme_silver__inputs;

INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
       content_checksum, disposition, reason, target_key, recorded_at
FROM public_health.silver.diseases_tb_programme_silver__dispositions;


-- =============================================================================
-- [10] summary and warnings; drop the staging tables (__classified kept until the next run)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW tbp_summary AS
SELECT indicator, drug_resistance, geo_level, count(*) AS rows, count_if(value_status = 'ok') AS with_value,
       sum(CASE WHEN area_key = 'ph' AND age_group = 'all_ages' AND sex = 'both_sexes' THEN value END) AS philippines_all_ages
FROM public_health.silver.diseases_tb_programme_silver
GROUP BY indicator, drug_resistance, geo_level;

SELECT gate, failures FROM public_health.silver.diseases_tb_programme_silver__gates WHERE severity = 'warn';

DROP TABLE IF EXISTS public_health.silver.diseases_tb_programme_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.diseases_tb_programme_silver__gates;
DROP TABLE IF EXISTS public_health.silver.diseases_tb_programme_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.diseases_tb_programme_silver__dispositions;

SELECT * FROM tbp_summary ORDER BY indicator, drug_resistance, geo_level;
