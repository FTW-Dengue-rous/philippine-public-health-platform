# Scope

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

## In scope

* Ingesting public and FOI-released Philippine public health data from DOH, PSA, UP NOAH, HDX, IHME, GLOBOCAN, and PSMO.
* Cleaning, matching, and quality-checking data through a medallion architecture on Databricks.
* Building silver tables per domain: geography, facilities, diseases, workforce, socioeconomic.
* Building gold analytical marts for supply-side questions (S1, S2, S3), disease burden (N1-N4), access (A1-A2), workforce (W1-W2), equity (E1-E2), priority (P1-P2), and supporting analysis (SUP1-SUP6) and conditional explorations (CON1-CON3, CASE) where they support BQ1. These answer the platform's only main question: BQ1 (capacity gap analysis). BQ2 (dengue surge stress test, D1-D5) is outside the active scope and is preserved as previous scope.
* A Lakeview dashboard for facility availability, bed occupancy, and primary care supply.
* Lineage and quality contract with build logs, input tracking, and row dispositions.
* CI/CD with GitHub Actions (lint, test, SQL lint, secret scan, repo hygiene, bundle deploy).

See [business questions](problem-and-business-context.md#analytical-questions) for the full question framework (BQ1, N1-N4, S1-S3, A1-A2, W1-W2, E1-E2, P1-P2, SUP1-SUP6, CON1-CON3, plus previous-scope BQ2 and D1-D5).

## Out of scope

* Real-time or streaming ingestion. The pipeline is batch.
* Clinical data at the patient level. All data is aggregated or facility-level.
* Predictive modeling or forecasting.
* External deployment beyond the team's Databricks workspace.

## Built in gold (public_health.gold, 2026-10-18)

* 5 dimensions (`dim_geography`, `dim_facility`, `dim_disease`, `dim_date`, `dim_data_source`).
* 4 fact tables (`fact_facility_capacity`, `fact_disease_metric`, `fact_workforce_capacity`, `fact_area_indicator`).
* 11 marts including `mart_area_service_profile` (109-row wide planning-unit mart), `mart_area_burden_indicator`, `mart_area_priority`, `mart_area_evidence`, case study marts.

## Designed but not fully built

* `mart_capacity_gap` -- the full BQ1 mart joining need, supply, access, workforce and equity per area. The v2 `mart_area_service_profile` partially covers this (supply, primary care, workforce, poverty per planning unit). Disease burden integration is the remaining gap.
* `mart_surge_stress_test` -- the BQ2 dengue surge stress test (previous scope; blocked on admission share and LOS parameters).
* Priority scoring (P1-P2) -- gated until upstream pillars are validated on the same analysis unit.

## Stretch goals

* Dengue surge stress test (BQ2, D1-D5) -- previous scope, only if re-scoped: replay historical dengue waves against current hospital capacity.
* Distance-to-care analysis (CON1): straight-line distance to nearest Level 3 hospital.
* PSMO oncologist comparison with cancer estimates (CON2).
* Cross-domain case studies (CASE): TB notifications vs workforce supply.
