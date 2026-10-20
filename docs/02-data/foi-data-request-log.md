# Data request log

This page records every data request the team filed or used: Freedom of Information (FOI) requests, hospital extracts and third-party releases. Use it to see where restricted data came from, what the team promised, and how to request it again.

Status date: 2026-10-20.

> **Keep personal details out of the repository.** Request and release documents carry the requester's address, phone number and ID link. Store them outside GitHub. Record only the ticket number, agency, scope and dates here (D-47).

---

## 1. What the team promised

Every request the team filed stated:

- the purpose: **academic research** (FTW capstone);
- that results appear **only in aggregate form**;
- small-cell suppression where needed.

The release letters set no sharing terms of their own. The restriction comes from the team's promise. So the pipeline publishes these sources as aggregates only. Gold suppresses cells built from fewer than 3 records or hospitals. Nobody commits the raw files (D-47).

Before anyone publishes the dashboard beyond the capstone, ask each FOI officer to confirm aggregate publication in writing.

## 2. Request log

| # | Agency | Ticket or reference | Data requested | Filed | Received | Status | Used in the pipeline |
|---|---|---|---|---|---|---|---|
| R-01 | DOH | eFOI (filed around Sep 2025; ticket TBC) | Dengue cases and deaths by region and month | ~2025-09 | Before 2026-10-04 | Received | `doh_foi_dengue` → diseases silver |
| R-02 | DOH | DOH-984883683631 | Weekly dengue 2021–2025 and leptospirosis 2016–2025 by region, province and HUC. Dengue admissions by province. Hospital bed capacity, occupancy and daily census with NHFR codes | 2026-09 (endorsed by 2026-09-30) | Partly (date TBC) | Partly received | `doh_foi_hospital_beds` → `facilities_bed_occupancy_silver` (2018–2025, records with no hospital name). Confirm which other parts arrived |
| R-03 | PhilHealth | FOI-REQ-2026-6223 | Claims by hospital and case-rate package, for the patient-residence vs hospital-distance idea | 2026-09 (by 2026-09-30) | 2026-10-14 | Received | `philhealth_foi_claims_hospital` → `diseases_hospital_claims_silver`. The request did not include TB |
| R-04 | DOH / HFSRB | eFOI 2026-5476 | Hospital bed capacity and occupancy | TBC | 2026-10-16 | Received, **not ingested** | None. It holds sheets with no hospital name for 2016–2025 (2020–2025 for CALABARZON only) and a named OHSRS 2023 sheet with DOH facility codes. Left out by the data freeze. Decision pending (backlog item 12, KI-12) |
| R-05 | DOH Region II | eFOI (ticket TBC) | TB tables 2020–2025 | TBC | Before 2026-10-04 | Received | `doh_foi_tb_region2` → bronze only |
| R-06 | PhilHealth | eFOI (ticket TBC) | TB claims 2017–2019 | TBC | TBC | Received | `philhealth_foi_tb_claims` → bronze only |
| R-07 | Government hospital (Davao) | Shared extract | De-identified pneumonia admissions | — | Before 2026-10-01 | Received | `davao_hospital_pneumonia` → `diseases_hospital_encounters_silver` (counts only in outputs) |
| R-08 | DOH | OHSRS regional release (ticket TBC; confirm which request it answers) | Annual consolidated hospital statistics, 2016–2025, government and private, by region: inpatient average length of stay and outpatient re-visits | TBC | 2026-10-20 | Received, **not ingested** | None. Left out by the data freeze. Main use: bed-day demand for the full dengue capacity question (BQ2). Decision pending (backlog item 36, KI-13) |

### Third-party releases the team uses

| Source | Origin | Note |
|---|---|---|
| UP NOAH regional dengue | DOH-EB counts released through FOI 2026-031 (not a team request) | UP NOAH publishes them openly (ODbL). Counts by ISO week (D-46) |
| IHME GBD 2023 export | IHME results tool | Licence: non-commercial, no redistribution of the export. Treated as restricted |

## 3. Requests considered but not filed

| Idea | Why the team considered it | Status (as recorded) |
|---|---|---|
| Nationwide de-identified pneumonia, 2024–2025 | Only Davao pneumonia data was on hand | Weighed on 2026-09-30. Not recorded as filed |
| Hospital-level data from Philippine Heart Center, PGH and East Avenue Medical Center | Bed share per disease | Weighed on 2026-10-01. Not recorded as filed |
| A second DOH request for heart disease, pneumonia and TB admissions | Yearly counts cannot answer bed sufficiency | Weighed on 2026-09-30. Not recorded as filed |

Update the table if the team filed any of these.

## 4. How to request the same data again

1. File through the eFOI portal (`foi.gov.ph`) with the agency named in section 2.
2. State the purpose and the aggregate-only promise (section 1).
3. Ask for the same scope, grain and years. Ask for PSGC codes or facility codes where possible. They save weeks of matching.
4. When the release arrives, land it under `<domain>/restricted/`. Add a YAML entry with `sharing: restricted` and the ticket number. Add a row here.

Expect weeks, not days. PhilHealth took about two weeks for R-03. The team planned for more than a month.

## 5. Running without restricted data

Set the YAML entries of the sources below to `enabled: false`. Expect these outputs to be missing or empty:

| Missing source | Effect |
|---|---|
| R-01 DOH dengue | Monthly dengue peaks (DOH FOI series) |
| R-02 hospital beds | Bed occupancy rows in `fact_facility_capacity` |
| R-03 PhilHealth claims | Claims metrics in `fact_disease_metric` |
| R-05 Region II TB | Nothing beyond bronze |
| R-07 Davao pneumonia | `diseases_hospital_encounters_silver` |
| IHME | Modelled deaths and prevalence, the kidney case study and part of the burden mart |

## 6. Requests to file next

The [limitations and recommendations](../01-context/limitations-and-recommendations.md) page, section 3.1, lists the data the team would ask for, with the grain and the agency for each. The first requests to file:

| Priority | Request | Agency | Why |
|---|---|---|---|
| 1 | Weekly or monthly case counts by province and city or municipality for notifiable diseases, starting with any part of R-02 that did not arrive (weekly dengue, leptospirosis) | DOH Epidemiology Bureau (PIDSR) | Local peaks beyond dengue (RS-08, RP-11) |
| 2 | Admissions and length of stay by disease, by hospital or province, monthly | DOH (OHSRS) | Bed-day demand and BQ2 (RS-01, G-01) |
| 3 | Claims by the patient's city or municipality, with PSGC and facility codes | PhilHealth | Travel for care (RP-07, G-04) |
| 4 | Confirmation of the BOR bed basis and reporting period | DOH (HFSRB) | Occupancy definitions (RP-05, G-30) |

## 7. History of updates

| Date | Change |
|---|---|
| 2026-09-30 | R-02 endorsed. R-03 sent |
| 2026-10-14 | R-03 received and ingested |
| 2026-10-16 | R-04 received. Not ingested before the capstone |
| 2026-10-18 | Sharing basis set: the team's own aggregate-only promise (D-47) |
| 2026-10-19 | Page written. Rows marked TBC need the ticket numbers and dates from the request emails |
| 2026-10-20 | R-08 (OHSRS regional release) added. New section 6: requests to file next, linked to the recommendations. Rewritten in short, active sentences |