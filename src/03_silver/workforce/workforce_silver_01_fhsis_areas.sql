-- =============================================================================
-- Classifies every FHSIS health-worker bronze row and resolves its area once, for the two tables
-- built from it (02 headcount, 03 denominator). Writes no published table.
-- Follows workforce-silver-plan.md (section 4.2) and lineage-qc-contract.md (v1.2).
--
-- Output (staging, kept until the next run so you can see how every row was resolved)
--   public_health.silver.workforce_fhsis__resolved   one row per FHSIS bronze row
--   public_health.silver.workforce_fhsis__versions   Delta version of every table this file read
--   public_health.silver.workforce_fhsis__gates      gate results of this step
--
-- Area resolution, in this order; each labelled row resolves exactly once (plan 4.2)
--   1. row override (workforce_area_override), bound to the file checksum in ingestion_metadata
--   2. 2025 rows with a usable code: join geography on psgc_code
--   3. workforce_area_exceptions: source + year range + label (+ parent region label; a blank
--      parent matches any parent)
--   4. name join: name core + level + parent region (child_region_codes); exactly one candidate.
--      A label with a city token matches cities only; otherwise a province wins over cities and
--      municipalities of the same name.
--   Anything else stops the build: add the label to the exceptions file after review.
--
-- Needs
--   workforce_silver_00_reference.sql has been run
--   public_health.silver.geography_silver exists (one PSGC snapshot is read; see [2])
--   Bronze QC passed for doh_fhsis_demographic
--
-- Differences from the contract, because this is plain SQL (same as the diseases files)
--   * Bronze is read at its current version, not pinned with VERSION AS OF. Run 01, 02 and 03 in
--     one job right after bronze QC. 02 and 03 stop if bronze changed after this file ran.
--   * Staging tables hold the intermediate results.
--
-- Rule 2a (2026-10-19)
--   - Settings in [0], one place for the whole FHSIS chain. 01 writes them to
--     public_health.silver.workforce_fhsis__settings; 02 and 03 read them from there and record
--     them in build_log.parameters, where workforce_silver_qc.py reads them.
--       fhsis_coded_years              files that print a PSGC code per row (was "year = 2025"
--                                      typed in five places here and in 02 and the QC)
--       province_coverage_change_year  first year a province row excludes only HUC / ICC (G1;
--                                      was "year <= 2022" in 02 and 03, "year = 2023" in 02)
--       nurse_definition_break_year    PHN count break (was 2019 in 02)
--       geography_expected_regions     regions in the PSGC snapshot (gate; PSGC Q2_2024 has 18)
--   - New gate: every child_region_codes value in workforce_area_exceptions is a region of the
--     geography snapshot (a wrong prefix would make the name join find nothing for that region).
-- =============================================================================

-- [0] settings (read by 02 and 03 through workforce_fhsis__settings)
DECLARE OR REPLACE VARIABLE fhsis_coded_years ARRAY<INT> DEFAULT array(2025);
DECLARE OR REPLACE VARIABLE province_coverage_change_year INT DEFAULT 2023;
DECLARE OR REPLACE VARIABLE nurse_definition_break_year INT DEFAULT 2019;
DECLARE OR REPLACE VARIABLE geography_expected_regions INT DEFAULT 18;   -- PSGC Q2_2024: 17 + Negros Island Region

-- [1] helper functions (same rules as norm(), core() and loose() in build_workforce_area_exceptions.py)
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


-- [2] geography: public_health.silver.geography_silver, one PSGC snapshot (the latest
--     content_checksum, same rule as the facilities files). This view is the only place that reads
--     the geography table; workforce_silver_04_specialist.sql has the same view (keep both identical).
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


-- [3] reference tables, typed
CREATE OR REPLACE TEMP VIEW wf_exc AS
SELECT _source_key,
       CAST(year_from AS INT)                                          AS year_from,
       CAST(year_to AS INT)                                            AS year_to,
       match_role,
       area_label_norm,
       nullif(trim(parent_label_norm), '')                             AS parent_label_norm,
       CASE WHEN nullif(trim(psgc_code), '') IS NOT NULL THEN lpad(trim(psgc_code), 10, '0') END AS psgc_code,
       nullif(trim(area_key), '')                                      AS named_area_key,
       nullif(trim(named_key_level), '')                               AS named_key_level,
       CASE WHEN nullif(trim(named_key_parent_psgc), '') IS NOT NULL
            THEN lpad(trim(named_key_parent_psgc), 10, '0') END        AS named_key_parent_psgc,
       CASE WHEN nullif(trim(child_region_codes), '') IS NOT NULL
            THEN transform(split(child_region_codes, ';'), x -> lpad(trim(x), 2, '0')) END AS child_region_codes,
       coalesce(lower(trim(is_superseded_area)) = 'true', false)       AS is_superseded_area
FROM public_health.silver.workforce_area_exceptions
WHERE _source_key = 'doh_fhsis_demographic';

-- File version of each FHSIS sheet (the override binding needs the checksum; plan 8.3)
CREATE OR REPLACE TEMP VIEW wf_fhsis_file_versions AS
SELECT i._source_file, i._source_sheet, count(m.batch_id) AS log_matches,
       max(m.content_checksum) AS content_checksum
FROM (SELECT DISTINCT _source_key, _source_file, _source_sheet, _ingested_at
      FROM public_health.bronze.workforce_fhsis_health_workers_bronze
      WHERE _source_key = 'doh_fhsis_demographic') i
LEFT JOIN public_health.bronze.ingestion_metadata m
  ON  m.source_name = i._source_key AND lower(m.status) = 'processed'
  AND endswith(m.raw_file_path, concat('/', i._source_file))
  AND m.source_sheet <=> i._source_sheet AND m.retrieved_at = i._ingested_at
GROUP BY i._source_file, i._source_sheet;

CREATE OR REPLACE TEMP VIEW wf_override AS
SELECT o._source_key, o._source_file, nullif(trim(o._source_sheet), '') AS _source_sheet,
       CAST(o._source_row_num AS INT) AS _source_row_num, o._content_checksum, o.original_label,
       o.proposed_area_key, lower(trim(o.review_status)) AS review_status,
       v.content_checksum AS current_checksum,
       (v.log_matches = 1 AND v.content_checksum = o._content_checksum) AS bound_ok
FROM public_health.silver.workforce_area_override o
LEFT JOIN wf_fhsis_file_versions v
  ON v._source_file = o._source_file AND v._source_sheet <=> nullif(trim(o._source_sheet), '')
WHERE o._source_key = 'doh_fhsis_demographic';


-- [4] bronze rows with label kind, code and region context, saved to a staging table
--     label_kind: labelled / legend / blank. Region rows: by the region labels in the exceptions
--     file; in fhsis_coded_years (2025) by code. Each row gets the region row above it (published
--     membership).
CREATE OR REPLACE TABLE public_health.silver.workforce_fhsis__ctx AS
WITH b AS (
  SELECT t._source_key, t._source_file, t._source_sheet, t._source_row_num, t._as_of_date, t._ingested_at,
         try_cast(regexp_extract(t._source_file, '_([0-9]{4})[.]xlsx$', 1) AS INT)   AS year,
         nullif(trim(t.area_name), '')                                                AS area_label_source,
         wf_norm(t.area_name)                                                         AS label_norm,
         wf_core(t.area_name)                                                         AS label_core,
         wf_has_city(t.area_name)                                                     AS label_has_city,
         wf_loose(t.area_name)                                                        AS label_loose,
         nullif(trim(t.psgc_code), '')                                                AS code_printed,
         -- 9 or 10 digits, left-padded. Other lengths are not used as a code (G12).
         CASE WHEN regexp_replace(trim(t.psgc_code), '[.]0$', '') RLIKE '^[0-9]{9,10}$'
              THEN lpad(regexp_replace(trim(t.psgc_code), '[.]0$', ''), 10, '0') END   AS code10,
         -- every column of the row as text, so 02 and 03 read a field by its column name
         from_json(to_json(struct(t.*)), 'MAP<STRING,STRING>')                        AS cells
  FROM public_health.bronze.workforce_fhsis_health_workers_bronze t
  WHERE t._source_key = 'doh_fhsis_demographic'),
k AS (
  SELECT b.*,
         CASE WHEN b.area_label_source IS NULL THEN 'blank'
              WHEN b.area_label_source RLIKE '^(?i)(Legend|[*]|0 *[-=])' THEN 'legend'
              ELSE 'labelled' END                                                     AS label_kind,
         er.psgc_code AS exc_region_code, er.child_region_codes AS exc_region_children,
         gc.geo_level AS code_geo_level
  FROM b
  LEFT JOIN wf_exc er
    ON er.match_role = 'region' AND b.year BETWEEN er.year_from AND er.year_to AND er.area_label_norm = b.label_norm
  LEFT JOIN wf_geo gc ON gc.psgc_code = b.code10 AND array_contains(fhsis_coded_years, b.year)),
r AS (
  SELECT k.*,
         coalesce(label_kind = 'labelled' AND (exc_region_code IS NOT NULL OR code_geo_level = 'region'), false) AS is_region_row,
         CASE WHEN label_kind <> 'labelled' THEN NULL
              WHEN exc_region_code IS NOT NULL THEN exc_region_children
              WHEN code_geo_level = 'region' THEN array(substr(code10, 1, 2)) END             AS own_region_children
  FROM k)
SELECT r.*,
       last_value(CASE WHEN is_region_row THEN area_label_source END, true) OVER w AS region_label_ctx,
       last_value(CASE WHEN is_region_row THEN own_region_children END, true) OVER w AS region_children_ctx,
       last_value(CASE WHEN is_region_row THEN _source_row_num END, true) OVER w AS region_row_ctx,
       -- "0 = No Data" printed in the file's legend (2018): a 0 there is not a reported zero
       bool_or(label_kind = 'legend' AND label_norm RLIKE '^0 NO DATA') OVER (PARTITION BY _source_file) AS zero_means_no_data
FROM r
WINDOW w AS (PARTITION BY _source_file, _source_sheet ORDER BY _source_row_num
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);


-- [5] candidates from each resolution step, one row per labelled bronze row
CREATE OR REPLACE TEMP VIEW wf_fhsis_match AS
WITH c AS (
  SELECT * FROM public_health.silver.workforce_fhsis__ctx WHERE label_kind = 'labelled'),
ov AS (
  SELECT c._source_file, c._source_sheet, c._source_row_num, o.review_status, o.proposed_area_key
  FROM c
  JOIN wf_override o
    ON  o._source_file = c._source_file AND o._source_sheet <=> c._source_sheet
    AND o._source_row_num = c._source_row_num AND o.bound_ok AND wf_norm(o.original_label) = c.label_norm),
exc AS (   -- a row with the row's own parent label wins over a row with a blank parent
  SELECT c._source_file, c._source_sheet, c._source_row_num, e.psgc_code, e.named_area_key,
         e.named_key_level, e.named_key_parent_psgc, e.is_superseded_area,
         dense_rank() OVER (PARTITION BY c._source_file, c._source_sheet, c._source_row_num
                            ORDER BY CASE WHEN e.parent_label_norm IS NULL THEN 1 ELSE 0 END) AS rk
  FROM c
  JOIN wf_exc e
    ON  e.match_role = 'area' AND c.year BETWEEN e.year_from AND e.year_to AND e.area_label_norm = c.label_norm
    AND (e.parent_label_norm IS NULL OR e.parent_label_norm = wf_norm(c.region_label_ctx))
  WHERE NOT c.is_region_row),
exc1 AS (
  SELECT _source_file, _source_sheet, _source_row_num, count(*) AS exc_n,
         max(psgc_code) AS exc_psgc, max(named_area_key) AS exc_named_key, max(named_key_level) AS exc_named_level,
         max(named_key_parent_psgc) AS exc_named_parent, bool_or(is_superseded_area) AS exc_superseded
  FROM exc WHERE rk = 1
  GROUP BY _source_file, _source_sheet, _source_row_num),
auto AS (
  SELECT c._source_file, c._source_sheet, c._source_row_num,
         count_if(g.geo_level = 'province')  AS n_prov,
         count_if(g.geo_level <> 'province') AS n_other,
         max(CASE WHEN g.geo_level = 'province' THEN g.psgc_code END)  AS prov_code,
         max(CASE WHEN g.geo_level <> 'province' THEN g.psgc_code END) AS other_code,
         concat_ws('; ', collect_list(concat(g.geo_name, ' ', g.psgc_code, ' (', g.geo_level, ')'))) AS candidates
  FROM c
  JOIN wf_geo g
    ON  g.name_core = c.label_core
    AND array_contains(c.region_children_ctx, substr(g.psgc_code, 1, 2))
    AND ((c.label_has_city AND g.geo_level = 'city')
         OR (NOT c.label_has_city AND g.geo_level IN ('province', 'city', 'municipality')))
  WHERE NOT c.is_region_row
  GROUP BY c._source_file, c._source_sheet, c._source_row_num)
SELECT c._source_file, c._source_sheet, c._source_row_num,
       ov.review_status AS override_status, ov.proposed_area_key,
       gc.psgc_code AS code_geo_psgc, gc.name_loose AS code_geo_name_loose,
       exc1.exc_n, exc1.exc_psgc, exc1.exc_named_key, exc1.exc_named_level, exc1.exc_named_parent, exc1.exc_superseded,
       CASE WHEN auto.n_prov > 0 THEN auto.n_prov ELSE auto.n_other END       AS auto_n,
       CASE WHEN auto.n_prov > 0 THEN auto.prov_code ELSE auto.other_code END AS auto_code,
       auto.candidates                                                        AS auto_candidates
FROM c
LEFT JOIN ov   ON ov._source_file = c._source_file AND ov._source_sheet <=> c._source_sheet AND ov._source_row_num = c._source_row_num
LEFT JOIN wf_geo gc ON gc.psgc_code = c.code10 AND array_contains(fhsis_coded_years, c.year)
LEFT JOIN exc1 ON exc1._source_file = c._source_file AND exc1._source_sheet <=> c._source_sheet AND exc1._source_row_num = c._source_row_num
LEFT JOIN auto ON auto._source_file = c._source_file AND auto._source_sheet <=> c._source_sheet AND auto._source_row_num = c._source_row_num;


-- [6] resolved rows (staging): the area of every labelled row, with its geography attributes
CREATE OR REPLACE TABLE public_health.silver.workforce_fhsis__resolved AS
WITH m AS (
  SELECT x.*, m.override_status, m.proposed_area_key, m.code_geo_psgc, m.code_geo_name_loose,
         m.exc_n, m.exc_psgc, m.exc_named_key, m.exc_named_level, m.exc_named_parent, m.exc_superseded,
         m.auto_n, m.auto_code, m.auto_candidates,
         CASE WHEN x.label_kind <> 'labelled' THEN NULL
              WHEN m.override_status IN ('proposed', 'accepted') THEN 'override'
              WHEN x.is_region_row AND NOT array_contains(fhsis_coded_years, x.year) THEN 'exception'
              WHEN array_contains(fhsis_coded_years, x.year) AND x.code10 IS NOT NULL AND m.code_geo_psgc IS NOT NULL THEN 'psgc_code'
              WHEN array_contains(fhsis_coded_years, x.year) AND x.code10 IS NOT NULL THEN 'code_not_in_geography'
              WHEN m.exc_n = 1 THEN 'exception'
              WHEN m.exc_n > 1 THEN 'ambiguous_exception'
              WHEN m.auto_n = 1 THEN 'name_join'
              WHEN m.auto_n > 1 THEN 'ambiguous_name'
              ELSE 'unresolved' END AS resolve_method
  FROM public_health.silver.workforce_fhsis__ctx x
  LEFT JOIN wf_fhsis_match m
    ON m._source_file = x._source_file AND m._source_sheet <=> x._source_sheet AND m._source_row_num = x._source_row_num),
r AS (
  SELECT m.*,
         CASE m.resolve_method
              WHEN 'override'  THEN substr(m.proposed_area_key, 6)
              WHEN 'exception' THEN CASE WHEN m.is_region_row THEN m.exc_region_code ELSE m.exc_psgc END
              WHEN 'psgc_code' THEN m.code10
              WHEN 'name_join' THEN m.auto_code END                                      AS res_psgc,
         CASE WHEN m.resolve_method = 'exception' AND NOT m.is_region_row THEN m.exc_named_key END AS res_named_key
  FROM m)
SELECT r._source_key, r._source_file, r._source_sheet, r._source_row_num, r._as_of_date, r._ingested_at,
       r.year, r.area_label_source, r.label_norm, r.label_kind, r.code_printed, r.code10, r.cells,
       r.is_region_row, r.region_label_ctx, r.region_row_ctx, r.zero_means_no_data,
       r.resolve_method, r.override_status, r.auto_candidates,
       coalesce(r.res_named_key, CASE WHEN r.res_psgc IS NOT NULL THEN concat('psgc:', r.res_psgc) END) AS area_key,
       r.res_psgc                                                                         AS psgc_code,
       CASE WHEN r.res_named_key IS NOT NULL THEN r.exc_named_level ELSE g.geo_level END  AS geo_level,
       g.city_class,
       CASE WHEN r.res_named_key IS NOT NULL
                 THEN CASE WHEN r.exc_named_parent IS NOT NULL THEN concat('psgc:', r.exc_named_parent) END
            WHEN g.geo_level = 'region' THEN 'ph'
            WHEN g.geo_level IN ('city', 'municipality') AND g.parent_province_psgc IS NOT NULL
                 THEN concat('psgc:', g.parent_province_psgc)
            WHEN g.parent_region_psgc IS NOT NULL THEN concat('psgc:', g.parent_region_psgc) END AS parent_area_key,
       coalesce(CASE WHEN r.res_named_key IS NOT NULL THEN r.exc_superseded END, false)   AS is_superseded_area,
       (g.psgc_code IS NOT NULL OR r.res_named_key IS NOT NULL)                           AS area_in_geography,
       -- fhsis_coded_years: the printed code is in geography under another name (loose key: spelling and
       -- abbreviations ignored) and no exception confirms it (a swapped code looks like this; G10).
       -- Region rows are excluded: they are region rows because their code is a region in geography,
       -- and their labels ('Region 1', 'NCR') never match the geography names.
       coalesce(r.resolve_method = 'psgc_code' AND NOT r.is_region_row
                AND r.code_geo_name_loose <> r.label_loose
                AND NOT (r.exc_psgc <=> r.code10), false)                                 AS code_name_mismatch,
       r.label_loose, r.code_geo_name_loose,
       CASE WHEN r.is_region_row THEN r.area_label_source ELSE r.region_label_ctx END     AS region_as_published
FROM r
LEFT JOIN wf_geo g ON g.psgc_code = r.res_psgc;


-- [7] Delta version of every table read here; 02 and 03 copy them into quality.build_inputs.
--     If your runtime rejects DESCRIBE HISTORY in a subquery, use the NULL version below instead.
--     content_checksum: the geography snapshot read (recorded in build_inputs like the facilities files).
CREATE OR REPLACE TABLE public_health.silver.workforce_fhsis__versions AS
SELECT 'public_health.bronze.workforce_fhsis_health_workers_bronze' AS table_name,
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.bronze.workforce_fhsis_health_workers_bronze)) AS table_version,
       (SELECT count(*) FROM public_health.bronze.workforce_fhsis_health_workers_bronze) AS table_rows,
       CAST(NULL AS STRING) AS content_checksum
UNION ALL SELECT 'public_health.silver.geography_silver',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.geography_silver)),
       (SELECT count(*) FROM wf_geo), geography_checksum
UNION ALL SELECT 'public_health.silver.workforce_area_exceptions',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.workforce_area_exceptions)),
       (SELECT count(*) FROM public_health.silver.workforce_area_exceptions), CAST(NULL AS STRING)
UNION ALL SELECT 'public_health.silver.workforce_area_override',
       (SELECT max(version) FROM (DESCRIBE HISTORY public_health.silver.workforce_area_override)),
       (SELECT count(*) FROM public_health.silver.workforce_area_override), CAST(NULL AS STRING);
-- NULL version (use this instead if the statement above fails):
-- CREATE OR REPLACE TABLE public_health.silver.workforce_fhsis__versions AS
-- SELECT t AS table_name, CAST(NULL AS BIGINT) AS table_version, CAST(NULL AS BIGINT) AS table_rows,
--        CASE WHEN t LIKE '%geography_silver' THEN geography_checksum END AS content_checksum
-- FROM VALUES ('public_health.bronze.workforce_fhsis_health_workers_bronze'), ('public_health.silver.geography_silver'),
--             ('public_health.silver.workforce_area_exceptions'), ('public_health.silver.workforce_area_override') AS v(t);


-- [7a] settings for 02 and 03 (one row). Rewritten on every run of this file.
CREATE OR REPLACE TABLE public_health.silver.workforce_fhsis__settings AS
SELECT fhsis_coded_years             AS fhsis_coded_years,
       province_coverage_change_year AS province_coverage_change_year,
       nurse_definition_break_year   AS nurse_definition_break_year,
       geography_checksum            AS geography_checksum,
       current_timestamp()           AS written_at;


-- [8] gates: every row must have failures = 0
CREATE OR REPLACE TABLE public_health.silver.workforce_fhsis__gates AS
SELECT 'geography snapshot: regions <> geography_expected_regions, or no snapshot found' AS gate,
       CASE WHEN geography_checksum IS NULL THEN 1
            ELSE abs(count_if(geo_level = 'region') - geography_expected_regions) END AS failures,
       concat('content_checksum ', coalesce(geography_checksum, 'none'), '; ', count(*), ' areas; ',
              count_if(geo_level = 'region'), ' regions, setting ', geography_expected_regions) AS detail
FROM wf_geo
UNION ALL
SELECT 'exceptions: child_region_codes that are not a region of the geography snapshot', count(*),
       left(concat_ws('; ', collect_list(x.code)), 1000)
FROM (SELECT DISTINCT code FROM (SELECT explode(child_region_codes) AS code FROM wf_exc
                                 WHERE child_region_codes IS NOT NULL)) x
LEFT ANTI JOIN (SELECT substr(psgc_code, 1, 2) AS code FROM wf_geo WHERE geo_level = 'region') g ON g.code = x.code
UNION ALL
SELECT 'geography snapshot: city without city_class (HUC / ICC / CC)', count(*),
       left(concat_ws('; ', collect_list(concat(psgc_code, ' ', geo_name))), 1000)
FROM wf_geo WHERE geo_level = 'city' AND city_class IS NULL
UNION ALL
SELECT 'labelled row that resolves to no area or to several (add it to workforce_area_exceptions after review)',
       count(*),
       left(concat_ws('; ', slice(collect_list(concat(year, ' ', _source_sheet, ' row ', _source_row_num, ' [',
            coalesce(region_label_ctx, ''), '] ', area_label_source, ': ', resolve_method,
            coalesce(concat(' (', auto_candidates, ')'), ''))), 1, 15)), 1000) AS detail
FROM public_health.silver.workforce_fhsis__resolved
WHERE label_kind = 'labelled'
  AND (resolve_method NOT IN ('override', 'exception', 'psgc_code', 'name_join', 'code_not_in_geography')
       OR (resolve_method <> 'code_not_in_geography' AND NOT area_in_geography))
UNION ALL
SELECT 'exception or override PSGC code not found in geography', count(*),
       left(concat_ws('; ', collect_list(x.code)), 1000)
FROM (SELECT DISTINCT psgc_code AS code FROM wf_exc WHERE psgc_code IS NOT NULL
      UNION SELECT DISTINCT substr(proposed_area_key, 6) FROM wf_override) x
LEFT ANTI JOIN wf_geo g ON g.psgc_code = x.code
UNION ALL
SELECT 'override not bound to the current file version, or its row or label changed (G6, G10)', count(*),
       left(concat_ws('; ', collect_list(concat(o._source_sheet, ' row ', o._source_row_num, ' ', o.original_label))), 1000)
FROM wf_override o
LEFT JOIN public_health.silver.workforce_fhsis__resolved r
  ON r._source_file = o._source_file AND r._source_sheet <=> o._source_sheet
 AND r._source_row_num = o._source_row_num AND r.label_norm = wf_norm(o.original_label)
WHERE o._source_file IN (SELECT _source_file FROM wf_fhsis_file_versions)
  AND NOT (coalesce(o.bound_ok, false) AND r._source_row_num IS NOT NULL)
UNION ALL
SELECT 'printed code (fhsis_coded_years) is another area in geography (needs an override or a name_variant exception; G10)', count(*),
       left(concat_ws('; ', collect_list(concat('row ', _source_row_num, ' ', area_label_source, ' code ', code10))), 1000)
FROM public_health.silver.workforce_fhsis__resolved WHERE code_name_mismatch
UNION ALL
SELECT 'FHSIS row with a file name that gives no year', count(*), CAST(NULL AS STRING)
FROM public_health.silver.workforce_fhsis__resolved WHERE year IS NULL;

SELECT raise_error(concat('workforce FHSIS area resolution failed: ', gate, ' = ', failures, '. ', coalesce(detail, '')))
FROM public_health.silver.workforce_fhsis__gates WHERE failures > 0;

DROP TABLE IF EXISTS public_health.silver.workforce_fhsis__ctx;


-- [9] summary
SELECT year, _source_sheet, count(*) AS bronze_rows,
       count_if(label_kind = 'labelled') AS labelled, count_if(label_kind = 'legend') AS legend,
       count_if(label_kind = 'blank') AS blank,
       count_if(resolve_method = 'psgc_code') AS by_code, count_if(resolve_method = 'override') AS by_override,
       count_if(resolve_method = 'exception') AS by_exception, count_if(resolve_method = 'name_join') AS by_name
FROM public_health.silver.workforce_fhsis__resolved
GROUP BY year, _source_sheet
ORDER BY year, _source_sheet;