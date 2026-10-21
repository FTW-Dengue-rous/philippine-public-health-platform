# Data gaps

This page lists the data the questions need but the team does not have, or has only in part. For each gap it says what it blocks, how the pipeline handles it now, and what would close it. The business questions and analytical question IDs (N1–N4, S1–S3, A1–A4, W1–W2, E1–E2, P1–P2) are defined in [problem and business context](../01-context/problem-and-business-context.md).

Last updated: 2026-10-21

Limits on how to *read* the data are in [limitations and recommendations](../01-context/limitations-and-recommendations.md), section 2. This page is about *missing* data.

---

## 1. Gaps that block a question

| ID | Missing data | Blocks | Current handling | What would close it |
|---|---|---|---|---|
| G-01 | Hospital admissions and bed use **per disease** | Bed sufficiency per disease; BQ2 full replay (previous scope) | BQ2 is previous scope (stretch 2). Core dengue view compares peaks to capacity, not admissions | DOH admissions by disease and province; OHSRS hospital utilization (partly in eFOI 2026-5476) |
| G-02 | Daily or weekly hospital census | Surge modelling | Not modelled | DOH daily census (asked in R-02, not received) |
| G-03 | Staffed beds | True capacity | Authorized beds used, labelled as licensed beds | HFSRB / OHSRS implementing beds |
| G-04 | Patient residence for hospital care | Travel for care; patient-residence vs hospital distance | Claims show the place of care only | PhilHealth claims by patient address (not in R-03) |
| G-05 | Immunization coverage | Prevention view for vaccine-preventable disease (stretch 1) | Not ingested | FHSIS immunization tables 2018–2025 (identified 2026-10-07) |
| G-06 | Travel time or road network | Real access distance | Straight-line distance | Road network routing (OSM) |
| G-07 | Monthly or weekly data for TB, pneumonia, heart disease | Seasonality and peaks outside dengue | Yearly views only | FHSIS monthly reports or FOI |
| G-08 | 2024 regional all-cause death total not confirmed | N1 (cause-of-death shares by area) | PSA deaths file used as delivered; regional totals not independently confirmed | Confirm the 2024 PSA deaths file has complete regional totals |
| G-09 | Validated facility coordinates for distance analysis | CON1 (distance to care) | Registry (NHFR + HFSRB) has no coordinates. The bundle job built `facilities_osm_point_silver` from HDX Healthsites (16,030 published rows; 2 rows quarantined). These crowd-sourced points support straight-line distance and map context only; they do not validate, replace, or count the regulated facility registries. | Validate OSM points against the registry before using them for facility-level conclusions; retain the straight-line-distance limitation. |

## 2. Gaps in coverage

| ID | Gap | Affected output | Current handling |
|---|---|---|---|
| G-10 | Sulu has no 2024 census count in the source | Sulu rates | Population null; no fallback to 2020 (D-41) |
| G-11 | Pneumonia admissions for Davao only | National pneumonia view | Davao used as a case only; national pneumonia from FHSIS 2024 yearly counts |
| G-12 | DOH FOI dengue ends Sep 2025 | 2025 dengue peak | 2025 is a partial year; `is_complete_year = false` |
| G-13 | HDX dengue stops in 2021; UP NOAH misses 2020–2021 | Continuous weekly series | Each source kept in its own ranking; coverage per year in `diseases_source_coverage_silver` |
| G-14 | HDX 2019 lacks ISO week 1; one gap at the 2019/2020 boundary | Weekly completeness | Flagged (S43 WARN, F14) |
| G-15 | TB preventive treatment and treatment success: FHSIS 2025 only | TB trend | Single-year view |
| G-16 | Health workforce: FHSIS from 2018, PSA 2012–2023 by region | Long workforce trend at local level | PSA preferred 2012–2017; FHSIS from 2018 |
| G-17 | PSMO oncologists: one snapshot, composite areas | Specialist trend | Exploratory comparison only (W3) |
| G-18 | Boundaries: no ADM4; 8 SGA municipalities have no polygon | Barangay maps; SGA maps | `has_boundary = false` |
| G-19 | Bed occupancy: 2018–2025 only; 2016–2017 sit in eFOI 2026-5476, not ingested | Pre-2018 baseline | Series starts 2018 |
| G-20 | Poverty: 2021, 2023, 2025 only; some provinces not comparable with planning units | Poverty trend; equity in some provinces | `comparison_eligible = false` with reason |
| G-21 | IHME and HDX province coverage of HUCs had to be inferred | Province comparisons | Closed by evidence (D-42, D-43); not confirmed by the publishers |
| G-22 | S2 bed-occupancy reporting cohort is small for 2020–2024 (123–184 facilities) and much larger in 2025 (1,162) | S2 trend across years | 2020–2024 rows excluded as `private_only_year`; only 2025 rows are baseline-eligible (1,003). Do not compare the 2025 cohort with earlier years |
| G-23 | BHS counts by municipality are available from FHSIS, not from PSA BHS | S3 (health stations at local level) | FHSIS municipality tab used for S3 |
| G-24 | PSA hospitals and beds national annual series ends at 2015 | S1 long-term national trend | PSA region annual (2020–2024) used for trends instead |

## 3. Gaps in metadata

| ID | Gap | Handling |
|---|---|---|
| G-30 | BOR bed basis and reporting period not confirmed by HFSRB | `bor_basis_confirmed = false`, `period_confirmed = false` (O-12) |
| G-31 | Some `_as_of_date` values mix release and download dates; several marked CONFIRM | Backlog: split into two dates |
| G-32 | `bed_occupancy` (earlier file) source marked CONFIRM | Replaced by `doh_foi_hospital_beds` in silver |
| G-33 | PSMO pull date marked CONFIRM | Recorded as a snapshot |
| G-34 | Facilities YAML entries 1–13 have no `header_check` | A shifted column would load under the wrong names. Backlog |

## 4. Data on hand but not used

| Data | Why not used |
|---|---|
| eFOI 2026-5476 (2016–2017 bed sheets, OHSRS 2023 named hospitals) | Arrived 2026-10-16; no more ingestions after the capstone decision of 2026-10-18 |
| `doh_foi_tb_region2`, `philhealth_foi_tb_claims` | Bronze only; one region or old years; not needed for core questions |
| `psa_psgc` (socioeconomic) | PSGC is owned by geography (D-16); kept in bronze, to be disabled |
| Other PhilHealth claims datasets | Team chose the R-03 claims file only |
| COVID datasets | Could overestimate facility need; stretch only |
| Candidates found 2026-10-07 (FHSIS hypertension, NCD programme tables, PSA SDG tables, WHO vaccine-preventable disease cases) | Not decided; outside v3 questions |
| Patient-level clinical data | Out of scope: all sources are aggregated or facility-level. The one restricted release with daily counts (Davao hospital pneumonia) stays in silver and is not redistributed ([scope](../01-context/scope.md)) |
| HDX healthsites (`facilities_hdx_healthsites_bronze`, 16,032 rows) | Bronze loaded; `facilities_osm_point_silver` built by the bundle job: 16,030 published rows and 2 quarantined rows. It is a map/distance reference, never a facility count. |

## 5. Priority to close

| Priority | Gap | Why |
|---|---|---|
| 1 | G-01 admissions per disease | Unlocks BQ2 and bed sufficiency |
| 2 | G-05 immunization | Stretch 1; strengthens prevention |
| 3 | G-19 + OHSRS (eFOI 2026-5476) | Already on hand; named hospital utilization |
| 4 | G-30 BOR definitions | Turns flags into facts |

The data granularity the team asks publishers for is in [limitations and recommendations](../01-context/limitations-and-recommendations.md), section 3.1.

## 6. History of updates

| Date | Change |
|---|---|
| 2026-10-19 | Page written from the silver and gold limits, decision log and FOI notes |
| 2026-10-21 | Integration pass: added G-08 (2024 regional deaths), G-09 (facility coordinates), G-22 (S2 cohort), G-23 (BHS municipality), and G-24 (PSA national series to 2015); labelled BQ2 as previous scope in G-01; added patient-level clinical data and clarified that the completed OSM silver build is a map/distance reference rather than a registry count. |
| 2026-10-20 | Links point to the limitations and recommendations page (the old "Assumptions and limitations" page was split) |
