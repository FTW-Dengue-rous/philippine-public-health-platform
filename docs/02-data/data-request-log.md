# Data request log

This page records every data request the team filed or used: Freedom of Information (FOI) requests, hospital extracts and third-party releases. Use it to know where restricted data came from, what was promised, and how to request it again.

Owner: LUNASaan Documentation Team

Last updated: 2026-10-21

> **Keep personal details out of the repository.** Request and release documents carry the requester's address, phone and ID link. Store them outside GitHub. Record only the ticket number, agency, scope and dates here ([D-47](../08-governance/decision-log.md#made)).

---

## 1. What we promised

Every request the team filed stated:

- the purpose: **academic research** (FTW capstone);
- that results are reported **only in aggregate form**;
- small-cell suppression where needed.

The release letters set no sharing terms of their own. The restriction comes from our promise. So the pipeline publishes these sources as aggregates only, suppresses cells built from fewer than 3 records or hospitals, and never commits the raw files ([D-47](../08-governance/decision-log.md#made)). See [data governance](../08-governance/data-governance.md) for the full sharing policy.

If the dashboard is published beyond the capstone, ask each FOI officer to confirm aggregate publication in writing first.

## 2. Request log

| # | Agency | Ticket / reference | Data requested | Filed | Received | Status | Used in pipeline |
|---|---|---|---|---|---|---|---|
| R-01 | DOH | eFOI (request filed around Sep 2025; ticket TBC) | Dengue cases and deaths by region and month | ~2025-09 | Before 2026-10-04 | Received | `doh_foi_dengue` → diseases silver |
| R-02 | DOH | DOH-984883683631 | Weekly dengue 2021–2025 and leptospirosis 2016–2025 by region/province/HUC; dengue admissions by province; hospital bed capacity, occupancy and daily census with NHFR code | 2026-09 (endorsed by 2026-09-30) | Partly (date TBC) | Partly received | `doh_foi_hospital_beds` → `facilities_bed_occupancy_silver` (2018–2025, anonymous records). Confirm which other parts arrived |
| R-03 | PhilHealth | FOI-REQ-2026-6223 | Claims by hospital and case-rate package (for the patient-residence vs hospital-distance idea) | 2026-09 (by 2026-09-30) | 2026-10-14 | Received | `philhealth_foi_claims_hospital` → `diseases_hospital_claims_silver`. TB was not included in the request |
| R-04 | DOH / HFSRB | eFOI 2026-5476 | Hospital bed capacity and occupancy | TBC | 2026-10-16 | Received, **not ingested** | None. Anonymous sheets 2016–2025 (2020–2025 CALABARZON only) and a named OHSRS 2023 sheet with DOH facility codes. Dropped before the capstone; decision pending (backlog 12) |
| R-05 | DOH Region II | eFOI (ticket TBC) | TB tables 2020–2025 | TBC | Before 2026-10-04 | Received | `doh_foi_tb_region2` → bronze only |
| R-06 | PhilHealth | eFOI (ticket TBC) | TB claims 2017–2019 | TBC | TBC | Received | `philhealth_foi_tb_claims` → bronze only |
| R-07 | Government hospital (Davao) | Shared extract | De-identified pneumonia admissions | — | Before 2026-10-01 | Received, not yet loaded | `davao_hospital_pneumonia` → `diseases_hospital_encounters_silver` (QC counts only). Config entry exists but bronze and silver tables are not yet built in this workspace |

### Third-party releases we use

| Source | Origin | Note |
|---|---|---|
| UP NOAH regional dengue | DOH-EB counts released through FOI 2026-031 (not our request) | Published openly by UP NOAH (ODbL). Counts by ISO week (D-46) |
| IHME GBD 2023 export | IHME results tool | Licence: non-commercial, no redistribution of the export. Treated as restricted |

## 3. Requests considered but not filed

| Idea | Why it was considered | Status (as recorded) |
|---|---|---|
| Nationwide de-identified pneumonia, 2024–2025 | Only Davao pneumonia data on hand | Weighed on 2026-09-30; not recorded as filed |
| Hospital-level data from Philippine Heart Center, PGH, East Avenue Medical Center | Bed share per disease | Weighed on 2026-10-01; not recorded as filed |
| A second DOH request for heart disease, pneumonia, TB admissions | Yearly counts cannot answer bed sufficiency | Weighed on 2026-09-30; not recorded as filed |

Update the table if any of these were filed.

## 4. How to request the same data again

1. File through the eFOI portal (`foi.gov.ph`) with the agency named in section 2.
2. State the purpose and the aggregate-only promise (section 1).
3. Ask for the same scope, grain and years. Ask for PSGC codes or facility codes where possible; they save weeks of matching.
4. When the release arrives, land it under `<domain>/restricted/`, add a YAML entry with `sharing: restricted` and the ticket number, and add a row here.

Expect weeks, not days. PhilHealth took about two weeks for R-03; the team planned for more than a month.

## 5. Running without restricted data

Set the YAML entries in section 2 to `enabled: false`. Expect these outputs to be missing or empty:

| Missing source | Effect |
|---|---|
| R-01 DOH dengue | Monthly dengue peaks (DOH FOI series) |
| R-02 hospital beds | Bed occupancy rows in `fact_facility_capacity` |
| R-03 PhilHealth claims | Claims metrics in `fact_disease_metric` |
| R-05 Region II TB | None beyond bronze |
| R-07 Davao pneumonia | `diseases_hospital_encounters_silver` (not yet built) |
| IHME | Modelled deaths and prevalence; kidney case study; part of the burden mart |

## 6. History of updates

| Date | Change |
|---|---|
| 2026-09-30 | R-02 endorsed; R-03 sent |
| 2026-10-14 | R-03 received and ingested |
| 2026-10-16 | R-04 received; not ingested before the capstone |
| 2026-10-18 | Sharing basis set: our own aggregate-only promise (D-47) |
| 2026-10-19 | Page written. Rows marked TBC need the ticket numbers and dates from the request emails |
| 2026-10-21 | Added Owner/Last updated metadata; added data-governance link to section 1; corrected R-07 status to "Received, not yet loaded" — bronze and silver tables not built in this workspace (verified via SHOW TABLES) |
| 2026-10-21 | File restored to `data-request-log.md` from `foi-data-request-log.md`: the log covers FOI requests, hospital extracts and third-party releases, not only FOI, so the general name is the right one |
