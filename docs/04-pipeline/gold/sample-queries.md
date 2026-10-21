# Gold sample queries

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Run these only after a successful gold and quality run. Inspect the mart's status and coverage fields before presenting a result.

```sql
-- Planning units that have a recorded service gap.
SELECT area_name, population, hospitals_recorded, hospital_beds, poverty_incidence_pct
FROM public_health.gold.mart_area_service_profile
WHERE population IS NOT NULL
ORDER BY hospital_beds / NULLIF(population, 0), area_name;
```

```sql
-- Explain the latest published build of a gold table.
SELECT build_id, status, finished_at, row_count, code_version
FROM public_health.quality.build_log
WHERE target_table = 'public_health.gold.fact_disease_metric'
ORDER BY finished_at DESC
LIMIT 1;
```

Do not sum sources, coverage bases, or periods merely because their columns share a name. Apply [gold usage rules](gold-usage-rules.md) and use [metric definitions](metric-definitions.md) for interpretation.
