# Data gaps

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Missing or unavailable source data that affects the platform's analytical coverage. Gap IDs match those referenced in the [findings report](../04-pipeline/gold/findings-report.md) and the [business question framework](../01-context/problem-and-business-context.md).

## Analytical gaps (G1–G11, G13–G20)

These gaps affect BQ1 and its supporting questions. Each row is one gap. They are referenced by the same IDs in the findings report. G1–G11 keep their original meaning; issues that were previously bundled into other rows now have their own IDs (G13–G20).

| ID | Gap | Affected questions | Workaround or candidate source | Status |
|---|---|---|---|---|
| G1 | No 2023 population, so no per-capita rate for 2023. | N1, N2, W1 | Use 2020 or 2024 census for nearby years and label the mismatch. | Open |
| G2 | GBD province estimates may not include HUCs. | N2 | Confirm GBD province boundary definitions with IHME. | Open |
| G3 | Poverty is not published below province level. | E1 | Do not infer HUC-level poverty. | Known limitation |
| G4 | No province-level dengue data after 2020. 2025 is partial (January to September only). UP NOAH weekly has a 2020–2021 gap. | N3 | DOH FOI monthly covers 2021+. HDX for area-level. Label partial year. | Partially filled |
| G5 | S2 reporting cohort is small for 2020–2024 (120–185 facilities) and much larger in 2025 (1,067). | S2 | Do not compare the 2025 cohort with earlier years. | Known limitation |
| G6 | BQ2 admission share and length-of-stay parameters are not available. Previous scope. | BQ2 (previous scope) | Source from clinical literature or DOH. Not required for BQ1. | Previous scope |
| G7 | No validated facility coordinates for distance analysis. | CON1 | Use Haversine if coordinates are validated. | Open |
| G8 | Census population exists for 2015, 2020, and 2024 only. FHSIS area names do not always match PSGC. | W1, S3, all per-capita metrics | Use nearest census year and label. v1.7 SQL reduces unmatched FHSIS area names. | Partially resolved |
| G9 | 2024 regional all-cause death total not confirmed. | N1 | Confirm the 2024 PSA deaths file has regional totals. | Open |
| G10 | Weighting sets for priority scoring are a team decision. | P1, P2 | Store weighting sets in `priority_weight_params`. | Open |
| G11 | Planning unit must be defined: HUCs and NCR have no province row in PSGC. | BQ1, S1, A2, E1, P1 | Implement province + HUC + NCR rule in `mart_base_planning_unit`. | Open |
| G13 | Facility-level bed occupancy before 2020 is unavailable. | S2 | FOI request for older bed-occupancy years. | Open |
| G14 | BHS counts by municipality are available only from FHSIS, not PSA BHS. | S3 | Use the FHSIS municipality tab for S3. | Known limitation |
| G15 | OSM healthsites are community-maintained and incomplete. | S1 | Cross-reference OSM with NHFR; absence is not evidence. | Known limitation |
| G16 | Poverty estimates are biennial (2021/2023/2025). | E1 | Do not interpolate poverty between survey years. | Known limitation |
| G17 | Week definitions differ across dengue sources (UP NOAH folds week 53 into 52; HDX uses ISO weeks). | N3 | Label the week convention per source. | Known limitation |
| G18 | Admin boundaries require a manual ingestion step and a job parameter per run. | All geographic joins | Set `admin_boundaries_run_dir` per run. | Open |
| G19 | `facilities_osm_point_silver` was previously unverified — resolved: built 2026-10-18, 16,030 rows (bundle-job run; verified via table Delta history). | S1 | No action; verification done. | Resolved |
| G20 | PSA hospitals/beds national annual series only goes to 2015. | S1 | Use PSA region annual (2020–2024) for trends. | Open |

## Scope limitation

| ID | Gap | Affected questions | Status |
|---|---|---|---|
| G12 | No patient-level clinical data. | Out of scope for this capstone. | Out of scope |
