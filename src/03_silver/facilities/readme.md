# Silver: facilities

This page covers the facilities silver tables: facility identity and registry, published counts by area and year, anonymous bed occupancy records, OSM facility points, and the reference inputs they depend on. It follows `facilities-silver-plan.md` v2.1 (2026-10-12) and the headers of the SQL and Python files.

## Status

| Item | Status |
|---|---|
| `facilities_silver_00a_area_boundary.sql` (`facilities_area_boundary` from the team's HDX `admin_boundaries_silver`) | SQL written 2026-10-12. Run on local Spark 4.0 against a stand-in in the owner's schema. Column names to confirm with `DESCRIBE` |
| `facilities_silver_00_reference.sql` (exceptions and id map override, checks against geography) | SQL written. Checks run on local Spark 4.0 (2026-10-12). `read_files()` not run locally |
| `facilities_silver_01_registry.sql` (`facilities_id_map_silver`, `facilities_registry_silver`) | SQL written. Run on local Spark 4.0 (2026-10-09), twice in a row; rerun 2026-10-12 |
| `facilities_silver_02_metric.sql` (`facilities_metric_silver`) | SQL written. Run on local Spark 4.0 (2026-10-12) |
| `facilities_silver_03_bed_occupancy.sql` (`facilities_bed_occupancy_silver`) | SQL written. Run on local Spark 4.0 (2026-10-12) |
| `facilities_silver_04a_osm_locate.py` | Written. Reads GeoJSON polygons since 2026-10-12. Run on local Spark 4.0. Not run on Databricks |
| `facilities_silver_04_osm_point.sql` (`facilities_osm_point_silver`) | SQL written. Run on local Spark 4.0 (2026-10-12) |
| `build_facilities_area_exceptions.py` | Written. Run locally as a notebook would call it (2026-10-12). Not tested on Databricks |
| `build_facilities_area_boundaries.py` (faeldon/philippines-json-maps) | **Retired 2026-10-12.** Replaced by `00a` and the team's HDX boundaries |
| Run on Databricks, all files | **Done 2026-10-12**: 00a → exceptions script → 00 → 01 → 02 → 03 → 04a → 04, all gates 0. Registry 3,957, id map 5,257, metric 2,988, bed occupancy 1,977, OSM points 13,370 |
| `facilities_silver_qc.py` (silver QC through DQRun on the published tables) | Written 2026-10-12. Run on local Spark 4.0: 136 results, 128 PASS, 8 WARN, 0 FAIL. Not run on Databricks |
| `source_priority` for the metric table, blood service facilities in the registry | Designed. Blood service is deferred to v2 |
| Bed occupancy source switch (`03`, `build_facilities_area_exceptions.py` BOR section, `facilities_silver_qc.py`) | Changed 2026-10-14 to the HFSRB FOI release `doh_foi_hospital_beds` (2018-2025). Run on local Spark 4.0: bronze load with the real loader, builder BOR section, `03` (9,145 rows, gates 0), QC 19 checks 0 FAIL. Not run on Databricks |
| Healthsites newest-file rule (`04`, `04a`, `build_facilities_area_exceptions.py`, `facilities_silver_qc.py` S09 / S16 / S28) | Changed 2026-10-14 for the second Healthsites file. Run on local Spark 4.0 with both files in bronze. Not run on Databricks |

## Sources

| Source key / bronze table | What it holds | Notes |
|---|---|---|
| `doh_nhfr` / `facilities_nhfr_bronze` | NHFR active hospitals, as of 2026-09-29, 1,359 rows | Registry spine. Carries PSGC codes. `?` in place of `Ñ` in some names, so the code decides |
| `doh_hfsrb_hospitals` / `facilities_hfsrb_hospitals_bronze` | Licensed hospitals, as of 2026-06-30, 1,336 rows | ABC, hospital-based dialysis stations, blood service. Sheets Government and Private |
| `doh_hfsrb_infirmaries`, `doh_hfsrb_primary_care` | Licensed infirmaries (614) and primary care facilities (1,180) | `nhfr_code` blank on 240 and 696 rows |
| `doh_hfsrb_dialysis_clinics` | Free-standing dialysis clinics, 800 rows | Private sheet name has a leading space (`" Private"`) |
| `doh_hfsrb_blood_service` | Free-standing blood service facilities, 121 rows | In bronze only. Not read by silver v1 |
| `psa_hospitals_region_annual`, `psa_beds_region_annual` | PSA 9.18 hospitals and 9.17 authorized beds by region, 2020 to 2024 | 9.17 national bed row is labelled "Total Number of Hospitals" in the source |
| `psa_hospitals_national_annual`, `psa_hospitals_beds_national_annual`, `psa_hospitals_region_annual_legacy` | National hospitals 2006 to 2015, hospitals and beds 1990 to 2015, hospitals by region 2005 to 2015 | Overlap on purpose. Carry the 2013 definition break |
| `psa_bhs_region_annual` | PSA 9.19 barangay health stations by region, 2006 to 2023 | Column BARMM holds ARMM before 2019 |
| `doh_fhsis_demographic` / `facilities_fhsis_primary_care_bronze` | FHSIS BGY & BHS tab, 2018 to 2025, 8 workbooks | No PSGC. Landed under `workforce/` |
| `doh_foi_hospital_beds` / `facilities_bed_occupancy_bronze` | HFSRB FOI release DOH-984883683631 (2026-10-14): per reporting hospital (no name), sheets 2018 to 2025, 9,145 rows. Region, province, city / municipality, hospital type, level, ownership, authorized beds, implementing beds, BOR, inpatient bed days | RESTRICTED (FOI, no stated terms): aggregates only. Read by `03` since 2026-10-14 |
| `bed_occupancy` / `facilities_bed_occupancy_bronze` | Older bed occupancy file, sheets 2020 to 2025, 1,977 rows | SUPERSEDED by `doh_foi_hospital_beds` (same HFSRB series). Kept in bronze for lineage; `silver_enabled: false`; not read by silver |
| `hdx_healthsites` / `facilities_hdx_healthsites_bronze` | OpenStreetMap health facilities, 16,032 rows per file. Two files: `..._asof_20260929.csv` (export) and `..._asof_20261014.csv` (derived from the GeoJSON: coordinates for the 3,870 building outlines) | Open, ODbL 1.0. No PSGC. `load_mode: latest_file`: bronze keeps both files, silver reads only the newest `_as_of_date` |
| `geography_silver` | PSGC codes, names, levels, city class | Only source of codes and names. One snapshot (`content_checksum`) |
| `admin_boundaries_silver` | HDX COD-AB city / municipality polygons, centroids, areas | Team table, also used by `dim_geography`. Only polygons are taken from it, never codes |

Bronze loading is described in [bronze.md](bronze.md).

## Tables

### Reference inputs

| Input and table | Rows | What it is for |
|---|---|---|
| `admin_boundaries_silver` to `silver.facilities_area_boundary` (`00a`) | 1,642 | One row per city or municipality of geography: HDX polygon (`geometry_json`), centroid, `area_km2`, `boundary_rule` (`hdx`, `name_conflict`, `no_boundary`). For OSM point-in-polygon |
| `facilities_area_exceptions.csv` to `silver.facilities_area_exceptions` (`00`) | 137 | Place labels or codes the normal geography join cannot resolve. Generated by `build_facilities_area_exceptions.py`. Nobody edits codes in it |
| `facilities_area_decisions.csv` | 11 | The only hand-written geography input. Reviewer decisions (accept, set, reject), all dated 2026-10-09. Read by the generator, not loaded to silver |
| `facilities_id_map_override.csv` to `silver.facilities_id_map_override` (`00`) | 0 (header only) | Manual identity decisions: `link_to_nhfr` or `own_facility` |

### `facilities_id_map_silver`
- One row is one source identifier. Key: `(_source_key, source_record_id)`.
- Columns: `source_id_raw`, `source_id_norm`, `code_validated`, `facility_key`, `match_method`, `match_status`, `_first_build_id`, plus lineage.
- Used to keep `facility_key` stable across rebuilds. The build reads its own previous version.

### `facilities_registry_silver`
- One row is one facility establishment. Key: `facility_key`.
- Identity: `facility_category` (`hospital`, `infirmary`, `primary_care`, `dialysis_clinic`), `facility_name`, `nhfr_id`, `license_no`, `ownership`, `service_level`.
- Area: `area_key`, `psgc_code`, `barangay_psgc`, `geo_name_source`, `geo_resolution_method`, `geo_conflict_nhfr_hfsrb`.
- Beds and services: `nhfr_reported_beds`, `hfsrb_abc`, `authorized_beds`, `analysis_beds`, `analysis_beds_basis`, `dialysis_stations`, `has_blood_service`, `blood_service_type`.
- Presence and licence: `in_nhfr`, `in_hfsrb`, `is_currently_listed_nhfr`, `is_currently_listed_hfsrb`, `facility_status`, `nhfr_licensing_status`, `license_valid_until`, `is_license_valid_on_as_of`.
- History and lineage: `_row_hash`, `_first_build_id`, `_business_change_build_id`, `_delisted_build_id`, `_silver_build_id`, one lineage group per side (`_nhfr_*`, `_hfsrb_*`), `_metric_source_columns`.

### `facilities_metric_silver`
- One row is one area, year, ownership and source. Key: `(area_key, year, ownership, _source_key)`.
- Measures (counts as published): `hospitals`, `authorized_beds`, `bhs`, `rhu`, `mhc`, `chc`, `health_centers_total`, `barangays`, `population`, `no_report_measures`.
- Context: `region_as_published`, `geo_coverage_basis`, `series_definition`, `is_break_year`, `geo_exception_reason`.
- Used for published-count history. Sources overlap and each keeps its own rows.

### `facilities_bed_occupancy_silver` (restricted)
- One row is one anonymous hospital record of one year. Key: `(_source_key, _source_file, _source_sheet, _source_row_num)`.
- Columns: `year`, `reporting_period_start`, `reporting_period_end`, `period_confirmed`, `area_key`, `province_unit_key`, `geo_coverage_basis`, `service_level`, `hospital_type` (General / Specialty), `ownership`, `bor_pct`, `bor_bed_basis`, `bor_basis_confirmed`, `authorized_beds`, `implementing_beds`, `inpatient_bed_days`, `days_in_year`, `is_bor_over_100`, `is_exact_duplicate_in_sheet`, `baseline_eligible`, `exclusion_reason`, `sharing`.
- Source since 2026-10-14: `doh_foi_hospital_beds` only (2018-2025, both ownerships, city / municipality every year).
- `sharing = 'restricted'` on every row. Keep table access limited. Publish aggregates only, with small cells suppressed.

### `facilities_osm_point_silver`
- One row is one located OSM health facility. Key: `(osm_type, osm_id)`.
- Columns: `facility_type`, `facility_name`, `ownership`, `beds`, `longitude`, `latitude`, `location_precision` (`point` or `municipality`), `area_key`, `psgc_code`, `geo_resolution_method`, `addr_city_conflict`, `boundary_version`, `license`.
- Used for map points and distance support. It is not a facility count.

## Rules

Facility identity
- `facility_key` is a surrogate (`uuid()`) assigned once and reused from the previous id map. It is never derived from a name or a code. A name correction or a late NHFR code updates the map row, not the key.
- NHFR ids are compared as numbers (`nhfr_id`), never as padded strings. Text tokens such as `none` give `invalid_code_token`.
- Duplicate NHFR codes among HFSRB hospital rows: exact duplicates and older records of the same facility become `duplicate_of`. Rows of different facilities sharing one code are ambiguous and the code is not used for them. All 7 current cases are of this type.
- A code match is accepted only if the two records agree on place (same LGU) or name (token similarity at least 0.5). Otherwise `code_name_place_mismatch`, and the row goes to the name match.
- Fallback match: exact normalized name plus municipality `psgc_code`, unique in both directions. No fuzzy matching in the build.
- Gate: each `nhfr_id` joins at most one HFSRB hospital record.

Registry content
- A hospital-based service is an attribute of the hospital row (`dialysis_stations`, `has_blood_service`). The plan counts 654 hospitals with 9,083 hospital-based stations.
- Free-standing dialysis clinics are separate establishments (`facility_category = 'dialysis_clinic'`). Their codes have `code_validated = false` because the NHFR export holds hospitals only.
- An infirmary, primary care or dialysis record that resolves to an existing hospital gets no second row. It is logged as `service_of_existing_facility` and written to `row_disposition` as quarantined.
- Hospital counts use `facility_category = 'hospital'` only.
- `is_currently_listed_nhfr` and `is_currently_listed_hfsrb` say whether the latest complete snapshot of that source lists the facility. Licence status is separate (`nhfr_licensing_status`, `license_valid_until`). Closure is never inferred from absence. `facility_status` is `listed` or `not_listed`.
- Delisting is applied only when every declared file and sheet of the source was read (declared-inputs gate).

Bed columns
- `authorized_beds` = `hfsrb_abc` only (licensing).
- `nhfr_reported_beds` = NHFR `Bed Capacity`. Its definition is not confirmed.
- `analysis_beds` = `coalesce(hfsrb_abc, nhfr_reported_beds)`. `analysis_beds_basis` is `authorized` or `nhfr_reported`, so a dashboard can show the basis.

Bed occupancy
- Wording: the 2025 records are the preferred candidate occupancy baseline, subject to validation of bed definitions, duplicate records and reporting coverage (decision D6).
- `baseline_eligible` is derived from `exclusion_reason`: `bor_null`, `bor_negative`, `bor_gt_150`, `level_missing` (general hospitals only; specialty hospitals have no level in the source), `exact_duplicate`. `private_only_year` is gone since 2026-10-14: every year now has both ownerships.
- BOR = inpatient bed days / (authorized beds x days in year) x 100. A warn gate counts rows where the published BOR differs by more than 0.5 points (0 in the 2026-10-14 file).
- BOR above 100 and up to 150 is kept, flagged and still eligible. Above 150 is kept but not eligible. The threshold is the variable `bor_baseline_max`.
- `bor_basis_confirmed = false` and `period_confirmed = false` until the provider confirms.
- Records are never matched to registry facilities. Identical rows stay separate because the records are anonymous.
- Records are placed at city / municipality every year. A record whose city label does not resolve is kept at its province unit (`province_incl_cities_as_reported`, which includes the HUCs inside it): 89 records (BALIUAG, OZAMIS CITY) until those two labels are decided.

Published-count history
- The hospital definition changed in 2013. `series_definition` is `hospitals_incl_infirmaries` up to 2012 and `general_and_specialty_hospitals` from 2013. `is_break_year = true` on 2013.
- FHSIS province rows exclude separately listed cities. Region = provinces plus listed cities.
- FHSIS 2025 "RHU" value is loaded as `health_centers_total`. `rhu` stays null for 2025 (decision D4).
- `*` and `-` mean no report. The value is null and the measure is listed in `no_report_measures`.

Area resolution
- Every row resolves once: exceptions first, then source code (NHFR), then name plus level plus parent. HFSRB rows matched to NHFR take the NHFR area.
- Only exceptions with `review_status` `auto`, `corroborated` or `reviewed` are used. Others are loaded as `unresolvable` and their records are quarantined.
- OSM points: `point_in_polygon`, then `nearest_boundary` (within 1 km), then `exception`, then `addr_city_name`. Otherwise quarantined.
- Healthsites file: `04` ([1] view `fac_osm_latest_file`), `04a` and the exceptions builder read only the bronze file with the newest `_as_of_date`; the builder stops if two files share it. `facilities_silver_qc.py` scopes S09, S16 and S28 to that file (`LATEST_FILE_SOURCES`).

Boundaries (`00a`)
- Areas come from `geography_silver` (latest snapshot, City and Mun). Polygons come from `admin_boundaries_silver` (ADM3, latest `source_version`), joined on its matched `psgc_code`.
- A polygon is accepted when the HDX name agrees with the geography name (text in brackets counts as a second name, e.g. "Bacungan (Leon T. Postigo)"), or the HDX match was name-based (not `CODE_MATCH`). A `CODE_MATCH` whose names disagree is not used: the area becomes `name_conflict` with no polygon, so no point is placed in the wrong municipality.
- An area with two accepted polygons stops the build.

## Run order

1. `geography_silver`, then `admin_boundaries_silver` (see [silver-geography-population.md](silver-geography-population.md)).
2. `facilities_silver_00a_area_boundary.sql` (every run).
3. Only when geography, the boundaries or a facilities bronze source changed: `build_facilities_area_exceptions.py`. Review the report and diff, record decisions in `facilities_area_decisions.csv`, upload the CSV.
4. `facilities_silver_00_reference.sql` (every run).
5. `facilities_silver_01_registry.sql`
6. `facilities_silver_02_metric.sql`
7. `facilities_silver_03_bed_occupancy.sql`
8. `facilities_silver_04a_osm_locate.py`, then `facilities_silver_04_osm_point.sql`, in the same job.
9. `facilities_silver_qc.py` (silver QC on the published tables), before gold. `dq_utils.py` must be a Python file in the quality folder.

## Checks

| Check | Severity | Quality attribute |
|---|---|---|
| Boundaries: one row per geography city / municipality, at most one accepted HDX polygon per area, GeoJSON present, centroid in the PH box, area > 0, WGS84 (`00a`) | FAIL | uniqueness, validity |
| Boundaries: areas without a polygon (`name_conflict`, `no_boundary`), HDX polygons not used (`00a`) | WARN | completeness |
| Exceptions CSV built from the current geography snapshot, names equal (`00_reference`) | FAIL | consistency |
| Declared files and sheets all read, exactly one `ingestion_metadata` match each | FAIL | completeness |
| NHFR code format `DOH` + 15 digits, `nhfr_id` unique | FAIL | validity |
| Each `nhfr_id` joined by at most one HFSRB hospital record | FAIL | uniqueness |
| Table keys not null and unique (all five tables) | FAIL | uniqueness |
| Every `psgc_code` exists in geography. Unresolved place label without an exception | FAIL | validity |
| Lineage groups match `in_nhfr` / `in_hfsrb`. Lineage columns not null | FAIL | auditability |
| Reconciliation per input: rows referenced by silver = rows read minus rows not loaded | FAIL | completeness |
| Control totals (NHFR beds 119,862, PSA and FHSIS national values, BOR 2025 rows and ABC, OSM 16,032 rows) | FAIL | accuracy |
| Cells that are neither numbers nor documented markers. Negative counts | FAIL | validity |
| 04a staging matches the bronze rows and boundaries read by 04 | FAIL | consistency |
| FHSIS region BHS not equal to the sum of rows under it | WARN | consistency |
| PSA 9.18 / 9.17 regions do not add up to the national row | WARN | consistency |
| BOR above 100, BOR above the baseline maximum | WARN | accuracy |
| OSM points not located, placed by `addr:city` only, on a shared border, `addr_city_conflict` | WARN | completeness |
| Freshness of the published table against bronze and geography (designed, plan 5.6) | FAIL | timeliness |

Shared rules are in [lineage-qc-contract.md](lineage-qc-contract.md).

### Silver QC: `facilities_silver_qc.py`

- Runs after `04`, before gold. Checks the published tables and writes to `quality.qc_results`, `run_log`, `table_stats`, `profile` and `quarantine` through `DQRun`. Raises at the end if any check is FAIL.
- Identity (plan 6.4): whole-table checks use `build:<build_id>` of the latest succeeded build. A check about one input uses `<source_key>:<content_checksum>` of the file the build read. FHSIS (8 files) keeps `build:<build_id>`.
- Codes: shared S00 to S06, S08, S09, S11 (seed names and severities), facilities S13 to S28. S29 is kept free. S13 to S28 are not in `quality_registry_seed.sql` yet.
- Bed occupancy is restricted: never profiled, quarantined rows are counted but not copied.

| Code | Check | Tables | Severity |
|---|---|---|---|
| S01, S02, S03 | Has rows, key not null, key unique | all | FAIL |
| S04 | PSGC code in the latest geography snapshot | all but id map | WARN |
| S05 | Area level fits the table (registry City / Mun / Manila district; OSM City / Mun; metric Reg to Mun; BOR Prov to SubMun), `area_key = psgc:<code>` or a named key | registry, metric, BOR, OSM | FAIL |
| S06, S08 | Counts non-negative, year in the source's range | | FAIL |
| S09 | Per source: rows read = bronze rows now; rows referenced = rows read minus rows not loaded | all but id map | FAIL |
| S11 | Accepted values | all | WARN |
| S13 | Lineage columns not null | all | FAIL |
| S14 | Every file or sheet the rows point to has exactly one `v_build_lineage` row | all | FAIL |
| S15 | Latest succeeded build wrote the table with this row count. Registry rows from an earlier build only if `not_listed` | all | FAIL |
| S16 | Bronze files and load times, geography snapshot and reference table versions unchanged since the build | all | FAIL |
| S17 | One load time and one processed `ingestion_metadata` row per file or sheet | all | FAIL |
| S18 | Each NHFR id in at most one registry facility | registry | FAIL |
| S19 | `_nhfr_*` / `_hfsrb_*` groups filled exactly when `in_nhfr` / `in_hfsrb` | registry | FAIL |
| S20 | Every `_metric_source_columns` key has a lineage group (registry) or is a measure (metric) | registry, metric | FAIL |
| S21 | Control totals: NHFR facilities 1,359 and beds 119,862, BOR rows 1,977 | registry, BOR | FAIL (WARN on a new file once the control checksum is set) |
| S22 | Id map and registry facility keys agree both ways | id map | FAIL |
| S23 | `authorized_beds`, `analysis_beds`, `analysis_beds_basis` follow their definitions | registry | FAIL |
| S24 | BOR eligibility follows `exclusion_reason` | BOR | FAIL |
| S25 | BOR above 100 | BOR | WARN |
| S26 | FHSIS region = provinces + listed cities (BHS, barangays), per file | metric | WARN |
| S27 | OSM points placed by `addr:city` only; `addr_city_conflict` | OSM | WARN |
| S28 | Quarantined bronze rows per source, with reasons | all but id map | WARN |

Not covered: "rerun gives the same rows" (needs a second build), S10 and S12.

## Results so far

Results are from local Spark 4.0 runs unless marked Databricks.

| Date | Result |
|---|---|
| 2026-10-09 | All FAIL gates pass on the four SQL builds. One WARN: FHSIS region total differs from its children for some region-years |
| 2026-10-09 | Registry 3,954 rows with the hand-made exceptions file. Id map 5,254. Metric 2,988. Bed occupancy 1,977 |
| 2026-10-09 | Hospitals: 1,092 joined on `nhfr_id`, 196 on name plus municipality, 71 NHFR-only, 48 HFSRB-only. Infirmaries 602, primary care 1,158, dialysis clinics 787 |
| 2026-10-09 | Registry `row_disposition`: 1,288 `merged_into`, 4 `duplicate_of`, 43 quarantined (27 `no_place_label`, 4 `place_reviewed_unresolvable`, 12 `service_of_existing_facility`) |
| 2026-10-09 | Rerun of 01: all `facility_key` values kept, 0 business changes. 10 `geo_conflict_nhfr_hfsrb` cases, NHFR code kept |
| 2026-10-09 | Bed occupancy 2025 eligible rows: government 299 of 418, private 704 of 744 |
| 2026-10-09 | Generated exceptions: 137 rows (22 auto, 53 corroborated, 11 reviewed, 51 needs_review). 46 of 52 hand-made rows reproduced |
| 2026-10-09 | With generated exceptions: registry 3,956, metric 2,988, bed occupancy 1,977, OSM points 13,367 |
| 2026-10-11 | Exceptions regenerated against geography with the ñ repair: same rows and codes. Silver row counts unchanged |
| 2026-10-12 | **Databricks, full facilities run**: registry 3,957, id map 5,257, metric 2,988, bed occupancy 1,977, OSM points 13,370. 04a: 12,155 points in a polygon, 0 on a shared border, 5 nearest boundary. Quarantined for place: OSM 2,579 `no_coordinates_no_city`, 78 `place_reviewed_unresolvable`, 3 `ambiguous_city_label`; registry 27 `no_place_label`, 1 `place_reviewed_unresolvable` (San Jose) |
| 2026-10-12 | Generator rule `address_other_province`: HFSRB San Francisco (labelled Agusan del Norte, address names Agusan del Sur) → 1600308000, `corroborated`. No other row changed. Registry 3,957 |
| 2026-10-12 | **Databricks**, `00a` rerun with the bracket rule: gates all 0, `hdx` 1,634, `no_boundary` 8 (SGA), 8 HDX polygons not used (SGA, no `psgc_code`) |
| 2026-10-12 | **Databricks**, `00a` on the real `admin_boundaries_silver`: 1 `name_conflict` (Leon T. Postigo, HDX "Bacungan (Leon T. Postigo)"; bracket name now accepted), 8 `no_boundary` (SGA, no `psgc_code` in HDX). No Maguindanao conflicts |
| 2026-10-12 | `facilities_silver_qc.py`: 136 results, 128 PASS, 8 WARN, 0 FAIL. WARN: S28 quarantined rows (infirmaries 12, primary care 21, dialysis 7, OSM 2,665), S26 FHSIS NCR 2025, S25 BOR above 100 (281 of 1,954), S27 OSM `addr:city` only (1,207) and `addr_city_conflict` (21). A duplicated OSM row gives S03 and S15 FAIL |
| 2026-10-14 | **Databricks**, `build_facilities_area_exceptions.py` (decisions now in the script's `DECISIONS` table, 13 rows): 72 exception rows, down from 137. `bor` 28 auto + 2 reviewed (BALIUAG, OZAMIS CITY); `fhsis` 3 auto, 11 corroborated, 1 reviewed; `hfsrb` 1 auto, 14 corroborated, 10 reviewed, 1 needs_review (San Jose, Oriental Mindoro, 1 record); `nhfr` 1 corroborated; no `osm` rows (every Healthsites point has coordinates). All 11 earlier decisions still apply (none stale). `damaged names repaired here: 0`: geography_silver's ñ is fixed at the source |
| 2026-10-14 | **Databricks**, `03_bed_occupancy` on `doh_foi_hospital_beds`: 9,145 rows, gates 0. Warnings: city not resolved 0, BOR vs bed days mismatch 0, BOR / bed days blank mismatch 0, BOR above 100 = 1,779, above 150 = 769. Eligible 8,150. Weighted BOR of eligible records, government / private: 2018 84.2 / 53.6, 2020 69.9 / 35.9, 2021 68.4 / 34.5, 2025 92.7 / 55.8 |
| 2026-10-14 | **Databricks**, `04a` on the 2026-10-14 Healthsites file: 16,032 rows, coordinates ok 16,032, point_in_polygon 16,021 (0 on a shared border), nearest_boundary 8, not located by coordinates 3 (previously 12,155 in a polygon and 2,579 without coordinates) |
| 2026-10-14 | **Databricks**, `04_osm_point`: 16,030 points published, 2 quarantined (not located), of 16,032. By method: point_in_polygon 16,021, nearest_boundary 8, addr_city_name 1. Hospitals 1,974 points in 729 cities / municipalities (was 358 hospitals with a point). Warnings: addr:city names another LGU than the coordinates 35 (coordinates kept), shared border 0. Quarantine share 0.01%, down from 16.6% |
| 2026-10-14 | Bed occupancy on `doh_foi_hospital_beds` (stand-in geography): bronze 9,145 rows in 8 sheets, header check passed, old file loaded alongside. Builder BOR section: 30 rows, 28 auto, 2 needs_review (BALIUAG spelling, OZAMIS CITY). `03`: 9,145 rows, gates 0; 9,056 at city / municipality, 89 at province; eligible 8,150, `bor_gt_150` 769, `level_missing` 116, `bor_null` 109, `exact_duplicate` 1. QC `bed_occupancy`: 19 checks, 0 FAIL, 1 WARN (S25 BOR above 100: 1,779) |
| 2026-10-14 | Bronze with both Healthsites files: `04` classified 16,032 rows, all from the 20261014 file, 0 without X / Y. `04a`, the exceptions builder and QC each scoped to 16,032 rows |
| 2026-10-12 | Boundaries from a stand-in `admin_boundaries_silver` (owner's schema, defects injected): `hdx` 1,632, `name_conflict` 2 (swapped Maguindanao codes), `no_boundary` 8 (SGA). A second polygon on one code was resolved by name. Exceptions unchanged. Silver 3,956 / 2,988 / 1,977 / 13,367 |

## Known limits

- **Databricks.** Full run passed on 2026-10-12 (see Results).
- **Boundary source.** Since 2026-10-12 facilities use the team's HDX table `admin_boundaries_silver`, the same source as `dim_geography`. The column names in `00a` step [1] come from the owner's guide and must be confirmed with `DESCRIBE`. Until the admin boundaries fix is applied, the Maguindanao municipalities with another municipality's code are `name_conflict` (no polygon, OSM points there fall back to nearest boundary or `addr:city`). After the fix they become `hdx` with no facilities change. The 8 SGA municipalities have no `psgc_code` in HDX and are `no_boundary`.
- **Polygons apply to OSM points only.** Registry facilities get their area from NHFR codes or name matching, not from polygons.
- **Geography column names.** No mismatch found. The SQL and the generator use `psgc_code`, `area_name`, `geographic_level`, `city_class`, `content_checksum` and `silver_processed_at`. `geo_level` in the SQL is an alias computed from `geographic_level`. Region and province parents are derived from the first 2 and 5 digits of `psgc_code`. The columns `region_code` and `province_code` are not used.
- **Plan vs SQL: ambiguous codes.** Plan 2.4 says rows with an ambiguous NHFR code go to quarantine. In `01_registry` the code is not used, the row falls back to the name match, and if unmatched it becomes its own facility with `match_status = 'ambiguous_code_own_facility'`. The local run shows no `ambiguous_nhfr_code` disposition.
- **Plan vs SQL: near matches.** The plan lists `match_status = 'candidate'` and a `candidate_match` quarantine reason. The SQL read here does exact matches only and produces neither.
- **Plan vs SQL: `source_record_id`.** The plan gives `nhfr:<nhfr_id>` for NHFR. The SQL stores the bare `nhfr_id` for NHFR rows and `nhfr:<id>` for HFSRB rows with a usable code.
- **Older notes superseded.** `sources_facilities.yaml` and the bronze handoff say "pad to 5 digits". The plan replaces this with the numeric `nhfr_id` rule.
- **Bed occupancy.** Since 2026-10-14 the source is the HFSRB FOI release (agency known). BOR denominator (authorized beds, per the header and the bed-days check) and reporting period are still unconfirmed in the flags. Coverage: reporting hospitals only, about 1,100-1,200 a year. Two city labels (BALIUAG 50 records, OZAMIS CITY 39) need a decision in `facilities_area_decisions.csv`; until then those records sit at province level.
- **OSM.** The 2026-09-29 export has no coordinates for the 3,870 building outlines (including 1,593 of 1,946 hospitals). The 2026-10-14 file fills them from the GeoJSON (centroid of the outline; 12 L/U-shaped outlines have the centroid outside the outline), so 0 rows lack coordinates (decision D12). Coverage is crowd-sourced and uneven. After the rerun on the new file, the S29 quarantine limit for this source (incident 2, 20%) can likely return to the default.
- **Latest-file rule, HFSRB.** The HFSRB sources also have `latest_file` semantics, but `01` does not filter by file yet. Same pattern to apply when a second HFSRB file lands.
- **Reference decisions are code.** Since 2026-10-14 `build_facilities_area_exceptions.py` writes all three facilities reference CSVs; decisions and identity overrides are rows in its `DECISIONS` and `ID_MAP_OVERRIDES` tables, changed by PR.
- **Bed occupancy reading.** Government hospitals report BOR above 100 on about 230 records a year (implementing beds above authorized beds). The weighted rate uses eligible records only (BOR 150 and below), so it understates government load; label it "eligible records" on the dashboard. 2020-2021 is the COVID dip in both sectors.
- **Open items.** 4 HFSRB place labels were unplaceable in v1 (D9). San Francisco is now placed by the generator rule `address_other_province` (2026-10-12); San Jose (Oriental Mindoro, no province in the address) remains quarantined. 50 exception rows are `needs_review`, 49 of them OSM city tags. FHSIS 2022 NCR rows look mislabelled (D8). FHSIS 2025 NCR: the NCR row prints 38 BHS and 2,593 barangays, but its 17 LGU rows add up to 54 and 3,160 (2021 to 2024 LGU rows add up to about 1,710 barangays, which matches NCR). The 2025 LGU barangay values look wrong in the source (QC S26). FHSIS file names differ between YAML and uploads. `qc_results_table` in the YAML still points to the bronze schema.

## Handoff to gold

| Gold table | Reads |
|---|---|
| `dim_facility` | `facilities_registry_silver` (key `facility_key`) |
| `fact_facility_capacity` | `facilities_registry_silver` bed and service columns |
| `fact_facility_published` | `facilities_metric_silver` |
| `fact_bed_occupancy` | `facilities_bed_occupancy_silver` |
| `mart_locality_service_presence`, `mart_area_service_profile`, `mart_kidney_case_study` | The tables above, plus `dim_geography` centroids (`center_lat`, `center_lon`) for straight-line distance |

Gold must not redo or override:
- Facility matching or keys. Use `facility_key` as given.
- Area resolution. Join `geography_silver` on `psgc_code` for level, city class and parents.
- Bed basis. Show `analysis_beds_basis` next to `analysis_beds`.
- Occupancy eligibility. Use `baseline_eligible` rows of 2025 only, labelled "candidate". Never join occupancy records to `dim_facility`. Publish aggregates only.
- Source choice for published counts. Keep each source's rows, respect `series_definition`, and do not trend hospitals across 2013 without the break.
- FHSIS totals. Never add a province to its own listed cities.
- Dialysis stations in `mart_kidney_case_study`: a null `dialysis_stations` means not reported. Missing is not zero.
- OSM points are never a facility count. Show "© OpenStreetMap contributors".
- Distances. Use `dim_geography` centroids, the same HDX polygons facilities use. Do not compute centroids again.

See [gold-model.md](gold-model.md) and [decisions.md](decisions.md).
