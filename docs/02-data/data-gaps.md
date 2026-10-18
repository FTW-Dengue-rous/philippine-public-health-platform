# Data gaps

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Missing or unavailable source data that affects the platform's analytical coverage.

| ID | Gap | Affected questions | Workaround or candidate source | Status |
|---|---|---|---|---|
| G1 | No facility-level bed occupancy for years before 2020 | S2 (historical trend) | FOI request for older years | Open |
| G2 | BHS counts by municipality (not just region) for recent years | S3 (municipality grain) | FHSIS municipality tab provides 2018–2025; PSA BHS only goes to region | Partially filled |
| G3 | OSM healthsites incomplete (community-maintained) | S1 (facility points) | Cross-reference with NHFR; absence is not evidence | Known limitation |
| G4 | 2020–2021 dengue data gap in UP NOAH weekly | Disease trend | DOH FOI monthly covers 2021+ | Partially filled |
| G5 | Poverty estimates are biennial (2021/2023/2025) | Equity analysis | Do not interpolate between survey years | Known limitation |
| G6 | Some HUC poverty estimates grouped with province | Equity analysis by HUC | None identified | Open |
| G7 | Week definition not reconciled across dengue sources | Weekly disease comparison | UP NOAH folds week 53 into 52; HDX uses ISO weeks | Known limitation |
| G8 | FHSIS area names do not always match PSGC | S3, workforce | 3,976 metric rows with unresolved area_names filtered in earlier notebook builds; v1.7 SQL reduces this | Partially resolved |
| G9 | Admin boundaries require manual ingestion step | All geographic joins | Job parameter `admin_boundaries_run_dir` must be set per run | Operational gap |
| G10 | `facilities_osm_point_silver` not verified to exist | S1 (OSM point analysis) | Table not found on Databricks (2026-10-14); documented per user instruction but unverified | Unverified |
| G11 | PSA hospitals/beds national annual only goes to 2015 | Historical hospital trend | PSA region annual covers 2020–2024 | Partially filled |
| G12 | No patient-level clinical data | Demand-side analysis | Out of scope for this capstone | Out of scope |
