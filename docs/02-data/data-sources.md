# Data sources

This page lists every source dataset the pipeline loads. For each one it gives the publisher, what it covers and how you may share it.

**The YAML files are the source of truth.** Each source is one entry in `config/sources_<domain>.yaml`. The entry name is its `source_key`. When this page and a YAML file disagree, the YAML wins. Fix this page in the same pull request.

Status date: 2026-10-20. Inventory taken from the YAML files on that date. Table names and expected rows per table are in the [data dictionary](data-dictionary.md), section 3.

---

## 1. Summary

| Domain | Bronze tables | Config |
|---|---|---|
| Diseases | 19 | `sources_diseases.yaml` |
| Facilities | 15 | `sources_facilities.yaml` |
| Workforce | 3 | `sources_workforce.yaml` |
| Socioeconomic | 5 | `sources_socioeconomic.yaml` |
| Geography | 2 API sources (`geography_bronze`, `admin_boundaries_bronze`) | `sources_geography.yaml` |
| Population | No table of its own. The census payload sits inside `geography_bronze` | `sources_population.yaml` (QC settings only) |

Two notes on the counts:

- Some sources share a table. The four FHSIS disease entries write `_source_key = doh_fhsis`. `doh_foi_hospital_beds` and the superseded `bed_occupancy` share `facilities_bed_occupancy_bronze`.
- `doh_fhsis_demographic` feeds one table in facilities and one in workforce.

Live row counts are in `quality.table_stats`.

## 2. Sharing values

| `sharing` | Meaning | Rule |
|---|---|---|
| `open` | Open licence, for example CC BY or ODbL | You may export it. Keep the attribution |
| `public` | Published by a government agency | You may export it |
| `restricted` | FOI release, hospital extract or licensed data | Aggregates only. Gold suppresses cells under 3. Nobody commits the raw file (D-47) |

## 3. Sources by domain

### Diseases

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `doh_foi_dengue` | DOH (eFOI, R-01) | Dengue cases and deaths | Region × month | Jan 2021 – Sep 2025 (2025 partial) | restricted |
| `upnoah` | UP NOAH | Dengue counts: DOH-EB counts released through FOI 2026-031 | Region × ISO week | 2016–2019, 2022–2025 | open (ODbL) |
| `hdx_dengue` | HDX | Dengue cases and deaths | Province or city × week | 2016–2021. Two files; the 2021 file repeats rows | open (CC BY) |
| `doh_foi_tb_region2` | DOH Region II (eFOI, R-05) | TB tables, 7 stacked | Mixed | 2020–2025 | restricted · bronze only |
| `psa_deaths_national_monthly` | PSA | Registered deaths by cause | National × month | 2020–2024 (5 files) | open |
| `psa_deaths_region_annual` | PSA OpenSTAT | Registered deaths by cause and age group | Region × year | 2023–2024 | open |
| `psa_deaths_national_annual` | PSA | Registered deaths by cause | National × year | 2015–2020 (2020 preliminary) | open |
| `psa_deaths_province_annual` | PSA | Registered deaths by cause and sex | Province × year | 2006–2015 | open · bronze only |
| `psa_deaths_allcause_region_annual` | PSA Table 9.5 | All-cause deaths | Region × year | 1992–2023 | open · bronze only |
| `psa_notifiable_national_annual` | PSA Table 9.15 | Notifiable diseases | National × year | 2014–2021 | open · bronze only |
| `psa_morbidity_leading_national_annual` | PSA Tables 9.12, 9.13 | Ten leading causes of morbidity | National × year | Several years | open · bronze only |
| `doh_fhsis_tb` | DOH FHSIS | TB notifications | City or municipality × year | 2024–2025 | public |
| `doh_fhsis_tb_tpt` | DOH FHSIS | TB preventive treatment | City or municipality × year × sex | 2025 | public |
| `doh_fhsis_tb_treatment_success` | DOH FHSIS | DS-TB and MDR-TB treatment success | City or municipality × year × sex | 2025 | public |
| `doh_fhsis_morbidity` | DOH FHSIS | Heart disease and pneumonia | Province × year | 2024 | public |
| `davao_hospital_pneumonia` | One government hospital (R-07) | Pneumonia admissions, de-identified | Patient encounter | 2017–2025, Davao region | restricted |
| `philhealth_foi_tb_claims` | PhilHealth (eFOI, R-06) | TB claims | Claim row | 2017–2019 | restricted · bronze only |
| `philhealth_foi_claims_hospital` | PhilHealth (FOI-REQ-2026-6223, R-03) | Claims by hospital and case-rate package, 14 packages | Hospital × year × package × status | 2016–2025 | restricted |
| `ihme_gbd` | IHME GBD 2023 | Modelled deaths and prevalence | Province × year | 2019–2023 (2 files) | restricted (licence) |

"Bronze only" means no silver build reads the source. The [silver diseases page](../04-pipeline/silver/diseases.md) lists what silver reads.

### Facilities

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `doh_nhfr` | DOH NHFR | Active hospitals with PSGC codes | Facility | As of 2026-09-29 | public |
| `doh_hfsrb_hospitals` | DOH HFSRB | Licensed hospitals | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_infirmaries` | DOH HFSRB | Licensed infirmaries | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_primary_care` | DOH HFSRB | Licensed primary care facilities | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_dialysis_clinics` | DOH HFSRB | Licensed free-standing dialysis clinics | Facility | As of 2026-06-30 | public |
| `doh_hfsrb_blood_service` | DOH HFSRB | Licensed free-standing blood service facilities | Facility | As of 2026-06-30 | public |
| `hdx_healthsites` | HDX / healthsites.io | OpenStreetMap health facility points. Silver reads the newest of 2 snapshots | Point | Newest snapshot | open (ODbL) |
| `psa_hospitals_region_annual` | PSA Table 9.18 | Hospitals by ownership | Region × year | 2020–2024 | open |
| `psa_beds_region_annual` | PSA Table 9.17 | Authorized beds by ownership | Region × year | 2020–2024 | open |
| `psa_hospitals_national_annual` | PSA OpenSTAT | Hospitals | National × year | 2006–2015 | open |
| `psa_hospitals_beds_national_annual` | PSA Table 9.16 | Hospitals and beds | National × year | 1990–2015 | open |
| `psa_hospitals_region_annual_legacy` | PSA Table 9.17 (PSY 2024) | Hospitals, older transposed layout | Region × year | 2005–2015 | open |
| `psa_bhs_region_annual` | PSA Table 9.19 | Barangay health stations | Region × year | 2006–2023 | open |
| `doh_fhsis_demographic` | DOH FHSIS | `BGY & BHS` tab: barangays, BHS, RHU, MHC, CHC, health centres | Area × year | 2018–2025 | public |
| `doh_foi_hospital_beds` | DOH HFSRB (eFOI DOH-984883683631, R-02) | Bed capacity, bed-days and BOR per reporting hospital, with no hospital name | Hospital record (city or municipality) × year | 2018–2025 | restricted |
| `bed_occupancy` | Source marked CONFIRM | Earlier bed occupancy file | Hospital × year | 2020–2025 | restricted · superseded by `doh_foi_hospital_beds` in silver (2026-10-14) |

### Workforce

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `doh_fhsis_demographic` | DOH FHSIS | Health worker tabs (18 sheets) and the printed population | Area × year | 2018–2025 | public |
| `psa_gov_practitioners` | PSA Table 9.14 | Government practitioners by profession | Region × year | 2012–2023 | open |
| `psmo_oncologists` | PSMO | Medical oncologists | Area snapshot | One pull (date marked CONFIRM) | open |

### Socioeconomic

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `psa_poverty` | PSA | Poverty threshold, incidence and poor population (`tab2`, `tab6`) | Region or province × year | 2021, 2023, 2025 | open |
| `psa_health_expenditure_share_national_annual` | PSA Table 9.26 | Health expenditure share by financing agent | National × year | 2016–2023 | open |
| `psa_health_expenditure_per_capita_national_annual` | PSA Table 9.24 | Health expenditure per capita | National × year | 2016–2023 | open |
| `psa_child_mortality` | PSA Table 9.9 | Child mortality by characteristic (NDHS) | Characteristic × survey year | 2017, 2022 | open |
| `psa_psgc` | PSA | PSGC datafile with income class, urban or rural, and 2024 population | Area | Q2 2024 | open · not used in silver (geography owns PSGC, D-16) |

### Geography and population

| `source_key` | Publisher | What it holds | Grain | Coverage | Sharing |
|---|---|---|---|---|---|
| `psgc` | PSA PSGC API | Codes, names, levels, hierarchy, income class, and the population payload | Area, down to barangay | Q2 2024 snapshot (43,762 records) | open |
| `hdx_phl_admin` | HDX COD-AB | Administrative boundary polygons | ADM1–ADM3 (17 / 88 / 1,642 features) | Version loaded on the capstone | open |
| `psgc_population` | PSA, inside the PSGC payload | Census population | Area × census year | 2015, 2020, 2024 | open · QC settings only |

## 4. Attribution rules

| Source | Show on every chart that uses it |
|---|---|
| IHME GBD | The IHME attribution line. Label the values as modelled |
| OpenStreetMap / healthsites.io | "© OpenStreetMap contributors" (ODbL 1.0) |
| HDX | Dataset name and publisher |
| Restricted (FOI) sources | "Aggregated; cells under 3 suppressed" |

## 5. Adding a source

1. Land the file under `<landing_root>/<domain>/<source>/`. Use the file-name pattern in [project conventions](../03-architecture/project-conventions.md).
2. Add one entry to `config/sources_<domain>.yaml`: identity, location, reading settings, `header_check`, `required_columns`, target table, `sharing` and a `qc` block.
3. Run `run_bronze.py --plan true`, then `run_bronze.py`.
4. Add a row to this page. For FOI data, also add a row to the [data request log](data-request-log.md).
5. Wire it into silver (reference maps, build file). Add it to `dim_data_source` in gold.

The sources the team would add next, and at which grain, are in [limitations and recommendations](../01-context/limitations-and-recommendations.md), sections 3.1 and 3.4 (RS-08).

## 6. History of updates

| Date | Change |
|---|---|
| 2026-10-06 | All domains moved to config-driven loading (D-12) |
| 2026-10-14 | Added the FHSIS TB preventive treatment and treatment success tabs and the PhilHealth claims. The HFSRB FOI bed file became the occupancy source |
| 2026-10-19 | Page written from the bronze inventory and the YAML entries |
| 2026-10-20 | Summary matched to the YAML inventory (42 file-source tables). Coverage years filled in from the YAML. "Bronze only" sources marked. Request IDs (R-xx) added. Link to the recommendations added. Rewritten in short, active sentences |