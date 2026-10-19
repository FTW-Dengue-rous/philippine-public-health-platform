# Quality results

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

Recorded quality check outcomes from Databricks runs. Results are stored in `public_health.quality.qc_results`. Run IDs, timestamps, and the executed revision are in the [2026-10-18 run record](../../06-evidence/2026-10-18-new-workspace-run.md).

## Bronze QC results

Bronze QC ran for all domains. The `qc_results` table contains records for sources including `doh_fhsis_demographic`, `hdx_healthsites`, `psa_hospitals_beds_national_annual`, `psa_beds_region_annual`, `psa_gov_practitioners`, `psa_child_mortality`, `psa_health_expenditure_share_national_annual`, `psa_bhs_region_annual`, `hdx_phl_admin`, `psgc`, and `psgc_population`. Most checks show status PASS. Early bronze QC attempts (2026-10-11, 2026-10-12) recorded FAIL rows for the "QC ran without error" check because the QC scripts themselves errored; those were fixed before the orchestrated runs.

The 2026-10-18 orchestrated runs executed bronze QC with 0 FAIL and 1 WARN. The single warning was B10 (numeric column parse) on `geography_bronze`: 94 of 127,945 nested population values carry raw text that cannot be parsed as BIGINT; the rows are kept and the unparseable values are excluded downstream.

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

The 2026-10-18 orchestrated runs are the first recorded silver QC executions with zero FAIL rows: 1,443 checks on 2026-10-18 across bronze and silver, 0 FAIL, 87 WARN. Earlier attempts on 2026-10-11, 2026-10-12, and 2026-10-15 recorded FAIL rows for check S00 ("QC ran without error" - the QC scripts errored against tables that did not exist yet or had mismatched columns during drafting).

| Build | Table | Rows | Null keys | Duplicate keys | Lineage | Result |
|---|---|---|---|---|---|---|
| 2026-10-18 | `facilities_id_map_silver` | 5,257 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `facilities_registry_silver` | 3,957 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `facilities_metric_silver` | 2,988 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `facilities_bed_occupancy_silver` | 9,145 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `facilities_osm_point_silver` | 16,030 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `diseases_metric_silver` | 131,887 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `diseases_deaths_age_silver` | 90,480 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `socioeconomic_poverty_silver` | 322 | 0 | 0 | Complete | PASS |
| 2026-10-18 | `workforce_headcount_silver` | 28,071 | 0 | 0 | Complete | PASS |

*(Source: build_log status = succeeded for the 2026-10-18 builds and qc_results with zero FAIL rows on 2026-10-18. Row counts from COUNT(*) queries, 2026-10-18.)*

Recurring WARN groups on 2026-10-18 (warnings do not block; review them after each run):

| Check | Table | Observation |
|---|---|---|
| S25 | `facilities_bed_occupancy_silver` | 1,779 of 9,036 rows report occupancy above 100 or above the baseline maximum |
| S29 | several | Quarantined rows within limits, for example 1,404 `illness_missing` (hospital claims), 18 `area_unresolved` (diseases metric), 10 `service_of_existing_facility` (registry) |
| S27/S28 | `facilities_osm_point_silver` | 35 points placed by city tag only (no coordinates), 2 points outside boundaries (quarantined) |
| S53-S58 | `population_silver` | Coverage and census-consistency caveats: 62 rows without usable population values, missing area-year rows, 9 area-total mismatches, 36 census-year changes above 30 percent |
| S68-S73 | `workforce_headcount_silver` | Totals vs mutually exclusive components disagree in 24 rows; 2025 province-vs-municipality gaps (Sulu doctors 0); year-on-year changes above 50 percent in 721 rows |
| S94-S96 | `socioeconomic_*` | Poverty incidence drops above 15 points (322-row source); child-mortality reference period not confirmed - do not state one on the dashboard |
| S98 | `diseases_metric_silver` | Stale latest years: `hdx_dengue` 2021, `psa_deaths_national_annual` 2020 |
| S99 | `workforce_area_denominator_silver` | Reported population disagrees with census population in 11 of 171 rows |

## Gold QC results

Gold objects (`public_health.gold`) were built successfully on 2026-10-18 (see the [run record](../../06-evidence/2026-10-18-new-workspace-run.md)). All objects have non-zero row counts:

| Table | Rows | Verified |
|---|---|---|
| `dim_geography` | 1,764 | Built, row count verified |
| `dim_facility` | 3,957 | Built, row count verified |
| `fact_facility_capacity` | 30,365 | Built, row count verified |
| `fact_disease_metric` | 593,171 | Built, row count verified |
| `fact_workforce_capacity` | 28,071 | Built, row count verified |
| `fact_area_indicator` | 8,928 | Built, row count verified |
| `mart_area_service_profile` (view) | 109 | Built, row count verified |
| `mart_area_burden_indicator` (view) | 2,071 | Built, row count verified |
| `mart_area_priority` (view) | 12,426 | Built, row count verified |

Gold QC is implemented in `src/05_quality/gold/gold_qc.py` with 14 checks (G00-G13) that validate published gold tables and write results to `quality.qc_results` via `dq_utils.DQRun`. See [known issues](../../08-governance/known-issues-and-backlog.md) KI11 (resolved) and the [quality check catalog](quality-check-catalog.md) for the full check list.

The legacy gold v1 `mart_area_service_profile` (2,784 rows; 2026-10-13 build; count verified 2026-10-18) predates the current gold QC implementation.

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
* Gold QC checks (G00-G13) are implemented and run after the last gold build script (KI11 resolved).
* Control totals are verified against the source file at config time. A source file update may change totals.
* Warnings do not stop the pipeline. Review them after each run.
