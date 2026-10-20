# Silver — diseases

Disease burden from eight public sources, plus TB programme data and two restricted hospital tables. Every count keeps its source, area, period and definition, so gold can compare like with like and never add things that should not be added.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.2. Back to the [silver overview](README.md).

## Sources

| Source | What it gives | Notes |
|---|---|---|
| DOH FOI dengue | Dengue cases and deaths by region and year | 2025 holds January to September only |
| UP NOAH dengue | Regional dengue counts by ISO week | DOH-EB counts by ISO week, not approximations (D-46) |
| HDX dengue | Provincial dengue counts by week | Each date closes its week (D-44) |
| PSA deaths (3 tables) | Registered deaths by cause, national monthly and by region | `location_basis = usual_residence` |
| DOH FHSIS TB | TB notifications, and the 2025 TPT and treatment success sheets | Rows carry their own PSGC code |
| IHME GBD 2023 | Modelled estimates with lower and upper bounds | Licence: non-commercial, no redistribution |
| Hospital extract (Davao) | De-identified hospital encounters | Restricted |
| PhilHealth FOI release | Hospital claims by case-rate package | Restricted |

Settings: `config/sources_diseases.yaml`, including the control values QC checks (`silver:` blocks on `qc.control_values`).

## Tables

| Table | One row is | Rows (last build) |
|---|---|---|
| `diseases_metric_silver` | One measure of one disease in one area and period, from one source | 131,887 |
| `diseases_deaths_age_silver` | One cause, area, year and age group (20 age groups) | 90,480 |
| `diseases_tb_programme_silver` | One TB programme count per area, year, age and sex | 73,216 |
| `diseases_source_coverage_silver` | One source, disease scope, level, grain and year: how complete the data is | 73 |
| `diseases_hospital_encounters_silver` | One de-identified hospital encounter (restricted) | 25,924 |
| `diseases_hospital_claims_silver` | One hospital, admission year, package and claim status (restricted) | 243,881 |
| `diseases_directory_silver` | One disease in the directory (becomes `dim_disease` in gold) | from the reference CSV |

Live counts: `quality.build_log.row_count` of the latest succeeded build.

## How it is built

| Step | File | What happens |
|---|---|---|
| Reference load | `00` | Area map, cause map, disease directory and cause aggregation; every code checked against geography |
| Metrics | `01` | Area and cause maps joined **before** reshaping, so a join cannot multiply a bronze row. Months, cases and deaths, and IHME bounds become rows. Each value gets a `value_status`. Known repeats become `duplicate_of` (252 HDX rows, 820 IHME neoplasm rows); 18 FHSIS TB rows of the Special Geographic Area are quarantined |
| Deaths by age | `02` | Each PSA region row becomes 20 age-group rows |
| Hospital encounters | `03` | Encounter id, barangay, amounts and exact age dropped; length-of-stay flag from a named setting; patient area mapped. Gold does not read this table |
| Coverage | `04` | From the published metric table: periods expected (1, 12, or 52 / 53 ISO weeks), periods present, complete years, missing periods |
| TB programme | `05` | FHSIS 2025 TPT and treatment success sheets; the printed percentages are not loaded (gold recomputes them) |
| Hospital claims | `06` | 1,404 rows with a blank illness quarantined; 120 repeats summed (`merged_into`); area from the province and municipality pair map; hospital → `facility_key` by a three-step name match (5.3% of claims unmatched); yearly totals equal the YAML controls |

**Weekly periods** (D-44, D-46):

| Source | `period_basis` | Period | Year and week |
|---|---|---|---|
| HDX dengue | `iso_week_ending_date` | The date and the 6 days before it (the date is always a Sunday) | ISO year and week of the date |
| UP NOAH | `iso_week` | Monday to Sunday of that ISO week | ISO year and week as published |

A gate stops the build on any weekly row that is not a consistent ISO week. Edge weeks belong to their ISO year: the HDX week ending 2021-01-03 is 2020 week 53.

**Area keys:** `ph` (country), `psgc:<10 digits>`, `hist:maguindanao` (the undivided province, `is_superseded_area = true`), `foreign` (PSA usual residence abroad).

## Quality checks

Every check of this domain, with its rule and severity: [silver quality checks](silver-quality-checks.md#9-diseases-diseases_silver_qcpy).

`diseases_silver_qc.py`, codes S01–S12 and S30–S50. Highlights:

| Code | Check |
|---|---|
| S08 | Periods valid, including the ISO week rules |
| S09, S10 | Bronze rows reconcile; totals preserved |
| S30–S32 | Lineage filled and traceable to one build input |
| S33 | Silver was built from the bronze loads that are there now |
| S34 | Control values from the YAML match |
| S40–S44 | Sources agree where they overlap |
| S45 | Quarantined rows are of a documented kind |
| S48 | The coverage table matches the metric table |
| S49, S50 | Codes exist in geography |

**Expected WARNs:** S43 (HDX weeks missing in the source: the week ending 2019-01-06 for all 126 areas, and one week in 2016, 2017 and 2020 for some provinces); S44 (3 of 48 region-years where DOH FOI and UP NOAH differ); S47 (hospital review counts).

## Rules for users

- Counts only (`value_unit = count`). Rates are computed in gold.
- Never add across `_source_key`, `geo_level`, `period_grain`, `value_type` or `measure_definition`, or a cause and its sub-causes. Use `diseases_cause_aggregation` to add causes.
- `location_basis` says what the area means: usual residence (PSA), reporting unit (FHSIS), modelled population (IHME), facility location (claims), patient origin (hospital).
- Read `diseases_source_coverage_silver` before comparing years: DOH FOI 2025 holds January to September only.
- Series breaks are flags, not fixes: claims 2020–2021 (COVID), 2024 amounts, IHD with MI from 2025.

## Limitations

- The week convention is a team decision verified on the data, not confirmed by the providers.
- Geographic coverage of IHME and HDX is not confirmed.
- 18 FHSIS TB rows of the Special Geographic Area are quarantined, and some claims area pairs are marked for review; see the backlog.
- A second PhilHealth release would stop build `06` (it accepts one claims file); that path is not designed yet.
