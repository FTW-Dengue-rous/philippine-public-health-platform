# Silver layer (`src/03_silver`)

The silver layer turns the raw bronze files into clean, typed tables. One row means one thing, and every area carries a PSGC code from one shared geography table. Sources stay side by side; nothing is guessed. A label that matches no rule is held back with a reason. Rates, rankings and the choice of preferred source are left to gold.

Use this guide to rebuild the layer, understand what each row represents, and know which rules gold must not redo. The shorter overview, one page per domain and the reconciliation method are in [`docs/04-pipeline/silver/`](../../docs/04-pipeline/silver/README.md).

| Setting | What you need to know |
|---|---|
| Catalog / schema | `public_health.silver` |
| Inputs | Bronze tables (`public_health.bronze`), `bronze.ingestion_metadata`, reviewed reference CSVs. Silver never reads landing files directly, except the reference CSVs |
| Table build pattern | Write a candidate, gate it, then publish it (write-audit-publish). A failed gate stops the build and leaves the published table untouched |
| Rebuild strategy | Observation tables are rebuilt in full on every run, by decision (D-57). See [rebuild strategy](../../docs/04-pipeline/silver/rebuild-strategy.md) |
| Lineage | Lineage contract v1.3: 7 lineage columns per row, load ids and checksums once per build in `quality.build_inputs` |
| Checks after the build | One QC script per domain (`src/05_quality/silver/<domain>_silver_qc.py`), then `silver_cross_domain_qc.py`. Any FAIL stops the job before gold. See [section 7](#7-quality) |
| Before silver | Bronze QC and the preload gate `bronze_gate.py --domains <domain>` (one job task per domain) |

If you are rebuilding silver, start with section 1. If you are reading silver tables in gold or a query, read section 6 first. Section 9 lists what to rerun after a change and how to recover from a failed build.

Status date: 2026-10-19.

---

## 1. Folder layout and run order

```
src/03_silver/
├── geography/
│   ├── geography_silver.py               PSGC codes, names, levels (the spine)
│   ├── psgc_population_silver.py         census population 2015 / 2020 / 2024
│   └── admin_boundaries_silver.py        HDX COD-AB polygons ADM1–3
├── diseases/
│   ├── diseases_silver_00_reference.sql
│   ├── diseases_silver_01_metric.sql
│   ├── diseases_silver_02_deaths_age.sql
│   ├── diseases_silver_03_hospital_encounters.sql
│   ├── diseases_silver_04_source_coverage.sql
│   ├── diseases_silver_05_tb_programme.sql
│   └── diseases_silver_06_hospital_claims.sql
├── facilities/
│   ├── facilities_silver_00a_area_boundary.sql
│   ├── facilities_silver_00_reference.sql
│   ├── facilities_silver_01_registry.sql
│   ├── facilities_silver_02_metric.sql
│   ├── facilities_silver_03_bed_occupancy.sql
│   ├── facilities_silver_04a_osm_locate.py   (point-in-polygon, needs shapely)
│   └── facilities_silver_04_osm_point.sql
├── workforce/
│   ├── workforce_silver_00_reference.sql
│   ├── workforce_silver_01_fhsis_areas.sql   (staging: resolves every FHSIS label once)
│   ├── workforce_silver_02_headcount.sql
│   ├── workforce_silver_03_denominator.sql
│   └── workforce_silver_04_specialist.sql
└── socioeconomic/
    ├── socioeconomic_silver_00_reference.sql
    ├── socioeconomic_silver_01_poverty.sql
    ├── socioeconomic_silver_02_health_expenditure_share.sql
    ├── socioeconomic_silver_03_health_expenditure_per_capita.sql
    ├── socioeconomic_silver_04_child_mortality.sql
    └── socioeconomic_silver_05_poverty_geography_check.sql

src/05_quality/silver/      <domain>_silver_qc.py, psgc_population_silver_qc.py,
                            geography_silver_qc.py, admin_boundaries_silver_qc.py,
                            silver_cross_domain_qc.py
builders/                   build_diseases_reference_maps.py, build_facilities_area_exceptions.py,
                            build_workforce_area_exceptions.py, build_socioeconomic_poverty_area_map.py
config/reference/<domain>/  reviewed reference CSVs (repo copy)
```

Within a domain the number in the file name is the run order. `00` loads the reference CSVs; the builds follow. SQL files run as `sql_task` on the SQL warehouse; `.py` files run as Python tasks on serverless compute.

### Job order (from `resources/ph_public_health_job.yml`)

A task waits for the tables it reads **and** the QC of those tables, so a failing QC stops everything downstream.

| Task | Must run after | Why |
|---|---|---|
| `silver_geography` | `gate_geography` | Bronze PSGC snapshot cleared |
| `qc_silver_geography` | `silver_geography` | Gates every task that reads `geography_silver` |
| `silver_psgc_population` → `qc_silver_psgc_population` | `qc_silver_geography` | Same PSGC payload as geography (S57) |
| `silver_admin_boundaries` → `qc_silver_admin_boundaries` | `gate_admin_boundaries`, `qc_silver_geography` | Matches boundaries to PSGC codes |
| facilities `00a` | `qc_silver_geography`, `qc_silver_admin_boundaries` | Polygons per city / municipality |
| facilities `00` → `01`, `02`, `03` | `gate_facilities`, `qc_silver_geography` | Exceptions are checked against the geography checksum |
| facilities `04a` → `04` | `00a` (and `00` for `04`) | OSM points need the polygons |
| `qc_silver_facilities_registry` | facilities `01` | Diseases `06` waits for this, not for OSM |
| `qc_silver_facilities_rest` | facilities `02`, `03`, `04` | |
| diseases `00` → `01`, `02`, `03`, `05` | `gate_diseases`, `qc_silver_geography` | Area map codes are checked against geography |
| diseases `04` | diseases `01` | Reads the published metric table |
| diseases `06` | diseases `00`, `qc_silver_facilities_registry` | Claims hospitals get a `facility_key` from the registry |
| `qc_silver_diseases` | diseases `02`–`06` | |
| workforce `00` → `01` → `02`, `03`; `00` → `04` | `gate_workforce`, `qc_silver_geography` | |
| `qc_silver_workforce` | workforce `02`, `03`, `04` | |
| socioeconomic `00` → `01` → `05`; `02`, `03`, `04` | `gate_socioeconomic` (`05` also `qc_silver_geography`) | Only `01` needs the area map |
| `qc_silver_socioeconomic` | socioeconomic `02`–`05` | |
| `qc_silver_cross_domain` | every silver QC task above | Last silver step; gold waits for it |

**Reference builders are not job tasks.** Run them by hand when a new file arrives, a geography snapshot changes or a rule changes (section 3).

---

## 2. How every build works

### 2.1 Write-audit-publish

Every observation build follows the same eight steps:

1. **Reference load (`00`).** Load the reviewed CSVs as text. Check duplicate keys, directory coverage, codes in geography and staleness (a CSV built from another geography snapshot or workbook stops the load).
2. **Capture inputs.** List every bronze file and sheet the build reads. Look each up in `ingestion_metadata` on source, path, sheet and `retrieved_at = _ingested_at`. Exactly one `processed` match, or the build stops.
3. **Classify every bronze row:** `data`, `non_data`, `duplicate`, `quarantined` or `unclassified`. An `unclassified` row fails a gate.
4. **Transform** in plain SQL: cast with a status per value (`try_cast`), unpivot wide to long, join reference maps **before** any unpivot (a join cannot multiply a bronze row), dedupe, combine sources, quarantine with a reason.
5. **Gates on the candidate:** one load per input, no unclassified rows, every area and cause resolves, codes exist in geography, every cell is a number or a documented marker, no negatives, key not null and unique, counts reconcile per source, control totals.
6. **Stop on failure:** insert a `failed` row in `quality.build_log`, then `raise_error`. The published table stays as it was; the staging tables (`__classified`, `__candidate`, `__gates`) stay for inspection; no `build_inputs` rows are written.
7. **Publish and record:** replace the table from `__candidate`, so the rows validated are the rows written. Append `build_log` (1 row), `build_inputs` (1 row per file, sheet or reference table read) and `row_disposition` (rows **not** loaded only: `dropped_non_data`, `duplicate_of`, `quarantined`, `merged_into`).
8. **QC** on the published table (section 7), keyed `batch_id = build:<build_id>`.

Build settings that the logic depends on (date formats, thresholds, series-break years) are named settings at the top of each file and are recorded in `build_log.parameters`.

### 2.2 Write pattern per table

| Pattern | Tables | Rerun on unchanged bronze |
|---|---|---|
| Full rebuild from a validated candidate | `population_silver`; diseases `01`–`06`; facilities `00a`, `02`, `03`, `04`; workforce `02`–`04`; socioeconomic `01`–`04` | Same rows; new `_silver_build_id` and `build_log` row; old version in Delta history |
| MERGE on a key | `geography_silver` (`psgc_code + content_checksum`), `admin_boundaries_silver` (delete the loaded `source_version`, insert-only MERGE) | 0 inserts, 0 updates |
| Rebuild with state carried forward | `facilities_id_map_silver`, `facilities_registry_silver` | Reads its previous version; `facility_key` reused; 0 business changes |

Full rebuild is deliberate at current volume (D-57): every gate sees the whole table, and a rule change such as D-44 reaches every row at once. The cost of rebuilding unchanged inputs, and the recommended fixes R0–R5, are in the [rebuild strategy](../../docs/04-pipeline/silver/rebuild-strategy.md).

### 2.3 Lineage (contract v1.3)

| On every silver row | Once per build |
|---|---|
| `_silver_build_id`, `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_metric_source_columns` (MAP, only where a row was unpivoted) | `build_inputs.ingested_at`, `load_batch_id`, `content_checksum`, input Delta version; `build_log.finished_at`, target Delta version, `parameters` |

- Rows combined from two sides keep one lineage group per side (`_nhfr_*` / `_hfsrb_*`, `_incidence_*` / `_magnitude_*`), filled exactly when that side contributed.
- Bronze rows carry no load id or checksum; the build looks them up once per input.
- **Reconciliation:** rows read per input = rows referenced by silver + rows in `row_disposition`. Method, checks and evidence queries: [reconciliation](../../docs/04-pipeline/silver/reconciliation.md).
- **Freshness:** current bronze inputs vs the inputs the latest succeeded build consumed (files added or removed, load time changed). QC S16 / S33 / S63 / S83 FAIL when they differ: rebuild silver.
- A dashboard number traces to a source cell in eight steps (contract Appendix A.7).

---

## 3. Reference CSVs and builders

Reviewed CSVs translate what a source says (a label, a cause name, a hospital id) into what the platform means (a PSGC code at a level, a `disease_key`). They are inputs, not data.

| Domain | CSVs (→ silver tables loaded by `00`) | Builder | Character |
|---|---|---|---|
| Diseases | `diseases_area_map`, `diseases_cause_map`, `diseases_directory` (→ `diseases_directory_silver`, becomes `dim_disease`), `diseases_cause_aggregation` | `build_diseases_reference_maps.py` | Full map of every label of every source; rule sequence per source; fuzzy rules marked `REVIEW` |
| Facilities | `facilities_area_exceptions`, `facilities_id_map_override`, `facilities_area_decisions` (record only) | `build_facilities_area_exceptions.py` | Exceptions only; named rule plus independent evidence; `review_status` auto / corroborated / needs_review / reviewed / rejected |
| Workforce | `workforce_area_exceptions`, `workforce_area_override`, `workforce_psmo_area_exceptions` | `build_workforce_area_exceptions.py` | Exceptions plus row overrides bound to the workbook checksum; unresolved labels go to a review CSV |
| Socioeconomic | `socioeconomic_poverty_area_map` | `build_socioeconomic_poverty_area_map.py` | One map with `geo_coverage_basis` and `comparison_eligible` |

Rules:

- **Generated, never hand-edited.** A manual decision is a row in the builder's decision table (with reviewer and date), changed by pull request. Review the CSV diff before committing.
- **One geography snapshot.** Builders read PSGC codes only from the latest `geography_silver` snapshot and check every code exists at the stated level; `00` checks again on load.
- **Stop, don't guess.** No matching rule, or a failed geography check: nothing is written.
- **Stale files stop the run:** facilities exceptions carry `geography_checksum`; workforce overrides carry the workbook `_content_checksum`.
- **Two copies:** the repo copy (`config/reference/<domain>/`, the reviewed record) and the Volume copy (`<landing_root>/reference/<domain>/`, what `00` reads). They are synced by hand; keep them identical.

---

## 4. Tables

Row counts are from the last Databricks builds (2026-10-14 to 2026-10-19). Live numbers: `quality.build_log.row_count`.

### 4.1 Geography and population (the spine)

`geography_silver` is the only table that may define a PSGC code. Every domain maps to it and is gated against it.

| Table | Grain / key | Rows | Build |
|---|---|---|---|
| `geography_silver` | One PSGC area in one snapshot. Key `psgc_code + content_checksum` | 43,762 (18 Reg, 82 Prov, 149 City incl. 33 HUC and 5 ICC, 1,493 Mun, 14 SubMun, 42,004 Bgy, 2 null-level) | `geography_silver.py`: lock one bronze snapshot (Q2_2024); trim and null-empty; repair `Ã±` → `ñ` (456 names, original kept in `area_name_raw`); no casting, no row dropped. Pre-write checks SG01–SG07 (SG07: code is 10 digits); MERGE |
| `population_silver` | One area in one census year. Key `psgc_code, population_year, source_version` | 127,945 | Unpivot the PSGC population columns to 2015 / 2020 / 2024. Status `VALID`, `VALID_WITH_NOTE` (a bracketed note moved to `population_note`), `MISSING`, `INVALID`. Never 0 for a missing value |
| `admin_boundaries_silver` | One HDX boundary in one source version. Key `admin_level, boundary_pcode, source_version` | 1,747 (ADM1 17, ADM2 88, ADM3 1,642) | Match to PSGC by code (with name agreement for cities and municipalities), then by name within parent, name and level, documented variants. AB01–AB07; delete-then-insert-only MERGE |

Rules: `0990100000` (placeholder "City of Isabela (Not a Province)") and `1999900000` (Special Geographic Area) stay as null-level rows and are never used as areas; Isabela City is `0990101000`. A HUC has its own 5-digit prefix, so its province cannot be read from the code (no HUC → province crosswalk in silver).

### 4.2 Diseases (`00`–`06`, SQL)

| Table | Grain / key | Rows | What the build does |
|---|---|---|---|
| `diseases_metric_silver` | One measure of one disease in one area and period from one source. Key `(disease_key, area_key, period_grain, period_key, measure, _source_key)` | 131,887 | 8 sources (DOH FOI dengue, UP NOAH, HDX dengue, PSA deaths ×3, FHSIS TB, IHME GBD). Area and cause maps joined before the unpivot; cast with `value_status`; 252 HDX repeats and 820 IHME neoplasm rows → `duplicate_of`; 18 FHSIS TB special-area rows quarantined (F9) |
| `diseases_deaths_age_silver` | One cause × area × year × age group. Key `(disease_key, area_key, year, age_group, _source_key)` | 90,480 | PSA region annual; each bronze row → 20 age groups |
| `diseases_hospital_encounters_silver` | One de-identified hospital encounter. Key: bronze row reference | 25,924 | **Restricted.** Encounter id, barangay, amounts and exact age dropped; stay and occupancy flags (`long_stay_days` setting); patient area mapped. Not read by gold |
| `diseases_source_coverage_silver` | One source × disease scope × level × grain × year. Key `(_source_key, disease_scope, geo_level, period_grain, year)` | 73 | From the published metric table: `periods_expected` (1, 12, or 52/53 ISO weeks), `periods_present`, `is_complete_year`, `missing_periods`, `areas_present`, `areas_complete` |
| `diseases_tb_programme_silver` | One TB programme count per area × year × age × sex. Key `(indicator, drug_resistance, area_key, year, age_group, sex, _source_key)` | 73,216 | FHSIS 2025 TPT and treatment success sheets; area from the row's own PSGC code; printed % not loaded (gold recomputes) |
| `diseases_hospital_claims_silver` | One hospital × admission year × case-rate package × claim status. Key `(year, facility_name_norm, area_key, disease_key, claim_status, _source_key)` | 243,881 | **Restricted.** From 245,405 bronze rows: 1,404 blank-illness rows quarantined, 120 repeats summed (`merged_into`); area from the (province, municipality) pair map; hospital → `facility_key` by a 3-tier name match (5.3% of claims unmatched); series flags from named settings |

**Weekly periods (D-44, D-46; applied and verified 2026-10-19):**

| Source | `period_basis` | `period_key` | Period | Year, week |
|---|---|---|---|---|
| HDX dengue | `iso_week_ending_date` | the date that closes the week (always a Sunday) | `date − 6` to `date` | ISO year and ISO week of the date |
| UP NOAH | `iso_week` | `yyyy-Www` | Monday to Sunday of that ISO week | `YR`, `WN` as ISO year and week; `is_approximated = false` |

A gate fails any weekly row that is not a consistent ISO week. Edge weeks belong to the ISO year: HDX week ending 2021-01-03 is ISO 2020 week 53.

**Area keys:** `ph` (country), `psgc:<10 digits>`, `hist:maguindanao` (undivided Maguindanao, `is_superseded_area = true`), `foreign` (PSA usual residence abroad).

### 4.3 Facilities (`00a`, `00`, `01`–`04`)

| Table | Grain / key | Rows | What the build does |
|---|---|---|---|
| `facilities_area_boundary` (`00a`) | One geography city / municipality with its HDX polygon | 1,642 | Polygon accepted only if names agree or the HDX match was name-based → `hdx`, `name_conflict`, `no_boundary` |
| `facilities_id_map_silver` (`01`) | One source identifier. Key `(_source_key, source_record_id)` | 5,257 | Keeps `facility_key` stable: reads its own previous version |
| `facilities_registry_silver` (`01`) | One facility establishment. Key `facility_key` | 3,957 | NHFR spine; HFSRB joins on numeric `nhfr_id` only if place or name agrees, else exact name + municipality code; no fuzzy match. `authorized_beds = hfsrb_abc`, `analysis_beds = coalesce(abc, nhfr)` with `analysis_beds_basis`. Services of an existing hospital → `service_of_existing_facility` |
| `facilities_metric_silver` (`02`) | One area × year × ownership × source. Key `(area_key, year, ownership, _source_key)` | 2,988 | Published counts (PSA 9.16–9.19, FHSIS BGY & BHS); 2013 hospital definition break flagged; `*` / `-` → null + `no_report_measures` |
| `facilities_bed_occupancy_silver` (`03`) | One anonymous hospital record of one year. Key: bronze row reference | 9,145 | **Restricted.** HFSRB FOI release 2018–2025; BOR recomputed from bed days and compared; `exclusion_reason` → `baseline_eligible` (8,150). Never matched to registry facilities |
| `facilities_osm_point_silver` (`04a` + `04`) | One located OSM health facility. Key `(osm_type, osm_id)` | 16,030 | Newest Healthsites file only; point-in-polygon → nearest boundary ≤ 1 km → exception → `addr:city`; 2 points quarantined |

Area resolution order: exceptions → source code (NHFR) → name + level + parent. Only `auto`, `corroborated` and `reviewed` exceptions are used.

### 4.4 Workforce (`00`–`04`)

| Table | Grain / key | Rows | What the build does |
|---|---|---|---|
| `workforce_fhsis__resolved` (`01`, staging) | One FHSIS label | — | Resolve every label once: row override → 2025 printed code → exceptions → name core + level + parent region. Zero or several candidates stop the build |
| `workforce_headcount_silver` (`02`) | One profession × area × year × source. Key `(_source_key, area_key, year, profession)` | 28,080 | 9 professions wide → long; status per cell; `analysis_eligible` with named rules R1–R5; split basis by year; nurse series break 2019; PSA preferred 2012–2017, FHSIS from 2018 (PSA 2018–2023 = `cross_check`); 8 blank-label rows quarantined |
| `workforce_area_denominator_silver` (`03`) | One area × year: population and households as FHSIS prints them. Key `(_source_key, area_key, year)` | 3,024 | Two lineage groups (population sheet, households sheet) |
| `workforce_specialist_silver` (`04`) | One PSMO area listing in one snapshot | 52 | Composite areas never split or summed |

### 4.5 Socioeconomic (`00`–`05`)

| Table | Grain / key | Rows | What the build does |
|---|---|---|---|
| `socioeconomic_poverty_silver` (`01`) | One area × reporting year. Key `(area_key, year)` | 322 | Data rows = membership in the area map, never cast success; status `ok`, `not_published`, `not_computed`, `parse_error`; tab2 / tab6 keys validated before an aggregated join; poor population × 1,000; CV → precision class; `comparison_eligible` + `exclusion_reason` |
| `socioeconomic_health_expenditure_share_silver` (`02`) | One financing agent × year. Key `(financing_agent, year)` | 128 | Approved list of 16 agents, 3 levels; `a/` → 0.0 + `is_below_0_05` |
| `socioeconomic_health_expenditure_per_capita_silver` (`03`) | One national year. Key `year` | 8 | Rows by label and position |
| `socioeconomic_child_mortality_silver` (`04`) | One characteristic × survey. Key `(characteristic_group, characteristic, survey_year)` | 60 | Approved list of 30 characteristics; `*` → `suppressed`, parentheses → `low_precision`; no PSGC |
| `05_poverty_geography_check` | — | — | Area map codes vs `geography_silver`; name differences marked REVIEW |

---

## 5. Restricted tables

| Table | Why restricted | Handling |
|---|---|---|
| `diseases_hospital_encounters_silver` | De-identified hospital extract | Not read by gold |
| `diseases_hospital_claims_silver` | PhilHealth FOI release | Gold publishes aggregates; cells from fewer than 3 hospitals suppressed |
| `facilities_bed_occupancy_silver` | HFSRB FOI release | Gold publishes aggregates; cells from fewer than 3 records suppressed |
| IHME rows in `diseases_metric_silver` | Licence: non-commercial, no redistribution | `value_lower` / `value_upper` never profiled; attribution line on every chart |

D-47: "restricted" is our own commitment in each request: academic use, aggregate reporting only. Restricted tables are never profiled and their rows are never copied to `quality.quarantine`; QC writes counts only. `sharing: restricted` is declared, not yet enforced by Unity Catalog grants.

---

## 6. Rules gold must not redo or break

| Rule | Meaning |
|---|---|
| **Counts only** | Silver holds published counts (`value_unit = count` in diseases). Gold computes rates |
| **Null is not zero** | A missing value is null with a status (`no_report`, `not_published`, `missing` …). A real 0 stays 0 |
| **Never sum across** | `_source_key`, `geo_level`, `period_grain`, `value_type`, `measure_definition`, a cause and its descendants, `indicator` / agent levels. Published totals (`all_causes`, `ph`) are their own rows |
| **Sum causes only through `diseases_cause_aggregation`** | The only approved way to sum over causes |
| **`location_basis` says what the area means** | `usual_residence` (PSA), `reporting_unit` (FHSIS), `modelled_population` (IHME), `facility_location` (claims), `patient_origin` (hospital) |
| **Coverage basis** | `geo_coverage_basis` and `comparison_eligible` say whether a province figure includes its HUCs. Do not compare ineligible rows with PSGC-based figures as they are |
| **Do not re-map or re-classify** | Use `area_key`, `disease_key`, `facility_key`, statuses and dispositions as given |
| **Read coverage before comparing years** | `diseases_source_coverage_silver`: compare like-for-like periods (DOH FOI 2025 holds January–September) |
| **Series breaks are flags, not fixes** | Hospitals 2013, nurses 2019, claims 2020–2021 (COVID), 2024 amounts, IHD with MI 2025 |
| **ISO weeks** | Weekly rows use `iso_week` / `iso_week_ending_date`; gold `dim_date` must accept both and take `period_start` / `period_end` from silver |

---

## 7. Quality

### 7.1 Build gates (before publishing)

Named checks inside each build file, all FAIL. They are listed in the file's `__gates` table and summarised in `build_log`. Some are warn gates (counted, not blocking), for example the three diseases claims gates that confirm each series-break rule is still visible in the data.

### 7.2 QC scripts (after publishing)

All write through `dq_utils.DQRun` into `public_health.quality` (`qc_results`, `run_log`, `table_stats`, `profile`, `quarantine`). The script raises at the end if any check is FAIL.

| Script | Codes | Checks (examples) |
|---|---|---|
| `geography_silver_qc.py` | GS01–GS08 | Rows, required fields, key unique, accepted levels (list in `sources_geography.yaml`), bronze = silver, hierarchy rebuilds the code, code is 10 digits (GS07), null-level codes = the documented placeholders (GS08) |
| `psgc_population_silver_qc.py` | S01–S09, S51–S59 | Grain, PSGC in geography, reconciliation, status consistency, missing rows (S54), province = Σ parts (S55), national control (S56, values in `sources_population.yaml`), one snapshot (S57), census-year swings (S58), census years = configured years (S59) |
| `admin_boundaries_silver_qc.py` | AS01–AS04, ASB05, AS07–AS09 | Rows, required fields, key unique, accepted levels and geometry (from the YAML), total-row reconciliation, spatial attributes, null PSGC only for the special structures listed in `sources_geography.yaml`, PSGC reference snapshot and level |
| `diseases_silver_qc.py` | S01–S12, S30–S50 | Lineage (S30–S32), freshness (S33), controls (S34, read from `sources_diseases.yaml`), ISO week periods (S08), cross-source (S40–S44), quarantine kind (S45), coverage = metric (S48), codes in geography (S49, S50) |
| `facilities_silver_qc.py` | S01–S11, S13–S28 | Lineage, freshness (S16), NHFR id unique (S18), control totals (S21), bed definitions (S23), BOR eligibility (S24) |
| `workforce_silver_qc.py` | S01–S09, S60–S79 | Lineage, freshness (S63), national and area controls (S64, S65, from `sources_workforce.yaml`), eligibility rules (S67), PSA vs FHSIS (S71); years, sheets, professions and rule ids from the builds' `build_log.parameters` |
| `socioeconomic_silver_qc.py` | S01–S10, S80–S96 | Lineage, freshness (S83), controls (S84, read from `sources_socioeconomic.yaml`), expected rows (S88, counts and years from the build's `build_log.parameters`), area map (S90), shares sum (S91) |
| `silver_cross_domain_qc.py` | S04, S08, S29, S97–S99 | Quarantine share per table (S29 gate), future years (S08), ratios per population (S97, latest census year), source age (S98), FHSIS vs census population (S99, every year held by both) |

Restricted tables: counts only, never profiled. Codes S13–S99 and S59 are not yet in `quality.check_registry`; scripts run with `strict_registry=False` until it is seeded (to-do item 7).

### 7.3 Last results

| Domain | Run | Result | Expected WARNs |
|---|---|---|---|
| Diseases | 2026-10-19, after the D-44 / D-46 rebuild | 143 checks, 0 FAIL, 7 WARN | S43 (126 HDX areas: weeks missing in the source), S44 (3 of 48 region-years, DOH FOI vs UP NOAH), S47 × 5 (hospital review counts) |
| Population | 2026-10-19 | 19 checks, 0 FAIL, 5 WARN | S53 missing / invalid cells, S54 areas without a census-year row, S55 × 2 (Benguet 2015; Maguindanao del Norte 2015 / 2020 without Cotabato City; regions changed by the Negros Island Region and BARMM regrouping), S58 swings above 30% |
| Facilities | 2026-10-14 | 136 checks, 0 FAIL, 9 WARN | S28 quarantined rows, S26 FHSIS NCR 2025, S25 BOR above 100, S11 / S27 OSM placed by `addr:city` |
| Workforce | Last recorded by 2026-10-16 | 0 FAIL, 7 WARN | Source consistency and review counts |
| Socioeconomic | Last recorded by 2026-10-16 | 82 checks, 0 FAIL, 3 WARN | S94 incidence drops, S95 non-comparable areas, S96 reference period |

Live numbers: `quality.qc_results`, latest `validation_id` per domain.

### 7.4 Verification of the 2026-10-19 week change

`silver_rev_d44_verify.sql` is a one-off check, not a pipeline task. All four steps passed on 2026-10-19: UP NOAH week numbers fit the ISO weeks of each year; every HDX date is a Sunday; 0 null dates and 0 approximated rows; HDX 2016–2018 complete, 2019 51 of 52 (week 1 missing in the source), 2020 53 of 53; UP NOAH 52 of 52 every year.

---

## 8. Run and rerun

### 8.1 Normal run

```bash
databricks bundle deploy -t dev
databricks bundle run ph_public_health_pipeline -t dev
```

Silver runs after bronze, bronze QC and the per-domain gates, and before gold. To run one domain by hand, run its tasks in the order of section 1, then its QC script, then `silver_cross_domain_qc.py`.

### 8.2 What to rerun after a change

| Change | Rerun |
|---|---|
| New or changed bronze file in a domain | That domain's builds that read it, then its QC, then cross-domain QC. QC S16 / S33 / S63 / S83 FAIL until you do |
| New `geography_silver` snapshot | Population, boundaries, all reference builders, then every domain from `00` |
| Facilities exceptions rebuilt | Facilities `00` then **all** of `01`, `02`, `03`, `04a`, `04` (incident 5: a skipped build keeps the old exceptions version and S16 fails) |
| Facilities registry rebuilt | Diseases `06` (claims `facility_key`) |
| Diseases `01` rebuilt | Diseases `04` (S48 fails until the coverage table matches) |
| A rule or setting changed in a build file | That build in full, then its QC. With R1 in place, use `force_rebuild` (rebuild strategy) |
| A control value or census year changed | Update `sources_<domain>.yaml` (`qc` / `silver_qc` blocks), rerun the QC script |

### 8.3 Recover from a failed build

1. Read the failed row in `quality.build_log` (`status = 'failed'`, error text) and the `__gates` staging table: the gate with `failures > 0` names the problem.
2. Fix the input (bronze file, YAML entry, reference decision) or the rule.
3. Rerun the build. The published table was never changed; the last good version is also in Delta history (`DESCRIBE HISTORY`, `RESTORE TABLE … TO VERSION AS OF …`).
4. Run the domain QC and the cross-domain QC.

A QC FAIL after a successful build usually means stale inputs (rerun the build) or a control that no longer matches (check the source, then the YAML).

---

## 9. Open decisions and known limits

| Item | Current treatment |
|---|---|
| Full rebuild every run (D-57) | Deliberate under a million rows per domain; recommendations R0–R5 in the rebuild strategy |
| Bronze read at its current version | Silver runs right after bronze QC in the same job; `VERSION AS OF` is R4 |
| HUC → province crosswalk | Not in silver; comparisons that include HUCs are flagged `comparison_eligible = false` |
| Week convention D-44 / D-46 | Team decision, applied and verified; not confirmed by the providers |
| Coverage of IHME, HDX, poverty provinces with HUCs, Basilan | Unconfirmed; flagged in `geo_coverage_basis` |
| Review rows | 18 FHSIS TB special-area rows (F9), 21 claims area pairs marked REVIEW, 34 Davao city labels, San Jose (Oriental Mindoro) |
| Second FOI release | Claims `06` stops on more than one claims file; not designed yet |
| `silver_tables.yaml` and shared QC | Not built; each QC script holds its own lineage expectations |
| Reference copies | Repo and Volume copies synced by hand |
| CI | sqlfluff skips diseases `01`–`03` (over the size limit) |
| BOR bed basis and reporting period | Unconfirmed: `bor_basis_confirmed = false`, `period_confirmed = false` |

---

## 10. Running silver without Databricks

Silver needs Spark SQL with ANSI mode, Delta tables (versions and history), three-part names or two-part replacements, and a scheduler that stops on the first failure. `read_files()` (reference CSV load) and the job YAML are the Databricks-specific parts; `facilities_silver_04a_osm_locate.py` needs shapely. Versions, libraries and rebuild steps for every layer: [reproducibility](../../docs/07-operations/reproducibility.md).

---

## 11. History of updates

| Date | Change |
|---|---|
| 2026-10-07 | Lineage contract v1.3 agreed: 7 lineage columns per row, load ids once per build |
| 2026-10-09 | Diseases, facilities, workforce and socioeconomic builds written and run on local Spark; write-audit-publish with `build_log` / `build_inputs` / `row_disposition` |
| 2026-10-11 | Reference builders read `geography_silver`; geography `ñ` repair; population parse fix |
| 2026-10-12 | Admin boundaries matching fix (name agreement, AB07); facilities full run on Databricks; HDX boundaries replace the old boundary seed |
| 2026-10-14 | Diseases `05` TB programme and `06` PhilHealth claims; facilities bed occupancy from the HFSRB FOI release; Healthsites newest-file rule |
| 2026-10-16, 10-17 | Full runs 1 and 2, bronze to gold |
| 2026-10-19 | D-44 / D-46 ISO week convention in diseases `01`, `04` and QC S08, verified on Databricks; D-47 wording; hardcoded numbers moved to config or derived (population census years and controls, diseases controls from `sources_diseases.yaml`, region prefixes from geography, claims and encounter settings); population QC S59; full rebuild kept (D-57). README written |
| 2026-10-19 | Rule 2a, geography batch: accepted levels, null-level codes and HDX special structures moved to `sources_geography.yaml` (build and QC read the same list); new SG07 / GS07 (10-digit code, FAIL) and GS08 (null-level codes, WARN); population S08 ceiling = current year |
| 2026-10-19 | Rule 2a, socioeconomic: report years and CV / tolerance settings recorded in `build_log.parameters` by `01`–`04`; new gate per build stops it when bronze has a year column the setting does not list; row counts derived from the approved lists; QC controls from `sources_socioeconomic.yaml` (2 silver-only controls added to bronze) |
| 2026-10-19 | Rule 2a, workforce and cross-domain: FHSIS settings (coded file years, province coverage change, nurse break, region count) set once in `01` and written to `workforce_fhsis__settings` for `02` / `03`; PSA years setting with a year-column gate; new gates for exception region codes, a new FHSIS year without a denominator sheet, and a profession without a printed label; QC controls from `sources_workforce.yaml`; cross-domain census years derived. Rule 2a is done for every silver file |