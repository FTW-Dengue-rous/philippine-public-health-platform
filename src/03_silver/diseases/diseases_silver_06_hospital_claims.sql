-- =============================================================================
-- Builds public_health.silver.diseases_hospital_claims_silver (RESTRICTED, D-47: the request
-- FOI-REQ-2026-6223 committed to academic use, reported only in aggregate form. The release letter
-- sets no terms of its own. Gold publishes aggregates only and suppresses cells built from fewer
-- than 3 hospitals; the raw file is never redistributed or committed):
--   PhilHealth claims count and amount of one hospital, in one admission year, for one case-rate
--   package and one claim status.
--   Key: (year, facility_name_norm, area_key, disease_key, claim_status, _source_key)
-- Follows lineage-qc-contract.md v1.3 and the pattern of diseases_silver_05_tb_programme.sql
-- (classified -> inputs -> candidate -> dispositions -> gates -> build log -> write -> record).
--
-- Source: bronze diseases_philhealth_claims_hospital_bronze (sources_diseases.yaml entry 19,
--   philhealth_foi_claims_hospital, sheet FOI20266223, FOI-REQ-2026-6223).
--
-- What a row means
--   * Claims filed by the hospital, not patients or admissions. claims_count is all claims of that
--     status; utilisation = all statuses, money paid = claim_status 'paid' only.
--   * claims_amount_php is the amount CLAIMED (filled for every status), not the amount paid.
--   * Place = the hospital's city / municipality (location_basis 'facility_location'), not the
--     patient's residence. It shows where care is delivered.
--   * disease_key = the PhilHealth case-rate package (phic_*). related_condition_group in the
--     directory links packages to the other sources (dengue, pneumonia_lri, stroke, ...).
--
-- Rules
--   Area     (HF_Province, HF_Municipality) label pair -> diseases_area_map
--            (_source_key philhealth_foi_claims_hospital, parent_label_norm = province). The pairs
--            are resolved by build_diseases_reference_maps.py section 6b. A pair missing from the
--            map fails the build: rerun the builder.
--   Package  Illness_Description -> diseases_cause_map. A blank illness is QUARANTINED (reason
--            illness_missing; 1,404 rows when checked 2026-10-14, live count = warn gate "rows
--            quarantined" in build_log.parameters). An unknown package fails the build.
--   Repeats  Bronze rows with the same key are SUMMED (checked 2026-10-14: 112 key groups with
--            different numbers, 19 exact repeats; live count = warn gate "merged_into" in
--            build_log.parameters). The first row (lowest _source_row_num) carries the lineage; the
--            others get disposition merged_into with the silver key. source_rows says how many
--            bronze rows a silver row holds. Facility names are compared normalised
--            (case, punctuation, INC / CORP dropped), so spelling variants of one hospital in one
--            municipality are summed too.
--   Facility facility_key from facilities_registry_silver, by the hospital's normalised name:
--            1 name_lgu        same name (spaces, AND / & / THE / OF ignored, SAINT = ST) in the
--                              same city / municipality
--            2 name_province   same name, exactly one registry facility in the province
--                              (NCR: in the region)
--            3 name_tokens_lgu same city / municipality; after removing generic words (HOSPITAL,
--                              MEDICAL, ...) and the words of the place name, every word of the
--                              shorter name is in the other and they share 2+ words (or both have
--                              the same single word); exactly one such facility
--            otherwise 'unmatched' (facility_key null). A tier is used only when it gives exactly
--            one registry facility. Unmatched hospitals stay in the table (warn gate).
--   Flags    The years and package are settings in [0], recorded in build_log.parameters; a warn
--            gate in [5] fires when the data stops showing each rule.
--            is_covid_period (covid_year_from .. covid_year_to: claims drop by more than half),
--            is_amount_series_break (from amount_series_break_year: case rates changed),
--            is_preliminary (latest admission year in the file, derived at run time: claims still
--            being filed), is_package_definition_change (package_change_disease_key from
--            package_change_year; checked 2026-10-14: IHD with MI fell from 31,722 claims in 2024
--            to 6,164 in 2025, likely moved to another package).
--            Gold must show or filter these; silver keeps every year.
--
-- Needs: diseases_silver_00_reference.sql (area map, cause map, directory with the claims rows),
--   facilities_silver_01_registry.sql (facilities_registry_silver), quality_setup.sql,
--   bronze QC passed for philhealth_foi_claims_hospital.
-- =============================================================================

-- [0] settings and helpers
DECLARE OR REPLACE VARIABLE phc_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE phc_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;

-- Flag rules (rule 2a: source facts named here, recorded in build_log.parameters, and each one
-- guarded by a warn gate in [5] that fires when the data no longer shows it). Source:
-- sources_diseases.yaml entry 19 notes, checked against the file on 2026-10-14.
--   COVID period: the admission years where claims drop by more than half. This is a claims flag,
--   separate from the pandemic period in gold dim_date; the team agreed both as they are.
DECLARE OR REPLACE VARIABLE covid_year_from INT DEFAULT 2020;
DECLARE OR REPLACE VARIABLE covid_year_to INT DEFAULT 2021;
--   Case rates changed: the average claimed amount jumps from this admission year on.
DECLARE OR REPLACE VARIABLE amount_series_break_year INT DEFAULT 2024;
--   One package whose claims fall sharply from this year (likely moved to another package).
DECLARE OR REPLACE VARIABLE package_change_disease_key STRING DEFAULT 'phic_ihd_with_mi';
DECLARE OR REPLACE VARIABLE package_change_year INT DEFAULT 2025;

-- Same as diseases_silver_01_metric.sql (kept identical)
CREATE OR REPLACE TEMPORARY FUNCTION dz_norm(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(translate(upper(s), 'Ñ', 'N'), '[^A-Z0-9]', ' '), ' +', ' '));

-- Facility-name helpers: the same rules as fac_norm, fac_fname, fac_name_tokens, fac_name_similarity
-- and fac_lgu in facilities_silver_01_registry.sql (kept identical, renamed so both files can run
-- in one session)
CREATE OR REPLACE TEMPORARY FUNCTION phc_fac_norm(s STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(
         translate(upper(replace(replace(replace(replace(s, 'Ã±', 'N'), 'Ã‘', 'N'), 'ñ', 'N'), '?', 'N')), 'ÑÁÉÍÓÚ', 'NAEIOU'),
         '[^A-Z0-9]', ' '), ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION phc_fname(s STRING) RETURNS STRING
RETURN trim(regexp_replace(
  regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
    concat(' ', phc_fac_norm(s), ' '),
    ' HOSP ', ' HOSPITAL '), ' MED ', ' MEDICAL '), ' (CTR|CNTR) ', ' CENTER '), ' GEN ', ' GENERAL '),
    ' MEM ', ' MEMORIAL '), ' STO ', ' SANTO '), ' (INC|CORP|CORPORATION|CO) ', ' '),
  ' +', ' '));

CREATE OR REPLACE TEMPORARY FUNCTION phc_name_tokens(s STRING) RETURNS ARRAY<STRING>
RETURN array_distinct(filter(split(phc_fname(s), ' '), t -> length(t) > 1 AND NOT array_contains(array(
  'HOSPITAL', 'MEDICAL', 'CENTER', 'GENERAL', 'DISTRICT', 'PROVINCIAL', 'MEMORIAL', 'REGIONAL', 'CITY', 'OF', 'THE',
  'AND', 'DE', 'DEL', 'NG', 'SA', 'MATERNITY', 'CLINIC', 'INFIRMARY', 'HEALTH', 'CARE', 'DOCTORS', 'DR', 'ST',
  'SANTO', 'SAN', 'OPC', 'COMMUNITY', 'MUNICIPAL', 'HOSPITALS', 'SPECIALTY', 'FOUNDATION'), t)));

CREATE OR REPLACE TEMPORARY FUNCTION phc_name_similarity(a STRING, b STRING) RETURNS DOUBLE
RETURN CASE WHEN size(phc_name_tokens(a)) = 0 OR size(phc_name_tokens(b)) = 0 THEN NULL
            ELSE size(array_intersect(phc_name_tokens(a), phc_name_tokens(b)))
                 / least(size(phc_name_tokens(a)), size(phc_name_tokens(b))) END;

CREATE OR REPLACE TEMPORARY FUNCTION phc_lgu(code STRING) RETURNS STRING
RETURN CASE WHEN code RLIKE '^13806[0-9]{2}000$' THEN '1380600000' ELSE code END;

-- Comparison key for tiers 1 and 2: phc_fname without the words AND, THE, OF and the '&amp;' residue,
-- SAINT written ST, spaces removed ('CLINIC & INFIRMARY' = 'CLINIC AND INFIRMARY')
CREATE OR REPLACE TEMPORARY FUNCTION phc_name_key(s STRING) RETURNS STRING
RETURN replace(regexp_replace(regexp_replace(concat(' ', phc_fname(s), ' '),
         '(?<= )(AND|THE|OF|AMP)(?= )', ''), '(?<= )SAINT(?= )', 'ST'), ' ', '');

-- Distinctive words of a facility name without the words of its place (municipality and province
-- labels of the claims row): 'TACURONG CITY MEDICAL CLINIC' in Tacurong City has none left
CREATE OR REPLACE TEMPORARY FUNCTION phc_core_tokens(s STRING, place1 STRING, place2 STRING) RETURNS ARRAY<STRING>
RETURN array_except(phc_name_tokens(s), split(concat(dz_norm(place1), ' ', dz_norm(place2), ' CITY'), ' '));

-- Province of an LGU code for the name_province tier; NCR cities have no province: the region
CREATE OR REPLACE TEMPORARY FUNCTION phc_prov(code STRING) RETURNS STRING
RETURN CASE WHEN code LIKE '13%' THEN '13' ELSE substr(code, 1, 5) END;

-- Whole, non-negative number from text ('12', '12.0'); null otherwise
CREATE OR REPLACE TEMPORARY FUNCTION phc_int(s STRING) RETURNS BIGINT
RETURN CASE WHEN trim(s) RLIKE '^[0-9]+([.]0+)?$' THEN CAST(CAST(trim(s) AS DECIMAL(20,2)) AS BIGINT) END;


-- =============================================================================
-- [1] classify and parse every bronze row
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_claims_silver__classified AS
WITH b AS (
  SELECT 'public_health.bronze.diseases_philhealth_claims_hospital_bronze' AS input_table,
         _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at, _as_of_date,
         phc_int(Admit_Year) AS year,
         regexp_replace(trim(HF_Name), '\\s+', ' ') AS facility_name,
         phc_fname(HF_Name) AS facility_name_norm,
         trim(HF_Region) AS facility_region_label,
         regexp_replace(trim(HF_Province), '\\s+', ' ') AS province_label,
         regexp_replace(trim(HF_Municipality), '\\s+', ' ') AS municipality_label,
         dz_norm(HF_Province) AS province_norm, dz_norm(HF_Municipality) AS municipality_norm,
         upper(trim(HF_Sector)) AS sector_raw,
         trim(Illness_Description) AS illness_label, dz_norm(Illness_Description) AS illness_norm,
         upper(trim(Claim_Status)) AS claim_status_raw,
         phc_int(Claims_Count) AS claims_count,
         phc_int(Claims_Amount) AS claims_amount
  FROM public_health.bronze.diseases_philhealth_claims_hospital_bronze
  WHERE _source_key = 'philhealth_foi_claims_hospital'
)
SELECT b.*,
       a.area_key, a.psgc_code, a.geo_level, a.parent_area_key, a.geo_coverage_basis,
       cm.disease_key,
       CASE b.claim_status_raw WHEN 'PAID' THEN 'paid' WHEN 'DENIED' THEN 'denied'
            WHEN 'RTH' THEN 'returned_to_hospital' WHEN 'IN-PROCESS' THEN 'in_process' END AS claim_status,
       CASE b.sector_raw WHEN 'GOVERNMENT' THEN 'Government' WHEN 'PRIVATE' THEN 'Private' END AS ownership,
       CASE WHEN b.illness_norm IS NULL OR b.illness_norm = '' THEN 'quarantined' ELSE 'data' END AS row_class,
       CASE WHEN b.illness_norm IS NULL OR b.illness_norm = '' THEN 'illness_missing' END AS reason
FROM b
LEFT JOIN public_health.silver.diseases_area_map a
  ON a._source_key = 'philhealth_foi_claims_hospital' AND a.match_type = 'label'
 AND a.parent_label_norm = b.province_norm AND a.match_value = b.municipality_norm
LEFT JOIN public_health.silver.diseases_cause_map cm
  ON cm._source_key = 'philhealth_foi_claims_hospital' AND cm.match_type = 'label' AND cm.match_value = b.illness_norm;


-- =============================================================================
-- [2] inputs: the bronze file and the tables that shaped the build (layout of quality.build_inputs)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW phc_table_versions AS
SELECT 'public_health.bronze.diseases_philhealth_claims_hospital_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.diseases_philhealth_claims_hospital_bronze)) AS table_version
UNION ALL SELECT 'public_health.silver.diseases_area_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_area_map))
UNION ALL SELECT 'public_health.silver.diseases_cause_map',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_cause_map))
UNION ALL SELECT 'public_health.silver.diseases_directory_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_directory_silver))
UNION ALL SELECT 'public_health.silver.facilities_registry_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_registry_silver));

CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_claims_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.diseases_hospital_claims_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at)
SELECT phc_build_id AS build_id, 'public_health.silver.diseases_hospital_claims_silver' AS target_table,
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
LEFT JOIN phc_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
SELECT phc_build_id, 'public_health.silver.diseases_hospital_claims_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.diseases_area_map' AS table_name, count(*) AS n
        FROM public_health.silver.diseases_area_map WHERE _source_key = 'philhealth_foi_claims_hospital'
      UNION ALL SELECT 'public_health.silver.diseases_cause_map', count(*)
        FROM public_health.silver.diseases_cause_map WHERE _source_key = 'philhealth_foi_claims_hospital'
      UNION ALL SELECT 'public_health.silver.diseases_directory_silver', count(*) FROM public_health.silver.diseases_directory_silver
      UNION ALL SELECT 'public_health.silver.facilities_registry_silver', count(*) FROM public_health.silver.facilities_registry_silver) t
LEFT JOIN phc_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] facility match: one row per claims hospital (normalised name + city / municipality)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_claims_silver__facility AS
WITH c AS (
  SELECT facility_name_norm, area_key, phc_lgu(psgc_code) AS lgu,
         min(facility_name) AS facility_name, min(municipality_label) AS place1, min(province_label) AS place2,
         phc_name_key(min(facility_name)) AS name_key, sum(claims_count) AS claims
  FROM public_health.silver.diseases_hospital_claims_silver__classified
  WHERE row_class = 'data' AND area_key IS NOT NULL
  GROUP BY facility_name_norm, area_key, phc_lgu(psgc_code)),
r AS (
  SELECT facility_key, facility_category, facility_name, phc_name_key(facility_name) AS name_key,
         phc_lgu(psgc_code) AS lgu
  FROM public_health.silver.facilities_registry_silver
  WHERE facility_key IS NOT NULL AND psgc_code IS NOT NULL),
t1 AS (
  SELECT c.facility_name_norm, c.area_key, count(DISTINCT r.facility_key) AS n, max(r.facility_key) AS facility_key
  FROM c JOIN r ON r.name_key = c.name_key AND r.lgu = c.lgu
  GROUP BY c.facility_name_norm, c.area_key),
t2 AS (
  SELECT c.facility_name_norm, c.area_key, count(DISTINCT r.facility_key) AS n, max(r.facility_key) AS facility_key
  FROM c JOIN r ON r.name_key = c.name_key AND phc_prov(r.lgu) = phc_prov(c.lgu)
  GROUP BY c.facility_name_norm, c.area_key),
t3_pairs AS (
  SELECT c.facility_name_norm, c.area_key, r.facility_key,
         phc_core_tokens(c.facility_name, c.place1, c.place2) AS a,
         phc_core_tokens(r.facility_name, c.place1, c.place2) AS b
  FROM c JOIN r ON r.lgu = c.lgu),
t3 AS (
  SELECT facility_name_norm, area_key, count(DISTINCT facility_key) AS n, max(facility_key) AS facility_key
  FROM t3_pairs
  WHERE size(a) > 0 AND size(b) > 0
    AND size(array_intersect(a, b)) = least(size(a), size(b))                   -- shorter name inside the other
    AND (size(array_intersect(a, b)) >= 2 OR array_sort(a) = array_sort(b))
  GROUP BY facility_name_norm, area_key)
SELECT c.facility_name_norm, c.area_key, c.facility_name, c.claims,
       CASE WHEN t1.n = 1 THEN t1.facility_key WHEN t1.n IS NULL AND t2.n = 1 THEN t2.facility_key
            WHEN t1.n IS NULL AND t2.n IS NULL AND t3.n = 1 THEN t3.facility_key END AS facility_key,
       CASE WHEN t1.n = 1 THEN 'name_lgu' WHEN t1.n IS NULL AND t2.n = 1 THEN 'name_province'
            WHEN t1.n IS NULL AND t2.n IS NULL AND t3.n = 1 THEN 'name_tokens_lgu'
            WHEN coalesce(t1.n, t2.n, t3.n) > 1 THEN 'ambiguous'
            ELSE 'unmatched' END AS facility_match_method
FROM c
LEFT JOIN t1 ON t1.facility_name_norm = c.facility_name_norm AND t1.area_key = c.area_key
LEFT JOIN t2 ON t2.facility_name_norm = c.facility_name_norm AND t2.area_key = c.area_key
LEFT JOIN t3 ON t3.facility_name_norm = c.facility_name_norm AND t3.area_key = c.area_key;


-- =============================================================================
-- [4] candidate: data rows summed by the silver key; the first bronze row carries the lineage
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_claims_silver__candidate AS
WITH d AS (
  SELECT * FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE row_class = 'data'),
g AS (
  SELECT year, facility_name_norm, area_key, disease_key, claim_status, _source_key,
         min_by(struct(_source_file, _source_sheet, _source_row_num, _as_of_date, facility_name, ownership,
                       facility_region_label, province_label, municipality_label, illness_label,
                       psgc_code, geo_level, parent_area_key, geo_coverage_basis),
                _source_row_num) AS k,
         count(*) AS source_rows,
         count(DISTINCT ownership) AS n_ownership,
         sum(claims_count) AS claims_count,
         sum(claims_amount) AS claims_amount
  FROM d
  GROUP BY year, facility_name_norm, area_key, disease_key, claim_status, _source_key),
latest AS (SELECT max(year) AS y FROM d)
SELECT
  g.year, 'year' AS period_grain, CAST(g.year AS STRING) AS period_key,
  make_date(g.year, 1, 1) AS period_start, make_date(g.year, 12, 31) AS period_end,
  'admission_year' AS period_basis,
  g.k.facility_name AS facility_name, g.facility_name_norm,
  f.facility_key, f.facility_match_method,
  g.k.ownership AS ownership,
  g.area_key, g.k.municipality_label AS area_label_source, g.k.province_label AS province_label_source,
  g.k.facility_region_label AS region_label_source,
  g.k.psgc_code AS psgc_code, g.k.geo_level AS geo_level, g.k.parent_area_key AS parent_area_key,
  concat('psgc:', substr(g.k.psgc_code, 1, 2), '00000000') AS region_area_key,
  g.k.geo_coverage_basis AS geo_coverage_basis, 'facility_location' AS location_basis,
  g.disease_key, g.k.illness_label AS illness_package_source, dir.related_condition_group,
  g.claim_status,
  g.claims_count,
  CAST(g.claims_amount AS DECIMAL(20,2)) AS claims_amount_php,
  'amount_claimed' AS amount_basis,
  'claims_filed' AS measure_definition,
  g.source_rows,
  g.year BETWEEN covid_year_from AND covid_year_to AS is_covid_period,
  g.year >= amount_series_break_year AS is_amount_series_break,
  g.year = l.y AS is_preliminary,
  (g.disease_key = package_change_disease_key AND g.year >= package_change_year) AS is_package_definition_change,
  phc_build_id AS _silver_build_id,
  g._source_key, g.k._source_file AS _source_file, g.k._source_sheet AS _source_sheet,
  g.k._source_row_num AS _source_row_num, g.k._as_of_date AS _as_of_date,
  map('claims_count', 'Claims_Count', 'claims_amount_php', 'Claims_Amount') AS _metric_source_columns,
  g.n_ownership
FROM g
CROSS JOIN latest l
LEFT JOIN public_health.silver.diseases_hospital_claims_silver__facility f
  ON f.facility_name_norm = g.facility_name_norm AND f.area_key = g.area_key
LEFT JOIN public_health.silver.diseases_directory_silver dir ON dir.disease_key = g.disease_key;


-- =============================================================================
-- [4b] rows not loaded as themselves (contract v1.3, 7.1), saved before the gates.
--      merged_into rows contributed to a silver row (they count as loaded in the reconciliation).
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_claims_silver__dispositions AS
WITH m AS (
  SELECT c.*, row_number() OVER (PARTITION BY year, facility_name_norm, area_key, disease_key, claim_status, _source_key
                                 ORDER BY _source_row_num) AS rn
  FROM public_health.silver.diseases_hospital_claims_silver__classified c
  WHERE row_class = 'data')
SELECT phc_build_id AS build_id, 'public_health.silver.diseases_hospital_claims_silver' AS target_table,
       x._source_key AS source_key, x._source_file AS source_file, x._source_sheet AS source_sheet,
       x._source_row_num AS source_row_num, i.load_batch_id, i.content_checksum,
       x.disposition, x.reason, x.target_key, current_timestamp() AS recorded_at
FROM (
  SELECT _source_key, _source_file, _source_sheet, _source_row_num, 'quarantined' AS disposition, reason,
         CAST(NULL AS STRING) AS target_key
  FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE row_class = 'quarantined'
  UNION ALL
  SELECT _source_key, _source_file, _source_sheet, _source_row_num, 'merged_into', 'same_key_summed',
         to_json(named_struct('year', year, 'facility_name_norm', facility_name_norm, 'area_key', area_key,
                              'disease_key', disease_key, 'claim_status', claim_status))
  FROM m WHERE rn > 1) x
LEFT JOIN public_health.silver.diseases_hospital_claims_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = x._source_key AND i.source_file = x._source_file
 AND i.source_sheet <=> x._source_sheet;


-- =============================================================================
-- [5] gates. severity 'fail' stops the build; 'warn' is reported in build_log.parameters.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_claims_silver__gates AS
SELECT 'inputs: not exactly one bronze file' AS gate, 'fail' AS severity,
       CASE WHEN (SELECT count(*) FROM public_health.silver.diseases_hospital_claims_silver__inputs
                  WHERE input_kind = 'bronze_source') = 1 THEN 0 ELSE 1 END AS failures
UNION ALL
SELECT 'inputs: no processed ingestion log match, or more than one', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__inputs
  WHERE input_kind = 'bronze_source' AND (metadata_matches > 1 OR (metadata_matches = 0 AND strict_load_lookup))
UNION ALL
SELECT 'inputs: no area map or cause map rows for this source', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__inputs
  WHERE input_kind = 'table' AND input_table RLIKE 'diseases_(area|cause)_map$' AND input_rows = 0
UNION ALL
SELECT 'bronze row classified more than once', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_hospital_claims_silver__classified
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'Admit Year not a whole number', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE year IS NULL
UNION ALL
SELECT 'Claims Count or Claims Amount not a whole non-negative number', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE claims_count IS NULL OR claims_amount IS NULL
UNION ALL
SELECT 'Claim Status not PAID / DENIED / RTH / IN-PROCESS', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE claim_status IS NULL
UNION ALL
SELECT 'HF Sector not GOVERNMENT / PRIVATE', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE ownership IS NULL
UNION ALL
SELECT 'HF Name blank', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE facility_name_norm IS NULL OR facility_name_norm = ''
UNION ALL
SELECT 'province / municipality pair not in the area map (rerun build_diseases_reference_maps.py)', 'fail', count(*) FROM (
  SELECT DISTINCT province_norm, municipality_norm FROM public_health.silver.diseases_hospital_claims_silver__classified
  WHERE area_key IS NULL)
UNION ALL
SELECT 'illness package not in the cause map', 'fail', count(*) FROM (
  SELECT DISTINCT illness_norm FROM public_health.silver.diseases_hospital_claims_silver__classified
  WHERE row_class = 'data' AND disease_key IS NULL)
UNION ALL
SELECT 'disease_key not in the directory', 'fail', count(*) FROM (
  SELECT DISTINCT disease_key FROM public_health.silver.diseases_hospital_claims_silver__candidate) c
  LEFT ANTI JOIN public_health.silver.diseases_directory_silver d ON d.disease_key = c.disease_key
UNION ALL
SELECT 'one hospital-year-package-status with two sectors (GOVERNMENT and PRIVATE)', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__candidate WHERE n_ownership > 1
UNION ALL
SELECT 'key column null', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__candidate
  WHERE year IS NULL OR facility_name_norm IS NULL OR area_key IS NULL OR disease_key IS NULL
     OR claim_status IS NULL OR _source_key IS NULL
UNION ALL
SELECT 'key not unique', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.diseases_hospital_claims_silver__candidate
  GROUP BY year, facility_name_norm, area_key, disease_key, claim_status, _source_key HAVING count(*) > 1)
UNION ALL
SELECT 'lineage: a lineage column is null', 'fail', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _source_sheet IS NULL
     OR _source_row_num IS NULL OR _as_of_date IS NULL OR _metric_source_columns IS NULL
UNION ALL
-- output validation (contract 7.2)
SELECT 'output: source_rows of silver <> data rows of bronze', 'fail',
       abs((SELECT sum(source_rows) FROM public_health.silver.diseases_hospital_claims_silver__candidate)
         - (SELECT count(*) FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE row_class = 'data'))
UNION ALL
SELECT 'totals: claims count or amount per year, silver + quarantined <> bronze', 'fail', count(*) FROM (
  SELECT b.year FROM (
    SELECT year, sum(claims_count) AS n, sum(claims_amount) AS amt
    FROM public_health.silver.diseases_hospital_claims_silver__classified GROUP BY year) b
  LEFT JOIN (SELECT year, sum(claims_count) AS n, sum(claims_amount_php) AS amt
             FROM public_health.silver.diseases_hospital_claims_silver__candidate GROUP BY year) s ON s.year = b.year
  LEFT JOIN (SELECT year, sum(claims_count) AS n, sum(claims_amount) AS amt
             FROM public_health.silver.diseases_hospital_claims_silver__classified WHERE row_class = 'quarantined'
             GROUP BY year) q ON q.year = b.year
  WHERE b.n <> coalesce(s.n, 0) + coalesce(q.n, 0) OR b.amt <> coalesce(s.amt, 0) + coalesce(q.amt, 0))
UNION ALL
SELECT 'reconciliation: rows read - rows not loaded <> rows referenced by silver', 'fail', count(*)
FROM public_health.silver.diseases_hospital_claims_silver__inputs i
LEFT JOIN (SELECT _source_key, _source_file, _source_sheet, count(*) AS n FROM (
             SELECT DISTINCT _source_key, _source_file, _source_sheet, _source_row_num
             FROM public_health.silver.diseases_hospital_claims_silver__candidate)
           GROUP BY _source_key, _source_file, _source_sheet) ref
  ON ref._source_key = i.source_key AND ref._source_file = i.source_file AND ref._source_sheet <=> i.source_sheet
LEFT JOIN (SELECT source_key, source_file, source_sheet, count(*) AS n
           FROM public_health.silver.diseases_hospital_claims_silver__dispositions
           GROUP BY source_key, source_file, source_sheet) nl
  ON nl.source_key = i.source_key AND nl.source_file = i.source_file AND nl.source_sheet <=> i.source_sheet
WHERE i.input_kind = 'bronze_source' AND i.input_rows - coalesce(nl.n, 0) <> coalesce(ref.n, 0)
UNION ALL
-- warnings: reported, never block
SELECT 'warn: rows quarantined (illness blank)', 'warn', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__dispositions WHERE disposition = 'quarantined'
UNION ALL
SELECT 'warn: bronze rows summed into another row (merged_into)', 'warn', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__dispositions WHERE disposition = 'merged_into'
UNION ALL
SELECT 'warn: hospitals not matched to the facility registry', 'warn', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__facility WHERE facility_key IS NULL
UNION ALL
SELECT 'warn: percent of claims at hospitals not matched to the registry', 'warn',
       CAST(round(100 * coalesce(sum(CASE WHEN facility_key IS NULL THEN claims END), 0) / sum(claims)) AS BIGINT)
  FROM public_health.silver.diseases_hospital_claims_silver__facility
UNION ALL
SELECT 'warn: registry facility matched by more than one claims hospital name', 'warn', count(*) FROM (
  SELECT facility_key FROM public_health.silver.diseases_hospital_claims_silver__facility
  WHERE facility_key IS NOT NULL GROUP BY facility_key HAVING count(*) > 1)
UNION ALL
SELECT 'warn: area map rows resolved by a review rule (initials, spelling, other province, manual)', 'warn', count(*)
  FROM public_health.silver.diseases_area_map
  WHERE _source_key = 'philhealth_foi_claims_hospital' AND review_note LIKE '%REVIEW%'
UNION ALL
SELECT 'warn: claims count 0 with an amount, or a count with amount 0', 'warn', count(*)
  FROM public_health.silver.diseases_hospital_claims_silver__candidate
  WHERE (claims_count = 0) <> (claims_amount_php = 0)
UNION ALL
-- the flag rules in [0] still match the data (1 = the rule is no longer visible: review it)
SELECT 'warn: COVID flag - claims in covid_year_from not below half of the year before', 'warn',
       CASE WHEN sum(CASE WHEN year = covid_year_from THEN claims_count END)
                 < 0.5 * sum(CASE WHEN year = covid_year_from - 1 THEN claims_count END) THEN 0 ELSE 1 END
  FROM public_health.silver.diseases_hospital_claims_silver__candidate
UNION ALL
SELECT 'warn: amount break flag - average claimed amount in amount_series_break_year not above the year before', 'warn',
       CASE WHEN sum(CASE WHEN year = amount_series_break_year THEN claims_amount_php END)
                 / sum(CASE WHEN year = amount_series_break_year THEN claims_count END)
               > sum(CASE WHEN year = amount_series_break_year - 1 THEN claims_amount_php END)
                 / sum(CASE WHEN year = amount_series_break_year - 1 THEN claims_count END) THEN 0 ELSE 1 END
  FROM public_health.silver.diseases_hospital_claims_silver__candidate
UNION ALL
SELECT 'warn: package change flag - package_change_disease_key claims in package_change_year not below half of the year before', 'warn',
       CASE WHEN sum(CASE WHEN year = package_change_year THEN claims_count END)
                 < 0.5 * sum(CASE WHEN year = package_change_year - 1 THEN claims_count END) THEN 0 ELSE 1 END
  FROM public_health.silver.diseases_hospital_claims_silver__candidate
  WHERE disease_key = package_change_disease_key;


-- =============================================================================
-- [6] build log row; stop if a gate failed (the failed build is logged first)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW phc_build_log AS
SELECT phc_build_id AS build_id, 'silver' AS layer, 'diseases' AS domain,
       'public_health.silver.diseases_hospital_claims_silver' AS target_table,
       phc_build_started_at AS started_at, current_timestamp() AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.diseases_hospital_claims_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT) AS target_table_version, code_version AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup,
                            'covid_years', concat(covid_year_from, '-', covid_year_to),
                            'amount_series_break_year', amount_series_break_year,
                            'package_change', concat(package_change_disease_key, ' from ', package_change_year),
                            'warnings', g.warn_names)) AS parameters,
       job_run_id AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0 AND severity = 'fail') AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'fail' THEN concat(gate, ' = ', failures) END)) AS failed_names,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'warn' THEN concat(gate, ' = ', failures) END)) AS warn_names
      FROM public_health.silver.diseases_hospital_claims_silver__gates) g;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM phc_build_log WHERE status = 'failed';

SELECT raise_error(concat('diseases_hospital_claims_silver was NOT published. ', error_message))
FROM phc_build_log WHERE status = 'failed';


-- =============================================================================
-- [7] write (full rebuild). n_ownership is a gate column only.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.diseases_hospital_claims_silver AS
SELECT * EXCEPT (n_ownership) FROM public_health.silver.diseases_hospital_claims_silver__candidate;


-- =============================================================================
-- [8] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.diseases_hospital_claims_silver),
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.diseases_hospital_claims_silver)),
       code_version, parameters, run_id, error_message
FROM phc_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.diseases_hospital_claims_silver__inputs;

INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
       content_checksum, disposition, reason, target_key, recorded_at
FROM public_health.silver.diseases_hospital_claims_silver__dispositions;


-- =============================================================================
-- [9] summary and warnings (counts only); drop the staging tables
--     (__classified and __facility are kept until the next run: they show how each bronze row
--      and each hospital was resolved)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW phc_summary AS
SELECT year, count(*) AS silver_rows, sum(claims_count) AS claims, sum(claims_amount_php) AS amount_claimed_php,
       sum(CASE WHEN claim_status = 'paid' THEN claims_count END) AS claims_paid,
       count(DISTINCT facility_name_norm, area_key) AS hospitals,
       sum(CASE WHEN facility_key IS NULL THEN claims_count END) AS claims_at_unmatched_hospitals
FROM public_health.silver.diseases_hospital_claims_silver
GROUP BY year;

SELECT gate, failures FROM public_health.silver.diseases_hospital_claims_silver__gates WHERE severity = 'warn';

DROP TABLE IF EXISTS public_health.silver.diseases_hospital_claims_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.diseases_hospital_claims_silver__gates;
DROP TABLE IF EXISTS public_health.silver.diseases_hospital_claims_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.diseases_hospital_claims_silver__dispositions;

SELECT * FROM phc_summary ORDER BY year;
