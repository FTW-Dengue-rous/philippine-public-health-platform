-- =============================================================================
-- Read-only evidence queries for facilities geography exceptions and review decisions.
-- Creates temporary views only; does not write or modify tables.
--
-- Run after:
--   bronze facilities tables
--   geography_silver
--   facilities_silver_00a_area_boundary.sql
--   facilities_silver_00_reference.sql
--
-- Queries
--   [0] Sets up matching helpers and the current geography snapshot.
--   [1] Lists source place labels that do not directly match geography_silver.
--   [2] Shows supporting evidence for reviewed and unresolved geography decisions.
--   [3] Shows generated exceptions, evidence, review status, and manual decisions.
--   [4] Shows how Silver applied exceptions or quarantined unresolved records.
--
-- Note:
--   The inventory uses simplified geography matching for investigation. Production
--   Silver builds apply additional fallback rules, so some listed labels may still
--   resolve without an exception.
-- =============================================================================
-- =============================================================================
-- facilities_area_evidence.sql
-- READ-ONLY evidence queries: why the facilities area exceptions and decisions exist.
-- Follows facilities-silver-plan.md v2.1 (sections 13 and 14). Not a build: no lineage-contract
-- records. Reads quality.row_disposition (contract v1.3: rows NOT loaded) in [4].
-- Status: ran on local Spark 4.0 (2026-10-12). Not yet run on Databricks.
-- Nothing is written (temp views only). Run after bronze, geography_silver,
-- facilities_silver_00a_area_boundary.sql and facilities_silver_00_reference.sql. Run cell by cell
-- and read each result.
--
--   [0] helpers: the same place-name key the silver builds use, and geography (one snapshot)
--   [1] INVENTORY: bronze place labels that do not match geography_silver, per source.
--       These are the labels that need an exception row (the generator's input list).
--   [2] EVIDENCE for each reviewed decision and each HFSRB label still in question (driven by the
--       exceptions table): 2a address evidence, 2b spelling distance, 2c FHSIS NCR names printed
--       twice (population in the neighbouring years), 2d label not in its province (San Francisco,
--       San Jose)
--   [3] the generated exceptions with their rule, evidence and status, and your decisions
--   [4] what silver did with them (records placed by an exception, records quarantined)
--
-- The inventory in [1] is a simplified mirror of the silver matching (name key within the
-- labelled province or region). The silver builds and build_facilities_area_exceptions.py apply
-- a few more rules (city-in-province-column, HUC fallback, other region), so [1] can list a few
-- labels that silver still resolves. Every label with an exception row is shown with its rule.
-- =============================================================================

-- [0] helpers -----------------------------------------------------------------
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

-- similarity 0..1 from the edit distance of the two keys (1 = identical)
CREATE OR REPLACE TEMPORARY FUNCTION ev_similarity(a STRING, b STRING) RETURNS DOUBLE
RETURN 1 - levenshtein(fac_place_key(a), fac_place_key(b)) / greatest(length(fac_place_key(a)), length(fac_place_key(b)), 1);

-- geography: latest snapshot; province, city, municipality, sub-municipality and barangay rows
CREATE OR REPLACE TEMP VIEW ev_geo AS
SELECT psgc_code, area_name, geographic_level, city_class,
       substr(psgc_code, 1, 2) AS region2, substr(psgc_code, 1, 5) AS prov5,
       fac_place_key(area_name) AS place_key
FROM public_health.silver.geography_silver
WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver)
  AND geographic_level IN ('Prov', 'City', 'Mun', 'SubMun', 'Bgy');

CREATE OR REPLACE TEMP VIEW ev_lgu AS
SELECT * FROM ev_geo WHERE geographic_level IN ('City', 'Mun', 'SubMun');

CREATE OR REPLACE TEMP VIEW ev_bgy_count AS          -- barangays per city / municipality and per province
SELECT substr(psgc_code, 1, 7) AS lgu7, count(*) AS barangays
FROM ev_geo WHERE geographic_level = 'Bgy' GROUP BY substr(psgc_code, 1, 7);

-- HFSRB records of the four lists the registry reads
CREATE OR REPLACE TEMP VIEW ev_hfsrb AS
SELECT 'hospitals' AS list, region, province, city_municipality, address, facility_name, nhfr_code,
       _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.bronze.facilities_hfsrb_hospitals_bronze
UNION ALL SELECT 'infirmaries', region, province, city_municipality, address, facility_name, nhfr_code,
       _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.bronze.facilities_hfsrb_infirmaries_bronze
UNION ALL SELECT 'primary_care', region, province, city_municipality, address, facility_name, nhfr_code,
       _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.bronze.facilities_hfsrb_primary_care_bronze
UNION ALL SELECT 'dialysis_clinics', region, province, city_municipality, address, facility_name, nhfr_code,
       _source_key, _source_file, _source_sheet, _source_row_num FROM public_health.bronze.facilities_hfsrb_dialysis_clinics_bronze;

-- province of each HFSRB province label: by name, else by the generated province_label exception
CREATE OR REPLACE TEMP VIEW ev_hfsrb_prov AS
SELECT DISTINCT h.province,
       coalesce(p.psgc_code, e.psgc_code) AS prov_code,
       CASE WHEN p.psgc_code IS NOT NULL THEN 'name' WHEN e.psgc_code IS NOT NULL THEN 'exception' END AS prov_resolved_by
FROM ev_hfsrb h
LEFT JOIN ev_geo p ON p.geographic_level = 'Prov' AND p.place_key = fac_place_key(h.province)
LEFT JOIN public_health.silver.facilities_area_exceptions e
  ON e.source_group = 'hfsrb' AND e.generated_match_type = 'province_label' AND e.match_value = fac_norm(h.province);


-- =============================================================================
-- [1] INVENTORY: labels that do not match geography_silver
-- =============================================================================

-- [1a] HFSRB: city labels with no city / municipality of that name in the labelled province
--      (an HUC of that name in the same region counts as a match), and how the registry build
--      resolved each one. Methods other than 'exception' are silver's own rules (a city typed in
--      the province column, the name in another province of the region, ...): those labels need no
--      exception. 'exception' rows used the generated file; geo_unresolved = 1 rows are quarantined.
SELECT h.province, h.city_municipality, p.prov_resolved_by, count(*) AS records,
       r.geo_resolution_method AS resolved_in_silver_by, max(r.geo_unresolved) AS unresolved,
       e.rule, e.review_status, e.proposed_psgc_code, e.proposed_area_name
FROM ev_hfsrb h
LEFT JOIN ev_hfsrb_prov p ON p.province <=> h.province
LEFT JOIN public_health.silver.facilities_registry_silver__records r
  ON r._source_key = h._source_key AND r._source_file = h._source_file
 AND r._source_sheet <=> h._source_sheet AND r._source_row_num = h._source_row_num
LEFT JOIN public_health.silver.facilities_area_exceptions e
  ON e.source_group = 'hfsrb' AND e.generated_match_type = 'area_label'
 AND e.match_value = fac_norm(h.city_municipality) AND e.parent_label_norm <=> fac_norm(h.province)
WHERE h.city_municipality IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ev_lgu g
                  WHERE g.place_key = fac_place_key(h.city_municipality)
                    AND (g.prov5 = substr(p.prov_code, 1, 5)
                         OR (g.city_class = 'HUC' AND g.region2 = substr(p.prov_code, 1, 2))))
GROUP BY ALL
ORDER BY CASE WHEN r.geo_resolution_method = 'exception' OR max(r.geo_unresolved) = 1 THEN 0 ELSE 1 END,
         resolved_in_silver_by, h.province, h.city_municipality;

-- same, summarised: how many mismatched labels each silver rule absorbs
SELECT coalesce(r.geo_resolution_method, CASE WHEN r.geo_unresolved = 1 THEN 'unresolved (quarantined)' ELSE 'not in registry records' END) AS resolved_in_silver_by,
       count(DISTINCT concat_ws('|', h.province, h.city_municipality)) AS labels, count(*) AS records
FROM ev_hfsrb h
LEFT JOIN ev_hfsrb_prov p ON p.province <=> h.province
LEFT JOIN public_health.silver.facilities_registry_silver__records r
  ON r._source_key = h._source_key AND r._source_file = h._source_file
 AND r._source_sheet <=> h._source_sheet AND r._source_row_num = h._source_row_num
WHERE h.city_municipality IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ev_lgu g
                  WHERE g.place_key = fac_place_key(h.city_municipality)
                    AND (g.prov5 = substr(p.prov_code, 1, 5)
                         OR (g.city_class = 'HUC' AND g.region2 = substr(p.prov_code, 1, 2))))
GROUP BY ALL ORDER BY records DESC;

-- [1b] FHSIS: area labels with no province / city / municipality of that name anywhere, and
--      labels printed twice in one file (one of them is another area: the 2022 NCR case)
CREATE OR REPLACE TEMP VIEW ev_fhsis AS
SELECT regexp_extract(_source_file, '_(\\d{4})\\.xlsx$', 1) AS year, _source_file, _source_row_num,
       trim(area_name) AS area_name, fac_place_key(area_name) AS place_key,
       try_cast(regexp_replace(CAST(barangays_no AS STRING), '[, ]', '') AS INT) AS barangays,
       try_cast(regexp_replace(CAST(population AS STRING), '[, ]', '') AS BIGINT) AS population
FROM public_health.bronze.facilities_fhsis_primary_care_bronze
WHERE _source_key = 'doh_fhsis_demographic' AND area_name IS NOT NULL
  AND CAST(population AS STRING) RLIKE '[0-9]';

SELECT f.year, f.area_name, count(DISTINCT f._source_row_num) AS rows_in_file,
       count(DISTINCT g.psgc_code) AS geography_areas_with_this_name,
       CASE WHEN count(DISTINCT g.psgc_code) = 0 THEN 'no geography area of this name'
            ELSE 'printed more than once in the same file' END AS why_listed,
       max(e.rule) AS rule, max(e.review_status) AS review_status, max(e.proposed_area_name) AS proposed_area_name
FROM ev_fhsis f
LEFT JOIN ev_geo g ON g.place_key = f.place_key AND g.geographic_level IN ('Prov', 'City', 'Mun')
LEFT JOIN public_health.silver.facilities_area_exceptions e
  ON e.source_group = 'fhsis' AND e.match_value = fac_norm(f.area_name)
 AND (e.year_from IS NULL OR e.year_from = f.year)
WHERE NOT fac_norm(f.area_name) RLIKE '^(REGION|NCR|N C R|CAR|C A R|BARMM|ARMM|CARAGA|MIMAROPA|CALABARZON|SOCCSKSARGEN|NATIONAL CAPITAL|CORDILLERA|BANGSAMORO|NEGROS ISLAND|PHILIPPINES)'
  AND NOT fac_norm(f.area_name) RLIKE '^(ILOCOS|CAGAYAN VALLEY|CENTRAL LUZON|BICOL|WESTERN VISAYAS|CENTRAL VISAYAS|EASTERN VISAYAS|ZAMBOANGA PENINSULA|NORTHERN MINDANAO|DAVAO|METRO MANILA)( REGION)?$'
GROUP BY f.year, f._source_file, f.area_name
HAVING count(DISTINCT g.psgc_code) = 0 OR count(DISTINCT f._source_row_num) > 1
ORDER BY f.year, f.area_name;

-- [1c] Bed occupancy: Province/District labels that are not a province name
SELECT `Province/District` AS province_label, count(*) AS records,
       e.rule, e.review_status, e.proposed_psgc_code, e.proposed_area_name
FROM public_health.bronze.facilities_bed_occupancy_bronze b
LEFT JOIN public_health.silver.facilities_area_exceptions e
  ON e.source_group = 'bor' AND e.generated_match_type = 'province_label' AND e.match_value = fac_norm(b.`Province/District`)
WHERE `Province/District` IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ev_geo g WHERE g.geographic_level = 'Prov' AND g.place_key = fac_place_key(b.`Province/District`))
GROUP BY ALL ORDER BY records DESC;

-- [1d] OSM points WITHOUT coordinates: addr:city labels that match 0 or 2+ cities / municipalities
SELECT o.addr_city, count(*) AS points_without_coordinates,
       (SELECT count(*) FROM ev_lgu g WHERE g.place_key = fac_place_key(o.addr_city)
          AND (g.geographic_level = 'City' OR NOT fac_norm(o.addr_city) RLIKE '(^CITY OF )|( CITY$)|( CITY )'))
         AS geography_areas_with_this_name,          -- a label saying 'City' matches cities only, as in silver
       e.rule, e.review_status, e.proposed_psgc_code, e.evidence
FROM public_health.bronze.facilities_hdx_healthsites_bronze o
LEFT JOIN public_health.silver.facilities_area_exceptions e
  ON e.source_group = 'osm' AND e.match_value = o.addr_city
WHERE o._source_key = 'hdx_healthsites' AND o.addr_city IS NOT NULL
  AND (try_cast(o.X AS DOUBLE) IS NULL OR try_cast(o.Y AS DOUBLE) IS NULL)
GROUP BY ALL
HAVING geography_areas_with_this_name <> 1
ORDER BY points_without_coordinates DESC;

-- [1e] NHFR: municipality PSGC codes that are not in geography_silver
SELECT n.`City/Municipality_PSGC` AS nhfr_code, n.`City/Municipality_Name` AS nhfr_name,
       n.`Province_Name` AS province, count(*) AS facilities
FROM public_health.bronze.facilities_nhfr_bronze n
WHERE NOT EXISTS (SELECT 1 FROM ev_geo g
                  WHERE g.psgc_code = lpad(regexp_replace(CAST(n.`City/Municipality_PSGC` AS STRING), '\\.0$', ''), 10, '0'))
GROUP BY ALL ORDER BY facilities DESC;


-- =============================================================================
-- [2] EVIDENCE for each decision
-- =============================================================================

-- The HFSRB records behind every reviewed decision and every label still in question
-- (driven by the exceptions table, so nothing is typed here)
CREATE OR REPLACE TEMP VIEW ev_check_labels AS
SELECT e.area_label_source AS label, e.review_status, e.rule, e.proposed_psgc_code, e.proposed_area_name,
       h.list, h.province, h.city_municipality, h.facility_name, h.address, p.prov_code,
       -- search scope: the labelled province; 'Metro Manila' / 'NCR' is not a province, so the region
       substr(p.prov_code, 1, 5) AS scope_prov5,
       CASE WHEN p.prov_code IS NOT NULL THEN substr(p.prov_code, 1, 2)
            WHEN fac_norm(h.province) RLIKE 'METRO MANILA|NCR|NATIONAL CAPITAL' THEN '13' END AS scope_region2,
       concat(' ', fac_place(h.address), ' ') AS address_text
FROM public_health.silver.facilities_area_exceptions e
JOIN ev_hfsrb h ON fac_norm(h.city_municipality) = e.match_value AND fac_norm(h.province) <=> e.parent_label_norm
LEFT JOIN ev_hfsrb_prov p ON p.province <=> h.province
WHERE e.source_group = 'hfsrb' AND e.generated_match_type = 'area_label'
  AND (e.review_status IN ('reviewed', 'needs_review') OR e.rule = 'address_other_province');

-- barangays whose name belongs to exactly one city / municipality of their province (so naming
-- one in an address points to one place; 'Poblacion' or 'San Isidro' do not)
CREATE OR REPLACE TEMP VIEW ev_bgy_unique AS
SELECT g.*
FROM ev_geo g
JOIN (SELECT prov5, place_key FROM ev_geo WHERE geographic_level = 'Bgy'
      GROUP BY prov5, place_key HAVING count(DISTINCT substr(psgc_code, 1, 7)) = 1) u
  ON u.prov5 = g.prov5 AND u.place_key = g.place_key
WHERE g.geographic_level = 'Bgy' AND length(g.place_key) >= 6;

-- [2a] Address evidence: the cities / municipalities and the unique barangays that each record's
--      ADDRESS names, inside the labelled province (or region for Metro Manila), and the
--      municipality the LABEL itself belongs to when the label is a barangay name ('Semirara')
SELECT c.label, c.province, c.review_status, c.proposed_area_name, c.facility_name, c.address,
       concat_ws('; ', collect_set(concat(l.area_name, ' ', l.psgc_code))) AS lgu_named_in_address,
       concat_ws('; ', collect_set(concat('Brgy ', b.area_name, ' -> ', bl.area_name, ' ', bl.psgc_code))) AS barangay_named_in_address,
       concat_ws('; ', collect_set(concat('Brgy ', lb.area_name, ' -> ', lbl.area_name, ' ', lbl.psgc_code))) AS label_is_barangay_of
FROM ev_check_labels c
LEFT JOIN ev_lgu l
  ON (l.prov5 = c.scope_prov5 OR (c.scope_prov5 IS NULL AND l.region2 = c.scope_region2))
 AND c.address_text LIKE concat('% ', fac_place(l.area_name), ' %')
 AND l.place_key NOT IN (fac_place_key(c.city_municipality), coalesce(fac_place_key(c.province), '-'))
LEFT JOIN ev_bgy_unique b
  ON (b.prov5 = c.scope_prov5 OR (c.scope_prov5 IS NULL AND b.region2 = c.scope_region2))
 AND c.address_text LIKE concat('% ', fac_place(b.area_name), ' %')
 AND b.place_key <> fac_place_key(c.city_municipality)
LEFT JOIN ev_lgu bl ON bl.psgc_code = concat(substr(b.psgc_code, 1, 7), '000')
LEFT JOIN ev_bgy_unique lb
  ON (lb.prov5 = c.scope_prov5 OR (c.scope_prov5 IS NULL AND lb.region2 = c.scope_region2))
 AND lb.place_key = fac_place_key(c.city_municipality)
LEFT JOIN ev_lgu lbl ON lbl.psgc_code = concat(substr(lb.psgc_code, 1, 7), '000')
GROUP BY ALL
ORDER BY c.review_status, c.label;
-- Note: a street named after a barangay ('A. Mabini St.') can also match; read the address.

-- [2b] Spelling: the 3 closest city / municipality names in the labelled province (1 = identical)
SELECT label, province, review_status, candidate, psgc_code, round(similarity, 3) AS similarity, rank
FROM (
  SELECT c.label, c.province, c.review_status, g.area_name AS candidate, g.psgc_code,
         ev_similarity(c.label, g.area_name) AS similarity,
         row_number() OVER (PARTITION BY c.label, c.province ORDER BY ev_similarity(c.label, g.area_name) DESC) AS rank
  FROM (SELECT DISTINCT label, province, review_status, scope_prov5, scope_region2 FROM ev_check_labels) c
  JOIN ev_lgu g ON g.prov5 = c.scope_prov5 OR (c.scope_prov5 IS NULL AND g.region2 = c.scope_region2))
WHERE rank <= 3
ORDER BY review_status, label, rank;

-- [2c] FHSIS, NCR: a name printed twice in one file means one row is another city. Each copy is
--      compared with the NCR areas MISSING from that file (and with the named city itself) on
--      population and barangays printed in the neighbouring years' files.
CREATE OR REPLACE TEMP VIEW ev_fhsis_ncr AS
SELECT f.*, g.psgc_code, g.area_name AS geography_name,
       count(*) OVER (PARTITION BY f._source_file, g.psgc_code) AS rows_with_this_name_in_file
FROM ev_fhsis f
JOIN ev_lgu g ON g.place_key = f.place_key AND g.region2 = '13' AND g.geographic_level IN ('City', 'Mun')
-- a label without 'City' that is also a province name is that province ('Quezon'), not the NCR city
WHERE fac_norm(f.area_name) RLIKE 'CITY'
   OR NOT EXISTS (SELECT 1 FROM ev_geo p WHERE p.geographic_level = 'Prov' AND p.place_key = f.place_key);

-- names printed more than once in one file
SELECT year, _source_row_num, area_name, population, barangays, geography_name
FROM ev_fhsis_ncr WHERE rows_with_this_name_in_file > 1
ORDER BY year, _source_row_num;

-- each copy against the candidates: the closest population in the year before / after decides
WITH dup AS (SELECT * FROM ev_fhsis_ncr WHERE rows_with_this_name_in_file > 1),
missing AS (
  SELECT d._source_file, g.psgc_code, g.area_name
  FROM (SELECT DISTINCT _source_file FROM dup) d
  CROSS JOIN ev_lgu g
  WHERE g.region2 = '13' AND g.geographic_level IN ('City', 'Mun')
    AND NOT EXISTS (SELECT 1 FROM ev_fhsis_ncr n WHERE n._source_file = d._source_file AND n.psgc_code = g.psgc_code)),
cand AS (
  SELECT d.*, m.psgc_code AS cand_code, m.area_name AS candidate, 'missing from this file' AS candidate_kind
  FROM dup d JOIN missing m ON m._source_file = d._source_file
  UNION ALL
  SELECT d.*, d.psgc_code, d.geography_name, 'the printed name' FROM dup d),
nb AS (SELECT psgc_code, year, population, barangays FROM ev_fhsis_ncr WHERE rows_with_this_name_in_file = 1)
SELECT c.year, c._source_row_num, c.area_name AS printed_label, c.population AS printed_population,
       c.barangays AS printed_barangays, c.candidate, c.candidate_kind, n.year AS other_year,
       n.population AS other_year_population, n.barangays AS other_year_barangays,
       round(abs(c.population - n.population) / n.population, 3) AS population_difference
FROM cand c
JOIN nb n ON n.psgc_code = c.cand_code AND abs(CAST(n.year AS INT) - CAST(c.year AS INT)) = 1
ORDER BY c.year, c._source_row_num, population_difference;

-- [2d] Labels whose city / municipality does not exist in the labelled province: where that name
--      exists in the region, and whether the address names that province
SELECT c.label, c.province AS label_province, c.review_status, c.rule, c.facility_name, c.address,
       g.area_name AS same_name_lgu, g.psgc_code, pr.area_name AS its_province,
       c.address_text LIKE concat('% ', fac_place(pr.area_name), ' %') AS address_names_this_province
FROM ev_check_labels c
JOIN ev_lgu g ON g.place_key = fac_place_key(c.city_municipality) AND g.region2 = substr(c.prov_code, 1, 2)
LEFT JOIN ev_geo pr ON pr.geographic_level = 'Prov' AND pr.psgc_code = concat(g.prov5, '00000')
WHERE g.prov5 <> substr(c.prov_code, 1, 5)
  AND NOT EXISTS (SELECT 1 FROM ev_lgu x WHERE x.place_key = fac_place_key(c.city_municipality)
                                         AND x.prov5 = substr(c.prov_code, 1, 5))
ORDER BY c.label, g.psgc_code;

-- barangays named in an address without a municipality: where they exist in the region
-- (San Jose, Oriental Mindoro: 'Brgy. Poblacion III')
SELECT c.label, c.province, c.address, l.area_name AS municipality, l.psgc_code, g.area_name AS barangay
FROM ev_check_labels c
JOIN ev_geo g ON g.geographic_level = 'Bgy' AND g.region2 = substr(c.prov_code, 1, 2)
             AND c.address_text LIKE concat('% ', fac_place(g.area_name), ' %')
             AND fac_place(g.area_name) RLIKE ' '          -- multi-word names only ('POBLACION III')
JOIN ev_lgu l ON l.psgc_code = concat(substr(g.psgc_code, 1, 7), '000')
WHERE c.review_status = 'needs_review'
ORDER BY c.label, l.psgc_code;


-- =============================================================================
-- [3] the generated exceptions and the decisions
-- =============================================================================
SELECT source_group, generated_match_type, area_label_source, parent_label_norm, year_from,
       rule, evidence, review_status, proposed_psgc_code, proposed_area_name, geography_check, records, review_note
FROM public_health.silver.facilities_area_exceptions
ORDER BY CASE review_status WHEN 'needs_review' THEN 0 WHEN 'reviewed' THEN 1 ELSE 2 END, source_group, area_label_source;

SELECT review_status, source_group, count(*) AS rows, sum(CAST(records AS INT)) AS records
FROM public_health.silver.facilities_area_exceptions
GROUP BY ALL ORDER BY review_status, source_group;

-- your decisions, as uploaded (the generator applied them: review_status 'reviewed')
SELECT * FROM read_files('/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/facilities/facilities_area_decisions.csv',
                         format => 'csv', header => true);


-- =============================================================================
-- [4] what silver did with them
-- =============================================================================
-- registry records placed by an exception row
SELECT _source_key, geo_name_source, psgc_code, count(*) AS records
FROM public_health.silver.facilities_registry_silver__records
WHERE geo_resolution_method = 'exception'
GROUP BY ALL ORDER BY geo_name_source;

-- records not loaded because their place could not be verified (all builds)
SELECT target_table, reason, count(*) AS records
FROM public_health.quality.row_disposition
WHERE disposition = 'quarantined' AND (reason LIKE 'place_%' OR reason LIKE '%city%' OR reason LIKE '%label%')
  AND build_id IN (SELECT max_by(build_id, finished_at) FROM public_health.quality.build_log
                   WHERE status = 'succeeded' GROUP BY target_table)
GROUP BY ALL ORDER BY target_table, records DESC;