-- ============================================================================
-- Builds public_health.silver.workforce_specialist_silver:
--   one PSMO area listing in one directory snapshot (medical oncologists listed by area of practice).
--   Key: (_source_key, snapshot_date, area_label_source)
--
-- Rules (plan 7.2)
--   * listed_oncologist_count is the count as published; count_unit = 'unconfirmed' until the
--     directory is checked (D3). Listings repeat across areas, so area counts are never summed
--     into a unique regional or national total.
--   * Composite labels ('Negros Oriental / Dumaguete City') stay one observation with a named key;
--     component codes are for reference only. The count is never copied to or split between them.
--   * Areas: workforce_psmo_area_exceptions first, then the same name join as workforce_silver_01
--     (name core + level + parent region; exactly one candidate).
--
-- Build sequence: the same four contract steps as workforce_silver_02_headcount.sql.
-- Needs: workforce_silver_00_reference.sql; public_health.silver.geography_silver; quality_setup.sql.
-- QC of the published table is in workforce_silver_qc.py.
-- =============================================================================

-- [0] build id, settings, helpers
DECLARE OR REPLACE VARIABLE silver_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE silver_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE strict_load_lookup BOOLEAN DEFAULT true;   -- see workforce_silver_02
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;

-- Same rules as workforce_silver_01 [1] (keep identical)
-- Upper case, accents folded, punctuation to spaces, single spaces. A damaged n-tilde ('Ã±', the
-- form geography_silver had before its repair) is read as 'ñ' first.
CREATE OR REPLACE TEMPORARY FUNCTION wf_norm(x STRING) RETURNS STRING
RETURN trim(regexp_replace(regexp_replace(
         translate(upper(replace(replace(x, 'Ã±', 'ñ'), 'Ã‘', 'Ñ')), 'ÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑ', 'AAAAAEEEEIIIIOOOOOUUUUN'),
         '[^A-Z0-9 ]', ' '), ' +', ' '));

-- Name core: bracketed text removed ('City of General Santos (Dadiangas)'), then a leading
-- 'CITY OF ' (or 'ISLAND GARDEN CITY OF ', 'SCIENCE CITY OF ') or a trailing ' CITY' removed,
-- so 'CITY OF X' = 'X CITY' = 'X'.
CREATE OR REPLACE TEMPORARY FUNCTION wf_core(x STRING) RETURNS STRING
RETURN regexp_replace(regexp_replace(wf_norm(regexp_replace(x, '[(][^)]*[)]', ' ')),
         '^(ISLAND GARDEN CITY OF|SCIENCE CITY OF|CITY OF) ', ''), ' CITY$', '');

-- True when the label says it is a city.
CREATE OR REPLACE TEMPORARY FUNCTION wf_has_city(x STRING) RETURNS BOOLEAN
RETURN coalesce(wf_norm(x) RLIKE '^CITY OF ' OR wf_norm(x) RLIKE ' CITY$', false);

-- Loose key for the 2025 name check only: the core with common abbreviations spelled out and no
-- spaces, so 'Sto. Tomas' = 'Santo Tomas'. A printed code whose loose key differs is a real
-- mismatch (a swapped code), not a spelling difference.
CREATE OR REPLACE TEMPORARY FUNCTION wf_loose(x STRING) RETURNS STRING
RETURN replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         concat(' ', replace(wf_core(x), ' ', '  '), ' '),
         ' STA ', ' SANTA '), ' STO ', ' SANTO '), ' GEN ', ' GENERAL '), ' PRES ', ' PRESIDENT '), ' SEN ', ' SENATOR '),
         ' ', '');

CREATE OR REPLACE TEMPORARY FUNCTION wf_num(x STRING) RETURNS DECIMAL(20,4)
RETURN CASE WHEN regexp_replace(trim(x), '[ ,]', '') RLIKE '^-?[0-9]+([.][0-9]+)?$'
            THEN try_cast(regexp_replace(trim(x), '[ ,]', '') AS DECIMAL(20,4)) END;

-- Geography: same view as workforce_silver_01 [2] (keep identical).
-- public_health.silver.geography_silver, one PSGC snapshot (the latest
--     content_checksum, same rule as the facilities files). This view is the only place that reads
--     the geography table; workforce_silver_01 has the same view.
--       geographic_level Reg / Prov / City / Mun -> region / province / city / municipality
--       1999900000 Special Geographic Area (no level in PSGC) -> special_geographic_area
--       0990100000 'City of Isabela (Not a Province)' (no level) is a placeholder and is left out;
--       the city is 0990101000. SubMun and Bgy are left out. Both codes are the documented
--       null-level codes in sources_geography.yaml; geography_silver_qc.py GS08 warns if they change.
--       parent province: municipalities and component cities (city_class not HUC / ICC) whose
--       5-digit prefix is a province (or the SGA) in geography; everything else hangs on its region.
DECLARE OR REPLACE VARIABLE geography_checksum STRING;
SET VARIABLE geography_checksum =
  (SELECT max_by(content_checksum, silver_processed_at) FROM public_health.silver.geography_silver);

CREATE OR REPLACE TEMP VIEW wf_geo AS
WITH g AS (
  SELECT lpad(trim(CAST(psgc_code AS STRING)), 10, '0')                                   AS psgc_code,
         trim(area_name)                                                                  AS geo_name,
         CASE geographic_level WHEN 'Reg' THEN 'region' WHEN 'Prov' THEN 'province'
                               WHEN 'City' THEN 'city' WHEN 'Mun' THEN 'municipality'
              ELSE CASE WHEN geographic_level IS NULL
                         AND lpad(trim(CAST(psgc_code AS STRING)), 10, '0') = '1999900000'
                        THEN 'special_geographic_area' END END                            AS geo_level,
         CASE WHEN geographic_level = 'City' THEN nullif(upper(trim(city_class)), '') END AS city_class
  FROM public_health.silver.geography_silver
  WHERE content_checksum = geography_checksum)
SELECT g.psgc_code, g.geo_name, g.geo_level, g.city_class,
       CASE WHEN g.geo_level = 'municipality'
              OR (g.geo_level = 'city' AND coalesce(g.city_class, 'CC') NOT IN ('HUC', 'ICC'))
            THEN p.psgc_code END                                                          AS parent_province_psgc,
       concat(substr(g.psgc_code, 1, 2), '00000000')                                      AS parent_region_psgc,
       wf_core(g.geo_name)                                                                AS name_core,
       wf_loose(g.geo_name)                                                               AS name_loose
FROM g
LEFT JOIN g p
  ON p.psgc_code = concat(substr(g.psgc_code, 1, 5), '00000') AND p.geo_level IN ('province', 'special_geographic_area')
WHERE g.geo_level IS NOT NULL;

CREATE OR REPLACE TEMP VIEW wf_psmo_exc AS
SELECT _source_key, match_role, area_label_norm,
       nullif(trim(parent_label_norm), '')                             AS parent_label_norm,
       CASE WHEN nullif(trim(psgc_code), '') IS NOT NULL THEN lpad(trim(psgc_code), 10, '0') END AS psgc_code,
       nullif(trim(area_key), '')                                      AS named_area_key,
       nullif(trim(named_key_level), '')                               AS named_key_level,
       CASE WHEN nullif(trim(named_key_parent_psgc), '') IS NOT NULL
            THEN lpad(trim(named_key_parent_psgc), 10, '0') END        AS named_key_parent_psgc,
       CASE WHEN nullif(trim(child_region_codes), '') IS NOT NULL
            THEN transform(split(child_region_codes, ';'), x -> lpad(trim(x), 2, '0')) END AS child_region_codes,
       coalesce(lower(trim(is_composite_area)) = 'true', false)        AS is_composite_area,
       CASE WHEN nullif(trim(component_psgc_codes), '') IS NOT NULL
            THEN transform(split(component_psgc_codes, ';'), x -> lpad(trim(x), 10, '0')) END AS component_psgc_codes
FROM public_health.silver.workforce_psmo_area_exceptions;


-- =============================================================================
-- [1] classified and resolved bronze rows (staging table)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_specialist_silver__classified AS
WITH c AS (
  SELECT b._source_key, b._source_file, b._source_sheet, b._source_row_num, b._as_of_date, b._ingested_at,
         trim(b.region) AS region_as_published, trim(b.province_area) AS area_label_source, b.doctor_count,
         wf_norm(b.region) AS region_norm, wf_norm(b.province_area) AS label_norm,
         wf_core(b.province_area) AS label_core, wf_has_city(b.province_area) AS label_has_city,
         er.child_region_codes AS region_children
  FROM public_health.bronze.workforce_psmo_oncologists_bronze b
  LEFT JOIN wf_psmo_exc er ON er.match_role = 'region' AND er._source_key = b._source_key AND er.area_label_norm = wf_norm(b.region)
  WHERE b._source_key = 'psmo_oncologists'),
exc AS (
  SELECT c._source_row_num, count(*) AS exc_n, max(e.psgc_code) AS exc_psgc, max(e.named_area_key) AS exc_named_key,
         max(e.named_key_level) AS exc_named_level, max(e.named_key_parent_psgc) AS exc_named_parent,
         bool_or(e.is_composite_area) AS is_composite_area, max(e.component_psgc_codes) AS component_psgc_codes
  FROM c
  JOIN wf_psmo_exc e
    ON e.match_role = 'area' AND e._source_key = c._source_key AND e.area_label_norm = c.label_norm
   AND (e.parent_label_norm IS NULL OR e.parent_label_norm = c.region_norm)
  GROUP BY c._source_row_num),
auto AS (
  SELECT c._source_row_num,
         count_if(g.geo_level = 'province') AS n_prov, count_if(g.geo_level <> 'province') AS n_other,
         max(CASE WHEN g.geo_level = 'province' THEN g.psgc_code END) AS prov_code,
         max(CASE WHEN g.geo_level <> 'province' THEN g.psgc_code END) AS other_code,
         concat_ws('; ', collect_list(concat(g.geo_name, ' ', g.psgc_code, ' (', g.geo_level, ')'))) AS candidates
  FROM c
  JOIN wf_geo g
    ON g.name_core = c.label_core AND array_contains(c.region_children, substr(g.psgc_code, 1, 2))
   AND ((c.label_has_city AND g.geo_level = 'city')
        OR (NOT c.label_has_city AND g.geo_level IN ('province', 'city', 'municipality')))
  GROUP BY c._source_row_num),
m AS (
  SELECT c.*, exc.exc_n, exc.exc_psgc, exc.exc_named_key, exc.exc_named_level, exc.exc_named_parent,
         coalesce(exc.is_composite_area, false) AS is_composite_area, exc.component_psgc_codes,
         auto.candidates AS auto_candidates,
         CASE WHEN auto.n_prov > 0 THEN auto.prov_code ELSE auto.other_code END AS auto_code,
         CASE WHEN c.region_children IS NULL THEN 'region_unresolved'
              WHEN exc.exc_n = 1 THEN 'exception'
              WHEN exc.exc_n > 1 THEN 'ambiguous_exception'
              WHEN (CASE WHEN auto.n_prov > 0 THEN auto.n_prov ELSE auto.n_other END) = 1 THEN 'name_join'
              WHEN auto.n_prov + auto.n_other > 1 THEN 'ambiguous_name'
              ELSE 'unresolved' END AS resolve_method
  FROM c
  LEFT JOIN exc ON exc._source_row_num = c._source_row_num
  LEFT JOIN auto ON auto._source_row_num = c._source_row_num),
r AS (
  SELECT m.*,
         CASE m.resolve_method WHEN 'exception' THEN m.exc_psgc WHEN 'name_join' THEN m.auto_code END AS res_psgc,
         CASE WHEN m.resolve_method = 'exception' THEN m.exc_named_key END                          AS res_named_key
  FROM m)
SELECT 'public_health.bronze.workforce_psmo_oncologists_bronze' AS input_table,
       r._source_key, r._source_file, r._source_sheet, r._source_row_num, r._as_of_date, r._ingested_at,
       r.region_as_published, r.area_label_source, r.doctor_count, r.resolve_method, r.auto_candidates,
       r.is_composite_area, r.component_psgc_codes,
       coalesce(r.res_named_key, CASE WHEN r.res_psgc IS NOT NULL THEN concat('psgc:', r.res_psgc) END) AS area_key,
       r.res_psgc AS psgc_code,
       CASE WHEN r.res_named_key IS NOT NULL THEN r.exc_named_level ELSE g.geo_level END     AS geo_level,
       g.city_class,
       CASE WHEN r.res_named_key IS NOT NULL
                 THEN CASE WHEN r.exc_named_parent IS NOT NULL THEN concat('psgc:', r.exc_named_parent) END
            WHEN g.geo_level = 'region' THEN 'ph'
            WHEN g.geo_level IN ('city', 'municipality') AND g.parent_province_psgc IS NOT NULL THEN concat('psgc:', g.parent_province_psgc)
            WHEN g.parent_region_psgc IS NOT NULL THEN concat('psgc:', g.parent_region_psgc) END AS parent_area_key,
       CASE WHEN r.resolve_method IN ('exception', 'name_join')
             AND (g.psgc_code IS NOT NULL OR r.res_named_key IS NOT NULL) THEN 'data' ELSE 'unclassified' END AS row_class,
       CASE WHEN r.resolve_method IN ('exception', 'name_join')
             AND (g.psgc_code IS NOT NULL OR r.res_named_key IS NOT NULL) THEN NULL
            ELSE concat(r.resolve_method, coalesce(concat(' (', r.auto_candidates, ')'), '')) END AS reason
FROM r
LEFT JOIN wf_geo g ON g.psgc_code = r.res_psgc;


-- =============================================================================
-- [2] inputs: the PSMO file, geography and the PSMO exceptions table
--     If your runtime rejects DESCRIBE HISTORY in a subquery, replace those subqueries with
--     CAST(NULL AS BIGINT).
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_specialist_silver__inputs AS
WITH files AS (
  SELECT input_table, _source_key, _source_file, _source_sheet, _ingested_at, count(*) AS input_rows
  FROM public_health.silver.workforce_specialist_silver__classified
  GROUP BY input_table, _source_key, _source_file, _source_sheet, _ingested_at)
SELECT silver_build_id AS build_id, 'public_health.silver.workforce_specialist_silver' AS target_table,
       'bronze_source' AS input_kind, f.input_table,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.workforce_psmo_oncologists_bronze)) AS input_table_version,
       f._source_key AS source_key, f._source_file AS source_file, f._source_sheet AS source_sheet,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.batch_id) END         AS load_batch_id,
       CASE WHEN count(m.batch_id) = 1 THEN max(m.content_checksum) END AS content_checksum,
       f._ingested_at AS ingested_at, f.input_rows, CAST(NULL AS STRING) AS reference_version,
       count(m.batch_id) AS metadata_matches      -- gate only
FROM files f
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON m.source_name = f._source_key AND lower(m.status) = 'processed'
 AND endswith(m.raw_file_path, concat('/', f._source_file))
 AND m.source_sheet <=> f._source_sheet AND m.retrieved_at = f._ingested_at
GROUP BY f.input_table, f._source_key, f._source_file, f._source_sheet, f._ingested_at, f.input_rows
UNION ALL
SELECT silver_build_id, 'public_health.silver.workforce_specialist_silver', 'table', t.table_name, t.v,
       CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING), t.checksum,
       CAST(NULL AS TIMESTAMP), t.n, CAST(NULL AS STRING), CAST(NULL AS BIGINT)
FROM (SELECT 'public_health.silver.geography_silver' AS table_name,
             (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.geography_silver)) AS v,
             (SELECT count(*) FROM wf_geo) AS n, geography_checksum AS checksum
      UNION ALL
      SELECT 'public_health.silver.workforce_psmo_area_exceptions',
             (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.workforce_psmo_area_exceptions)),
             (SELECT count(*) FROM public_health.silver.workforce_psmo_area_exceptions), CAST(NULL AS STRING)) t;


-- =============================================================================
-- [3] candidate (staging table)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_specialist_silver__candidate AS
SELECT area_key, area_label_source, geo_level, psgc_code, parent_area_key, city_class, region_as_published,
       is_composite_area, component_psgc_codes, resolve_method AS area_resolution_method,
       _as_of_date AS snapshot_date,
       CASE WHEN wf_num(doctor_count) IS NOT NULL AND wf_num(doctor_count) = floor(wf_num(doctor_count))
            THEN CAST(wf_num(doctor_count) AS BIGINT) END                       AS listed_oncologist_count,
       CASE WHEN doctor_count IS NULL OR trim(doctor_count) = '' THEN 'blank'
            WHEN wf_num(doctor_count) IS NULL OR wf_num(doctor_count) <> floor(wf_num(doctor_count)) THEN 'parse_error'
            ELSE 'ok' END                                                       AS count_status,
       'unconfirmed'                                                            AS count_unit,
       silver_build_id                                                          AS _silver_build_id,
       _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date,
       map('listed_oncologist_count', 'doctor_count')                           AS _metric_source_columns
FROM public_health.silver.workforce_specialist_silver__classified
WHERE row_class = 'data';


-- =============================================================================
-- [4] gates: every row must have failures = 0
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_specialist_silver__gates AS
SELECT 'inputs: no PSMO file in bronze' AS gate,
       CASE WHEN count(*) = 0 THEN 1 ELSE 0 END AS failures
  FROM public_health.silver.workforce_specialist_silver__inputs WHERE input_kind = 'bronze_source'
UNION ALL
SELECT 'inputs: file with more than one load time', count(*) FROM (
  SELECT 1 FROM public_health.silver.workforce_specialist_silver__inputs WHERE input_kind = 'bronze_source'
  GROUP BY source_key, source_file HAVING count(*) > 1)
UNION ALL
SELECT 'inputs: more than one ingestion log match', count(*)
  FROM public_health.silver.workforce_specialist_silver__inputs WHERE input_kind = 'bronze_source' AND metadata_matches > 1
UNION ALL
SELECT 'inputs: no processed ingestion log match (strict_load_lookup = true)', count(*)
  FROM public_health.silver.workforce_specialist_silver__inputs
  WHERE input_kind = 'bronze_source' AND metadata_matches = 0 AND strict_load_lookup
UNION ALL
SELECT 'area does not resolve exactly once (add it to workforce_psmo_area_exceptions after review)', count(*)
  FROM public_health.silver.workforce_specialist_silver__classified WHERE row_class <> 'data'
UNION ALL
SELECT 'PSMO exception code or component code not found in geography', count(*) FROM (
  SELECT psgc_code AS code FROM wf_psmo_exc WHERE psgc_code IS NOT NULL
  UNION SELECT code FROM (SELECT explode(component_psgc_codes) AS code FROM wf_psmo_exc WHERE component_psgc_codes IS NOT NULL)) x
  LEFT ANTI JOIN wf_geo g ON g.psgc_code = x.code
UNION ALL
-- added 2026-10-19 (rule 2a, same gate as workforce_silver_01)
SELECT 'PSMO exceptions: child_region_codes that are not a region of the geography snapshot', count(*) FROM (
  SELECT DISTINCT code FROM (SELECT explode(child_region_codes) AS code FROM wf_psmo_exc
                             WHERE child_region_codes IS NOT NULL)) x
  LEFT ANTI JOIN (SELECT substr(psgc_code, 1, 2) AS code FROM wf_geo WHERE geo_level = 'region') g ON g.code = x.code
UNION ALL
SELECT 'count that is not a whole number', count(*)
  FROM public_health.silver.workforce_specialist_silver__candidate WHERE count_status = 'parse_error'
UNION ALL
SELECT 'negative count', count(*)
  FROM public_health.silver.workforce_specialist_silver__candidate WHERE listed_oncologist_count < 0
UNION ALL
SELECT 'key column is null', count(*)
  FROM public_health.silver.workforce_specialist_silver__candidate
  WHERE _source_key IS NULL OR snapshot_date IS NULL OR area_label_source IS NULL OR geo_level IS NULL
UNION ALL
SELECT 'key not unique', count(*) FROM (
  SELECT 1 FROM public_health.silver.workforce_specialist_silver__candidate
  GROUP BY _source_key, snapshot_date, area_label_source HAVING count(*) > 1)
UNION ALL
SELECT 'lineage column null', count(*)
  FROM public_health.silver.workforce_specialist_silver__candidate
  WHERE _silver_build_id IS NULL OR _source_file IS NULL OR _source_row_num IS NULL OR _as_of_date IS NULL
UNION ALL
SELECT 'silver rows <> bronze rows read (one observation per listing)', abs(s.n - i.n)
  FROM (SELECT count(*) AS n FROM public_health.silver.workforce_specialist_silver__candidate) s,
       (SELECT coalesce(sum(input_rows), 0) AS n FROM public_health.silver.workforce_specialist_silver__inputs
        WHERE input_kind = 'bronze_source') i;


-- =============================================================================
-- [5] build log row; STOP if a gate failed (the failed build is logged first)
-- =============================================================================
CREATE OR REPLACE TEMP VIEW specialist_build_log AS
SELECT silver_build_id                                         AS build_id,
       'silver'                                                AS layer,
       'workforce'                                             AS domain,
       'public_health.silver.workforce_specialist_silver'      AS target_table,
       silver_build_started_at                                 AS started_at,
       current_timestamp()                                     AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       CASE WHEN g.failed_gates = 0 THEN (SELECT count(*) FROM public_health.silver.workforce_specialist_silver__candidate) END AS row_count,
       CAST(NULL AS BIGINT)                                    AS target_table_version,
       code_version                                            AS code_version,
       to_json(named_struct('strict_load_lookup', strict_load_lookup))                                  AS parameters,
       job_run_id                                              AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.silver.workforce_specialist_silver__gates) g;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
       target_table_version, code_version, parameters, run_id, error_message
FROM specialist_build_log WHERE status = 'failed';

SELECT raise_error(concat('workforce_specialist_silver was NOT published. ', error_message))
FROM specialist_build_log WHERE status = 'failed';


-- =============================================================================
-- [6] write the table (full rebuild)
-- =============================================================================
CREATE OR REPLACE TABLE public_health.silver.workforce_specialist_silver AS
SELECT * FROM public_health.silver.workforce_specialist_silver__candidate;


-- =============================================================================
-- [7] record the build
-- =============================================================================
INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.silver.workforce_specialist_silver),
       -- Delta version just written. If your runtime rejects this line, use CAST(NULL AS BIGINT).
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.workforce_specialist_silver)),
       code_version, parameters, run_id, error_message
FROM specialist_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
       source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version
FROM public_health.silver.workforce_specialist_silver__inputs;

-- Only rows not loaded are stored (same as diseases). Every PSMO row is loaded when the gates pass,
-- so this inserts nothing today; it is here so a future non-data row is recorded.
INSERT INTO public_health.quality.row_disposition
  (build_id, target_table, source_key, source_file, source_sheet, source_row_num, load_batch_id,
   content_checksum, disposition, reason, target_key, recorded_at)
SELECT silver_build_id, 'public_health.silver.workforce_specialist_silver',
       c._source_key, c._source_file, c._source_sheet, c._source_row_num, i.load_batch_id, i.content_checksum,
       'dropped_non_data', c.reason, CAST(NULL AS STRING), current_timestamp()
FROM public_health.silver.workforce_specialist_silver__classified c
LEFT JOIN public_health.silver.workforce_specialist_silver__inputs i
  ON i.input_kind = 'bronze_source' AND i.source_key = c._source_key AND i.source_file = c._source_file
 AND i.source_sheet <=> c._source_sheet
WHERE c.row_class <> 'data';


-- =============================================================================
-- [8] summary, then remove the staging tables (__classified is kept until the next run)
-- =============================================================================
DROP TABLE IF EXISTS public_health.silver.workforce_specialist_silver__candidate;
DROP TABLE IF EXISTS public_health.silver.workforce_specialist_silver__gates;
DROP TABLE IF EXISTS public_health.silver.workforce_specialist_silver__inputs;

SELECT area_resolution_method, geo_level, count(*) AS listings, sum(listed_oncologist_count) AS listed_count
FROM public_health.silver.workforce_specialist_silver
GROUP BY area_resolution_method, geo_level
ORDER BY area_resolution_method, geo_level;
