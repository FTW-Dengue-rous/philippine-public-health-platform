# Gold layer (`src/04_gold`)

The gold layer prepares the cleaned silver data for analysis. It builds the gold data model: 5 dimensions and 4 facts. It also builds the seeds, reference tables, views and marts that the LUNASaan? dashboard reads.

Use this guide to rebuild the layer, understand what each row represents, and choose the right data for a query.

| Setting | What you need to know |
|---|---|
| Catalog / schema | `public_health.gold` |
| Model | The combined model agreed on 2026-10-14. The team called it "data model v2" while testing it in `test_gold2`. It is the final model. |
| Inputs | Silver tables and reviewed seeds. Gold never reads bronze. |
| Table build pattern | Write a candidate, check it, then publish it. The build stops if any gate fails. After publishing, it records the build in `quality.build_log` and `quality.build_inputs`. |
| Checks after the build | Run `gold_qc.py` against the published tables. It runs G01–G13. If the script itself crashes, it records G00. See [section 8](#8-quality). |

If you are rebuilding gold, start with section 1. If you are querying it, read the selection rules in section 6 before adding up fact rows. Section 9 lists the decisions that remain open and the limits you need to carry into your analysis.

This README is the **reference** for engineers. The overview pages for reviewers and analysts are in `docs/04-pipeline/gold/`: [overview](../../docs/04-pipeline/gold/README.md), [conceptual model](../../docs/04-pipeline/gold/conceptual-model.md), [logical model and ERD](../../docs/04-pipeline/gold/logical-data-model-and-erd.md), [data dictionary](../../docs/04-pipeline/gold/data-dictionary.md), [usage rules](../../docs/04-pipeline/gold/gold-usage-rules.md), [validation and traceability](../../docs/04-pipeline/gold/analytical-validation-and-traceability.md). When this README and an overview page differ, the code and this README win.

> The testing schema, `public_health.test_gold2`, still holds the same model. Keep it until you copy the queries into the current gold layer and archive the testing schema. Nothing in `public_health.gold` reads it.

---

## 1. Folder layout and run order

The setup job creates the `public_health.gold` schema, with the other schemas and the quality tables. Gold has no setup file of its own: a gold file stops if the schema is missing. Run the setup and the required silver builds first. Then run the gold files in this order:

1. Run the files in `dimension/`.
2. Run the files in `fact/`.
3. Run the files in `mart/`.

Within each folder, run the files in alphabetical order. The number in each file name gives its run order. Use the dependency table below when checking what a file needs.

```
04_gold/
├── dimension/
│   ├── gold_01_dim_geography.sql
│   ├── gold_02_dim_date.sql
│   ├── gold_03_dim_data_source.sql
│   ├── gold_04_dim_facility.sql
│   └── gold_05_dim_disease.sql
├── fact/
│   ├── gold_06_fact_facility_capacity.sql
│   ├── gold_07_fact_disease_metric.sql
│   ├── gold_08_fact_workforce_capacity.sql
│   └── gold_09_fact_area_indicator.sql
└── mart/
    ├── gold_10_source_priority.sql
    ├── gold_11_area_coverage_map.sql
    ├── gold_12_ref_osm_healthsite_point.sql
    ├── gold_13_fact_default_views.sql
    ├── gold_14_mart_locality_service_presence.sql
    ├── gold_15_mart_base_planning_unit.sql
    ├── gold_16_mart_area_service_profile.sql
    ├── gold_17_mart_area_burden_indicator.sql
    ├── gold_18_mart_area_evidence.sql
    ├── gold_19_mart_area_priority.sql
    ├── gold_20_fact_area_access.sql
    ├── gold_21_mart_tb_case_study.sql
    ├── gold_22_mart_kidney_case_study.sql
    ├── gold_23_mart_dengue_peak_capacity.sql
    └── gold_24_mart_evidence_readiness.sql
```

| File | Builds | Object | Previous file name | Must run after |
|---|---|---|---|---|
| 01 | `dim_geography` | table | gold_v2_11 | silver geography, admin boundaries |
| 02 | `dim_date` | table | gold_v2_12 | silver |
| 03 | `dim_data_source` | table | gold_v2_13 | — |
| 04 | `dim_facility` | table | gold_v2_21 | 01 |
| 05 | `dim_disease` | table | gold_v2_31 | silver diseases |
| 06 | `fact_facility_capacity` | table | gold_v2_20 | 01, 02, 03 |
| 07 | `fact_disease_metric` | table | gold_v2_30 | 01, 02, 03, 05 |
| 08 | `fact_workforce_capacity` | table | gold_v2_35 | 01, 02, 03 |
| 09 | `fact_area_indicator` | table | gold_v2_40 | 01, 02, 03 |
| 10 | `source_priority` | seed table | gold_v2_41 | 03 |
| 11 | `huc_province_crosswalk`, `area_coverage_map` | views | gold_v2_42 | 01–09 |
| 12 | `ref_osm_healthsite_point` | table | gold_v2_43 | 01, 03 |
| 13 | `v_facility_capacity_totals`, `v_disease_metric_totals`, `v_workforce_preferred`, `v_area_indicator_latest` | views | gold_v2_44 | 06–10 |
| 14 | `mart_locality_service_presence` | view | gold_v2_51 | 06, 09 |
| 15 | `mart_base_planning_unit` | view | gold_v2_52 | 14 |
| 16 | `mart_area_service_profile` | view | gold_v2_53 | 11, 14, 15 |
| 17 | `mart_area_burden_indicator` | view | gold_v2_54 | 10, 11, 15 |
| 18 | `mart_area_evidence` | view | gold_v2_55 | 16, 17 |
| 19 | `priority_weight_params` (seed table) + `mart_area_priority` (view) | table + view | gold_v2_56 | 16, 17 |
| 20 | `fact_area_access` | view | gold_v2_57 | 12, 14 |
| 21 | `mart_tb_case_study` | view | gold_v2_61 | 14 |
| 22 | `mart_kidney_case_study` | view | gold_v2_62 | 11, 14 |
| 23 | `mart_dengue_peak_capacity` | view | gold_v2_63 | 11, 14 |
| 24 | `mart_evidence_readiness` | view | gold_v2_71 | always last |

After file 24 finishes, run `src/05_quality/gold/gold_qc.py`. Stop the job if a build or a FAIL-level quality check fails.

**In the job** (`resources/ph_public_health_job.yml`, section 9 and 10): one SQL task per file, task key = file name, on the SQL warehouse. The tasks follow what each file reads, not the number, so files that read only silver run in parallel:

```
qc_silver_cross_domain -> {01, 02, 03, 05} -> 04 -> {06, 07, 08, 09} -> {10, 11, 12, 13} -> 14 -> 15
  -> {16, 17} -> {18, 19, 20} ; {21, 22, 23} ; 24 -> qc_gold
```

- The dimensions wait for `qc_silver_cross_domain`, so a silver FAIL anywhere stops gold before it starts.
- `qc_gold` is the last task. The YAML holds an optional `dashboard_refresh` task after it, commented out.
- Runs stay manual for the capstone. The recommendations cover the file-arrival trigger and the change check (R0, R1) (D-59).
- Environment: SQL tasks need only the warehouse (ANSI on). `gold_qc.py` runs on the `default` serverless environment (pyyaml, openpyxl); it needs no extra library.

**When you add or maintain files**

Add new files at the end of the sequence: 25, 26 and so on. Keep the existing file numbers.

File 20 builds `fact_area_access`. Its name starts with `fact_`, but this object is a view in `mart/`. It sits outside the 4 model facts. Keep its name because the dashboard reads it.

---

## 2. The model at a glance

All 4 facts join to geography, reporting period and data source. Disease metrics also join to the disease dimension.

| Fact | Dimensions it joins |
|---|---|
| `fact_facility_capacity` | `dim_geography`, `dim_date`, `dim_data_source` |
| `fact_disease_metric` | `dim_geography`, `dim_date`, `dim_data_source`, `dim_disease` |
| `fact_workforce_capacity` | `dim_geography`, `dim_date`, `dim_data_source` |
| `fact_area_indicator` | `dim_geography`, `dim_date`, `dim_data_source` |

`dim_facility` holds registry details. It joins only to `dim_geography`. Do not join it to a fact.

**Keys and lineage**

Gold generates each key as a BIGINT `xxhash64` of its natural key. The same natural key therefore keeps the same key across rebuilds. `date_key` and `data_source_key` retain the hash values of the earlier `period_key` and `source_key`.

Gold tables carry one lineage column: `_gold_build_id`. Use it to trace a row through `quality.build_log` and `quality.build_inputs`. Views have no `_gold_build_id`. This covers the marts, the crosswalk, the coverage map and the default views. Each view reads the underlying tables every time you query it.

---

## 3. Dimensions

The dimensions describe the areas, periods, sources, facilities and diseases used in gold. In each entry, **grain** tells you what one row represents.

### `dim_geography` (01)

| Property | Details |
|---|---|
| **Grain** | One row per area in the current PSGC snapshot, plus 7 named areas with no PSGC code |
| **Primary key / natural key** | `area_key` / `area_code` (`psgc:<10-digit code>` or a named code) |
| **Reads** | `silver.geography_silver`, `silver.admin_boundaries_silver`, a reviewed list of named areas in the file |

**How the build works**

- **Snapshot:** use one `geography_silver` snapshot: the `content_checksum` of the row processed last. This snapshot supplies the codes, names, levels and hierarchy.
- **Levels:** keep region, province, city, municipality, submunicipality (Manila) and the Special Geographic Area. Exclude barangays.
- **Region:** take the first 2 digits of the PSGC code.
- **Province:** take the first 5 digits only when that code identifies a province row. Leave the province unset for a highly urbanized city (HUC).
- **Planning units:** treat each province without its HUCs, each HUC, and NCR as separate units. Gold applies the rule as proposed (O-01).
- **`broad_unit_key`:** leave it null for HUCs outside NCR. The province of such a HUC comes from `huc_province_crosswalk` (file 11), which runs after this table.
- **Boundaries:** read `area_sqkm`, `center_lat`, `center_lon` and `has_boundary` from the HDX boundaries. Join on the matched `psgc_code` and level. Use the latest source version for each level.
- **Named areas:** add Philippines, foreign country, undivided Maguindanao and the 4 NCR districts. These 7 areas have no PSGC code.
- **`snapshot_date`:** use the quarter end of the PSGC version. For example, Q2_2024 becomes 2024-06-30.

**Main columns:** `area_code`, `psgc_code`, `area_name`, `geographic_level`, `income_class`, `city_class` (HUC/ICC/CC), `parent_area_key`, `region_key`, `province_key`, `planning_unit_key`, `broad_unit_key`, `snapshot_date`, `area_sqkm`, `center_lat`, `center_lon`, `has_boundary`.

### `dim_date` (02)

| Property | Details |
|---|---|
| **Grain** | One row per reporting period under one period convention (year, month, week or snapshot date). Not one row per day |
| **Primary key / natural key** | `date_key` / (`period_basis`, `period_label`) |
| **Reads** | Every silver table that carries a period: diseases metric and deaths by age, population, workforce headcount and denominators, facilities metric, occupancy and registry, poverty, health expenditure |

**How the build works**

- Include every period in `diseases_metric_silver`. Add every year in the yearly silver tables and one snapshot date for the facility registry.
- **Registry snapshot:** use the later of the NHFR and HFSRB as-of dates.
- **Weekly dengue (D-44, D-46):** HDX weeks have `period_basis = iso_week_ending_date`: the date closes its week, which runs from the date minus 6 days to the date. UP NOAH weeks have `period_basis = iso_week` (Monday to Sunday). Both take the ISO week and ISO year, so a few edge weeks belong to the year before (HDX week ending 2021-01-03 is in 2020). Start and end dates come from silver.
- **`period_label`:** keep the silver `period_key` unchanged. It is part of the key, so a mart adds display words such as "week ending <date>" instead of reformatting it.
- **`is_pandemic_period`:** set by two variables at the top of the file: 2020–2022, agreed 2026-10-19 (O-14). PhilHealth claims carry their own COVID flag (2020–2021) in silver.

**Main columns:** `period_basis`, `period_label`, `period_grain`, `year`, `period_start_date`, `period_end_date`, `is_pandemic_period`.

### `dim_data_source` (03)

| Property | Details |
|---|---|
| **Grain** | One row per source dataset, keyed by the `_source_key` value that silver rows carry |
| **Primary key / natural key** | `data_source_key` / `source_dataset` |
| **Reads** | A reviewed list in the file, copied from `config/sources_<domain>.yaml`. When a YAML entry changes, change its row here |

**How to maintain and use it**

- **`value_type`:** classify each source as `registered`, `reported`, `modelled`, `census` or `survey_estimate`. The marts use this field to keep modelled and reported values separate.
- **`sharing`:** use `open` for data you may export. Use `restricted` for aggregates only, with cells under 3 suppressed. "Restricted" is our own request commitment (D-47): academic use and aggregates only. The release letters set no terms. The restricted rule applies to FOI releases such as PhilHealth claims and DOH hospital beds.
- **`source_domain` and `used_in`:** use these fields to see what each source covers and which gold tables read it.

### `dim_facility` (04)

| Property | Details |
|---|---|
| **Grain** | One row per facility establishment in `facilities_registry_silver` (listed, or carried as not_listed) |
| **Primary key / natural key** | `facility_key` / `facility_source_id` (the registry's facility key) |
| **Reads** | `silver.facilities_registry_silver`, `dim_geography` |

**How the build works**

- Keep one gold row per registry row. Reuse the matching, area resolution and keys from silver.
- **`facility_category`:** hospital, infirmary, primary_care or dialysis_clinic.
- **`ownership`:** government or private.
- **`hospital_level`:** read Level 1–3 from `service_level`. Set it to `unknown` for a hospital with no level. Leave it null for other facility categories.
- **`facility_status`:** count only facilities marked `listed`. Keep the `not_listed` rows as registry detail.
- **Beds:** retain `authorized_beds`, `analysis_beds` and `analysis_beds_basis`.
- **`dialysis_stations`:** keep null when the source does not report a value.
- **`is_license_valid_on_as_of`:** use this flag when counting licensed primary care facilities.

**Join rule:** join `dim_facility` to `dim_geography` on `area_key` only. Do not join it to `fact_facility_capacity`. That fact already holds area totals. Joining facility rows to it would repeat those totals once per facility.

### `dim_disease` (05)

| Property | Details |
|---|---|
| **Grain** | One row per disease, cause or case-rate package |
| **Primary key / natural key** | `disease_key` / `disease_code` |
| **Reads** | `silver.diseases_directory_silver`, `silver.diseases_cause_aggregation` |

**How the build works**

- **`classification`:** keep the following four lists separate. Never sum across them:
  - `psa_tabulation_list`: PSA causes of death.
  - `ihme_gbd`: IHME causes.
  - `programme`: TB programme diseases.
  - `phic_case_rate_package`: the 14 PhilHealth packages.
- **`disease_group`:** use the reviewed group to link the same condition across lists. Examples include tuberculosis, dengue, stroke and chronic_kidney_disease.
- **`cause_group`:** read communicable, noncommunicable or injury from `diseases_cause_aggregation`. Assign each PSA cause the category of its chapter.
- **`cause_level` and `parent_disease_key`:** use these fields to identify the cause hierarchy. Never add a cause to its children.
- **`is_focus_disease`:** marks the diseases used in the burden mart and the case studies.

---

## 4. Facts

Each fact deliberately keeps overlapping rows from different sources, geographic levels and breakdowns. **Apply the selection contract in section 6 before calculating a total.** Start with the default views in file 13, then select the series and filters your query needs.

### `fact_facility_capacity` (06)

| Property | Details |
|---|---|
| **Grain** | One capacity measurement of one facility group (category × ownership × hospital level) in one area and period, from one source and capacity basis |
| **Grain columns** | `area_key`, `date_key`, `data_source_key`, `capacity_basis`, `facility_category`, `ownership`, `hospital_level` |
| **Primary key** | `fact_facility_capacity_key` |
| **Reads** | `silver.facilities_registry_silver`, `silver.facilities_metric_silver`, `silver.facilities_bed_occupancy_silver`, `dim_geography`, `dim_date`, `dim_data_source` |

**How the build works**

The build combines three row types. Use `capacity_basis` to tell them apart:

| `capacity_basis` | From | What a row is | Measures |
|---|---|---|---|
| `registry_snapshot` | facilities registry | Count listed facilities per city or municipality at the latest registry snapshot. Include Manila submunicipalities in the City of Manila | `facility_count`, `authorized_beds`, `analysis_beds`, `dialysis_stations`, `facilities_license_valid`, `facilities_without_beds` |
| `published_statistic` | PSA and FHSIS published tables | Keep published counts by area and year: hospitals, BHS, RHU, MHC, CHC and health centre total. Retain separate `total`, government and private rows | `facility_count`, `authorized_beds` (hospitals only) |
| `occupancy_report` | DOH/HFSRB FOI hospital beds (restricted) | Aggregate bed occupancy from reporting hospitals. Do not match records to facilities. Publish 3 geographic levels (silver level, `province_excl_huc`, `region`) × 3 breakdowns (ownership × level, ownership, total) | `bor_weighted_pct` (bed-weighted), `bor_median_pct`, `bor_reporting_record_count`, `bor_eligible_record_count`, `bor_weighted_beds_sum` |

**Rules**

- Fill only the measure columns that belong to the row's capacity basis. Leave the other measures null. A build gate checks this rule.
- **Occupancy suppression:** set `value_status = 'suppressed'` when a cell contains fewer than 3 hospital records. Leave its measures null.
- **Occupancy rollups:** calculate `sum(bor_weighted_pct × bor_weighted_beds_sum) / sum(bor_weighted_beds_sum)`. Do not take a simple average of occupancy rates.
- **Areas with no facility:** the registry basis has no row for a locality with no facility. The marts start from `dim_geography` and left join this fact to identify areas with "no hospital recorded".

### `fact_disease_metric` (07)

| Property | Details |
|---|---|
| **Grain** | One metric of one disease, area, period, age group and sex, from one source |
| **Grain columns** | `disease_key`, `area_key`, `date_key`, `data_source_key`, `age_group`, `sex`, `metric_name`, `metric_basis` |
| **Primary key** | `fact_disease_metric_key` |
| **Reads** | `silver.diseases_metric_silver`, `silver.diseases_source_coverage_silver`, `silver.diseases_deaths_age_silver`, `silver.diseases_tb_programme_silver`, `silver.diseases_hospital_claims_silver`, `dim_disease`, `dim_geography`, `dim_date`, `dim_data_source` |

**How the build works**

The build combines four row sources:

| Row source | From | How |
|---|---|---|
| metric | `diseases_metric_silver` | Keep one gold row per silver row for cases, deaths or prevalence. Retain the bounds for modelled IHME values. Set `age_group = all_ages` and `sex = both_sexes`. Set `is_complete_year` to true when the source holds every period of the year AND the area holds every period available in that source. Otherwise set it to false |
| deaths by age | `diseases_deaths_age_silver` | Keep one gold row per silver row and retain its age group. Set `metric_name = deaths` and `metric_definition = registered_deaths`. The source has 20 age groups per cause, area and year |
| TB programme | `diseases_tb_programme_silver` (FHSIS 2025) | Keep one gold row per silver row for `tpt_given`, `tpt_eligible_contacts`, `treatment_cohort` or `treatment_success`. Keep `sex` in the grain because the source splits values by sex. Use `disease_key` to distinguish `tb_all_forms` and `tb_drug_resistant` |
| PhilHealth claims | `diseases_hospital_claims_silver` (FOI, restricted) | **Aggregate** per area × year × package into 4 metrics: `claims_filed`, `claims_paid`, `claims_amount_claimed_php`, `claims_paid_amount_claimed_php`. Drop hospital identity. Publish at 3 levels: `facility_location`, `facility_location_province_excl_huc`, `facility_location_region`. Suppress cells built from fewer than 3 hospitals |

**Rules**

- Set `metric_basis = number`. Silver supplies the counts. The marts calculate rates.
- Fill `value` only when `value_status = 'ok'`. Never treat a null as 0.
- **Claims geography:** interpret the area as the place that delivered care. It does not identify the patient's residence.
- **Claims series notes:** gold carries only one of these as a column: `is_preliminary`, on the latest year. Apply the others in the marts and on chart labels:
  - 2020–2021 is the COVID period.
  - Do not compare amounts across the 2024 case-rate change.
  - IHD with MI changed definition in 2025.

  Silver keeps all four as flags in `diseases_hospital_claims_silver`.

### `fact_workforce_capacity` (08)

| Property | Details |
|---|---|
| **Grain** | Headcount of one profession in one area and year, from one source |
| **Grain columns** | `area_key`, `date_key`, `profession_code`, `data_source_key` |
| **Primary key** | `fact_workforce_capacity_key` |
| **Reads** | `silver.workforce_headcount_silver`, a reviewed profession list in the file, `dim_geography`, `dim_date`, `dim_data_source` |

**How the build works**

- **Rows:** keep one gold row per silver row. Retain rows that are not `analysis_eligible` and carry their `exclusion_reason`.
- **Professions:** store the profession name and group on the fact. The model has no profession dimension.
  - `core_clinical`: doctors, nurses, midwives.
  - `community`: barangay health workers.
  - `other`: the remaining professions.
- **Headcounts:** fill `headcount_total`, `headcount_lgu_hired` and `headcount_doh_hired` only when each field's own silver status is ok. Convert values covered by the 2018 "0 = No Data" legend to null.
- **`source_role`:**
  - FHSIS 2018–2025 and PSA 2012–2017 are `preferred`.
  - PSA 2018–2023 is `cross_check`. Use it to compare against FHSIS. Do not display it as the selected value.
- **Series break:** use `is_break_year` to identify the 2019 change in the nurse series definition.

### `fact_area_indicator` (09)

| Property | Details |
|---|---|
| **Grain** | One population or socioeconomic indicator of one area and period, from one source |
| **Grain columns** | `area_key`, `date_key`, `data_source_key`, `indicator_name`, `indicator_category` |
| **Primary key** | `fact_area_indicator_key` |
| **Reads** | `silver.population_silver`, `silver.workforce_area_denominator_silver`, `silver.socioeconomic_poverty_silver`, `silver.socioeconomic_health_expenditure_share_silver`, `silver.socioeconomic_health_expenditure_per_capita_silver`, `dim_geography`, `dim_date`, `dim_data_source` |

**How the build works**

Store one indicator per row in a long table. The datasets cover different years: census covers 2015, 2020 and 2024; poverty covers 2021, 2023 and 2025; expenditure covers 2016–2023. A wide table would leave most columns empty.

| `indicator_name` | `indicator_category` | From | Notes |
|---|---|---|---|
| `population` | `census` | `population_silver` (latest snapshot, areas in `dim_geography`) | Map `VALID` and `VALID_WITH_NOTE` to ok. Set province coverage to `province_excl_huc` in the years of the setting `census_province_excl_huc_years` (2024) and `province_coverage_unconfirmed` for 2015 and 2020 |
| `population` | `reported` | `workforce_area_denominator_silver` | Use the population printed in the FHSIS tables. Set `label_under_review` and leave the value null when an area has a proposed or rejected label override |
| `poverty_incidence_pct`, `poor_population` | `all` | `socioeconomic_poverty_silver` | Create two rows per area and year. Keep `comparison_eligible` and `exclusion_reason` on both rows |
| `health_expenditure_share_pct` | financing agent | expenditure share silver | National (area `ph`). Only `category_level = 1` adds up to 100 |
| `health_expenditure_per_capita_php`, `_growth_pct` | `all` | expenditure per capita silver | National, one row per year |

**Rules**

- Never sum across `indicator_name`, `indicator_category` or `data_source_key`.
- Keep the published census values. Gold never interpolates between census years. The marts apply a 2-year alignment window.

---

## 5. Seeds, crosswalk, reference layer and default views (10–13)

These objects support source selection, geographic alignment and dashboard queries. The default views in file 13 provide a starting point for the selection rules in section 6.

### `source_priority` (seed table) (10)

Use this seed to choose the source gold displays for each metric. It contains 34 rules. The rules remain a proposal for team review (D3).

The `role` field controls how to use a source:

| Role | How to use the source |
|---|---|
| `preferred` | Display this source. |
| `cross_check` | Compare it with the selected source. Do not display it as the selected value. |
| `fallback` | Use it only when the preferred source has no row. |

| Property | Details |
|---|---|
| **Grain / key** | One source rule per (`metric`, `disease_scope`, `geo_level`, `period_grain`, `year_from`, `year_to`, `data_source_key`) |
| **Reads** | reviewed list in the file; checks against `dim_data_source` |

### `huc_province_crosswalk` (view) (11)

Use this view to place the 17 HUCs outside NCR in their provinces. It matches a reviewed name list to `dim_geography`.

| Property | Details |
|---|---|
| **Grain / key** | One HUC outside NCR, with its province. Key `huc_area_key` |
| **Reads** | `dim_geography` |

### `area_coverage_map` (view) (11)

Use this view to map published geographic coverage to planning units. Sources may include or exclude HUCs in their province totals. This map handles those differences for FHSIS, poverty, IHME and HDX rows. IHME province estimates include their HUCs (D-42). HDX province rows exclude the cities the source lists apart (D-43).

| Mapping outcome | What it means |
|---|---|
| `direct` | The published area is a planning unit. |
| `aggregate` | The published area is one part of a planning unit. |
| `not_separable` | The row covers more or less than a planning unit. Nobody can split it. Leave it out of the comparison. |
| `not_used` | A province or region row the same source publishes already counts this area. Use that row instead. |
| `out_of_scope` | The level is not a planning-unit level (country, region, district, historical area). |

| Property | Details |
|---|---|
| **Grain / key** | One area published by one source in one year in one fact. Key (`fact_table`, `data_source_key`, `geo_coverage_basis`, `area_key`, `date_key`) |
| **Reads** | `dim_geography`, `dim_date`, `dim_data_source`, `huc_province_crosswalk`, `fact_workforce_capacity`, `fact_area_indicator`, `fact_facility_capacity` (published), `fact_disease_metric` (IHME, HDX dengue) |

### `ref_osm_healthsite_point` (table) (12)

Use these OpenStreetMap points as a map layer and to calculate distance to the nearest OSM hospital. This reference table sits outside the model. Never use it as a facility count.

Show "© OpenStreetMap contributors" when displaying the data. The licence is ODbL 1.0.

| Property | Details |
|---|---|
| **Grain / key** | One OpenStreetMap health facility point. Key `osm_point_key` |
| **Reads** | `silver.facilities_osm_point_silver`, `dim_geography` |

### `v_facility_capacity_totals` (view) (13)

Start here for facility-capacity totals. The view sums registry rows across ownership and hospital level. For published statistics and occupancy, it uses the `total` rows.

| Property | Details |
|---|---|
| **Grain / key** | One area × date × source × basis × category, ownership `total`, all levels |
| **Reads** | `fact_facility_capacity` |

### `v_disease_metric_totals` (view) (13)

Start here for all-age, both-sex disease totals. Use `is_preferred_source` to select one source series.

| Property | Details |
|---|---|
| **Grain / key** | One `fact_disease_metric` row, all ages, both sexes, with `is_preferred_source` |
| **Reads** | `fact_disease_metric`, `dim_disease`, `dim_data_source`, `dim_date`, `dim_geography`, `source_priority` |

### `v_workforce_preferred` (view) (13)

Start here for workforce totals. The view keeps preferred rows that are eligible for analysis.

| Property | Details |
|---|---|
| **Grain / key** | One preferred, analysis-eligible workforce row |
| **Reads** | `fact_workforce_capacity`, `dim_date`, `dim_data_source` |

### `v_area_indicator_latest` (view) (13)

Use this view to find the latest census population, poverty and expenditure values for each area. It keeps ok indicator rows and marks the latest period with `is_latest_period`.

| Property | Details |
|---|---|
| **Grain / key** | One ok indicator row, with `is_latest_period` |
| **Reads** | `fact_area_indicator`, `dim_date`, `dim_data_source` |

---

## 6. Selection contract: how to calculate valid totals

A selection contract tells you which rows belong in a total. Follow it even when two rows appear to describe the same area and year. They may use different sources, coverage or breakdowns.

| Fact | A total is valid only with | Default view |
|---|---|---|
| `fact_facility_capacity` | `capacity_basis` + `coverage_basis` + `ownership` + `hospital_level` + `value_status = 'ok'`. Registry rows: sum over ownership and level. Published rows: `ownership = 'total'`. Occupancy rows: `ownership = 'total' AND hospital_level = 'all'` | `v_facility_capacity_totals` |
| `fact_disease_metric` | one source (preferred in `source_priority`) + `metric_name` + `age_group = 'all_ages'` + `sex = 'both_sexes'` + one `coverage_basis` | `v_disease_metric_totals` |
| `fact_workforce_capacity` | `source_role = 'preferred'` + `profession_code` + `analysis_eligible` | `v_workforce_preferred` |
| `fact_area_indicator` | `indicator_name` + `indicator_category` + `value_status = 'ok'` + one period | `v_area_indicator_latest` |

**Choose and label the denominator**

| Rate | Population denominator |
|---|---|
| Cross-domain rates: beds, workforce, poverty and burden | Use the planning unit's **census** population. |
| FHSIS facility rates: BHS and health centres per 10k | Use the population **printed in the same FHSIS workbook**. |

Label the denominator in the output. Never compare an FHSIS-workbook-based rate with a census-based rate.

---

## 7. Marts (14–24)

The marts turn model data into outputs for specific questions. All marts are views. They read the model tables each time you query them and have no `_gold_build_id`. File 19 also builds the `priority_weight_params` seed table.

### `mart_locality_service_presence` (14)

Use this view for **A1–A4**. It identifies cities and municipalities with no hospital or licensed primary care facility **recorded**. It also shows the highest hospital level and population per hospital, bed and primary care facility.

| Property | Details |
|---|---|
| **Grain / key** | One row per city or municipality (with or without a facility). Key `area_key` |
| **Reads** | `dim_geography`, `dim_date`, `fact_area_indicator` (census population), `fact_facility_capacity` (registry snapshot) |

### `mart_base_planning_unit` (15)

Use this helper as the common list of planning units. It gives each unit one census denominator, so marts 16–19 compare the same units.

| Property | Details |
|---|---|
| **Grain / key** | One row per planning unit (province excl. HUCs, HUC, NCR, `other` = Isabela City and SGA municipalities). Key `planning_unit_key` |
| **Reads** | `dim_geography`, `dim_data_source`, `mart_locality_service_presence` |

### `mart_area_service_profile` (16)

Use this view for **S1, S3, A2, W1, W2, E1 and E2**. It brings supply, workforce and poverty together for each planning unit.

It includes beds, BHS and health centres, plus doctors, nurses, midwives and BHW per 10k. It also includes poverty incidence, poverty bands and quintiles.

| Property | Details |
|---|---|
| **Grain / key** | One row per planning unit. Key `planning_unit_key` |
| **Reads** | `mart_base_planning_unit`, `mart_locality_service_presence`, `area_coverage_map`, `dim_geography`, `dim_date`, `fact_facility_capacity`, `fact_workforce_capacity`, `fact_area_indicator` |

### `mart_area_burden_indicator` (17)

Use this view for **N2 and N4**. It shows FHSIS TB notifications and IHME modelled deaths and prevalence as rates per 100k, with quintiles.

Every planning unit gets a row for every burden indicator. When a value is missing, the row explains why.

| Property | Details |
|---|---|
| **Grain / key** | One row per planning unit × burden indicator (disease, measure, source) in the source's latest year. Key (`planning_unit_key`, `burden_indicator_key`) |
| **Reads** | `mart_base_planning_unit`, `area_coverage_map`, `source_priority`, `dim_disease`, `dim_geography`, `dim_date`, `dim_data_source`, `fact_disease_metric` |

### `mart_area_evidence` (18)

Use this supporting view to explain which units enter a comparison and which do not. It supports labels such as "N units compared, M excluded and why."

The view reshapes marts 16 and 17 into one long list. It calculates no new measures.

| Property | Details |
|---|---|
| **Grain / key** | One row per planning unit × indicator. Key (`planning_unit_key`, `indicator_key`) |
| **Reads** | `mart_area_service_profile`, `mart_area_burden_indicator`, `mart_base_planning_unit`, `dim_data_source` |

### `priority_weight_params` + `mart_area_priority` (19)

Use these objects for **P1 and P2**. They identify areas that combine high disease burden with hospital, primary care, workforce and socioeconomic gaps. They also show how rankings change when you change weights or eligibility rules.

The team agreed the fifths, the "two of three" rule and the 3 weight sets, with a reason for each (D-56). Read `weight_set = equal` with `eligibility_config = complete_only` by default. The other weight sets are sensitivity tests.

| Property | Details |
|---|---|
| **Grain / key** | Seed: one weight per (`weight_set`, `indicator`). Mart: one row per planning unit × burden indicator × weight set × eligibility rule. Key (`planning_unit_key`, `burden_indicator_key`, `weight_set`, `eligibility_config`) |
| **Reads** | `mart_area_service_profile`, `mart_area_burden_indicator` |

### `fact_area_access` (20)

Use this view for the **"how far" part of A1 and A2**. It calculates straight-line distance from each locality to:

- The nearest locality with a hospital **recorded**: `nearest_hospital_locality_km`.
- The nearest locality with a Level 3 hospital recorded.
- The nearest OSM hospital point: `nearest_osm_hospital_point_km`. This point is unverified.

These are straight-line distances. Do not interpret them as travel distances.

| Property | Details |
|---|---|
| **Grain / key** | One row per city or municipality. Key `area_key` |
| **Reads** | `mart_locality_service_presence`, `dim_geography`, `ref_osm_healthsite_point` |

### `mart_tb_case_study` (21)

Use this view for the TB case study:

- **T1, prevention:** compare TB notification rates with health worker availability and the presence of a recorded primary care facility or hospital.
- **T2:** examine TB preventive treatment coverage and DS-TB / MDR-TB treatment success using FHSIS 2025.

| Property | Details |
|---|---|
| **Grain / key** | One row per city or municipality. Key `area_key` |
| **Reads** | `mart_locality_service_presence`, `dim_disease`, `dim_date`, `dim_data_source`, `fact_disease_metric`, `fact_workforce_capacity` |

### `mart_kidney_case_study` (22)

Use this view for **K1, specialist treatment capacity**. It identifies provinces with high modelled chronic kidney disease mortality and few recorded dialysis stations per population.

| Property | Details |
|---|---|
| **Grain / key** | One row per province (or NCR) as IHME publishes it. Key (`kidney_unit_key`, `unit_basis`); `unit_basis` = `planning` or `broad` (province plus its HUCs, D-42). Broad units can be comparable since 2026-10-18 |
| **Reads** | `mart_locality_service_presence`, `huc_province_crosswalk`, `dim_disease`, `dim_geography`, `dim_date`, `dim_data_source`, `fact_disease_metric`, `fact_facility_capacity` |

### `mart_dengue_peak_capacity` (23)

Use this view to ask: **where were historical dengue peaks largest relative to current recorded hospital capacity?** It also supports **N3**: when and where dengue peaks occur, how concentrated they are, and which areas repeatedly show high burden.

Keep weekly peaks (HDX and UP NOAH) and monthly peaks (DOH FOI) in separate rankings.

Use UP NOAH or DOH FOI for the timing of regional peaks. From 2018, HDX peak weeks run 1–2 weeks behind the DOH counts (D-45). HDX peaks read "week ending <date>".

This view does not estimate which areas would exceed capacity. That requires the full dengue capacity replay in stretch-2.

| Property | Details |
|---|---|
| **Grain / key** | One row per area × dengue source × year. Key (`area_key`, `data_source_key`, `year`) |
| **Reads** | `fact_disease_metric`, `fact_facility_capacity`, `fact_area_indicator`, `area_coverage_map`, `mart_locality_service_presence`, `dim_geography`, `dim_date`, `dim_data_source`, `dim_disease` |

### `mart_evidence_readiness` (24)

Use this view for the **pipeline status page**. It shows whether each silver and gold table has a build, a QC run and the latest inputs. It includes `schema_name`, which separates `public_health.gold` from the old test schemas.

| Property | Details |
|---|---|
| **Grain / key** | One row per silver or gold table in its latest succeeded build. Key `table_name` |
| **Reads** | `quality.v_latest_build`, `quality.build_inputs`, `quality.v_table_health` |

### Rules to carry into every mart query

| Rule | How to interpret or use the data |
|---|---|
| **"Recorded" is literal** | `has_hospital_recorded = false` means the registry lists no hospital in that area. It does not prove that no hospital exists. |
| **Missing values** | Keep null values as null. Read `exclusion_reason`, `mapping_outcome` or `value_status` to understand why a value is missing. |
| **2-year alignment window** | Leave a rate null when the count year and population year differ by more than 2 years. |
| **Quintiles** | Rank only units with a value. Quintile 1 is lowest; 5 is highest. Give equal values the same quintile. |
| **IHME attribution** | Show the IHME attribution line with modelled IHME values. |
| **OSM attribution** | Show "© OpenStreetMap contributors". |
| **Restricted FOI data** | Publish aggregates only and suppress cells under 3 (D-47). |

---

## 8. Quality

### Before publishing: checks inside each table file

Each table file follows the write-audit-publish pattern:

1. Write a candidate table.
2. Run the build gates against the candidate and its inputs.
3. Publish only when every gate returns 0.

The gates check for null or duplicate keys, duplicate grain combinations, and foreign keys that do not resolve. They also compare control totals with silver, check that measures use the correct basis, and check whether any silver input has a FAIL in its latest QC.

If any gate returns a value other than 0, the file logs a failed build and stops. It leaves the published table untouched.

### Type casts: `CAST` in gold, `try_cast` in silver

Gold uses `CAST`, not `try_cast`. This is deliberate.

| | `CAST` | `try_cast` |
|---|---|---|
| A value it cannot convert | Stops the query (ANSI mode) | Becomes NULL, with no error |
| Use it when | The input is already typed and valid, so a failure means a bug | The input is raw text that may be dirty |
| Layer | Gold | Silver |

- **Silver parses.** Bronze stores every column as text. Silver cleans each value, converts it with `try_cast`, and records a status per value (`ok`, `missing`, `invalid` …). A value that fails to parse stays visible as a status. It never disappears.
- **Gold only aligns types.** The casts in gold convert values that silver already typed. They do four things:
  - give `UNION ALL` branches the same column types (`CAST(NULL AS BIGINT)`)
  - widen measures to one type (`CAST(value AS DECIMAL(20, 4))`)
  - set key and year types (`CAST(year AS INT)`)
  - turn gate results into 0 or 1 (`CAST(count(*) = 0 AS INT)`)
- **Why not `try_cast` in gold.** Null means "missing" in this pipeline. With `try_cast`, an unexpected value would turn into a missing value without warning. It would drop out of totals and rates. `CAST` stops the build instead. `build_log` records a failed build, and the published table stays as it was.
- **The one exception.** `dim_geography` reads the year and quarter out of the PSGC `source_version` text. That is parsing, so it uses `try_cast`.
- **Requirement.** Run Spark with `spark.sql.ansi.enabled = true`. With ANSI mode off, `CAST` also returns NULL silently, and this protection is lost.

A failed cast in gold is a bug in the pipeline, not a data issue. Fix the silver step that produced the value.

### After publishing: `gold_qc.py`

Run `gold_qc.py`. It checks the published objects and writes its results through the shared `DQRun` helper (`dq_utils.py`) with layer `gold`:

| Code | Check | Severity |
|---|---|---|
| G00 | Confirm that QC ran without error | FAIL |
| G01 | Confirm that the table has rows | FAIL |
| G02 | Check that the primary key is complete and unique | FAIL |
| G03 | Check that the grain is unique | FAIL |
| G04 | Check that each foreign key resolves | FAIL |
| G05 | Match the published table to its latest succeeded build. Check row counts and confirm that no data write occurred after the recorded build version | FAIL |
| G06 | Check that the table uses the latest build of every input. This detects stale inputs and incorrect run order | FAIL |
| G07 | Match gold control totals to silver | FAIL |
| G08 | Check that values, statuses and bases agree | FAIL |
| G09 | Check that views, marts and seeds are readable and contain rows | FAIL |
| G10 | Check that each disease series has one preferred source | FAIL |
| G11 | Check that measure values fall within valid ranges | FAIL |
| G12 | Check that the content fingerprint is unchanged from the previous QC run (idempotency) | WARN |
| G13 | Check that population changes between censuses are plausible | WARN |

Read the results in `public_health.quality.qc_results`. Any FAIL stops the job.

### Settings recorded with every build

Each table file declares its settings in step [0] and writes them to `build_log.parameters`. No query types a number that the logic depends on (rule 2a, D-62). Reviewed lists are views that gold counts into `build_inputs.input_rows`. Thresholds are named settings.

| Setting | File | Value | Use |
|---|---|---|---|
| `strict_input_builds` | all tables | false | true: a silver input needs a succeeded build row (notebook-built silver tables have none) |
| `block_on_silver_qc_fail` | all tables | true | A silver input whose latest QC has a FAIL stops the build |
| `code_version`, `job_run_id` | all tables | null | Git commit and job run, when passed |
| `planning_unit_rule` | 01 | `O-01` | Label of the planning-unit rule |
| `pandemic_year_from`, `pandemic_year_to` | 02 | 2020, 2022 | `is_pandemic_period` (O-14) |
| `suppression_min_records` | 06 | 3 | Gold suppresses occupancy groups under it (D-47) |
| `suppression_min_hospitals` | 07 | 3 | Gold suppresses claims cells under it (D-47) |
| `census_province_excl_huc_years` | 09 | `array(2024)` | Census years whose province rows exclude HUCs |
| `share_level1_tolerance_pct` | 09 | 0.2 | Level-1 expenditure shares sum to 100 within it (same as silver) |
| `ihme_includes_huc_confirmed` | 22 | true | D-42; broad units pass gate 3 |

### When a build or check fails

| What failed | Where to look | Do |
|---|---|---|
| A gate in a table file | `quality.build_log` (`status = 'failed'`, `error_message` names the gate); the kept `<table>__gates` and `__candidate` | Fix the cause, rerun the file, then every file after it that reads it |
| "silver input whose latest QC has a FAIL" | `quality.v_open_issues` for that silver table | Fix silver and rerun its QC first |
| "data_source_key not in dim_data_source" | The new `_source_key` | Add the source to `gold_03` (and the YAML) |
| "period_basis outside the known conventions" | The new silver basis | Add it to the `gold_02` gate on purpose |
| A `raise_error` in a seed or view file | The message names the row | Fix the list; rerun |
| `gold_qc.py` FAIL | `quality.qc_results` (`layer = 'gold'`) | G05/G06: rerun the file and its dependants. G07: compare with silver. G09: rerun the view's file |
| G12 WARN | `detail` lists the input versions | Expected once after an input or rule change; on unchanged inputs it is a bug |
| A leftover `__inputs` / `__candidate` / `__gates` after success | The run stopped between [5] and [7] | Drop it |

A failed build never touches the published table, so the dashboard keeps showing the last good build while you fix it.

### Trace a build and its inputs

Each build writes one row to `quality.build_log`. The row records its build id, start and finish times, status, row count, Delta version and `parameters`.

The build also writes one row to `quality.build_inputs` for each table it reads. Each row records the input's version. `mart_evidence_readiness` and G06 use these records to identify stale tables.

---

## 9. Open decisions and known limits

Carry these qualifications into dashboard labels, comparisons and future changes.

| Decision or limit | Current treatment |
|---|---|
| **O-01: planning units** | Built as proposed: each province without its HUCs, each HUC, and NCR. Open only on the Sulu population (D-41). |
| **D3: source selection** | The `source_priority` rows remain a proposal for team review. |
| **D-44 / D-46: week convention** | Closed. Each HDX date closes its week (ISO week and ISO year of the date). UP NOAH weeks are ISO weeks, not approximated. Applied in silver (2026-10-19) and `dim_date` (2026-10-20). |
| **D-45: HDX lag** | From 2018, HDX counts run 1–2 weeks behind and below the DOH FOI counts. Use UP NOAH or DOH FOI for regional peak timing. |
| **D-42 / D-43: HUC coverage in IHME and HDX** | Closed. IHME province estimates include their HUCs: a province with a HUC is `not_separable` for planning units, and the kidney study compares it at the broad unit. HDX province rows exclude the cities the source lists apart. The silver basis names still end in `_unconfirmed`; renaming them is a silver reference change. |
| **Sulu population** | The source has no 2024 census count for Sulu. Keep its planning-unit population and rates null. Do not fall back to the 2020 count. See runbook incident 6. |
| **Mart values (D-56)** | Poverty bands (10/20/30%, display only), gap fifths, the "two of three" workforce rule, the 3 weight sets and 80% dialysis station completeness. Agreed with a reason per value; evidence queries in `gold_o13_evidence.sql`. Label fifths "lowest 20% of planning units", never "inadequate". |
| **Pandemic period (O-14)** | 2020–2022 in `dim_date`, agreed 2026-10-19. |
| **Authorized beds** | These are licensed beds. They do not measure staffed beds. |
| **Weighted occupancy** | The rate uses eligible records only: BOR 150 and below. It therefore understates load where many records exceed 150, mostly in government hospitals. Label it "eligible records". The bed basis and reporting period are not confirmed by HFSRB yet (O-12). |
| **Unbuilt stretch items** | Immunization coverage and the full dengue capacity replay (BQ2) remain outside the current build. |
| **Run mode (D-59)** | Manual runs; the schedule stays paused. R0 (trigger) and R1 (skip unchanged work) are recommendations, not built. |
| **No gold setup file (D-60)** | The setup job's `schema_setup.sql` creates `public_health.gold`. A gold file stops if the schema is missing. |
| **Input pinning (R4)** | Builds record the silver version they read but do not pin it with `VERSION AS OF`. |

---

## 10. Running gold without Databricks

The platform needs a short list of capabilities, not Databricks: Spark SQL 4.x with ANSI mode on, a versioned table format (Delta Lake), a scheduler that stops on the first failure, and the quality tables. The list, the open-source alternative for each, the library versions and the Spark SQL features to replace when porting are in one place: [reproducibility](../../docs/07-operations/reproducibility.md). This section keeps only what is specific to gold.

| Gold-specific item | What to do |
|---|---|
| Three-part names (`public_health.gold.*`) | Configure a catalog named `public_health`, or switch to two-part names in the SQL. Set `--gold_schema`, `--silver_schema` and `--dq_schema` in `gold_qc.py` |
| Run order | Run the files in number order (section 1) and stop on the first error, then run `gold_qc.py` |
| Settings and run parameters | Edit the variables in step [0] of each file, or pass `job_run_id` / `code_version`; `gold_qc.py` takes them as arguments |
| Dashboard | Any BI tool that queries SQL views can read the marts and default views |

### Keep keys consistent across the rebuild

Gold uses `xxhash64` for surrogate keys. If you choose another hash function, the key values will change. Rebuild every table in the same run so all joins use the same keys. This is acceptable because nothing stores a key from outside the run.

### If table versions are unavailable

Builds record `target_table_version` as null. This reduces what QC can verify:

- G05 compares row counts only.
- G06 cannot compare input versions. It lists those inputs as "not checked".

For versions, libraries and the rebuild steps for every layer, see [reproducibility](../../docs/07-operations/reproducibility.md).

---

## 11. History of updates

| Date | Change |
|---|---|
| 2026-10-11 | Created the first gold SQL from Gold Layer Proposal v3 in `public_health.test_gold`. Set up write-audit-publish builds and lineage through `build_log` / `build_inputs`. |
| 2026-10-12 | Aligned the SQL columns with Proposal v3.1 and marked proposed extra columns. Applied the silver QC changes. Reviewers flagged too many fact tables, a data dictionary that was hard for non-technical readers to use, and the missing conceptual model. They also requested sample datasets. |
| 2026-10-13 | Ran all v1 dimensions and facts in `test_gold`, plus `context_health_expenditure`. The built **data model v1** had 6 dimensions and 9 facts. The mentor shared a conceptual model covering Date, Geography, Facilities, Disease metric, Population, Socio-economic, Healthcare workers capacity and Facilities capacity. Compared option v2 (three stars) with option v3 (based on the mentor's model). |
| 2026-10-14 | Agreed on **data model v2**: the combined model with 5 dimensions and 4 facts. Built it in `test_gold2` with no reads from `test_gold`. Retired the labels "v4" (SQL) and "v3" (mentor proposal) for this model. Renamed `dim_period` → `dim_date` and `dim_source` → `dim_data_source`. Combined registry snapshot, published and occupancy data in `fact_facility_capacity`. Combined metric and deaths-by-age data in `fact_disease_metric`. Moved the profession list onto `fact_workforce_capacity`. Combined population, poverty and expenditure in `fact_area_indicator`. Ran all 10 model files. Every gate returned 0. |
| 2026-10-14 (evening) | Added TB programme rows and PhilHealth claims to `fact_disease_metric`. Added `sex` to the grain, keeping the model at 4 facts. Added `ref_osm_healthsite_point` outside the model. Published occupancy at 3 geographic levels × 3 breakdowns because the first run suppressed most city cells. Fixed HDX `is_complete_year` with a contiguity and span test. Passed `source_role` through from silver as `cross_check` rather than `alternate`. |
| 2026-10-14 (night) | Wrote and ran the seeds, crosswalk, default views and marts. Applied the reviewer's 5 points to the marts and documentation only. (1) Join `dim_facility` to geography only. (2) Define a selection contract per fact through default views. (3) Label the two denominators. (4) Ask where dengue peaks were "largest relative to current recorded capacity". (5) Label access distance as distance to the nearest locality with a hospital recorded. Placed the kidney study under specialist treatment capacity. |
| 2026-10-16 | Completed **full run 1**, from bronze to marts: 00:09–01:13 PHT (UTC+8). |
| 2026-10-17 | Completed **full run 2**, end to end: 13:39–14:49 PHT. |
| 2026-10-18 | Promoted gold v2 to **`public_health.gold`**. Renamed the files `gold_01`–`gold_24` and grouped them into `dimension/`, `fact/` and `mart/`. File numbers now give the run order. Added `gold_qc.py` with G01–G13, including the G12 idempotency check. Kept `test_gold2` until it is archived. Documented the type-cast rule (`CAST` in gold, `try_cast` in silver) and the ANSI mode requirement. |
| 2026-10-19 | Applied D-42 in `mart_kidney_case_study`: provinces with HUCs can be compared at the broad unit. Renamed the exclusion reason `province_estimate_assumed_to_include_its_huc` to `province_estimate_includes_its_huc`. Added `ds_small_cohort` and `mdr_small_cohort` to `mart_tb_case_study`. Dropped the `model` column from `mart_evidence_readiness`. The team agreed the mart values (D-56) and the pandemic period (O-14). |
| 2026-10-20 | Applied the week convention (D-44, D-46) in `dim_date`. The gate accepts `iso_week` and `iso_week_ending_date`. Weekly dates come from silver. HDX peaks read "week ending <date>". Rewrote the comments of every file in one format. Removed the `model` label from the build log. Moved hard-coded counts and thresholds into named settings (`gold_01`, `gold_08`, `gold_09`). Null areas stay null in `dim_facility` and `ref_osm_healthsite_point`. Removed `gold_00_setup.sql`. The setup job creates the schema. The weekly `date_key` values change once, so G12 differs once after this rebuild. |
| 2026-10-20 (later) | `gold_03`: the source list is now a view that gold counts into `build_inputs`. The upnoah and hdx_dengue names carry D-44 to D-46. Job YAML: `gold_00` task removed. Dimensions wait for `qc_silver_cross_domain`. Added the settings table and failure guide to this README. Wrote the detailed gold and quality pages in `docs/04-pipeline/`. |
| 2026-10-20 (later) | Rewrote this README in short, active sentences. |

For the table, column and question map, use the gold map workbook: `capstone_gold_v4_map.xlsx`. The planned filename is `capstone_gold_v2_map.xlsx`.
