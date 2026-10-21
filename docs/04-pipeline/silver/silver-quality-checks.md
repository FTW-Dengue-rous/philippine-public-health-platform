# Silver — quality checks

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Every check that guards the silver layer: what it tests, which table it runs on, how bad a failure is, and what to do about it. The check IDs, names and severities on this page are the ones in the QC scripts' `CHECKS` dictionaries.

Status date: 2026-10-19, after the rule 2a revision. Back to the [silver overview](README.md). Row accounting is explained in [reconciliation](reconciliation.md); every code across all layers (B, S, G) is in the [quality check catalog](../quality/quality-check-catalog.md).

---

## 1. Summary

Silver is checked at three points:

| # | When | What | Where it runs | On failure |
|---|---|---|---|---|
| 1 | **Before publishing** | Build gates on the candidate table | Inside each build file (`__gates` staging table, or the Python gate in geography and population) | The build raises and the published table stays as it was. A `failed` row goes to `quality.build_log` |
| 2 | **After publishing, per domain** | Domain QC on the published tables | One script per domain (`<domain>_silver_qc.py`) | Any FAIL makes the job task fail, so gold does not start |
| 3 | **After every domain** | Cross-domain QC: checks that read two or more domains | `silver_cross_domain_qc.py` | Same: a FAIL stops gold |

Rules that apply to every check:

- **FAIL** means the table is wrong, incomplete or can't be traced. It blocks the pipeline.
- **WARN** means the table is a faithful copy of its source, but the source has a gap or a disagreement that a person should read. It does not block.
- Results are written by `dq_utils.DQRun` to `quality.qc_results`, one row per check. The run summary goes to `quality.run_log`. Row counts and Delta versions go to `quality.table_stats`, column profiles to `quality.profile`, and quarantine copies to `quality.quarantine`.
- No number that the logic depends on is typed in a QC script (rule 2a). Control values come from `config/sources_<domain>.yaml`. Years, counts and thresholds come from the settings the build recorded in `build_log.parameters` (section 3.3).

## 2. Scripts, tables and run order

| Order | Script | Tables checked | Codes |
|---|---|---|---|
| 1 | `geography_silver_qc.py` | `geography_silver` | GS01–GS08 |
| 2 | `admin_boundaries_silver_qc.py` | `admin_boundaries_silver` | AS01–AS04, ASB05, AS07–AS09 |
| 3 | `psgc_population_silver_qc.py` | `population_silver` | S00–S09, S51–S59 |
| 4 | `facilities_silver_qc.py` | `facilities_registry_silver`, `facilities_id_map_silver`, `facilities_metric_silver`, `facilities_bed_occupancy_silver` (restricted), `facilities_osm_point_silver` | S00–S11, S13–S28 |
| 4 | `diseases_silver_qc.py` | `diseases_metric_silver`, `diseases_deaths_age_silver`, `diseases_hospital_encounters_silver` (restricted), `diseases_source_coverage_silver`, `diseases_tb_programme_silver`, `diseases_hospital_claims_silver` (restricted) | S00–S12, S30–S50 |
| 4 | `workforce_silver_qc.py` | `workforce_headcount_silver`, `workforce_area_denominator_silver`, `workforce_specialist_silver` | S00–S09, S60–S79 |
| 4 | `socioeconomic_silver_qc.py` | `socioeconomic_poverty_silver`, `socioeconomic_health_expenditure_share_silver`, `socioeconomic_health_expenditure_per_capita_silver`, `socioeconomic_child_mortality_silver` | S00–S10, S80–S96 |
| 5 | `silver_cross_domain_qc.py` | All of the above | S00, S04, S08, S29, S97–S99 |

Each domain script runs after that domain's build files. The cross-domain script depends on every silver QC task, and gold depends on it.

Options common to the domain scripts:

| Option | Default | Use |
|---|---|---|
| `--tables` | `ALL` | Check only some tables, for example `--tables metric,deaths_age` |
| `--fail_on_error` | `true` | `false` records results without raising (for investigation only) |
| `--profile` | `true` | Also write column profiles (never written for restricted tables) |
| `--config_path` | found by search | Path to `sources_<domain>.yaml` |
| `--job_run_id` | none | Pass `{{job.run_id}}` from the Databricks job |

## 3. How a result is decided

### 3.1 Status

A check either gives its status directly (PASS or its severity), or gives `fail_count` and `total_count` and lets `dq_utils` decide:

| Mode | Rule |
|---|---|
| Plain | PASS when `fail_count / total_count` ≤ `threshold` (default 0). Otherwise the check's severity (WARN or FAIL) |
| Banded (S29 only) | PASS at 0. WARN up to the limit, or when failing rows ≤ the row floor. Above both, FAIL |
| Value | PASS when observed = expected (numbers within 0.0005). Otherwise the check's severity |

`S00` "QC ran without error" is recorded as FAIL when a table's checks raise an error, for example a missing table or a missing build setting. The other tables still run, and the run fails at the end.

### 3.2 Identity of a result

| Column | Holds |
|---|---|
| `batch_id` | `build:<build_id>` of the silver build that wrote the table, so the result points at one build. Geography and boundaries use the bronze `batch_id` of the snapshot checked. Facilities checks about one input file use `<source_key>:<content_checksum>` |
| `source_key` | Filled when the check is about one source |
| `validation_id` | One QC run |
| `observed` / `expected` / `detail` | What was found, what was required, and a short list of the failing rows or groups (500 characters at most) |

`capture_table_stats` records the Delta version that was checked.

### 3.3 Where the settings come from (rule 2a)

| Kind of number | Source | If missing |
|---|---|---|
| Published control values (S21, S34, S56, S64, S65, S78, S84) | `config/sources_<domain>.yaml`: the same `qc.control_values` items bronze QC B11 checks, with a `silver:` block saying where the number sits in silver | S00 FAIL for the table, so a YAML edit can't switch a control off without notice |
| Years, counts, cut-offs the build used | `build_log.parameters` of the table's own `build_id`, read with `TableQC.param(key)` | S00 FAIL naming the build to rerun (a table built before 2026-10-19 doesn't have the keys) |
| Accepted vocabularies of geography and boundaries | `config/sources_geography.yaml` (`psgc.silver_qc`, `hdx_phl_admin.silver_qc`), the same lists the builds use | Not applicable: build and QC read the same list |
| Policy constants that are part of a check's meaning | Named constants in the script, one comment each: S29 limits, S58 30%, S94 15 points, S07 growth ±50%, S97 bands, S99 10% | Not applicable |

Settings recorded by each build and read by QC:

| Table | Settings in `build_log.parameters` | Used by |
|---|---|---|
| `facilities_metric_silver` | `hospital_definition_break_year` | S11 |
| `facilities_bed_occupancy_silver` | `bor_baseline_max`, `bor_expected_sheets` | S08, S24, S25 |
| `facilities_osm_point_silver` | `ph_bbox` | S11 |
| `workforce_headcount_silver` | `fhsis_years`, `psa_years`, `fhsis_coded_years`, `professions`, `eligibility_rule_ids` | S08, S66, S67, S68, S70, S71 |
| `workforce_area_denominator_silver` | `denominator_sheets`, `households_years` | S08, S09, S63, S74 |
| `socioeconomic_poverty_silver` | `poverty_years`, `poverty_cv_caution_pct` | S08, S10, S87, S88 |
| `socioeconomic_health_expenditure_share_silver` | `share_years`, `share_agent_count`, `share_level1_tolerance_pct` | S08, S10, S88, S91 |
| `socioeconomic_health_expenditure_per_capita_silver` | `per_capita_years` | S08, S88 |
| `socioeconomic_child_mortality_silver` | `mortality_survey_years`, `characteristic_count`, `characteristics_by_group` | S08, S10, S88 |
| `diseases_hospital_encounters_silver` | `long_stay_days` | S47 (detail) |

### 3.4 Restricted tables (D-47)

`diseases_hospital_encounters_silver`, `diseases_hospital_claims_silver` and `facilities_bed_occupancy_silver` get counts only:

- No column profile, because a minimum or maximum would copy a record value into `quality.profile`.
- No quarantine copy, because no row of the release may leave the table. Quarantined rows are still counted in S28 and S29.
- `diseases_metric_silver` profiles leave out `value_lower` and `value_upper`, because of the IHME licence.

## 4. Build gates (before publishing)

Every SQL build writes a `__gates` table with one row per gate and a `failures` count. A non-zero count marks the build `failed` in `build_log` and raises. The same gate kinds appear in every domain:

| Gate kind | Fails when | Example |
|---|---|---|
| Inputs | A file or sheet has more than one load time, more than one ingestion-log match, or no processed match; a declared sheet is missing from bronze, or bronze has a sheet the layout doesn't know | Workforce `02`: "declared FHSIS sheet missing from bronze" |
| Classification | A bronze row has no disposition, or classified rows ≠ rows read | Every build |
| Row accounting | Bronze rows referenced by silver ≠ rows read − rows not loaded | Every build |
| Key | The grain key is null or repeated | Every build |
| Reference | A reference table is missing, or was built from another geography snapshot | Facilities `00`, workforce `01` |
| Upstream step | The step this build depends on did not pass, or its bronze changed since it ran | Workforce `02` and `03`: "workforce_silver_01 gates are not all 0: rerun 01" |
| Settings | A setting the build reads is missing | Workforce `02` and `03`: settings from `workforce_fhsis__settings` |
| New-file protection | A bronze year column, sheet or layout that the settings don't list | PSA year columns vs `psa_years`; poverty `first_estimate_year` not in `poverty_years`; OSM / PSA year range |
| Domain rules | Values the table can't be published with | Unknown area, profession without a label, bed definitions, the 2013 hospital break still visible in the data |

The Python builds have their own checks, recorded in `qc_results` before the write:

| Build | Checks | Stop rule |
|---|---|---|
| `geography_silver.py` | SG01 required fields, SG02 key unique, SG03 accepted levels (from the YAML), SG04 hierarchy, SG05 bronze = silver rows, SG06 names repaired, SG07 10-digit code | A FAIL stops the MERGE |
| `admin_boundaries_silver.py` | AB01 completeness, AB02 key unique, AB03 accepted values, AB04 bronze = silver features, AB05 PSGC reconciliation, AB06 spatial validity, AB07 PSGC codes | AB07 stops the run; the grain check stops it before the version is replaced |
| `psgc_population_silver.py` | Grain unique, parse status in the approved list | Stops before the write |

Gates and QC overlap on purpose. A gate stops a bad candidate, while QC checks the published table and stores the result, including the WARN checks that are not gates.

## 5. Code ranges

| Range | Owner |
|---|---|
| S00–S12 | Shared silver codes; same name and meaning in every domain |
| S13–S28 | Facilities |
| S29 | Cross-domain quarantine gate |
| S30–S50 | Diseases |
| S51–S59 | Population |
| S60–S79 | Workforce |
| S80–S96 | Socioeconomic |
| S97–S99 | Cross-domain |
| GS01–GS08 | Geography |
| AS01–AS09, ASB05 | Admin boundaries |

The same idea has a different code in each domain, because each domain took its own block:

| Idea | Diseases | Facilities | Workforce | Socioeconomic | Population |
|---|---|---|---|---|---|
| Lineage columns not null | S30 | S13 | S60 | S80 | S51 |
| Each file or sheet referenced has one `build_inputs` row | S31 | S14 | S61 | S81 | – |
| Table written by one succeeded build with this row count | S32 | S15 | S62 | S82 | – |
| Silver built from the bronze and references there now | S33 | S16 | S63 | S83 | S57 |
| Control values match | S34 | S21 | S64, S65, S78 | S84 | S56 |
| Quarantined rows listed | S45 (FAIL if another reason) | S28 | S73 | – (only non-data rows dropped) | – |

## 6. Shared checks (S00–S12)

| Code | Check | Severity | Fails when | Used by |
|---|---|---|---|---|
| S00 | QC ran without error | FAIL | The checks of a table raised an error (missing table, missing build setting or control) | All |
| S01 | Table exists and has rows | FAIL | No table, or 0 rows | All |
| S02 | Grain key not null | FAIL | Any key column is null | All |
| S03 | Grain key unique | FAIL | A key value appears twice | All |
| S04 | PSGC code found in geography | WARN | A code is not in the latest geography snapshot | Population, facilities, socioeconomic, cross-domain (workforce) |
| S05 | Admin level valid | FAIL | The code's level doesn't fit the table, or the area key is not `psgc:<code>` or a named key | Facilities |
| S06 | Counts non-negative | FAIL | A count or measure is below 0 | Population, facilities, diseases, workforce |
| S07 | Rates within range | WARN | A rate is outside its plausible range | Socioeconomic |
| S08 | Period within expected range | FAIL | A year outside the range, a bad period key, or (weekly rows) not an ISO week | All domains, cross-domain |
| S09 | Bronze to silver rows reconcile | FAIL | Rows read ≠ bronze rows now, or rows referenced ≠ rows read − rows not loaded | All domains (per source) |
| S10 | Metric totals preserved | FAIL | The sum of a measure in silver ≠ the sum of the same cells in bronze | Diseases, socioeconomic |
| S11 | Accepted values | WARN | A value outside its vocabulary | Facilities |
| S12 | Metric null rate under threshold | WARN | The null share is above the threshold (5% or 10%) | Diseases |

How S09 counts (all domains, see [reconciliation](reconciliation.md)):

```
PASS when   rows read (build_inputs.input_rows)  = bronze rows of that source now
      and   rows silver references              = rows read − rows not loaded
```

`row_disposition` holds only the rows that were not loaded. `merged_into` rows count as loaded. In socioeconomic, any disposition other than `dropped_non_data` also fails S09.

## 7. Geography and boundaries

### 7.1 `geography_silver` (`geography_silver_qc.py`)

Checks one PSGC snapshot: `psgc.version` in the YAML (Q2_2024), and the single bronze batch silver holds for it. Both tables are read at one fixed Delta version, so every check sees the same data.

| Code | Check | Severity | Fails when |
|---|---|---|---|
| GS01 | Snapshot exists and has rows | FAIL | Bronze or silver has no rows for the snapshot |
| GS02 | Required fields complete | FAIL | `psgc_code`, `area_name`, `source_version`, `content_checksum`, `batch_id` or `silver_processed_at` is null or blank |
| GS03 | Logical key unique | FAIL | `psgc_code + content_checksum` repeats |
| GS04 | Non-null levels accepted | FAIL | A level is not in `psgc.silver_qc.accepted_geographic_levels` (Reg, Prov, City, Mun, SubMun, Bgy) |
| GS05 | Bronze to silver rows reconcile | FAIL | Bronze snapshot rows ≠ silver snapshot rows |
| GS06 | Hierarchy components reconstruct the code | WARN | Region, province and municipality parts don't rebuild the code |
| GS07 | PSGC code is 10 digits | FAIL | Any code that is not 10 digits (population S55, boundaries and facilities read levels from fixed positions) |
| GS08 | Null-level codes are the documented placeholders | WARN | The null-level codes differ from `psgc.silver_qc.null_level_codes` (`0990100000`, `1999900000`) |

### 7.2 `admin_boundaries_silver` (`admin_boundaries_silver_qc.py`)

Checks one HDX version and its batch against bronze and the PSGC snapshot it was matched to.

| Code | Check | Severity | Fails when |
|---|---|---|---|
| AS01 | Snapshot exists and has rows | FAIL | Bronze or silver has no rows for the version |
| AS02 | Required fields complete | FAIL | A required field is null (`psgc_code` excluded: special structures keep a null code) |
| AS03 | Logical key unique | FAIL | `admin_level + boundary_pcode + source_version` repeats |
| AS04 | Admin and geometry values accepted | FAIL | Level not in `hdx_phl_admin.required_levels` (1/2/3), or geometry not in `silver_qc.accepted_geometry_types` (Polygon, MultiPolygon) |
| ASB05 | Boundary total rows reconcile | FAIL | Bronze features ≠ silver boundaries |
| AS07 | Spatial attributes valid | FAIL | Area ≤ 0, latitude outside −90..90, longitude outside −180..180 |
| AS08 | PSGC match status and special structures valid | FAIL | Unknown match status, or a null code on a boundary that is not a documented special structure (`silver_qc.special_structures`) |
| AS09 | PSGC reference snapshot and level valid | FAIL | The recorded PSGC snapshot is gone, or a code sits at the wrong level |

## 8. Population (`psgc_population_silver_qc.py`)

Table `population_silver`: one row per `psgc_code × population_year × source_version`. Settings come from `psgc_population.silver_qc` in `sources_population.yaml`: census years 2015, 2020 and 2024, and the national control totals.

| Code | Check | Severity | Fails when |
|---|---|---|---|
| S01–S03 | Exists, key not null, key unique | FAIL | See section 6 |
| S04 | PSGC code found in geography | WARN | A code is not in geography silver |
| S06 | Counts non-negative | FAIL | A population is below 0 |
| S08 | Period within expected range | FAIL | A year before 1900 (before the first census, 1903) or after the current year |
| S09 | Bronze to silver rows reconcile | FAIL | Population entries unpacked from bronze ≠ silver rows (matched on area, year and version), or a parse status outside the approved list |
| S51 | Lineage columns not null | FAIL | `source_version`, `content_checksum`, `batch_id` or `silver_processed_at` is null |
| S52 | Population filled exactly when valid | FAIL | Population is null on a `VALID` / `VALID_WITH_NOTE` row or filled on another; `VALID_WITH_NOTE` without a moved note |
| S53 | Rows without a usable population | WARN | `MISSING` or `INVALID` rows (listed) |
| S54 | Every area has every census year | WARN | A geography area without a row for a census year |
| S55 | Area total = its cities and municipalities | WARN | A province or region total differs from the sum of its parts |
| S56 | National total matches the PSA release | WARN (FAIL once `confirmed: true`) | National total differs from the YAML control by more than 0.1% |
| S57 | One snapshot from the current PSGC release | WARN | More than one snapshot, or a release other than geography silver's |
| S58 | Change between census years above 30% | WARN | A province, city or municipality changed more than 30% |
| S59 | Years are the configured census years | FAIL | The table holds a year that `census_years` doesn't list, so a new census can't slip past S54 and S56 |

**Expected WARNs:** S54 / S56 (Negros Island Region has no 2015 or 2020 region rows; Sulu has no 2024 rows); S55 (Maguindanao del Norte 2015 and 2020, Benguet 2015, and the regions changed by the NIR and BARMM regrouping). S56 stays WARN until the controls are confirmed.

## 9. Diseases (`diseases_silver_qc.py`)

Tables: **M** metric, **A** deaths by age, **E** hospital encounters (restricted), **C** source coverage, **T** TB programme, **H** hospital claims (restricted).

Grain keys (S02, S03):

| Table | Key |
|---|---|
| M | `disease_key, area_key, period_grain, period_key, measure, _source_key` |
| A | `disease_key, area_key, year, age_group, _source_key` |
| E | `_source_key, _source_file, _source_sheet, _source_row_num` |
| C | `_source_key, disease_scope, geo_level, period_grain, year` |
| T | `indicator, drug_resistance, area_key, year, age_group, sex, _source_key` |
| H | `year, facility_name_norm, area_key, disease_key, claim_status, _source_key` |

| Code | Check | Sev. | Tables | Fails when |
|---|---|---|---|---|
| S01–S03 | Exists, key not null, key unique | FAIL | all | See section 6 |
| S06 | Counts non-negative | FAIL | M A T H | `value`, `deaths`, `claims_count` or `claims_amount_php` below 0 |
| S08 | Period within expected range | FAIL | M T H | Year below the floor (M 2000, T 2015, H 2016) or after the current year. M also: year key not `yyyy`, month key not `yyyy-Mmm`, week not a 7-day ISO week whose week and year are those of `period_end` (`iso_week` key `yyyy-Www`; `iso_week_ending_date` key = `period_end`) (D-44, D-46) |
| S09 | Bronze to silver rows reconcile | FAIL | M A E T H | Per bronze table and source (TB programme reads two bronze tables with the same source key) |
| S10 | Metric totals preserved | FAIL | M H | M: DOH FOI cases and deaths, UP NOAH cases, PSA region deaths, silver sum vs bronze sum. H: claims count and amount, silver + quarantined rows = bronze |
| S12 | Null rate under threshold | WARN | M A T H | M and A: null values above 5%. T: no-report cells per indicator above 10%. H: share of claims at hospitals with no `facility_key` above 10% |
| S30 | Lineage columns not null | FAIL | M A E T H | `_silver_build_id`, `_source_key`, `_source_file`, `_source_row_num`, `_as_of_date` (plus `_metric_source_columns`, and `_source_sheet` where required) |
| S31 | Each lineage reference has one build input | FAIL | M A E T H | A file or sheet the rows point to without exactly one `build_inputs` row |
| S32 | Written by one succeeded build | FAIL | all | More than one build id, or `build_log` doesn't show one succeeded build with this row count |
| S33 | Built from the current bronze loads | FAIL | M A E T H | Bronze has a new, removed or reloaded file or sheet since the build: **rebuild silver** |
| S34 | Control values match | FAIL | M T H | A published figure from `sources_diseases.yaml` differs (M: DOH FOI dengue per year, PSA monthly deaths, FHSIS TB; T: Philippines TPT and treatment success per year; H: claims filed per year, silver + quarantined) |
| S35 | Modelled value within its bounds | FAIL | M | An IHME row where not `value_lower ≤ value ≤ value_upper` |
| S36 | Value, status and definitions consistent | FAIL | M E T H | Value null while status `ok` (or the reverse); definition, unit, basis or level missing; T: a count with decimals; E: occupancy eligibility vs date status; H: claim status, ownership, flags or facility match outside the rules |
| S37 | Disease and area keys resolve | FAIL | M A T H | `disease_key` not in the directory, or an area key outside `psgc:<10 digits>`, `ph`, `foreign`, `hist:…` (H: city or municipality only) |
| S38 | Aggregation set sums to all causes | FAIL | M | The members of an approved aggregation set don't add up to `all_causes` where it's published |
| S39 | Aggregation set members don't overlap | FAIL | M | A member's parent or grandparent is also in the set |
| S40 | Months sum to the published year total | WARN | M | PSA monthly: 12 months ≠ the Total column |
| S41 | Country = regions + foreign | WARN | M | PSA region table: regions + foreign ≠ Philippines |
| S42 | National totals agree between PSA tables | WARN | M | Monthly table and region table differ for the same cause and year |
| S43 | Weekly series has no gaps | WARN | M | HDX dengue: an area whose weekly dates are not all 7 days apart |
| S44 | Dengue sources agree on a common basis | WARN | M | DOH FOI vs UP NOAH annual cases differ by more than 10% in a region, on the complete years both hold (from the coverage table; regions VI, VII and NIR compared as one) |
| S45 | Quarantined rows are the reviewed kind only | FAIL | M T H | A quarantined row with any reason other than the reviewed one: M `area_unresolved` (FHSIS TB special area), T `psgc_not_in_geography`, H `illness_missing` |
| S46 | Age groups sum to the metric total | FAIL | A | A cause, area and year without exactly 20 age groups, or a sum ≠ the metric table total |
| S47 | Hospital encounter review flags | WARN | E | Counts of rows with a date problem, long stay (`long_stay_days`), inconsistent death fields, unresolved patient location, or unknown age |
| S48 | Coverage table matches the metric table | FAIL | C | Sources, levels, grains, years or period counts differ: rerun `04` after `01` |
| S49 | Mapped area codes exist in geography | FAIL | M A H | A code from `diseases_area_map` not in the latest geography snapshot, or at another level: rerun the reference maps, then `00`–`04` |
| S50 | Source-printed codes agree with geography | WARN | M T | Same test for FHSIS TB, which prints its own codes |

**Expected WARNs:** S40–S44 (source disagreements), S47 (review flags on encounters), S12 on claims if the facility match share drops, S50 for FHSIS special-area codes.

## 10. Facilities (`facilities_silver_qc.py`)

Tables: **R** registry, **I** id map, **M** metric, **B** bed occupancy (restricted), **O** OSM points.

| Code | Check | Sev. | Tables | Fails when |
|---|---|---|---|---|
| S01–S03 | Exists, key not null, key unique | FAIL | all | Keys: R `facility_key`; I `_source_key, source_record_id`; M `area_key, year, ownership, _source_key`; B source row; O `osm_type, osm_id` |
| S04 | PSGC code found in geography | WARN | R M B O | A code is not in the latest snapshot |
| S05 | Admin level valid | FAIL | R M B O | R and O: not a city / municipality (R also Manila district, SubMun). M: region, province, city or municipality, or a named key (`ph`, `hist:`, `sga:`). B: province, city or municipality, or `hist:` / `ncr-district:` |
| S06 | Counts non-negative | FAIL | R M B O | Beds, stations or counts below 0 (B: a negative BOR passes only when excluded as `bor_negative`) |
| S08 | Year within the source's range | FAIL | M B | M: before 1990 or after the current year (FHSIS before 2018). B: a year not in `bor_expected_sheets` |
| S09 | Bronze to silver rows reconcile | FAIL | R M B O | Per source. HDX Healthsites is compared with its newest file only |
| S11 | Accepted values | WARN | all | R: category, match method, beds basis, status, ownership, resolution method. I: match status and method, source key. M: ownership, series definition, area key, `is_break_year` only in `hospital_definition_break_year`. B: sharing, ownership, service level, exclusion reason, bed basis, hospital type. O: precision vs coordinates, points inside `ph_bbox`, resolution method, open licence |
| S13 | Lineage columns not null | FAIL | all | A lineage column is null (I: HFSRB identifiers without a sheet) |
| S14 | Each file or sheet referenced has one build input | FAIL | I M B O + R | See S31 |
| S15 | Table written by the latest succeeded build | FAIL | all | Row count ≠ `build_log`, or rows from an earlier build where not allowed (R: only `not_listed` facilities; I: carried identifiers) |
| S16 | Built from the current bronze loads and reference versions | FAIL (WARN) | all | Bronze file, sheet or load time changed; geography snapshot changed; a reference table changed version **and** row count. Same row count, new version is WARN |
| S17 | One load time and one ingestion-log row per input | FAIL | all | A file or sheet with more than one load time, or not exactly one processed `ingestion_metadata` row |
| S18 | NHFR id in at most one facility | FAIL | R | An NHFR id on two facilities |
| S19 | Registry lineage groups follow `in_nhfr` / `in_hfsrb` | FAIL | R | A side's lineage filled when that side didn't contribute, or empty when it did |
| S20 | Every metric source key has a lineage group | FAIL | R M | A key in `_metric_source_columns` with no group (R) or not a measure column (M) |
| S21 | Control totals match | FAIL (WARN on a new file) | R B | NHFR facilities, NHFR beds (registry, current build only) and bed occupancy rows ≠ `sources_facilities.yaml`. A new file checksum gives WARN: check the value, then update the YAML |
| S22 | Id map and registry keys agree | FAIL | I | An id map key not in the registry, or a facility without an identifier |
| S23 | Bed columns follow their definitions | FAIL | R | `authorized_beds` ≠ HFSRB ABC, `analysis_beds` ≠ ABC else NHFR beds, or the basis names the wrong side |
| S24 | Bed occupancy eligibility follows the named rules | FAIL | B | `baseline_eligible` ≠ no exclusion reason; a reason that doesn't match the data (`bor_null`, `bor_gt_150` above `bor_baseline_max`, `level_missing`); `is_bor_over_100` wrong |
| S25 | BOR above 100% | WARN | B | Rows with BOR above 100, listed by year and band (100 to the baseline max, above it) |
| S26 | FHSIS region = its provinces + listed cities | WARN | M | Barangay health stations or barangays of a region ≠ the sum of its parts, where all parts are reported |
| S27 | OSM points placed by city tag only, or tag disagrees | WARN | O | Points placed by `addr:city` (no coordinates), or `addr:city` conflicts with the coordinates |
| S28 | Quarantined bronze rows | WARN | R M B O | Any quarantined row, listed by reason (copied to `quality.quarantine`, never for B) |

**Not covered:** "a rerun gives the same rows" (needs a second build), S10 and S12.

**Expected WARNs:** S28 (quarantined rows), S26 (FHSIS NCR 2025), S25 (BOR above 100%), S11 / S27 (OSM points placed by `addr:city`), S16 WARN after a reference table rerun with the same rows.

## 11. Workforce (`workforce_silver_qc.py`)

Tables: **H** headcount, **D** area denominator, **P** PSMO specialist.

| Code | Check | Sev. | Tables | Fails when |
|---|---|---|---|---|
| S01–S03 | Exists, key not null, key unique | FAIL | all | Keys: H `_source_key, area_key, year, profession`; D `_source_key, area_key, year`; P `_source_key, snapshot_date, area_label_source` |
| S06 | Counts non-negative | FAIL | all | A headcount, population, household or listing count below 0 |
| S08 | Period within expected range | FAIL | H D | H: FHSIS year not in `fhsis_years`, PSA year not in `psa_years`. D: year not in the population years of `denominator_sheets` |
| S09 | Bronze to silver rows reconcile | FAIL | all | Per source. D counts population and households rows; its sheet scope comes from `denominator_sheets` |
| S60 | Lineage columns not null | FAIL | all | A lineage column is null (FHSIS also needs the sheet) |
| S61 | Each lineage reference has one build input | FAIL | all | D checks both the population and households sheets |
| S62 | Written by one succeeded build | FAIL | all | See S32 |
| S63 | Built from the current bronze loads and reference versions | FAIL (WARN) | all | Bronze or geography snapshot changed, or a reference table changed version and row count. Same rows, new version: WARN |
| S64 | National control values match | FAIL | H | Philippines totals per year and profession ≠ `qc.control_values` (FHSIS and PSA) |
| S65 | Area control values match | FAIL | H | Area totals ≠ `doh_fhsis_demographic.silver_qc.area_controls` |
| S66 | Accepted values | FAIL | all | H: profession not in `professions`, level, split basis, source role, cell statuses, area key format. D: population and households status, level. P: count status, `count_unit = unconfirmed`, level, composite areas with component codes |
| S67 | Eligibility follows the named rules | FAIL | H | Excluded row without a reason or label; eligible row with a reason or a status other than `ok`; a `reporting_inconsistency` rule not in `eligibility_rule_ids` |
| S68 | Totals equal their components | WARN | H | National ≠ sum of regions; region ≠ its listed rows (uncoded files) or its child areas (coded years); only groups where every part is `ok` |
| S69 | Splits add up to the total | WARN | H | Sex or employer split ≠ total |
| S70 | 2025 province vs its municipalities and cities | WARN | H | Rows flagged `province_vs_municipality_sum` in the coded years |
| S71 | PSA and FHSIS national totals agree | WARN | H | National totals differ in the years both sources hold (derived; listed in the detail) |
| S72 | Province change above 50% outside break years | WARN | H | Rows flagged `large_change` |
| S73 | Quarantined bronze rows | WARN | H | Any quarantined row (blank area label, code not in geography), copied to `quality.quarantine` |
| S74 | Denominator lineage groups follow source contribution | FAIL | D | A side's lineage filled when the side didn't contribute (or the reverse), or households outside `households_years` |
| S75 | Every metric source key has a lineage group | FAIL | D | A key other than `reported_population` / `household_estimates` |
| S76 | Population agrees across sheets of one workbook | WARN | D | Population printed on another sheet of the same workbook differs by more than 0.5 |
| S77 | PSMO label matched to a city by name | WARN | P | A label matched to a city by name, with no "City" in it |
| S78 | Listed oncologist control total | FAIL | P | Sum of listings ≠ the PSMO control in the YAML (a sum of listings, not unique people) |
| S79 | Area label overrides not reviewed | WARN | H | Overrides with status `proposed` or `rejected` |

Workforce PSGC codes are checked by the cross-domain script (S04), because this script has no geography check.

**Expected WARNs:** S68–S72 (source consistency), S73 (8 blank-label rows; the Zamboanga Sibugay 2025 row with a wrong printed code is resolved by a row override from 2026-10-20), S76, S77, S79 (labels under review).

## 12. Socioeconomic (`socioeconomic_silver_qc.py`)

Tables: **V** poverty, **S** expenditure share, **C** per capita expenditure, **K** child mortality.

| Code | Check | Sev. | Tables | Fails when |
|---|---|---|---|---|
| S01–S03 | Exists, key not null, key unique | FAIL | all | Keys: V `area_key, year`; S `financing_agent, year`; C `year`; K `characteristic_group, characteristic, survey_year` |
| S04 | PSGC code found in geography | WARN | V | A poverty code not in the latest snapshot (WARN "not validated" if geography is missing; never a PASS) |
| S07 | Rates within range | WARN | V C K | V: estimate outside its confidence limits. C: growth outside −50% to 50%. K: under-five mortality below infant mortality |
| S08 | Period within expected range | FAIL | all | A year not in the build's `poverty_years`, `share_years`, `per_capita_years` or `mortality_survey_years` |
| S09 | Bronze to silver rows reconcile | FAIL | all | See section 6; any disposition other than `dropped_non_data` also fails |
| S10 | Metric totals preserved | FAIL | V S K | V: incidence, and poor population × 1,000. S: shares (`a/` counted as 0). K: three rates, every survey |
| S80 | Lineage columns not null | FAIL | all | A lineage column is null |
| S81 | Each lineage reference has one build input | FAIL | all | See S31 |
| S82 | Written by one succeeded build | FAIL | all | See S32 |
| S83 | Built from the current bronze loads and reference tables | FAIL | all | Bronze changed, or (V) the poverty area map changed row count or version |
| S84 | Control values match | FAIL | all | A `qc.control_values` item with a `silver:` block differs |
| S85 | Build inputs carry a load id and file checksum | WARN | all | A bronze input without them |
| S86 | Measure within its hard limits | FAIL | all | Incidence outside 0–100, threshold ≤ 0, negative CV, SE or population; share outside 0–100; per capita ≤ 0; negative mortality rate |
| S87 | Value agrees with its flag or status | FAIL | all | V: missing measure, below-threshold flag without a zero, precision vs CV (`use_with_caution` above `poverty_cv_caution_pct`), basis not population or full year. S: `is_below_0_05` without a zero. C: missing measure, wrong growth period. K: null rate not `suppressed`, reliability outside its three values |
| S88 | Expected rows present, no others | FAIL | all | V: area-years ≠ the area map from each area's `first_estimate_year`. S: agents ≠ `share_agent_count`, or an agent missing a year. C: rows ≠ `per_capita_years`. K: characteristics per group ≠ `characteristics_by_group`, or one missing a survey |
| S89 | Metric source columns complete and valid | FAIL | all | `_metric_source_columns` keys ≠ the table's metric columns |
| S90 | Area attributes match the area map | FAIL | V | Area not in the map, an attribute differs from the map, a superseded area marked eligible, or a bad area key |
| S91 | Level-1 shares sum to the total | FAIL | S | Total ≠ 100, or level-1 sum differs from the total by more than `share_level1_tolerance_pct` |
| S92 | Financing agent hierarchy resolves | FAIL | S | Not exactly one total, a level outside 0–3, or a parent not one level above |
| S93 | PSGC code unique in geography, same level | FAIL | V | A code twice in geography, on a row with no level, or at another level |
| S94 | Incidence fell by more than 15 points, or reached zero | WARN | V | Listed for review (decision D4) |
| S95 | Rows not eligible for comparison with PSGC data | WARN | V | Areas with `comparison_eligible = false`, counted by reason (decision D2) |
| S96 | Definition not confirmed yet | WARN | K | `reference_period` is null (decision D7) |

**Expected WARNs:** S94, S95, S96 (all by design), S07 if a source value falls outside its band.

## 13. Cross-domain (`silver_cross_domain_qc.py`)

| Code | Check | Severity | Rule |
|---|---|---|---|
| S29 | Quarantined rows within the limit | **Gate:** PASS at 0; WARN up to 5% or ≤ 10 rows; FAIL above both | Per silver table and source, latest succeeded build, from `quality.v_build_reconciliation`. Geography and population are not covered (no `build_inputs`) |
| S04 | PSGC code found in geography | WARN | Distinct workforce codes (headcount, denominator) not in the latest geography snapshot |
| S08 | Period within expected range | FAIL | Any row dated after the current year, in every table with a year column |
| S97 | Ratio per population inside the plausible band | WARN | By region. Beds per 1,000 (registry `analysis_beds`, listed hospitals and infirmaries, latest census year): band 0.3–5.0. Doctors + nurses + midwives per 10,000 (FHSIS province and city rows, latest year in both FHSIS and the census): band 1–60 |
| S98 | Latest data year of each source is recent | WARN | Latest year older than `--max_age_years` (default 3), unless the source is in `HISTORICAL_SOURCES` |
| S99 | Reported population agrees with census | WARN | FHSIS population vs census for regions, cities and municipalities, every year both hold; above 10% is listed |

Years are derived at run time. Each detail names the years it used.

## 14. Latest recorded run

Run of 2026-10-20, after the workforce rebuild with the Zamboanga Sibugay override:

| Script | `validation_id` | Result |
|---|---|---|
| `workforce_silver_qc.py` | `5ddb4edc-a3c7-49f0-ab52-7214b1cba1c5` | 0 FAIL. WARN: S68, S69, S70, S72, S73, S77, S79 (all expected, section 11). Headcount 28,080 rows, denominator 3,024, specialist 52 |
| `silver_cross_domain_qc.py` | `14f27bc1-8c3f-48dd-aa5c-8a6faddd2ed4` | **68 checks, 0 FAIL, 10 WARN** |

Cross-domain WARNs, all expected:

| Check | Result | Reading |
|---|---|---|
| S29 × 8 | Quarantine below the limit: claims 1,404 of 245,405 (blank illness); FHSIS TB 18 of 3,493 (`area_unresolved`); TB programme 2 of 5,244 (`psgc_not_in_geography`); OSM 2 of 16,032 (outside every boundary); facilities 7 of 800, 12 of 614 and 21 of 1,180 (no place label, service of an existing facility, one place reviewed and unresolvable); workforce 8 of 4,999 (`area_label_missing`) | Documented set-asides ([reconciliation](reconciliation.md), section 4) |
| S98 | `hdx_dengue` latest 2021; `psa_deaths_national_annual` latest 2020 | Both sources stopped publishing; history, not staleness. Candidates for `HISTORICAL_SOURCES` |
| S99 | 11 of 171 area-years above 10% | Largest: regions VI and VII in 2024. FHSIS keeps the old regions; the 2024 census has the Negros Island Region. The rest are areas where FHSIS prints its own population figure |

Passed: S04 for workforce (0 of 1,743 codes missing from geography), S08 everywhere, S97 for both ratios (beds on census 2024; health workers on FHSIS and census 2024).

The previous run (2026-10-19, `e56cdd87-64bd-4686-9f32-74ff95622ed6`, 11 WARN) had one more S29 WARN: the Zamboanga Sibugay 2025 row, printed `0908001000`, quarantined in headcount (9 rows) and denominator (1 row). A row override to `0908300000` (`accepted`) resolved it.

The full results of every run go to [`06-evidence/`](../../06-evidence/README.md). How to read them: [quality results and evidence](../quality/quality-results.md).

## 15. Reading the results

**Latest result of every silver check:**

```sql
SELECT table_name, source_key, check_id, check_name, status, fail_count, total_count,
       observed, expected, detail, executed_at
FROM public_health.quality.qc_results
WHERE layer = 'silver'
QUALIFY row_number() OVER (PARTITION BY table_name, source_key, check_id, column_name, detail
                           ORDER BY executed_at DESC) = 1
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, table_name, check_id;
```

**Summary of the last run of each script:**

```sql
SELECT script_name, status, checks_total, checks_pass, checks_warn, checks_fail,
       started_at, ended_at, validation_id
FROM public_health.quality.run_log
WHERE layer = 'silver'
QUALIFY row_number() OVER (PARTITION BY script_name ORDER BY started_at DESC) = 1
ORDER BY script_name;
```

**The settings a QC run read (from the build):**

```sql
SELECT target_table, build_id, finished_at, parameters
FROM public_health.quality.build_log
WHERE layer = 'silver' AND status = 'succeeded'
QUALIFY row_number() OVER (PARTITION BY target_table ORDER BY finished_at DESC) = 1;
```

## 16. When a check fails

| Result | Likely cause | Do |
|---|---|---|
| S00 FAIL "did not record `<key>`" | The table was built before 2026-10-19 | Rerun that table's build file (workforce: `01` first), then its QC |
| S00 FAIL on a control | A control is missing from `sources_<domain>.yaml` | Restore the YAML item with its `silver:` block |
| S33 / S16 / S63 / S83 FAIL | Bronze loaded a new or reloaded file after the silver build | Rebuild the domain's silver, then rerun QC |
| S09 FAIL | Bronze changed since the build, or rows are unaccounted | Rebuild. If it persists, compare `row_disposition` with bronze for that source ([reconciliation](reconciliation.md)) |
| Control FAIL (S21, S34, S64, S65, S78, S84) | The source file changed, or a transform error | Check bronze B11 first. If bronze passes and silver fails, the transform is wrong. For S21 WARN (new file), confirm the value and update the YAML |
| S45 FAIL | A new kind of quarantined row | Read the reasons in `row_disposition`; decide whether it is a new rule or a bug |
| S29 FAIL | More than 5% and more than 10 rows of a source set aside | Read the reasons in the S29 detail; fix the map, exception or rule before gold runs |
| S49 FAIL | The area map is older than geography silver | Rerun the reference maps, then diseases `00`–`04` |
| S59 FAIL | A new census year in the PSGC payload | Add the year to `census_years` and its control to `control_totals`, then rerun |
| WARN | Source gap or disagreement | Compare with the expected WARNs on this page; anything new goes to the backlog |

## 17. Limitations

- `strict_registry` is off. Codes missing from `quality.check_registry` still run and are reported as unregistered. The domain codes must be in `quality_registry_seed.sql` before it is switched on.
- A rerun that gives the same rows (idempotency) is not checked automatically for the observation tables. Geography and boundaries show it as 0 inserts and 0 updates on a rerun.
- S29 does not cover geography, boundaries and population, which are not built through `build_inputs`. Their row checks are GS05, ASB05 and S09.
- Restricted tables have no profile and no quarantine copy, so a reviewer reads their set-aside rows in silver, under the access rules of D-47.
- S97 bands, S99 tolerance and S29 limits are team policy, not agency figures. They were set on the first runs and may need tuning when sources change.

## 18. History of updates

| Date | Change |
|---|---|
| 2026-10-12 | Population codes S51–S58; facilities QC reviewed before the first Databricks run |
| 2026-10-14 | S29 Healthsites override removed; OSM newest file only; S98 tables added |
| 2026-10-19 | Rule 2a: controls from the YAML, settings from `build_log.parameters`; GS07, GS08 and S59 added; S08 ceilings are the current year; S08 checks ISO weeks (D-44, D-46); cross-domain years derived |
| 2026-10-19 | Page written |
| 2026-10-20 | Workforce: Zamboanga Sibugay 2025 row override (S29, S73); latest run updated (68 checks, 0 FAIL, 10 WARN) |
