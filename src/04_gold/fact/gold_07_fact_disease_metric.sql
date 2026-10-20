-- ========================================
-- Builds public_health.gold.fact_disease_metric
--   One row is: one metric of one disease, area, period, age group and sex from one source
--   Primary key: fact_disease_metric_key = xxhash64 of the natural values of the grain.
--                Stable across rebuilds.
--   Grain: (disease_key, area_key, date_key, data_source_key, age_group, sex, metric_name,
--          metric_basis)
--
-- Reads
--   public_health.silver.diseases_metric_silver
--   public_health.silver.diseases_source_coverage_silver
--   public_health.silver.diseases_deaths_age_silver
--   public_health.silver.diseases_tb_programme_silver
--   public_health.silver.diseases_hospital_claims_silver   (RESTRICTED, D-47)
--   public_health.gold.dim_disease, dim_geography, dim_date, dim_data_source (gold 01-03, 05)
--
-- Four row sources, told apart by data_source_key and metric_name
--   * metric         diseases_metric_silver, one row per silver row (cases, deaths, prevalence).
--   * deaths_by_age  diseases_deaths_age_silver, as metric_name = 'deaths',
--                    metric_definition = 'registered_deaths', with their own age group.
--   * tb_programme   diseases_tb_programme_silver (FHSIS 2025), one row per silver row:
--                    metric_name = indicator (tpt_given, tpt_eligible_contacts, treatment_cohort,
--                    treatment_success), metric_definition = indicator_definition. drug_resistance
--                    is already in disease_key (tb_all_forms vs tb_drug_resistant). This source has
--                    a SEX split, which is why sex is in the grain.
--   * claims         diseases_hospital_claims_silver (PhilHealth FOI), AGGREGATED to one row per
--                    area x year x case-rate package x metric:
--                      claims_filed                    claims of every status (utilisation)
--                      claims_paid                     claims with status paid
--                      claims_amount_claimed_php       amount claimed, every status
--                      claims_paid_amount_claimed_php  amount claimed on paid claims
--                    The amount is the amount CLAIMED, not paid. Hospital identity is dropped:
--                    restricted source, aggregates only (D-47). A cell built from fewer than
--                    suppression_min_hospitals hospitals is suppressed (value_status
--                    suppressed, value null). Claims are published at THREE geographic levels,
--                    told apart by coverage_basis, each a full pass over the same silver rows and
--                    suppressed at its own level (first run, 2026-10-14: 74% of city /
--                    municipality cells had fewer than 3 hospitals):
--                      facility_location                    the hospital's city / municipality
--                      facility_location_province_excl_huc  its province (HUCs / ICCs excluded)
--                      facility_location_region             its region (every hospital)
--                    The area is where care was delivered, not where the patient lives. Never add
--                    levels together. Series rules (COVID period, 2024 case-rate change, IHD with
--                    MI from 2025) are named settings in diseases_silver_06; gold keeps only
--                    is_preliminary (the latest year).
--
-- Rules
--   * One gold row per silver row for metric, deaths_by_age and tb_programme. Claims are summed
--     per cell (the only aggregation; the hospital level is not published).
--   * date_key = xxhash64(period_basis, period_label) with period_label = the silver
--     period_key, the same as dim_date (gold 02). Weekly rows use iso_week (UP NOAH) and
--     iso_week_ending_date (HDX), D-44 / D-46.
--   * For totals filter age_group = 'all_ages' AND sex = 'both_sexes'. The by-age rows add up
--     to a cause total and the by-sex rows add up to both_sexes: never add them to a total row.
--   * metric_basis is number: silver holds counts (and the FHSIS TPT eligible-contacts estimate,
--     a count of persons). Rates are computed in the marts.
--   * value stays null when value_status is not ok. It is never read as 0.
--   * is_complete_year (metric rows only) = the SOURCE holds every period of the year
--     (diseases_source_coverage_silver.is_complete_year: 12 months, or every ISO week, 52 or 53)
--     AND THIS AREA holds every period the source holds. Annual rows are complete by
--     definition; tb_programme and claims rows are annual (true). It is null on the by-age
--     rows, and so are coverage_basis and is_preliminary.
--   * Sources overlap. The preferred source per metric is in source_priority (gold 10);
--     v_disease_metric_totals (gold 13) flags it as is_preferred_source.
--
-- Build steps (write-audit-publish)
--   [0] build id and settings
--   [1] __inputs     every input, with the build that wrote it and its latest silver QC
--   [2] __candidate  the candidate rows
--   [3] __gates      every gate must have failures = 0
--   [4] stop if a gate failed: the failed build is logged, the published table is not touched
--   [5] write the table from the candidate (full rebuild)
--   [6] record the build in quality.build_log and quality.build_inputs
--   [7] drop the staging tables, then show the summary
--
-- History
--   2026-10-14  Written for the combined data model (from gold_30, v1). TB programme rows and
--               PhilHealth claims added the same evening; sex added to the grain.
--   2026-10-20  Moved to public_health.gold and renamed gold_07. Comments updated (D-44, D-46,
--               D-47, source_priority). 'model' removed from the build log parameters. Weekly
--               date_key values change with the new period_basis of silver (one-time G12 change).
-- ========================================

-- [0] build id and settings: one value each for the whole build
DECLARE OR REPLACE VARIABLE gold_build_id STRING DEFAULT uuid();
DECLARE OR REPLACE VARIABLE gold_build_started_at TIMESTAMP DEFAULT current_timestamp();
DECLARE OR REPLACE VARIABLE gold_target_version BIGINT DEFAULT NULL;
-- true : every silver input needs a succeeded build in quality.build_log.
-- false: a silver table written by a notebook is allowed. Gold inputs always need one.
DECLARE OR REPLACE VARIABLE strict_input_builds BOOLEAN DEFAULT false;
-- true : a silver input whose latest QC (quality.v_table_health) has a FAIL stops the build.
--        No QC run does not stop it; it makes the approval provisional (step [4]).
DECLARE OR REPLACE VARIABLE block_on_silver_qc_fail BOOLEAN DEFAULT true;
DECLARE OR REPLACE VARIABLE code_version STRING DEFAULT NULL;   -- Git commit, if you pass one
DECLARE OR REPLACE VARIABLE job_run_id STRING DEFAULT NULL;     -- {{job.run_id}} from a job
-- Smallest number of hospitals a published claims cell may be built from (D-47, same rule
-- as occupancy). Recorded in build_log.parameters.
DECLARE OR REPLACE VARIABLE suppression_min_hospitals INT DEFAULT 3;


-- ========================================
-- [1] inputs: one row per table or reviewed list read, with the version its latest succeeded
--     build wrote and the status of its latest silver QC (null = no build row, no QC run).
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_disease_metric__inputs AS
SELECT t.input_kind, t.input_table, t.source_file, t.input_rows,
       b.build_id AS input_build_id, b.target_table_version AS input_table_version,
       h.overall_status AS qc_status, h.last_checked_at AS qc_checked_at
FROM (
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_metric_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_metric_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_source_coverage_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_source_coverage_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_deaths_age_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_deaths_age_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_tb_programme_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_tb_programme_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.silver.diseases_hospital_claims_silver' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.silver.diseases_hospital_claims_silver
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_disease' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_disease
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_geography' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_geography
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_date' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_date
  UNION ALL
  SELECT 'table' AS input_kind, 'public_health.gold.dim_data_source' AS input_table, CAST(NULL AS STRING) AS source_file,
         count(*) AS input_rows
  FROM public_health.gold.dim_data_source
) AS t
LEFT JOIN public_health.quality.v_latest_build AS b ON b.target_table = t.input_table
LEFT JOIN public_health.quality.v_table_health AS h
  ON h.table_name = t.input_table AND h.layer = 'silver';


-- ========================================
-- [2] candidate rows
-- ========================================
-- claims: each silver row (one hospital, year, package, status) gets its own area, its province
-- (municipalities and component cities only) and its region from dim_geography, then is counted
-- once at each level. Suppression (hospital count) is applied per level after grouping.
CREATE OR REPLACE TEMP VIEW fdm_claims_src AS
SELECT s.area_key AS area_code, CAST(s.year AS INT) AS year, s.disease_key, s._source_key, s.claim_status,
       s.facility_name_norm, s.claims_count, s.claims_amount_php, s.is_preliminary,
       coalesce(g.area_key, xxhash64(s.area_key)) AS base_key,
       CASE WHEN p.geographic_level = 'province' THEN p.area_key END AS province_key,
       CASE WHEN p.geographic_level = 'region' THEN p.area_key
            WHEN pp.geographic_level = 'region' THEN pp.area_key END AS region_key
FROM public_health.silver.diseases_hospital_claims_silver AS s
LEFT JOIN public_health.gold.dim_geography AS g ON g.area_code = s.area_key
LEFT JOIN public_health.gold.dim_geography AS p ON p.area_key = g.parent_area_key
LEFT JOIN public_health.gold.dim_geography AS pp ON pp.area_key = p.parent_area_key;

CREATE OR REPLACE TEMP VIEW fdm_claims_cells AS
SELECT lvl.roll_level,
       lvl.roll_area_key                                         AS area_key,
       s.year, s.disease_key, s._source_key,
       lvl.coverage_basis,
       coalesce(bool_or(s.is_preliminary), false)                AS is_preliminary,
       count(DISTINCT s.facility_name_norm)                      AS hospitals,
       sum(s.claims_count)                                       AS claims_filed,
       sum(CASE WHEN s.claim_status = 'paid' THEN s.claims_count END) AS claims_paid,
       sum(s.claims_amount_php)                                  AS amount_claimed,
       sum(CASE WHEN s.claim_status = 'paid' THEN s.claims_amount_php END) AS amount_claimed_paid
FROM fdm_claims_src AS s
LATERAL VIEW explode(array(
  named_struct('roll_level', 'base',     'roll_area_key', s.base_key,     'coverage_basis', 'facility_location'),
  named_struct('roll_level', 'province', 'roll_area_key', s.province_key, 'coverage_basis', 'facility_location_province_excl_huc'),
  named_struct('roll_level', 'region',   'roll_area_key', s.region_key,   'coverage_basis', 'facility_location_region')
)) l AS lvl
WHERE lvl.roll_area_key IS NOT NULL
GROUP BY lvl.roll_level, lvl.roll_area_key, s.year, s.disease_key, s._source_key, lvl.coverage_basis;

CREATE OR REPLACE TEMP VIEW fact_disease_metric_rows AS
-- metric -------------------------------------------------------------------------------------
SELECT 'metric'                                   AS row_source,
       m.disease_key                              AS disease_code,
       m.area_key                                 AS area_code,
       m.period_basis,
       m.period_key                               AS period_label,
       m._source_key,
       m.age_scope                                AS age_group,
       CAST(NULL AS SMALLINT)                     AS age_min,
       CAST(NULL AS SMALLINT)                     AS age_max,
       'both_sexes'                               AS sex,   -- diseases_metric_silver is all sexes by design (sex_scope constant)
       m.measure                                  AS metric_name,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value AS DECIMAL(20, 4)) END       AS value,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value_lower AS DECIMAL(20, 4)) END AS value_lower,
       CASE WHEN m.value_status = 'ok' THEN CAST(m.value_upper AS DECIMAL(20, 4)) END AS value_upper,
       m.value_status,
       m.measure_definition                       AS metric_definition,
       m.geo_coverage_basis                       AS coverage_basis,
       CASE WHEN m.period_grain = 'year' THEN c.is_complete_year
            ELSE c.is_complete_year AND ap.area_periods >= c.periods_present END AS is_complete_year,
       m.is_preliminary
FROM public_health.silver.diseases_metric_silver AS m
LEFT JOIN public_health.silver.diseases_source_coverage_silver AS c
  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
 AND c.period_grain = m.period_grain AND c.year = m.year
LEFT JOIN (
  -- periods this area holds in this year, per source and grain
  SELECT _source_key, area_key, period_grain, year, count(DISTINCT period_key) AS area_periods
  FROM public_health.silver.diseases_metric_silver
  GROUP BY _source_key, area_key, period_grain, year
) AS ap
  ON ap._source_key = m._source_key AND ap.area_key = m.area_key
 AND ap.period_grain = m.period_grain AND ap.year = m.year
UNION ALL
-- deaths by age ------------------------------------------------------------------------------
SELECT 'deaths_by_age',
       d.disease_key,
       d.area_key,
       'calendar_year',
       CAST(d.year AS STRING),
       d._source_key,
       d.age_group,
       CAST(d.age_from AS SMALLINT),
       CAST(d.age_to AS SMALLINT),
       'both_sexes',
       'deaths',
       CASE WHEN d.value_status = 'ok' THEN CAST(d.deaths AS DECIMAL(20, 4)) END,
       CAST(NULL AS DECIMAL(20, 4)),
       CAST(NULL AS DECIMAL(20, 4)),
       d.value_status,
       'registered_deaths',
       CAST(NULL AS STRING),
       CAST(NULL AS BOOLEAN),
       CAST(NULL AS BOOLEAN)
FROM public_health.silver.diseases_deaths_age_silver AS d
UNION ALL
-- TB programme (FHSIS TPT, treatment success) ------------------------------------------------
SELECT 'tb_programme',
       t.disease_key,
       t.area_key,
       'calendar_year',                           -- FHSIS reporting year = calendar year
       CAST(t.year AS STRING),
       t._source_key,
       t.age_group,
       CASE t.age_group WHEN '0_14' THEN CAST(0 AS SMALLINT) WHEN '15_over' THEN CAST(15 AS SMALLINT) END,
       CASE t.age_group WHEN '0_14' THEN CAST(14 AS SMALLINT) END,
       t.sex,
       t.indicator,
       CASE WHEN t.value_status = 'ok' THEN CAST(t.value AS DECIMAL(20, 4)) END,
       CAST(NULL AS DECIMAL(20, 4)),
       CAST(NULL AS DECIMAL(20, 4)),
       t.value_status,
       t.indicator_definition,
       CAST(NULL AS STRING),
       true,
       false
FROM public_health.silver.diseases_tb_programme_silver AS t
UNION ALL
-- PhilHealth claims, aggregated per cell and unpivoted to four metrics ------------------------
-- area_code carries the gold area_key as text ('key:<bigint>'); the candidate maps it back.
SELECT 'claims',
       k.disease_key,
       concat('key:', CAST(k.area_key AS STRING)),
       'calendar_year',
       CAST(k.year AS STRING),
       k._source_key,
       'all_ages',
       CAST(NULL AS SMALLINT),
       CAST(NULL AS SMALLINT),
       'both_sexes',
       k.metric_name,
       CASE WHEN k.hospitals >= suppression_min_hospitals THEN CAST(k.raw AS DECIMAL(20, 4)) END,
       CAST(NULL AS DECIMAL(20, 4)),
       CAST(NULL AS DECIMAL(20, 4)),
       CASE WHEN k.hospitals < suppression_min_hospitals THEN 'suppressed' WHEN k.raw IS NULL THEN 'missing' ELSE 'ok' END,
       k.metric_definition,
       k.coverage_basis,
       true,
       k.is_preliminary
FROM (
  SELECT c.*, stack(4,
    'claims_filed',                   'philhealth_claims_filed_all_statuses',           CAST(c.claims_filed AS DECIMAL(20, 4)),
    'claims_paid',                    'philhealth_claims_paid',                         CAST(coalesce(c.claims_paid, 0) AS DECIMAL(20, 4)),
    'claims_amount_claimed_php',      'philhealth_amount_claimed_php_all_statuses',     CAST(c.amount_claimed AS DECIMAL(20, 4)),
    'claims_paid_amount_claimed_php', 'philhealth_amount_claimed_php_on_paid_claims',   CAST(coalesce(c.amount_claimed_paid, 0) AS DECIMAL(20, 4))
  ) AS (metric_name, metric_definition, raw)
  FROM fdm_claims_cells AS c
) AS k;

CREATE OR REPLACE TABLE public_health.gold.fact_disease_metric__candidate AS
SELECT xxhash64(disease_code, area_code, period_basis, period_label, _source_key, age_group, sex, metric_name)
                                                  AS fact_disease_metric_key,
       xxhash64(disease_code)                     AS disease_key,
       CASE WHEN area_code LIKE 'key:%' THEN CAST(substr(area_code, 5) AS BIGINT)   -- claims roll-ups carry the gold key
            ELSE xxhash64(area_code) END          AS area_key,
       xxhash64(period_basis, period_label)       AS date_key,
       xxhash64(_source_key)                      AS data_source_key,
       age_group,
       CASE age_group WHEN 'all_ages' THEN 'All ages' WHEN 'under_1' THEN 'Under 1'
                      WHEN '85_over' THEN '85 and over' WHEN '15_over' THEN '15 and over'
                      WHEN 'not_stated' THEN 'Not stated' WHEN 'age_unknown' THEN 'Age unknown'
                      ELSE replace(age_group, '_', ' to ') END AS age_group_name,
       age_min,
       age_max,
       sex,
       metric_name,
       'number'                                   AS metric_basis,
       value,
       value_lower,
       value_upper,
       value_status,
       metric_definition,
       coverage_basis,
       is_complete_year,
       is_preliminary,
       gold_build_id                              AS _gold_build_id
FROM fact_disease_metric_rows;


-- ========================================
-- [3] gates: every row must have failures = 0
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_disease_metric__gates AS
SELECT 'candidate has no rows' AS gate, CAST(count(*) = 0 AS INT) AS failures
FROM public_health.gold.fact_disease_metric__candidate
UNION ALL
SELECT 'input without a succeeded build', count(*)
FROM public_health.gold.fact_disease_metric__inputs
WHERE input_kind = 'table' AND input_build_id IS NULL
  AND (strict_input_builds OR input_table LIKE 'public_health.gold.%')
UNION ALL
SELECT 'silver input whose latest QC has a FAIL', count(*)
FROM public_health.gold.fact_disease_metric__inputs
WHERE block_on_silver_qc_fail AND qc_status NOT IN ('PASS', 'WARN')
UNION ALL
SELECT 'primary key or a required key column is null', count(*)
FROM public_health.gold.fact_disease_metric__candidate
WHERE fact_disease_metric_key IS NULL OR disease_key IS NULL OR area_key IS NULL OR date_key IS NULL OR data_source_key IS NULL OR age_group IS NULL OR sex IS NULL OR metric_name IS NULL OR metric_basis IS NULL
UNION ALL
SELECT 'primary key not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_disease_metric__candidate GROUP BY fact_disease_metric_key HAVING count(*) > 1)
UNION ALL
SELECT 'grain not unique', count(*) FROM (
  SELECT 1 FROM public_health.gold.fact_disease_metric__candidate
  GROUP BY disease_key, area_key, date_key, data_source_key, age_group, sex, metric_name, metric_basis HAVING count(*) > 1)
UNION ALL
SELECT 'rows <> metric + deaths_age + tb_programme silver rows + 4 x claims cells',
       abs((SELECT count(*) FROM public_health.gold.fact_disease_metric__candidate)
           - (SELECT count(*) FROM public_health.silver.diseases_metric_silver)
           - (SELECT count(*) FROM public_health.silver.diseases_deaths_age_silver)
           - (SELECT count(*) FROM public_health.silver.diseases_tb_programme_silver)
           - 4 * (SELECT count(*) FROM fdm_claims_cells))
UNION ALL
SELECT 'sum of values <> silver sum of ok values (metric, deaths_age, tb_programme)',
       CAST(ceil(abs(coalesce((SELECT sum(value) FROM public_health.gold.fact_disease_metric__candidate
                               WHERE metric_name NOT LIKE 'claims%'), 0)
         - coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN value END) FROM public_health.silver.diseases_metric_silver), 0)
         - coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN deaths END) FROM public_health.silver.diseases_deaths_age_silver), 0)
         - coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN value END) FROM public_health.silver.diseases_tb_programme_silver), 0))) AS BIGINT)
UNION ALL
SELECT 'claims filed: base-level cells (published + suppressed) <> silver claims_count total',
       CAST(abs(coalesce((SELECT sum(claims_filed) FROM fdm_claims_cells WHERE roll_level = 'base'), 0)
         - coalesce((SELECT sum(claims_count) FROM public_health.silver.diseases_hospital_claims_silver), 0)) AS BIGINT)
UNION ALL
SELECT 'claims filed: region-level cells <> silver claims_count total',
       CAST(abs(coalesce((SELECT sum(claims_filed) FROM fdm_claims_cells WHERE roll_level = 'region'), 0)
         - coalesce((SELECT sum(claims_count) FROM public_health.silver.diseases_hospital_claims_silver), 0)) AS BIGINT)
UNION ALL
SELECT 'claims filed: province-level cells <> silver claims of hospitals in a province',
       CAST(abs(coalesce((SELECT sum(claims_filed) FROM fdm_claims_cells WHERE roll_level = 'province'), 0)
         - coalesce((SELECT sum(claims_count) FROM fdm_claims_src WHERE province_key IS NOT NULL), 0)) AS BIGINT)
UNION ALL
SELECT 'claims hospital whose area has no region in dim_geography', count_if(region_key IS NULL) FROM fdm_claims_src
UNION ALL
SELECT 'claims amount: base-level cells <> silver claims_amount_php total',
       CAST(ceil(abs(coalesce((SELECT sum(amount_claimed) FROM fdm_claims_cells WHERE roll_level = 'base'), 0)
         - coalesce((SELECT sum(claims_amount_php) FROM public_health.silver.diseases_hospital_claims_silver), 0))) AS BIGINT)
UNION ALL
SELECT 'claims paid above claims filed in a cell', count(*) FROM fdm_claims_cells WHERE claims_paid > claims_filed
UNION ALL
SELECT 'claims cell under the hospital threshold that is not suppressed, or above it that is', count(*)
FROM fact_disease_metric_rows AS r
JOIN fdm_claims_cells AS c ON concat('key:', CAST(c.area_key AS STRING)) = r.area_code AND CAST(c.year AS STRING) = r.period_label
                           AND c.disease_key = r.disease_code AND c._source_key = r._source_key
                           AND c.coverage_basis = r.coverage_basis
WHERE r.row_source = 'claims'
  AND ((c.hospitals < suppression_min_hospitals) <> (r.value_status = 'suppressed'))
UNION ALL
SELECT 'value filled without status ok, or null with status ok', count(*) FROM public_health.gold.fact_disease_metric__candidate WHERE (value IS NULL) = (value_status = 'ok')
UNION ALL
SELECT 'value outside its bounds on a modelled row (value_lower <= value <= value_upper)', count(*) FROM public_health.gold.fact_disease_metric__candidate WHERE value < value_lower OR value > value_upper
UNION ALL
SELECT 'bounds on a source that is not modelled', count(*) FROM public_health.gold.fact_disease_metric__candidate AS c
INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = c.data_source_key
WHERE s.value_type <> 'modelled' AND (c.value_lower IS NOT NULL OR c.value_upper IS NOT NULL)
UNION ALL
SELECT 'metric row without a coverage row in diseases_source_coverage_silver', count(*) FROM public_health.silver.diseases_metric_silver AS m
LEFT ANTI JOIN public_health.silver.diseases_source_coverage_silver AS c
  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
 AND c.period_grain = m.period_grain AND c.year = m.year
UNION ALL
SELECT 'metric row with is_complete_year null (coverage row missing periods_present?)', count(*)
FROM fact_disease_metric_rows WHERE row_source = 'metric' AND is_complete_year IS NULL
UNION ALL
SELECT 'deaths by age: cause, area and year without exactly 20 age groups', count(*) FROM (
  SELECT 1 FROM fact_disease_metric_rows WHERE row_source = 'deaths_by_age'
  GROUP BY disease_code, area_code, period_label, _source_key HAVING count(*) <> 20)
UNION ALL
SELECT 'by-age row with age group all_ages, or metric / claims row with a specific age group', count(*) FROM fact_disease_metric_rows
WHERE (row_source = 'deaths_by_age' AND age_group = 'all_ages')
   OR (row_source IN ('metric', 'claims') AND age_group <> 'all_ages')
UNION ALL
SELECT 'sex outside male, female, both_sexes, or a split sex on a row that is not TB programme', count(*) FROM fact_disease_metric_rows
WHERE sex NOT IN ('male', 'female', 'both_sexes') OR (row_source <> 'tb_programme' AND sex <> 'both_sexes')
UNION ALL
SELECT 'TB programme: a both-sexes row without its male and female rows (or the reverse) where the source splits by sex', count(*) FROM (
  SELECT disease_code, area_code, period_label, _source_key, age_group, metric_name,
         count_if(sex = 'both_sexes') AS both_n, count_if(sex IN ('male', 'female')) AS split_n
  FROM fact_disease_metric_rows WHERE row_source = 'tb_programme' AND metric_name IN ('tpt_given', 'treatment_success')
  GROUP BY disease_code, area_code, period_label, _source_key, age_group, metric_name
  HAVING both_n <> 1 OR split_n <> 2)
UNION ALL
SELECT 'age_min above age_max', count(*) FROM public_health.gold.fact_disease_metric__candidate WHERE age_min > age_max
UNION ALL
SELECT 'disease_key not in dim_disease', count(*) FROM (
  SELECT DISTINCT disease_key AS k FROM public_health.gold.fact_disease_metric__candidate WHERE disease_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_disease AS d ON d.disease_key = c.k
UNION ALL
SELECT 'area_key not in dim_geography', count(*) FROM (
  SELECT DISTINCT area_key AS k FROM public_health.gold.fact_disease_metric__candidate WHERE area_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_geography AS d ON d.area_key = c.k
UNION ALL
SELECT 'date_key not in dim_date', count(*) FROM (
  SELECT DISTINCT date_key AS k FROM public_health.gold.fact_disease_metric__candidate WHERE date_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_date AS d ON d.date_key = c.k
UNION ALL
SELECT 'data_source_key not in dim_data_source', count(*) FROM (
  SELECT DISTINCT data_source_key AS k FROM public_health.gold.fact_disease_metric__candidate WHERE data_source_key IS NOT NULL) AS c
LEFT ANTI JOIN public_health.gold.dim_data_source AS d ON d.data_source_key = c.k;


-- ========================================
-- [4] stop if a gate failed. The failed build is logged first and the staging tables are kept:
--     SELECT * FROM public_health.gold.fact_disease_metric__gates WHERE failures <> 0
--     approval: provisional while a silver input has no QC run or has WARN findings to review.
-- ========================================
CREATE OR REPLACE TEMP VIEW fact_disease_metric_build_log AS
SELECT gold_build_id                                   AS build_id,
       'gold'                                          AS layer,
       'diseases'                                      AS domain,
       'public_health.gold.fact_disease_metric'                        AS target_table,
       gold_build_started_at                           AS started_at,
       current_timestamp()                             AS finished_at,
       CASE WHEN g.failed_gates = 0 THEN 'succeeded' ELSE 'failed' END AS status,
       code_version                                    AS code_version,
       to_json(named_struct('approval', q.approval, 'silver_qc', q.silver_qc, 'strict_input_builds', strict_input_builds, 'suppression_min_hospitals', suppression_min_hospitals)) AS parameters,
       job_run_id                                      AS run_id,
       CASE WHEN g.failed_gates > 0 THEN substr(concat('gates failed: ', g.failed_names), 1, 500) END AS error_message
FROM (SELECT count_if(failures <> 0) AS failed_gates,
             concat_ws(' | ', collect_list(CASE WHEN failures <> 0 THEN concat(gate, ' = ', failures) END)) AS failed_names
      FROM public_health.gold.fact_disease_metric__gates) AS g
CROSS JOIN (
  SELECT CASE WHEN count_if(input_table LIKE '%silver.%' AND qc_status IS NULL) > 0
                   THEN 'provisional: silver QC not run for every input'
              WHEN count_if(qc_status = 'WARN') > 0 THEN 'provisional: silver QC WARN findings to review'
              WHEN count_if(qc_status = 'PASS') > 0 THEN 'silver QC passed'
              ELSE 'no silver input' END AS approval,
         concat_ws(', ', collect_list(CASE WHEN input_table LIKE '%silver.%'
                   THEN concat(element_at(split(input_table, '[.]'), -1), ' ', coalesce(qc_status, 'NOT RUN')) END)) AS silver_qc
  FROM public_health.gold.fact_disease_metric__inputs) AS q;

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status, CAST(NULL AS BIGINT),
       CAST(NULL AS BIGINT), code_version, parameters, run_id, error_message
FROM fact_disease_metric_build_log WHERE status = 'failed';

SELECT raise_error(concat('fact_disease_metric was NOT published. ', error_message))
FROM fact_disease_metric_build_log WHERE status = 'failed';


-- ========================================
-- [5] write the table (full rebuild)
-- ========================================
CREATE OR REPLACE TABLE public_health.gold.fact_disease_metric AS
SELECT * FROM public_health.gold.fact_disease_metric__candidate;


-- ========================================
-- [6] record the build, with the table version just written. If your runtime rejects this
--     SET VAR, delete it: the version stays null, and freshness checks (G06,
--     mart_evidence_readiness) cannot compare this table.
-- ========================================
SET VAR gold_target_version = (SELECT max(version) FROM (DESCRIBE HISTORY public_health.gold.fact_disease_metric));

INSERT INTO public_health.quality.build_log
  (build_id, layer, domain, target_table, started_at, finished_at, status, row_count,
   target_table_version, code_version, parameters, run_id, error_message)
SELECT build_id, layer, domain, target_table, started_at, finished_at, status,
       (SELECT count(*) FROM public_health.gold.fact_disease_metric),
       gold_target_version, code_version, parameters, run_id, error_message
FROM fact_disease_metric_build_log;

INSERT INTO public_health.quality.build_inputs
  (build_id, target_table, input_kind, input_table, input_table_version, source_key, source_file,
   source_sheet, load_batch_id, content_checksum, ingested_at, input_rows, reference_version)
SELECT gold_build_id, 'public_health.gold.fact_disease_metric', input_kind, input_table, input_table_version,
       CAST(NULL AS STRING), source_file, CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
       CAST(NULL AS TIMESTAMP), input_rows,
       CASE WHEN input_kind = 'reference' THEN code_version END
FROM public_health.gold.fact_disease_metric__inputs;


-- ========================================
-- [7] remove the staging tables, then show the summary
-- ========================================
DROP TABLE IF EXISTS public_health.gold.fact_disease_metric__candidate;
DROP TABLE IF EXISTS public_health.gold.fact_disease_metric__gates;
DROP TABLE IF EXISTS public_health.gold.fact_disease_metric__inputs;

-- Databricks 2026-10-14 (before TB programme and claims): 131,887 metric rows and 90,480 by-age rows.
-- Expect + 73,216 TB programme rows and 4 x (claims cells) claims rows.
-- First run with claims (2026-10-14): 61,958 city / municipality cells per metric, 45,792 suppressed (74%).
SELECT s.source_dataset, s.value_type, f.metric_name, f.age_group = 'all_ages' AS is_all_ages, f.sex = 'both_sexes' AS is_both_sexes,
       CASE WHEN f.metric_name LIKE 'claims%' THEN f.coverage_basis END AS claims_level,
       count(*) AS row_count, count_if(f.value_status <> 'ok') AS not_ok,
       count_if(f.value_status = 'suppressed') AS suppressed,
       count_if(f.is_complete_year IS NULL) AS completeness_unknown
FROM public_health.gold.fact_disease_metric AS f
INNER JOIN public_health.gold.dim_data_source AS s ON s.data_source_key = f.data_source_key
GROUP BY s.source_dataset, s.value_type, f.metric_name, f.age_group = 'all_ages', f.sex = 'both_sexes',
         CASE WHEN f.metric_name LIKE 'claims%' THEN f.coverage_basis END
ORDER BY s.source_dataset, f.metric_name, is_all_ages DESC, is_both_sexes DESC, claims_level;

-- Proof (T2, national): TB preventive-treatment coverage and treatment success, Philippines 2025.
-- Expect tpt 120,108 / 1,498,711.2 = 8.0%; DS-TB 382,547 / 414,185 = 92.4%; MDR 5,030 / 7,721 = 65.1%.
SELECT dd.disease_code, f.metric_name, f.value
FROM public_health.gold.fact_disease_metric AS f
INNER JOIN public_health.gold.dim_disease AS dd ON dd.disease_key = f.disease_key
INNER JOIN public_health.gold.dim_geography AS g ON g.area_key = f.area_key
WHERE g.area_code = 'ph' AND f.age_group = 'all_ages' AND f.sex = 'both_sexes'
  AND f.metric_name IN ('tpt_given', 'tpt_eligible_contacts', 'treatment_cohort', 'treatment_success')
ORDER BY dd.disease_code, f.metric_name;
