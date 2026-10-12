-- =============================================================================
-- Loads reviewed facilities reference CSVs into the Silver schema.
-- Run this before other facilities Silver scripts and rerun it whenever a reference
-- CSV changes. Loads all columns as STRING to preserve values such as PSGC codes.
--
-- Reference tables
--   facilities_area_exceptions.csv
--     -> public_health.silver.facilities_area_exceptions
--   facilities_id_map_override.csv
--     -> public_health.silver.facilities_id_map_override
--
-- Reference handling
--   facilities_area_exceptions stores reviewed geography mappings that the standard
--   geography join cannot resolve. build_facilities_area_exceptions.py generates
--   this file from source evidence and reviewer decisions; do not edit mappings
--   directly in the generated CSV.
--
--   Only auto, corroborated, and reviewed mappings are usable. Other records remain
--   unresolvable and are quarantined rather than matched by name.
--
--   facilities_id_map_override stores manual facility identity decisions between
--   source systems.
--
-- Geography safeguard
--   Validates the exceptions file against the current geography_silver checksum and
--   stops the build if the geography snapshot has changed.
--
-- Reference files live in config/reference/facilities/ and are reviewed like code.
-- City/municipality boundaries are built separately by
-- facilities_silver_00a_area_boundary.sql.
-- =============================================================================
-- [1] area exceptions
CREATE OR REPLACE TEMP VIEW facilities_area_exceptions_file AS
SELECT *
FROM read_files('/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/facilities/facilities_area_exceptions.csv',
       format => 'csv', header => true, multiLine => true, escape => '"',
       schema => 'source_group STRING, match_type STRING, match_value STRING, parent_label_norm STRING, year_from STRING, year_to STRING, area_label_source STRING, psgc_code STRING, area_key STRING, named_key_level STRING, reason STRING, review_note STRING, rule STRING, evidence STRING, evidence_n STRING, evidence_share STRING, review_status STRING, proposed_psgc_code STRING, proposed_area_name STRING, geography_check STRING, records STRING, geography_checksum STRING');

CREATE OR REPLACE TABLE public_health.silver.facilities_area_exceptions AS
SELECT source_group,
       CASE WHEN review_status IN ('auto', 'corroborated', 'reviewed') THEN match_type ELSE 'unresolvable' END AS match_type,
       match_value, parent_label_norm, year_from, year_to, area_label_source,
       CASE WHEN review_status IN ('auto', 'corroborated', 'reviewed') THEN psgc_code END AS psgc_code,
       CASE WHEN review_status IN ('auto', 'corroborated', 'reviewed') THEN area_key END AS area_key,
       named_key_level, reason, review_note, rule, evidence, review_status, proposed_psgc_code, proposed_area_name,
       geography_check, CAST(records AS INT) AS records, geography_checksum,
       match_type AS generated_match_type
FROM facilities_area_exceptions_file;

-- [2] id map overrides (header only until a manual decision is needed)
CREATE OR REPLACE TABLE public_health.silver.facilities_id_map_override AS
SELECT _source_key, source_record_id, action, nhfr_id, reason, review_status, reviewed_by, reviewed_on
FROM read_files('/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/facilities/facilities_id_map_override.csv',
       format => 'csv', header => true,
       schema => '_source_key STRING, source_record_id STRING, action STRING, nhfr_id STRING, reason STRING, review_status STRING, reviewed_by STRING, reviewed_on STRING');

-- [3] checks: each must return 0. A failure stops the run here.
-- current geography snapshot (geography_silver keeps one; max_by guards against a second one)
CREATE OR REPLACE TEMP VIEW facilities_geography_snapshot AS
SELECT max_by(content_checksum, silver_processed_at) AS geography_checksum
FROM public_health.silver.geography_silver;

CREATE OR REPLACE TEMP VIEW facilities_reference_checks AS
SELECT 'area exceptions: duplicate key' AS check_name, count(*) AS failures FROM (
  SELECT 1 FROM public_health.silver.facilities_area_exceptions
  GROUP BY source_group, generated_match_type, match_value, coalesce(parent_label_norm, ''), coalesce(year_from, '')
  HAVING count(*) > 1)
UNION ALL
SELECT 'area exceptions: review_status or rule missing / unknown (regenerate the file)', count(*)
  FROM public_health.silver.facilities_area_exceptions
  WHERE review_status IS NULL OR review_status NOT IN ('auto', 'corroborated', 'reviewed', 'needs_review', 'rejected')
     OR (review_status IN ('auto', 'corroborated') AND rule IS NULL)
UNION ALL
SELECT 'area exceptions: unknown match_type', count(*)
  FROM public_health.silver.facilities_area_exceptions
  WHERE generated_match_type NOT IN ('area_label', 'province_label', 'code_prefix')
UNION ALL
SELECT 'area exceptions: not exactly one of psgc_code / area_key', count(*)
  FROM public_health.silver.facilities_area_exceptions
  WHERE match_type NOT IN ('code_prefix', 'unresolvable') AND ((psgc_code IS NULL) = (area_key IS NULL))
UNION ALL
SELECT 'area exceptions: unresolvable row with a code', count(*)
  FROM public_health.silver.facilities_area_exceptions
  WHERE match_type = 'unresolvable' AND coalesce(psgc_code, area_key) IS NOT NULL
UNION ALL
SELECT 'area exceptions: psgc_code not in geography silver', count(*)
  FROM public_health.silver.facilities_area_exceptions e
  WHERE e.match_type <> 'code_prefix' AND e.psgc_code IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public_health.silver.geography_silver g WHERE g.psgc_code = e.psgc_code)
UNION ALL
SELECT 'area exceptions: generated from another geography snapshot, or columns shifted (regenerate the file)', count(*)
  FROM public_health.silver.facilities_area_exceptions e
  WHERE e.geography_checksum IS NULL
     OR e.geography_checksum <> (SELECT geography_checksum FROM facilities_geography_snapshot)
UNION ALL
SELECT 'area exceptions: proposed_area_name differs from geography silver (regenerate the file)', count(*)
  FROM public_health.silver.facilities_area_exceptions e
  JOIN public_health.silver.geography_silver g ON g.psgc_code = e.proposed_psgc_code
  WHERE e.generated_match_type <> 'code_prefix'
    AND g.content_checksum = (SELECT geography_checksum FROM facilities_geography_snapshot)
    AND e.proposed_area_name IS DISTINCT FROM g.area_name
UNION ALL
SELECT 'area exceptions: usable row that failed the generator geography check', count(*)
  FROM public_health.silver.facilities_area_exceptions
  WHERE review_status IN ('auto', 'corroborated', 'reviewed') AND geography_check IS NOT NULL AND geography_check <> 'ok'
UNION ALL
SELECT 'id map override: duplicate key', count(*) FROM (
  SELECT 1 FROM public_health.silver.facilities_id_map_override
  GROUP BY _source_key, source_record_id HAVING count(*) > 1)
UNION ALL
SELECT 'id map override: unknown action', count(*)
  FROM public_health.silver.facilities_id_map_override
  WHERE action NOT IN ('link_to_nhfr', 'own_facility')
     OR (action = 'link_to_nhfr' AND try_cast(nhfr_id AS BIGINT) IS NULL);

SELECT raise_error(concat('Reference check failed: ', check_name, ' = ', failures))
FROM facilities_reference_checks WHERE failures > 0;

-- [4] result
SELECT * FROM facilities_reference_checks;
