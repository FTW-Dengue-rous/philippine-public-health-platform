-- =============================================================================
-- headline_figures.sql
-- Reproduces the "What the data shows" table of the root README from public_health.gold.
-- Read-only. Run after a successful gold build; save the output in
-- docs/06-evidence/<date>-headline-figures/ (one screenshot per query, h1_<date>.png ...).
-- If a value differs from the README, the README takes the query value.
-- =============================================================================

-- H1. Cities and municipalities with no hospital recorded, and the people living in them.
SELECT
    count_if(NOT has_hospital_recorded) AS localities_without_hospital,
    count(*) AS localities,
    round(100.0 * count_if(NOT has_hospital_recorded) / count(*), 1) AS pct,
    sum(CASE WHEN NOT has_hospital_recorded THEN population END) AS population_without_hospital
FROM public_health.gold.mart_locality_service_presence;

-- H2. No licensed primary care facility recorded; neither a hospital nor licensed primary care.
SELECT
    count_if(NOT has_licensed_primary_care_recorded) AS localities_without_licensed_primary_care,
    count_if(NOT has_licensed_primary_care_recorded AND NOT has_hospital_recorded) AS localities_with_neither
FROM public_health.gold.mart_locality_service_presence;

-- H3. Provinces with no Level 3 hospital recorded, and the median straight-line distance from
--     their cities and municipalities to the nearest locality with a Level 3 hospital.
WITH prov AS (
    SELECT planning_unit_key
    FROM public_health.gold.mart_area_service_profile
    WHERE unit_level = 'province' AND coalesce(level3_hospitals, 0) = 0
)

SELECT
    (SELECT count(*) FROM prov) AS provinces_without_level3,
    (
        SELECT count(*) FROM public_health.gold.mart_area_service_profile AS s
        WHERE s.unit_level = 'province'
    ) AS provinces,
    round(percentile(a.nearest_level3_locality_km, 0.5), 0) AS median_km_to_level3
FROM public_health.gold.fact_area_access AS a
INNER JOIN prov AS p ON a.planning_unit_key = p.planning_unit_key;

-- H4. Registry analysis beds per 10,000 residents, national (latest census).
SELECT round(10000.0 * sum(hospital_beds) / sum(population), 1) AS beds_per_10k_national
FROM public_health.gold.mart_locality_service_presence
WHERE population IS NOT NULL;

-- H5. Beds per 10,000 residents in provinces under 10% poverty vs 20-30% poverty
--     (pooled: total beds / total population of the provinces in each group).
SELECT
    CASE
        WHEN poverty_incidence_pct < 10 THEN 'under 10%'
        WHEN poverty_incidence_pct >= 20 AND poverty_incidence_pct < 30 THEN '20-30%'
    END AS poverty_group,
    count(*) AS provinces,
    round(10000.0 * sum(beds) / sum(population), 1) AS beds_per_10k
FROM public_health.gold.mart_area_service_profile
WHERE
    unit_level = 'province'
    AND population IS NOT NULL
    AND (poverty_incidence_pct < 10 OR (poverty_incidence_pct >= 20 AND poverty_incidence_pct < 30))
GROUP BY 1
ORDER BY 1 DESC;
