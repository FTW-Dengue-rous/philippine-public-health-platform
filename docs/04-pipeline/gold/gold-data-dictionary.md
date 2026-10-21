# Gold — data dictionary

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Every column of every object in `public_health.gold`, in the order the object returns them. This is the technical dictionary. Plain-language definitions of the business terms are in the [business data dictionary](business-data-dictionary.md); formulas are in [metric definitions](metric-definitions.md).

Status date: 2026-10-20. Column lists checked against the SQL files of 2026-10-20. Back to the [gold overview](README.md).

**Kind** column:

| Kind | Meaning |
|---|---|
| PK | Primary key: BIGINT `xxhash64` of the natural key, stable across rebuilds |
| NK | Natural key: the business value that gold hashes into the key |
| FK | Foreign key to a dimension (or to the same table) |
| Grain | Part of the fact's grain (with the FKs) |
| Attr | Descriptive attribute |
| Measure | A number; null means not available, never zero |
| Flag | Boolean; null means not assessed unless stated |
| Status | Says whether a measure is usable and why not |
| Lineage | Build identity |

**Common rules.** A measure has a value only when its status is `ok`. `_gold_build_id` joins to `quality.build_log.build_id`. Views have no `_gold_build_id`.

---

## 1. Dimensions

### 1.1 `dim_geography`

| Column | Kind | Meaning |
|---|---|---|
| `area_key` | PK | `xxhash64(area_code)` |
| `area_code` | NK | `psgc:<10-digit PSGC code>`, or a named code: `ph`, `foreign`, `hist:maguindanao`, `ncr-district:1`–`4` |
| `psgc_code` | Attr | The 10-digit PSGC code; null for named areas |
| `area_name` | Attr | Name from the PSGC snapshot |
| `geographic_level` | Attr | `region`, `province`, `city`, `municipality`, `submunicipality`, `special_geographic_area`; named areas: `country` (`ph`), `foreign`, `historical_province`, `ncr_district` |
| `income_class` | Attr | LGU income class from PSGC |
| `parent_area_key` | FK | Next level up (section 5 of the [logical model](logical-data-model-and-erd.md)) |
| `region_key` | FK | The region |
| `province_key` | FK | The province; null for regions and HUCs |
| `planning_unit_key` | FK | The planning unit (O-01); null for regions outside NCR |
| `broad_unit_key` | FK | The broad unit; null for HUCs outside NCR (use `huc_province_crosswalk`) |
| `snapshot_date` | Attr | Quarter end of the PSGC version (Q2_2024 → 2024-06-30) |
| `city_class` | Attr | `HUC`, `ICC` or `CC` for cities; null otherwise |
| `area_sqkm` | Measure | Area from the HDX boundary; null without a boundary |
| `center_lat`, `center_lon` | Measure | Boundary centroid; null without a boundary |
| `has_boundary` | Flag | The area has an HDX boundary (false for submunicipalities, the SGA, named areas, unmatched areas) |
| `_gold_build_id` | Lineage | Build that wrote the row |

### 1.2 `dim_date`

| Column | Kind | Meaning |
|---|---|---|
| `date_key` | PK | `xxhash64(period_basis, period_label)` |
| `period_basis` | NK | `calendar_year`, `calendar_month`, `iso_week` (UP NOAH), `iso_week_ending_date` (HDX), `snapshot` |
| `period_grain` | Attr | `year`, `month`, `week`, `snapshot` |
| `period_label` | NK | The silver `period_key` unchanged: `yyyy`, `yyyy-Mmm`, `yyyy-Www`, or a date (`yyyy-MM-dd`) for HDX weeks and the registry snapshot |
| `year` | Attr | Calendar year; ISO year for weekly periods (so 2021-01-03 is 2020) |
| `month` | Attr | 1–12 for monthly periods |
| `week` | Attr | ISO week 1–53 for weekly periods |
| `period_start_date`, `period_end_date` | Attr | First and last day. Weekly: 7 days, from silver |
| `is_pandemic_period` | Flag | Year between the settings `pandemic_year_from` and `pandemic_year_to` (2020–2022, O-14) |
| `_gold_build_id` | Lineage | |

### 1.3 `dim_data_source`

| Column | Kind | Meaning |
|---|---|---|
| `data_source_key` | PK | `xxhash64(source_dataset)` |
| `source_name` | Attr | Readable description. Its notes change how you read the source (D-44, D-45, D-46) |
| `source_organization` | Attr | Publisher |
| `source_dataset` | NK | The silver `_source_key` |
| `value_type` | Attr | `registered`, `reported`, `modelled`, `census`, `survey_estimate` |
| `source_as_of_date` | Attr | Publication or extraction date |
| `sharing` | Attr | `open` or `restricted` (D-47) |
| `license` | Attr | Licence text, where one applies |
| `source_domain` | Attr | `diseases`, `facilities`, `workforce`, `socioeconomic`, `geography`, `population` |
| `used_in` | Attr | Gold tables that read the source |
| `_gold_build_id` | Lineage | |

### 1.4 `dim_facility`

| Column | Kind | Meaning |
|---|---|---|
| `facility_key` | PK | `xxhash64(facility_source_id)` |
| `facility_source_id` | NK | The silver registry `facility_key` |
| `facility_name` | Attr | Registry name |
| `area_key` | FK | City, municipality or Manila submunicipality; null when silver has no area |
| `facility_category` | Attr | `hospital`, `infirmary`, `primary_care`, `dialysis_clinic` |
| `hospital_level` | Attr | `Level 1`, `Level 2`, `Level 3` or `unknown` for hospitals; null otherwise |
| `ownership` | Attr | `government` or `private` |
| `facility_status` | Attr | `listed` (counted) or `not_listed` (carried, never counted) |
| `authorized_beds` | Measure | Licensed bed capacity (HFSRB ABC) |
| `analysis_beds` | Measure | Beds used in analysis: ABC, else NHFR beds |
| `analysis_beds_basis` | Attr | Which side `analysis_beds` came from |
| `dialysis_stations` | Measure | Recorded stations; null = not reported |
| `is_license_valid_on_as_of` | Flag | Licence valid on the registry as-of date |
| `_gold_build_id` | Lineage | |

### 1.5 `dim_disease`

| Column | Kind | Meaning |
|---|---|---|
| `disease_key` | PK | `xxhash64(disease_code)` |
| `disease_code` | NK | The silver `disease_key` (for example `ihme_589`, `tb_all_forms`) |
| `disease_name` | Attr | Name |
| `disease_group` | Attr | Reviewed group that links one condition across lists (`tuberculosis`, `dengue`, `stroke`, `chronic_kidney_disease` …) |
| `cause_group` | Attr | Death composition category (`communicable`, `noncommunicable`, `injury` …); null for IHME and programme causes |
| `classification` | Attr | `psa_tabulation_list`, `ihme_gbd`, `programme`, `phic_case_rate_package`. Never summed across |
| `cause_level` | Attr | `all_causes`, `group`, `cause`, `sub_cause` |
| `parent_disease_key` | FK | Parent cause; never sum a cause with its children |
| `is_focus_disease` | Flag | Used by the burden mart and the case studies |
| `_gold_build_id` | Lineage | |

## 2. Facts

### 2.1 `fact_facility_capacity`

| Column | Kind | Meaning |
|---|---|---|
| `fact_facility_capacity_key` | PK | Hash of the grain (null `hospital_level` hashed as `'-'`) |
| `area_key` | FK, Grain | Area |
| `date_key` | FK, Grain | Registry snapshot, or the year |
| `data_source_key` | FK, Grain | Source |
| `capacity_basis` | Grain | `registry_snapshot`, `published_statistic`, `occupancy_report` |
| `facility_category` | Grain | Registry: the four categories. Published: `hospital`, `barangay_health_station`, `rural_health_unit`, `main_health_center`, `city_health_center`, `health_center_total`. Occupancy: `hospital` |
| `ownership` | Grain | `government`, `private`; published and occupancy also `total` |
| `hospital_level` | Grain | Registry: level for hospitals, null otherwise. Published: null. Occupancy: a level, `unknown` or `all` |
| `facility_count` | Measure | Facilities (registry, published) |
| `authorized_beds` | Measure | Licensed beds (registry; published hospitals only) |
| `analysis_beds` | Measure | Registry only |
| `dialysis_stations` | Measure | Registry; null when no facility of the group has a known count |
| `dialysis_facilities_stations_known` | Measure | Registry: dialysis facilities with a station count |
| `dialysis_facilities_stations_unknown` | Measure | Registry: dialysis facilities without one |
| `facilities_license_valid` | Measure | Registry: facilities with a valid licence on the as-of date |
| `facilities_without_beds` | Measure | Registry: facilities with no bed count |
| `bor_weighted_pct` | Measure | Occupancy: bed-weighted occupancy rate of eligible records |
| `bor_median_pct` | Measure | Occupancy: median rate of eligible records |
| `bor_reporting_record_count` | Measure | Occupancy: hospital records in the group |
| `bor_eligible_record_count` | Measure | Occupancy: records eligible for the baseline (BOR 150 and below) |
| `bor_weighted_beds_sum` | Measure | Occupancy: beds used as weights; use it to roll up |
| `value_status` | Status | `ok` or `suppressed` (occupancy group under `suppression_min_records`) |
| `coverage_basis` | Attr | Geographic coverage. Registry `city_municipality`; published as silver gives it; occupancy the silver level, `province_excl_huc` or `region` |
| `series_definition` | Attr | Published hospitals: definition of the series (break 2013) |
| `is_break_year` | Flag | Published: the series definition changes in this year |
| `baseline_validated` | Flag | Occupancy: HFSRB confirmed bed basis and period. False until then (O-12) |
| `nhfr_as_of_date`, `hfsrb_as_of_date` | Attr | Registry: as-of dates of the two registry sources |
| `_gold_build_id` | Lineage | |

Only the measures of the row's `capacity_basis` hold values. A gate checks this.

### 2.2 `fact_disease_metric`

| Column | Kind | Meaning |
|---|---|---|
| `fact_disease_metric_key` | PK | Hash of the natural values of the grain |
| `disease_key` | FK, Grain | Disease, cause or package |
| `area_key` | FK, Grain | Area. Claims: the hospital's area at one of three levels |
| `date_key` | FK, Grain | Year, month or week |
| `data_source_key` | FK, Grain | Source |
| `age_group` | Grain | `all_ages`, or one of 20 bands on deaths-by-age rows (`under_1`, `1_4` … `85_over`, `not_stated`); TB programme bands |
| `age_group_name` | Attr | Readable label |
| `age_min`, `age_max` | Attr | Band limits; null for `all_ages` |
| `sex` | Grain | `both_sexes`; `male`, `female` on TB programme rows only |
| `metric_name` | Grain | `cases`, `deaths`, `prevalence`; TB programme `tpt_given`, `tpt_eligible_contacts`, `treatment_cohort`, `treatment_success`; claims `claims_filed`, `claims_paid`, `claims_amount_claimed_php`, `claims_paid_amount_claimed_php` |
| `metric_basis` | Grain | `number`. The marts compute rates |
| `value` | Measure | The value; null unless `value_status = ok` |
| `value_lower`, `value_upper` | Measure | Uncertainty bounds, IHME only |
| `value_status` | Status | `ok`, `suppressed` (claims cell under 3 hospitals), or the silver status |
| `metric_definition` | Attr | What the metric counts (for example `registered_deaths`, the FHSIS indicator definition) |
| `coverage_basis` | Attr | Geographic coverage. Claims: `facility_location`, `facility_location_province_excl_huc`, `facility_location_region`. Null on by-age rows |
| `is_complete_year` | Flag | Metric rows: the source holds every period of the year and this area holds every period the source holds. Annual rows true. Null on by-age rows |
| `is_preliminary` | Flag | Claims: the latest year. Null on by-age rows |
| `_gold_build_id` | Lineage | |

### 2.3 `fact_workforce_capacity`

| Column | Kind | Meaning |
|---|---|---|
| `fact_workforce_capacity_key` | PK | Hash of the grain |
| `area_key` | FK, Grain | Area (country to municipality) |
| `date_key` | FK, Grain | Year |
| `data_source_key` | FK, Grain | `doh_fhsis_demographic` or `psa_gov_practitioners` |
| `profession_code` | Grain | `doctors`, `nurses`, `midwives`, `bhw`, `dentists`, `medtech`, `nutritionists`, `sanitary_engineers`, `sanitary_inspectors` |
| `profession_name` | Attr | Readable name (reviewed list) |
| `profession_group` | Attr | `core_clinical` (doctors, nurses, midwives), `community` (BHW), `other` |
| `headcount_total` | Measure | Total headcount; filled only when its silver status is ok |
| `headcount_lgu_hired` | Measure | LGU-hired part |
| `headcount_doh_hired` | Measure | DOH-hired (deployed) part |
| `analysis_eligible` | Flag | A rate may use `headcount_total` |
| `exclusion_reason` | Status | Why not eligible |
| `source_role` | Attr | `preferred` or `cross_check` (PSA 2018–2023) |
| `coverage_basis` | Attr | Geographic coverage as silver gives it |
| `is_break_year` | Flag | Nurse series definition changes (2019) |
| `_gold_build_id` | Lineage | |

### 2.4 `fact_area_indicator`

| Column | Kind | Meaning |
|---|---|---|
| `fact_area_indicator_key` | PK | Hash of the grain |
| `area_key` | FK, Grain | Area; `ph` for health expenditure |
| `date_key` | FK, Grain | Year |
| `data_source_key` | FK, Grain | `psa_psgc`, `doh_fhsis_demographic`, `psa_poverty`, the two expenditure sources |
| `indicator_name` | Grain | `population`, `poverty_incidence_pct`, `poor_population`, `health_expenditure_share_pct`, `health_expenditure_per_capita_php`, `health_expenditure_per_capita_growth_pct` |
| `indicator_category` | Grain | Population: `census` or `reported`. Poverty and per capita: `all`. Share: the financing agent |
| `category_level` | Attr | Expenditure share: level of the financing agent (0 total, 1–3). Only level 1 adds up to 100 |
| `parent_category` | Attr | Expenditure share: parent agent |
| `indicator_unit` | Attr | `persons`, `percent`, `php` |
| `value` | Measure | Null unless `value_status = ok` |
| `value_status` | Status | `ok`, `label_under_review` (FHSIS population with an unreviewed override), or the silver status |
| `value_note` | Attr | For example `below_0_05`: a 0.0 share stands for below 0.05% |
| `coverage_basis` | Attr | Census province rows: `province_excl_huc` (2024) or `province_coverage_unconfirmed` (2015, 2020) |
| `comparison_eligible` | Flag | Poverty rows: comparable with PSGC-based data. Null on other rows |
| `exclusion_reason` | Status | Poverty: why not eligible |
| `_gold_build_id` | Lineage | |

## 3. Seeds

### 3.1 `source_priority`

| Column | Kind | Meaning |
|---|---|---|
| `metric` | Key | Metric (`cases`, `deaths`, `prevalence`, `headcount`, `population`, TB programme and claims metrics) |
| `disease_scope` | Key | `dengue`, `tuberculosis`, `psa_tabulation_list`, `ihme_gbd`, `phic_case_rate_package`, `not_applicable` |
| `geo_level` | Key | `country`, `region`, `province`, `city`, `municipality`, `any` |
| `period_grain` | Key | `year`, `month`, `week` |
| `year_from`, `year_to` | Key | Years the rule covers |
| `data_source_key` | Key, FK | `xxhash64(source_dataset)` |
| `source_dataset` | Attr | Source |
| `priority` | Attr | 1 = first choice |
| `role` | Attr | `preferred`, `cross_check`, `fallback` |
| `replay_eligibility` | Attr | Whether the source may feed the dengue replay (stretch 2) |
| `reason` | Attr | Why this rule |

### 3.2 `priority_weight_params`

| Column | Kind | Meaning |
|---|---|---|
| `weight_set` | Key | `equal`, `supply_heavy`, `equity_heavy` |
| `indicator` | Key | The gap flag (`has_primary_care_gap`, `has_hospital_gap`, `has_workforce_gap`, `has_socioeconomic_flag`) |
| `gap_type` | Attr | `primary_care`, `hospital`, `workforce`, `socioeconomic` |
| `weight` | Measure | Weight; each set sums to 1 |
| `rationale` | Attr | Why |

## 4. Helpers and reference

### 4.1 `huc_province_crosswalk`

| Column | Kind | Meaning |
|---|---|---|
| `huc_area_key`, `huc_area_code`, `huc_name` | Key, Attr | The HUC outside NCR |
| `province_area_key`, `province_area_code`, `province_name` | FK, Attr | The province it sits in |
| `match_status` | Status | `matched`, `not_in_name_list` (a new HUC in PSGC), `province_not_found` |

### 4.2 `area_coverage_map`

| Column | Kind | Meaning |
|---|---|---|
| `fact_table` | Key | Fact the row comes from |
| `data_source_key`, `source_dataset` | Key, Attr | Source |
| `geo_coverage_basis` | Key | The source's coverage basis for the row (from silver) |
| `area_key`, `area_code`, `area_name`, `geographic_level` | Key, Attr | Published area |
| `date_key`, `year` | Key, Attr | Year |
| `mapping_outcome` | Attr | `direct`, `aggregate`, `not_separable`, `not_used`, `out_of_scope` |
| `planning_unit_key` | FK | The unit, for `direct` and `aggregate` only |
| `broad_unit_key` | FK | Province (or NCR) the row belongs to |
| `unit_parts_present`, `unit_parts_expected` | Measure | Aggregate: parts the source published, parts the unit needs |
| `cities_included` | Attr | Component cities added to a province row (never a HUC) |
| `note` | Attr | Why this outcome, citing D-42 or D-43 where relevant |

### 4.3 `ref_osm_healthsite_point`

| Column | Kind | Meaning |
|---|---|---|
| `osm_point_key` | PK | `xxhash64(osm_key)` |
| `osm_key` | NK | `osm_type/osm_id` |
| `osm_type`, `osm_id` | Attr | OSM element |
| `facility_name`, `facility_type`, `amenity`, `healthcare`, `speciality`, `operator`, `ownership`, `operational_status`, `beds_tagged`, `emergency` | Attr | OSM tags as published; unverified |
| `latitude`, `longitude` | Measure | Coordinates from the GeoJSON |
| `has_coordinates` | Flag | Point has coordinates |
| `location_precision` | Attr | `point` (exact) or `municipality` (placed by city tag only) |
| `area_key` | FK | City or municipality from the silver placement; null when silver has none |
| `geo_resolution_method` | Attr | `point_in_polygon`, `nearest_boundary`, `exception`, `addr_city_name` |
| `data_source_key` | FK | `hdx_healthsites` |
| `source_as_of_date` | Attr | Export date |
| `_gold_build_id` | Lineage | |

## 5. Default views

| View | Columns |
|---|---|
| `v_facility_capacity_totals` | `area_key`, `date_key`, `data_source_key`, `capacity_basis`, `coverage_basis`, `facility_category`, `ownership` (always `total`), `hospital_level` (`all`), `facility_count`, `authorized_beds`, `analysis_beds`, `dialysis_stations`, `facilities_license_valid`, `bor_weighted_pct`, `bor_reporting_record_count`, `value_status`, `nhfr_as_of_date`, `hfsrb_as_of_date` |
| `v_disease_metric_totals` | Every column of `fact_disease_metric` for all-ages, both-sexes rows, plus `is_preferred_source` (the row's source is `preferred` in `source_priority` for its metric, scope, level, grain and year) |
| `v_workforce_preferred` | `fact_workforce_capacity_key`, `area_key`, `date_key`, `data_source_key`, `profession_code`, `profession_name`, `profession_group`, `headcount_total`, `headcount_lgu_hired`, `headcount_doh_hired`, `coverage_basis`, `is_break_year`, `exclusion_reason`, `year`, `source_dataset` |
| `v_area_indicator_latest` | The `fact_area_indicator` columns for ok rows, plus `year`, `source_dataset`, `is_latest_period` (latest year of that area, indicator, category and source) |

## 6. Marts

### 6.1 `mart_locality_service_presence`

| Column | Meaning |
|---|---|
| `area_key`, `area_code`, `area_name`, `geographic_level`, `city_class`, `planning_unit_key`, `region_key` | The city or municipality |
| `population`, `population_year` | Latest census count |
| `hospitals_recorded`, `has_hospital_recorded` | Listed hospitals; at least one |
| `highest_hospital_level`, `has_level3_hospital_recorded` | Highest listed level; a Level 3 is listed |
| `hospital_beds` | Analysis beds of listed hospitals; 0 when none listed, null when listed but none has a count |
| `hospitals_without_bed_count` | Listed hospitals with no bed count |
| `primary_care_facilities_listed` | Listed primary care facilities |
| `licensed_primary_care_facilities_recorded`, `has_licensed_primary_care_recorded` | Those with a valid licence; at least one |
| `infirmaries_recorded` | Listed infirmaries |
| `population_per_hospital`, `population_per_hospital_bed`, `population_per_licensed_primary_care` | A4 ratios; null where the count is 0 |
| `registry_as_of_date`, `primary_care_list_as_of_date` | As-of dates to show |

### 6.2 `mart_base_planning_unit`

| Column | Meaning |
|---|---|
| `planning_unit_key`, `area_code`, `area_name` | The unit |
| `unit_level` | `province`, `HUC`, `NCR`, `other` |
| `region_key`, `region_name`, `income_class` | Context |
| `localities` | Cities and municipalities in the unit |
| `population`, `population_year`, `population_data_source_key` | Sum of the localities' census counts, latest census year; null if any locality lacks one |
| `localities_without_population` | Localities with no count |

### 6.3 `mart_area_service_profile`

| Column | Meaning |
|---|---|
| `planning_unit_key`, `area_code`, `area_name`, `region_key`, `unit_level`, `income_class` | The unit |
| `population`, `population_year`, `population_source` | Census denominator |
| `hospitals`, `beds`, `beds_per_10k`, `beds_level1`, `beds_level2`, `beds_level3` | Registry hospitals and analysis beds |
| `government_beds`, `government_bed_share` | Government beds; share of all beds |
| `level3_hospitals`, `highest_hospital_level` | Level 3 count; highest level |
| `localities`, `localities_without_hospital`, `population_without_hospital` | Localities and people with no hospital recorded |
| `licensed_primary_care_facilities_recorded`, `localities_without_licensed_primary_care_recorded`, `population_without_licensed_primary_care_recorded` | Same for licensed primary care |
| `reported_bhs`, `reported_health_centers`, `fhsis_reported_population` | FHSIS counts and the population printed with them |
| `reported_bhs_per_10k`, `reported_health_centers_per_10k` | FHSIS facility rates on the FHSIS population |
| `fhsis_count_year`, `fhsis_mapping_outcome`, `fhsis_exclusion_reason` | Year, coverage outcome, why null |
| `doctors`, `nurses`, `midwives`, `bhw` | Preferred, eligible headcounts |
| `doctors_per_10k`, `nurses_per_10k`, `midwives_per_10k`, `bhw_per_10k` | Census-based rates |
| `doh_deployed_share` | DOH-hired share of the core headcount |
| `workforce_year`, `workforce_mapping_outcome`, `workforce_exclusion_reason` | Year, coverage outcome, why null |
| `bhw_year`, `bhw_exclusion_reason` | BHW year (2025 has no total), why null |
| `poverty_incidence_pct`, `poverty_year`, `poverty_band`, `poverty_exclusion_reason` | Poverty from a direct row; display band (`under 10%`, `10% to under 20%`, `20% to under 30%`, `30% or more`); why null |
| `*_quintile` (8 columns) | Quintile 1 (lowest) to 5 among units with a value |
| `hospitals_without_bed_count`, `registry_as_of_date`, `localities_without_population` | Data-quality context |

### 6.4 `mart_area_burden_indicator`

| Column | Meaning |
|---|---|
| `planning_unit_key`, `area_code`, `area_name` | The unit |
| `burden_indicator_key` | `<disease_code>:<metric_name>:<source_dataset>` |
| `disease_key`, `disease_code`, `disease_name`, `metric_name`, `metric_basis` | The indicator |
| `data_source_key`, `source_dataset`, `value_type` | Source (preferred in `source_priority`) |
| `value`, `value_lower`, `value_upper` | Count or estimate; bounds for IHME |
| `population`, `population_year` | Census denominator |
| `rate_per_100k`, `reference_year`, `quintile` | Rate, its year, quintile among units with a rate |
| `localities_reporting` | FHSIS: localities with a report |
| `mapping_outcome`, `exclusion_reason` | Coverage outcome; why no rate |

### 6.5 `mart_area_evidence`

| Column | Meaning |
|---|---|
| `planning_unit_key`, `area_code`, `area_name`, `unit_level` | The unit |
| `indicator_key`, `indicator_group` | Indicator (service rate or burden indicator) and its group |
| `value`, `value_available` | Value; whether there is one |
| `reference_year`, `data_source_key` | Year and source |
| `mapping_outcome`, `coverage_compatible` | Coverage outcome; whether it maps (direct or aggregate) |
| `comparison_eligible`, `exclusion_reason` | Enters comparisons; why not |

### 6.6 `mart_area_priority`

| Column | Meaning |
|---|---|
| `planning_unit_key`, `area_code`, `area_name`, `unit_level` | The unit |
| `burden_indicator_key`, `burden_rate_per_100k`, `burden_quintile`, `is_high_burden` | Burden indicator of the row |
| `weight_set`, `eligibility_config`, `missing_rule` | Scenario |
| `indicator_set`, `indicators_available`, `missing_indicators` | Gap flags used, known, missing |
| `has_primary_care_gap`, `primary_care_gap_basis`, `has_hospital_gap`, `has_workforce_gap`, `has_socioeconomic_flag` | Gap flags (null = input missing) |
| `gap_profile` | Raised flags as text, or `none` |
| `flags_count`, `score`, `rank`, `ranking_population` | Unweighted count; weighted score 0–1; rank (1 = highest); ranked units |

### 6.7 `fact_area_access`

| Column | Meaning |
|---|---|
| `area_key`, `area_code`, `area_name`, `planning_unit_key`, `population`, `has_hospital_recorded` | The locality |
| `nearest_hospital_locality_key`, `_name`, `_km` | Nearest locality with a hospital recorded; 0 km if its own |
| `nearest_level3_locality_key`, `_name`, `_km` | Same for Level 3 |
| `locality_distance_basis` | Text: how the mart measures the distance |
| `nearest_osm_hospital_point_key`, `_name`, `_km` | Nearest OSM hospital point (exact coordinates) |
| `osm_distance_basis` | Text, with the OSM attribution |
| `coordinates_validated` | The locality has a boundary centre |

### 6.8 `mart_tb_case_study`

| Column | Meaning |
|---|---|
| `area_key`, `area_code`, `area_name`, `planning_unit_key`, `region_key` | The locality |
| `tb_notifications_2024`, `tb_notifications_2025`, `tb_change` | FHSIS notifications, all forms; 2025 − 2024 |
| `tb_notifications_per_100k_2024`, `_2025` | On the 2024 census population |
| `population`, `population_year` | 2024 census |
| `doctors_per_10k`, `nurses_per_10k`, `midwives_per_10k`, `bhw_per_10k`, `bhw_lgu_hired_per_10k`, `workforce_year` | FHSIS 2025 workforce |
| `has_licensed_primary_care_recorded`, `has_hospital_recorded` | From mart 14 |
| `comparison_eligible`, `exclusion_reason` | T1 eligibility |
| `tpt_given`, `tpt_eligible_contacts_estimate`, `tpt_coverage_pct` | T2 preventive treatment |
| `ds_treatment_cohort`, `ds_treatment_success`, `ds_treatment_success_rate_pct`, `ds_small_cohort` | Drug-susceptible TB |
| `mdr_treatment_cohort`, `mdr_treatment_success`, `mdr_treatment_success_rate_pct`, `mdr_small_cohort` | Drug-resistant TB |
| `programme_small_cohort`, `programme_available`, `programme_year` | Older flag (both cohorts under 10); any denominator; year |

### 6.9 `mart_kidney_case_study`

| Column | Meaning |
|---|---|
| `kidney_unit_key`, `unit_basis`, `area_code`, `area_name`, `region_key` | IHME province or NCR; `planning` or `broad` |
| `ckd_deaths`, `ckd_deaths_lower`, `ckd_deaths_upper`, `ckd_deaths_per_100k`, `burden_year` | IHME modelled CKD deaths |
| `dialysis_facilities`, `dialysis_facilities_stations_known`, `dialysis_facilities_stations_unknown`, `stations_known_share` | Dialysis facilities and station completeness |
| `dialysis_stations_reported`, `dialysis_stations_hospital`, `dialysis_stations_freestanding`, `dialysis_stations_per_100k` | Stations |
| `has_dialysis_facility_recorded`, `registry_as_of_date` | Any listed; as-of date |
| `population`, `population_year` | Census, summed over the unit's localities |
| `mapping_outcome`, `comparison_eligible`, `exclusion_reason` | Gates 1–4 |

### 6.10 `mart_dengue_peak_capacity`

| Column | Meaning |
|---|---|
| `area_key`, `area_code`, `area_name`, `geographic_level` | Area as the source publishes it |
| `data_source_key`, `source_dataset`, `period_grain`, `period_basis`, `year` | Source and year |
| `periods_reported`, `is_complete_year`, `is_near_complete`, `is_preliminary` | Completeness |
| `peak_label`, `peak_period_label`, `peak_period_number`, `peak_cases` | The peak; HDX label reads "week ending <date>" |
| `annual_cases`, `peak_period_share_pct`, `top4_periods_share_pct` | Concentration |
| `population`, `population_year`, `annual_cases_per_100k` | Latest census |
| `is_high_burden_year`, `high_burden_years`, `repeat_high_burden` | Repeat high burden |
| `mapping_outcome`, `comparison_eligible`, `coverage_note` | Coverage |
| `hospitals_recorded`, `hospital_beds_recorded`, `capacity_coverage`, `registry_as_of_date` | Registry capacity of the same coverage |
| `peak_cases_per_100_beds` | Relative pressure |
| `occupancy_year`, `bor_weighted_pct`, `bor_reporting_record_count`, `occupancy_value_status` | Latest occupancy |

### 6.11 `mart_evidence_readiness`

| Column | Meaning |
|---|---|
| `table_name`, `schema_name`, `layer`, `domain` | Table; filter `schema_name = 'gold'` |
| `latest_build_id`, `finished_at`, `row_count` | Latest succeeded build |
| `inputs`, `stale_inputs`, `is_fresh` | Inputs recorded; inputs rebuilt since; none stale |
| `qc_pass`, `qc_warn`, `qc_fail`, `qc_status`, `qc_checked_at` | Latest QC |
| `approval` | From the build parameters. Provisional until every input passes silver QC and someone reviews its warnings |

## 7. History of updates

| Date | Change |
|---|---|
| 2026-10-12 | Column list in `gold_columns.csv` (first model) |
| 2026-10-14 | Combined model columns |
| 2026-10-19 | `mart_tb_case_study` + `ds_small_cohort`, `mdr_small_cohort`; `mart_evidence_readiness` − `model` |
| 2026-10-20 | Page written from the SQL files |
| 2026-10-20 | Rewritten in short, active sentences |
