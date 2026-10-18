# Data sources

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Each source is configured in a YAML file under `config/`. The bronze loader reads the config, loads the file(s) with all columns as STRING, and adds lineage columns. See [bronze pipeline](../04-pipeline/bronze/README.md) for loader details.

Landing root: `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`

## Geography

| Source key | Provider | Format | Coverage | Reference year | Update frequency | License | Bronze table |
|---|---|---|---|---|---|---|---|
| `psgc` | PSA (classification.psa.gov.ph/psgc) | API (JSON) | All PSGC areas (region to barangay) | Q2 2024 | Quarterly | Open | `geography_bronze` |
| `hdx_phl_admin` | HDX (data.humdata.org) | GeoJSON | Admin boundaries levels 1–3 | 2024 | Irregular | Open (HDX) | `admin_boundaries_bronze` |

## Population

Population is embedded in the PSGC API response (`populations_json` field) and extracted in silver. Available years: 2015, 2020, 2024.

## Facilities

| Source key | Provider | Format | Coverage | Reference year | Update frequency | License | Bronze table |
|---|---|---|---|---|---|---|---|
| `doh_nhfr_hospitals` | DOH NHFR | CSV | All registered hospitals | 2026-09-29 | Snapshot | Open | `facilities_doh_nhfr_hospitals_bronze` |
| `doh_hfsrb_hospitals` | DOH HFSRB | XLSX | Licensed hospitals (gov + private) | 2026-06-30 | Biannual | Open | `facilities_doh_hfsrb_hospitals_bronze` |
| `doh_hfsrb_infirmaries` | DOH HFSRB | XLSX | Licensed infirmaries | 2026-06-30 | Biannual | Open | `facilities_doh_hfsrb_infirmaries_bronze` |
| `doh_hfsrb_primary_care` | DOH HFSRB | XLSX | Licensed primary care facilities | 2026-06-30 | Biannual | Open | `facilities_doh_hfsrb_primary_care_bronze` |
| `doh_hfsrb_dialysis_clinics` | DOH HFSRB | XLSX | Licensed free-standing dialysis clinics | 2026-06-30 | Biannual | Open | `facilities_doh_hfsrb_dialysis_clinics_bronze` |
| `doh_hfsrb_blood_service` | DOH HFSRB | XLSX | Licensed blood service facilities | 2026-06-30 | Biannual | Open | `facilities_doh_hfsrb_blood_service_bronze` |
| `psa_hospitals_region_annual` | PSA | CSV | Hospitals by region, 2020–2024 | 2024 | Annual | Open | `facilities_psa_hospitals_region_annual_bronze` |
| `psa_hospitals_national_annual` | PSA | CSV | Hospitals nationally, 2006–2015 | 2015 | Annual (legacy) | Open | `facilities_psa_hospitals_national_annual_bronze` |
| `psa_beds_region_annual` | PSA | CSV | Beds by region, 2020–2024 | 2024 | Annual | Open | `facilities_psa_beds_region_annual_bronze` |
| `psa_beds_national_annual` | PSA | CSV | Beds nationally, 1990–2015 | 2015 | Annual (legacy) | Open | `facilities_psa_beds_national_annual_bronze` |
| `psa_bhs_region_annual` | PSA | CSV | BHS by region, 2006–2023 | 2023 | Annual | Open | `facilities_psa_bhs_region_annual_bronze` |
| `hdx_healthsites` | HDX (OSM extract) | CSV | Health facility points (lat/lon) | 2026-09-29 | Irregular | Open (ODbL) | `facilities_hdx_healthsites_bronze` |
| `doh_fhsis_demographic` | DOH FHSIS | XLSX | BHS/RHU/MHC/CHC by province and city, 2018–2025 | 2025 | Annual | Open | `facilities_doh_fhsis_demographic_bronze` |
| `doh_foi_bed_occupancy` | DOH (FOI) | XLSX | Bed occupancy by hospital, 2020–2025 | 2025 | Annual | **Restricted** | `facilities_doh_foi_bed_occupancy_bronze` |
| `doh_foi_hospital_beds` | DOH (FOI DOH-984883683631) | XLSX | Hospital beds by municipality, 2018–2025 | 2025 | FOI request | **Restricted** | `facilities_doh_foi_hospital_beds_bronze` |

## Diseases

| Source key | Provider | Format | Coverage | Reference year | Update frequency | License | Bronze table |
|---|---|---|---|---|---|---|---|
| `doh_foi_dengue` | DOH (FOI) | CSV | Dengue cases/deaths by region × month, 2021–2025-09 | 2025-09 | FOI request | **Restricted** | `diseases_doh_foi_dengue_bronze` |
| `upnoah` | UP NOAH | XLSX | Dengue by region × week, 2016–2019, 2022–2025 | 2025 | Irregular | Open (ODbL) | `diseases_upnoah_dengue_regional_bronze` |
| `hdx_dengue` | HDX | CSV | Dengue by province × week, 2016–2020 + 2021 | 2021 | Irregular | Open | `diseases_hdx_dengue_*_bronze` |
| `ihme_neoplasm` | IHME | CSV | Neoplasm prevalence | 2021 | Irregular | Non-commercial | `diseases_ihme_neoplasm_*_bronze` |
| `globocan_2024` | IARC GLOBOCAN | XLSX | Cancer estimates | 2022 | Irregular | Non-commercial | `diseases_globocan_2024_bronze` |
| `doh_tb` | DOH | CSV | TB programme indicators | 2023 | Annual | Open | `diseases_doh_tb_*_bronze` |

## Workforce

| Source key | Provider | Format | Coverage | Reference year | Update frequency | License | Bronze table |
|---|---|---|---|---|---|---|---|
| `doh_fhsis_demographic` | DOH FHSIS | XLSX | Workforce by province/city, 2018–2025 | 2025 | Annual | Open | `workforce_doh_fhsis_demographic_bronze` |
| `psa_gov_practitioners` | PSA | CSV | Government medical practitioners by region, 2012–2023 | 2023 | Annual | Open | `workforce_psa_gov_practitioners_bronze` |
| `psmo_oncologists` | PSMO | CSV | Oncologists by province (directory snapshot) | 2024 | Irregular | Open | `workforce_psmo_oncologists_bronze` |

## Socioeconomic

| Source key | Provider | Format | Coverage | Reference year | Update frequency | License | Bronze table |
|---|---|---|---|---|---|---|---|
| `psa_poverty` | PSA | XLSX | Poverty threshold, incidence, magnitude by region/province, 2021/2023/2025 | 2025 | Biennial (survey) | Open | `socioeconomic_psa_poverty_bronze` |
| `psa_health_expenditure_share` | PSA | CSV | Health expenditure share of GDP, national, 2016–2023 | 2023 | Annual | Open | `socioeconomic_psa_health_expenditure_share_bronze` |
| `psa_health_expenditure_per_capita` | PSA | CSV | Health expenditure per capita, national, 2016–2023 | 2023 | Annual | Open | `socioeconomic_psa_health_expenditure_per_capita_bronze` |
| `psa_child_mortality` | PSA | CSV | Child mortality by region, 2017/2022 survey | 2022 | Survey | Open | `socioeconomic_psa_child_mortality_bronze` |

## Source acquisition

* **Open sources** are downloaded from public URLs or APIs and placed in the landing volume.
* **FOI sources** are obtained through eFOI requests to DOH. Each request has a ticket number (where confirmed). See [FOI request log](foi-data-request-log.md).
* **PSGC** is fetched via the PSA PSGC API (`src/01_ingestion/psgc_ingestion` notebook).
* **Admin boundaries** are fetched from HDX and processed via `src/01_ingestion/admin_boundaries_ingestion` notebook.
* The landing volume is not synced by the DABs bundle. Files must be placed manually or by the ingestion notebooks.
