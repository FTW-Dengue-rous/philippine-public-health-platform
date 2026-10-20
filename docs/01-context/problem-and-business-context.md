# Problem and business context

This page explains why LUNASaan? exists, who it is for and which questions it answers. Read it first if you are new to the project.

| Item | Value |
|---|---|
| Project | LUNASaan? — Philippine Public Health Platform |
| Programme | FTW Data Engineering, capstone (final project) |
| Team | Learning Team 5 |
| Client (persona) | Inter-Agency Technical Working Group on Health Facility Data (IATWG-HFD) |
| Status date | 2026-10-20 |

---

## 1. The situation

Many Filipinos go to a hospital only when an illness is already severe. Three barriers show up again and again: there is no facility nearby, the facility has no capacity, or care costs too much.

Hospitals that do exist are often full. Patients share beds and hallways become wards. Serious care, such as a Level 3 hospital, is often far away.

The team framed the story as one question: **why is it hard to get sick in the Philippines?**

## 2. The data problem

The data needed to see these barriers exists, but it is fragmented.

| What you need | Where it sits | Why it does not join |
|---|---|---|
| How much disease, where | DOH FHSIS, DOH FOI releases, PSA vital statistics, IHME | Different grains (week, month, year), different area labels |
| Which facilities exist, with how many beds | DOH NHFR, DOH HFSRB licence lists, PSA tables | No shared facility ID; place names inside free-text addresses |
| How many people live there | PSA census through PSGC | PSGC 10-digit codes that most other sources do not carry |
| How poor the area is | PSA poverty statistics | Province rows that may or may not include their highly urbanized cities |
| How many health workers | DOH FHSIS, PSA | Workbook layout changes every year |

The same town can appear as a code, a name in an address, a label under a region row, a province-and-town pair, or a polygon name. Until these are joined on one code, nobody can answer "where is care missing?" in one view.

## 3. The client

The capstone is presented to a fictional client: the **Inter-Agency Technical Working Group on Health Facility Data (IATWG-HFD)**. It is a DOH working group with technical partners from the WHO country office and UNICEF.

The client wants one consistent view of facility availability and disease trends across cities and municipalities. They will use it to plan facility upgrades, staffing and outbreak-preparedness resources.

## 4. Stakeholders

| Group | Who | What they need |
|---|---|---|
| Primary | DOH, LGUs, health policymakers | Where to add facilities, beds, primary care and staff |
| Secondary | General public | A clear picture of access to care where they live |
| Secondary (later) | Researchers | Analysis-ready data. Out of scope for now (see [scope](scope.md)) |

## 5. Business questions

| ID | Question | Priority |
|---|---|---|
| **BQ1** | Where are the biggest gaps between healthcare needs and available health services, and how do these gaps relate to poverty and other socioeconomic conditions? | **Core** |
| BQ2 | Which regions or provinces would exceed hospital capacity if a past dengue peak recurred today? | Stretch goal 2 |

BQ1 has three parts:

- **Gaps:** need (disease burden) against supply (facilities, beds, workers).
- **Equity:** how those gaps line up with poverty.
- **Prevention:** primary care and early detection, not only Level 3 hospitals. The mentor advised against looking only at hospitals.

BQ2 needs admissions and bed data per disease, which the team does not have yet. A smaller, honest version stays in core: *where were historical dengue peaks largest relative to current recorded hospital capacity?* It does not claim which areas would exceed capacity.

## 6. Analytical questions

The business questions break into analytical questions. Each one is answered by a gold mart. The full list, with wording and the mart that answers it, is in the question map workbook (`capstone_gold_question_map.xlsx`).

| Group | IDs | What it asks | Gold object |
|---|---|---|---|
| Need | N2, N3, N4 | Disease burden by area (TB notifications, modelled deaths and prevalence, dengue peaks) | `mart_area_burden_indicator`, `mart_dengue_peak_capacity` |
| Supply | S1, S3 | Beds, health stations and health centres per population | `mart_area_service_profile` |
| Access | A1–A4 | Areas with no hospital or primary care recorded; highest hospital level; population per facility or bed; distance to care | `mart_locality_service_presence`, `fact_area_access` |
| Workforce | W1, W2 | Doctors, nurses, midwives and barangay health workers per population | `mart_area_service_profile` |
| Equity | E1, E2 | Service gaps by poverty band | `mart_area_service_profile` |
| Priority | P1, P2 | Areas with high burden and several gaps; how the ranking moves with weights | `mart_area_priority` |
| TB case study | T1, T2 | TB rates against workers and primary care; preventive treatment and treatment success | `mart_tb_case_study` |
| Kidney case study | K1 | High kidney disease mortality with few dialysis stations (specialist treatment capacity) | `mart_kidney_case_study` |
| Dengue (core view) | — | Historical dengue peaks relative to current recorded capacity | `mart_dengue_peak_capacity` |

**Access questions, as reworded on 2026-10-12**

| ID | Question |
|---|---|
| A1 | Using the latest available facility registry, which cities and municipalities have no hospital or licensed primary care facility recorded, and how many residents live in each? |
| A2 | What is the highest recorded hospital level per city, municipality and province? Which areas have no Level 3 hospital recorded within their boundaries? |
| A3 | Using the latest available HFSRB list, how many residents live in each area without a recorded facility? |
| A4 | Which cities and municipalities have the highest population per recorded hospital, licensed primary care facility or hospital bed? |

## 7. Success criteria

| # | Criterion | How we show it |
|---|---|---|
| 1 | The dashboard shows where government should add services | BQ1 marts answer every core analytical question above |
| 2 | Every number can be traced to its source | Lineage from a dashboard cell to a source cell (silver lineage + `build_inputs`) |
| 3 | Areas that cannot be compared fairly are flagged, not hidden | `comparison_eligible`, `exclusion_reason` and `mapping_outcome` on mart rows |
| 4 | The pipeline can rerun safely | Idempotency evidence: three full runs on the same inputs; every gold QC G12 row passes on runs 2 and 3 ([evidence](../06-evidence/README.md)) |
| 5 | Restricted data stays restricted | Aggregates only; cells under 3 suppressed; raw files not in the repo |

Confirm criteria 1–5 against the team's success-criteria slide before the final submission.

## 8. The platform name

**LUNASaan?** combines *lunas* (cure) and *saan* (where): "where is the cure?"

Motto: **Tamang Datos. Tamang Lugar. Tamang Tugon.** The right data, for the right place, for the right response.

## 9. History of updates

| Date | Change |
|---|---|
| 2026-09-30 | Stakeholders and dashboard-only output agreed (D-01, D-02) |
| 2026-10-01 | Two business questions kept; access and equity are part of BQ1 (D-04) |
| 2026-10-02 | Plan presented to the client persona; 4-week timeline |
| 2026-10-07 | Business Questions v3 |
| 2026-10-09 | BQ1 gains a prevention view; BQ2 becomes stretch goal 2 (D-26, D-27) |
| 2026-10-12 | Access questions A1–A4 reworded |
| 2026-10-14 | Core dengue question reworded to "largest relative to current recorded capacity" (D-39) |
| 2026-10-19 | Page written from the decision log and the presentation script |
| 2026-10-20 | Criterion 4: three evidence runs |