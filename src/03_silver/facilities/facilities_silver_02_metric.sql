-- =============================================================================
-- Builds public_health.silver.facilities_metric_silver.
-- Grain: one area-year-ownership-source record of facility, bed, or barangay counts.
-- Key: (area_key, year, ownership, _source_key).
--
-- Sources
--   Combines PSA and DOH/FHSIS facility metrics at national, regional, provincial,
--   and city/municipality levels from 1990-2025.
--
-- Source handling
--   Preserves overlapping source records independently; Gold selects preferred
--   records using source_priority.
--   Loads published counts only. Gold computes derived rates and ratios.
--   Converts '*' and '-' to null and records the affected measures in
--   no_report_measures; unexpected non-numeric values fail validation.
--
-- Requires:
--   facilities_silver_00_reference.sql
--   geography silver tables
--   bronze QC for facility metric sources
-- =============================================================================

-- [0] settings
DECLARE OR REPLACE VARIABLE metric_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;
-- PSA hospital definition change (plan 4.4): up to the year before, hospitals include infirmaries.
-- Was typed as 2012 / 2013 until 2026-10-19 (rule 2a). A warn gate checks the break is still
-- visible in the national series; recorded in build_log.parameters.
DECLARE OR REPLACE VARIABLE hospital_definition_break_year INT DEFAULT 2013;
DECLARE OR REPLACE VARIABLE geography_checksum STRING;
SET VARIABLE geography_checksum =
  (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

-- Same helper functions as facilities_silver_01_registry.sql (kept identical in both files)
CREATE OR REPLACE TEMPORARY FUNCTION fac_norm(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(
         translate(upper(replace(replace(replace(replace(s, 'Ã±', 'N'), 'Ã‘', 'N'), 'ñ', 'N'), '?', 'N')), 'ÑÁÉÍÓÚ', 'NAEIOU'),
         '[^A-Z0-9]', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION fac_place(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         regexp_replace(regexp_replace(concat(' ', fac_norm(regexp_replace(s, "['’`-]", '')), ' '),
         ' (HUC|ICC|CC|CAPITAL|NOT A PROVINCE) ', ' '),
         ' STA ', ' SANTA '), ' STO ', ' SANTO '), ' GEN ', ' GENERAL '), ' GOV ', ' GOVERNOR '), ' SEN ', ' SENATOR '),
         '^ (MUNICIPALITY OF|ISLAND GARDEN CITY OF|SCIENCE CITY OF|CITY OF) ', ' '), ' CITY $', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION fac_place_key(s STRING) RETURNS STRING
RETURN replace(fac_place(s), ' ', '');

CREATE OR REPLACE TEMPORARY FUNCTION fac_city_hint(s STRING) RETURNS BOOLEAN
RETURN fac_norm(s) RLIKE '(^CITY OF )|( CITY$)|( CITY )';

CREATE OR REPLACE TEMPORARY FUNCTION fac_num(s STRING) RETURNS DECIMAL(20,4)
RETURN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4));

-- 1 when a cell is neither empty, a number, nor a documented no-report marker
CREATE OR REPLACE TEMPORARY FUNCTION fac_parse_error(s STRING) RETURNS INT
RETURN CASE WHEN s IS NULL OR trim(s) IN ('', '*', '-', '#DIV/0!') THEN 0
            WHEN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4)) IS NOT NULL THEN 0
            ELSE 1 END;

CREATE OR REPLACE TEMPORARY FUNCTION fac_no_report(s STRING) RETURNS BOOLEAN
RETURN trim(s) IN ('*', '-');

CREATE OR REPLACE TEMPORARY FUNCTION fac_region_psgc(s STRING) RETURNS STRING
RETURN CASE
  WHEN fac_norm(s) RLIKE '(^| )(NCR|N C R|NATIONAL CAPITAL|METRO MANILA)( |$)'           THEN '1300000000'
  WHEN fac_norm(s) RLIKE '(^| )(CAR|C A R|CORDILLERA)( |$)'                               THEN '1400000000'
  WHEN fac_norm(s) RLIKE '(^| )(BARMM|ARMM|BANGSAMORO|AUTONOMOUS REGION IN MUSLIM MINDANAO)( |$)' THEN '1900000000'
  WHEN fac_norm(s) RLIKE '(^| )(NIR|NEGROS ISLAND)( |$)'                                  THEN '1800000000'
  WHEN fac_norm(s) RLIKE '(^| )(MIMAROPA|IV B|4 B|4B|IVB)( |$)'                           THEN '1700000000'
  WHEN fac_norm(s) RLIKE '(^| )(CARAGA|XIII|13)( |$)'                                     THEN '1600000000'
  WHEN fac_norm(s) RLIKE '(^| )(CALABARZON|IV A|4 A|4A|IVA)( |$)'                         THEN '0400000000'
  -- region names without a number (FHSIS 2019-2020: ILOCOS, CAGAYAN VALLEY, ...)
  WHEN fac_norm(s) RLIKE '^ILOCOS( REGION)?$'          THEN '0100000000'
  WHEN fac_norm(s) RLIKE '^CAGAYAN VALLEY( REGION)?$'  THEN '0200000000'
  WHEN fac_norm(s) RLIKE '^CENTRAL LUZON( REGION)?$'   THEN '0300000000'
  WHEN fac_norm(s) RLIKE '^BICOL( REGION)?$'           THEN '0500000000'
  WHEN fac_norm(s) RLIKE '^WESTERN VISAYAS( REGION)?$' THEN '0600000000'
  WHEN fac_norm(s) RLIKE '^CENTRAL VISAYAS( REGION)?$' THEN '0700000000'
  WHEN fac_norm(s) RLIKE '^EASTERN VISAYAS( REGION)?$' THEN '0800000000'
  WHEN fac_norm(s) RLIKE '^ZAMBOANGA PENINSULA( REGION)?$' THEN '0900000000'
  WHEN fac_norm(s) RLIKE '^NORTHERN MINDANAO( REGION)?$'   THEN '1000000000'
  WHEN fac_norm(s) RLIKE '^DAVAO( REGION)?$'           THEN '1100000000'
  WHEN fac_norm(s) RLIKE '^SOCCSKSARGEN( REGION)?$'    THEN '1200000000'
  ELSE CASE regexp_extract(fac_norm(s), '^REGION ([IVX]+|[0-9]+)( |$)', 1)
         WHEN 'I' THEN '0100000000' WHEN '1' THEN '0100000000' WHEN 'II' THEN '0200000000' WHEN '2' THEN '0200000000'
         WHEN 'III' THEN '0300000000' WHEN '3' THEN '0300000000' WHEN 'V' THEN '0500000000' WHEN '5' THEN '0500000000'
         WHEN 'VI' THEN '0600000000' WHEN '6' THEN '0600000000' WHEN 'VII' THEN '0700000000' WHEN '7' THEN '0700000000'
         WHEN 'VIII' THEN '0800000000' WHEN '8' THEN '0800000000' WHEN 'IX' THEN '0900000000' WHEN '9' THEN '0900000000'
         WHEN 'X' THEN '1000000000' WHEN '10' THEN '1000000000' WHEN 'XI' THEN '1100000000' WHEN '11' THEN '1100000000'
         WHEN 'XII' THEN '1200000000' WHEN '12' THEN '1200000000' END
  END;

-- Year at the end of a file name: ..._2024.xlsx -> 2024
CREATE OR REPLACE TEMPORARY FUNCTION fac_file_year(f STRING) RETURNS INT
RETURN try_cast(regexp_extract(f, '_([0-9]{4})[.][A-Za-z]+$', 1) AS INT);

CREATE OR REPLACE TEMP VIEW fac_geo AS
SELECT psgc_code, area_name,
       CASE geographic_level WHEN 'Reg' THEN 'region' WHEN 'Prov' THEN 'province' WHEN 'City' THEN 'city'
            WHEN 'Mun' THEN 'municipality' WHEN 'SubMun' THEN 'submunicipality' WHEN 'Bgy' THEN 'barangay' END AS geo_level,
       city_class, fac_place_key(area_name) AS place_norm,
       concat(substr(psgc_code, 1, 2), '00000000') AS region_psgc
FROM public_health.silver.geography_silver
WHERE content_checksum = geography_checksum;

-- Hospital counts before and after the definition change (plan 4.4; break year = setting in [0])
CREATE OR REPLACE TEMPORARY FUNCTION fac_hosp_series(y INT, break_year INT) RETURNS STRING
RETURN CASE WHEN y < break_year THEN 'hospitals_incl_infirmaries' ELSE 'general_and_specialty_hospitals' END;


-- =============================================================================
-- [1] classify every bronze row
--   measures_per_row = silver rows one data row must produce (the unpivot rule, used in [6])
-- =============================================================================

-- PSA 9.18 hospitals and 9.17 beds, 2020-2024: 18 rows each, all data (national row + 17 regions)
CREATE OR REPLACE TEMP VIEW cls_psa_region_wide AS
SELECT 'public_health.bronze.facilities_psa_hospitals_region_annual_bronze' AS input_table,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       Region AS label,
       CASE WHEN Region IS NULL THEN 'non_data' ELSE 'data' END AS row_class,
       CASE WHEN Region IS NULL THEN 'blank_label' END AS reason, 15 AS measures_per_row
FROM public_health.bronze.facilities_psa_hospitals_region_annual_bronze WHERE _source_key = 'psa_hospitals_region_annual'
UNION ALL
SELECT 'public_health.bronze.facilities_psa_beds_region_annual_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       Regions, CASE WHEN Regions IS NULL THEN 'non_data' ELSE 'data' END,
       CASE WHEN Regions IS NULL THEN 'blank_label' END, 15
FROM public_health.bronze.facilities_psa_beds_region_annual_bronze WHERE _source_key = 'psa_beds_region_annual';

-- PSA OpenSTAT national hospitals and PSA 9.16 national hospitals + beds: a row is data when
-- its year cell is a 4-digit year; footnotes (a/ ... e/) and the source line are not.
CREATE OR REPLACE TEMP VIEW cls_psa_national AS
SELECT 'public_health.bronze.facilities_psa_hospitals_national_annual_bronze' AS input_table,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       Year AS label,
       CASE WHEN trim(Year) RLIKE '^[0-9]{4}$' THEN 'data' ELSE 'non_data' END AS row_class,
       CASE WHEN NOT trim(Year) RLIKE '^[0-9]{4}$' THEN 'footnote_or_source' END AS reason, 3 AS measures_per_row
FROM public_health.bronze.facilities_psa_hospitals_national_annual_bronze WHERE _source_key = 'psa_hospitals_national_annual'
UNION ALL
SELECT 'public_health.bronze.facilities_psa_hospitals_beds_national_annual_bronze',
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       year, CASE WHEN trim(year) RLIKE '^[0-9]{4}$' THEN 'data' ELSE 'non_data' END,
       CASE WHEN NOT trim(year) RLIKE '^[0-9]{4}$' THEN 'footnote_or_source' END, 3
FROM public_health.bronze.facilities_psa_hospitals_beds_national_annual_bronze WHERE _source_key = 'psa_hospitals_beds_national_annual';

-- PSA 9.17 legacy (2005-2015): year blocks. A year row ('2005 ', '2013 a') opens a block;
-- the Total / Government / Private rows under it are data. The year is carried down.
CREATE OR REPLACE TEMP VIEW cls_psa_legacy AS
WITH r AS (
  SELECT t.*,
         try_cast(regexp_extract(trim(col_0), '^([0-9]{4})( a)?$', 1) AS INT) AS year_marker,
         (trim(col_0) RLIKE '^[0-9]{4} a$') AS year_footnote_a
  FROM public_health.bronze.facilities_psa_hospitals_region_annual_legacy_bronze t
  WHERE _source_key = 'psa_hospitals_region_annual_legacy'
)
SELECT 'public_health.bronze.facilities_psa_hospitals_region_annual_legacy_bronze' AS input_table, r.*,
       last_value(year_marker, true) OVER (PARTITION BY _source_file ORDER BY _source_row_num
                                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS block_year,
       last_value(CASE WHEN year_marker IS NOT NULL THEN year_footnote_a END, true) OVER (
         PARTITION BY _source_file ORDER BY _source_row_num ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS block_footnote_a,
       CASE WHEN trim(col_0) IN ('Total', 'Government', 'Private') THEN 'data' ELSE 'non_data' END AS row_class,
       CASE WHEN trim(col_0) IN ('Total', 'Government', 'Private') THEN NULL
            WHEN year_marker IS NOT NULL THEN 'year_header'
            WHEN _source_row_num <= 3 THEN 'title_or_header'
            WHEN upper(trim(col_0)) LIKE 'SOURCE%' THEN 'source_line'
            ELSE 'footnote' END AS reason,
       18 AS measures_per_row
FROM r;

-- PSA 9.19 BHS (2006-2023): a row is data when its year cell is a 4-digit year
CREATE OR REPLACE TEMP VIEW cls_psa_bhs AS
SELECT 'public_health.bronze.facilities_psa_bhs_region_annual_bronze' AS input_table, t.*,
       CASE WHEN trim(year) RLIKE '^[0-9]{4}$' THEN 'data' ELSE 'non_data' END AS row_class,
       CASE WHEN NOT trim(year) RLIKE '^[0-9]{4}$' THEN 'source_line' END AS reason,
       18 AS measures_per_row
FROM public_health.bronze.facilities_psa_bhs_region_annual_bronze t WHERE _source_key = 'psa_bhs_region_annual';

-- FHSIS BGY & BHS (2018-2025): data = a labelled row with at least one number or '*';
-- notes and legends (label, no values) and blank rows are not data.
CREATE OR REPLACE TEMP VIEW cls_fhsis AS
SELECT 'public_health.bronze.facilities_fhsis_primary_care_bronze' AS input_table, t.*,
       fac_file_year(_source_file) AS file_year,
       CASE WHEN area_name IS NOT NULL
                 AND coalesce(fac_num(population), fac_num(barangays_no), fac_num(bhs_no), fac_num(rhu_no),
                              fac_num(mhc_no), fac_num(chc_no), fac_num(health_centers_total)) IS NOT NULL
                 OR (area_name IS NOT NULL AND (fac_no_report(bhs_no) OR fac_no_report(barangays_no))) THEN 'data'
            WHEN area_name IS NOT NULL THEN 'non_data'
            WHEN coalesce(fac_num(population), fac_num(barangays_no), fac_num(bhs_no)) IS NULL THEN 'non_data'
            ELSE 'unclassified' END AS row_class,
       CASE WHEN area_name IS NOT NULL AND NOT (coalesce(fac_num(population), fac_num(barangays_no), fac_num(bhs_no),
                 fac_num(rhu_no), fac_num(mhc_no), fac_num(chc_no), fac_num(health_centers_total)) IS NOT NULL
                 OR fac_no_report(bhs_no) OR fac_no_report(barangays_no)) THEN 'note_or_legend'
            WHEN area_name IS NULL THEN 'blank_label' END AS reason,
       1 AS measures_per_row
FROM public_health.bronze.facilities_fhsis_primary_care_bronze t WHERE _source_key = 'doh_fhsis_demographic';

CREATE OR REPLACE TABLE public_health.silver.facilities_metric_silver__classified AS
SELECT input_table, _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, measures_per_row FROM cls_psa_region_wide
UNION ALL
SELECT input_table, _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, measures_per_row FROM cls_psa_national
UNION ALL
SELECT input_table, _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, measures_per_row FROM cls_psa_legacy
UNION ALL
SELECT input_table, _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, measures_per_row FROM cls_psa_bhs
UNION ALL
SELECT input_table, _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       row_class, reason, measures_per_row FROM cls_fhsis;


-- =============================================================================
-- [2] inputs
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_metric_declared_inputs AS
SELECT * FROM VALUES
  ('psa_hospitals_region_annual', 1), ('psa_beds_region_annual', 1), ('psa_hospitals_national_annual', 1),
  ('psa_hospitals_beds_national_annual', 1), ('psa_hospitals_region_annual_legacy', 1),
  ('psa_bhs_region_annual', 1), ('doh_fhsis_demographic', 8)
  AS t(source_key, expected_files);

-- Delta versions of the tables read. DESCRIBE HISTORY cannot be used in a subquery in
-- Databricks SQL, so table versions are recorded as NULL (same fallback as
-- facilities_silver_01_registry.sql section [2]).
CREATE OR REPLACE TEMP VIEW fac_metric_table_versions AS
SELECT 'public_health.bronze.facilities_psa_hospitals_region_annual_bronze' AS table_name,
       CAST(NULL AS BIGINT) AS table_version
UNION ALL SELECT 'public_health.bronze.facilities_psa_beds_region_annual_bronze',
       CAST(NULL AS BIGINT)
UNION ALL SELECT 'public_health.bronze.facilities_psa_hospitals_national_annual_bronze',
       CAST(NULL AS BIGINT)
UNION ALL SELECT 'public_health.bronze.facilities_psa_hospitals_beds_national_annual_bronze',
       CAST(NULL AS BIGINT)
UNION ALL SELECT 'public_health.bronze.facilities_psa_hospitals_region_annual_legacy_bronze',
       CAST(NULL AS BIGINT)
UNION ALL SELECT 'public_health.bronze.facilities_psa_bhs_region_annual_bronze',
       CAST(NULL AS BIGINT)
UNION ALL SELECT 'public_health.bronze.facilities_fhsis_primary_care_bronze',
       CAST(NULL AS BIGINT)
UNION ALL SELECT 'public_health.silver.geography_silver',
       CAST(NULL AS BIGINT)
UNION ALL SELECT 'public_health.silver.facilities_area_exceptions',
       CAST(NULL AS BIGINT);

CREATE OR REPLACE TABLE public_health.silver.facilities_metric_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.facilities_metric_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT metric_build_id AS build_id, 'public_health.silver.facilities_metric_silver' AS target_table,
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
LEFT JOIN fac_metric_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
SELECT metric_build_id, 'public_health.silver.facilities_metric_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CASE WHEN t.table_name LIKE '%geography_silver' THEN geography_checksum END,
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.geography_silver' AS table_name, count(*) AS n FROM fac_geo
      UNION ALL SELECT 'public_health.silver.facilities_area_exceptions', count(*) FROM public_health.silver.facilities_area_exceptions) t
LEFT JOIN fac_metric_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] FHSIS areas: the national row, region rows (region rule), and the
--     province / city rows under each region (name + level + parent region). A province row
--     excludes the cities listed under it (plan 4.3).
--     Exceptions: source_group 'fhsis', match_type 'area_label', match_value = normalised
--     label, parent_label_norm = the parent REGION's PSGC code, optional year range.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_metric_silver__fhsis_geo AS
WITH r AS (
  SELECT c._source_key, c._source_file, c._source_sheet, c._source_row_num, c.file_year, c.area_name,
         fac_norm(c.area_name) AS label_norm, fac_place_key(c.area_name) AS place_key,
         fac_city_hint(c.area_name) AS city_hint,
         -- a region row: a region label that is not also a province name and does not say "city"
         -- ('CARAGA' is also a municipality and 'DAVAO' the place name of Davao City: still regions)
         CASE WHEN fac_norm(c.area_name) = 'PHILIPPINES' THEN 'national'
              WHEN fac_region_psgc(c.area_name) IS NOT NULL AND NOT fac_city_hint(c.area_name)
                   AND NOT EXISTS (SELECT 1 FROM fac_geo g WHERE g.geo_level = 'province'
                                     AND g.place_norm = fac_place_key(c.area_name)) THEN 'region'
              ELSE 'child' END AS row_kind
  FROM cls_fhsis c WHERE c.row_class = 'data'
),
rr AS (
  SELECT r.*,
         CASE WHEN row_kind = 'region' THEN fac_region_psgc(area_name) END AS own_region,
         last_value(CASE WHEN row_kind = 'region' THEN fac_region_psgc(area_name) END, true) OVER (
           PARTITION BY _source_file ORDER BY _source_row_num ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS parent_region,
         last_value(CASE WHEN row_kind = 'region' THEN trim(area_name) END, true) OVER (
           PARTITION BY _source_file ORDER BY _source_row_num ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS region_label
  FROM r
),
cand AS (
  SELECT rr._source_file, rr._source_row_num, g.psgc_code,
         CASE WHEN rr.city_hint AND g.geo_level = 'city' THEN 2
              WHEN NOT rr.city_hint AND g.geo_level = 'province' THEN 2
              WHEN NOT rr.city_hint AND g.geo_level IN ('city', 'municipality') THEN 1
              ELSE 0 END AS score
  FROM rr JOIN fac_geo g
    ON rr.row_kind = 'child' AND g.region_psgc = rr.parent_region AND g.place_norm = rr.place_key
   AND g.geo_level IN ('province', 'city', 'municipality')
   AND (NOT rr.city_hint OR g.geo_level = 'city')   -- a label that says city must be a city
),
-- No candidate in the published region: try the regions that took over part of it (Negros
-- Island Region 18 from VI and VII in 2024; BARMM 19 from XII), then the whole country.
-- A match there must still be unique.
related AS (
  SELECT * FROM VALUES ('0600000000', '1800000000'), ('0700000000', '1800000000'), ('1200000000', '1900000000'),
                       ('0900000000', '1900000000') AS t(published_region, successor_region)
),
cand_rel AS (
  SELECT rr._source_file, rr._source_row_num, g.psgc_code,
         CASE WHEN rr.city_hint AND g.geo_level = 'city' THEN 2
              WHEN NOT rr.city_hint AND g.geo_level = 'province' THEN 2
              WHEN NOT rr.city_hint AND g.geo_level IN ('city', 'municipality') THEN 1 ELSE 0 END AS score
  FROM rr
  JOIN related x ON x.published_region = rr.parent_region
  JOIN fac_geo g ON rr.row_kind = 'child' AND g.region_psgc = x.successor_region AND g.place_norm = rr.place_key
   AND g.geo_level IN ('province', 'city', 'municipality')
   AND (NOT rr.city_hint OR g.geo_level = 'city')   -- a label that says city must be a city
  WHERE NOT EXISTS (SELECT 1 FROM cand c WHERE c._source_file = rr._source_file AND c._source_row_num = rr._source_row_num)
),
cand_any AS (
  SELECT rr._source_file, rr._source_row_num, g.psgc_code,
         CASE WHEN rr.city_hint AND g.geo_level = 'city' THEN 2
              WHEN NOT rr.city_hint AND g.geo_level = 'province' THEN 2
              WHEN NOT rr.city_hint AND g.geo_level IN ('city', 'municipality') THEN 1 ELSE 0 END AS score
  FROM rr
  JOIN fac_geo g ON rr.row_kind = 'child' AND g.place_norm = rr.place_key
   AND g.geo_level IN ('province', 'city', 'municipality')
   AND (NOT rr.city_hint OR g.geo_level = 'city')   -- a label that says city must be a city
  WHERE NOT EXISTS (SELECT 1 FROM cand c WHERE c._source_file = rr._source_file AND c._source_row_num = rr._source_row_num)
    AND NOT EXISTS (SELECT 1 FROM cand_rel c WHERE c._source_file = rr._source_file AND c._source_row_num = rr._source_row_num)
),
cand_all AS (
  SELECT *, 'name_level_parent' AS method FROM cand
  UNION ALL SELECT *, 'name_level_successor_region' FROM cand_rel
  UNION ALL SELECT *, 'name_level_other_region' FROM cand_any
),
best AS (
  SELECT _source_file, _source_row_num, count_if(score = max_s) AS n_best, max_by(psgc_code, score) AS best_psgc,
         max(method) AS method, array_join(array_sort(collect_list(psgc_code)), ',') AS candidates
  FROM (SELECT *, max(score) OVER (PARTITION BY _source_file, _source_row_num) AS max_s FROM cand_all)
  GROUP BY _source_file, _source_row_num
),
exc AS (SELECT * FROM public_health.silver.facilities_area_exceptions WHERE source_group = 'fhsis' AND match_type = 'area_label'),
-- labels whose exception row is not usable (needs_review / rejected, loaded as 'unresolvable' by
-- facilities_silver_00_reference.sql): the row is quarantined, never matched by its name
unres AS (SELECT * FROM public_health.silver.facilities_area_exceptions WHERE source_group = 'fhsis' AND match_type = 'unresolvable')
SELECT rr._source_key, rr._source_file, rr._source_sheet, rr._source_row_num, rr.row_kind, rr.region_label,
       CASE WHEN u.match_value IS NOT NULL THEN NULL
            WHEN rr.row_kind = 'national' THEN 'ph'
            WHEN rr.row_kind = 'region' THEN concat('psgc:', rr.own_region)
            WHEN coalesce(e.psgc_code, e.area_key) IS NOT NULL THEN coalesce(concat('psgc:', e.psgc_code), e.area_key)
            WHEN b.n_best = 1 THEN concat('psgc:', b.best_psgc) END AS area_key,
       CASE WHEN rr.row_kind = 'region' THEN rr.own_region
            WHEN rr.row_kind = 'child' THEN coalesce(e.psgc_code, CASE WHEN e.area_key IS NULL AND b.n_best = 1 THEN b.best_psgc END) END AS psgc_code,
       CASE WHEN rr.row_kind = 'national' THEN 'national_row'
            WHEN rr.row_kind = 'region' THEN 'region_rule'
            WHEN coalesce(e.psgc_code, e.area_key) IS NOT NULL THEN 'exception'
            WHEN b.n_best = 1 THEN b.method END AS geo_resolution_method,
       b.candidates AS geo_candidates,
       e.reason AS geo_exception_reason,
       CASE WHEN u.match_value IS NOT NULL THEN concat('place_', 'needs_review') END AS quarantine_reason
FROM rr
LEFT JOIN best b ON b._source_file = rr._source_file AND b._source_row_num = rr._source_row_num
LEFT JOIN exc e
  ON rr.row_kind = 'child' AND e.match_value = rr.label_norm
 AND (e.parent_label_norm IS NULL OR e.parent_label_norm = rr.parent_region)
 AND (e.year_from IS NULL OR rr.file_year >= CAST(e.year_from AS INT))
 AND (e.year_to IS NULL OR rr.file_year <= CAST(e.year_to AS INT))
LEFT JOIN unres u
  ON rr.row_kind = 'child' AND u.match_value = rr.label_norm
 AND (u.parent_label_norm IS NULL OR u.parent_label_norm = rr.parent_region)
 AND (u.year_from IS NULL OR rr.file_year >= CAST(u.year_from AS INT))
 AND (u.year_to IS NULL OR rr.file_year <= CAST(u.year_to AS INT));


-- =============================================================================
-- [4] one view per source, same columns in the same order. raw_* are the published cells;
--     [5] turns them into numbers. parse_errors counts cells that are not numbers or markers.
-- =============================================================================

-- [4a] PSA 9.18 hospitals and 9.17 beds: 15 columns (Total / Government / Private x 2020-2024)
CREATE OR REPLACE TEMP VIEW part_psa_region_wide
  (area_key, psgc_code, geo_name_source, geo_resolution_method, region_as_published, year, ownership,
   raw_hospitals, raw_authorized_beds, raw_bhs, raw_rhu, raw_mhc, raw_chc, raw_health_centers_total,
   raw_barangays, raw_population, series_definition, is_break_year, geo_coverage_basis,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns) AS
WITH b AS (
  SELECT 'hospitals' AS measure, Region AS label, Total_2020 AS t20, Total_2021 AS t21, Total_2022 AS t22, Total_2023 AS t23, Total_2024 AS t24,
         Government_2020 AS g20, Government_2021 AS g21, Government_2022 AS g22, Government_2023 AS g23, Government_2024 AS g24,
         Private_2020 AS p20, Private_2021 AS p21, Private_2022 AS p22, Private_2023 AS p23, Private_2024 AS p24,
         _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date
  FROM public_health.bronze.facilities_psa_hospitals_region_annual_bronze WHERE _source_key = 'psa_hospitals_region_annual' AND Region IS NOT NULL
  UNION ALL
  SELECT 'authorized_beds', Regions, Total_2020, Total_2021, Total_2022, Total_2023, Total_2024,
         Government_2020, Government_2021, Government_2022, Government_2023, Government_2024,
         Private_2020, Private_2021, Private_2022, Private_2023, Private_2024,
         _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date
  FROM public_health.bronze.facilities_psa_beds_region_annual_bronze WHERE _source_key = 'psa_beds_region_annual' AND Regions IS NOT NULL
),
u AS (
  SELECT b.*, stack(15,
     'total', 2020, t20, 'Total_2020', 'total', 2021, t21, 'Total_2021', 'total', 2022, t22, 'Total_2022',
     'total', 2023, t23, 'Total_2023', 'total', 2024, t24, 'Total_2024',
     'government', 2020, g20, 'Government_2020', 'government', 2021, g21, 'Government_2021', 'government', 2022, g22, 'Government_2022',
     'government', 2023, g23, 'Government_2023', 'government', 2024, g24, 'Government_2024',
     'private', 2020, p20, 'Private_2020', 'private', 2021, p21, 'Private_2021', 'private', 2022, p22, 'Private_2022',
     'private', 2023, p23, 'Private_2023', 'private', 2024, p24, 'Private_2024') AS (ownership, year, raw, src_col)
  FROM b
)
SELECT -- 9.17 labels its national BED row "Total Number of Hospitals" (source error, plan / YAML note)
       CASE WHEN label LIKE 'Total Number of Hospitals%' THEN 'ph' ELSE concat('psgc:', fac_region_psgc(label)) END AS area_key,
       CASE WHEN label LIKE 'Total Number of Hospitals%' THEN NULL ELSE fac_region_psgc(label) END AS psgc_code,
       trim(label) AS geo_name_source,
       CASE WHEN label LIKE 'Total Number of Hospitals%' THEN 'national_row' ELSE 'region_rule' END AS geo_resolution_method,
       CASE WHEN label LIKE 'Total Number of Hospitals%' THEN NULL ELSE trim(label) END AS region_as_published,
       year, ownership,
       CASE WHEN measure = 'hospitals' THEN raw END AS raw_hospitals,
       CASE WHEN measure = 'authorized_beds' THEN raw END AS raw_authorized_beds,
       CAST(NULL AS STRING) AS raw_bhs, CAST(NULL AS STRING) AS raw_rhu, CAST(NULL AS STRING) AS raw_mhc,
       CAST(NULL AS STRING) AS raw_chc, CAST(NULL AS STRING) AS raw_health_centers_total,
       CAST(NULL AS STRING) AS raw_barangays, CAST(NULL AS STRING) AS raw_population,
       CASE WHEN measure = 'hospitals' THEN fac_hosp_series(year, hospital_definition_break_year) END AS series_definition,
       false AS is_break_year,
       'regions_17_old_definition' AS region_definition,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map(measure, src_col) AS _metric_source_columns
FROM u;

-- [4b] PSA OpenSTAT national hospitals and PSA 9.16 national hospitals + beds
CREATE OR REPLACE TEMP VIEW part_psa_national
  (area_key, psgc_code, geo_name_source, geo_resolution_method, region_as_published, year, ownership,
   raw_hospitals, raw_authorized_beds, raw_bhs, raw_rhu, raw_mhc, raw_chc, raw_health_centers_total,
   raw_barangays, raw_population, series_definition, is_break_year, geo_coverage_basis,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns) AS
WITH b AS (
  SELECT CAST(trim(Year) AS INT) AS y, Total AS h_t, Government AS h_g, Private AS h_p,
         CAST(NULL AS STRING) AS b_t, CAST(NULL AS STRING) AS b_g, CAST(NULL AS STRING) AS b_p,
         'Total' AS hc_t, 'Government' AS hc_g, 'Private' AS hc_p, CAST(NULL AS STRING) AS bc_t, CAST(NULL AS STRING) AS bc_g, CAST(NULL AS STRING) AS bc_p,
         _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date
  FROM public_health.bronze.facilities_psa_hospitals_national_annual_bronze
  WHERE _source_key = 'psa_hospitals_national_annual' AND trim(Year) RLIKE '^[0-9]{4}$'
  UNION ALL
  SELECT CAST(trim(year) AS INT), hospitals_total, hospitals_government, hospitals_private,
         beds_total, beds_government, beds_private,
         'hospitals_total', 'hospitals_government', 'hospitals_private', 'beds_total', 'beds_government', 'beds_private',
         _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date
  FROM public_health.bronze.facilities_psa_hospitals_beds_national_annual_bronze
  WHERE _source_key = 'psa_hospitals_beds_national_annual' AND trim(year) RLIKE '^[0-9]{4}$'
),
u AS (
  SELECT b.*, stack(3, 'total', h_t, b_t, hc_t, bc_t, 'government', h_g, b_g, hc_g, bc_g, 'private', h_p, b_p, hc_p, bc_p)
         AS (ownership, raw_h, raw_b, col_h, col_b)
  FROM b
)
SELECT 'ph', CAST(NULL AS STRING), 'Philippines', 'national_row', CAST(NULL AS STRING),
       y, ownership, raw_h, raw_b,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS STRING), CAST(NULL AS STRING),
       fac_hosp_series(y, hospital_definition_break_year), (y = hospital_definition_break_year), 'national',
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       CASE WHEN col_b IS NULL THEN map('hospitals', col_h) ELSE map('hospitals', col_h, 'authorized_beds', col_b) END
FROM u;

-- [4c] PSA 9.17 legacy: one data row = one ownership in one year, 18 areas (Philippines + 17 regions).
--      The column labelled BARMM holds ARMM for these years.
CREATE OR REPLACE TEMP VIEW part_psa_legacy
  (area_key, psgc_code, geo_name_source, geo_resolution_method, region_as_published, year, ownership,
   raw_hospitals, raw_authorized_beds, raw_bhs, raw_rhu, raw_mhc, raw_chc, raw_health_centers_total,
   raw_barangays, raw_population, series_definition, is_break_year, geo_coverage_basis,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns) AS
WITH u AS (
  SELECT c.*, stack(18,
     'Philippines', col_1, 'col_1', 'NCR', col_3, 'col_3', 'CAR', col_4, 'col_4', 'Region I', col_5, 'col_5',
     'Region II', col_6, 'col_6', 'Region III', col_7, 'col_7', 'Region IV-A', col_8, 'col_8', 'MIMAROPA', col_9, 'col_9',
     'Region V', col_10, 'col_10', 'Region VI', col_11, 'col_11', 'Region VII', col_12, 'col_12',
     'Region VIII', col_13, 'col_13', 'Region IX', col_14, 'col_14', 'Region X', col_15, 'col_15',
     'Region XI', col_16, 'col_16', 'Region XII', col_17, 'col_17', 'Caraga', col_18, 'col_18', 'ARMM', col_19, 'col_19'
  ) AS (area_label, raw, src_col)
  FROM cls_psa_legacy c WHERE c.row_class = 'data'
)
SELECT CASE WHEN area_label = 'Philippines' THEN 'ph' ELSE concat('psgc:', fac_region_psgc(area_label)) END,
       CASE WHEN area_label = 'Philippines' THEN NULL ELSE fac_region_psgc(area_label) END,
       area_label,
       CASE WHEN area_label = 'Philippines' THEN 'national_row' ELSE 'column_position' END,
       CASE WHEN area_label = 'Philippines' THEN NULL ELSE area_label END,
       block_year, lower(trim(col_0)), raw, CAST(NULL AS STRING),
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS STRING), CAST(NULL AS STRING),
       fac_hosp_series(block_year, hospital_definition_break_year), (block_year = hospital_definition_break_year),
       CASE WHEN area_label = 'Philippines' THEN 'national' ELSE 'regions_17_old_definition' END,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('hospitals', src_col)
FROM u;

-- [4d] PSA 9.19 BHS: one data row = one year, 18 areas
CREATE OR REPLACE TEMP VIEW part_psa_bhs
  (area_key, psgc_code, geo_name_source, geo_resolution_method, region_as_published, year, ownership,
   raw_hospitals, raw_authorized_beds, raw_bhs, raw_rhu, raw_mhc, raw_chc, raw_health_centers_total,
   raw_barangays, raw_population, series_definition, is_break_year, geo_coverage_basis,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns) AS
WITH u AS (
  SELECT c.*, stack(18,
     'Philippines', philippines, 'philippines', 'NCR', ncr, 'ncr', 'CAR', car, 'car', 'Region I', region_01, 'region_01',
     'Region II', region_02, 'region_02', 'Region III', region_03, 'region_03', 'Region IV-A', region_04a, 'region_04a',
     'MIMAROPA', mimaropa, 'mimaropa', 'Region V', region_05, 'region_05', 'Region VI', region_06, 'region_06',
     'Region VII', region_07, 'region_07', 'Region VIII', region_08, 'region_08', 'Region IX', region_09, 'region_09',
     'Region X', region_10, 'region_10', 'Region XI', region_11, 'region_11', 'Region XII', region_12, 'region_12',
     'Caraga', caraga, 'caraga', 'BARMM', barmm, 'barmm'
  ) AS (area_label, raw, src_col)
  FROM cls_psa_bhs c WHERE c.row_class = 'data'
)
SELECT CASE WHEN area_label = 'Philippines' THEN 'ph' ELSE concat('psgc:', fac_region_psgc(area_label)) END,
       CASE WHEN area_label = 'Philippines' THEN NULL ELSE fac_region_psgc(area_label) END,
       area_label,
       CASE WHEN area_label = 'Philippines' THEN 'national_row' ELSE 'column_position' END,
       CASE WHEN area_label = 'Philippines' THEN NULL
            -- BARMM replaced ARMM in 2019 (RA 11054): a fixed fact of geography history, not a setting
            WHEN area_label = 'BARMM' AND CAST(trim(year) AS INT) < 2019 THEN 'ARMM' ELSE area_label END,
       CAST(trim(year) AS INT), 'total',
       CAST(NULL AS STRING), CAST(NULL AS STRING), raw,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS STRING), false,
       CASE WHEN area_label = 'Philippines' THEN 'national' ELSE 'regions_17_old_definition' END,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('bhs', src_col)
FROM u;

-- [4e] FHSIS BGY & BHS. Columns change by year:
--   2018       barangays, BHS
--   2019-2024  barangays, MHC, CHC, RHU, health centres total, BHS
--   2025       barangays, "RHU" (= all health centres, decision D4), BHS
CREATE OR REPLACE TEMP VIEW part_fhsis
  (area_key, psgc_code, geo_name_source, geo_resolution_method, region_as_published, year, ownership,
   raw_hospitals, raw_authorized_beds, raw_bhs, raw_rhu, raw_mhc, raw_chc, raw_health_centers_total,
   raw_barangays, raw_population, series_definition, is_break_year, geo_coverage_basis,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns) AS
SELECT g.area_key, g.psgc_code, trim(c.area_name),
       g.geo_resolution_method,
       g.region_label,
       c.file_year, 'total',
       CAST(NULL AS STRING), CAST(NULL AS STRING), c.bhs_no,
       CASE WHEN c.file_year BETWEEN 2019 AND 2024 THEN c.rhu_no END,
       c.mhc_no, c.chc_no,
       CASE WHEN c.file_year = 2025 THEN c.rhu_no ELSE c.health_centers_total END,
       c.barangays_no, c.population,
       CAST(NULL AS STRING), false,
       CASE WHEN g.row_kind = 'national' THEN 'national' WHEN g.row_kind = 'region' THEN 'region_as_reported'
            ELSE 'province_excl_listed_cities_or_city' END,
       c._source_key, c._source_file, c._source_sheet, c._source_row_num, c._as_of_date,
       map_filter(map(
         'bhs', 'bhs_no', 'barangays', 'barangays_no', 'population', 'population',
         'rhu', CASE WHEN c.file_year BETWEEN 2019 AND 2024 THEN 'rhu_no' END,
         'mhc', CASE WHEN c.file_year BETWEEN 2019 AND 2024 THEN 'mhc_no' END,
         'chc', CASE WHEN c.file_year BETWEEN 2019 AND 2024 THEN 'chc_no' END,
         'health_centers_total', CASE WHEN c.file_year = 2025 THEN 'rhu_no'
                                      WHEN c.file_year BETWEEN 2019 AND 2024 THEN 'health_centers_total' END),
         (k, v) -> v IS NOT NULL)
FROM cls_fhsis c
JOIN public_health.silver.facilities_metric_silver__fhsis_geo g
  ON g._source_file = c._source_file AND g._source_sheet <=> c._source_sheet AND g._source_row_num = c._source_row_num
WHERE c.row_class = 'data' AND g.quarantine_reason IS NULL;


-- =============================================================================
-- [5] candidate rows
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_metric_parts
  (area_key, psgc_code, geo_name_source, geo_resolution_method, region_as_published, year, ownership,
   raw_hospitals, raw_authorized_beds, raw_bhs, raw_rhu, raw_mhc, raw_chc, raw_health_centers_total,
   raw_barangays, raw_population, series_definition, is_break_year, geo_coverage_basis,
   _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns) AS
SELECT * FROM part_psa_region_wide
UNION ALL SELECT * FROM part_psa_national
UNION ALL SELECT * FROM part_psa_legacy
UNION ALL SELECT * FROM part_psa_bhs
UNION ALL SELECT * FROM part_fhsis;

CREATE OR REPLACE TABLE public_health.silver.facilities_metric_silver__candidate AS
SELECT area_key, psgc_code, geo_name_source, geo_resolution_method,
       -- rule of the exceptions row that placed it (e.g. duplicate_in_file: a row printed under another name)
       geo_exception_reason,
       region_as_published, geo_coverage_basis,
       year, ownership,
       CAST(fac_num(raw_hospitals) AS INT)            AS hospitals,
       CAST(fac_num(raw_authorized_beds) AS INT)      AS authorized_beds,
       CAST(fac_num(raw_bhs) AS INT)                  AS bhs,
       CAST(fac_num(raw_rhu) AS INT)                  AS rhu,
       CAST(fac_num(raw_mhc) AS INT)                  AS mhc,
       CAST(fac_num(raw_chc) AS INT)                  AS chc,
       CAST(fac_num(raw_health_centers_total) AS INT) AS health_centers_total,
       CAST(fac_num(raw_barangays) AS INT)            AS barangays,
       CAST(round(fac_num(raw_population)) AS BIGINT) AS population,   -- some FHSIS years carry decimals
       filter(array(
         CASE WHEN fac_no_report(raw_hospitals) THEN 'hospitals' END,
         CASE WHEN fac_no_report(raw_authorized_beds) THEN 'authorized_beds' END,
         CASE WHEN fac_no_report(raw_bhs) THEN 'bhs' END, CASE WHEN fac_no_report(raw_rhu) THEN 'rhu' END,
         CASE WHEN fac_no_report(raw_mhc) THEN 'mhc' END, CASE WHEN fac_no_report(raw_chc) THEN 'chc' END,
         CASE WHEN fac_no_report(raw_health_centers_total) THEN 'health_centers_total' END,
         CASE WHEN fac_no_report(raw_barangays) THEN 'barangays' END,
         CASE WHEN fac_no_report(raw_population) THEN 'population' END), x -> x IS NOT NULL) AS no_report_measures,
       series_definition, is_break_year,
       metric_build_id AS _silver_build_id,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns,
       -- validation only, not published
       fac_parse_error(raw_hospitals) + fac_parse_error(raw_authorized_beds) + fac_parse_error(raw_bhs)
       + fac_parse_error(raw_rhu) + fac_parse_error(raw_mhc) + fac_parse_error(raw_chc)
       + fac_parse_error(raw_health_centers_total) + fac_parse_error(raw_barangays)
       + fac_parse_error(raw_population) AS parse_errors
FROM fac_metric_parts p
LEFT JOIN (SELECT _source_file AS g_file, _source_row_num AS g_row, geo_exception_reason
           FROM public_health.silver.facilities_metric_silver__fhsis_geo) g
  ON p._source_key = 'doh_fhsis_demographic' AND g.g_file = p._source_file AND g.g_row = p._source_row_num;


-- =============================================================================
-- [5b] dispositions: one row per bronze row that was
--      NOT loaded. Loaded rows are not stored: the silver rows carry their bronze row reference, and
--      rows loaded per input = input_rows - rows here (quality.v_build_reconciliation).
--      Not loaded: non-data rows (titles, footnotes, spacers, year headers), and FHSIS rows whose
--      place label is not verified (quarantined; see build_facilities_area_exceptions.py).
--      Saved before the gates, so the gates check exactly what step [10] writes.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_metric_silver__dispositions AS
SELECT metric_build_id AS build_id, 'public_health.silver.facilities_metric_silver' AS target_table,
       c._source_key AS source_key, c._source_file AS source_file, c._source_sheet AS source_sheet,
       c._source_row_num AS source_row_num, i.load_batch_id, i.content_checksum,
       'dropped_non_data' AS disposition, c.reason, CAST(NULL AS STRING) AS target_key,
       current_timestamp() AS recorded_at
FROM public_health.silver.facilities_metric_silver__classified c
LEFT JOIN public_health.silver.facilities_metric_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data'
UNION ALL
-- FHSIS rows whose place label is not verified (exceptions file, review_status not usable)
SELECT metric_build_id, 'public_health.silver.facilities_metric_silver',
       g._source_key, g._source_file, g._source_sheet, g._source_row_num, i.load_batch_id, i.content_checksum,
       'quarantined', g.quarantine_reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.facilities_metric_silver__fhsis_geo g
LEFT JOIN public_health.silver.facilities_metric_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = g._source_key AND i.source_file = g._source_file
 AND i.source_sheet <=> g._source_sheet
WHERE g.quarantine_reason IS NOT NULL;


-- =============================================================================
-- [6] gates. severity 'fail' stops the build; 'warn' is reported in the summary only.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_metric_silver__gates AS
SELECT 'inputs: declared source missing or with a different number of files' AS gate, 'fail' AS severity, count(*) AS failures
  FROM fac_metric_declared_inputs d
  LEFT JOIN (SELECT source_key, count(*) AS n FROM public_health.silver.facilities_metric_silver__inputs
             WHERE input_kind = 'bronze_source' GROUP BY source_key) i ON i.source_key = d.source_key
  WHERE coalesce(i.n, 0) <> d.expected_files
UNION ALL
SELECT 'inputs: file or sheet with more than one load time', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_metric_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__inputs
  WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'unclassified bronze rows', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__classified WHERE row_class NOT IN ('data', 'non_data')
UNION ALL
SELECT 'bronze row classified more than once', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_metric_silver__classified
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'PSA 9.17 legacy: region header row is not NCR ... BARMM in columns 3 to 19', 'fail',
       CASE WHEN EXISTS (SELECT 1 FROM public_health.bronze.facilities_psa_hospitals_region_annual_legacy_bronze
                         WHERE _source_key = 'psa_hospitals_region_annual_legacy'
                           AND trim(col_3) = 'NCR' AND trim(col_4) = 'CAR' AND trim(col_5) = 'I' AND trim(col_8) = 'IV-A'
                           AND trim(col_9) = 'MIMAROPA' AND trim(col_17) = 'XII' AND trim(col_18) = 'Caraga'
                           AND trim(col_19) = 'BARMM') THEN 0 ELSE 1 END
UNION ALL
SELECT 'PSA 9.17 legacy: data row without a year above it', 'fail', count(*)
  FROM cls_psa_legacy WHERE row_class = 'data' AND block_year IS NULL
UNION ALL
SELECT 'PSA 9.19 BHS: header row is not Year / Philippines / Region', 'fail', 0   -- checked by bronze header_check
UNION ALL
-- rule 2a (2026-10-19): [4a] unpivots exactly 15 columns (Total / Government / Private x 2020-2024).
-- A newer PSA file with another year column would load to bronze and be silently ignored here.
SELECT 'PSA 9.18 / 9.17: year columns in bronze are not the 15 that [4a] unpivots (2020-2024)', 'fail',
       (SELECT coalesce(max(size(filter(json_object_keys(to_json(struct(*), map('ignoreNullFields', 'false'))),
                                         k -> k RLIKE '^(Total|Government|Private)_[0-9]{4}$'
                                              AND NOT k RLIKE '_(2020|2021|2022|2023|2024)$'))), 0)
        FROM public_health.bronze.facilities_psa_hospitals_region_annual_bronze WHERE _source_key = 'psa_hospitals_region_annual')
     + (SELECT coalesce(max(size(filter(json_object_keys(to_json(struct(*), map('ignoreNullFields', 'false'))),
                                         k -> k RLIKE '^(Total|Government|Private)_[0-9]{4}$'
                                              AND NOT k RLIKE '_(2020|2021|2022|2023|2024)$'))), 0)
        FROM public_health.bronze.facilities_psa_beds_region_annual_bronze WHERE _source_key = 'psa_beds_region_annual')
UNION ALL
-- rule 2a (2026-10-19): [4e] knows the column layouts of the 2018, 2019-2024 and 2025 FHSIS files
-- (sources_facilities.yaml bgy_* layouts). A file of another year would get no rhu / health centre values.
SELECT 'FHSIS: data row from a file year without a known column layout (2018-2025)', 'fail', count(*)
  FROM cls_fhsis WHERE row_class = 'data' AND (file_year IS NULL OR file_year NOT BETWEEN 2018 AND 2025)
UNION ALL
SELECT 'region label not recognised', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__candidate WHERE area_key IS NULL OR area_key = 'psgc:'
UNION ALL
SELECT 'FHSIS: area not resolved (add an area exception with the parent region code)', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__fhsis_geo WHERE area_key IS NULL AND quarantine_reason IS NULL
UNION ALL
SELECT 'area code not in geography', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__candidate c
  WHERE c.psgc_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fac_geo g WHERE g.psgc_code = c.psgc_code)
UNION ALL
SELECT 'cell that is neither a number nor a documented marker', 'fail', coalesce(sum(parse_errors), 0)
  FROM public_health.silver.facilities_metric_silver__candidate
UNION ALL
SELECT 'negative count', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__candidate
  WHERE least(hospitals, authorized_beds, bhs, rhu, mhc, chc, health_centers_total, barangays, population) < 0
UNION ALL
SELECT 'key column null', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__candidate
  WHERE area_key IS NULL OR year IS NULL OR ownership IS NULL OR _source_key IS NULL
UNION ALL
SELECT 'key not unique', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_metric_silver__candidate
  GROUP BY area_key, year, ownership, _source_key HAVING count(*) > 1)
UNION ALL
SELECT 'lineage: a lineage column is null (only _source_sheet may be)', 'fail', count(*)
  FROM public_health.silver.facilities_metric_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _source_row_num IS NULL
     OR _as_of_date IS NULL OR _metric_source_columns IS NULL OR size(_metric_source_columns) = 0
UNION ALL
-- contract 7.1, per input: distinct bronze rows referenced by silver = rows read - rows not loaded
SELECT 'reconciliation: inputs where rows referenced by silver <> rows read - rows not loaded', 'fail', count(*)
FROM public_health.silver.facilities_metric_silver__inputs i
LEFT JOIN (
  SELECT _source_key, _source_file, _source_sheet, count(*) AS n FROM (
    SELECT DISTINCT _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.silver.facilities_metric_silver__candidate)
  GROUP BY _source_key, _source_file, _source_sheet) ref
  ON ref._source_key = i.source_key AND ref._source_file = i.source_file AND ref._source_sheet <=> i.source_sheet
LEFT JOIN (
  SELECT source_key, source_file, source_sheet, count(*) AS n
  FROM public_health.silver.facilities_metric_silver__dispositions GROUP BY source_key, source_file, source_sheet) nl
  ON nl.source_key = i.source_key AND nl.source_file = i.source_file AND nl.source_sheet <=> i.source_sheet
WHERE i.input_kind = 'bronze_source' AND i.input_rows - coalesce(nl.n, 0) <> coalesce(ref.n, 0)
UNION ALL
-- output validation per source
SELECT concat(c.source_key, ': silver rows <> data rows x measures per row'), 'fail',
       abs(c.expected_rows - coalesce(s.silver_rows, 0))
  FROM (SELECT c._source_key AS source_key, sum(CASE WHEN c.row_class = 'data' AND q._source_row_num IS NULL THEN c.measures_per_row ELSE 0 END) AS expected_rows
        FROM public_health.silver.facilities_metric_silver__classified c
        LEFT JOIN (SELECT _source_file, _source_row_num FROM public_health.silver.facilities_metric_silver__fhsis_geo
                   WHERE quarantine_reason IS NOT NULL) q
          ON q._source_file = c._source_file AND q._source_row_num = c._source_row_num
        GROUP BY c._source_key) c
  LEFT JOIN (SELECT _source_key AS source_key, count(*) AS silver_rows
             FROM public_health.silver.facilities_metric_silver__candidate GROUP BY _source_key) s ON s.source_key = c.source_key
UNION ALL
SELECT concat(c.source_key, ': bronze rows referenced by silver lineage <> data rows'), 'fail',
       abs(c.data_rows - coalesce(s.referenced, 0))
  FROM (SELECT c._source_key AS source_key, count_if(c.row_class = 'data' AND q._source_row_num IS NULL) AS data_rows
        FROM public_health.silver.facilities_metric_silver__classified c
        LEFT JOIN (SELECT _source_file, _source_row_num FROM public_health.silver.facilities_metric_silver__fhsis_geo
                   WHERE quarantine_reason IS NOT NULL) q
          ON q._source_file = c._source_file AND q._source_row_num = c._source_row_num
        GROUP BY c._source_key) c
  LEFT JOIN (SELECT _source_key AS source_key, count(*) AS referenced
             FROM (SELECT DISTINCT _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.silver.facilities_metric_silver__candidate)
             GROUP BY _source_key) s ON s.source_key = c.source_key
UNION ALL
-- control values (the same numbers bronze QC uses: sources_facilities.yaml qc.control_values of each
-- source, checked against the published tables). SQL cannot read the YAML: a new file changes both.
SELECT concat('control: ', t.label), 'fail', CASE WHEN a.v = t.expected THEN 0 ELSE 1 END
FROM (SELECT * FROM VALUES
  ('PSA 9.18 hospitals 2024 = 1,312', 'psa_hospitals_region_annual', 2024, 'hospitals', 1312),
  ('PSA 9.18 hospitals 2020 = 1,283', 'psa_hospitals_region_annual', 2020, 'hospitals', 1283),
  ('PSA 9.17 beds 2024 = 114,623', 'psa_beds_region_annual', 2024, 'authorized_beds', 114623),
  ('PSA 9.17 beds 2020 = 110,136', 'psa_beds_region_annual', 2020, 'authorized_beds', 110136),
  ('OpenSTAT hospitals 2006 = 1,921', 'psa_hospitals_national_annual', 2006, 'hospitals', 1921),
  ('PSA 9.16 beds 1990 = 87,133', 'psa_hospitals_beds_national_annual', 1990, 'authorized_beds', 87133),
  ('PSA 9.16 beds 2014 = 98,429', 'psa_hospitals_beds_national_annual', 2014, 'authorized_beds', 98429),
  ('PSA 9.17 legacy hospitals 2005 = 1,838', 'psa_hospitals_region_annual_legacy', 2005, 'hospitals', 1838),
  ('PSA 9.19 BHS 2023 = 24,327', 'psa_bhs_region_annual', 2023, 'bhs', 24327),
  ('FHSIS BHS 2018 = 21,546', 'doh_fhsis_demographic', 2018, 'bhs', 21546),
  ('FHSIS BHS 2024 = 25,532', 'doh_fhsis_demographic', 2024, 'bhs', 25532),
  ('FHSIS BHS 2025 = 26,944', 'doh_fhsis_demographic', 2025, 'bhs', 26944),
  ('FHSIS barangays 2024 = 41,590', 'doh_fhsis_demographic', 2024, 'barangays', 41590)
  AS v(label, k, y, measure, expected)) t
LEFT JOIN (SELECT _source_key, year, measure, v
           FROM (SELECT _source_key, year, stack(4, 'hospitals', CAST(hospitals AS BIGINT), 'authorized_beds', CAST(authorized_beds AS BIGINT),
                                                    'bhs', CAST(bhs AS BIGINT), 'barangays', CAST(barangays AS BIGINT)) AS (measure, v)
                 FROM public_health.silver.facilities_metric_silver__candidate
                 WHERE area_key = 'ph' AND ownership = 'total')) a
  ON a._source_key = t.k AND a.year = t.y AND a.measure = t.measure
UNION ALL
-- rule 2a (2026-10-19): the hospital definition break is still where the setting says
-- (national hospitals fall at hospital_definition_break_year: 1,825 to 1,454 in 2012-2013, OpenSTAT file)
SELECT 'warn: national hospital count does not fall at hospital_definition_break_year (check the setting)', 'warn',
       CASE WHEN (SELECT max(CASE WHEN year = hospital_definition_break_year THEN hospitals END)
                       < 0.9 * max(CASE WHEN year = hospital_definition_break_year - 1 THEN hospitals END)
                  FROM public_health.silver.facilities_metric_silver__candidate
                  WHERE _source_key = 'psa_hospitals_national_annual' AND area_key = 'ph' AND ownership = 'total')
            THEN 0 ELSE 1 END
UNION ALL
-- consistency (reported, not blocking): a region equals its provinces plus its listed cities
SELECT 'warn: FHSIS region BHS <> sum of the rows listed under it (region-years)', 'warn', count(*) FROM (
  SELECT r.year, r.area_key FROM public_health.silver.facilities_metric_silver__candidate r
  JOIN public_health.silver.facilities_metric_silver__fhsis_geo g
    ON g._source_file = r._source_file AND g._source_row_num = r._source_row_num AND g.row_kind = 'region'
  JOIN (SELECT c.year, g2.region_label, c._source_file, sum(c.bhs) AS child_bhs
        FROM public_health.silver.facilities_metric_silver__candidate c
        JOIN public_health.silver.facilities_metric_silver__fhsis_geo g2
          ON g2._source_file = c._source_file AND g2._source_row_num = c._source_row_num AND g2.row_kind = 'child'
        GROUP BY c.year, g2.region_label, c._source_file) ch
    ON ch._source_file = r._source_file AND ch.region_label = r.geo_name_source
  WHERE r._source_key = 'doh_fhsis_demographic' AND NOT (r.bhs <=> ch.child_bhs))
UNION ALL
SELECT 'warn: PSA 9.18 / 9.17 regions do not add up to the national row (area-years)', 'warn', count(*) FROM (
  SELECT c._source_key, c.year, c.ownership
  FROM public_health.silver.facilities_metric_silver__candidate c
  WHERE c._source_key IN ('psa_hospitals_region_annual', 'psa_beds_region_annual')
  GROUP BY c._source_key, c.year, c.ownership
  HAVING sum(CASE WHEN area_key <> 'ph' THEN coalesce(hospitals, authorized_beds) END)
         <> sum(CASE WHEN area_key = 'ph' THEN coalesce(hospitals, authorized_beds) END));


-- =============================================================================
-- [7] build log row
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_metric_build_log AS
SELECT metric_build_id AS build_id, 'silver' AS layer, 'facilities' AS domain,
       'public_health.silver.facilities_metric_silver' AS target_table,
       silver_build_started_at AS started_at, current_timestamp() AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.facilities_metric_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT) AS target_table_version, code_version AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup, 'geography_checksum', geography_checksum,
                            'hospital_definition_break_year', hospital_definition_break_year,
                            'warnings', g.warn_names)) AS parameters,
       job_run_id AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0 AND severity = 'fail') AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'fail' THEN concat(gate, ' = ', failures) END)) AS failed_names,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'warn' THEN concat(gate, ' = ', failures) END)) AS warn_names
      FROM public_health.silver.facilities_metric_silver__gates) g;

-- [8] stop if a gate failed (the failed build is logged first)
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM fac_metric_build_log WHERE status = 'failed';

SELECT raise_error(concat('facilities_metric_silver was NOT published. ', error_message))
FROM fac_metric_build_log WHERE status = 'failed';


-- =============================================================================
-- [9] write (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_metric_silver AS
SELECT * EXCEPT (parse_errors) FROM public_health.silver.facilities_metric_silver__candidate;


-- =============================================================================
-- [10] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.facilities_metric_silver),
       CAST(NULL AS BIGINT),
       code_version, parameters, run_id, error_message
FROM fac_metric_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.facilities_metric_silver__inputs;

-- bronze rows not loaded (staged in [5b]); loaded rows are not written
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
       content_checksum, disposition, reason, target_key, recorded_at
FROM public_health.silver.facilities_metric_silver__dispositions;


-- =============================================================================
-- [11] summary and warnings; drop staging tables (__classified kept until the next run)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_metric_summary AS
SELECT _source_key, min(year) AS year_from, max(year) AS year_to, count(*) AS silver_rows,
       count(DISTINCT area_key) AS areas, sum(size(no_report_measures)) AS no_report_cells
FROM public_health.silver.facilities_metric_silver GROUP BY _source_key;

CREATE OR REPLACE TEMP VIEW fac_metric_warnings AS
SELECT gate, failures FROM public_health.silver.facilities_metric_silver__gates WHERE severity = 'warn';

SELECT * FROM fac_metric_warnings;

DROP TABLE IF EXISTS public_health.silver.facilities_metric_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.facilities_metric_silver__gates;
DROP TABLE IF EXISTS public_health.silver.facilities_metric_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.facilities_metric_silver__fhsis_geo;
DROP TABLE IF EXISTS public_health.silver.facilities_metric_silver__dispositions;

SELECT * FROM fac_metric_summary ORDER BY _source_key;
