-- =============================================================================
-- Builds public_health.silver.facilities_bed_occupancy_silver:
--   one anonymous hospital record (no name, no code) of one year from the HFSRB bed file.
--   Key: (_source_key, _source_file, _source_sheet, _source_row_num). The records are
--   anonymous, so the lineage columns are the key; identical rows are kept apart (plan 3, 5.2).
-- Follows facilities-silver-plan.md v2.1 (section 3: occupancy definitions) and lineage-qc-contract.md
-- v1.3 (lineage columns are the key here; build_log / build_inputs per build; row_disposition holds
-- only the bronze rows that were NOT loaded).
-- Run order: 00a -> build_facilities_area_exceptions.py (when inputs change) -> 00 -> 01 -> 02 -> [03] -> 04a -> 04
--
-- SHARING: restricted. FOI release (DOH-984883683631, HFSRB, 2026-10-14) with no stated terms.
-- Keep the table's access limited and publish only aggregates with small cells suppressed.
--
-- Source (changed 2026-10-14): sources_facilities.yaml entry 12a, doh_foi_hospital_beds, one
-- workbook with sheets 2018-2025. It replaces entry 12 (bed_occupancy, 2020-2025), whose rows stay
-- in the same bronze table for lineage but are no longer read here.
--   Every sheet: government and private hospitals, region / province / city-municipality,
--   hospital type (General / Specialty), level, authorized beds, implementing beds, BOR (based on
--   authorized beds) and inpatient bed days. Reporting hospitals only (1,093 to 1,210 records a year in
--   the 2018-2025 file, checked 2026-10-14; live counts in the summary at the end).
--   BOR = bed days / (authorized beds x days in the year) x 100: a warn gate checks it per row.
--   The 2025 records remain the preferred CANDIDATE occupancy baseline, subject to validation of
--   bed definitions, duplicate records and reporting coverage (decision D6); 2018-2024 are now a
--   comparable series (same layout, both ownerships).
--   Header quirk: the column "Service Capability" holds General / Specialty, the column "General"
--   holds the level (Level 1 / 2 / 3 Hospital).
--
-- Build sequence: [0] settings  [1] classify  [2] inputs  [3] areas  [4] candidate
--                 [4b] dispositions  [5] gates  [6] build log  [7] STOP on failure  [8] write  [9] record  [10] summary
-- Needs: facilities_silver_00_reference.sql (exceptions), quality_setup.sql, geography silver, bronze QC.
-- Status: rewritten 2026-10-14 for doh_foi_hospital_beds
-- =============================================================================

-- [0] settings
DECLARE OR REPLACE VARIABLE bor_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;
-- BOR above this value is kept and flagged but is not eligible for the baseline (plan 3.3).
-- The exclusion_reason value is named 'bor_gt_150' (QC S24 and gold read it): a gate stops the build
-- if this setting changes without renaming that value.
DECLARE OR REPLACE VARIABLE bor_baseline_max DECIMAL(7,2) DEFAULT 150;
-- Sheets (years) the release must hold, once each. Was typed inside the gate until 2026-10-19
-- (rule 2a); a new release with another year range changes this setting and the YAML files: list.
DECLARE OR REPLACE VARIABLE bor_expected_sheets ARRAY<STRING>
  DEFAULT array('2018', '2019', '2020', '2021', '2022', '2023', '2024', '2025');
-- the bronze source this build reads (sources_facilities.yaml entry 12a)
DECLARE OR REPLACE VARIABLE bor_source_key STRING DEFAULT 'doh_foi_hospital_beds';
DECLARE OR REPLACE VARIABLE geography_checksum STRING;
SET VARIABLE geography_checksum =
  (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

-- Same helper functions as facilities_silver_01_registry.sql (kept identical)
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

CREATE OR REPLACE TEMPORARY FUNCTION fac_parse_error(s STRING) RETURNS INT
RETURN CASE WHEN s IS NULL OR trim(s) = '' THEN 0
            WHEN try_cast(regexp_replace(trim(s), '[ ,]', '') AS DECIMAL(20,4)) IS NOT NULL THEN 0 ELSE 1 END;

CREATE OR REPLACE TEMPORARY FUNCTION fac_region_psgc(s STRING) RETURNS STRING
RETURN CASE
  WHEN fac_norm(s) RLIKE '(^| )(NCR|N C R|NATIONAL CAPITAL|METRO MANILA)( |$)'           THEN '1300000000'
  WHEN fac_norm(s) RLIKE '(^| )(CAR|C A R|CORDILLERA)( |$)'                               THEN '1400000000'
  WHEN fac_norm(s) RLIKE '(^| )(BARMM|ARMM|BANGSAMORO|AUTONOMOUS REGION IN MUSLIM MINDANAO)( |$)' THEN '1900000000'
  WHEN fac_norm(s) RLIKE '(^| )(NIR|NEGROS ISLAND)( |$)'                                  THEN '1800000000'
  WHEN fac_norm(s) RLIKE '(^| )(MIMAROPA|IV B|4 B|4B|IVB)( |$)'                           THEN '1700000000'
  WHEN fac_norm(s) RLIKE '(^| )(CARAGA|XIII|13)( |$)'                                     THEN '1600000000'
  WHEN fac_norm(s) RLIKE '(^| )(CALABARZON|IV A|4 A|4A|IVA)( |$)'                         THEN '0400000000'
  ELSE CASE regexp_extract(fac_norm(s), '^REGION ([IVX]+|[0-9]+)( |$)', 1)
         WHEN 'I' THEN '0100000000' WHEN '1' THEN '0100000000' WHEN 'II' THEN '0200000000' WHEN '2' THEN '0200000000'
         WHEN 'III' THEN '0300000000' WHEN '3' THEN '0300000000' WHEN 'V' THEN '0500000000' WHEN '5' THEN '0500000000'
         WHEN 'VI' THEN '0600000000' WHEN '6' THEN '0600000000' WHEN 'VII' THEN '0700000000' WHEN '7' THEN '0700000000'
         WHEN 'VIII' THEN '0800000000' WHEN '8' THEN '0800000000' WHEN 'IX' THEN '0900000000' WHEN '9' THEN '0900000000'
         WHEN 'X' THEN '1000000000' WHEN '10' THEN '1000000000' WHEN 'XI' THEN '1100000000' WHEN '11' THEN '1100000000'
         WHEN 'XII' THEN '1200000000' WHEN '12' THEN '1200000000' END
  END;

CREATE OR REPLACE TEMP VIEW fac_geo AS
SELECT psgc_code,
       CASE geographic_level WHEN 'Reg' THEN 'region' WHEN 'Prov' THEN 'province' WHEN 'City' THEN 'city'
            WHEN 'Mun' THEN 'municipality' WHEN 'SubMun' THEN 'submunicipality' WHEN 'Bgy' THEN 'barangay' END AS geo_level,
       city_class, fac_place_key(area_name) AS place_norm,
       concat(substr(psgc_code, 1, 2), '00000000') AS region_psgc,
       CASE WHEN geographic_level IN ('City', 'Mun') AND coalesce(city_class, '') <> 'HUC'
            THEN concat(substr(psgc_code, 1, 5), '00000') END AS province_psgc
FROM public_health.silver.geography_silver
WHERE content_checksum = geography_checksum;


-- =============================================================================
-- [1] classify: every row with a region label is a hospital record
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver__classified AS
SELECT 'public_health.bronze.facilities_bed_occupancy_bronze' AS input_table, t.*,
       try_cast(trim(_source_sheet) AS INT) AS sheet_year,
       CASE WHEN Region IS NOT NULL THEN 'data' ELSE 'non_data' END AS row_class,
       CASE WHEN Region IS NULL THEN 'blank_or_note' END AS reason
FROM public_health.bronze.facilities_bed_occupancy_bronze t
WHERE _source_key = bor_source_key;


-- =============================================================================
-- [2] inputs
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_bor_table_versions AS
SELECT 'public_health.bronze.facilities_bed_occupancy_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.facilities_bed_occupancy_bronze)) AS table_version
UNION ALL SELECT 'public_health.silver.geography_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.geography_silver))
UNION ALL SELECT 'public_health.silver.facilities_area_exceptions',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_area_exceptions));

CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.facilities_bed_occupancy_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at
)
SELECT bor_build_id AS build_id, 'public_health.silver.facilities_bed_occupancy_silver' AS target_table,
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
LEFT JOIN fac_bor_table_versions v ON v.table_name = f.input_table
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
SELECT bor_build_id, 'public_health.silver.facilities_bed_occupancy_silver', 'table', t.table_name, v.table_version,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CASE WHEN t.table_name LIKE '%geography_silver' THEN geography_checksum END,
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.geography_silver' AS table_name, count(*) AS n FROM fac_geo
      UNION ALL SELECT 'public_health.silver.facilities_area_exceptions', count(*) FROM public_health.silver.facilities_area_exceptions) t
LEFT JOIN fac_bor_table_versions v ON v.table_name = t.table_name;


-- =============================================================================
-- [3] areas
--   province unit (every year): the Province/District label -> province, or a city / NCR district
--     printed in that column (exceptions, source_group 'bor', match_type 'province_label').
--     The unit is AS PRINTED: a highly urbanized city sits under its geographic province, so a
--     record kept at province level (city label not resolved) includes those cities (geo_coverage_basis).
--   city / municipality (every year): name within the province, else the region, else the country.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver__geo AS
WITH r AS (
  SELECT _source_file, _source_sheet, _source_row_num, sheet_year,
         fac_region_psgc(Region) AS region_psgc,
         fac_norm(`Province/District`) AS prov_norm, fac_place_key(`Province/District`) AS prov_place,
         `City/Municipality` AS city_label, fac_place_key(`City/Municipality`) AS city_place,
         fac_city_hint(`City/Municipality`) AS city_hint
  FROM public_health.silver.facilities_bed_occupancy_silver__classified WHERE row_class = 'data'
),
pe AS (SELECT * FROM public_health.silver.facilities_area_exceptions WHERE source_group = 'bor' AND match_type = 'province_label'),
-- labels whose exception row is not usable (needs_review / rejected, loaded as 'unresolvable'):
-- the record is quarantined, never matched by its name
pu AS (SELECT * FROM public_health.silver.facilities_area_exceptions WHERE source_group = 'bor' AND match_type = 'unresolvable'),
p_reg AS (
  SELECT r._source_sheet, r._source_row_num, count(*) AS n, max(g.psgc_code) AS psgc_code
  FROM r JOIN fac_geo g ON g.geo_level = 'province' AND g.region_psgc = r.region_psgc AND g.place_norm = r.prov_place
  GROUP BY r._source_sheet, r._source_row_num
),
p_any AS (   -- e.g. NEGROS OCCIDENTAL printed under Region VI, now in the Negros Island Region
  SELECT r._source_sheet, r._source_row_num, count(*) AS n, max(g.psgc_code) AS psgc_code
  FROM r JOIN fac_geo g ON g.geo_level = 'province' AND g.place_norm = r.prov_place
  GROUP BY r._source_sheet, r._source_row_num
),
rp AS (
  SELECT r.*,
         coalesce(pe.psgc_code, CASE WHEN pr.n = 1 THEN pr.psgc_code END, CASE WHEN pr.n IS NULL AND pa.n = 1 THEN pa.psgc_code END) AS prov_psgc,
         pe.area_key AS prov_named_key,
         CASE WHEN pe.match_value IS NOT NULL THEN 'exception' WHEN pr.n = 1 THEN 'name_level_parent'
              WHEN pr.n IS NULL AND pa.n = 1 THEN 'name_level_other_region' END AS prov_method,
         CASE WHEN pu.match_value IS NOT NULL THEN concat('place_', coalesce(pu.review_status, 'needs_review')) END AS quarantine_reason
  FROM r
  LEFT JOIN pe ON pe.match_value = r.prov_norm
  LEFT JOIN pu ON pu.match_value = r.prov_norm AND pu.parent_label_norm IS NULL
  LEFT JOIN p_reg pr ON pr._source_sheet = r._source_sheet AND pr._source_row_num = r._source_row_num
  LEFT JOIN p_any pa ON pa._source_sheet = r._source_sheet AND pa._source_row_num = r._source_row_num
),
cand AS (
  SELECT rp._source_sheet, rp._source_row_num, g.psgc_code,
         CASE WHEN g.province_psgc = rp.prov_psgc OR g.psgc_code = rp.prov_psgc THEN 4
              WHEN g.region_psgc = rp.region_psgc THEN 2 ELSE 0 END
       + CASE WHEN rp.city_hint AND g.geo_level = 'city' THEN 1
              WHEN NOT rp.city_hint AND g.geo_level IN ('municipality', 'submunicipality') THEN 1 ELSE 0 END AS score
  FROM rp JOIN fac_geo g
    ON rp.city_label IS NOT NULL AND g.geo_level IN ('city', 'municipality', 'submunicipality') AND g.place_norm = rp.city_place
),
best AS (
  SELECT _source_sheet, _source_row_num, count_if(score = max_s) AS n_best, max_by(psgc_code, score) AS best_psgc,
         max(max_s) AS best_score, array_join(array_sort(collect_list(psgc_code)), ',') AS candidates
  FROM (SELECT *, max(score) OVER (PARTITION BY _source_sheet, _source_row_num) AS max_s FROM cand)
  GROUP BY _source_sheet, _source_row_num
),
ce AS (SELECT * FROM public_health.silver.facilities_area_exceptions WHERE source_group = 'bor' AND match_type = 'area_label')
SELECT rp._source_file, rp._source_sheet, rp._source_row_num,
       coalesce(concat('psgc:', rp.prov_psgc), rp.prov_named_key) AS province_unit_key,
       rp.prov_method,
       coalesce(ce.psgc_code, CASE WHEN b.n_best = 1 THEN b.best_psgc END) AS city_psgc,
       CASE WHEN ce.psgc_code IS NOT NULL THEN 'exception'
            WHEN b.n_best = 1 AND b.best_score >= 4 THEN 'name_level_parent'
            WHEN b.n_best = 1 THEN 'name_level_other_region' END AS city_method,
       b.candidates AS city_candidates,
       rp.city_label,
       rp.quarantine_reason
FROM rp
LEFT JOIN best b ON b._source_sheet = rp._source_sheet AND b._source_row_num = rp._source_row_num
LEFT JOIN ce ON ce.match_value = fac_norm(rp.city_label) AND ce.parent_label_norm <=> rp.prov_norm;


-- =============================================================================
-- [4] candidate rows
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver__candidate AS
WITH d AS (
  SELECT c.*, g.province_unit_key, g.prov_method, g.city_psgc, g.city_method, g.city_candidates,
         fac_num(c.Bed_Occupancy_Rate_BOR_Based_on_Authorized_Beds) AS bor,
         fac_num(c.Total_number_of_inpatient_bed_days_service_days) AS bed_days,
         fac_num(c.Authorized_Bed_Capacity) AS abc,
         dayofyear(make_date(c.sheet_year, 12, 31)) AS days_in_year,
         -- identical rows in one sheet: the first is kept for the baseline, the others are flagged
         row_number() OVER (PARTITION BY c._source_file, c._source_sheet, c.Region, c.`Province/District`,
                                         c.`City/Municipality`, c.General, c.Nature_of_Ownership,
                                         c.Bed_Occupancy_Rate_BOR_Based_on_Authorized_Beds,
                                         c.Authorized_Bed_Capacity, c.Implementing_Beds,
                                         c.Service_Capability, c.Total_number_of_inpatient_bed_days_service_days
                            ORDER BY c._source_row_num) AS copy_no
  FROM public_health.silver.facilities_bed_occupancy_silver__classified c
  JOIN public_health.silver.facilities_bed_occupancy_silver__geo g
    ON g._source_file = c._source_file AND g._source_sheet <=> c._source_sheet AND g._source_row_num = c._source_row_num
  WHERE c.row_class = 'data' AND g.quarantine_reason IS NULL
)
SELECT
  sheet_year                                                        AS year,
  make_date(sheet_year, 1, 1)                                       AS reporting_period_start,   -- assumed
  make_date(sheet_year, 12, 31)                                     AS reporting_period_end,     -- assumed
  false                                                             AS period_confirmed,
  -- finest area available: city / municipality, else the province unit
  coalesce(concat('psgc:', city_psgc), province_unit_key)           AS area_key,
  coalesce(city_psgc, CASE WHEN province_unit_key LIKE 'psgc:%' THEN substr(province_unit_key, 6) END) AS psgc_code,
  CASE WHEN city_psgc IS NOT NULL THEN 'city_municipality' ELSE 'province_or_district' END AS area_level_published,
  coalesce(trim(`City/Municipality`), trim(`Province/District`))    AS geo_name_source,
  coalesce(city_method, prov_method)                                AS geo_resolution_method,
  province_unit_key,
  trim(`Province/District`)                                         AS province_label_source,
  trim(Region)                                                      AS region_as_published,
  CASE WHEN city_psgc IS NOT NULL THEN 'city_municipality'
       WHEN province_unit_key LIKE 'ncr-district:%' THEN 'ncr_district'
       ELSE 'province_incl_cities_as_reported' END                  AS geo_coverage_basis,
  regexp_extract(General, '(Level [1-3])', 1)                       AS service_level,
  initcap(trim(Service_Capability))                                 AS hospital_type,            -- General / Specialty
  lower(trim(Nature_of_Ownership))                                  AS ownership,
  CAST(bor AS DECIMAL(7,2))                                         AS bor_pct,
  'authorized'                                                      AS bor_bed_basis,            -- per the column header
  false                                                             AS bor_basis_confirmed,
  CAST(abc AS INT)                                                  AS authorized_beds,
  CAST(fac_num(Implementing_Beds) AS INT)                           AS implementing_beds,
  CAST(bed_days AS BIGINT)                                          AS inpatient_bed_days,        -- service days in the year
  days_in_year,
  (bor > 100)                                                       AS is_bor_over_100,
  (copy_no > 1)                                                     AS is_exact_duplicate_in_sheet,
  CASE WHEN bor IS NULL THEN 'bor_null'
       WHEN bor < 0 THEN 'bor_negative'
       WHEN bor > bor_baseline_max THEN 'bor_gt_150'
       -- a specialty hospital has no level in the source: only a general hospital needs one
       WHEN (regexp_extract(General, '(Level [1-3])', 1) = '' OR General IS NULL)
            AND initcap(trim(Service_Capability)) = 'General' THEN 'level_missing'
       WHEN copy_no > 1 THEN 'exact_duplicate' END                  AS exclusion_reason,
  'restricted'                                                      AS sharing,
  bor_build_id                                                      AS _silver_build_id,
  _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
  map('bor_pct', 'Bed_Occupancy_Rate_BOR_Based_on_Authorized_Beds',
      'authorized_beds', 'Authorized_Bed_Capacity', 'implementing_beds', 'Implementing_Beds',
      'inpatient_bed_days', 'Total_number_of_inpatient_bed_days_service_days',
      'service_level', 'General', 'hospital_type', 'Service_Capability',
      'ownership', 'Nature_of_Ownership')                           AS _metric_source_columns,
  -- validation only
  fac_parse_error(Bed_Occupancy_Rate_BOR_Based_on_Authorized_Beds) + fac_parse_error(Authorized_Bed_Capacity)
    + fac_parse_error(Implementing_Beds)
    + fac_parse_error(Total_number_of_inpatient_bed_days_service_days) AS parse_errors,
  -- published BOR minus the BOR recomputed from bed days (null when either is missing)
  CASE WHEN abc > 0 AND bed_days IS NOT NULL AND bor IS NOT NULL
       THEN bor - bed_days / (abc * days_in_year) * 100 END        AS bor_check_diff,
  city_candidates,
  `City/Municipality` AS city_label_raw
FROM d;

-- baseline_eligible is derived from exclusion_reason so the two can never disagree
CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver__candidate2 AS
SELECT c.* EXCEPT (exclusion_reason, sharing, _silver_build_id, _source_key, _source_file, _source_sheet,
                   _source_row_num, _as_of_date, _metric_source_columns, parse_errors, bor_check_diff,
                   city_candidates, city_label_raw),
       (exclusion_reason IS NULL) AS baseline_eligible, exclusion_reason, sharing,
       _silver_build_id, _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns,
       parse_errors, bor_check_diff, city_candidates, city_label_raw
FROM public_health.silver.facilities_bed_occupancy_silver__candidate c;


-- =============================================================================
-- [4b] dispositions (lineage-qc-contract.md v1.3, section 7.1): one row per bronze row that was
--      NOT loaded. Loaded rows are not stored: the silver rows carry their bronze row reference, and
--      rows loaded per input = input_rows - rows here (quality.v_build_reconciliation).
--      Every data row is loaded (ineligible and identical rows too: eligibility is a flag), except
--      records whose Province/District label is not verified (quarantined).
--      Saved before the gates, so the gates check exactly what step [9] writes.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver__dispositions AS
SELECT bor_build_id AS build_id, 'public_health.silver.facilities_bed_occupancy_silver' AS target_table,
       c._source_key AS source_key, c._source_file AS source_file, c._source_sheet AS source_sheet,
       c._source_row_num AS source_row_num, i.load_batch_id, i.content_checksum,
       'dropped_non_data' AS disposition, c.reason, CAST(NULL AS STRING) AS target_key,
       current_timestamp() AS recorded_at
FROM public_health.silver.facilities_bed_occupancy_silver__classified c
LEFT JOIN public_health.silver.facilities_bed_occupancy_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data'
UNION ALL
-- records whose Province/District label is not verified (exceptions file, review_status not usable)
SELECT bor_build_id, 'public_health.silver.facilities_bed_occupancy_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num, i.load_batch_id, i.content_checksum,
       'quarantined', g.quarantine_reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.facilities_bed_occupancy_silver__classified c
JOIN public_health.silver.facilities_bed_occupancy_silver__geo g
  ON g._source_file = c._source_file AND g._source_sheet <=> c._source_sheet AND g._source_row_num = c._source_row_num
LEFT JOIN public_health.silver.facilities_bed_occupancy_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE g.quarantine_reason IS NOT NULL;


-- =============================================================================
-- [5] gates
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver__gates AS
SELECT 'inputs: every sheet in bor_expected_sheets is read, once each, and no other' AS gate, 'fail' AS severity,
       CASE WHEN (SELECT count(DISTINCT source_sheet) FROM public_health.silver.facilities_bed_occupancy_silver__inputs
                  WHERE input_kind = 'bronze_source' AND array_contains(bor_expected_sheets, source_sheet)) = size(bor_expected_sheets)
             AND (SELECT count(*) FROM public_health.silver.facilities_bed_occupancy_silver__inputs WHERE input_kind = 'bronze_source')
                 = size(bor_expected_sheets)
            THEN 0 ELSE 1 END AS failures
UNION ALL
SELECT 'setting: bor_baseline_max is not 150 but the exclusion reason is named bor_gt_150 (rename both)', 'fail',
       CASE WHEN bor_baseline_max = 150 THEN 0 ELSE 1 END
UNION ALL
SELECT 'inputs: more than one ingestion log match', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__inputs
  WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'sheet name is not a year', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__classified WHERE sheet_year IS NULL
UNION ALL
SELECT 'region label not recognised', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__classified
  WHERE row_class = 'data' AND fac_region_psgc(Region) IS NULL
UNION ALL
-- rule 2a (2026-10-19): the region codes typed in fac_region_psgc must still be regions of geography
SELECT 'region rule gives a code that is not a region of the geography snapshot', 'fail', count(*) FROM (
  SELECT DISTINCT fac_region_psgc(Region) AS region_psgc
  FROM public_health.silver.facilities_bed_occupancy_silver__classified WHERE row_class = 'data') r
  LEFT ANTI JOIN fac_geo g ON g.psgc_code = r.region_psgc AND g.geo_level = 'region'
  WHERE r.region_psgc IS NOT NULL
UNION ALL
SELECT 'province / district not resolved (add a bor province_label exception)', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2 WHERE province_unit_key IS NULL
UNION ALL
SELECT 'cell that is not a number', 'fail', coalesce(sum(parse_errors), 0)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2
UNION ALL
SELECT 'ownership not government / private', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2 WHERE ownership NOT IN ('government', 'private') OR ownership IS NULL
UNION ALL
SELECT 'hospital type not General / Specialty (column layout moved?)', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2 WHERE hospital_type NOT IN ('General', 'Specialty') OR hospital_type IS NULL
UNION ALL
SELECT 'level column holds something other than Level 1 / 2 / 3 Hospital (column layout moved?)', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__classified
  WHERE row_class = 'data' AND General IS NOT NULL AND NOT General RLIKE '^Level [1-3] Hospital$'
UNION ALL
SELECT 'negative beds or bed days', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2
  WHERE authorized_beds < 0 OR implementing_beds < 0 OR inpatient_bed_days < 0
UNION ALL
SELECT 'key not unique', 'fail', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_bed_occupancy_silver__candidate2
  GROUP BY _source_key, _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)
UNION ALL
SELECT 'lineage: a lineage column is null', 'fail', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2
  WHERE _silver_build_id IS NULL OR _source_key IS NULL OR _source_file IS NULL OR _source_sheet IS NULL
     OR _source_row_num IS NULL OR _as_of_date IS NULL OR _metric_source_columns IS NULL
UNION ALL
-- contract 7.1, per input: distinct bronze rows referenced by silver = rows read - rows not loaded
SELECT 'reconciliation: inputs where rows referenced by silver <> rows read - rows not loaded', 'fail', count(*)
FROM public_health.silver.facilities_bed_occupancy_silver__inputs i
LEFT JOIN (
  SELECT _source_key, _source_file, _source_sheet, count(*) AS n FROM (
    SELECT DISTINCT _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.silver.facilities_bed_occupancy_silver__candidate2)
  GROUP BY _source_key, _source_file, _source_sheet) ref
  ON ref._source_key = i.source_key AND ref._source_file = i.source_file AND ref._source_sheet <=> i.source_sheet
LEFT JOIN (
  SELECT source_key, source_file, source_sheet, count(*) AS n
  FROM public_health.silver.facilities_bed_occupancy_silver__dispositions GROUP BY source_key, source_file, source_sheet) nl
  ON nl.source_key = i.source_key AND nl.source_file = i.source_file AND nl.source_sheet <=> i.source_sheet
WHERE i.input_kind = 'bronze_source' AND i.input_rows - coalesce(nl.n, 0) <> coalesce(ref.n, 0)
UNION ALL
SELECT 'output: silver rows <> bronze data rows', 'fail',
       abs((SELECT count(*) FROM public_health.silver.facilities_bed_occupancy_silver__candidate2)
         - (SELECT count_if(row_class = 'data') FROM public_health.silver.facilities_bed_occupancy_silver__classified)
         + (SELECT count(*) FROM public_health.silver.facilities_bed_occupancy_silver__geo WHERE quarantine_reason IS NOT NULL))
UNION ALL
-- controls for doh_foi_hospital_beds_municipality_annual_2018_2025.xlsx (FOI DOH-984883683631): the
-- per-sheet counts add up to the YAML qc.expected_rows (9,145); the 2025 control is in the YAML notes.
-- They belong to this file: a new release changes them with the YAML.
SELECT 'control: data rows per sheet (2018 1,098 ... 2025 1,209; silver + quarantined)', 'fail', count(*)
  FROM (SELECT * FROM VALUES (2018, 1098), (2019, 1093), (2020, 1101), (2021, 1127), (2022, 1128), (2023, 1179),
                             (2024, 1210), (2025, 1209) AS t(y, n)) e
  LEFT JOIN (SELECT sheet_year, count_if(row_class = 'data') AS n
             FROM public_health.silver.facilities_bed_occupancy_silver__classified GROUP BY sheet_year) c ON c.sheet_year = e.y
  WHERE coalesce(c.n, 0) <> e.n
UNION ALL
SELECT 'control: 2025 bronze rows 427 government and 782 private, authorized beds 111,833', 'fail',
       CASE WHEN (SELECT count_if(lower(trim(Nature_of_Ownership)) = 'government') FROM public_health.silver.facilities_bed_occupancy_silver__classified
                  WHERE row_class = 'data' AND sheet_year = 2025) = 427
             AND (SELECT count_if(lower(trim(Nature_of_Ownership)) = 'private') FROM public_health.silver.facilities_bed_occupancy_silver__classified
                  WHERE row_class = 'data' AND sheet_year = 2025) = 782
             AND (SELECT sum(fac_num(Authorized_Bed_Capacity)) FROM public_health.silver.facilities_bed_occupancy_silver__classified
                  WHERE row_class = 'data' AND sheet_year = 2025) = 111833
            THEN 0 ELSE 1 END
UNION ALL
SELECT 'warn: city / municipality not resolved (record kept at province level)', 'warn', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2 WHERE area_level_published <> 'city_municipality'
UNION ALL
SELECT 'warn: published BOR differs from bed days / (authorized beds x days) by more than 0.5 points', 'warn', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2 WHERE abs(bor_check_diff) > 0.5
UNION ALL
SELECT 'warn: BOR filled but bed days blank, or the reverse', 'warn', count(*)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2 WHERE (bor_pct IS NULL) <> (inpatient_bed_days IS NULL)
UNION ALL
SELECT 'warn: BOR above 100 (kept, flagged)', 'warn', count_if(is_bor_over_100)
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2
UNION ALL
SELECT 'warn: BOR above the baseline maximum (kept, not baseline-eligible)', 'warn', count_if(exclusion_reason = 'bor_gt_150')
  FROM public_health.silver.facilities_bed_occupancy_silver__candidate2;


-- =============================================================================
-- [6] build log row   [7] stop if a gate failed
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_bor_build_log AS
SELECT bor_build_id AS build_id, 'silver' AS layer, 'facilities' AS domain,
       'public_health.silver.facilities_bed_occupancy_silver' AS target_table,
       silver_build_started_at AS started_at, current_timestamp() AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.facilities_bed_occupancy_silver__candidate2) END AS row_count,
       CAST(NULL AS BIGINT) AS target_table_version, code_version AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup, 'bor_baseline_max', bor_baseline_max,
                            'bor_expected_sheets', bor_expected_sheets,
                            'geography_checksum', geography_checksum, 'warnings', g.warn_names)) AS parameters,
       job_run_id AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0 AND severity = 'fail') AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'fail' THEN concat(gate, ' = ', failures) END)) AS failed_names,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 AND severity = 'warn' THEN concat(gate, ' = ', failures) END)) AS warn_names
      FROM public_health.silver.facilities_bed_occupancy_silver__gates) g;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM fac_bor_build_log WHERE status = 'failed';

SELECT raise_error(concat('facilities_bed_occupancy_silver was NOT published. ', error_message))
FROM fac_bor_build_log WHERE status = 'failed';


-- =============================================================================
-- [8] write (full rebuild). Keep access to this table restricted.
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.facilities_bed_occupancy_silver AS
SELECT * EXCEPT (parse_errors, bor_check_diff, city_candidates, city_label_raw)
FROM public_health.silver.facilities_bed_occupancy_silver__candidate2;


-- =============================================================================
-- [9] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.facilities_bed_occupancy_silver),
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.facilities_bed_occupancy_silver)),
       code_version, parameters, run_id, error_message
FROM fac_bor_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.facilities_bed_occupancy_silver__inputs;

-- bronze rows not loaded (staged in [4b]); loaded rows are not written (contract 7.1)
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
       content_checksum, disposition, reason, target_key, recorded_at
FROM public_health.silver.facilities_bed_occupancy_silver__dispositions;


-- =============================================================================
-- [10] summary: the candidate baseline by year (aggregates only; the rows are restricted)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW fac_bor_summary AS
SELECT year, ownership, count(*) AS records, count_if(baseline_eligible) AS baseline_eligible,
       count_if(is_bor_over_100) AS bor_over_100, sum(authorized_beds) AS authorized_beds,
       sum(inpatient_bed_days) AS inpatient_bed_days,
       -- bed-weighted occupancy of eligible records (same period for every record assumed)
       round(sum(CASE WHEN baseline_eligible THEN bor_pct * authorized_beds END)
             / sum(CASE WHEN baseline_eligible THEN authorized_beds END), 1) AS weighted_bor_eligible
FROM public_health.silver.facilities_bed_occupancy_silver
GROUP BY year, ownership;

CREATE OR REPLACE TEMP VIEW fac_bor_warnings AS
SELECT gate, failures FROM public_health.silver.facilities_bed_occupancy_silver__gates WHERE severity = 'warn';

SELECT * FROM fac_bor_warnings;

DROP TABLE IF EXISTS public_health.silver.facilities_bed_occupancy_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.facilities_bed_occupancy_silver__candidate2;
DROP TABLE IF EXISTS public_health.silver.facilities_bed_occupancy_silver__gates;
DROP TABLE IF EXISTS public_health.silver.facilities_bed_occupancy_silver__inputs;
DROP TABLE IF EXISTS public_health.silver.facilities_bed_occupancy_silver__geo;
DROP TABLE IF EXISTS public_health.silver.facilities_bed_occupancy_silver__dispositions;

SELECT * FROM fac_bor_summary ORDER BY year, ownership;
