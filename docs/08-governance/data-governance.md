# Data governance

How the platform handles data that comes with conditions: restricted releases, licensed data, personal details and attribution. These rules apply in every layer and on the dashboard.

Status date: 2026-10-20. Decision behind most of this page: D-47.

---

## 1. Sharing classes

Every source has a `sharing` value in its YAML entry ([data sources](../02-data/data-sources.md)):

| `sharing` | Sources | What may leave the platform |
|---|---|---|
| `open` | Open licence (CC BY, ODbL): HDX, UP NOAH, OpenStreetMap / healthsites.io, PSA open tables | Values and exports, with attribution |
| `public` | Published by a government agency: DOH NHFR, HFSRB lists, FHSIS | Values and exports |
| `restricted` | FOI releases (DOH dengue, HFSRB hospital beds, PhilHealth claims, DOH Region II TB, PhilHealth TB claims), the Davao hospital extract, IHME GBD (licence) | Aggregates only, with small cells suppressed |

## 2. Why restricted data is restricted

The release letters set no sharing terms of their own. The restriction is **our own commitment**, made in each request: the data is for academic use (the FTW capstone) and is reported only in aggregate form, with small-cell suppression where needed (D-47). IHME GBD is restricted by its licence: non-commercial use, no redistribution of the export.

If the dashboard is published beyond the capstone, ask each FOI officer to confirm aggregate publication in writing first ([data request log](../02-data/data-request-log.md)).

## 3. Rules for restricted data

| Layer | Rule |
|---|---|
| Landing | Files sit under `<domain>/restricted/`. They are never committed to GitHub |
| Repository | No raw restricted file, and no request or release document: those hold the requester's address, phone and ID link. The repository records only ticket numbers, agencies, scope and dates |
| Bronze | Loaded as text like any source; bronze QC writes no column profile for them |
| Silver | Kept at row level for the pipeline only. Never profiled, never copied to `quality.quarantine`; QC stores counts and row references only. The Davao extract has no encounter id (dropped for privacy); anonymous bed records are never matched to registry facilities (D-18) |
| Gold | Published as aggregates only. A cell built from fewer than **3 records or hospitals** is suppressed (`value_status = 'suppressed'`) |
| Dashboard | Shows aggregates; restricted charts carry "Aggregated; cells under 3 suppressed" |
| Docs and config | No record-level restricted value. Aggregate totals used as QC controls (for example claims filed per year) are the only restricted figures in the YAML |
| IHME | `value_lower` / `value_upper` are kept out of column profiles; values are labelled as modelled |

## 4. Personal data

| Data | Treatment |
|---|---|
| Hospital extract (Davao pneumonia) | De-identified at source; the encounter id is dropped in silver; restricted handling above |
| Hospital bed records (HFSRB FOI) | Anonymous records; never matched to named facilities |
| PhilHealth claims | Aggregated by hospital, year and package; facility location only, not patient residence |
| FOI request and release documents | Hold the requester's personal details; stored outside the repository |
| Team members | Names only in the docs; no contact details |

## 5. Attribution

| Source | Show on every chart that uses it |
|---|---|
| IHME GBD 2023 | The IHME attribution line; label values as modelled |
| OpenStreetMap / healthsites.io | "© OpenStreetMap contributors" (ODbL 1.0) |
| HDX dengue and COD-AB boundaries | Dataset name and publisher (CC BY) |
| UP NOAH | Publisher (ODbL) |
| Restricted (FOI) sources | "Aggregated; cells under 3 suppressed" |
| PSA, DOH | Agency and table, as published |

## 6. Access control

`sharing: restricted` is declared, not enforced. The workspace is a personal Databricks workspace used by the team; Unity Catalog grants on the restricted bronze and silver tables are in the backlog (item 23). Until then, the protection is that restricted rows never leave silver except as suppressed aggregates.

## 7. Retention

| Item | Kept |
|---|---|
| Landing files | Never edited or deleted; a new release is a new file |
| Bronze, silver, gold | Delta history keeps earlier versions; how long is not decided (contract O4) |
| Quality tables | Append-only; nothing is deleted |
| Quarantine copies | Replaced per check on each QC run (latest state only) |

## 8. Running without restricted data

Set the restricted YAML entries to `enabled: false`. The pipeline still runs; the outputs that depend on them are missing ([data request log](../02-data/data-request-log.md), section 5).

## 9. History of updates

| Date | Change |
|---|---|
| 2026-10-08 | FOI datasets labelled `sharing: restricted` (D-19) |
| 2026-10-18 | Basis set: our own aggregate-only commitment; suppression under 3 (D-47) |
| 2026-10-20 | Page written |