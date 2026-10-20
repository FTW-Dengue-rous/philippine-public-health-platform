# Silver: diseases

This page covers the diseases domain in silver: six built tables, four reference tables, the rules that decide which bronze rows are kept, and what has been run so far. The design source is `diseases-silver-plan.md` (v1.7, 2026-10-09). Facts dated 2026-10-11 or later on this page are newer than the plan and override it.

## Status

| Item | Status |
|---|---|
| Table design (`diseases-silver-plan.md` v1.7) | Designed, 2026-10-09 |
| `build_diseases_reference_maps.py` (drafts the four reference CSVs) | Run on Databricks, 2026-10-11, with `--overwrite true` |
| `diseases_silver_00_reference.sql` | Run on local Spark, 2026-10-09 (checks only, `read_files()` not tested locally). Databricks run: status not recorded. `01` ran on Databricks and needs these tables |
| `diseases_silver_01_metric.sql` | Run on Databricks, 2026-10-11 |
| `diseases_silver_02_deaths_age.sql` | Run on local Spark, 2026-10-09. Databricks result not recorded |
| `diseases_silver_03_hospital_encounters.sql` | Run on local Spark, 2026-10-09. Databricks result not recorded |
| `diseases_silver_04_source_coverage.sql` | Run on Databricks, 2026-10-11 and again 2026-10-14 (weekly completeness and per-area columns, see Results) |
| View `diseases_metric_wide_v` (created by `04`) | SQL written. Not separately checked on Databricks |
| `diseases_silver_qc.py`, checks S01 to S50, all six tables | Run on Databricks 2026-10-14: 143 results, 0 FAIL, 7 WARN (see Results) |
| `diseases_silver_05_tb_programme.sql` (`diseases_tb_programme_silver`) | Written 2026-10-14. Run on Databricks 2026-10-14: 73,216 rows, gates 0 |
| `diseases_silver_06_hospital_claims.sql` (`diseases_hospital_claims_silver`) | Written 2026-10-14. Run on Databricks 2026-10-14: 243,881 rows, gates 0 |
| `build_diseases_reference_maps.py`, PhilHealth claims sections (6b area pairs, 7 packages, 8 directory) | Added 2026-10-14. Run on local Spark against the claims bronze rows (other sources stubbed). Databricks run implied by the `06` build (the area map resolved every pair); not separately recorded |

Nothing on this page has the status "Verified".

## Sources

Bronze QC for all 16 diseases sources ran on Databricks on 2026-10-07 with 0 FAIL. Silver v1 reads nine of the bronze tables. Details of each source are in `sources_diseases.yaml` and [bronze.md](bronze.md).

| Bronze table (`_source_key`) | What it holds | Notes |
|---|---|---|
| `diseases_doh_foi_dengue_bronze` (`doh_foi_dengue`) | Dengue cases and deaths by region and month, 2021-01 to 2025-09, 18 regions | Restricted (eFOI). 2025 holds January to September only |
| `diseases_upnoah_dengue_regional_bronze` (`upnoah`) | Dengue cases by region and week number, 2016 to 2019 and 2022 to 2025, 17 regions | Open, ODbL. No Negros Island Region. Every row is flagged as approximated by the source |
| `diseases_hdx_dengue_bronze` (`hdx_dengue`) | Dengue cases and deaths by province or city and weekly date, two files | Open, CC BY. The 2021 file repeats rows of the main file (F1) |
| `diseases_psa_deaths_national_monthly_bronze` (`psa_deaths_national_monthly`) | Registered deaths by cause and month, Philippines, 2020 to 2024, five files | Open. Year comes from the file name |
| `diseases_psa_deaths_region_annual_bronze` (`psa_deaths_region_annual`) | Registered deaths by cause, region of usual residence and age group, 2023 and 2024 | Open. Feeds two silver tables. Includes `Philippines` and `FOREIGN COUNTRY` rows |
| `diseases_psa_deaths_national_annual_bronze` (`psa_deaths_national_annual`) | Registered deaths by cause, Philippines, 2015 to 2020 | Open. 2020 is preliminary |
| `diseases_fhsis_tb_bronze` (`doh_fhsis`) | TB notifications (all forms, drug-resistant) by area, 2024 and 2025 | Public. YAML entry is `doh_fhsis_tb` with `source_key_override: doh_fhsis`. Rows carry their own PSGC code |
| `diseases_ihme_gbd_bronze` (`ihme_gbd`) | Modelled deaths and prevalence by cause and province, 2019 to 2023, two files | Restricted by licence: non-commercial, no row-level export, attribution line on every chart |
| `diseases_davao_hospital_pneumonia_bronze` (`davao_hospital_pneumonia`) | Patient-level hospital encounters (ICD J18), one hospital | Restricted. Counts only in any output. The hospital is not named in gold |
| `diseases_fhsis_tb_tpt_bronze`, `diseases_fhsis_tb_treatment_success_bronze` (`doh_fhsis`, YAML entries 17 and 18) | TB preventive treatment (sheet TB-TPT) and treatment success, drug-susceptible and RR/MDR (TSR-DSTB, TSR-MDRTB), by area, 2025 | Public. Same 2025 workbook as `doh_fhsis_tb`. Rows carry their own PSGC code |
| `diseases_philhealth_claims_hospital_bronze` (`philhealth_foi_claims_hospital`, entry 19) | PhilHealth claims count and amount by admission year, hospital, case-rate package and claim status, 2016 to 2025, 245,405 rows | RESTRICTED (eFOI FOI-REQ-2026-6223, academic use, aggregate only). No PSGC and no facility code |
| `public_health.silver.facilities_registry_silver` | Facility registry (facilities domain) | Read by `06` to give claims hospitals a `facility_key`. Run facilities silver `01` first |
| `public_health.silver.geography_silver` | PSGC codes, names and levels | Reference input for the area map builder and for QC checks S49 and S50. See [silver-geography-population.md](silver-geography-population.md) |

Seven other diseases bronze tables have no v3 question and are not in silver v1 (plan section 12).

## Tables

### `diseases_metric_silver`

- **One row is** one measure of one disease in one area in one period from one source.
- **Key:** `(disease_key, area_key, period_grain, period_key, measure, _source_key)`.
- **Disease and area:** `disease_key`, `source_cause_code`, `source_cause_label`, `area_key`, `area_label_source`, `geo_level`, `psgc_code`, `parent_area_key`, `geo_coverage_basis`, `location_basis`.
- **Period:** `period_grain` (`year`, `month`, `week`), `period_key`, `year`, `month`, `week`, `period_start`, `period_end`, `period_basis`.
- **Measure:** `measure` (`cases`, `deaths`, `prevalence`), `measure_definition`, `value` (DECIMAL(20,4)), `value_unit` (always `count`), `value_lower`, `value_upper`, `value_type` (`registered`, `reported`, `modelled`), `value_status`.
- **Scope and flags:** `age_scope`, `sex_scope`, `is_partial_period`, `is_preliminary`, `is_approximated`, `source_plausibility_flag`, `is_superseded_area`.
- **Lineage (7):** `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_metric_source_columns`.
- **Used for:** every disease question in gold. It is long by measure so that each silver row comes from exactly one bronze row.

### `diseases_deaths_age_silver`

- **One row is** registered deaths of one cause in one area in one year in one age group.
- **Key:** `(disease_key, area_key, year, age_group, _source_key)`.
- **Columns:** the disease and area columns above, `year`, `age_group`, `age_from`, `age_to`, `deaths`, `value_status`, `measure_definition` (`registered_deaths`), `location_basis` (`usual_residence`), and the same seven lineage columns.
- **Source and use:** `psa_deaths_region_annual` only. Each bronze row becomes 20 rows: 19 age bands plus `not_stated`. It serves the cause-of-death profile by age group and region.

### `diseases_hospital_encounters_silver` (restricted, counts only)

- **One row is** one de-identified hospital encounter.
- **Key:** the bronze row reference `(_source_key, _source_file, _source_sheet, _source_row_num)`.
- **Kept:** `admission_date`, `discharge_date` (dates only), `date_status`, `occupancy_eligible`, `is_same_day`, `length_of_stay_days_published`, `stay_days_by_date`, `is_long_stay`, `is_inpatient_confirmed`, `died_in_hospital`, `death_fields_consistent`, `age_group` (banded), `sex`, `icd_code`, `level_of_care`, `patient_classification`, `phic_class`, `disposition`, `result`, `patient_province_area_key`, `patient_city_area_key`, `patient_location_status`, `is_same_province_as_hospital`, `location_basis` (`patient_origin`), and six lineage columns.
- **Dropped:** encounter id, barangay, height, weight, bill and coverage amounts, free-text diagnosis, times of day, exact age.
- **Used for:** a method check of how admissions and stays become occupied beds. It is not a dengue input. Gold v3 does not read it.
- **Restricted rules:** gates and QC results are counts. Row dispositions hold row references only. The table is never profiled and its rows are never written to `quality.quarantine`.

### `diseases_source_coverage_silver`

- **One row is** one source, disease scope, geographic level and period grain in one year: which periods it holds.
- **Key:** `(_source_key, disease_scope, geo_level, period_grain, year)`.
- **Columns:** `periods_expected` (1, 12, or a nominal 52), `periods_present`, `first_period`, `last_period`, `is_complete_year`, `missing_periods`, `areas_present`, `min_periods_per_area`, `max_periods_per_area`, `areas_complete`, `all_areas_complete`, `_silver_build_id`.
- **`is_complete_year`** is a source-level flag. Annual rows: always. Monthly: 12 months. Week-number sources (UP NOAH): 52 weeks. Date-based weeks (HDX): the dates are contiguous (`(last − first) / 7 + 1 = periods_present`) and span the year (first date ≤ 7 January, last ≥ 25 December). A year holds 52 or 53 of any weekday, so a contiguous spanning series always has 52 or 53 dates and 51 always means a missing week. The test does not depend on D4 (which only decides whether a date is the week start or end). Changed 2026-10-14: HDX was null before.
- **`areas_complete`** counts areas that hold every period the source holds that year (`>= periods_present`); `all_areas_complete` = `areas_complete = areas_present`. Gold (`gold_v2_30`) applies the per-area test on each fact row.
- **Used for:** like-for-like annual comparisons. Example: DOH FOI dengue 2025 holds 9 of 12 months, so 2025 is compared January to September only. It reads the published metric table, has no bronze input and writes no row dispositions.

### `diseases_tb_programme_silver`

- **One row is** one TB programme count for one area, year, age group and sex.
- **Key:** `(indicator, drug_resistance, area_key, year, age_group, sex, _source_key)`.
- **Indicators:** `tpt_given` (contacts given preventive treatment; 9 rows per area: 3 ages x 3 sexes), `tpt_eligible_contacts` (the FHSIS estimate, notified cases x 4 contacts x 70%; `value_type = 'estimated'`, unit `persons_estimated`, has decimals), `treatment_cohort` (4 age groups, both sexes; not split by sex in the source), `treatment_success` (cured + completed; 4 ages x 3 sexes). `drug_resistance` is `not_applicable`, `drug_susceptible` or `drug_resistant`.
- **Columns:** `indicator_definition`, `disease_key` (`tb_all_forms`, or `tb_drug_resistant` for RR/MDR), area columns, `period_*` (`reporting_year`), `value`, `value_unit`, `value_type`, `value_status`, `location_basis` (`reporting_unit`), and the seven lineage columns.
- **Rules:** areas come from the row's own PSGC code, looked up in the latest geography snapshot (same rule as `workforce_silver_01`). The Philippines row becomes `ph`. A code not in geography is quarantined (`psgc_not_in_geography`). `*` and blank are `no_report`. The printed % columns are not loaded; a warn gate compares them with the recomputed %.
- **Used for:** TB case-study coverage and success rates in gold. Gold computes the percentages.

### `diseases_hospital_claims_silver` (restricted, aggregate only)

- **One row is** the PhilHealth claims of one hospital, in one admission year, for one case-rate package and one claim status.
- **Key:** `(year, facility_name_norm, area_key, disease_key, claim_status, _source_key)`.
- **Measures:** `claims_count`, `claims_amount_php` (`amount_basis = 'amount_claimed'`: filled for every status, not the amount paid), `source_rows` (bronze rows summed into the row).
- **Hospital:** `facility_name` (as published), `facility_name_norm`, `ownership` (HF Sector), `facility_key` and `facility_match_method` (`name_lgu`, `name_province`, `name_tokens_lgu`, `ambiguous`, `unmatched`).
- **Area:** the hospital's city or municipality: `area_key`, `psgc_code`, `geo_level`, `parent_area_key`, `region_area_key`, `area_label_source`, `province_label_source`, `region_label_source` (PhilHealth office label, kept as text), `location_basis = 'facility_location'`.
- **Package:** `disease_key` (`phic_*`), `illness_package_source`, `related_condition_group` (from the directory).
- **Claim status:** `paid`, `denied`, `returned_to_hospital`, `in_process`. Utilisation = all statuses; money paid = `paid` only.
- **Series flags:** `is_covid_period` (2020, 2021), `is_amount_series_break` (2024 on, case rates changed), `is_preliminary` (latest admission year in the file), `is_package_definition_change` (IHD with MI from 2025).
- **Restricted rules:** QC writes counts only, never a profile or quarantine rows. Gold publishes aggregates.

### Reference tables

All four are loaded as text by `00` from reviewed CSVs. The CSVs are drafted by `build_diseases_reference_maps.py`, which is a drafting tool and not a pipeline step.

| Table | One row is | Key | Used for |
|---|---|---|---|
| `diseases_area_map` | one published area label or id in one source | `(_source_key, match_type, match_value, parent_label_norm, year_from)` | Turns a printed label, an IHME location id or a row override into `area_key`, `psgc_code`, `geo_level`, `parent_area_key`, `geo_coverage_basis`. PhilHealth claims rows: one per (province, municipality) label pair, `parent_label_norm` = province, `geo_coverage_basis = 'facility_location'`, rule and evidence in `review_note` |
| `diseases_cause_map` | one published cause code or label in one source | `(_source_key, match_type, match_value)` | Gives `disease_key` and `row_class`. It also lists the documented non-data labels, so it classifies every PSA row |
| `diseases_directory_silver` | one disease or cause | `disease_key` | Names, classification, hierarchy, `related_condition_group`, `is_focus_disease`. Becomes `dim_disease` in gold. 14 PhilHealth packages with classification `phic_case_rate_package` |
| `diseases_cause_aggregation` | one cause in one approved aggregation set | `(aggregation_set, disease_key)` | The only allowed way to sum over causes. First set: `psa_death_composition_v1`, which must equal `all_causes` |

### Area keys

| Key | Meaning |
|---|---|
| `ph` | The Philippines (country rows and published national totals) |
| `psgc:<10-digit>` | A region, province, city or municipality by its PSGC code |
| `hist:maguindanao` | The undivided Maguindanao province kept by HDX, IHME and the hospital file. No current PSGC code. `is_superseded_area = true` |
| `foreign` | The PSA `FOREIGN COUNTRY` row (usual residence abroad) |

## Rules

### Write-audit-publish in `01`

`02`, `03` and `04` use the same sequence.

1. **Classify.** Every bronze row gets a `row_class`: `data`, `non_data`, `duplicate`, `quarantined` or `unclassified`. The result is saved to `diseases_metric_silver__classified`.
2. **Inputs.** `__inputs` holds one row per file or sheet read, with its load id and checksum from `ingestion_metadata`, plus one row per reference table.
3. **Candidate.** `__candidate` holds the rows to publish. Areas are joined before the unpivot, so a join cannot multiply a bronze row.
4. **Gates.** `__gates` holds one row per check. Every row must have `failures = 0`.
5. **Stop on failure.** A failed build is inserted into `quality.build_log` with `status = failed`, then `raise_error` stops the run. The published table is left as it was. The staging tables stay for inspection.
6. **Publish and record.** The table is replaced from `__candidate`, so the rows validated are the rows written. The build appends to `build_log`, `build_inputs` and `row_disposition` (rows not loaded only).

Gates in `01` cover: one load time and one ingestion log match per input, no unclassified rows, duplicates still equal after parsing (F1, F2), IHME scope constants, the F7 override still matching its row, cells that are a number or a documented marker, every cause and area resolving, valid periods, no negative values, key not null and unique, and row counts reconciling per source.

### Findings with a rule

| # | Finding | Rule |
|---|---|---|
| F1 | `hdx_dengue_province_weekly_2021.csv` repeats the 252 rows of 2021 already in the 2016 to 2021 file, with dates written day/month/year | All 252 rows get disposition `duplicate_of` with a reference to the kept row. Equality is tested after parsing (normalised area, date parsed with each file's own format, numeric cases and deaths). A gate re-tests it on every build |
| F2 | IHME cause 410 (Neoplasms) is in both files: 820 rows | The neoplasms-file rows are kept. The 820 rows in the main-causes file get `duplicate_of`. Gate: `val`, `lower` and `upper` are equal after casting |
| F7 | In the FHSIS TB 2024 sheet the `Philippines` row carries NCR's PSGC code | A `row_override` in the area map turns that row into `ph`. It matches on file, sheet, row number, printed label and printed code. If the file is revised, the override stops matching and a gate fails |
| F9 | FHSIS TB lists the Special Geographic Area and eight clusters with codes `19999xxxxx`: 9 rows per year | The rows are `quarantined` with reason `area_unresolved` until each has a reviewed identity and parent. Expected: 18 rows. Any other unresolved area fails a gate |
| F14 | HDX dengue weekly dates have one gap for every area, at the 2019 / 2020 boundary: 2019 holds 51 dates, 2020 starts on time. 2016 starts on 10 January (51 dates). The 2016-2021 file ends in early January 2021 (2 dates) | Recorded in the coverage table: 2016, 2019 and 2021 are `is_complete_year = false` for the source; 2017 (53), 2018 (52) and 2020 (52) are complete. S43 reports the gap as a WARN on all 126 areas: this is the expected result, not a new finding. Annual HDX comparisons in gold filter `is_complete_year = true`; peaks and weekly series are not affected |

Findings F3 to F6, F8 and F10 to F13 are in plan section 3.7.

### Other rules that change meaning

- **Counts only.** `value_unit` is `count` on every row. Silver holds no rates.
- **Null is not zero.** A missing value is null with a `value_status` of `no_report`, `not_applicable` or `missing`. A real 0 stays 0. A cell that is neither a number nor a documented marker fails a gate.
- **`measure_definition` says what was counted.** TB notifications, reported dengue cases, registered deaths and modelled numbers are different measurements.
- **`location_basis` says what the area means:** `usual_residence` (PSA), `reporting_unit` (FHSIS TB), `modelled_population` (IHME), `reporting_unconfirmed` (dengue sources), `patient_origin` (hospital).
- **Never sum across** `geo_level`, `period_grain`, `_source_key`, `value_type`, `measure_definition`, or a cause and its descendants. Prevalence is never summed across diseases. Published totals (`all_causes`, `ph`) are loaded as their own rows.
- **Week meaning is unconfirmed.** HDX and UP NOAH rows have null `period_start` and `period_end`, with `period_basis` `source_date_unconfirmed` or `week_number_unconfirmed`. Regions VI and VII have `geo_coverage_basis = region_pre_nir_definition` for UP NOAH and PSA 2023, and `region` for PSA 2024.
- **Hospital occupancy** uses the midnight census on dates, not the published length of stay. `is_inpatient_confirmed` is false on every row.

### PhilHealth claims rules (`06` and builder section 6b)

- **Area of a label pair.** The builder resolves each (HF Province, HF Municipality) pair against geography silver, first rule that gives exactly one place:
  1. `manila_district`: NCR `<district>, MANILA` → City of Manila.
  2. `in_province:<form>`: a city or municipality of the province whose name equals one form of the label (as printed, STA / STO / GEN / PRES expanded, outside or inside brackets, the word CITY added or removed, spaces removed).
  3. `city_in_region`: the same forms against the HUCs / ICCs of the province's region (CEBU / CEBU CITY).
  4. `in_province:initials` (GEN M ALVAREZ), `in_province:spelling` (edit distance up to 2, unique closest: OZAMIS CITY).
  5. `city_outside_listed_province` (COTABATO / COTABATO CITY → City of Cotabato, BARMM).
  6. `CLAIMS_AREA_MANUAL`: 4 reviewed decisions by target name (MUSUAN → Maramag, MENDEZ-NUNEZ → Mendez, SAN ISIDRO Davao del Norte → Sawata or San Isidro, RIZAL (MARCOS) Palawan → Dr. Jose P. Rizal or Rizal).
  Any pair that matches nothing stops the builder. Rules 4 to 6 write `REVIEW` in `review_note`. Province aliases: NORTH COTABATO → Cotabato, WESTERN SAMAR → Samar.
- **Packages.** 14 `Illness_Description` values map to `phic_*` keys (`CLAIMS_PACKAGES`). Groups: dengue (2), pneumonia_lri (2), hypertensive_disease (1), stroke (4), ischaemic_heart_disease (2); CHRONIC HEART DISEASES, ENCEPHALOPATHY and PRIMARY CARE have none. A new package stops the builder. A blank illness (1,404 rows) is quarantined (`illness_missing`).
- **Repeats are summed.** Rows with the same key (112 raw repeats, 8 more after name normalisation) are summed; the first bronze row carries the lineage, the others are `merged_into` with the silver key.
- **Facility match.** Tier 1 same name (spaces, AND / & / THE / OF ignored, SAINT = ST) in the same LGU; tier 2 same name, unique in the province (NCR: region); tier 3 same LGU, distinctive words left after removing generic and place words agree (shorter inside longer, 2+ shared or identical). Only a unique hit counts. No match leaves `facility_key` null.
- **Totals gate.** Per year, silver + quarantined rows = bronze, for count and amount.

## Run order

1. `build_diseases_reference_maps.py` (only when a new file arrives or a rule changes, then review the CSV diff)
2. `diseases_silver_00_reference.sql`
3. `diseases_silver_01_metric.sql`
4. `diseases_silver_02_deaths_age.sql`
5. `diseases_silver_03_hospital_encounters.sql`
6. `diseases_silver_04_source_coverage.sql` (reads the published metric table, so it runs after `01`)
7. `diseases_silver_05_tb_programme.sql`
8. `diseases_silver_06_hospital_claims.sql` (after facilities silver `01_registry`)
9. `diseases_silver_qc.py`

`quality_setup.sql` and geography silver must exist first. Each of `01` to `06` is one build with its own `_silver_build_id`. `04` covers the metric table only; `05` and `06` are not in the coverage table.

## Checks

Checks run by `diseases_silver_qc.py` on the published tables. Results go through `DQRun` into `quality.qc_results` with `batch_id = build:<build_id>`. Severities are from the script. The quality attribute column maps the script's check types to the project's attribute list.

| Check | Severity | Quality attribute |
|---|---|---|
| S01 table exists and has rows, S02 grain key not null | FAIL | completeness |
| S03 grain key unique | FAIL | uniqueness |
| S06 counts non-negative, S08 period within expected range | FAIL | validity |
| S09 bronze to silver rows reconcile, per source | FAIL | completeness |
| S12 metric null rate under threshold, S43 weekly series has no gaps (HDX) | WARN | completeness |
| S30 lineage columns not null, S31 every lineage reference has one build input, S32 table written by one succeeded build | FAIL | auditability |
| S33 silver built from the current bronze loads | FAIL | timeliness |
| S10 metric totals preserved (silver sums equal bronze sums), S34 control values match (dengue cases by year, all-cause deaths 2020 to 2024, TB notifications) | FAIL | accuracy |
| S35 modelled value within its bounds (IHME), S36 value, status and definitions consistent, S37 disease and area keys resolve | FAIL | validity |
| S40 months sum to the published year total, S41 country equals regions plus foreign, S42 national totals agree between PSA tables, S44 dengue sources agree on a common basis (DOH FOI vs UP NOAH, 2022 to 2024) | WARN | consistency |
| S45 quarantined rows are the reviewed kind only (F9) | FAIL | validity |
| S38 aggregation set sums to all causes, S46 age groups sum to the metric total | FAIL | accuracy |
| S47 hospital encounter review flags (counts only) | WARN | validity |
| S39 aggregation set members do not overlap, S48 coverage table matches the metric table | FAIL | consistency |
| S49 mapped area codes exist in geography silver at the stated level | FAIL | validity |
| S50 FHSIS TB printed codes agree with geography silver | WARN | consistency |

The TB programme and claims tables reuse these codes (the diseases range S30 to S50 is full; no new code):

| Table | Checks |
|---|---|
| `tb_programme` | S01-S03, S30-S33, S09 per bronze table, S06, S08, S36, S37, S50 (Special Geographic Area accepted without a level), S34 Philippines 2025 controls (TPT 120,108; eligible 1,498,711.2; DS-TB cohort 414,185 and success 382,547; MDR cohort 7,721 and success 5,030), S45 (only `psgc_not_in_geography`), S12 no-report share per indicator (WARN above 10%) |
| `hospital_claims` | S01-S03, S30-S33, S09 (merged rows not referenced are allowed for), S06, S08, S36, S37, S49, S10 count and amount (silver + quarantined = bronze), S34 the 10 yearly control totals from the YAML, S45 (only `illness_missing`), S12 share of claims with no `facility_key` (WARN above 10%). No profile |

S09 and S33 are now scoped per bronze table: `05` reads two bronze tables with the same source key.

`00` also runs its own reference checks (duplicate keys, keys missing from the directory, empty table) and stops on any failure.

### Known WARN results (expected, no action)

| Check | Count | Why |
|---|---|---|
| S43 weekly series has no gaps | 126 of 126 HDX areas | F14: one source-wide gap at the 2019 / 2020 boundary |
| S44 dengue sources agree on a common basis | 3 of 48 region-years | DOH FOI and UP NOAH differ by more than 10% in three region-years, 2022 to 2024 (D11) |
| S47 hospital encounter review flags | 64, 66, 45, 135, 1 | Review counts carried from the source (dates not usable, long stays, death fields, patient place unresolved, age missing) |

## Results so far

**2026-10-09, local Spark 4.0, landing files, Parquet in place of Delta**

- All four builds ran with all gates at 0: 131,887 (metric), 90,480 (deaths by age), 25,924 (hospital encounters), 73 (coverage) rows. They equal the earlier Python build row for row.
- Failure path: with one area removed from the map, the build stopped at the gate, logged `failed`, wrote no `build_inputs` rows and left the published table unchanged.
- `diseases_silver_qc.py`: 83 results, 76 PASS, 7 WARN, 0 FAIL. The WARN results were S43 (126 of 126 HDX areas), S44 (3 of 48 region-years) and five S47 review counts.

**2026-10-11, Databricks**

- `build_diseases_reference_maps.py` ran with `--overwrite true`. It wrote 499 area-map rows, 421 cause-map rows, 165 directory rows and 25 aggregation rows. 34 hospital city labels are unresolved, which is expected.
- The script now builds its PSGC lookup from `public_health.silver.geography_silver` (argument `--geography_table`, exactly one PSGC snapshot required, levels Reg, Prov, City, Mun). It no longer uses a hard-coded list. Before writing, it checks that every code in the area map exists in geography at the stated level.
- Isabela City maps to `psgc:0990101000`. The earlier map used the placeholder `0990100000`. The hospital HUC fallback applies only when the label ends in " CITY".
- IHME cause 589 was added as group `chronic_kidney_disease` and is a focus group, for the kidney case study.
- `diseases_silver_01_metric.sql` ran: 131,887 silver rows, matching plan section 3.6. Per source: 6,938 (`doh_fhsis`), 2,052 (`doh_foi_dengue`), 65,402 (`hdx_dengue`), 37,720 (`ihme_gbd`), 678 (`psa_deaths_national_annual`), 7,501 (`psa_deaths_national_monthly`), 4,524 (`psa_deaths_region_annual`), 7,072 (`upnoah`).
- In that run 252 HDX rows and 820 IHME rows are duplicates (F1, F2) and 18 FHSIS TB rows are quarantined (F9).
- `diseases_silver_04_source_coverage.sql` ran after a lint-only revision (sqlfluff formatting, `AS` aliases, table versions moved into `SET VAR` statements). The build succeeded: 73 rows, one build id.
- Results of `02` and `03` on Databricks were not recorded. S49 and S50 were added on 2026-10-11.

**2026-10-14, local Spark 4.0, stand-in geography (PSGC 2026-07-13 file)**

- `05` TB programme: 72,376 rows, gates 0. Philippines totals match the printed national rows. 62 rows quarantined (Sulu: the stand-in has the 2026 code `09066`; the real geography snapshot has `19066`), 12 non_data rows. Warnings: TPT above 100% = 1, rows with no report = 27.
- `06` claims: 243,881 rows from 245,405 bronze rows (1,404 quarantined, 120 merged). 2,303 hospitals. Area pairs: 894, all resolved (862 in province, 17 city in region, 9 Manila district, 2 city outside the listed province, 4 manual; 21 marked REVIEW). Per-year totals equal the YAML controls. Failure test: one pair removed from the area map → build stopped, `failed` logged, table unchanged.
- Facility match against a registry stand-in (NHFR + HFSRB hospitals and infirmaries, not the real registry): 1,786 `name_lgu`, 65 `name_tokens_lgu`, 4 `name_province`, 19 ambiguous, 429 unmatched; 5% of claims at unmatched hospitals.

**2026-10-14, Databricks**

- `05` TB programme: 73,216 rows, gates 0. 2 rows quarantined (`psgc_not_in_geography`), 12 non-data rows dropped. The Sulu rows load with the real geography snapshot.
- `06` claims: 243,881 rows (1,404 quarantined `illness_missing`, 120 merged), gates 0. Per-year totals equal the YAML controls.
- **Facility match against the real registry:** 717,348 of 13,574,611 claims (5.3%) are at hospitals with no `facility_key` (S12, under the 10% WARN line). The count by `facility_match_method` was not captured; read it from the table when needed. `06` records the registry version it used; rerun `06` after any registry rebuild.
- `04` coverage reran three times while the weekly completeness rule was settled (HDX rows were null before; see the table section and F14). Final: 73 rows, S48 0 fail.
- `diseases_silver_qc.py`, all six tables: 143 results, 0 FAIL, 7 WARN (the known S43, S44 and S47 results above). Checks S30 to S50 are not yet in `check_registry` (seeded at the end of the project).
- `diseases_metric_silver` null rate: 17 of 131,887 values; `tb_programme`: 81 of 15,696 `tpt_given`, 9 of 1,744 `tpt_eligible_contacts`, 72 of 13,944 `treatment_cohort`, 216 of 41,832 `treatment_success` are `no_report`.

## Known limits

- **FHSIS TB areas.** The coverage table shows 17 regions in 2024 and 18 in 2025, and the cause is not yet checked. `01` section 4g derives `geo_level` and `parent_area_key` from the PSGC code pattern, not from geography silver, and is marked provisional.
- **The plan (v1.7) is out of date on the area map.** It says PSGC codes come from the FHSIS TB 2025 sheet and that Isabela uses `0990100000`. The script now reads geography silver and uses `0990101000`. The plan also expects about 400, 300 and 170 reference rows and 33 unresolved city labels. The 2026-10-11 run gave 499, 421, 165 and 34.
- **F7 override and checksum.** The plan says the override is bound to the file checksum. In code it is bound to file, sheet, row, label and printed code. `override_content_checksum` is blank in the draft and is to be filled after the first Databricks build. Whether it has been filled: status not recorded.
- **Silver QC timing.** The plan describes QC as candidate validation before the write. In code the SQL gates do that, and `diseases_silver_qc.py` runs after the build on the published tables. The rerun-equality check is not in the script.
- **Bronze is not pinned.** The SQL reads bronze at its current version, not with `VERSION AS OF`. Run silver right after bronze QC. `strict_load_lookup` is strict by default, and the value used for the Databricks runs was not recorded.
- **`sources_diseases.yaml`** still describes the old wide design (`silver_target`, `disease:` blocks, `merge_keys`). It also says the PSA age columns stay in bronze. They now go to `diseases_deaths_age_silver`.
- **Open questions to data providers:** week meaning for HDX and UP NOAH (D4), geographic coverage for IHME and HDX (D5), inpatient status of hospital encounters (D9), aggregation categories (D10), dengue location basis (D11), completeness of the last DOH FOI months of 2025 (D12).
- **Claims: one file only.** `06` stops if bronze holds more than one claims file. The YAML says `load_mode: upsert` on `merge_keys`; how a second FOI release replaces the first is not designed yet.
- **Claims: area by name.** The 21 REVIEW rows in the area map need a person to confirm. `CLAIMS_AREA_MANUAL` names targets, not codes, so a new PSGC snapshot still resolves them; Sawata / San Isidro and Dr. Jose P. Rizal / Rizal accept either name.
- **Claims: facility match is a name match.** `name_tokens_lgu` also links sub-units (TB-DOTS, animal bite centres) to their hospital. Hospitals that closed before the registry snapshot stay unmatched. The registry must be built before `06`; a registry rebuild with new keys needs a `06` rerun.
- **Claims: series flags are fixed rules** (2020-2021, 2024 on, IHD with MI 2025, latest year). Revisit them when a new release arrives.
- **TB programme vs F9.** `05` loads the Special Geographic Area rows when geography has them; `01` still quarantines them (F9). Align both when F9 is closed.
- **CI skips files `01` to `03`.** They are over sqlfluff's 20 KB limit. **18 FHSIS TB special-area rows** stay out of silver until reviewed. The metric table would have 6,974 FHSIS rows once they are mapped.

## Handoff to gold

Gold is data model v2 (`gold_v2/`, schema `public_health.test_gold2`): 5 dimensions, 4 facts.

| Gold table | Reads from silver |
|---|---|
| `fact_disease_metric` | `diseases_metric_silver` and `diseases_deaths_age_silver` (by-age rows UNIONed in with their own `age_group`), with `diseases_source_coverage_silver` for `is_complete_year` (source complete AND the area holds every source period) |
| `dim_disease` | `diseases_directory_silver` (now including the `phic_*` packages) |
| `dim_date` | periods of the silver rows (year, month, week, snapshot) |
| TB case study (coverage, success rates) | `diseases_tb_programme_silver` — not yet read by any gold v2 file; planned as extra `fact_disease_metric` rows (metric_name = indicator) |
| claims by hospital / area / condition group | `diseases_hospital_claims_silver` — not yet read by any gold v2 file (aggregate only; join `dim_facility` on `facility_key` where not null) |
| `source_priority` | seeded from plan section 7 (preferred source per measure, level and grain) |
| `mart_area_burden_indicator`, `mart_tb_case_study`, `mart_kidney_case_study` | through the tables above (the v1 marts still read v1 names and need a rewrite to v2) |

What gold must do and must not redo (gold design is in [gold-model.md](gold-model.md) and `gold_v2/README.md`):

- **Gold computes rates.** Silver holds counts only. Rates use the population domain.
- **Do not re-classify, de-duplicate or re-map.** Duplicates (F1, F2), non-data rows and unresolved areas are already handled. Use `disease_key` and `area_key` as given.
- **Do not combine sources by matching keys.** Pick the preferred row through `source_priority`. Modelled IHME values are never mixed with registered or reported values.
- **Sum over causes only through `diseases_cause_aggregation`.** Do not sum a cause with its descendants, and do not sum prevalence across diseases.
- **Read `diseases_source_coverage_silver` before comparing years.** Compare the same months on both sides. For HDX, annual totals are safe only where `is_complete_year` is true on the fact row (2018 everywhere; 2017 and 2020 for the provinces that hold all weeks). Peaks do not need it.
- **Exclude `ph` and `foreign` from regional sums.** Show `measure_definition` and `location_basis` when different measurements or area meanings share a chart.
- **Hospital encounters are not read by gold.** If they are used later, publish aggregates only, suppress small cells and do not name the hospital.
- **IHME licence:** no row-level export, and the attribution line goes on every chart that uses it.
- **Claims:** never sum claim statuses into "money paid" (use `paid`); do not trend `claims_amount_php` across 2024 or IHD with MI into 2025 without the flags; label 2025 preliminary; 2020-2021 is the COVID period, not less disease. Place is the hospital, not the patient. Publish aggregates only (FOI terms).
- **TB programme:** coverage = `tpt_given / tpt_eligible_contacts` (an estimate); success rate = `treatment_success / treatment_cohort` (both sexes; the cohort has no sex split).
- **Week dates (D4):** until the HDX week convention is confirmed, label peaks by week number, not by date.
