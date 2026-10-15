-- =============================================================================
-- Builds two Silver facility registry tables in one validated build:
--
--   public_health.silver.facilities_id_map_silver
--     Grain: one source facility identifier.
--     Key: (_source_key, source_record_id).
--
--   public_health.silver.facilities_registry_silver
--     Grain: one facility establishment.
--     Key: facility_key.
--
-- Inputs
--   Uses NHFR hospitals as the registry spine and matches four HFSRB licensed lists:
--   hospitals, infirmaries, primary care facilities, and free-standing dialysis clinics.
--   Also uses geography_silver, facilities reference tables, and previous target versions
--   to preserve facility_key and history across rebuilds.
--
-- Facility matching
--   Resolves geography, applies duplicate-code rules, matches records by facility code
--   or name, applies reviewed overrides, and reuses existing facility_key values when
--   available. Assigns a new facility_key only when no prior identity exists.
--
-- Write strategy
--   Builds and validates the complete new state of both tables before replacing them.
--   If validation fails, logs the failed build and leaves both target tables unchanged.
--
-- Requires:
--   facilities_silver_00_reference.sql
--   geography silver tables
--   quality_setup.sql
--   bronze QC for all five facility registry sources
--
-- Changes 2026-10-15
--   A previous facility is carried forward as 'not_listed' only while the id map still holds
--   one of its source records. When its records now belong to another facility (identity moved
--   between builds, e.g. an HFSRB record that now joins an NHFR facility), or it has no id map
--   row at all, it is recorded in public_health.silver.facilities_registry_silver__moved and not
--   carried. This stopped the gate 'registry: every registry key is in the id map' failing
--   while keeping every other facility_key stable. Counts go to build_log.parameters
--   (moved_facilities, dropped_without_id_map). __moved is kept after the run for review.
-- =============================================================================

-- [0] build ids and settings
DECLARE OR REPLACE VARIABLE registry_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE idmap_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
-- true: every input needs exactly one processed ingestion_metadata row (contract 3.5)
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job
-- geography snapshot: the latest one in geography silver (psgc_code is unique per snapshot)
DECLARE OR REPLACE VARIABLE geography_checksum STRING;
SET VARIABLE geography_checksum =
  (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

-- Text normalization: upper case; N-tilde (also the broken 'Ã±' and NHFR's '?') becomes N;
-- anything that is not A-Z or 0-9 becomes a space; single spaces.
CREATE OR REPLACE TEMPORARY FUNCTION fac_norm(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(
         translate(upper(replace(replace(replace(replace(s, 'Ã±', 'N'), 'Ã‘', 'N'), 'ñ', 'N'), '?', 'N')), 'ÑÁÉÍÓÚ', 'NAEIOU'),
         '[^A-Z0-9]', ' '), ' +', ' '));

-- Place name for matching: 'CITY OF LAS PIÑAS (HUC)' and 'Las Piñas City' -> 'LAS PINAS';
-- 'Sto. Tomas' and 'Santo Tomas' -> 'SANTO TOMAS'; 'Municipality of Glan' -> 'GLAN';
-- 'Island Garden City of Samal' and 'Samal City' -> 'SAMAL'. Applied to both sides.
-- Apostrophes and hyphens are dropped first ('M'Lang' = 'Mlang', 'Jala-Jala' = 'Jalajala'), and
-- fac_place_key compares without spaces ('Mataas na Kahoy' = 'Mataasnakahoy').
CREATE OR REPLACE TEMPORARY FUNCTION fac_place(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         regexp_replace(regexp_replace(concat(' ', fac_norm(regexp_replace(s, "['’`-]", '')), ' '),
         ' (HUC|ICC|CC|CAPITAL|NOT A PROVINCE) ', ' '),
         ' STA ', ' SANTA '), ' STO ', ' SANTO '), ' GEN ', ' GENERAL '), ' GOV ', ' GOVERNOR '), ' SEN ', ' SENATOR '),
         '^ (MUNICIPALITY OF|ISLAND GARDEN CITY OF|SCIENCE CITY OF|CITY OF) ', ' '), ' CITY $', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION fac_place_key(s STRING) RETURNS STRING
RETURN replace(fac_place(s), ' ', '');

-- True when a label says it is a city
CREATE OR REPLACE TEMPORARY FUNCTION fac_city_hint(s STRING) RETURNS BOOLEAN
RETURN fac_norm(s) RLIKE '(^CITY OF )|( CITY$)|( CITY )';

-- Facility name for matching: normalised, common abbreviations expanded, legal suffixes dropped
CREATE OR REPLACE TEMPORARY FUNCTION fac_fname(s STRING) RETURNS STRING
RETURN trim(regexp_replace(
  regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    concat(' ', fac_norm(s), ' '),
    ' HOSP ', ' HOSPITAL '), ' MED ', ' MEDICAL '), ' (CTR|CNTR) ', ' CENTER '), ' GEN ', ' GENERAL '),
    ' MEM ', ' MEMORIAL '), ' STO ', ' SANTO '), ' (INC|CORP|CORPORATION|CO) ', ' '),
  ' +', ' '));

-- Distinctive words of a facility name (generic words removed), for comparing two names
CREATE OR REPLACE TEMPORARY FUNCTION fac_name_tokens(s STRING) RETURNS ARRAY<STRING>
RETURN array_distinct(filter(split(fac_fname(s), ' '), t -> length(t) > 1 AND NOT array_contains(array(
  'HOSPITAL', 'MEDICAL', 'CENTER', 'GENERAL', 'DISTRICT', 'PROVINCIAL', 'MEMORIAL', 'REGIONAL', 'CITY', 'OF', 'THE',
  'AND', 'DE', 'DEL', 'NG', 'SA', 'MATERNITY', 'CLINIC', 'INFIRMARY', 'HEALTH', 'CARE', 'DOCTORS', 'DR', 'ST',
  'SANTO', 'SAN', 'OPC', 'COMMUNITY', 'MUNICIPAL', 'HOSPITALS', 'SPECIALTY', 'FOUNDATION'), t)));

-- Share of distinctive words two names have in common (0 to 1; null if either has none)
CREATE OR REPLACE TEMPORARY FUNCTION fac_name_similarity(a STRING, b STRING) RETURNS DOUBLE
RETURN CASE WHEN size(fac_name_tokens(a)) = 0 OR size(fac_name_tokens(b)) = 0 THEN NULL
            ELSE size(array_intersect(fac_name_tokens(a), fac_name_tokens(b)))
                 / least(size(fac_name_tokens(a)), size(fac_name_tokens(b))) END;

-- LGU of a city / municipality / sub-municipality code: a Manila district (1380601000 Tondo)
-- belongs to its city (1380600000). Codes of other levels are returned unchanged.
CREATE OR REPLACE TEMPORARY FUNCTION fac_lgu(code STRING) RETURNS STRING
RETURN CASE WHEN code RLIKE '^13806[0-9]{2}000$' THEN '1380600000' ELSE code END;

-- Text to number: spaces and thousands separators removed; null when not a number
CREATE OR REPLACE TEMPORARY FUNCTION fac_num(s STRING) RETURNS DECIMAL(20,4)
RETURN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4));

-- NHFR id from any of the formats seen: 3880, 03880, 3880.0, DOH000000000003880, DOH03880.
-- Compared as a number, never as a padded string (plan 2.2). Null for anything else.
CREATE OR REPLACE TEMPORARY FUNCTION fac_nhfr_id(s STRING) RETURNS BIGINT
RETURN CASE WHEN trim(s) RLIKE '^(DOH|doh)?[0-9]{1,15}([.]0)?$'
            THEN try_cast(regexp_extract(trim(s), '([0-9]{1,15})', 1) AS BIGINT) END;

-- Date from ISO text (2026-12-31T00:00:00) or MM/dd/yyyy
CREATE OR REPLACE TEMPORARY FUNCTION fac_date(s STRING) RETURNS DATE
RETURN coalesce(to_date(try_to_timestamp(trim(s))), to_date(try_to_timestamp(trim(s), 'MM/dd/yyyy')),
                to_date(try_to_timestamp(trim(s), 'M/d/yyyy')));

-- Region code from any region label seen in the facilities sources (NCR, CORDILLERA, NIR,
-- REGION 4-A, Region IV-A  CALABARZON, REGION XII (SOCCSKSARGEN), ARMM, N C R, ...).
-- Null when the label is not recognised (fails a gate). ARMM maps to BARMM (19).
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

-- Geography reference: one snapshot; level names, place name for matching, parents.
-- province_psgc is null for highly urbanized cities (they have no province).
CREATE OR REPLACE TEMP VIEW fac_geo AS
SELECT psgc_code, area_name,
       CASE geographic_level WHEN 'Reg' THEN 'region' WHEN 'Prov' THEN 'province' WHEN 'City' THEN 'city'
            WHEN 'Mun' THEN 'municipality' WHEN 'SubMun' THEN 'submunicipality' WHEN 'Bgy' THEN 'barangay' END AS geo_level,
       city_class,
       fac_place_key(area_name) AS place_norm,
       concat(substr(psgc_code, 1, 2), '00000000') AS region_psgc,
       CASE WHEN geographic_level IN ('City', 'Mun') AND coalesce(city_class, '') <> 'HUC'
            THEN concat(substr(psgc_code, 1, 5), '00000') END AS province_psgc
FROM public_health.silver.geography_silver
WHERE content_checksum = geography_checksum;

-- Target tables must exist before the first build (the build reads their previous version).
CREATE TABLE IF NOT EXISTS public_health.silver.facilities_id_map_silver (
  _source_key STRING, source_record_id STRING, source_id_raw STRING, source_id_norm BIGINT,
  code_validated BOOLEAN, facility_key STRING, match_method STRING, match_status STRING,
  _first_build_id STRING, _silver_build_id STRING, _source_file STRING, _source_sheet STRING,
  _source_row_num INT, _as_of_date DATE);

CREATE TABLE IF NOT EXISTS public_health.silver.facilities_registry_silver (
  facility_key STRING, facility_category STRING, facility_name STRING, nhfr_id BIGINT, license_no STRING,
  ownership STRING, ownership_class STRING, service_level STRING,
  area_key STRING, psgc_code STRING, barangay_psgc STRING, geo_name_source STRING, geo_resolution_method STRING,
  geo_conflict_nhfr_hfsrb BOOLEAN,
  nhfr_reported_beds INT, hfsrb_abc INT, authorized_beds INT, analysis_beds INT, analysis_beds_basis STRING,
  dialysis_stations INT, has_blood_service BOOLEAN, blood_service_type STRING,
  nhfr_licensing_status STRING, license_valid_until DATE, is_license_valid_on_as_of BOOLEAN,
  in_nhfr BOOLEAN, in_hfsrb BOOLEAN, match_method STRING,
  is_currently_listed_nhfr BOOLEAN, is_currently_listed_hfsrb BOOLEAN, facility_status STRING,
  _row_hash STRING, _first_build_id STRING, _business_change_build_id STRING, _delisted_build_id STRING,
  _silver_build_id STRING,
  _nhfr_source_key STRING, _nhfr_source_file STRING, _nhfr_source_row_num INT, _nhfr_as_of_date DATE,
  _hfsrb_source_key STRING, _hfsrb_source_file STRING, _hfsrb_source_sheet STRING, _hfsrb_source_row_num INT,
  _hfsrb_as_of_date DATE,
  _metric_source_columns MAP<STRING, STRING>);


-- =============================================================================
-- [1] classify and parse every bronze row of the five sources
--     row_class: data / non_data. Identity decisions (duplicate, quarantined) come in [4].
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_nhfr_rows AS
SELECT 'public_health.bronze.facilities_nhfr_bronze' AS input_table,
       _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       'hospital' AS facility_category,
       Health_Facility_Code AS source_id_raw,
       CASE WHEN trim(Health_Facility_Code) RLIKE '^DOH[0-9]{15}$'
            THEN CAST(substr(trim(Health_Facility_Code), 4) AS BIGINT) END AS nhfr_id,
       trim(Facility_Name) AS facility_name,
       Region_Name AS region_label, Province_Name AS province_label, `City/Municipality_Name` AS city_label,
       `City/Municipality_PSGC` AS city_code_raw, Barangay_PSGC AS barangay_code_raw,
       initcap(trim(Ownership_Major_Classification)) AS ownership,
       trim(coalesce(`Ownership_Sub-Classification_for_Government_facilities`,
                     `Ownership_Sub-Classification_for_private_facilities`)) AS ownership_class,
       trim(Service_Capability) AS service_level,
       CAST(fac_num(Bed_Capacity) AS INT) AS nhfr_reported_beds,
       CAST(NULL AS INT) AS hfsrb_abc, CAST(NULL AS INT) AS dialysis_stations, CAST(NULL AS STRING) AS blood_service_type,
       trim(regexp_replace(Licensing_Status, '<[^>]*>|Licensing Status:', '')) AS nhfr_licensing_status,
       CAST(NULL AS DATE) AS license_valid_until, CAST(NULL AS STRING) AS license_no,
       map('facility_name', 'Facility_Name', 'nhfr_reported_beds', 'Bed_Capacity', 'service_level', 'Service_Capability',
           'nhfr_licensing_status', 'Licensing_Status', 'ownership', 'Ownership_Major_Classification') AS value_columns,
       CASE WHEN Health_Facility_Code IS NULL AND Facility_Name IS NULL THEN 'non_data' ELSE 'data' END AS row_class,
       CASE WHEN Health_Facility_Code IS NULL AND Facility_Name IS NULL THEN 'blank_row' END AS reason
FROM public_health.bronze.facilities_nhfr_bronze
WHERE _source_key = 'doh_nhfr';

CREATE OR REPLACE TEMP VIEW fac_hfsrb_rows AS
WITH u AS (
  SELECT 'public_health.bronze.facilities_hfsrb_hospitals_bronze' AS input_table, 'hospital' AS facility_category,
         _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
         nhfr_code, facility_name, region, province, city_municipality, ownership, ownership_class,
         service_capability, abc, dialysis_stations AS dialysis_raw, blood_service_facility, validity_until, license_no,
         map('facility_name', 'facility_name', 'hfsrb_abc', 'abc', 'service_level', 'service_capability',
             'dialysis_stations', 'dialysis_stations', 'blood_service_type', 'blood_service_facility',
             'license_valid_until', 'validity_until', 'ownership', 'ownership') AS value_columns
  FROM public_health.bronze.facilities_hfsrb_hospitals_bronze WHERE _source_key = 'doh_hfsrb_hospitals'
  UNION ALL
  SELECT 'public_health.bronze.facilities_hfsrb_infirmaries_bronze', 'infirmary',
         _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
         nhfr_code, facility_name, region, province, city_municipality, ownership, ownership_class,
         CAST(NULL AS STRING), abc, CAST(NULL AS STRING), CAST(NULL AS STRING), validity_until, license_no,
         map('facility_name', 'facility_name', 'hfsrb_abc', 'abc', 'license_valid_until', 'validity_until', 'ownership', 'ownership')
  FROM public_health.bronze.facilities_hfsrb_infirmaries_bronze WHERE _source_key = 'doh_hfsrb_infirmaries'
  UNION ALL
  SELECT 'public_health.bronze.facilities_hfsrb_primary_care_bronze', 'primary_care',
         _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
         nhfr_code, facility_name, region, province, city_municipality, ownership, CAST(NULL AS STRING),
         CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), validity_until, license_no,
         map('facility_name', 'facility_name', 'license_valid_until', 'validity_until', 'ownership', 'ownership')
  FROM public_health.bronze.facilities_hfsrb_primary_care_bronze WHERE _source_key = 'doh_hfsrb_primary_care'
  UNION ALL
  SELECT 'public_health.bronze.facilities_hfsrb_dialysis_clinics_bronze', 'dialysis_clinic',
         _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
         nhfr_code, facility_name, region, province, city_municipality, ownership, CAST(NULL AS STRING),
         CAST(NULL AS STRING), CAST(NULL AS STRING), stations, CAST(NULL AS STRING), validity_until, license_no,
         map('facility_name', 'facility_name', 'dialysis_stations', 'stations', 'license_valid_until', 'validity_until', 'ownership', 'ownership')
  FROM public_health.bronze.facilities_hfsrb_dialysis_clinics_bronze WHERE _source_key = 'doh_hfsrb_dialysis_clinics'
)
SELECT input_table, _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
       facility_category,
       nhfr_code AS source_id_raw,
       fac_nhfr_id(nhfr_code) AS nhfr_id,
       trim(facility_name) AS facility_name,
       region AS region_label, province AS province_label, city_municipality AS city_label,
       CAST(NULL AS STRING) AS city_code_raw, CAST(NULL AS STRING) AS barangay_code_raw,
       -- ownership from the column, else from the sheet name (' Private' has a leading space)
       initcap(trim(coalesce(ownership, _source_sheet))) AS ownership,
       trim(ownership_class) AS ownership_class,
       trim(service_capability) AS service_level,
       CAST(NULL AS INT) AS nhfr_reported_beds,
       CAST(fac_num(abc) AS INT) AS hfsrb_abc,
       CAST(fac_num(dialysis_raw) AS INT) AS dialysis_stations,          -- 'N/A', 'none' -> null
       CASE WHEN trim(blood_service_facility) IS NOT NULL THEN initcap(trim(blood_service_facility)) END AS blood_service_type,
       CAST(NULL AS STRING) AS nhfr_licensing_status,
       fac_date(validity_until) AS license_valid_until,
       trim(license_no) AS license_no,
       value_columns,
       CASE WHEN facility_name IS NULL AND nhfr_code IS NULL AND license_no IS NULL THEN 'non_data' ELSE 'data' END AS row_class,
       CASE WHEN facility_name IS NULL AND nhfr_code IS NULL AND license_no IS NULL THEN 'blank_or_footer' END AS reason
FROM u;

CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__classified AS
SELECT *, CASE WHEN source_id_raw IS NOT NULL AND nhfr_id IS NULL THEN 'invalid_code_token' END AS code_issue
FROM fac_nhfr_rows
UNION ALL
SELECT *, CASE WHEN source_id_raw IS NOT NULL AND nhfr_id IS NULL THEN 'invalid_code_token' END
FROM fac_hfsrb_rows;


-- =============================================================================
-- [2] inputs: everything this build reads (layout of quality.build_inputs)
-- =============================================================================
-- Declared inputs (plan 5.4): the build fails if one is missing or extra.
CREATE OR REPLACE TEMP VIEW fac_declared_inputs AS
SELECT * FROM VALUES
  ('doh_nhfr', NULL),
  ('doh_hfsrb_hospitals', 'Government'), ('doh_hfsrb_hospitals', 'Private'),
  ('doh_hfsrb_infirmaries', 'Government'), ('doh_hfsrb_infirmaries', 'Private'),
  ('doh_hfsrb_primary_care', 'Government'), ('doh_hfsrb_primary_care', 'Private'),
  ('doh_hfsrb_dialysis_clinics', 'Government'), ('doh_hfsrb_dialysis_clinics', ' Private')
  AS t(source_key, source_sheet);

-- Delta versions of the tables read. If DESCRIBE HISTORY in a subquery is rejected, replace
-- each (SELECT max(version) ...) with CAST(NULL AS BIGINT).
CREATE OR REPLACE TEMP VIEW fac_registry_table_versions AS
SELECT 'public_health.bronze.facilities_nhfr_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.facilities_nhfr_bronze)) AS table_version
UNION ALL SELECT 'public_health.bronze.facilities_hfsrb_hospitals_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.facilities_hfsrb_hospitals_bronze))
UNION ALL SELECT 'public_health.bronze.facilities_hfsrb_infirmaries_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.facilities_hfsrb_infirmaries_bronze))
UNION ALL SELECT 'public_health.bronze.facilities_hfsrb_primary_care_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.facilities_hfsrb_primary_care_bronze))
UNION ALL SELECT 'public_health.bronze.facilities_hfsrb_dialysis_clinics_bronze',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.facilities_hfsrb_dialysis_clinics_bronze))
UNION ALL SELECT 'public_health.silver.geography_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.geography_silver))
UNION ALL SELECT 'public_health.silver.facilities_area_exceptions',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_area_exceptions))
UNION ALL SELECT 'public_health.silver.facilities_id_map_override',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_id_map_override))
UNION ALL SELECT 'public_health.silver.facilities_id_map_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_id_map_silver))
UNION ALL SELECT 'public_health.silver.facilities_registry_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_registry_silver));

CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.facilities_registry_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT registry_build_id AS build_id,
       'public_health.silver.facilities_registry_silver' AS target_table,
       'bronze_source' AS input_kind,
       f.input_table,
       max(v.table_version) AS input_table_version,
       f._source_key AS source_key, f._source_file AS source_file, f._source_sheet AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at AS ingested_at,
       f.input_rows,
       CAST(NULL AS STRING) AS reference_version,
       count(m.batch_id) AS metadata_matches                         -- gate only, not appended
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key
 AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet
 AND m.retrieved_at = f._ingested_at
LEFT JOIN fac_registry_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
-- tables that shaped the build: geography, the two reference tables, the previous targets
SELECT registry_build_id, 'public_health.silver.facilities_registry_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CASE WHEN t.table_name LIKE '%geography_silver' THEN geography_checksum END,
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.geography_silver' AS table_name, count(*) AS n FROM fac_geo
      UNION ALL SELECT 'public_health.silver.facilities_area_exceptions', count(*) FROM public_health.silver.facilities_area_exceptions
      UNION ALL SELECT 'public_health.silver.facilities_id_map_override', count(*) FROM public_health.silver.facilities_id_map_override
      UNION ALL SELECT 'public_health.silver.facilities_id_map_silver', count(*) FROM public_health.silver.facilities_id_map_silver
      UNION ALL SELECT 'public_health.silver.facilities_registry_silver', count(*) FROM public_health.silver.facilities_registry_silver) t
LEFT JOIN fac_registry_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] geography: the area of every data row. Each row resolves once.
--   NHFR: its own city/municipality code (Sulu codes remapped by the exceptions file),
--         validated against geography; the level comes from geography.
--   HFSRB: region label -> region (rule), province label -> province (name within region),
--          city label -> city / municipality / sub-municipality by name within the region,
--          ties broken by the province and by whether the label says "city".
--          An exception row (area_label) wins over the rule.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__geo AS
WITH remap AS (
  SELECT match_value AS from_prefix, psgc_code AS to_prefix
  FROM public_health.silver.facilities_area_exceptions
  WHERE source_group = 'nhfr' AND match_type = 'code_prefix'
),
nhfr AS (
  SELECT c._source_key, c._source_file, c._source_sheet, c._source_row_num,
         coalesce(concat(r1.to_prefix, substr(c.city_code_raw, length(r1.from_prefix) + 1)), c.city_code_raw) AS city_code,
         coalesce(concat(r2.to_prefix, substr(c.barangay_code_raw, length(r2.from_prefix) + 1)), c.barangay_code_raw) AS bgy_code,
         (r1.from_prefix IS NOT NULL) AS remapped
  FROM public_health.silver.facilities_registry_silver__classified c
  LEFT JOIN remap r1 ON startswith(c.city_code_raw, r1.from_prefix)
  LEFT JOIN remap r2 ON startswith(c.barangay_code_raw, r2.from_prefix)
  WHERE c._source_key = 'doh_nhfr' AND c.row_class = 'data'
),
nhfr_geo AS (
  SELECT n._source_key, n._source_file, n._source_sheet, n._source_row_num,
         g.psgc_code, CASE WHEN b.psgc_code IS NOT NULL THEN n.bgy_code END AS barangay_psgc,
         CASE WHEN n.remapped THEN 'exception' ELSE 'source_code' END AS geo_resolution_method,
         CASE WHEN g.psgc_code IS NULL THEN 1 ELSE 0 END AS geo_unresolved,
         CAST(NULL AS STRING) AS geo_candidates
  FROM nhfr n
  LEFT JOIN fac_geo g ON g.psgc_code = n.city_code AND g.geo_level IN ('city', 'municipality', 'submunicipality')
  LEFT JOIN fac_geo b ON b.psgc_code = n.bgy_code AND b.geo_level = 'barangay'
),
h AS (
  SELECT c._source_key, c._source_file, c._source_sheet, c._source_row_num,
         fac_region_psgc(c.region_label) AS region_psgc,
         fac_place_key(c.province_label) AS prov_place, fac_place_key(c.city_label) AS city_place,
         fac_norm(c.city_label) AS city_norm, fac_norm(c.province_label) AS prov_norm,
         fac_city_hint(c.city_label) AS city_hint
  FROM public_health.silver.facilities_registry_silver__classified c
  WHERE c._source_key <> 'doh_nhfr' AND c.row_class = 'data'
),
-- province: exception row, else a unique province of that name in the region, else in the country
prov_region AS (
  SELECT h._source_key, h._source_file, h._source_sheet, h._source_row_num, count(*) AS n, max(p.psgc_code) AS psgc_code
  FROM h JOIN fac_geo p ON p.geo_level = 'province' AND p.region_psgc = h.region_psgc AND p.place_norm = h.prov_place
  GROUP BY h._source_key, h._source_file, h._source_sheet, h._source_row_num
),
prov_any AS (
  SELECT h._source_key, h._source_file, h._source_sheet, h._source_row_num, count(*) AS n, max(p.psgc_code) AS psgc_code
  FROM h JOIN fac_geo p ON p.geo_level = 'province' AND p.place_norm = h.prov_place
  GROUP BY h._source_key, h._source_file, h._source_sheet, h._source_row_num
),
h_prov1 AS (
  SELECT h.*,
         coalesce(pe.psgc_code, CASE WHEN pr.n = 1 THEN pr.psgc_code END,
                  CASE WHEN pr.n IS NULL AND pa.n = 1 THEN pa.psgc_code END) AS prov_psgc
  FROM h
  LEFT JOIN prov_region pr ON pr._source_key = h._source_key AND pr._source_file = h._source_file
       AND pr._source_sheet <=> h._source_sheet AND pr._source_row_num = h._source_row_num
  LEFT JOIN prov_any pa ON pa._source_key = h._source_key AND pa._source_file = h._source_file
       AND pa._source_sheet <=> h._source_sheet AND pa._source_row_num = h._source_row_num
  LEFT JOIN public_health.silver.facilities_area_exceptions pe
    ON pe.source_group = 'hfsrb' AND pe.match_type = 'province_label' AND pe.match_value = h.prov_norm
),
cand AS (
  SELECT h._source_key, h._source_file, h._source_sheet, h._source_row_num, g.psgc_code,
         (CASE WHEN h.prov_psgc IS NOT NULL AND g.province_psgc = h.prov_psgc THEN 2 ELSE 0 END)
       + (CASE WHEN h.city_hint AND g.geo_level = 'city' THEN 1
               WHEN NOT h.city_hint AND g.geo_level = 'municipality' THEN 1 ELSE 0 END) AS score
  FROM h_prov1 h
  JOIN fac_geo g
    ON g.geo_level IN ('city', 'municipality', 'submunicipality')
   AND g.region_psgc = h.region_psgc AND g.place_norm = h.city_place
),
-- no candidate in the labelled region: the same name anywhere (labels such as
-- REGION 12 / Cotabato City, NCR / Imus City put the place in the wrong region)
cand_any AS (
  SELECT h._source_key, h._source_file, h._source_sheet, h._source_row_num, g.psgc_code,
         (CASE WHEN h.prov_psgc IS NOT NULL AND g.province_psgc = h.prov_psgc THEN 2 ELSE 0 END)
       + (CASE WHEN h.city_hint AND g.geo_level = 'city' THEN 1
               WHEN NOT h.city_hint AND g.geo_level = 'municipality' THEN 1 ELSE 0 END) AS score
  FROM h_prov1 h
  JOIN fac_geo g
    ON g.geo_level IN ('city', 'municipality', 'submunicipality') AND g.place_norm = h.city_place
  WHERE NOT EXISTS (SELECT 1 FROM cand c WHERE c._source_key = h._source_key AND c._source_file = h._source_file
                      AND c._source_sheet <=> h._source_sheet AND c._source_row_num = h._source_row_num)
),
-- the province column names a city (e.g. province 'Davao City', city 'Talomo District'):
-- used only when the city label matched nothing anywhere
city_as_prov AS (
  SELECT h._source_key, h._source_file, h._source_sheet, h._source_row_num,
         CASE WHEN count(*) = 1 THEN max(g.psgc_code) END AS psgc_code
  FROM h_prov1 h
  JOIN fac_geo g ON g.geo_level = 'city' AND g.place_norm = h.prov_place
                AND (g.region_psgc = h.region_psgc OR h.region_psgc IS NULL)
  WHERE h.prov_psgc IS NULL
  GROUP BY h._source_key, h._source_file, h._source_sheet, h._source_row_num
),
best_any AS (
  SELECT _source_key, _source_file, _source_sheet, _source_row_num,
         count_if(score = max_s) AS n_best, max_by(psgc_code, score) AS best_psgc,
         array_join(array_sort(collect_list(psgc_code)), ',') AS all_candidates
  FROM (SELECT *, max(score) OVER (PARTITION BY _source_key, _source_file, _source_sheet, _source_row_num) AS max_s FROM cand_any)
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num
),
best AS (
  SELECT _source_key, _source_file, _source_sheet, _source_row_num,
         max(score) AS best_score,
         count_if(score = max_s) AS n_best,
         max_by(psgc_code, score) AS best_psgc,
         array_join(array_sort(collect_list(psgc_code)), ',') AS all_candidates
  FROM (SELECT *, max(score) OVER (PARTITION BY _source_key, _source_file, _source_sheet, _source_row_num) AS max_s FROM cand)
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num
),
exc AS (
  SELECT * FROM public_health.silver.facilities_area_exceptions
  WHERE source_group = 'hfsrb' AND match_type = 'area_label'
),
hfsrb_geo AS (
  SELECT h._source_key, h._source_file, h._source_sheet, h._source_row_num,
         coalesce(e1.psgc_code, e2.psgc_code,
                  CASE WHEN b.n_best = 1 THEN b.best_psgc END,
                  CASE WHEN b.n_best IS NULL AND ba.n_best = 1 THEN ba.best_psgc END,
                  CASE WHEN b.n_best IS NULL AND ba.n_best IS NULL THEN cp.psgc_code END) AS psgc_code,
         CAST(NULL AS STRING) AS barangay_psgc,
         CASE WHEN coalesce(e1.psgc_code, e2.psgc_code) IS NOT NULL THEN 'exception'
              WHEN b.n_best = 1 THEN 'name_level_parent'
              WHEN b.n_best IS NULL AND ba.n_best = 1 THEN 'name_level_other_region'
              WHEN b.n_best IS NULL AND ba.n_best IS NULL AND cp.psgc_code IS NOT NULL THEN 'city_in_province_column' END AS geo_resolution_method,
         CASE WHEN coalesce(e1.psgc_code, e2.psgc_code, CASE WHEN b.n_best = 1 THEN b.best_psgc END,
                            CASE WHEN b.n_best IS NULL AND ba.n_best = 1 THEN ba.best_psgc END,
                            CASE WHEN b.n_best IS NULL AND ba.n_best IS NULL THEN cp.psgc_code END) IS NULL
              THEN 1 ELSE 0 END AS geo_unresolved,
         CASE WHEN eu.match_value IS NOT NULL THEN concat('reviewed_unresolvable: ', coalesce(b.all_candidates, ba.all_candidates, 'no candidate'))
              ELSE coalesce(b.all_candidates, ba.all_candidates) END AS geo_candidates
  FROM h_prov1 h
  LEFT JOIN best b
    ON b._source_key = h._source_key AND b._source_file = h._source_file
   AND b._source_sheet <=> h._source_sheet AND b._source_row_num = h._source_row_num
  LEFT JOIN best_any ba
    ON ba._source_key = h._source_key AND ba._source_file = h._source_file
   AND ba._source_sheet <=> h._source_sheet AND ba._source_row_num = h._source_row_num
  LEFT JOIN city_as_prov cp
    ON cp._source_key = h._source_key AND cp._source_file = h._source_file
   AND cp._source_sheet <=> h._source_sheet AND cp._source_row_num = h._source_row_num
  LEFT JOIN exc e1 ON e1.match_value = h.city_norm AND e1.parent_label_norm = h.prov_norm
  LEFT JOIN exc e2 ON e2.match_value = h.city_norm AND e2.parent_label_norm IS NULL
  -- labels a reviewer could not place: quarantined without failing the gate
  LEFT JOIN public_health.silver.facilities_area_exceptions eu
    ON eu.source_group = 'hfsrb' AND eu.match_type = 'unresolvable'
   AND eu.match_value = h.city_norm AND eu.parent_label_norm <=> h.prov_norm
)
SELECT * FROM nhfr_geo
UNION ALL
SELECT * FROM hfsrb_geo;


-- =============================================================================
-- [4] identity (plan 2.2 - 2.6)
--   a. NHFR record: source_record_id = nhfr_id
--   b. HFSRB hospital rows sharing one nhfr_id (rule 2.4):
--        1 exact duplicate            -> duplicate_of the kept row
--        2 same licence or same name + municipality -> one facility, latest validity kept
--        3 different facilities       -> code not used for these rows (ambiguous_nhfr_code)
--   c. usable code that exists in NHFR -> joins that NHFR facility
--      (non-hospital lists: service_of_existing_facility, no second registry row)
--   d. no usable code: exact facility name + municipality against NHFR hospitals not
--      already matched (hospital list only)
--   e. overrides from facilities_id_map_override
--   f. everything else is its own facility: source_record_id = category | name | municipality
--   facility_key: reused from the previous id map for the same (_source_key, source_record_id);
--   an HFSRB record joined to NHFR takes the NHFR facility's key; otherwise a new uuid.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__records_pre AS
WITH d AS (
  SELECT c.*, g.psgc_code, g.barangay_psgc, g.geo_resolution_method, g.geo_unresolved, g.geo_candidates,
         fac_fname(c.facility_name) AS fname_norm
  FROM public_health.silver.facilities_registry_silver__classified c
  JOIN public_health.silver.facilities_registry_silver__geo g
    ON g._source_key = c._source_key AND g._source_file = c._source_file
   AND g._source_sheet <=> c._source_sheet AND g._source_row_num = c._source_row_num
  WHERE c.row_class = 'data'
),
nhfr AS (SELECT * FROM d WHERE _source_key = 'doh_nhfr'),
-- b. HFSRB hospital rows that share an nhfr_id
hh AS (
  SELECT d.*,
         count(*) OVER (PARTITION BY _source_key, nhfr_id) AS n_code,
         size(collect_set(coalesce(psgc_code, fac_norm(city_label))) OVER (PARTITION BY _source_key, nhfr_id)) AS n_places,
         size(collect_set(fname_norm) OVER (PARTITION BY _source_key, nhfr_id)) AS n_names,
         row_number() OVER (PARTITION BY _source_key, nhfr_id ORDER BY license_valid_until DESC NULLS LAST, _source_file, _source_sheet, _source_row_num) AS rn_code
  FROM d WHERE _source_key <> 'doh_nhfr' AND nhfr_id IS NOT NULL
),
hh_rule AS (
  SELECT h.*,
         CASE WHEN n_code = 1 THEN 'single'
              WHEN n_code > 1 AND n_places = 1 AND n_names = 1 THEN 'same_facility'
              ELSE 'ambiguous' END AS code_rule,
         first_value(struct(_source_file, _source_sheet, _source_row_num)) OVER (PARTITION BY _source_key, nhfr_id ORDER BY rn_code) AS kept_row
  FROM hh h
),
hfsrb AS (
  SELECT d.*,
         r.code_rule,
         CASE WHEN r.code_rule = 'same_facility' AND r.rn_code > 1 THEN r.kept_row END AS dup_kept_row,
         -- the id the row may use to join NHFR
         CASE WHEN d.nhfr_id IS NOT NULL AND coalesce(r.code_rule, 'single') <> 'ambiguous' THEN d.nhfr_id END AS usable_nhfr_id
  FROM d
  LEFT JOIN hh_rule r
    ON r._source_key = d._source_key AND r._source_file = d._source_file
   AND r._source_sheet <=> d._source_sheet AND r._source_row_num = d._source_row_num
  WHERE d._source_key <> 'doh_nhfr'
),
-- c. a code match is accepted only when the two records agree on the place (same LGU) or
--    share at least half of their distinctive name words; otherwise the code is not trusted
--    (code_name_place_mismatch) and the row goes on to the name match like a row without a code.
code_match AS (
  SELECT h.* EXCEPT (usable_nhfr_id),
         CASE WHEN n.nhfr_id IS NOT NULL AND NOT (fac_lgu(n.psgc_code) <=> fac_lgu(h.psgc_code))
                   AND coalesce(fac_name_similarity(n.facility_name, h.facility_name), 0) < 0.5
              THEN NULL ELSE h.usable_nhfr_id END AS usable_nhfr_id,
         CASE WHEN n.nhfr_id IS NOT NULL AND NOT (fac_lgu(n.psgc_code) <=> fac_lgu(h.psgc_code))
                   AND coalesce(fac_name_similarity(n.facility_name, h.facility_name), 0) < 0.5
              THEN NULL ELSE n.nhfr_id END AS matched_nhfr_id,
         (n.nhfr_id IS NOT NULL AND NOT (fac_lgu(n.psgc_code) <=> fac_lgu(h.psgc_code))
          AND coalesce(fac_name_similarity(n.facility_name, h.facility_name), 0) < 0.5) AS code_rejected
  FROM hfsrb h LEFT JOIN nhfr n ON n.nhfr_id = h.usable_nhfr_id
),
-- d. name + municipality match for hospital-list rows without a code match
name_cand AS (
  SELECT h._source_key, h._source_file, h._source_sheet, h._source_row_num, n.nhfr_id
  FROM code_match h
  JOIN nhfr n ON n.fname_norm = h.fname_norm AND n.psgc_code = h.psgc_code
  WHERE h._source_key = 'doh_hfsrb_hospitals' AND h.matched_nhfr_id IS NULL AND h.dup_kept_row IS NULL
    AND n.nhfr_id NOT IN (SELECT matched_nhfr_id FROM code_match
                          WHERE matched_nhfr_id IS NOT NULL AND _source_key = 'doh_hfsrb_hospitals' AND dup_kept_row IS NULL)
),
name_ok AS (       -- exactly one NHFR candidate, and that NHFR facility is claimed by only this row
  SELECT * FROM (
    SELECT c.*, count(*) OVER (PARTITION BY _source_key, _source_file, _source_sheet, _source_row_num) AS n_for_row,
                count(*) OVER (PARTITION BY nhfr_id) AS n_for_nhfr
    FROM name_cand c) WHERE n_for_row = 1 AND n_for_nhfr = 1
),
ov AS (
  SELECT * FROM public_health.silver.facilities_id_map_override
  WHERE coalesce(review_status, 'accepted') = 'accepted'
),
h_ident AS (
  SELECT h.*,
         CASE WHEN h._source_key = 'doh_hfsrb_hospitals' THEN coalesce(h.matched_nhfr_id, nm.nhfr_id) ELSE h.matched_nhfr_id END AS joined_nhfr_id,
         CASE WHEN h.matched_nhfr_id IS NOT NULL THEN 'nhfr_id'
              WHEN nm.nhfr_id IS NOT NULL THEN 'name_municipality' END AS auto_match_method,
         -- stable identifier of the source record
         CASE WHEN h.usable_nhfr_id IS NOT NULL THEN concat('nhfr:', h.usable_nhfr_id)
              WHEN h.psgc_code IS NOT NULL THEN concat('name:', h.facility_category, '|', h.fname_norm, '|', h.psgc_code)
         END AS source_record_id
  FROM code_match h
  LEFT JOIN name_ok nm
    ON nm._source_key = h._source_key AND nm._source_file = h._source_file
   AND nm._source_sheet <=> h._source_sheet AND nm._source_row_num = h._source_row_num
),
h_final AS (
  SELECT h.*,
         CASE WHEN o.action = 'link_to_nhfr' THEN CAST(o.nhfr_id AS BIGINT)
              WHEN o.action = 'own_facility' THEN NULL
              ELSE h.joined_nhfr_id END AS final_nhfr_id,
         CASE WHEN o.action IS NOT NULL THEN 'manual' ELSE h.auto_match_method END AS match_method
  FROM h_ident h
  LEFT JOIN ov o ON o._source_key = h._source_key AND o.source_record_id = h.source_record_id
),
-- duplicate source records among HFSRB-only rows (same id in one list): latest validity kept
h_dedup AS (
  SELECT h.*,
         row_number() OVER (PARTITION BY _source_key, source_record_id
                            ORDER BY license_valid_until DESC NULLS LAST, _source_file, _source_sheet, _source_row_num) AS rn_rec,
         first_value(struct(_source_file, _source_sheet, _source_row_num)) OVER (
           PARTITION BY _source_key, source_record_id
           ORDER BY license_valid_until DESC NULLS LAST, _source_file, _source_sheet, _source_row_num) AS rec_kept_row
  FROM h_final h
),
prev_map AS (SELECT * FROM public_health.silver.facilities_id_map_silver),
nhfr_keyed AS (
  SELECT n.*, coalesce(p.facility_key, uuid()) AS facility_key, p._first_build_id AS prev_first_build_id
  FROM nhfr n
  LEFT JOIN prev_map p ON p._source_key = 'doh_nhfr' AND p.source_record_id = CAST(n.nhfr_id AS STRING)
)
SELECT n.input_table, n._source_key, n._source_file, n._source_sheet, n._source_row_num, n._ingested_at, n._as_of_date,
       n.facility_category, n.source_id_raw, n.nhfr_id, CAST(n.nhfr_id AS STRING) AS source_record_id,
       true AS code_validated,
       'data' AS record_class, CAST(NULL AS STRING) AS reason,
       'matched' AS match_status, 'nhfr_id' AS match_method, n.nhfr_id AS joined_nhfr_id,
       CAST(NULL AS STRING) AS kept_file, CAST(NULL AS STRING) AS kept_sheet, CAST(NULL AS INT) AS kept_row,
       n.facility_key, n.prev_first_build_id,
       n.facility_name, n.ownership, n.ownership_class, n.service_level, n.nhfr_reported_beds, n.hfsrb_abc,
       n.dialysis_stations, n.blood_service_type, n.nhfr_licensing_status, n.license_valid_until, n.license_no,
       n.psgc_code, n.barangay_psgc, n.geo_resolution_method, n.geo_unresolved, n.geo_candidates,
       n.city_label AS geo_name_source, n.value_columns, n.code_issue
FROM nhfr_keyed n
UNION ALL
SELECT h.input_table, h._source_key, h._source_file, h._source_sheet, h._source_row_num, h._ingested_at, h._as_of_date,
       h.facility_category, h.source_id_raw, h.nhfr_id, h.source_record_id,
       -- a dialysis code cannot be checked: the NHFR export holds hospitals only (plan 2.2)
       CASE WHEN h.facility_category = 'dialysis_clinic' THEN false ELSE (h.nhfr_id IS NOT NULL) END AS code_validated,
       CASE WHEN h.code_rule = 'same_facility' AND h.dup_kept_row IS NOT NULL THEN 'duplicate'
            WHEN h.final_nhfr_id IS NULL AND h.psgc_code IS NULL THEN 'quarantined'
            WHEN h.rn_rec > 1 THEN 'duplicate'
            ELSE 'data' END AS record_class,
       CASE WHEN h.code_rule = 'same_facility' AND h.dup_kept_row IS NOT NULL THEN 'same_facility_older_record'
            WHEN h.final_nhfr_id IS NULL AND h.psgc_code IS NULL
                 THEN CASE WHEN h.city_label IS NULL THEN 'no_place_label'
                           WHEN h.geo_candidates LIKE 'reviewed_unresolvable%' THEN 'place_reviewed_unresolvable'
                           ELSE 'geo_unresolved' END
            WHEN h.rn_rec > 1 THEN 'same_record_in_list' END AS reason,
       CASE WHEN h.final_nhfr_id IS NOT NULL AND h.facility_category <> 'hospital' THEN 'service_of_existing_facility'
            WHEN h.final_nhfr_id IS NOT NULL THEN 'matched'
            WHEN h.code_rule = 'ambiguous' THEN 'ambiguous_code_own_facility'
            ELSE 'new_facility' END AS match_status,
       coalesce(h.match_method, 'new') AS match_method,
       h.final_nhfr_id AS joined_nhfr_id,
       coalesce(h.dup_kept_row._source_file, CASE WHEN h.rn_rec > 1 THEN h.rec_kept_row._source_file END),
       coalesce(h.dup_kept_row._source_sheet, CASE WHEN h.rn_rec > 1 THEN h.rec_kept_row._source_sheet END),
       coalesce(h.dup_kept_row._source_row_num, CASE WHEN h.rn_rec > 1 THEN h.rec_kept_row._source_row_num END),
       -- joined to NHFR: the NHFR facility's key. Own facility: the key it had before, but only
       -- if it was its own facility then too (a record that used to join NHFR gets a new key)
       CASE WHEN h.final_nhfr_id IS NOT NULL THEN nk.facility_key
            WHEN p.match_status IN ('new_facility', 'ambiguous_code_own_facility') THEN p.facility_key
       END AS facility_key_pre,                                           -- new uuid assigned below
       p._first_build_id,
       h.facility_name, h.ownership, h.ownership_class, h.service_level, h.nhfr_reported_beds, h.hfsrb_abc,
       h.dialysis_stations, h.blood_service_type, h.nhfr_licensing_status, h.license_valid_until, h.license_no,
       h.psgc_code, h.barangay_psgc, h.geo_resolution_method, h.geo_unresolved, h.geo_candidates,
       h.city_label, h.value_columns,
       coalesce(h.code_issue, CASE WHEN h.code_rule = 'ambiguous' THEN 'ambiguous_nhfr_code'
                                   WHEN h.code_rejected THEN 'code_name_place_mismatch' END)
FROM h_dedup h
LEFT JOIN nhfr_keyed nk ON nk.nhfr_id = h.final_nhfr_id
LEFT JOIN prev_map p ON p._source_key = h._source_key AND p.source_record_id = h.source_record_id;

-- one new uuid per new HFSRB-only facility (one per source record, shared by its duplicates)
CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__records AS
WITH new_keys AS (
  SELECT _source_key, source_record_id, uuid() AS new_key
  FROM (SELECT DISTINCT _source_key, source_record_id
        FROM public_health.silver.facilities_registry_silver__records_pre
        WHERE facility_key IS NULL AND source_record_id IS NOT NULL)
)
SELECT r.* EXCEPT (facility_key), coalesce(r.facility_key, k.new_key) AS facility_key
FROM public_health.silver.facilities_registry_silver__records_pre r
LEFT JOIN new_keys k USING (_source_key, source_record_id);


-- =============================================================================
-- [5] candidates
-- =============================================================================

-- [5a] id map: one row per (_source_key, source_record_id) seen now (the record kept for it),
--      plus rows of the previous version not seen now, carried unchanged (old build id).
CREATE OR REPLACE TABLE public_health.silver.facilities_id_map_silver__candidate AS
WITH cur AS (
  SELECT _source_key, source_record_id, source_id_raw, nhfr_id AS source_id_norm, code_validated, facility_key,
         match_method, match_status,
         coalesce(prev_first_build_id, idmap_build_id) AS _first_build_id,
         idmap_build_id AS _silver_build_id,
         _source_file, _source_sheet, _source_row_num, _as_of_date
  FROM public_health.silver.facilities_registry_silver__records
  WHERE record_class = 'data'
)
SELECT * FROM cur
UNION ALL
SELECT p.* FROM public_health.silver.facilities_id_map_silver p
LEFT ANTI JOIN cur c ON c._source_key = p._source_key AND c.source_record_id = p.source_record_id;

-- [5a2] previous facilities the id map no longer holds: not carried forward in [5b].
--       reason 'records_now_in_another_facility': their source records now map to another
--         facility_key (new_facility_keys lists it). The facility continues under that key.
--       reason 'no_id_map_rows': the previous id map had no row for the key either.
--       Review: SELECT * FROM public_health.silver.facilities_registry_silver__moved
CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__moved AS
WITH gone AS (
  SELECT p.facility_key, p.facility_category, p.facility_name
  FROM public_health.silver.facilities_registry_silver p
  LEFT ANTI JOIN public_health.silver.facilities_id_map_silver__candidate k ON k.facility_key = p.facility_key
),
moved_to AS (
  SELECT pm.facility_key,
         array_join(array_sort(collect_set(c.facility_key)), ',') AS new_facility_keys,
         array_join(array_sort(collect_set(concat(pm._source_key, ':', pm.source_record_id))), ',') AS source_records
  FROM public_health.silver.facilities_id_map_silver pm
  JOIN public_health.silver.facilities_id_map_silver__candidate c
    ON c._source_key = pm._source_key AND c.source_record_id = pm.source_record_id
   AND c.facility_key <> pm.facility_key
  GROUP BY pm.facility_key
)
SELECT g.facility_key AS old_facility_key, g.facility_category, g.facility_name,
       m.new_facility_keys, m.source_records,
       CASE WHEN m.facility_key IS NOT NULL THEN 'records_now_in_another_facility'
            ELSE 'no_id_map_rows' END AS reason,
       registry_build_id AS _detected_build_id
FROM gone g
LEFT JOIN moved_to m ON m.facility_key = g.facility_key;

-- [5b] registry
CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__candidate AS
WITH n AS (SELECT * FROM public_health.silver.facilities_registry_silver__records
           WHERE _source_key = 'doh_nhfr' AND record_class = 'data'),
     h AS (SELECT * FROM public_health.silver.facilities_registry_silver__records
           WHERE _source_key <> 'doh_nhfr' AND record_class = 'data'
             AND match_status <> 'service_of_existing_facility'),
facilities AS (
  -- NHFR facilities, with their HFSRB hospital record when one joined
  SELECT n.facility_key, n.facility_category, struct(n.*) AS nr, struct(hj.*) AS hr
  FROM n LEFT JOIN h hj ON hj.joined_nhfr_id = n.nhfr_id AND hj._source_key = 'doh_hfsrb_hospitals'
  UNION ALL
  -- HFSRB facilities that did not join an NHFR facility (the NHFR struct is all nulls)
  SELECT h.facility_key, h.facility_category, struct(n.*) AS nr, struct(h.*) AS hr
  FROM h LEFT JOIN n ON false
  WHERE h.joined_nhfr_id IS NULL
),
cur AS (
  SELECT f.facility_key,
         f.facility_category,
         coalesce(nr.facility_name, hr.facility_name)                     AS facility_name,
         nr.nhfr_id                                                       AS nhfr_id,
         hr.license_no                                                    AS license_no,
         coalesce(nr.ownership, hr.ownership)                             AS ownership,
         coalesce(nr.ownership_class, hr.ownership_class)                 AS ownership_class,
         coalesce(nr.service_level, hr.service_level)                     AS service_level,
         concat('psgc:', coalesce(nr.psgc_code, hr.psgc_code))            AS area_key,
         coalesce(nr.psgc_code, hr.psgc_code)                             AS psgc_code,
         nr.barangay_psgc                                                 AS barangay_psgc,
         coalesce(nr.geo_name_source, hr.geo_name_source)                 AS geo_name_source,
         CASE WHEN nr.facility_key IS NOT NULL THEN nr.geo_resolution_method ELSE hr.geo_resolution_method END AS geo_resolution_method,
         (nr.facility_key IS NOT NULL AND hr.facility_key IS NOT NULL AND hr.psgc_code IS NOT NULL
          AND fac_lgu(hr.psgc_code) <> fac_lgu(nr.psgc_code))             AS geo_conflict_nhfr_hfsrb,
         nr.nhfr_reported_beds,
         hr.hfsrb_abc,
         hr.hfsrb_abc                                                     AS authorized_beds,
         coalesce(hr.hfsrb_abc, nr.nhfr_reported_beds)                    AS analysis_beds,
         CASE WHEN hr.hfsrb_abc IS NOT NULL THEN 'authorized'
              WHEN nr.nhfr_reported_beds IS NOT NULL THEN 'nhfr_reported' END AS analysis_beds_basis,
         hr.dialysis_stations,
         CASE WHEN f.facility_category = 'hospital' AND hr.facility_key IS NOT NULL THEN hr.blood_service_type IS NOT NULL END AS has_blood_service,
         hr.blood_service_type,
         nr.nhfr_licensing_status,
         hr.license_valid_until,
         hr.license_valid_until >= hr._as_of_date                         AS is_license_valid_on_as_of,
         (nr.facility_key IS NOT NULL)                                    AS in_nhfr,
         (hr.facility_key IS NOT NULL)                                    AS in_hfsrb,
         CASE WHEN nr.facility_key IS NOT NULL AND hr.facility_key IS NOT NULL THEN hr.match_method
              WHEN nr.facility_key IS NOT NULL THEN 'nhfr_only' ELSE 'hfsrb_only' END AS match_method,
         (nr.facility_key IS NOT NULL)                                    AS is_currently_listed_nhfr,
         (hr.facility_key IS NOT NULL)                                    AS is_currently_listed_hfsrb,
         'listed'                                                         AS facility_status,
         registry_build_id                                                AS _silver_build_id,
         nr._source_key AS _nhfr_source_key, nr._source_file AS _nhfr_source_file,
         nr._source_row_num AS _nhfr_source_row_num, nr._as_of_date AS _nhfr_as_of_date,
         hr._source_key AS _hfsrb_source_key, hr._source_file AS _hfsrb_source_file, hr._source_sheet AS _hfsrb_source_sheet,
         hr._source_row_num AS _hfsrb_source_row_num, hr._as_of_date AS _hfsrb_as_of_date,
         -- silver column -> bronze column, only for the side each value came from (metric_groups in the plan)
         map_concat(
           CASE WHEN nr.facility_key IS NOT NULL
                THEN map('nhfr_reported_beds', 'Bed_Capacity', 'nhfr_licensing_status', 'Licensing_Status')
                ELSE CAST(map() AS MAP<STRING, STRING>) END,
           CASE WHEN hr.facility_key IS NOT NULL THEN map_filter(
                  map('hfsrb_abc', hr.value_columns['hfsrb_abc'], 'dialysis_stations', hr.value_columns['dialysis_stations'],
                      'license_valid_until', hr.value_columns['license_valid_until'],
                      'blood_service_type', hr.value_columns['blood_service_type']),
                  (k, v) -> v IS NOT NULL)
                ELSE CAST(map() AS MAP<STRING, STRING>) END,
           -- columns filled from either side: the side that supplied the value
           map('facility_name', CASE WHEN nr.facility_name IS NOT NULL THEN 'nhfr:Facility_Name' ELSE 'hfsrb:facility_name' END,
               'ownership', CASE WHEN nr.ownership IS NOT NULL THEN 'nhfr:Ownership_Major_Classification' ELSE 'hfsrb:ownership' END),
           CASE WHEN coalesce(nr.service_level, hr.service_level) IS NOT NULL
                THEN map('service_level', CASE WHEN nr.service_level IS NOT NULL THEN 'nhfr:Service_Capability' ELSE 'hfsrb:service_capability' END)
                ELSE CAST(map() AS MAP<STRING, STRING>) END
         ) AS _metric_source_columns
  FROM facilities f
),
hashed AS (
  SELECT c.*,
         sha2(to_json(named_struct(
           'facility_category', facility_category, 'facility_name', facility_name, 'nhfr_id', nhfr_id,
           'license_no', license_no, 'ownership', ownership, 'ownership_class', ownership_class,
           'service_level', service_level, 'psgc_code', psgc_code, 'barangay_psgc', barangay_psgc,
           'nhfr_reported_beds', nhfr_reported_beds, 'hfsrb_abc', hfsrb_abc, 'dialysis_stations', dialysis_stations,
           'blood_service_type', blood_service_type, 'nhfr_licensing_status', nhfr_licensing_status,
           'license_valid_until', license_valid_until, 'in_nhfr', in_nhfr, 'in_hfsrb', in_hfsrb)), 256) AS _row_hash
  FROM cur c
),
prev AS (SELECT * FROM public_health.silver.facilities_registry_silver)
SELECT h.facility_key, h.facility_category, h.facility_name, h.nhfr_id, h.license_no, h.ownership, h.ownership_class,
       h.service_level, h.area_key, h.psgc_code, h.barangay_psgc, h.geo_name_source, h.geo_resolution_method,
       h.geo_conflict_nhfr_hfsrb, h.nhfr_reported_beds, h.hfsrb_abc, h.authorized_beds, h.analysis_beds,
       h.analysis_beds_basis, h.dialysis_stations, h.has_blood_service, h.blood_service_type, h.nhfr_licensing_status,
       h.license_valid_until, h.is_license_valid_on_as_of, h.in_nhfr, h.in_hfsrb, h.match_method,
       h.is_currently_listed_nhfr, h.is_currently_listed_hfsrb, h.facility_status,
       h._row_hash,
       coalesce(p._first_build_id, registry_build_id)                                   AS _first_build_id,
       CASE WHEN p._row_hash <=> h._row_hash THEN p._business_change_build_id ELSE registry_build_id END AS _business_change_build_id,
       CAST(NULL AS STRING)                                                             AS _delisted_build_id,
       h._silver_build_id,
       h._nhfr_source_key, h._nhfr_source_file, h._nhfr_source_row_num, h._nhfr_as_of_date,
       h._hfsrb_source_key, h._hfsrb_source_file, h._hfsrb_source_sheet, h._hfsrb_source_row_num, h._hfsrb_as_of_date,
       h._metric_source_columns
FROM hashed h
LEFT JOIN prev p ON p.facility_key = h.facility_key
UNION ALL
-- facilities no source lists any more: kept unchanged, so their lineage still points at the build
-- that last read them; only the listing flags and _delisted_build_id change (plan 5.3).
-- The declared-inputs gate in [6] guarantees this build read every source completely.
-- Facilities recorded in __moved ([5a2]) are not carried: the id map no longer holds them.
SELECT p.facility_key, p.facility_category, p.facility_name, p.nhfr_id, p.license_no, p.ownership, p.ownership_class,
       p.service_level, p.area_key, p.psgc_code, p.barangay_psgc, p.geo_name_source, p.geo_resolution_method,
       p.geo_conflict_nhfr_hfsrb, p.nhfr_reported_beds, p.hfsrb_abc, p.authorized_beds, p.analysis_beds,
       p.analysis_beds_basis, p.dialysis_stations, p.has_blood_service, p.blood_service_type, p.nhfr_licensing_status,
       p.license_valid_until, p.is_license_valid_on_as_of, p.in_nhfr, p.in_hfsrb, p.match_method,
       false, false, 'not_listed',
       p._row_hash, p._first_build_id, p._business_change_build_id,
       coalesce(p._delisted_build_id, registry_build_id),
       p._silver_build_id,
       p._nhfr_source_key, p._nhfr_source_file, p._nhfr_source_row_num, p._nhfr_as_of_date,
       p._hfsrb_source_key, p._hfsrb_source_file, p._hfsrb_source_sheet, p._hfsrb_source_row_num, p._hfsrb_as_of_date,
       p._metric_source_columns
FROM prev p
LEFT ANTI JOIN hashed h ON h.facility_key = p.facility_key
LEFT ANTI JOIN public_health.silver.facilities_registry_silver__moved mv ON mv.old_facility_key = p.facility_key;


-- =============================================================================
-- [5c] dispositions: one row per bronze row that was
--      NOT loaded as itself. Loaded rows are not stored: the silver rows carry their bronze row
--      reference, and rows loaded per input = input_rows - rows here (quality.v_build_reconciliation).
--      merged_into rows are stored (with the facility_key) but count as loaded: they contributed.
--      A service record of an existing hospital is quarantined (target_key = that hospital's key).
--      Saved before the gates, so the gates check exactly what step [10] writes.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__dispositions AS
SELECT * FROM (
SELECT registry_build_id AS build_id, 'public_health.silver.facilities_registry_silver' AS target_table,
       c._source_key AS source_key, c._source_file AS source_file, c._source_sheet AS source_sheet,
       c._source_row_num AS source_row_num, i.load_batch_id, i.content_checksum,
       CASE WHEN c.row_class = 'non_data' THEN 'dropped_non_data'
            WHEN r.record_class = 'duplicate' THEN 'duplicate_of'
            WHEN r.record_class = 'quarantined' THEN 'quarantined'
            -- a second licence (infirmary, primary care, dialysis) of a hospital already in the registry:
            -- it adds no value to the hospital row, so it is not loaded; kept for review (plan 2.1)
            WHEN r.match_status = 'service_of_existing_facility' THEN 'quarantined'
            WHEN r._source_key <> 'doh_nhfr' AND r.joined_nhfr_id IS NOT NULL THEN 'merged_into'
            ELSE 'loaded' END AS disposition,
       CASE WHEN c.row_class = 'non_data' THEN c.reason
            WHEN r.record_class IN ('duplicate', 'quarantined') THEN r.reason
            WHEN r.match_status = 'service_of_existing_facility' THEN r.match_status
            WHEN r._source_key <> 'doh_nhfr' AND r.joined_nhfr_id IS NOT NULL THEN r.match_status END AS reason,
       CASE WHEN r.record_class = 'duplicate' THEN to_json(named_struct(
              '_source_key', r._source_key, '_source_file', r.kept_file, '_source_sheet', r.kept_sheet,
              '_source_row_num', r.kept_row, '_content_checksum', i.content_checksum))
            WHEN r.record_class = 'data' THEN to_json(named_struct('facility_key', r.facility_key)) END AS target_key,
       current_timestamp() AS recorded_at
FROM public_health.silver.facilities_registry_silver__classified c
LEFT JOIN public_health.silver.facilities_registry_silver__records r
  ON r._source_key = c._source_key AND r._source_file = c._source_file
 AND r._source_sheet <=> c._source_sheet AND r._source_row_num = c._source_row_num
LEFT JOIN public_health.silver.facilities_registry_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
) d
WHERE disposition <> 'loaded';


-- =============================================================================
-- [6] gates and output validation: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver__gates AS
SELECT 'inputs: declared file or sheet not read' AS gate, count(*) AS failures
  FROM fac_declared_inputs d
  LEFT ANTI JOIN public_health.silver.facilities_registry_silver__inputs i
    ON i.input_kind = 'bronze_source' AND i.source_key = d.source_key AND i.source_sheet <=> d.source_sheet
UNION ALL
SELECT 'inputs: file or sheet read that is not declared', count(*)
  FROM public_health.silver.facilities_registry_silver__inputs i
  LEFT ANTI JOIN fac_declared_inputs d ON i.source_key = d.source_key AND i.source_sheet <=> d.source_sheet
  WHERE i.input_kind = 'bronze_source'
UNION ALL
SELECT 'inputs: file or sheet with more than one load time', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_registry_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY input_table, source_key, source_file, source_sheet HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.facilities_registry_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.facilities_registry_silver__inputs
  WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'inputs: geography snapshot is empty', CASE WHEN (SELECT count(*) FROM fac_geo) = 0 THEN 1 ELSE 0 END
UNION ALL
SELECT 'NHFR: code not in the format DOH + 15 digits', count(*)
  FROM public_health.silver.facilities_registry_silver__classified WHERE _source_key = 'doh_nhfr' AND row_class = 'data' AND nhfr_id IS NULL
UNION ALL
SELECT 'NHFR: nhfr_id not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_registry_silver__classified WHERE _source_key = 'doh_nhfr' AND row_class = 'data'
  GROUP BY nhfr_id HAVING count(*) > 1)
UNION ALL
SELECT 'NHFR: city/municipality code not in geography (after the code exceptions)', count(*)
  FROM public_health.silver.facilities_registry_silver__geo WHERE _source_key = 'doh_nhfr' AND geo_unresolved = 1
UNION ALL
SELECT 'HFSRB: region label not recognised', count(*)
  FROM public_health.silver.facilities_registry_silver__classified
  WHERE _source_key <> 'doh_nhfr' AND row_class = 'data' AND fac_region_psgc(region_label) IS NULL
UNION ALL
SELECT 'HFSRB: record without an NHFR match whose place does not resolve (add an area exception)', count(*)
  FROM public_health.silver.facilities_registry_silver__records WHERE record_class = 'quarantined' AND reason = 'geo_unresolved'
UNION ALL
SELECT 'HFSRB hospitals: an nhfr_id joined by more than one record (rule 2.4)', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_registry_silver__records
  WHERE _source_key = 'doh_hfsrb_hospitals' AND record_class = 'data' AND joined_nhfr_id IS NOT NULL
  GROUP BY joined_nhfr_id HAVING count(*) > 1)
UNION ALL
SELECT 'bronze row classified more than once', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_registry_silver__classified
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'data row without an identity decision', count(*)
  FROM public_health.silver.facilities_registry_silver__classified c
  LEFT ANTI JOIN public_health.silver.facilities_registry_silver__records r
    ON r._source_key = c._source_key AND r._source_file = c._source_file
   AND r._source_sheet <=> c._source_sheet AND r._source_row_num = c._source_row_num
  WHERE c.row_class = 'data'
UNION ALL
SELECT 'id map: key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_id_map_silver__candidate GROUP BY _source_key, source_record_id HAVING count(*) > 1)
UNION ALL
SELECT 'id map: facility_key null', count(*) FROM public_health.silver.facilities_id_map_silver__candidate WHERE facility_key IS NULL
UNION ALL
SELECT 'registry: facility_key null or not unique', count(*) FROM (
  SELECT facility_key FROM public_health.silver.facilities_registry_silver__candidate
  GROUP BY facility_key HAVING count(*) > 1 OR facility_key IS NULL)
UNION ALL
SELECT 'registry: listed facility with an area not in geography', count(*)
  FROM public_health.silver.facilities_registry_silver__candidate r
  WHERE r.facility_status = 'listed'
    AND NOT EXISTS (SELECT 1 FROM fac_geo g WHERE g.psgc_code = r.psgc_code)
UNION ALL
SELECT 'registry: every registry key is in the id map', count(*)
  FROM public_health.silver.facilities_registry_silver__candidate r
  LEFT ANTI JOIN public_health.silver.facilities_id_map_silver__candidate m ON m.facility_key = r.facility_key
UNION ALL
-- lineage requirements (plan 5.4): a group is filled exactly when its side contributed
SELECT 'lineage: nhfr group does not match in_nhfr', count(*)
  FROM public_health.silver.facilities_registry_silver__candidate
  WHERE in_nhfr <> (_nhfr_source_key IS NOT NULL AND _nhfr_source_file IS NOT NULL
                    AND _nhfr_source_row_num IS NOT NULL AND _nhfr_as_of_date IS NOT NULL)
     OR (NOT in_nhfr AND coalesce(_nhfr_source_key, _nhfr_source_file, CAST(_nhfr_source_row_num AS STRING), CAST(_nhfr_as_of_date AS STRING)) IS NOT NULL)
UNION ALL
SELECT 'lineage: hfsrb group does not match in_hfsrb', count(*)
  FROM public_health.silver.facilities_registry_silver__candidate
  WHERE in_hfsrb <> (_hfsrb_source_key IS NOT NULL AND _hfsrb_source_file IS NOT NULL AND _hfsrb_source_sheet IS NOT NULL
                     AND _hfsrb_source_row_num IS NOT NULL AND _hfsrb_as_of_date IS NOT NULL)
     OR (NOT in_hfsrb AND coalesce(_hfsrb_source_key, _hfsrb_source_file, _hfsrb_source_sheet,
                                   CAST(_hfsrb_source_row_num AS STRING), CAST(_hfsrb_as_of_date AS STRING)) IS NOT NULL)
UNION ALL
SELECT 'lineage: _silver_build_id or _metric_source_columns null', count(*)
  FROM public_health.silver.facilities_registry_silver__candidate WHERE _silver_build_id IS NULL OR _metric_source_columns IS NULL
UNION ALL
SELECT 'lineage: _metric_source_columns key without a metric group', count(*)
  FROM (SELECT explode(map_keys(_metric_source_columns)) AS k FROM public_health.silver.facilities_registry_silver__candidate
        WHERE _silver_build_id = registry_build_id)
  WHERE k NOT IN ('nhfr_reported_beds', 'nhfr_licensing_status', 'hfsrb_abc', 'dialysis_stations',
                  'license_valid_until', 'blood_service_type', 'facility_name', 'ownership', 'service_level')
UNION ALL
-- output validation
SELECT 'output: hospitals <> NHFR hospitals + HFSRB hospital records that joined no NHFR facility',
       abs((SELECT count(*) FROM public_health.silver.facilities_registry_silver__candidate
            WHERE facility_category = 'hospital' AND _silver_build_id = registry_build_id)
         - (SELECT count(*) FROM public_health.silver.facilities_registry_silver__records WHERE _source_key = 'doh_nhfr' AND record_class = 'data')
         - (SELECT count(*) FROM public_health.silver.facilities_registry_silver__records
            WHERE _source_key = 'doh_hfsrb_hospitals' AND record_class = 'data' AND joined_nhfr_id IS NULL))
UNION ALL
SELECT 'control: NHFR bed capacity = 119,862 (bronze QC control)',
       CASE WHEN (SELECT sum(nhfr_reported_beds) FROM public_health.silver.facilities_registry_silver__candidate
                  WHERE in_nhfr AND _silver_build_id = registry_build_id) = 119862 THEN 0 ELSE 1 END
UNION ALL
SELECT 'control: HFSRB hospital ABC in silver = bronze ABC of the records kept',
       abs(coalesce((SELECT sum(hfsrb_abc) FROM public_health.silver.facilities_registry_silver__candidate
                     WHERE _hfsrb_source_key = 'doh_hfsrb_hospitals' AND _silver_build_id = registry_build_id), 0)
         - coalesce((SELECT sum(hfsrb_abc) FROM public_health.silver.facilities_registry_silver__records
                     WHERE _source_key = 'doh_hfsrb_hospitals' AND record_class = 'data'), 0))
UNION ALL
SELECT 'dispositions: classified rows <> bronze rows read', abs(
         (SELECT count(*) FROM public_health.silver.facilities_registry_silver__classified)
       - (SELECT sum(input_rows) FROM public_health.silver.facilities_registry_silver__inputs WHERE input_kind = 'bronze_source'))
UNION ALL
-- contract 7.1, per input: distinct bronze rows referenced by the registry (either side, this build)
--   = rows read - rows not loaded. merged_into counts as loaded (it contributed to a facility row).
SELECT 'reconciliation: inputs where rows referenced by silver <> rows read - rows not loaded', count(*)
FROM public_health.silver.facilities_registry_silver__inputs i
LEFT JOIN (
  SELECT k, f, s, count(*) AS n FROM (
    SELECT DISTINCT _nhfr_source_key AS k, _nhfr_source_file AS f, CAST(NULL AS STRING) AS s, _nhfr_source_row_num AS r
    FROM public_health.silver.facilities_registry_silver__candidate WHERE in_nhfr AND _silver_build_id = registry_build_id
    UNION
    SELECT DISTINCT _hfsrb_source_key, _hfsrb_source_file, _hfsrb_source_sheet, _hfsrb_source_row_num
    FROM public_health.silver.facilities_registry_silver__candidate WHERE in_hfsrb AND _silver_build_id = registry_build_id)
  GROUP BY k, f, s) ref
  ON ref.k = i.source_key AND ref.f = i.source_file AND ref.s <=> i.source_sheet
LEFT JOIN (
  SELECT source_key, source_file, source_sheet, count_if(disposition <> 'merged_into') AS n
  FROM public_health.silver.facilities_registry_silver__dispositions GROUP BY source_key, source_file, source_sheet) nl
  ON nl.source_key = i.source_key AND nl.source_file = i.source_file AND nl.source_sheet <=> i.source_sheet
WHERE i.input_kind = 'bronze_source' AND i.input_rows - coalesce(nl.n, 0) <> coalesce(ref.n, 0);


-- =============================================================================
-- [7] build log rows (status 'succeeded' only when every gate is 0)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_registry_build_log AS
WITH g AS (
  SELECT count_if(failures <> 0) AS failed_gates,
         concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
  FROM public_health.silver.facilities_registry_silver__gates
)
SELECT b.build_id, 'silver' AS layer, 'facilities' AS domain, b.target_table,
       silver_build_started_at AS started_at, current_timestamp() AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN b.n END AS row_count,
       CAST(NULL AS BIGINT) AS target_table_version,
       code_version AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup, 'geography_checksum', geography_checksum,
                            'companion_build_id', b.companion,
                            'moved_facilities', mv.moved, 'dropped_without_id_map', mv.no_id_map)) AS parameters,
       job_run_id AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT registry_build_id AS build_id, 'public_health.silver.facilities_registry_silver' AS target_table,
             (SELECT count(*) FROM public_health.silver.facilities_registry_silver__candidate) AS n, idmap_build_id AS companion
      UNION ALL
      SELECT idmap_build_id, 'public_health.silver.facilities_id_map_silver',
             (SELECT count(*) FROM public_health.silver.facilities_id_map_silver__candidate), registry_build_id) b
CROSS JOIN g
CROSS JOIN (SELECT count_if(reason = 'records_now_in_another_facility') AS moved,
                   count_if(reason = 'no_id_map_rows') AS no_id_map
            FROM public_health.silver.facilities_registry_silver__moved) mv;


-- =============================================================================
-- [8] stop here if a gate failed. The failed builds are logged; the published tables stay as
--     they were. Staging tables are kept for inspection:
--       SELECT * FROM public_health.silver.facilities_registry_silver__gates WHERE failures <> 0
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM fac_registry_build_log WHERE status = 'failed';

SELECT raise_error(concat('facilities registry was NOT published. ', error_message))
FROM fac_registry_build_log WHERE status = 'failed' AND target_table LIKE '%registry%';


-- =============================================================================
-- [9] write both tables from the validated candidates
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_id_map_silver AS
SELECT * FROM public_health.silver.facilities_id_map_silver__candidate;

CREATE OR REPLACE TABLE public_health.silver.facilities_registry_silver AS
SELECT * FROM public_health.silver.facilities_registry_silver__candidate;


-- =============================================================================
-- [10] record the builds
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       -- Delta version just written. If your runtime rejects these lines, use CAST(NULL AS BIGINT).
       CASE WHEN target_table LIKE '%registry%'
            THEN (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_registry_silver))
            ELSE (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_id_map_silver)) END,
       code_version, parameters, run_id, error_message
FROM fac_registry_build_log;

-- the registry's inputs; the id map build read the same inputs
INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.facilities_registry_silver__inputs
UNION ALL
SELECT idmap_build_id, 'public_health.silver.facilities_id_map_silver', input_kind, input_table, input_table_version,
       source_key, source_file, source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.facilities_registry_silver__inputs
WHERE NOT (input_kind = 'table' AND input_table LIKE '%facilities_registry_silver');

-- bronze rows not loaded as themselves (staged in [5c]); loaded rows are not written (contract 7.1)
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
       content_checksum, disposition, reason, target_key, recorded_at
FROM public_health.silver.facilities_registry_silver__dispositions;


-- =============================================================================
-- [11] summary, then remove the staging tables (__classified, __records and __moved are kept
--      until the next run: they show how every bronze row was parsed and matched, and which
--      previous facilities were not carried forward)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_registry_summary AS
SELECT facility_category, facility_status, match_method, count(*) AS facilities,
       sum(analysis_beds) AS analysis_beds, count_if(geo_conflict_nhfr_hfsrb) AS geo_conflicts
FROM public_health.silver.facilities_registry_silver
GROUP BY facility_category, facility_status, match_method;

DROP TABLE IF EXISTS public_health.silver.facilities_registry_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.facilities_id_map_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.facilities_registry_silver__gates;
DROP TABLE IF EXISTS public_health.silver.facilities_registry_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.facilities_registry_silver__geo;
DROP TABLE IF EXISTS public_health.silver.facilities_registry_silver__records_pre;
DROP TABLE IF EXISTS public_health.silver.facilities_registry_silver__dispositions;

SELECT * FROM fac_registry_summary ORDER BY facility_category, facility_status, match_method;