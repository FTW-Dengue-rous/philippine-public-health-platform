# Data sources

This page lists every source dataset the pipeline loads, who publishes it, what it covers and how it may be shared. Each source feeds specific analytical questions in the BQ1 framework. See [business context](../01-context/problem-and-business-context.md) for the question-to-source traceability.

Last updated: 2026-10-21

**The YAML files are the source of truth.** Each source is one entry in `config/sources_<domain>.yaml`. The entry name is its `source_key`. When this page and a YAML file disagree, the YAML wins. Fix this page in the same pull request. The bronze loader reads the config, loads the file(s) with all data columns as STRING, and adds lineage columns; see [bronze pipeline](../04-pipeline/bronze/README.md) for loader details.

Landing root: `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`

Base list from the bronze inventory of 2026-10-11, plus the entries added on 2026-10-14.

---

## 1. Summary

| Domain | Sources | Bronze tables | Config |
|---|---|---|---|
| Diseases | 19 | 16 + 2026-10-14 entries | [`sources_diseases.yaml`](../../config/sources_diseases.yaml) |
| Facilities | 16 | 15 | [`sources_facilities.yaml`](../../config/sources_facilities.yaml) |
| Workforce | 3 | 3 | [`sources_workforce.yaml`](../../config/sources_workforce.yaml) |
| Socioeconomic | 5 | 5 | [`sources_socioeconomic.yaml`](../../config/sources_socioeconomic.yaml) |
| Geography | 2 | 2 | [`sources_geography.yaml`](../../config/sources_geography.yaml) |
| Population | 1 (QC only) | — (payload inside the PSGC table) | [`sources_population.yaml`](../../config/sources_population.yaml) |

Counts are from the `run_bronze.py` run of 2026-10-19 (46 source entries; `doh_fhsis_demographic` counts in both facilities and workforce). Confirm exact table counts from `ingestion_metadata` after the next full job run.

## 2. Sharing values

| `sharing` | Meaning | Rule |
|---|---|---|
| `open` | Open licence (for example CC BY, ODbL) | Export allowed; keep attribution |
| `public` | Published by a government agency | Export allowed |
| `restricted` | FOI release, hospital extract or licensed data | Aggregates only; cells under 3 suppressed; raw file never committed ([D-47](../08-governance/decision-log.md#made)) |

## 3. Sources by domain

### Diseases

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `doh_foi_dengue` | DOH (eFOI, R-01) | Dengue cases and deaths | Region × month | Jan 2021 – Sep 2025 (2025 partial) | restricted |
| `upnoah` | UP NOAH | Dengue counts (DOH-EB counts via FOI 2026-031) | Region × ISO week | 2016–2019, 2022–2025 | open (ODbL) |
| `hdx_dengue` | HDX | Dengue cases and deaths | Province/city × week | 2016–2021 (2 files; the 2021 file repeats rows) | open (CC BY) |
| `doh_foi_tb_region2` | DOH Region II (eFOI, R-05) | TB tables (7 stacked) | Mixed | 2020–2025 | restricted · bronze only |
| `psa_deaths_national_monthly` | PSA | Registered deaths by cause | National × month | 5 files (2022–2024 releases) | open |
| `psa_deaths_region_annual` | PSA OpenSTAT | Registered deaths by cause, age group | Region × year | Multi-year | open |
| `psa_deaths_national_annual` | PSA | Registered deaths by cause | National × year | 2015–2020 | open |
| `psa_deaths_province_annual` | PSA | Registered deaths by cause and sex | Province × year | 2006–2015 | open |
| `psa_deaths_allcause_region_annual` | PSA Table 9.5 | All-cause deaths | Region × year | Multi-year | open |
| `psa_notifiable_national_annual` | PSA Table 9.15 | Notifiable diseases | National × year | Multi-year | open |
| `psa_morbidity_leading_national_annual` | PSA Tables 9.12, 9.13 | Leading causes of morbidity | National × year | Multi-year | open |
| `doh_fhsis_tb` | DOH FHSIS | TB notifications | City/municipality × year | 2024–2025 | public |
| `doh_fhsis_tb_tpt` | DOH FHSIS | TB preventive treatment (added 2026-10-14) | City/municipality × year × sex | 2025 | public |
| `doh_fhsis_tb_treatment_success` | DOH FHSIS | DS-TB and MDR-TB treatment success (added 2026-10-14) | City/municipality × year × sex | 2025 | public |
| `doh_fhsis_morbidity` | DOH FHSIS | Heart disease, pneumonia | Province × year | 2024 | public |
| `davao_hospital_pneumonia` | One government hospital (R-07) | Pneumonia admissions, de-identified | Patient encounter | 2017–2025, Davao region | restricted |
| `philhealth_foi_tb_claims` | PhilHealth (eFOI, R-06) | TB claims | Claim row | 2017–2019 | restricted · bronze only |
| `philhealth_foi_claims_hospital` | PhilHealth (FOI-REQ-2026-6223, R-03) | Claims by hospital and case-rate package, 14 packages (added 2026-10-14) | Hospital × year × package × status | 2016–2025 | restricted |
| `ihme_gbd` | IHME GBD 2023 | Modelled deaths and prevalence | Province × year | 2019–2023 (2 files) | restricted (licence) |

"Bronze only" means no silver build reads the source. The [silver diseases page](../04-pipeline/silver/diseases.md) lists what silver reads.
The four `doh_fhsis` disease entries write `_source_key = doh_fhsis` (`source_key_override`).

### Facilities

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `doh_nhfr` | DOH NHFR | Active hospitals with PSGC codes | Facility | As of 2026-09-29 | public |
| `doh_hfsrb_hospitals` | DOH HFSRB | Licensed hospitals | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_infirmaries` | DOH HFSRB | Licensed infirmaries | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_primary_care` | DOH HFSRB | Licensed primary care facilities | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_dialysis_clinics` | DOH HFSRB | Licensed dialysis clinics | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_blood_service` | DOH HFSRB | Licensed blood service facilities | Facility | As of 2026-06-30 | public |
| `hdx_healthsites` | HDX / healthsites.io | OpenStreetMap health facility points | Point | Newest file only | open (ODbL) |
| `psa_hospitals_region_annual` | PSA Table 9.18 | Hospitals by ownership | Region × year | 2020–2024 | open |
| `psa_beds_region_annual` | PSA Table 9.17 | Beds by ownership | Region × year | 2020–2024 | open |
| `psa_hospitals_national_annual` | PSA OpenSTAT | Hospitals | National × year | 2006–2015 | open |
| `psa_hospitals_beds_national_annual` | PSA Table 9.16 | Hospitals and beds | National × year | 1990–2015 | open |
| `psa_hospitals_region_annual_legacy` | PSA Table 9.17 (PSY 2024) | Hospitals, transposed layout | Region × year | 2005–2015 | open |
| `psa_bhs_region_annual` | PSA Table 9.19 | Barangay health stations | Region × year | Multi-year | open |
| `doh_fhsis_demographic` | DOH FHSIS | `BGY & BHS` tab: BHS, RHU, MHC, CHC, health centres | Area × year | 2018–2025 | public |
| `doh_foi_hospital_beds` | DOH HFSRB (eFOI, ticket DOH-984883683631) | Anonymous hospital bed capacity, bed-days, BOR | Hospital record (city/municipality) × year | 2018–2025 | restricted |
| `bed_occupancy` | Marked CONFIRM | Earlier bed occupancy file (2020–2025) | Hospital × year | — | restricted · replaced by `doh_foi_hospital_beds` in silver (2026-10-14) |

### Workforce

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `doh_fhsis_demographic` | DOH FHSIS | Health worker tabs (18 sheets), printed population | Area × year | 2018–2025 | public |
| `psa_gov_practitioners` | PSA Table 9.14 | Government practitioners by profession | Region × year | 2012–2023 | open |
| `psmo_oncologists` | PSMO | Medical oncologists | Area snapshot | One pull (date CONFIRM) | open |

### Socioeconomic

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `psa_poverty` | PSA | Poverty threshold, incidence, poor population (`tab2`, `tab6`) | Region/province × year | 2021, 2023, 2025 | open |
| `psa_health_expenditure_share_national_annual` | PSA Table 9.26 | Health expenditure share by financing agent | National × year | 2016–2023 | open |
| `psa_health_expenditure_per_capita_national_annual` | PSA Table 9.24 | Health expenditure per capita | National × year | 2016–2023 | open |
| `psa_child_mortality` | PSA Table 9.9 | Child mortality by characteristic (NDHS) | Region/characteristic | 2017, 2022 | open |
| `psa_psgc` | PSA | PSGC datafile with income class, urban/rural, 2024 population | Area | Q2 2024 | open · not used in silver (geography owns PSGC, [D-16](../08-governance/decision-log.md)) |

### Geography and population

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `psgc` | PSA PSGC API | Codes, names, levels, hierarchy, income class; population payload | Area (down to barangay) | Q2 2024 snapshot (43,762 records) | open |
| `hdx_phl_admin` | HDX COD-AB | Administrative boundary polygons | ADM1–ADM3 (17 / 88 / 1,642 features) | Current release | open |
| `psgc_population` | PSA (inside the PSGC payload) | Census population | Area × census year | 2015, 2020, 2024 | open · QC settings only |

## 4. Attribution rules

| Source | Show on every chart that uses it |
|---|---|
| IHME GBD | The IHME attribution line; label values as modelled |
| OpenStreetMap / healthsites.io | "© OpenStreetMap contributors" (ODbL 1.0) |
| HDX | Dataset name and publisher |
| Restricted (FOI) sources | "Aggregated; cells under 3 suppressed" |

## 5. Adding a source

1. Land the file under `<landing_root>/<domain>/<source>/` with the file-name pattern in [project conventions](../03-architecture/project-conventions.md).
2. Add one entry to `config/sources_<domain>.yaml`: identity, location, reading settings, `header_check`, `required_columns`, target table, `sharing`, `qc` block.
3. Run `run_bronze.py --plan true`, then [`run_bronze.py`](../../src/02_bronze/run_bronze.py).
4. Add a row to this page and, for FOI data, to the [Data request log](data-request-log.md).
5. Wire it into silver (reference maps, build file) and add it to [`dim_data_source`](../04-pipeline/gold/table-catalog.md) in gold.

## 6. Source acquisition

* **Open sources** are downloaded from public URLs or APIs and placed in the landing volume.
* **FOI sources** are obtained through eFOI requests to DOH. Each request has a ticket number where confirmed. See the [Data request log](data-request-log.md).
* **PSGC** is fetched via the PSA PSGC API by the [`psgc_ingestion`](../../src/01_ingestion/psgc_ingestion.ipynb) notebook in `src/01_ingestion`.
* **Admin boundaries** are fetched from HDX and processed by the [`admin_boundaries_ingestion`](../../src/01_ingestion/admin_boundaries_ingestion.ipynb) notebook in `src/01_ingestion`. This step runs outside the main job; see the [runbook](../07-operations/runbook.md) for the procedure.
* The landing volume is not synced by the DABs bundle. Files must be placed manually or by the ingestion notebooks.

## 7. History of updates

| Date | Change |
|---|---|
| 2026-10-06 | All domains moved to config-driven loading (D-12) |
| 2026-10-14 | Added FHSIS TB TPT and treatment success tabs, PhilHealth claims, HFSRB FOI bed occupancy as the occupancy source |
| 2026-10-19 | Page written from the bronze inventory and YAML entries |
| 2026-10-21 | Added Owner/Last updated metadata; added BQ1 framing, business-context link, bronze-pipeline link, and landing root to intro; added section 6 (source acquisition); fixed broken FOI log link (was `data-request-log.md`, now `foi-data-request-log.md`) |
| 2026-10-21 | Log restored to `data-request-log.md`: the committed `foi-data-request-log.md` was a one-line stub, and the full page now lives under the original name. Links point to `data-request-log.md`. The name stays general because the log covers FOI requests, hospital extracts and third-party releases, not only FOI |
| 2026-10-21 | Link text renamed to “Data request log” to match the file's general name |
| 2026-10-21 | Section 6: PSGC and admin-boundaries ingestion references now link to the notebooks in `src/01_ingestion` |
| 2026-10-21 | Cross-reference links added: the six config YAMLs in section 1; `run_bronze.py` and `dim_data_source` in section 5; decision references D-16 and D-47 |
