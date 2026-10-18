# Quality results

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Recorded quality check outcomes from Databricks runs. Results are stored in `public_health.quality.qc_results`.

## Bronze QC results

Bronze QC ran successfully for all domains during the 2026-10 builds. No ERROR failures were recorded for the latest runs.

Notable control total verifications:

| Source | Check | Expected | Result |
|---|---|---|---|
| `doh_foi_dengue` | Sum of cases by year | 2021: 80,919 · 2022: 264,390 · 2023: 214,638 · 2024: 413,960 · 2025: 240,540 | PASS (configured in YAML) |
| `psa_poverty` | 2025 Philippines poverty incidence | 9.7 | PASS |
| `psa_poverty` | 2025 Philippines poverty threshold | 35,120.89 | PASS |
| `psa_poverty` | 2025 Philippines poor population | 11,083.03 | PASS |

*(Source: YAML `qc:` sections and Databricks runs. Control values were verified against source files on the dates noted in each YAML.)*

## Silver QC results

Facilities silver builds (v1.7 SQL) all passed validation gates:

| Build | Table | Rows | Null keys | Duplicate keys | Lineage | Result |
|---|---|---|---|---|---|---|
| 2026-10-10 | `facilities_id_map_silver` | 5,254 | 0 | 0 | Complete | PASS |
| 2026-10-10 | `facilities_registry_silver` | 3,954 | 0 | 0 | Complete | PASS |
| 2026-10-12 | `facilities_metric_silver` | 2,988 | 0 | 0 | Complete | PASS |
| 2026-10-12 | `facilities_bed_occupancy_silver` | 1,977 | 0 | 0 | Complete | PASS |

Warnings (non-blocking):

| Build | Warning | Count | Severity |
|---|---|---|---|
| 2026-10-12 | BOR > 150 (implausible, excluded) | 110 | WARN |
| 2026-10-12 | BOR > 100 (over capacity) | 281 | WARN |
| 2026-10-12 | City unresolved (geography) | 1 | WARN |

*(Source: Databricks build_log and row_disposition, 2026-10-10 to 2026-10-12.)*

## Gold QC results

`mart_area_service_profile` build (2026-10-13):

| Check | Result |
|---|---|
| Row count > 0 | PASS (~2,784 rows) |
| Key columns non-null | PASS |
| Population coverage | S1 City/Mun 899/904, S1 Province 329/331, S2 Province 259/281 (22 NCR/hist null), S3 100% |

*(Source: Databricks gold mart build, 2026-10-13.)*

## How to check current results

```sql
-- All ERROR failures
SELECT source_key, check_name, actual_value, expected_value, recorded_at
FROM public_health.quality.qc_results
WHERE severity = 'ERROR' AND result = 'FAIL'
ORDER BY recorded_at DESC;

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
