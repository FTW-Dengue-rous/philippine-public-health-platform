# Quality results

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Recorded quality check outcomes from Databricks runs. Results are stored in `public_health.quality.qc_results`.

## Bronze QC results

Bronze QC ran for all domains. The `qc_results` table contains records for sources including `doh_fhsis_demographic`, `hdx_healthsites`, `psa_hospitals_beds_national_annual`, `psa_beds_region_annual`, `psa_gov_practitioners`, `psa_child_mortality`, `psa_health_expenditure_share_national_annual`, `psa_bhs_region_annual`, `hdx_phl_admin`, `psgc`, and `psgc_population`. Most checks show status PASS. A small number of early bronze QC runs recorded status FAIL for the "QC ran without error" check (the QC script itself errored). These were early attempts that were corrected.

Notable control total verifications:

| Source | Check | Expected | Result |
|---|---|---|---|
| `doh_foi_dengue` | Sum of cases by year | 2021: 80,919 / 2022: 264,390 / 2023: 214,638 / 2024: 413,960 / 2025: 240,540 | PASS |
| `psa_poverty` | 2025 Philippines poverty incidence | 9.7 | PASS |
| `psa_poverty` | 2025 Philippines poverty threshold | 35,120.89 | PASS |
| `psa_poverty` | 2025 Philippines poor population | 11,083.03 | PASS |
| `doh_fhsis_demographic` | Row count matches expected | 4,999 | PASS |
| `hdx_healthsites` | Row count matches expected | configured | PASS |
| `psa_gov_practitioners` | Control totals match | configured | PASS |

*(Source: qc_results query, executed 2026-10-18. Control values verified against source files at config time.)*

## Silver QC results

All silver builds succeeded on 2026-10-15 (full pipeline run). Facilities, diseases, socioeconomic, and workforce silver tables all passed validation gates:

| Build | Table | Rows | Null keys | Duplicate keys | Lineage | Result |
|---|---|---|---|---|---|---|
| 2026-10-15 | `facilities_id_map_silver` | 5,257 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `facilities_registry_silver` | 3,957 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `facilities_metric_silver` | 2,988 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `facilities_bed_occupancy_silver` | 9,145 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `facilities_osm_point_silver` | 16,030 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `diseases_metric_silver` | 131,887 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `diseases_deaths_age_silver` | 90,480 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `socioeconomic_poverty_silver` | 322 | 0 | 0 | Complete | PASS |
| 2026-10-15 | `workforce_headcount_silver` | 28,071 | 0 | 0 | Complete | PASS |

*(Source: build_log status = succeeded for all 2026-10-15 builds. Row counts from COUNT(*) queries, 2026-10-18.)*

## Gold QC results

Gold v2 tables (test_gold2) were built successfully on 2026-10-15. All 25 tables have non-zero row counts:

| Table | Rows | Status |
|---|---|---|
| `dim_geography` | 1,764 | PASS |
| `dim_facility` | 3,957 | PASS |
| `fact_facility_capacity` | 30,365 | PASS |
| `fact_disease_metric` | 593,171 | PASS |
| `fact_workforce_capacity` | 28,071 | PASS |
| `fact_area_indicator` | 8,928 | PASS |
| `mart_area_service_profile` | 109 | PASS |
| `mart_area_burden_indicator` | 2,071 | PASS |
| `mart_area_priority` | 12,426 | PASS |

*(Source: build_log status = succeeded for all test_gold2 builds on 2026-10-15. Row counts from COUNT(*) queries, 2026-10-18.)*

The legacy gold v1 `mart_area_service_profile` (2,701 rows, 2026-10-13 build) also passed its checks.

## How to check current results

```sql
-- All FAIL results
SELECT source_key, check_name, observed, expected, status, executed_at
FROM public_health.quality.qc_results
WHERE status = 'FAIL'
ORDER BY executed_at DESC;

-- All warnings for the latest build
SELECT q.* FROM public_health.quality.qc_results q
JOIN public_health.quality.build_log b ON q.validation_id = b.build_id
WHERE q.severity = 'WARN'
ORDER BY b.started_at DESC LIMIT 20;
```

## Limitations

* QC results are only as good as the checks configured. Unknown data issues may not be caught.
* Control totals are verified against the source file at config time. A source file update may change totals.
* Warnings do not stop the pipeline. Review them after each run.
