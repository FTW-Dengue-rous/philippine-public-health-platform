# Limitations and recommendations

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

This page covers the limits of the study and of the data, and what the team recommends. It is the last step of the story: what the results can and cannot claim, and what should happen next.

Status date: 2026-10-21.

**Read this first.** The figures in section 3.3 come from the 2026-10-14 test build. They are historical examples, not current findings. The 2026-10-21 evidence records show that the pipeline ran, but they do not independently refresh or approve these rankings. Recompute and review each figure before quoting it.

| Looking for | Go to |
|---|---|
| What the platform assumes (AS-xx) | [Assumptions](assumptions.md) |
| Data the questions need but the team does not have (G-xx) | [Data gaps](../02-data/data-gaps.md) |
| Engineering limitations (EL-xx), the backlog and cost steps R0–R5 | [Known issues and backlog](../08-governance/known-issues-and-backlog.md) |

---

## 1. Study limitations

These limits come from how the study was designed, not from one dataset.

| ID | Limitation | What it means for the results |
|---|---|---|
| SL-01 | **Area data, not people.** Every figure describes a city, municipality or planning unit | You cannot say that a person in a poor area lacks care. You can only say that the area has fewer recorded services |
| SL-02 | **Association, not cause.** The study compares need, supply and poverty side by side | A link between two figures does not prove that one causes the other. For example, thin TB staffing beside high TB notifications does not show which came first |
| SL-03 | **One point in time, mixed years.** The registry is a 2026 snapshot, census 2024, disease data 2018–2025 | The study shows where gaps are now. It cannot show whether they are closing or growing |
| SL-04 | **Relative gaps, not standards.** A "gap" means the lowest fifth of planning units (D-56) | A unit in the lowest fifth may still meet a DOH norm. A unit outside it may still fall short. The study uses no national planning norm |
| SL-05 | **Team judgement values.** Poverty bands, the "two of three" rule, weight sets and the 80% dialysis rule are team choices (AS-11) | Other values can move a unit in or out of a list. P2 tests the weights only, not every value |
| SL-06 | **Supply means listed capacity.** The study counts licensed beds, listed facilities and public-sector workers | It does not measure staffing, opening hours, equipment, quality of care or private practitioners |
| SL-07 | **Need means reported or modelled disease.** Notifications depend on detection. IHME values are modelled | An area that detects or reports less looks healthier than it is |
| SL-08 | **Cost appears only through poverty.** The study has no out-of-pocket spending or PhilHealth coverage by area | It cannot measure the cost barrier directly, only where poverty and service gaps meet |
| SL-09 | **No field check.** Nobody visited the areas or checked lists with LGUs. The client is a persona. The publishers have not confirmed the coverage findings (D-42, D-43) | Treat each result as a lead to verify, not a confirmed fact |
| SL-10 | **Few diseases at fine grain.** Only dengue has weekly or monthly data by area: weekly by province to 2021 (HDX), weekly and monthly by region. Monthly deaths are national only. TB notifications and IHME estimates are yearly. TB, kidney disease and dengue go deep; other diseases do not | The findings do not cover every disease or service. Peaks, seasonality and local outbreaks are visible for dengue only |
| SL-11 | **Restricted data limits reuse.** FOI releases are one-off, end at fixed dates and are aggregates only (D-47) | Others cannot rebuild those views without their own FOI request. Small areas may show "suppressed" |
| SL-12 | **Four-week timeline and data freeze.** The team stopped new ingestion on 2026-10-18 | Two late releases stay outside the results: eFOI 2026-5476 and the OHSRS regional release (KI-12, KI-13) |

## 2. Data limitations

These limits come from the sources. They say what the data cannot tell you. Carry them into every chart, comparison and conclusion.

| ID | Limitation | Effect | How the platform handles it |
|---|---|---|---|
| LM-01 | Disease data is mostly yearly counts, not admissions | Nobody can answer bed sufficiency per disease | BQ2 stays a stretch goal. The core dengue view compares peaks with capacity only |
| LM-02 | Capacity is a 2026 registry snapshot. Disease and population data are from 2024–2025 | The years differ within one comparison | Every chart shows the years |
| LM-03 | "No hospital recorded" is not "no hospital" | An unlisted facility looks like a gap | Every label says "recorded" |
| LM-04 | Distances are straight lines between area centres | The platform does not measure roads or travel time | Labelled "straight-line". The target is the nearest *locality with* a recorded hospital |
| LM-05 | OpenStreetMap points are crowd-sourced and uneven | They are not a facility count | Map layer and distance only (`ref_osm_healthsite_point`) |
| LM-06 | Sources count provinces differently: with or without their HUCs | Some province figures are not comparable | `not_separable` or `comparison_eligible = false`, with a reason |
| LM-07 | The source has no 2024 census count for Sulu | Sulu has no rates | Population stays null. No fallback to 2020 (D-41) |
| LM-08 | Weighted occupancy uses eligible records only (BOR ≤ 150) | It understates load where many records exceed 150, mostly in government hospitals | Labelled "eligible records" |
| LM-09 | HFSRB has not confirmed the BOR bed basis and reporting period | Occupancy definitions stay provisional | `bor_basis_confirmed = false`, `period_confirmed = false` (O-12) |
| LM-10 | PhilHealth claims show the place of care, not the patient's residence | Nobody can measure travel for care | Claims geography is the facility location |
| LM-11 | The PhilHealth claims series has breaks: COVID 2020–2021, the 2024 case-rate change, and the 2025 change in the IHD and MI definition | Amounts and some counts are not comparable across a break | Silver flags the breaks. Marts and charts carry notes |
| LM-12 | The workforce nurse series changes definition in 2019. The hospital series changes in 2013 | Trends across a break mislead | `is_break_year` flags |
| LM-13 | IHME values are modelled, not reported | They mean something different from registered counts | `value_type = modelled`. Marts keep them separate |
| LM-14 | Restricted sources appear as aggregates only. Gold suppresses cells under 3 | Small areas may show "suppressed" | `value_status = 'suppressed'` |
| LM-15 | Some area labels still wait for review: 18 FHSIS TB special-area rows, 34 Davao city labels, 21 claims pairs, San Jose in Oriental Mindoro | Those rows stay out of the analysis | Quarantine or `REVIEW` flags, each with a reason |
| LM-16 | Admin boundaries cover ADM1–ADM3 only. 8 special-area municipalities have no polygon | They have no map shape or density | `has_boundary = false` |
| LM-17 | TB preventive treatment coverage comes from one FHSIS year (2025) | It shows no trend | Single-year view in mart 21 |

## 3. Recommendations

Four groups. Section 3.1 comes first because data availability limits the study most. Each recommendation names who acts and the limit or finding behind it.

### 3.1 For data publishers

The main limit of this study is data availability, not the pipeline. The platform already joins and checks data from DOH, PSA, PhilHealth and others on one geography. A new dataset costs one YAML entry and one silver build. But many datasets reach the public only as yearly, regional or national totals. Finer granularity would answer more of BQ1 and would make BQ2 possible.

The changes below would also remove most of the manual matching and inference the team had to do.

| ID | Recommendation | Who | Why |
|---|---|---|---|
| RP-01 | Publish the PSGC code on every area row | DOH (FHSIS, NHFR, FOI releases), PhilHealth, PSA | Area names do not join. Matching them took most of the silver work, and some labels still wait for review (LM-15, KI-01) |
| RP-02 | State whether a province row includes its highly urbanized cities | PSA (poverty), IHME, DOH and HDX (dengue) | The team had to infer it from the numbers (D-42, D-43). Only 67 planning units got a comparable poverty value |
| RP-03 | Give facilities one shared ID across lists | DOH (NHFR, HFSRB), PhilHealth | No shared ID exists. Facilities match through licence numbers and addresses |
| RP-04 | Publish staffed beds beside authorized beds | DOH (HFSRB, OHSRS) | Licensed beds overstate usable capacity (G-03) |
| RP-05 | Confirm the bed basis and reporting period of the bed occupancy rate, and flag records above 150% at source | DOH (HFSRB) | Occupancy definitions stay provisional (LM-08, LM-09, O-12) |
| RP-06 | Publish admissions and length of stay by disease and province | DOH (OHSRS) | Without them, nobody can answer BQ2 or bed sufficiency per disease (G-01) |
| RP-07 | Add the patient's province or municipality to claims aggregates | PhilHealth | Claims show only where care happened, not where patients live (LM-10, G-04) |
| RP-08 | Release FHSIS tables as CSV with the same columns every year | DOH (Epidemiology Bureau) | The workbook layout changes every year. Each change needs new parsing rules |
| RP-09 | State the week convention on weekly data | DOH, HDX | The team had to test which week each date closes (D-44) |
| RP-10 | Update regional groupings when regions change, and note it | DOH (FHSIS) | FHSIS 2024 regions VI and VII still include the Negros Island Region provinces (F-S7) |
| RP-11 | Publish weekly or monthly case counts by province and city or municipality for notifiable diseases, not only dengue | DOH (Epidemiology Bureau, PIDSR) | Most disease data reaches the public as yearly or regional totals. Local peaks stay hidden (SL-10, G-07) |

**Finer granularity would be better.** The analysis would be stronger if the data below were available at a finer time grain and a lower area level. Each row shows what the team had and what would help.

| Data | Available to the team | Better if available as | What it would allow | Who holds it |
|---|---|---|---|---|
| Dengue cases and deaths | Weekly by province to 2021 (HDX). Weekly and monthly by region (UP NOAH, DOH FOI to September 2025) | Weekly by city or municipality, up to the current week | Local outbreak timing and peak pressure on nearby hospitals | DOH Epidemiology Bureau (PIDSR) |
| Other notifiable diseases (for example leptospirosis, measles, typhoid) | Yearly, national only (PSA) | Weekly or monthly by province and city or municipality | Seasonality and local peaks beyond dengue | DOH Epidemiology Bureau (PIDSR) |
| TB notifications | Yearly by city or municipality, 2024–2025 only (FHSIS) | Quarterly or monthly by city or municipality, with several years | TB trends and seasonal detection patterns | DOH (FHSIS, National TB Program) |
| Deaths by cause | Monthly national only. Yearly by region (2023–2024) | Monthly by province and city or municipality of residence | Local mortality burden from registered deaths, not only modelled estimates | PSA (civil registration) |
| Hospital admissions and length of stay by disease | None by disease. Length of stay by region and year arrived after the data freeze | Monthly by hospital or province, by disease | Bed-day demand per disease; the full dengue capacity question (BQ2) | DOH (OHSRS) |
| Bed occupancy | Yearly records, 2018–2025, with no hospital identity (D-18). Bed basis not confirmed | Monthly by named hospital, on a confirmed bed basis | Real load and surge pressure | DOH (HFSRB, OHSRS) |
| Hospital beds | Authorized beds, one 2026 snapshot | Staffed beds by hospital, every year | True capacity and its change over time | DOH (HFSRB, OHSRS) |
| Beds by type | None by type. Dialysis station counts missing for some clinics | ICU, isolation and ward beds per hospital, and dialysis stations per clinic, every year | Surge and specialist capacity | DOH (HFSRB, OHSRS) |
| Facility services and status | Facility lists with category and level, one snapshot each (NHFR 2026-09-29, HFSRB 2026-06-30) | Services offered and operating status per facility, dated every year | Access to a specific service and change over time | DOH (NHFR, HFSRB) |
| Primary care facilities | Counts of BHS and health centres per area and year (FHSIS). Licensed primary care list (HFSRB) | A list of every BHS and rural health unit with location and status | Primary care access by locality | DOH (FHSIS), LGUs |
| Health workers | Yearly by city or municipality, public sector only (FHSIS). By region (PSA) | Yearly by city or municipality and by facility, public and private, by profession | Full workforce supply, not only public staff | DOH (Health Human Resource Development Bureau, FHSIS), PRC |
| Specialists | Medical oncologists only, one snapshot, composite areas (PSMO) | Specialists by specialty and city or municipality, every year | Specialist access, for example nephrologists for the kidney study | PRC, specialty societies |
| PhilHealth claims | Yearly by hospital, where care happened | Monthly, by the patient's city or municipality, with PSGC and facility codes | Travel for care and local demand | PhilHealth |
| Poverty | 2021, 2023, 2025 by province; some provinces include their highly urbanized cities | City and municipal estimates in every round, with highly urbanized cities apart | Equity at the same level as the service data | PSA |
| Population | Census 2015, 2020, 2024 | Yearly estimates by city or municipality | Rates for every year, not only census years | PSA |
| Immunization | FHSIS tables 2018–2025, identified but not ingested | Monthly by city or municipality | A prevention view for vaccine-preventable disease (stretch 1) | DOH (FHSIS) |

### 3.2 For users of the results

These rules apply to planners, analysts and dashboard readers.

| ID | Recommendation | Why |
|---|---|---|
| RU-01 | Treat "no hospital recorded" as a lead. Check it with the LGU or the DOH regional office before you act | The registry can miss facilities (LM-03, SL-09) |
| RU-02 | Use rankings to shortlist areas, not to decide. Prefer areas that stay at the top under all three weight sets | Rankings rest on team judgement values (SL-04, SL-05) |
| RU-03 | Quote every figure with its year, source and label. Never mix census and FHSIS denominators | Sources differ by year and coverage ([gold usage rules](../04-pipeline/gold/gold-usage-rules.md)) |
| RU-04 | Read TB notification rates together with detection effort | A low rate can mean low detection (SL-07) |
| RU-05 | Read dengue peak pressure as a relative ranking | It does not say that a hospital would be overwhelmed (BQ2 not built) |
| RU-06 | Show "suppressed" and "not comparable" cells with their reason. Never fill them with zero | Null means "not available" |
| RU-07 | Refresh the figures after each new release and state the as-of date | The study is one point in time (SL-03) |

### 3.3 Policy actions

These actions follow from the test-build findings. They point to where to look first. They do not say what to build: each needs a field check and costing first (SL-09). Confirm every figure against the final rebuild.

| ID | Action | Finding behind it (test build, 2026-10-14) |
|---|---|---|
| RA-01 | Verify and close primary care gaps first, starting with the localities that have neither a hospital nor licensed primary care recorded | 924 localities (about 47.9 million people) have no licensed primary care recorded. 678 have neither. The mentor advised a prevention focus, not only hospitals |
| RA-02 | Direct public health workforce deployment to areas with the highest TB notification rates | Nurses per 10,000 fall from 3.1 to 2.0, and midwives from 3.5 to 2.4, from the lowest to the highest TB fifth |
| RA-03 | Scale up TB preventive treatment for household contacts | Median preventive treatment coverage by locality is 0–7%, while treatment success is about 95% |
| RA-04 | Review dialysis access in Camiguin, Davao Occidental and Dinagat Islands | These provinces combine high modelled CKD mortality with no dialysis facility recorded. Check against the accredited dialysis list first |
| RA-05 | Prepare dengue surge plans before the season in the areas with the largest peaks relative to beds | Antique, Zamboanga City, Guimaras, Iloilo and Cebu lead. These figures predate the week fix (D-44), so confirm them after the rebuild |
| RA-06 | Strengthen referral and transport links for areas far from a Level 3 hospital | The median straight-line distance to a locality with a Level 3 hospital recorded is 45 km |
| RA-07 | Adopt a shared reporting standard across agencies: PSGC codes, one facility ID, stated coverage, and aggregate release with small-cell suppression | The client working group can push its member agencies to apply RP-01 to RP-03. Regular refreshes would then need no new FOI request each time (SL-11) |

### 3.4 Further study

| ID | Study | What it adds | Needs |
|---|---|---|---|
| RS-01 | Full dengue capacity replay (BQ2, stretch 2) | Which areas would exceed capacity if a past peak recurred | Admissions by disease (G-01), length of stay from the OHSRS release (KI-13) |
| RS-02 | Immunization coverage (stretch 1) | A prevention view for vaccine-preventable disease | FHSIS immunization tables (G-05) |
| RS-03 | Field check of "no hospital recorded" localities | Tells registry gaps apart from real gaps | A sample, starting where OSM and the registry disagree (Cuyo, Lubang, Olutanga, Siasi, Polillo) |
| RS-04 | Travel time by road | Real access instead of straight-line distance | Road network routing (G-06) |
| RS-05 | Cost barrier by area | Measures the third barrier directly | Out-of-pocket spending or PhilHealth coverage by area (SL-08) |
| RS-06 | Gaps against DOH planning norms | Turns relative gaps into absolute ones | Agreed norms for beds, facilities and workers per population (SL-04) |
| RS-07 | Trends over time | Shows whether gaps close | Each new census, poverty and registry release, run through the same pipeline |
| RS-08 | Ingest more diseases at weekly or monthly grain, by province and city or municipality. Start with notifiable diseases (for example leptospirosis, measles, typhoid, cholera) and with TB, pneumonia and heart disease | Peaks, seasonality and local outbreaks beyond dengue. More diseases for the burden side of BQ1 | Weekly or monthly local counts from DOH (PIDSR, FHSIS monthly reports) or FOI requests (G-07, RP-11). Each new source is a YAML entry and a silver build; `fact_disease_metric` already holds weekly and monthly periods |
| RS-09 | Named hospital utilization | Occupancy per hospital and a pre-2018 baseline | eFOI 2026-5476 (KI-12, G-19) |
| RS-10 | Barangay-level analysis | Gaps inside large municipalities | ADM4 boundaries and barangay data (G-18) |

## 4. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Page written: study limitations SL-01 to SL-12 and recommendations for publishers, users, policy and further study. Policy actions use the test-build figures of 2026-10-14 |
| 2026-10-20 | RS-08 widened to more diseases at weekly or monthly grain and local level. RP-11 added. SL-10 reworded |
| 2026-10-20 | Data granularity table added to section 2.1: what the team had and what would help, per data type |
| 2026-10-20 | Data limitations LM-01 to LM-17 moved here from "Assumptions and limitations" as section 2. Recommendations renumbered to section 3. The assumptions now have their own page |
| 2026-10-20 | Section 3.1 opens with the key message on data availability. The granularity table, "Finer granularity would be better", gained beds by type, facility services, primary care facilities and specialists |
