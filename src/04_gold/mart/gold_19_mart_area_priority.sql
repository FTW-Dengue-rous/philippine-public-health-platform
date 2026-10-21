-- ========================================
-- 1. Builds the seed table public_health.gold.priority_weight_params
--      One row is: the weight of one gap type in one weight set
--      Key: (weight_set, indicator)
-- 2. Creates the view public_health.gold.mart_area_priority
--      One row is: one planning unit, burden indicator, weight set and eligibility rule
--      Key: (planning_unit_key, burden_indicator_key, weight_set, eligibility_config)
--      Every unit appears for every burden indicator. A unit with no burden rate is not ranked.
--   Answers: P1 (which areas combine a high burden with gaps, and which type of gap)
--            P2 (how stable the ranking is when the weights and rules change)
--
-- Reads: mart_area_service_profile (gold 16), mart_area_burden_indicator (gold 17),
--        priority_weight_params (this file). It does not read the facts.
--
-- Gap flags
--   A flag is true, false or null. Null means the unit lacks the input. Missing is not "no gap".
--   has_hospital_gap        beds per 10,000 in the lowest fifth of units.
--   has_primary_care_gap    true when either measure is in its worst fifth:
--                             - FHSIS health centres per 10,000 in the lowest fifth, or
--                             - the share of residents in a city or municipality with no
--                               licensed primary care facility recorded (HFSRB) in the highest
--                               fifth, and above 0.
--                           Null only when both measures are missing.
--                           primary_care_gap_basis says which measure raised the flag, or
--                           which measures were checked.
--   has_workforce_gap       at least two of doctors, nurses and midwives per 10,000 in the lowest
--                           fifth. Null unless all three are known.
--   has_socioeconomic_flag  poverty incidence in the highest fifth.
--   is_high_burden          burden rate in the highest fifth, for the burden indicator of the row.
--                           Computed here, counted from the top. It can differ from
--                           burden_quintile = 5 at the boundary and when rates tie.
--   Lowest fifth = quintile 1 in the service profile.
--   Highest fifth = top 20 percent, counted from the top.
--   Tied units are treated the same, so a fifth can hold more than 20 percent of the units.
--
-- Score and rank
--   flags_count   number of flags raised. Not weighted. A null flag counts as not raised.
--   score         weighted flags / total weight of the flags the unit has. Range 0 to 1.
--                 Under complete_only the total weight is 1, so equal weights give flags_count / 4.
--   eligibility_config
--     complete_only    ranks a unit only when all four flags are known (true or false) and it
--                      has a burden rate.
--     rescale_missing  ranks a unit with at least two known flags and a burden rate. Dividing
--                      by the weight of the known flags spreads the missing weight over them.
--   rank          1 = highest score. Ties are broken by the burden rate, highest first. Units
--                 with the same score and rate share a rank.
--   ranking_population  number of ranked units for the indicator, weight set and rule.
--
-- Burden indicators come from gold 17, with its gaps. IHME indicators have no rate for a
-- province with a HUC, or for the HUC itself (D-42), so those units are never ranked on them.
--
-- Why these values (D-56, agreed by the team 2026-10-19). Each is a judgement, not a published
-- standard; evidence queries are in gold_o13_evidence.sql.
--   * Fifths: BQ1 asks where gaps are largest, a relative question; quintiles are the usual
--     grouping in equity analysis. Label them "lowest 20% of planning units", never
--     "inadequate": the data has no national planning norm.
--   * "Two of three": a workforce gap needs most of the three core professions (doctors,
--     nurses, midwives) in the lowest fifth, so one profession's reporting gap cannot raise it
--     alone. The WHO density threshold (44.5 per 10,000, SDG 3.c.1) is not applied: our counts
--     are public sector only.
--   * Weight sets: equal is the default, because no gap type has a basis to count more.
--     supply_heavy and equity_heavy are sensitivity tests. A claim rests on the units that stay
--     at the top under all three.
-- Show the flags and the gap type first. Show a score only next to them. Default reading:
-- weight_set = equal and eligibility_config = complete_only.
-- Put the IHME attribution line on any chart of an IHME burden indicator.
--
-- Extra columns (not in the v3 column list): area_code, area_name, unit_level,
--   burden_rate_per_100k, burden_quintile, is_high_burden. A view has no _gold_build_id.
--
-- Rule for the weight-sum check (fix of 2026-10-13, see runbook): never put raise_error in the
-- same SELECT as GROUP BY / HAVING. Filter in a subquery first, then raise.
--
-- History
--   2026-10-14  Written for data model v2 (from gold_56, v1).
--   2026-10-18  Moved to public_health.gold and renamed gold_19. Comments corrected (score under
--               rescale_missing, workforce null rule, is_high_burden vs quintile, check queries).
--               No logic change.
--   2026-10-20  Reasons for the values recorded from D-56 (closes O-13). No logic change.
-- ========================================

CREATE OR REPLACE TABLE public_health.gold.priority_weight_params AS
SELECT weight_set, indicator, gap_type, CAST(weight AS DECIMAL(6, 4)) AS weight, rationale
FROM VALUES
  ('equal', 'has_primary_care_gap', 'primary_care', 0.25, 'No gap type counts more than another'),
  ('equal', 'has_hospital_gap', 'hospital', 0.25, 'No gap type counts more than another'),
  ('equal', 'has_workforce_gap', 'workforce', 0.25, 'No gap type counts more than another'),
  ('equal', 'has_socioeconomic_flag', 'socioeconomic', 0.25, 'No gap type counts more than another'),
  ('supply_heavy', 'has_primary_care_gap', 'primary_care', 0.35, 'Sensitivity test: service supply counts more'),
  ('supply_heavy', 'has_hospital_gap', 'hospital', 0.35, 'Sensitivity test: service supply counts more'),
  ('supply_heavy', 'has_workforce_gap', 'workforce', 0.20, 'Sensitivity test: service supply counts more'),
  ('supply_heavy', 'has_socioeconomic_flag', 'socioeconomic', 0.10, 'Sensitivity test: service supply counts more'),
  ('equity_heavy', 'has_primary_care_gap', 'primary_care', 0.20, 'Sensitivity test: poverty counts more'),
  ('equity_heavy', 'has_hospital_gap', 'hospital', 0.20, 'Sensitivity test: poverty counts more'),
  ('equity_heavy', 'has_workforce_gap', 'workforce', 0.20, 'Sensitivity test: poverty counts more'),
  ('equity_heavy', 'has_socioeconomic_flag', 'socioeconomic', 0.40, 'Sensitivity test: poverty counts more')
  AS t (weight_set, indicator, gap_type, weight, rationale);

-- Check: each weight set has 4 rows that sum to 1. Filter in the subquery first, raise outside it.
SELECT raise_error(concat('priority_weight_params: weights of ', weight_set, ' do not sum to 1 (sum = ',
                          CAST(total_weight AS STRING), ', rows = ', CAST(n AS STRING), ')'))
FROM (
  SELECT weight_set, sum(weight) AS total_weight, count(*) AS n
  FROM public_health.gold.priority_weight_params
  GROUP BY weight_set
  HAVING sum(weight) <> 1 OR count(*) <> 4
) AS bad;


CREATE OR REPLACE VIEW public_health.gold.mart_area_priority AS
-- share of residents in a city or municipality with no licensed primary care facility recorded
WITH shares AS (
  SELECT p.*,
         CASE WHEN p.population > 0
              THEN p.population_without_licensed_primary_care_recorded / p.population END AS uncovered_share
  FROM public_health.gold.mart_area_service_profile AS p
),

-- Highest fifth: position counted from the top, so units tied at the top are all in it
measured AS (
  SELECT s.*,
         CASE WHEN s.uncovered_share IS NOT NULL
              THEN percent_rank() OVER (PARTITION BY s.uncovered_share IS NOT NULL ORDER BY s.uncovered_share DESC) < 0.2
         END AS uncovered_share_in_top_fifth,
         CASE WHEN s.poverty_incidence_pct IS NOT NULL
              THEN percent_rank() OVER (PARTITION BY s.poverty_incidence_pct IS NOT NULL
                                        ORDER BY s.poverty_incidence_pct DESC) < 0.2
         END AS poverty_in_top_fifth
  FROM shares AS s
),

-- one row per unit: the gap flags (null = input missing).
-- fhsis_flag and hfsrb_flag are the two measures of the primary care gap.
flags AS (
  SELECT planning_unit_key, area_code, area_name, unit_level,
         (beds_per_10k_quintile = 1) AS has_hospital_gap,
         (reported_health_centers_per_10k_quintile = 1) AS fhsis_flag,
         (uncovered_share_in_top_fifth AND uncovered_share > 0) AS hfsrb_flag,
         CASE WHEN doctors_per_10k_quintile IS NOT NULL AND nurses_per_10k_quintile IS NOT NULL
                   AND midwives_per_10k_quintile IS NOT NULL
              THEN (CAST(doctors_per_10k_quintile = 1 AS INT) + CAST(nurses_per_10k_quintile = 1 AS INT)
                    + CAST(midwives_per_10k_quintile = 1 AS INT)) >= 2 END AS has_workforce_gap,
         poverty_in_top_fifth AS has_socioeconomic_flag
  FROM measured
),

-- primary care gap: raised by either measure; null only when both are missing
unit_flags AS (
  SELECT f.*,
         CASE WHEN f.fhsis_flag IS NULL AND f.hfsrb_flag IS NULL THEN NULL
              ELSE coalesce(f.fhsis_flag, false) OR coalesce(f.hfsrb_flag, false) END AS has_primary_care_gap,
         CASE WHEN f.hfsrb_flag AND f.fhsis_flag THEN 'HFSRB licensed list and FHSIS reported counts'
              WHEN f.hfsrb_flag THEN 'HFSRB licensed list'
              WHEN f.fhsis_flag THEN 'FHSIS reported counts'
              WHEN f.fhsis_flag IS NULL AND f.hfsrb_flag IS NULL THEN NULL
              WHEN f.fhsis_flag IS NULL THEN 'checked on the HFSRB licensed list only'
              WHEN f.hfsrb_flag IS NULL THEN 'checked on FHSIS reported counts only'
              ELSE 'checked on both' END AS primary_care_gap_basis
  FROM flags AS f
),

-- one row per weight set, one column per gap type
weights AS (
  SELECT weight_set,
         CAST(max(CASE WHEN gap_type = 'primary_care' THEN weight END) AS DOUBLE) AS w_primary_care,
         CAST(max(CASE WHEN gap_type = 'hospital' THEN weight END) AS DOUBLE) AS w_hospital,
         CAST(max(CASE WHEN gap_type = 'workforce' THEN weight END) AS DOUBLE) AS w_workforce,
         CAST(max(CASE WHEN gap_type = 'socioeconomic' THEN weight END) AS DOUBLE) AS w_socioeconomic
  FROM public_health.gold.priority_weight_params
  GROUP BY weight_set
),

-- the two eligibility rules. min_indicators = known flags a unit needs to be ranked
configs AS (
  SELECT * FROM VALUES
    ('complete_only', 'exclude the unit', 4),
    ('rescale_missing', 'rescale the weights over the flags the unit has', 2)
    AS t (eligibility_config, missing_rule, min_indicators)
),

-- every unit x burden indicator x weight set x rule.
-- weighted_flags = weight of the raised flags; weight_available = weight of the known flags.
scored AS (
  SELECT b.planning_unit_key, b.burden_indicator_key, w.weight_set, c.eligibility_config, c.missing_rule,
         f.area_code, f.area_name, f.unit_level,
         f.has_primary_care_gap, f.primary_care_gap_basis, f.has_hospital_gap, f.has_workforce_gap,
         f.has_socioeconomic_flag,
         b.rate_per_100k AS burden_rate_per_100k, b.quintile AS burden_quintile,
         CASE WHEN b.rate_per_100k IS NOT NULL
              THEN percent_rank() OVER (PARTITION BY b.burden_indicator_key, w.weight_set, c.eligibility_config,
                                                     b.rate_per_100k IS NOT NULL
                                        ORDER BY b.rate_per_100k DESC) < 0.2
         END AS is_high_burden,
         CAST(f.has_primary_care_gap IS NOT NULL AS INT) + CAST(f.has_hospital_gap IS NOT NULL AS INT)
           + CAST(f.has_workforce_gap IS NOT NULL AS INT) + CAST(f.has_socioeconomic_flag IS NOT NULL AS INT)
           AS indicators_available,
         concat_ws(', ',
           CASE WHEN f.has_primary_care_gap IS NULL THEN 'primary_care' END,
           CASE WHEN f.has_hospital_gap IS NULL THEN 'hospital' END,
           CASE WHEN f.has_workforce_gap IS NULL THEN 'workforce' END,
           CASE WHEN f.has_socioeconomic_flag IS NULL THEN 'socioeconomic' END) AS missing_indicators,
         concat_ws(' + ',
           CASE WHEN f.has_primary_care_gap THEN 'primary_care' END,
           CASE WHEN f.has_hospital_gap THEN 'hospital' END,
           CASE WHEN f.has_workforce_gap THEN 'workforce' END,
           CASE WHEN f.has_socioeconomic_flag THEN 'socioeconomic' END) AS gap_profile,
         CAST(coalesce(f.has_primary_care_gap, false) AS INT) + CAST(coalesce(f.has_hospital_gap, false) AS INT)
           + CAST(coalesce(f.has_workforce_gap, false) AS INT) + CAST(coalesce(f.has_socioeconomic_flag, false) AS INT)
           AS flags_count,
         w.w_primary_care * CAST(coalesce(f.has_primary_care_gap, false) AS INT)
           + w.w_hospital * CAST(coalesce(f.has_hospital_gap, false) AS INT)
           + w.w_workforce * CAST(coalesce(f.has_workforce_gap, false) AS INT)
           + w.w_socioeconomic * CAST(coalesce(f.has_socioeconomic_flag, false) AS INT) AS weighted_flags,
         w.w_primary_care * CAST(f.has_primary_care_gap IS NOT NULL AS INT)
           + w.w_hospital * CAST(f.has_hospital_gap IS NOT NULL AS INT)
           + w.w_workforce * CAST(f.has_workforce_gap IS NOT NULL AS INT)
           + w.w_socioeconomic * CAST(f.has_socioeconomic_flag IS NOT NULL AS INT) AS weight_available,
         c.min_indicators
  FROM public_health.gold.mart_area_burden_indicator AS b
  INNER JOIN unit_flags AS f ON f.planning_unit_key = b.planning_unit_key
  CROSS JOIN weights AS w
  CROSS JOIN configs AS c
),

-- a unit is ranked when it has a burden rate and enough known flags.
-- score = weighted_flags / weight_available (under complete_only, weight_available = 1)
ranked AS (
  SELECT s.*,
         (s.burden_rate_per_100k IS NOT NULL AND s.indicators_available >= s.min_indicators) AS is_ranked,
         CASE WHEN s.burden_rate_per_100k IS NOT NULL AND s.indicators_available >= s.min_indicators
                   AND s.weight_available > 0
              THEN s.weighted_flags / s.weight_available END AS score
  FROM scored AS s
)

SELECT planning_unit_key,
       burden_indicator_key,
       weight_set,
       eligibility_config,
       'primary_care, hospital, workforce, socioeconomic' AS indicator_set,
       indicators_available,
       nullif(missing_indicators, '') AS missing_indicators,
       missing_rule,
       CAST(count_if(is_ranked) OVER (PARTITION BY burden_indicator_key, weight_set, eligibility_config) AS INT)
         AS ranking_population,
       has_primary_care_gap,
       primary_care_gap_basis,
       has_hospital_gap,
       has_workforce_gap,
       has_socioeconomic_flag,
       CASE WHEN gap_profile = '' THEN 'none' ELSE gap_profile END AS gap_profile,
       flags_count,
       round(score, 4) AS score,
       CASE WHEN is_ranked
            THEN rank() OVER (PARTITION BY burden_indicator_key, weight_set, eligibility_config, is_ranked
                              ORDER BY score DESC, burden_rate_per_100k DESC) END AS rank,
       area_code,                                   -- extra
       area_name,                                   -- extra
       unit_level,                                  -- extra
       burden_rate_per_100k,                        -- extra
       burden_quintile,                             -- extra
       is_high_burden                               -- extra
FROM ranked;


-- Checks after creating the view.
-- P1: units with a high burden and at least one gap, by gap type (default reading: equal
-- weights, complete_only)
SELECT burden_indicator_key, gap_profile, count(*) AS units
FROM public_health.gold.mart_area_priority
WHERE weight_set = 'equal' AND eligibility_config = 'complete_only' AND is_high_burden AND flags_count > 0
GROUP BY burden_indicator_key, gap_profile
ORDER BY burden_indicator_key, units DESC;

-- P2: ranked units per indicator under each rule (equal weights).
-- Expect rescale_missing >= complete_only for every indicator.
SELECT burden_indicator_key, eligibility_config, max(ranking_population) AS ranked_units
FROM public_health.gold.mart_area_priority
WHERE weight_set = 'equal'
GROUP BY burden_indicator_key, eligibility_config
ORDER BY burden_indicator_key, eligibility_config;
