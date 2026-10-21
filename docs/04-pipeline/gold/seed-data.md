# Gold — seed data

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Gold holds a few **reviewed lists**: choices the team makes, written as rows in the SQL files instead of logic buried in queries. This page lists each one, what it decides, why it is a list, and how to change it safely.

Status date: 2026-10-20. Back to the [gold overview](README.md).

---

## 1. Why seeds

| Reason | Effect |
|---|---|
| A choice is visible and reviewable | "Which source does the dashboard show for dengue in 2023?" is one row, not a `WHERE` clause in three marts |
| One place to change | The marts and default views join the seed, so a change reaches every consumer |
| Counted, not typed | Each build counts its list and records the count in `build_inputs.input_rows` (rule 2a, D-62). A gate checks the list where the logic depends on its content |

## 2. Overview

| Seed | File | Rows | Object | Checked by |
|---|---|---|---|---|
| Source list | `gold_03` | 25 | `dim_data_source` | Gates: value type, sharing, domain, names |
| Named areas | `gold_01` | 7 | Rows of `dim_geography` | Gates: key, parent and unit keys resolve |
| Profession list | `gold_08` | 9 | Columns of `fact_workforce_capacity` | Gates: every profession has a name and group; exactly 3 `core_clinical` |
| Source priority | `gold_10` | 34 | `source_priority` | `raise_error`: duplicate key, unknown source, two overlapping preferred rules |
| HUC name list | `gold_11` | 17 | `huc_province_crosswalk` | Check query: every HUC `matched` |
| Weight sets | `gold_19` | 12 | `priority_weight_params` | `raise_error`: each set has 4 rows summing to 1 |
| Settings | Each table file, step [0] | — | `build_log.parameters` | Recorded with every build |

## 3. Source list (`dim_data_source`, gold 03)

Copied by hand from `config/sources_<domain>.yaml`. **When a YAML entry changes** (name, as-of date, licence, sharing), change its row here in the same commit.

| `source_dataset` | Organization | Value type | Sharing | Used in |
|---|---|---|---|---|
| `doh_foi_dengue` | DOH | reported | restricted | `fact_disease_metric` |
| `upnoah` | UP NOAH | reported | open (ODbL) | `fact_disease_metric` |
| `hdx_dengue` | HDX | reported | open (CC BY) | `fact_disease_metric` |
| `psa_deaths_national_monthly` | PSA | registered | open | `fact_disease_metric` |
| `psa_deaths_region_annual` | PSA | registered | open | `fact_disease_metric` |
| `psa_deaths_national_annual` | PSA | registered | open | `fact_disease_metric` |
| `doh_fhsis` | DOH | reported | open | `fact_disease_metric` |
| `philhealth_foi_claims_hospital` | PhilHealth | reported | restricted | `fact_disease_metric` |
| `hdx_healthsites` | Healthsites.io / OSM | reported | open (ODbL) | `ref_osm_healthsite_point` |
| `ihme_gbd` | IHME | modelled | restricted (licence) | `fact_disease_metric` |
| `facilities_registry` | DOH (NHFR, HFSRB) | reported | open | `fact_facility_capacity`, `dim_facility` |
| `psa_hospitals_region_annual` | PSA | reported | open | `fact_facility_capacity` |
| `psa_beds_region_annual` | PSA | reported | open | `fact_facility_capacity` |
| `psa_hospitals_national_annual` | PSA | reported | open | `fact_facility_capacity` |
| `psa_hospitals_beds_national_annual` | PSA | reported | open | `fact_facility_capacity` |
| `psa_hospitals_region_annual_legacy` | PSA | reported | open | `fact_facility_capacity` |
| `psa_bhs_region_annual` | PSA | reported | open | `fact_facility_capacity` |
| `bed_occupancy` | DOH (HFSRB) | reported | restricted | none (superseded 2026-10-14, kept for lineage) |
| `doh_foi_hospital_beds` | DOH (HFSRB) | reported | restricted | `fact_facility_capacity` |
| `doh_fhsis_demographic` | DOH | reported | open | `fact_facility_capacity`, `fact_workforce_capacity`, `fact_area_indicator` |
| `psa_gov_practitioners` | PSA | reported | open | `fact_workforce_capacity` |
| `psa_poverty` | PSA | survey_estimate | open | `fact_area_indicator` |
| `psa_psgc` | PSA | census | open | `dim_geography`, `fact_area_indicator` |
| `psa_health_expenditure_share_national_annual` | PSA (PNHA) | reported | open | `fact_area_indicator` |
| `psa_health_expenditure_per_capita_national_annual` | PSA (PNHA) | reported | open | `fact_area_indicator` |

**Why `source_dataset` = the silver `_source_key`.** The facts compute `data_source_key = xxhash64(_source_key)` from the silver rows. A new silver source without a row here stops every fact build at its "data_source_key not in dim_data_source" gate. That is deliberate: no number reaches the dashboard without a named source and a sharing rule.

**Why notes sit in `source_name`.** Some notes change how you read a source (D-44, D-45, D-46). In `source_name`, they reach the dashboard's "about the data" page without another join.

## 4. Named areas (gold 01)

| `area_code` | Name | Level | Planning unit |
|---|---|---|---|
| `ph` | Philippines | country | — |
| `foreign` | Foreign country | foreign | — |
| `hist:maguindanao` | Maguindanao (undivided) | historical_province | — (parent BARMM) |
| `ncr-district:1` … `4` | NCR, First to Fourth District | ncr_district | NCR |

**Why.** Sources publish rows for areas PSGC does not list: the national total, deaths abroad, the province split in 2022, NCR's districts. A named row lets them join a dimension. Without it, gold would drop them.

## 5. Professions (gold 08)

| `profession_code` | Name | Group |
|---|---|---|
| `doctors` | Doctors | core_clinical |
| `nurses` | Nurses | core_clinical |
| `midwives` | Midwives | core_clinical |
| `bhw` | Barangay health workers | community |
| `dentists` | Dentists | other |
| `medtech` | Medical technologists | other |
| `nutritionists` | Nutritionists | other |
| `sanitary_engineers` | Sanitary engineers | other |
| `sanitary_inspectors` | Sanitary inspectors | other |

**Why a list and not a dimension.** Nine values, used by one fact (D-36). **Why the gate on `core_clinical` = 3.** The workforce gap rule ("two of three") in gold 19 depends on exactly these three.

## 6. Source priority (gold 10)

34 rules: 30 `preferred`, 2 `cross_check`, 2 `fallback`. Source of the rules: the diseases, workforce and population plans.

| Metric | Scope | Level | Grain | Years | Source | Role |
|---|---|---|---|---|---|---|
| cases | dengue | region | week | 2016–2019, 2022–2025 | `upnoah` | preferred (2 rules) |
| cases, deaths | dengue | region | month | 2021–2025 | `doh_foi_dengue` | preferred (2) |
| cases, deaths | dengue | province | week | 2016–2020 | `hdx_dengue` | preferred (2) |
| deaths | PSA list | country | month | 2020–2024 | `psa_deaths_national_monthly` | preferred |
| deaths | PSA list | country | year | 2015–2019 | `psa_deaths_national_annual` | preferred |
| deaths | PSA list | country | year | 2020–2024 | `psa_deaths_national_monthly` | preferred |
| deaths | PSA list | country | year | 2020 | `psa_deaths_national_annual` | fallback (preliminary) |
| deaths | PSA list | country | year | 2023–2024 | `psa_deaths_region_annual` | cross_check |
| deaths | PSA list | region | year | 2023–2024 | `psa_deaths_region_annual` | preferred |
| cases | tuberculosis | country, region, province, city, municipality | year | 2024–2025 | `doh_fhsis` | preferred (5) |
| TPT given, eligible contacts, treatment cohort, success | tuberculosis | any | year | 2025 | `doh_fhsis` | preferred (4) |
| deaths, prevalence | IHME | province, region (NCR) | year | 2019–2023 | `ihme_gbd` | preferred (4) |
| 4 claims metrics | PhilHealth packages | any | year | 2016–2025 | `philhealth_foi_claims_hospital` | preferred (4) |
| headcount | — | any | year | 2012–2017 | `psa_gov_practitioners` | preferred |
| headcount | — | any | year | 2018–2025 | `doh_fhsis_demographic` | preferred |
| headcount | — | any | year | 2018–2023 | `psa_gov_practitioners` | cross_check |
| population | — | any | year | 2015–2024 | `psa_psgc` | preferred |
| population | — | any | year | 2018–2025 | `doh_fhsis_demographic` | fallback (FHSIS rates only) |

Each row also has a `reason` and a `replay_eligibility` (for the stretch-2 dengue replay). The reasons carry D-42 to D-46.

**Checks** (each must return no row; a failure stops the file):

1. No duplicate key.
2. Every source is in `dim_data_source`.
3. No two `preferred` rules overlap for the same metric, scope, level and grain. This is what makes "one preferred source per question" true, and gold QC G10 checks it again on the default view.

**Status.** The rules remain a proposal for team review (D3 in the proposal). Changing one does not change any fact; it changes which source the default view and the marts show.

## 7. HUC name list (gold 11)

The 17 HUCs outside NCR and their provinces: Baguio (Benguet), Angeles (Pampanga), Olongapo (Zambales), Lucena (Quezon), Puerto Princesa (Palawan), Iloilo (Iloilo), Bacolod (Negros Occidental), Cebu, Lapu-Lapu and Mandaue (Cebu), Tacloban (Leyte), Zamboanga (Zamboanga del Sur), Cagayan de Oro (Misamis Oriental), Iligan (Lanao del Norte), Davao (Davao del Sur), General Santos (South Cotabato), Butuan (Agusan del Norte).

**Why.** PSGC gives a HUC no province parent. The sources and the kidney study need one. The seed looks up codes in `dim_geography` by normalized name, level and region, so nobody types a code. **When PSGC adds a HUC**, it shows as `not_in_name_list`. Add it here. To-do 19 moves the list to silver.

## 8. Weight sets (gold 19)

| Weight set | Primary care | Hospital | Workforce | Socioeconomic | Why |
|---|---|---|---|---|---|
| `equal` (default) | 0.25 | 0.25 | 0.25 | 0.25 | No gap type has a basis to count more |
| `supply_heavy` | 0.35 | 0.35 | 0.20 | 0.10 | Sensitivity test: service supply counts more |
| `equity_heavy` | 0.20 | 0.20 | 0.20 | 0.40 | Sensitivity test: poverty counts more |

Check: each set has 4 rows summing to 1. Agreed by the team 2026-10-19 (D-56). Evidence that the ranking does not hinge on the weights: `gold_o13_evidence.sql` (run in the workspace; not kept in the repo) Q1–Q2.

## 9. Settings (step [0] of each table file)

Each file declares its settings once, at the top. `build_log.parameters` records them. So every build can say which values it used.

| Setting | File | Value | Meaning |
|---|---|---|---|
| `strict_input_builds` | every table | false | true: every silver input needs a succeeded build row (notebook-built silver tables have none) |
| `block_on_silver_qc_fail` | every table | true | A silver input whose latest QC has a FAIL stops the build |
| `code_version`, `job_run_id` | every table | null | Git commit and job run, when passed |
| `pandemic_year_from`, `pandemic_year_to` | 02 | 2020, 2022 | `is_pandemic_period` (O-14) |
| `suppression_min_records` | 06 | 3 | Gold suppresses occupancy groups under it (D-47) |
| `suppression_min_hospitals` | 07 | 3 | Gold suppresses claims cells under it (D-47) |
| `census_province_excl_huc_years` | 09 | [2024] | Census years whose province rows exclude HUCs |
| `share_level1_tolerance_pct` | 09 | 0.2 | Level-1 expenditure shares must sum to 100 within it (same as silver) |
| `planning_unit_rule` | 01 | `O-01` | Recorded label of the planning-unit rule |
| `ihme_includes_huc_confirmed` | 22 (view) | true | D-42: broad units pass gate 3 |

## 10. How to change a seed

1. Edit the list in its file. Keep the file's history line up to date.
2. If the list mirrors a YAML (source list), change both in the same commit.
3. Rerun the file, then every file after it in run order (the seeds feed the facts and marts).
4. Run `gold_qc.py`. A changed seed changes content, so G12 will WARN once; the detail says the inputs changed.
5. Record the reason in the [decision log](../../08-governance/decision-log.md) if it changes a result.

## 11. History of updates

| Date | Change |
|---|---|
| 2026-10-14 | Seeds written for the combined model |
| 2026-10-18 | `source_priority` reasons updated for D-42 to D-46; no rule changed |
| 2026-10-19 | Weight sets agreed (D-56) |
| 2026-10-20 | Named areas, professions and the source list defined as views and counted (D-62). Page written |
| 2026-10-20 | Rewritten in short, active sentences |
