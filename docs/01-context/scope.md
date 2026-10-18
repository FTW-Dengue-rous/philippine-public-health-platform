# Scope

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

## In scope

* Ingesting public and FOI-released Philippine public health data from DOH, PSA, UP NOAH, HDX, IHME, GLOBOCAN, and PSMO.
* Cleaning, matching, and quality-checking data through a medallion architecture on Databricks.
* Building silver tables per domain: geography, facilities, diseases, workforce, socioeconomic.
* Building gold analytical marts for supply-side questions (S1, S2, S3), disease burden (N1-N4), access (A1-A2), workforce (W1-W2), equity (E1-E2), and supporting analysis (SUP1-SUP6).
* A Lakeview dashboard for facility availability, bed occupancy, and primary care supply.
* Lineage and quality contract with build logs, input tracking, and row dispositions.
* CI/CD with GitHub Actions (lint, test, SQL lint, secret scan, repo hygiene, bundle deploy).

See [business questions](problem-and-business-context.md#analytical-questions) for the full question framework (BQ1, BQ2, N1-N4, S1-S2, A1-A2, W1-W2, E1-E2, P1-P2, D1-D5, SUP1-SUP6, CON1-CON3).

## Out of scope

* Real-time or streaming ingestion. The pipeline is batch.
* Clinical data at the patient level. All data is aggregated or facility-level.
* Predictive modeling or forecasting.
* External deployment beyond the team's Databricks workspace.

## Designed but not yet built

* `mart_capacity_gap` -- the main BQ1 mart joining need, supply, access, workforce and equity indicators per area.
* `mart_surge_stress_test` -- the BQ2 dengue surge stress test (blocked on admission share and LOS parameters).
* Gold fact tables (`fact_disease_metric`, `fact_facility_capacity`, `fact_bed_occupancy`, `fact_workforce`, `fact_population`, `fact_socioeconomic`) -- silver tables exist; gold materialisation is pending.
* Priority scoring (P1-P2) -- gated until upstream pillars are validated.

## Stretch goals

* Dengue surge stress test (BQ2, D1-D5): replay historical dengue waves against current hospital capacity.
* Distance-to-care analysis (CON1): straight-line distance to nearest Level 3 hospital.
* PSMO oncologist comparison with cancer estimates (CON2).
* Cross-domain case studies (CASE): TB notifications vs workforce supply.
