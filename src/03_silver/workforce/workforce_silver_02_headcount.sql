-- =============================================================================
-- Builds public_health.silver.workforce_headcount_silver:
--   one profession in one area in one year from one source (FHSIS 2018-2025, PSA T9.14 2012-2023).
--   Key: (_source_key, area_key, year, profession)
--
-- Build sequence (contract section 5.1)
--   Step 1, inputs
--     [0]  build id, settings, helper functions, declared layouts and eligibility rules
--     [1]  ..__classified   one row per bronze row read (FHSIS from workforce_fhsis__resolved, PSA)
--     [2]  ..__inputs       one row per file or sheet read, with load id and checksum; the
--                           geography and reference tables with their versions
--   Step 2, transform
--     [3]  FHSIS rows: one per data row and declared profession, a status per field
--     [4]  PSA T9.14 rows: 12 year columns unpivoted
--     [5]  ..__candidate    eligibility rules, series, review flags; saved to a staging table
--   Step 3, validate
--     [6]  ..__gates        every row must have failures = 0
--     [7]  headcount_build_log, then STOP if a gate failed (the failed build is logged first)
--   Step 4, record
--     [8]  write the table from the validated candidate
--     [9]  append build_log, build_inputs, row_disposition
--     [10] summary; drop the staging tables
--
-- QC of the published table (controls, reconciliation, review lists, quarantine rows, profile) is
-- in workforce_silver_qc.py, not here. The gates below only stop a bad build.
--
-- Needs
--   workforce_silver_00_reference.sql and workforce_silver_01_fhsis_areas.sql have been run (same job)
--   quality_setup.sql has been run (build_log, build_inputs, row_disposition)
--   Bronze QC passed for doh_fhsis_demographic and psa_gov_practitioners
--
-- Lineage on the silver row (contract 3.3, 7 columns)
--   _silver_build_id, _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
--   _metric_source_columns. Load time, load id and file checksum are in quality.build_inputs.
--
-- Differences from the contract, because this is plain SQL (same as the diseases files)
--   * Bronze is read at its current version, not pinned with VERSION AS OF. A gate stops the build
--     if the FHSIS bronze changed after workforce_silver_01 ran.
-- =============================================================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
-- true : every input needs exactly one processed ingestion_metadata row (contract 3.5).
-- false: a missing row is allowed; that input gets a null load id and checksum.
--        Use false only while the bronze B13 warnings are open.
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job

-- Upper case, accents folded, punctuation to spaces, single spaces. A damaged n-tilde ('Ã±', the
-- form geography_silver had before its repair) is read as 'ñ' first.
CREATE OR REPLACE TEMPORARY FUNCTION wf_norm(x STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(
         translate(upper(replace(replace(x, 'Ã±', 'ñ'), 'Ã‘', 'Ñ')), 'ÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑ', 'AAAAAEEEEIIIIOOOOOUUUUN'),
         '[^A-Z0-9 ]', ' '), ' +', ' '));

-- Text to number. Spaces and thousands separators removed; anything that is not a plain decimal
-- number gives null (so 'NaN', 'Infinity' and '1e5' are not read as numbers).
CREATE OR REPLACE TEMPORARY FUNCTION wf_num(x STRING) RETURNS DECIMAL(20,4)
RETURN CASE WHEN regexp_replace(trim(x), '[ ,]', '') RLIKE '^-?[0-9]+([.][0-9]+)?$'
            THEN try_cast(regexp_replace(trim(x), '[ ,]', '') AS DECIMAL(20,4)) END;

-- Status of one headcount cell (plan 3.2). A column the layout does not have is 'not_published'
-- and is decided by the caller. A fractional headcount is not a number here: parse_error.
CREATE OR REPLACE TEMPORARY FUNCTION wf_cell_status(raw STRING, zero_means_no_data BOOLEAN) RETURNS STRING
RETURN CASE WHEN raw IS NULL OR trim(raw) = '' THEN 'blank'
            WHEN trim(raw) = '*'  THEN 'no_report'
            WHEN trim(raw) = '**' THEN 'marker_undefined'     -- 2019-2020 Palawan DOH-hired; no legend defines it
            WHEN wf_num(raw) IS NULL OR wf_num(raw) <> floor(wf_num(raw)) THEN 'parse_error'
            WHEN coalesce(zero_means_no_data, false) AND wf_num(raw) = 0 THEN 'zero_no_data'
            ELSE 'ok' END;

-- FHSIS layout: the bronze column of each field, per year, sheet and profession. One profession
-- comes from exactly one sheet, so every headcount row has one bronze source row (plan 2.1).
-- Generated from sources_workforce.yaml; change both together.
CREATE OR REPLACE TEMP VIEW wf_layout AS
SELECT * FROM VALUES
  (2018, 'Table 3B.1', 'doctors', NULL, NULL, 'doctors_male', 'doctors_female', 'doctors_total'),
  (2018, 'Table 3B.1', 'nurses', NULL, NULL, 'nurses_male', 'nurses_female', 'nurses_total'),
  (2018, 'Table 3B.1', 'midwives', NULL, NULL, 'midwives_male', 'midwives_female', 'midwives_total'),
  (2018, 'Table 3B.1', 'dentists', NULL, NULL, 'dentists_male', 'dentists_female', 'dentists_total'),
  (2018, 'Table 3B.2', 'medtech', NULL, NULL, 'medtech_male', 'medtech_female', 'medtech_total'),
  (2018, 'Table 3B.2', 'nutritionists', NULL, NULL, 'nutritionists_male', 'nutritionists_female', 'nutritionists_total'),
  (2018, 'Table 3B.3', 'sanitary_engineers', NULL, NULL, 'sanitary_engineers_male', 'sanitary_engineers_female', 'sanitary_engineers_total'),
  (2018, 'Table 3B.3', 'sanitary_inspectors', NULL, NULL, 'sanitary_inspectors_male', 'sanitary_inspectors_female', 'sanitary_inspectors_total'),
  (2018, 'Table 3B.3', 'bhw', NULL, NULL, 'bhw_male', 'bhw_female', 'bhw_total'),
  (2019, 'HEALTH WORKERS PART1', 'doctors', 'doctors_lgu_hired', 'doctors_doh_hired', NULL, NULL, 'doctors_total'),
  (2019, 'HEALTH WORKERS PART1', 'nurses', 'nurses_lgu_hired', 'nurses_doh_hired', NULL, NULL, 'nurses_total'),
  (2019, 'HEALTH WORKERS PART1', 'dentists', 'dentists_lgu_hired', 'dentists_doh_hired', NULL, NULL, 'dentists_total'),
  (2019, 'Health Workers Part2', 'midwives', 'midwives_lgu_hired', 'midwives_doh_hired', NULL, NULL, 'midwives_total'),
  (2019, 'Health Workers Part2', 'medtech', 'medtech_lgu_hired', 'medtech_doh_hired', NULL, NULL, 'medtech_total'),
  (2019, 'Health Workers Part2', 'nutritionists', 'nutritionists_lgu_hired', 'nutritionists_doh_hired', NULL, NULL, 'nutritionists_total'),
  (2019, 'HEALTH WORKERS PART3', 'sanitary_engineers', 'sanitary_engineers_lgu_hired', 'sanitary_engineers_doh_hired', NULL, NULL, 'sanitary_engineers_total'),
  (2019, 'HEALTH WORKERS PART3', 'sanitary_inspectors', 'sanitary_inspectors_lgu_hired', 'sanitary_inspectors_doh_hired', NULL, NULL, 'sanitary_inspectors_total'),
  (2019, 'HEALTH WORKERS PART3', 'bhw', 'bhw_lgu_hired', 'bhw_doh_hired', NULL, NULL, 'bhw_total'),
  (2020, 'HEALTH WORKERS PART1', 'doctors', 'doctors_lgu_hired', 'doctors_doh_hired', NULL, NULL, 'doctors_total'),
  (2020, 'HEALTH WORKERS PART1', 'nurses', 'nurses_lgu_hired', 'nurses_doh_hired', NULL, NULL, 'nurses_total'),
  (2020, 'HEALTH WORKERS PART1', 'dentists', 'dentists_lgu_hired', 'dentists_doh_hired', NULL, NULL, 'dentists_total'),
  (2020, 'HEALTH WORKERS PART2', 'midwives', 'midwives_lgu_hired', 'midwives_doh_hired', NULL, NULL, 'midwives_total'),
  (2020, 'HEALTH WORKERS PART2', 'medtech', 'medtech_lgu_hired', 'medtech_doh_hired', NULL, NULL, 'medtech_total'),
  (2020, 'HEALTH WORKERS PART2', 'nutritionists', 'nutritionists_lgu_hired', 'nutritionists_doh_hired', NULL, NULL, 'nutritionists_total'),
  (2020, 'HEALTH WORKERS PART3', 'sanitary_engineers', 'sanitary_engineers_lgu_hired', 'sanitary_engineers_doh_hired', NULL, NULL, 'sanitary_engineers_total'),
  (2020, 'HEALTH WORKERS PART3', 'sanitary_inspectors', 'sanitary_inspectors_lgu_hired', 'sanitary_inspectors_doh_hired', NULL, NULL, 'sanitary_inspectors_total'),
  (2020, 'HEALTH WORKERS PART3', 'bhw', 'bhw_lgu_hired', 'bhw_doh_hired', NULL, NULL, 'bhw_total'),
  (2021, 'HEALTH WORKERS PART1', 'doctors', 'doctors_lgu_hired', 'doctors_doh_hired', NULL, NULL, 'doctors_total'),
  (2021, 'HEALTH WORKERS PART1', 'nurses', 'nurses_lgu_hired', 'nurses_doh_hired', NULL, NULL, 'nurses_total'),
  (2021, 'HEALTH WORKERS PART1', 'dentists', 'dentists_lgu_hired', 'dentists_doh_hired', NULL, NULL, 'dentists_total'),
  (2021, 'HW Part2', 'midwives', 'midwives_lgu_hired', 'midwives_doh_hired', NULL, NULL, 'midwives_total'),
  (2021, 'HW Part2', 'medtech', 'medtech_lgu_hired', 'medtech_doh_hired', NULL, NULL, 'medtech_total'),
  (2021, 'HW Part2', 'nutritionists', 'nutritionists_lgu_hired', 'nutritionists_doh_hired', NULL, NULL, 'nutritionists_total'),
  (2021, 'HEALTH WORKERS PART3', 'sanitary_engineers', 'sanitary_engineers_lgu_hired', 'sanitary_engineers_doh_hired', NULL, NULL, 'sanitary_engineers_total'),
  (2021, 'HEALTH WORKERS PART3', 'sanitary_inspectors', 'sanitary_inspectors_lgu_hired', 'sanitary_inspectors_doh_hired', NULL, NULL, 'sanitary_inspectors_total'),
  (2021, 'HEALTH WORKERS PART3', 'bhw', 'bhw_lgu_hired', 'bhw_doh_hired', NULL, NULL, 'bhw_total'),
  (2022, 'HEALTH WORKERS PART1', 'doctors', 'doctors_lgu_hired', 'doctors_doh_hired', NULL, NULL, 'doctors_total'),
  (2022, 'HEALTH WORKERS PART1', 'nurses', 'nurses_lgu_hired', 'nurses_doh_hired', NULL, NULL, 'nurses_total'),
  (2022, 'HEALTH WORKERS PART1', 'midwives', 'midwives_lgu_hired', 'midwives_doh_hired', NULL, NULL, 'midwives_total'),
  (2022, 'HEALTH WORKERS PART1', 'dentists', 'dentists_lgu_hired', 'dentists_doh_hired', NULL, NULL, 'dentists_total'),
  (2022, 'HEALTH WORKERS PART1', 'nutritionists', 'nutritionists_lgu_hired', 'nutritionists_doh_hired', NULL, NULL, 'nutritionists_total'),
  (2022, 'HEALTH WORKERS PART2', 'medtech', 'medtech_lgu_hired', 'medtech_doh_hired', NULL, NULL, 'medtech_total'),
  (2022, 'HEALTH WORKERS PART2', 'sanitary_engineers', 'sanitary_engineers_lgu_hired', 'sanitary_engineers_doh_hired', NULL, NULL, 'sanitary_engineers_total'),
  (2022, 'HEALTH WORKERS PART2', 'sanitary_inspectors', 'sanitary_inspectors_lgu_hired', 'sanitary_inspectors_doh_hired', NULL, NULL, 'sanitary_inspectors_total'),
  (2022, 'HEALTH WORKERS PART2', 'bhw', 'bhw_lgu_hired', 'bhw_doh_hired', NULL, NULL, 'bhw_total'),
  (2023, 'HEALTH WORKERS PART1', 'doctors', 'doctors_lgu_hired', 'doctors_doh_hired', NULL, NULL, 'doctors_total'),
  (2023, 'HEALTH WORKERS PART1', 'nurses', 'nurses_lgu_hired', 'nurses_doh_hired', NULL, NULL, 'nurses_total'),
  (2023, 'HEALTH WORKERS PART1', 'midwives', 'midwives_lgu_hired', 'midwives_doh_hired', NULL, NULL, 'midwives_total'),
  (2023, 'HEALTH WORKERS PART1', 'dentists', 'dentists_lgu_hired', 'dentists_doh_hired', NULL, NULL, 'dentists_total'),
  (2023, 'HEALTH WORKERS PART1', 'nutritionists', 'nutritionists_lgu_hired', 'nutritionists_doh_hired', NULL, NULL, 'nutritionists_total'),
  (2023, 'HEALTH WORKERS PART2', 'medtech', 'medtech_lgu_hired', 'medtech_doh_hired', NULL, NULL, 'medtech_total'),
  (2023, 'HEALTH WORKERS PART2', 'sanitary_engineers', 'sanitary_engineers_lgu_hired', 'sanitary_engineers_doh_hired', NULL, NULL, 'sanitary_engineers_total'),
  (2023, 'HEALTH WORKERS PART2', 'sanitary_inspectors', 'sanitary_inspectors_lgu_hired', 'sanitary_inspectors_doh_hired', NULL, NULL, 'sanitary_inspectors_total'),
  (2023, 'HEALTH WORKERS PART2', 'bhw', 'bhw_lgu_hired', 'bhw_doh_hired', NULL, NULL, 'bhw_total'),
  (2024, 'Health Workers', 'doctors', 'doctors_lgu_hired', 'doctors_doh_hired', NULL, NULL, 'doctors_total'),
  (2024, 'Health Workers', 'nurses', 'nurses_lgu_hired', 'nurses_doh_hired', NULL, NULL, 'nurses_total'),
  (2024, 'Health Workers', 'midwives', 'midwives_lgu_hired', 'midwives_doh_hired', NULL, NULL, 'midwives_total'),
  (2024, 'Health Workers', 'dentists', 'dentists_lgu_hired', 'dentists_doh_hired', NULL, NULL, 'dentists_total'),
  (2024, 'Health Workers', 'medtech', 'medtech_lgu_hired', 'medtech_doh_hired', NULL, NULL, 'medtech_total'),
  (2024, 'Health Workers', 'nutritionists', 'nutritionists_lgu_hired', 'nutritionists_doh_hired', NULL, NULL, 'nutritionists_total'),
  (2024, 'Health Workers', 'sanitary_engineers', 'sanitary_engineers_lgu_hired', 'sanitary_engineers_doh_hired', NULL, NULL, 'sanitary_engineers_total'),
  (2024, 'Health Workers', 'sanitary_inspectors', 'sanitary_inspectors_lgu_hired', 'sanitary_inspectors_doh_hired', NULL, NULL, 'sanitary_inspectors_total'),
  (2024, 'Health Workers', 'bhw', 'bhw_lgu_hired', 'bhw_doh_hired', NULL, NULL, 'bhw_total'),
  (2025, 'Health Workers', 'doctors', 'doctors_lgu_hired', 'doctors_doh_hired', NULL, NULL, 'doctors_total'),
  (2025, 'Health Workers', 'nurses', 'nurses_lgu_hired', 'nurses_doh_hired', NULL, NULL, 'nurses_total'),
  (2025, 'Health Workers', 'midwives', 'midwives_lgu_hired', 'midwives_doh_hired', NULL, NULL, 'midwives_total'),
  (2025, 'Health Workers', 'dentists', 'dentists_lgu_hired', 'dentists_doh_hired', NULL, NULL, 'dentists_total'),
  (2025, 'Health Workers', 'medtech', 'medtech_lgu_hired', 'medtech_doh_hired', NULL, NULL, 'medtech_total'),
  (2025, 'Health Workers', 'nutritionists', 'nutritionists_lgu_hired', 'nutritionists_doh_hired', NULL, NULL, 'nutritionists_total'),
  (2025, 'Health Workers', 'sanitary_engineers', 'sanitary_engineers_lgu_hired', 'sanitary_engineers_doh_hired', NULL, NULL, 'sanitary_engineers_total'),
  (2025, 'Health Workers', 'sanitary_inspectors', 'sanitary_inspectors_lgu_hired', 'sanitary_inspectors_doh_hired', NULL, NULL, 'sanitary_inspectors_total'),
  (2025, 'Health Workers', 'bhw', 'bhw_lgu_hired', NULL, NULL, NULL, NULL)
AS t(year, sheet, profession, lgu_col, doh_col, male_col, female_col, total_col);

-- Profession labels as printed in the sheet headers (sources_workforce.yaml header_check).
CREATE OR REPLACE TEMP VIEW wf_source_labels AS
SELECT * FROM VALUES
  (2018, 2018, 'doctors', 'MD'), (2018, 2018, 'dentists', 'Dentist'), (2018, 2018, 'nurses', 'PHN'),
  (2018, 2018, 'midwives', 'Midwives'), (2018, 2018, 'nutritionists', 'Nutritionist'),
  (2018, 2018, 'medtech', 'Med. Technologist'), (2018, 2018, 'sanitary_engineers', 'Sanitary Engineer'),
  (2018, 2018, 'sanitary_inspectors', 'Sanitary Inspector'), (2018, 2018, 'bhw', 'Active BHW'),
  (2019, 2023, 'doctors', 'MDs'), (2019, 2023, 'dentists', 'Dentists'), (2019, 2023, 'nurses', 'PHNs'),
  (2019, 2023, 'midwives', 'Midwives'), (2019, 2023, 'nutritionists', 'Nutritionists'),
  (2019, 2023, 'medtech', 'Medical Technologists'), (2019, 2023, 'sanitary_engineers', 'Sanitary Engineers'),
  (2019, 2023, 'sanitary_inspectors', 'Sanitary Inspectors'), (2019, 2023, 'bhw', 'Active BHWs'),
  (2024, 2025, 'doctors', 'Doctors'), (2024, 2025, 'dentists', 'Dentists'), (2024, 2025, 'nurses', 'Nurses'),
  (2024, 2025, 'midwives', 'Midwives'), (2024, 2025, 'nutritionists', 'Nutritionists'),
  (2024, 2025, 'medtech', 'Medical Technologists'), (2024, 2025, 'sanitary_engineers', 'Sanitary Engineers'),
  (2024, 2025, 'sanitary_inspectors', 'Sanitary Inspectors'), (2024, 2025, 'bhw', 'Barangay Health Workers')
AS t(year_from, year_to, profession, source_label);

-- Named eligibility rules (plan 3.2). A value is never excluded without a rule listed here.
--   condition 'any'                             the listed area-years
--   condition 'total_zero'                      listed area-years whose total is 0
--   condition 'province_zero_children_positive' a province whose total is 0 while its
--                                               municipalities and cities sum to more than 0
--   condition 'total_zero_splits_blank'         total 0 while LGU and DOH cells are both blank (the 0
--                                               is the sheet's sum of empty cells; e.g. 2020 Region I)
--   condition 'total_zero_split_positive'       total 0 while a split cell is above 0 (e.g. 2022
--                                               Region V BHWs)
--   year / area_key / profession NULL = any.
CREATE OR REPLACE TEMP VIEW wf_eligibility_rules AS
SELECT * FROM VALUES
  ('R1_PROVINCE_ZERO_CHILDREN_POSITIVE', 'doh_fhsis_demographic', CAST(NULL AS STRING), 2025, CAST(NULL AS STRING),
   'province_zero_children_positive', 'Province total = 0 while its municipalities and cities sum > 0 (2025 Sulu)'),
  ('R2_NEW_PROVINCE_FIRST_YEAR_ZERO', 'doh_fhsis_demographic', 'psgc:1908700000', 2024, NULL,
   'total_zero', 'Maguindanao del Norte, first year as a province, total 0 while the predecessor had staff'),
  ('R2_NEW_PROVINCE_FIRST_YEAR_ZERO', 'doh_fhsis_demographic', 'psgc:1908800000', 2024, NULL,
   'total_zero', 'Maguindanao del Sur, first year as a province, total 0 while the predecessor had staff'),
  ('R3_PSA_SUSPECT_VALUE', 'psa_gov_practitioners', 'psgc:0100000000', 2020, NULL,
   'any', 'Region I 2020: doctors 51 and other professions drop in one year'),
  ('R3_PSA_SUSPECT_VALUE', 'psa_gov_practitioners', 'psgc:1600000000', 2013, NULL,
   'any', 'CARAGA 2013: every profession 0'),
  ('R4_TOTAL_ZERO_SPLITS_BLANK', 'doh_fhsis_demographic', NULL, NULL, NULL,
   'total_zero_splits_blank', 'Total 0 while LGU-hired and DOH-hired are both blank'),
  ('R5_TOTAL_ZERO_SPLIT_POSITIVE', 'doh_fhsis_demographic', NULL, NULL, NULL,
   'total_zero_split_positive', 'Total 0 while a split field is above 0')
AS t(rule_id, source_key, area_key, year, profession, condition, description);

-- PSA area labels: the exceptions file only (every PSA label is a region or the country)
CREATE OR REPLACE TEMP VIEW wf_exc_psa AS
SELECT CAST(year_from AS INT) AS year_from, CAST(year_to AS INT) AS year_to, match_role, area_label_norm,
       CASE WHEN nullif(trim(psgc_code), '') IS NOT NULL THEN lpad(trim(psgc_code), 10, '0') END AS psgc_code,
       nullif(trim(area_key), '') AS named_area_key, nullif(trim(named_key_level), '') AS named_key_level,
       CASE WHEN nullif(trim(named_key_parent_psgc), '') IS NOT NULL THEN lpad(trim(named_key_parent_psgc), 10, '0') END AS named_key_parent_psgc
FROM public_health.silver.workforce_area_exceptions
WHERE _source_key = 'psa_gov_practitioners';


-- =============================================================================
-- [1] classified bronze rows, one line per bronze row (staging table)
--     FHSIS: data rows need a resolved area. Blank-label rows that carry numbers in the declared
--     columns are quarantined, not dropped (G13). measures_per_row = rows one data row must give.
-- =============================================================================
CREATE OR REPLACE TEMP VIEW wf_psa_long AS
SELECT b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date, b._ingested_at,
       trim(b.Region) AS area_label_source,
       regexp_replace(trim(b.Region), '^[.]+', '') AS region_label_clean,
       wf_norm(b.Region) AS label_norm,
       trim(b.Professionals) AS source_label,
       CASE lower(trim(b.Professionals)) WHEN 'doctors' THEN 'doctors' WHEN 'dentists' THEN 'dentists'
            WHEN 'nurses' THEN 'nurses' WHEN 'midwives' THEN 'midwives' END AS profession,
       u.year, u.raw, u.src_col
FROM public_health.bronze.workforce_psa_gov_practitioners_bronze b
LATERAL VIEW stack(12,
  2012, b.`2012`, '2012', 2013, b.`2013`, '2013', 2014, b.`2014`, '2014', 2015, b.`2015`, '2015',
  2016, b.`2016`, '2016', 2017, b.`2017`, '2017', 2018, b.`2018`, '2018', 2019, b.`2019`, '2019',
  2020, b.`2020`, '2020', 2021, b.`2021`, '2021', 2022, b.`2022`, '2022', 2023, b.`2023`, '2023') u AS year, raw, src_col
WHERE b._source_key = 'psa_gov_practitioners';

CREATE OR REPLACE TEMP VIEW wf_psa_resolved AS
SELECT p.*, e.match_role, e.psgc_code AS exc_psgc, e.named_area_key, e.named_key_level, e.named_key_parent_psgc,
       count(e.area_label_norm) OVER (PARTITION BY p._source_file, p._source_row_num, p.year) AS n_match
FROM wf_psa_long p
LEFT JOIN wf_exc_psa e ON e.area_label_norm = p.label_norm AND p.year BETWEEN e.year_from AND e.year_to;

CREATE OR REPLACE TABLE public_health.silver.workforce_headcount_silver__classified AS
WITH lay AS (SELECT year, sheet, count(*) AS n_professions FROM wf_layout GROUP BY year, sheet),
vals AS (
  SELECT r._source_file, r._source_sheet, r._source_row_num,
         bool_or(wf_num(r.cells[l.lgu_col]) IS NOT NULL OR wf_num(r.cells[l.doh_col]) IS NOT NULL
              OR wf_num(r.cells[l.male_col]) IS NOT NULL OR wf_num(r.cells[l.female_col]) IS NOT NULL
              OR wf_num(r.cells[l.total_col]) IS NOT NULL) AS has_values
  FROM public_health.silver.workforce_fhsis__resolved r
  JOIN wf_layout l ON l.year = r.year AND l.sheet = r._source_sheet
  GROUP BY r._source_file, r._source_sheet, r._source_row_num)
SELECT 'public_health.bronze.workforce_fhsis_health_workers_bronze' AS input_table,
       r._source_key, r._source_file, r._source_sheet, r._source_row_num, r._ingested_at, r._as_of_date,
       CASE WHEN lay.n_professions IS NULL THEN 'unclassified'
            WHEN r.label_kind = 'legend' THEN 'non_data'
            WHEN r.label_kind = 'blank' AND NOT coalesce(v.has_values, false) THEN 'non_data'
            WHEN r.label_kind = 'blank' THEN 'quarantined'
            WHEN r.resolve_method = 'code_not_in_geography' THEN 'quarantined'
            WHEN r.resolve_method IN ('override', 'exception', 'psgc_code', 'name_join') AND r.area_in_geography THEN 'data'
            ELSE 'unclassified' END AS row_class,
       CASE WHEN lay.n_professions IS NULL THEN 'sheet_not_in_layout'
            WHEN r.label_kind = 'legend' THEN 'legend'
            WHEN r.label_kind = 'blank' AND NOT coalesce(v.has_values, false) THEN 'blank_row'
            WHEN r.label_kind = 'blank' THEN 'area_label_missing'
            WHEN r.resolve_method = 'code_not_in_geography' THEN 'psgc_code_not_in_geography'
            WHEN r.resolve_method IN ('override', 'exception', 'psgc_code', 'name_join') AND r.area_in_geography THEN NULL
            ELSE coalesce(r.resolve_method, 'unresolved') END AS reason,
       lay.n_professions AS measures_per_row
FROM public_health.silver.workforce_fhsis__resolved r
LEFT JOIN lay ON lay.year = r.year AND lay.sheet = r._source_sheet
LEFT JOIN vals v ON v._source_file = r._source_file AND v._source_sheet <=> r._source_sheet AND v._source_row_num = r._source_row_num
UNION ALL
SELECT 'public_health.bronze.workforce_psa_gov_practitioners_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, max(_as_of_date),
       CASE WHEN bool_and(n_match = 1) AND bool_and(profession IS NOT NULL) THEN 'data' ELSE 'unclassified' END,
       CASE WHEN NOT bool_and(profession IS NOT NULL) THEN 'profession_unknown'
            WHEN NOT bool_and(n_match = 1) THEN concat('area_label_not_in_exceptions: ', max(area_label_source)) END,
       12
FROM wf_psa_resolved
GROUP BY _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at;


-- =============================================================================
-- [2] inputs: everything this build reads, in the column layout of quality.build_inputs.
--     Each file or sheet is looked up ONCE in the ingestion log; never joined onto silver rows.
--     FHSIS and reference versions are the ones workforce_silver_01 read.
--     If your runtime rejects DESCRIBE HISTORY in a subquery, replace that subquery with
--     CAST(NULL AS BIGINT) (the build still works; the PSA version is just not recorded).
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_headcount_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.workforce_headcount_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at),
versions AS (
  SELECT table_name, table_version FROM public_health.silver.workforce_fhsis__versions
  UNION ALL
  SELECT 'public_health.bronze.workforce_psa_gov_practitioners_bronze',
         (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.workforce_psa_gov_practitioners_bronze)))
SELECT silver_build_id                                            AS build_id,
       'public_health.silver.workforce_headcount_silver'          AS target_table,
       'bronze_source'                                            AS input_kind,
       f.input_table,
       max(v.table_version)                                       AS input_table_version,
       f._source_key                                              AS source_key,
       f._source_file                                             AS source_file,
       f._source_sheet                                            AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END         AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at                                             AS ingested_at,
       f.input_rows,
       CAST(NULL AS STRING)                                       AS reference_version,
       count(m.batch_id)                                          AS metadata_matches      -- gate only, not appended
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet AND m.retrieved_at = f._ingested_at
LEFT JOIN versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
-- geography and the reviewed reference tables that shaped the build
SELECT silver_build_id, 'public_health.silver.workforce_headcount_silver', 'table', v.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), v.content_checksum,
       CAST(NULL AS TIMESTAMP), v.table_rows, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM public_health.silver.workforce_fhsis__versions v
WHERE v.table_name LIKE 'public_health.silver.%';


-- =============================================================================
-- [3] FHSIS: one row per data row and declared profession, with a status per field
-- =============================================================================
CREATE OR REPLACE TEMP VIEW wf_hc_fhsis AS
WITH x AS (
  SELECT r.*, l.profession, l.lgu_col, l.doh_col, l.male_col, l.female_col, l.total_col,
         coalesce(r.zero_means_no_data, false) AS znd
  FROM public_health.silver.workforce_fhsis__resolved r
  JOIN public_health.silver.workforce_headcount_silver__classified c
    ON c._source_file = r._source_file AND c._source_sheet <=> r._source_sheet
   AND c._source_row_num = r._source_row_num AND c.row_class = 'data'
  JOIN wf_layout l ON l.year = r.year AND l.sheet = r._source_sheet),
s AS (
  SELECT x.*,
         CASE WHEN lgu_col IS NULL THEN 'not_published' ELSE wf_cell_status(cells[lgu_col], znd) END       AS lgu_hired_status,
         CASE WHEN doh_col IS NULL THEN 'not_published' ELSE wf_cell_status(cells[doh_col], znd) END       AS doh_hired_status,
         CASE WHEN male_col IS NULL THEN 'not_published' ELSE wf_cell_status(cells[male_col], znd) END     AS male_status,
         CASE WHEN female_col IS NULL THEN 'not_published' ELSE wf_cell_status(cells[female_col], znd) END AS female_status,
         CASE WHEN total_col IS NULL THEN 'not_published' ELSE wf_cell_status(cells[total_col], znd) END   AS total_status
  FROM x)
SELECT s._source_key, s._source_file, s._source_sheet, s._source_row_num, s._as_of_date,
       s.area_key, s.area_label_source, s.geo_level, s.psgc_code, s.parent_area_key, s.city_class,
       s.region_as_published, s.is_superseded_area, s.resolve_method AS area_resolution_method,
       s.override_status AS area_label_override_status,
       s.year, s.profession, lb.source_label,
       CASE WHEN s.lgu_hired_status IN ('ok', 'zero_no_data') THEN CAST(wf_num(s.cells[s.lgu_col]) AS BIGINT) END    AS headcount_lgu_hired,
       CASE WHEN s.doh_hired_status IN ('ok', 'zero_no_data') THEN CAST(wf_num(s.cells[s.doh_col]) AS BIGINT) END    AS headcount_doh_hired,
       CASE WHEN s.male_status IN ('ok', 'zero_no_data') THEN CAST(wf_num(s.cells[s.male_col]) AS BIGINT) END        AS headcount_male,
       CASE WHEN s.female_status IN ('ok', 'zero_no_data') THEN CAST(wf_num(s.cells[s.female_col]) AS BIGINT) END    AS headcount_female,
       CASE WHEN s.total_status IN ('ok', 'zero_no_data') THEN CAST(wf_num(s.cells[s.total_col]) AS BIGINT) END      AS headcount_total,
       s.lgu_hired_status, s.doh_hired_status, s.male_status, s.female_status, s.total_status,
       CASE WHEN s.male_col IS NOT NULL THEN 'sex'
            WHEN s.lgu_col IS NOT NULL AND s.doh_col IS NULL THEN 'employer_lgu_only'
            WHEN s.lgu_col IS NOT NULL THEN 'employer' ELSE 'none' END                                AS split_basis,
       map_from_entries(filter(array(
           named_struct('k', 'headcount_lgu_hired', 'v', s.lgu_col),
           named_struct('k', 'headcount_doh_hired', 'v', s.doh_col),
           named_struct('k', 'headcount_male',      'v', s.male_col),
           named_struct('k', 'headcount_female',    'v', s.female_col),
           named_struct('k', 'headcount_total',     'v', s.total_col)), e -> e.v IS NOT NULL))         AS _metric_source_columns
FROM s
LEFT JOIN wf_source_labels lb ON lb.profession = s.profession AND s.year BETWEEN lb.year_from AND lb.year_to;


-- =============================================================================
-- [4] PSA T9.14: 72 rows x 12 years (plan 5)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW wf_hc_psa AS
SELECT p._source_key, p._source_file, p._source_sheet, p._source_row_num, p._as_of_date,
       coalesce(p.named_area_key, concat('psgc:', p.exc_psgc))                                 AS area_key,
       p.area_label_source,
       CASE WHEN p.named_area_key IS NOT NULL THEN p.named_key_level ELSE 'region' END        AS geo_level,
       p.exc_psgc AS psgc_code,
       CASE WHEN p.named_area_key IS NOT NULL
                 THEN CASE WHEN p.named_key_parent_psgc IS NOT NULL THEN concat('psgc:', p.named_key_parent_psgc) END
            ELSE 'ph' END                                                                      AS parent_area_key,
       CAST(NULL AS STRING) AS city_class,
       CASE WHEN p.match_role = 'region' THEN p.region_label_clean END                        AS region_as_published,
       false AS is_superseded_area, 'exception' AS area_resolution_method,
       CAST(NULL AS STRING) AS area_label_override_status,
       p.year, p.profession, p.source_label,
       CAST(NULL AS BIGINT) AS headcount_lgu_hired, CAST(NULL AS BIGINT) AS headcount_doh_hired,
       CAST(NULL AS BIGINT) AS headcount_male, CAST(NULL AS BIGINT) AS headcount_female,
       CASE WHEN wf_cell_status(p.raw, false) = 'ok' THEN CAST(wf_num(p.raw) AS BIGINT) END   AS headcount_total,
       'not_published' AS lgu_hired_status, 'not_published' AS doh_hired_status,
       'not_published' AS male_status, 'not_published' AS female_status,
       wf_cell_status(p.raw, false) AS total_status,
       'none' AS split_basis,
       map('headcount_total', p.src_col) AS _metric_source_columns
FROM wf_psa_resolved p
JOIN public_health.silver.workforce_headcount_silver__classified c
  ON c._source_key = p._source_key AND c._source_file = p._source_file AND c._source_row_num = p._source_row_num
 AND c.row_class = 'data';


-- =============================================================================
-- [5] candidate: rules, series, review flags, eligibility (staging table)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_headcount_silver__candidate AS
WITH u AS (
  SELECT * FROM wf_hc_fhsis
  UNION ALL
  SELECT * FROM wf_hc_psa),
children AS (   -- rows whose comparison-geography parent is a province, summed per year and profession
  SELECT _source_key, year, profession, parent_area_key,
         sum(CASE WHEN total_status = 'ok' THEN headcount_total END) AS children_total,
         count(*) AS n_children, count_if(total_status = 'ok') AS n_children_ok
  FROM u WHERE geo_level IN ('city', 'municipality')
  GROUP BY _source_key, year, profession, parent_area_key),
f0 AS (
  SELECT u.*, c.children_total, c.n_children, c.n_children_ok
  FROM u
  LEFT JOIN children c
    ON c._source_key = u._source_key AND c.year = u.year AND c.profession = u.profession AND c.parent_area_key = u.area_key),
rule_hit AS (
  SELECT f0._source_key, f0.area_key, f0.year, f0.profession, min(r.rule_id) AS rule_id
  FROM f0
  JOIN wf_eligibility_rules r
    ON  r.source_key = f0._source_key AND (r.year IS NULL OR r.year = f0.year)
    AND (r.area_key IS NULL OR r.area_key = f0.area_key)
    AND (r.profession IS NULL OR r.profession = f0.profession)
    AND f0.total_status = 'ok'
    AND CASE r.condition
          WHEN 'any' THEN true
          WHEN 'total_zero' THEN f0.headcount_total = 0
          WHEN 'province_zero_children_positive'
               THEN f0.geo_level = 'province' AND f0.headcount_total = 0 AND coalesce(f0.children_total, 0) > 0
          WHEN 'total_zero_splits_blank'
               THEN f0.split_basis = 'employer' AND f0.headcount_total = 0
                    AND f0.lgu_hired_status = 'blank' AND f0.doh_hired_status = 'blank'
          WHEN 'total_zero_split_positive'
               THEN f0.headcount_total = 0 AND greatest(coalesce(f0.headcount_lgu_hired, 0), coalesce(f0.headcount_doh_hired, 0),
                                                        coalesce(f0.headcount_male, 0), coalesce(f0.headcount_female, 0)) > 0
          ELSE false END
  GROUP BY f0._source_key, f0.area_key, f0.year, f0.profession),
f AS (
  SELECT f0.*, rh.rule_id AS exclusion_rule,
         CASE WHEN f0.profession = 'nurses' THEN CASE WHEN f0.year < 2019 THEN 'reported_public_health_nurses_to_2018'
                                                      ELSE 'reported_public_health_nurses_from_2019' END
              ELSE concat('reported_public_health_', f0.profession) END                          AS series_definition,
         lag(f0.year) OVER (PARTITION BY f0._source_key, f0.area_key, f0.profession ORDER BY f0.year)            AS prev_year,
         lag(f0.headcount_total) OVER (PARTITION BY f0._source_key, f0.area_key, f0.profession ORDER BY f0.year) AS prev_total,
         lag(f0.total_status) OVER (PARTITION BY f0._source_key, f0.area_key, f0.profession ORDER BY f0.year)    AS prev_status
  FROM f0
  LEFT JOIN rule_hit rh
    ON rh._source_key = f0._source_key AND rh.area_key = f0.area_key AND rh.year = f0.year AND rh.profession = f0.profession),
g AS (
  SELECT f.*,
         (f.profession = 'nurses' AND f.year = 2019)                                         AS is_break_year,
         CASE f.geo_level
              WHEN 'province' THEN CASE WHEN f.year <= 2022 THEN 'province_excl_listed_cities' ELSE 'province_excl_huc_icc' END
              ELSE f.geo_level END                                                          AS geo_coverage_basis,
         CASE f.split_basis
              WHEN 'sex'      THEN f.male_status = 'ok' AND f.female_status = 'ok'
              WHEN 'employer' THEN f.lgu_hired_status = 'ok' AND f.doh_hired_status = 'ok'
              ELSE false END                                                                AS split_complete,
         CASE WHEN f._source_key = 'doh_fhsis_demographic' THEN 1
              WHEN f.year <= 2017 THEN 1 ELSE 2 END                                         AS source_priority,
         CASE WHEN f.total_status = 'zero_no_data'     THEN 'source_zero_means_no_data'
              WHEN f.total_status = 'no_report'        THEN 'no_report'
              WHEN f.total_status = 'not_published'    THEN 'not_published'
              WHEN f.total_status = 'blank'            THEN 'blank_cell'
              WHEN f.total_status = 'marker_undefined' THEN 'marker_undefined'
              WHEN f.total_status = 'parse_error'      THEN 'parse_error'
              WHEN f.area_label_override_status IN ('proposed', 'rejected') THEN 'label_under_review'
              WHEN f.exclusion_rule IS NOT NULL        THEN 'reporting_inconsistency' END   AS exclusion_reason
  FROM f)
SELECT g.area_key, g.area_label_source, g.geo_level, g.psgc_code, g.parent_area_key, g.city_class,
       g.region_as_published, g.geo_coverage_basis, g.is_superseded_area,
       g.area_resolution_method, g.area_label_override_status,
       g.year, g.profession, g.source_label,
       g.headcount_lgu_hired, g.headcount_doh_hired, g.headcount_male, g.headcount_female, g.headcount_total,
       g.lgu_hired_status, g.doh_hired_status, g.male_status, g.female_status, g.total_status,
       g.exclusion_reason IS NULL                                                            AS analysis_eligible,
       g.exclusion_reason,
       g.exclusion_rule,
       CASE g.exclusion_reason
            WHEN 'source_zero_means_no_data' THEN 'No data reported'
            WHEN 'no_report'                 THEN 'No report'
            WHEN 'not_published'             THEN 'Not published'
            WHEN 'blank_cell'                THEN 'No data reported'
            WHEN 'marker_undefined'          THEN 'Excluded: undefined source marker'
            WHEN 'parse_error'               THEN 'Excluded: value not readable'
            WHEN 'label_under_review'        THEN 'Excluded: area label under review'
            WHEN 'reporting_inconsistency'   THEN 'Excluded: reporting inconsistency' END   AS display_label,
       g.split_basis,
       g.split_complete,
       CASE WHEN g.split_complete AND g.total_status = 'ok' THEN
            CASE g.split_basis WHEN 'sex' THEN g.headcount_male + g.headcount_female
                               ELSE g.headcount_lgu_hired + g.headcount_doh_hired END = g.headcount_total
       END                                                                                   AS split_matches_total,
       g.series_definition,
       g.is_break_year,
       CASE WHEN g.is_break_year THEN 'inferred' END                                         AS break_basis,
       g.source_priority,
       CASE WHEN g.source_priority = 1 THEN 'preferred' ELSE 'cross_check' END              AS source_role,
       array_compact(array(
         CASE WHEN g._source_key = 'psa_gov_practitioners' AND g.prev_year = g.year - 1
                   AND g.total_status = 'ok' AND g.prev_status = 'ok' AND g.headcount_total > 0
                   AND g.headcount_total = g.prev_total THEN 'repeated_value' END,
         CASE WHEN g.geo_level = 'province' AND g.prev_year = g.year - 1 AND NOT g.is_break_year
                   AND NOT (g._source_key = 'doh_fhsis_demographic' AND g.year = 2023)   -- coverage change (G1)
                   AND g.total_status = 'ok' AND g.prev_status = 'ok' AND g.prev_total > 0
                   AND abs(g.headcount_total - g.prev_total) > 0.5 * g.prev_total THEN 'large_change' END,
         CASE WHEN g.year = 2025 AND g.geo_level = 'province' AND g.total_status = 'ok' AND g.n_children > 0
                   AND g.n_children = g.n_children_ok AND g.children_total <> g.headcount_total
                   THEN 'province_vs_municipality_sum' END,
         CASE WHEN g.year = 2025 AND g.geo_level IN ('city', 'municipality') AND g.total_status = 'ok'
                   AND g.headcount_total = 0 AND g.profession IN ('doctors', 'nurses', 'midwives')
                   THEN 'zero_reported' END
       ))                                                                                    AS review_flags,
       silver_build_id                                                                       AS _silver_build_id,
       g._source_key, g._source_file, g._source_sheet, g._source_row_num, g._as_of_date,
       g._metric_source_columns
FROM g;


-- =============================================================================
-- [6] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_headcount_silver__gates AS
SELECT 'workforce_silver_01 gates are not all 0: rerun 01' AS gate, count(*) AS failures
  FROM public_health.silver.workforce_fhsis__gates WHERE failures <> 0
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
  SELECT 1 FROM public_health.silver.workforce_headcount_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.workforce_headcount_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.workforce_headcount_silver__inputs
  WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'inputs: declared FHSIS sheet missing from bronze, or a bronze sheet not in the layout', count(*) FROM (
  SELECT l.year FROM (SELECT DISTINCT year, sheet FROM wf_layout) l
  FULL OUTER JOIN (SELECT DISTINCT try_cast(regexp_extract(source_file, '_([0-9]{4})[.]xlsx$', 1) AS INT) AS year,
                          source_sheet AS sheet
                   FROM public_health.silver.workforce_headcount_silver__inputs
                   WHERE input_kind = 'bronze_source' AND source_key = 'doh_fhsis_demographic') i
    ON i.year = l.year AND i.sheet = l.sheet
  WHERE l.sheet IS NULL OR i.sheet IS NULL)
UNION ALL
SELECT 'inputs: PSA T9.14 file missing', CASE WHEN count(*) = 0 THEN 1 ELSE 0 END
  FROM public_health.silver.workforce_headcount_silver__inputs WHERE source_key = 'psa_gov_practitioners'
UNION ALL
SELECT 'unclassified bronze rows (sheet not in layout, area unresolved, PSA label or profession unknown)', count(*)
  FROM public_health.silver.workforce_headcount_silver__classified WHERE row_class NOT IN ('data', 'non_data', 'quarantined')
UNION ALL
SELECT 'bronze row classified more than once', count(*) FROM (
  SELECT 1 FROM public_health.silver.workforce_headcount_silver__classified
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'cell that is neither a number nor a documented marker', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate
  WHERE array_contains(array(lgu_hired_status, doh_hired_status, male_status, female_status, total_status), 'parse_error')
UNION ALL
SELECT 'status not in the accepted list', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate
  WHERE size(array_except(array(lgu_hired_status, doh_hired_status, male_status, female_status, total_status),
             array('ok', 'zero_no_data', 'no_report', 'not_published', 'blank', 'marker_undefined'))) > 0
UNION ALL
SELECT 'a value with a status other than ok / zero_no_data, or ok without a value', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate
  WHERE (headcount_total IS NOT NULL) <> (total_status IN ('ok', 'zero_no_data'))
UNION ALL
SELECT 'negative count', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate
  WHERE least(coalesce(headcount_lgu_hired, 0), coalesce(headcount_doh_hired, 0), coalesce(headcount_male, 0),
              coalesce(headcount_female, 0), coalesce(headcount_total, 0)) < 0
UNION ALL
SELECT 'excluded row without reason or label, or reporting_inconsistency without a named rule', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate
  WHERE (NOT analysis_eligible AND (exclusion_reason IS NULL OR display_label IS NULL))
     OR (analysis_eligible AND total_status <> 'ok')
     OR (exclusion_reason = 'reporting_inconsistency' AND exclusion_rule IS NULL)
UNION ALL
SELECT 'area attributes missing (geo_level)', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate WHERE geo_level IS NULL
UNION ALL
SELECT 'key column is null', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate
  WHERE _source_key IS NULL OR area_key IS NULL OR year IS NULL OR profession IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.workforce_headcount_silver__candidate
  GROUP BY _source_key, area_key, year, profession HAVING count(*) > 1)
UNION ALL
SELECT 'lineage column null (FHSIS rows need _source_sheet)', count(*)
  FROM public_health.silver.workforce_headcount_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_file IS NULL OR _source_row_num IS NULL OR _as_of_date IS NULL
     OR _metric_source_columns IS NULL OR cardinality(_metric_source_columns) = 0
     OR (_source_key = 'doh_fhsis_demographic' AND _source_sheet IS NULL)
UNION ALL
-- output validation, per source
SELECT concat(c.source_key, ': classified rows <> bronze rows read'), abs(c.n - coalesce(i.n, 0))
  FROM (SELECT _source_key AS source_key, count(*) AS n FROM public_health.silver.workforce_headcount_silver__classified GROUP BY _source_key) c
  LEFT JOIN (SELECT source_key, sum(input_rows) AS n FROM public_health.silver.workforce_headcount_silver__inputs
             WHERE input_kind = 'bronze_source' GROUP BY source_key) i ON i.source_key = c.source_key
UNION ALL
SELECT concat(c.source_key, ': silver rows <> data rows x declared professions (FHSIS) or 12 years (PSA)'),
       abs(c.expected_rows - coalesce(s.n, 0))
  FROM (SELECT _source_key AS source_key, sum(CASE WHEN row_class = 'data' THEN measures_per_row ELSE 0 END) AS expected_rows
        FROM public_health.silver.workforce_headcount_silver__classified GROUP BY _source_key) c
  LEFT JOIN (SELECT _source_key AS source_key, count(*) AS n FROM public_health.silver.workforce_headcount_silver__candidate
             GROUP BY _source_key) s ON s.source_key = c.source_key
UNION ALL
SELECT 'a loaded bronze row did not give exactly its declared professions or years', count(*)
  FROM public_health.silver.workforce_headcount_silver__classified c
  LEFT JOIN (SELECT _source_key, _source_file, _source_sheet, _source_row_num, count(*) AS n
             FROM public_health.silver.workforce_headcount_silver__candidate
             GROUP BY _source_key, _source_file, _source_sheet, _source_row_num) s
    ON s._source_key = c._source_key AND s._source_file = c._source_file
   AND s._source_sheet <=> c._source_sheet AND s._source_row_num = c._source_row_num
  WHERE c.row_class = 'data' AND NOT (coalesce(s.n, 0) = c.measures_per_row);


-- =============================================================================
-- [7] build log row (status is 'succeeded' only when every gate is 0); STOP if a gate failed.
--     The failed build is logged first; the published table stays as it was. The staging tables
--     are kept so you can see what failed:
--       SELECT * FROM public_health.silver.workforce_headcount_silver__gates WHERE failures <> 0
-- =============================================================================
CREATE OR REPLACE TEMP VIEW headcount_build_log AS
SELECT silver_build_id                                      AS build_id,
       'silver'                                             AS layer,
       'workforce'                                          AS domain,
       'public_health.silver.workforce_headcount_silver'    AS target_table,
       silver_build_started_at                              AS started_at,
       current_timestamp()                                  AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.workforce_headcount_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                                 AS target_table_version,     -- filled in [9]
       code_version                                         AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'inputs_without_load_log',
                            (SELECT count(*) FROM public_health.silver.workforce_headcount_silver__inputs
                             WHERE input_kind = 'bronze_source' AND metadata_matches = 0))) AS parameters,
       job_run_id                                           AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.workforce_headcount_silver__gates) g;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM headcount_build_log WHERE status = 'failed';

SELECT raise_error(concat('workforce_headcount_silver was NOT published. ', error_message))
FROM headcount_build_log WHERE status = 'failed';


-- =============================================================================
-- [8] write the table (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_headcount_silver AS
SELECT * FROM public_health.silver.workforce_headcount_silver__candidate;


-- =============================================================================
-- [9] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.workforce_headcount_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.workforce_headcount_silver)),
       code_version, parameters, run_id, error_message
FROM headcount_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.workforce_headcount_silver__inputs;

-- Loaded rows are not stored (same as diseases): the silver rows already carry their bronze row
-- reference, and rows loaded per file = build_inputs.input_rows minus these rows
-- (view quality.v_build_reconciliation).
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.workforce_headcount_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num,
       i.load_batch_id, i.content_checksum,
       CASE c.row_class WHEN 'data' THEN 'loaded' WHEN 'non_data' THEN 'dropped_non_data'
                        WHEN 'quarantined' THEN 'quarantined' END,
       c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.workforce_headcount_silver__classified c
LEFT JOIN public_health.silver.workforce_headcount_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [10] summary (compare with section 8.6 of the plan), then remove the staging tables
-- =============================================================================
CREATE OR REPLACE TEMP VIEW headcount_summary AS
SELECT c.source_key, c.bronze_rows, c.data_rows, c.non_data, c.quarantined, s.silver_rows, s.eligible_rows
FROM (SELECT _source_key AS source_key, count(*) AS bronze_rows, count_if(row_class = 'data') AS data_rows,
             count_if(row_class = 'non_data') AS non_data, count_if(row_class = 'quarantined') AS quarantined
      FROM public_health.silver.workforce_headcount_silver__classified GROUP BY _source_key) c
LEFT JOIN (SELECT _source_key AS source_key, count(*) AS silver_rows, count_if(analysis_eligible) AS eligible_rows
           FROM public_health.silver.workforce_headcount_silver GROUP BY _source_key) s ON s.source_key = c.source_key;

DROP TABLE IF EXISTS public_health.silver.workforce_headcount_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.workforce_headcount_silver__gates;
DROP TABLE IF EXISTS public_health.silver.workforce_headcount_silver__inputs;
-- public_health.silver.workforce_headcount_silver__classified is kept until the next run:
-- it shows how every bronze row was classified.

SELECT * FROM headcount_summary ORDER BY source_key;