# Diseases Silver Layer Documentation

Owner: Jemma Santiago
Last updated: 2026-10-15

## Overview

The diseases silver layer cleans, types, and geographically matches disease data from bronze. Scripts live in `src/03_silver/` and build into `public_health.silver.diseases_*`.

## Build scripts

| Script | Target table | Grain | Key | Purpose |
|---|---|---|---|---|
| `diseases_silver_00_reference.sql` | `diseases_disease_reference_silver` | One disease | `disease_key` | Disease name normalization, ICD-10 mapping |
| `diseases_silver_01_metric.sql` | `diseases_metric_silver` | `area_key x year x month x disease x source` | `(area_key, year, month, disease_key, _source_key)` | Disease cases, deaths, incidence by area and period |
| `diseases_silver_02_deaths_age.sql` | `diseases_deaths_age_silver` | `area_key x year x age_group x disease x source` | `(area_key, year, age_group, disease_key, _source_key)` | Deaths by age group (for SUP1) |
| `diseases_silver_03_hospital_encounters.sql` | `diseases_hospital_encounters_silver` | `facility x year x disease` | `(facility_key, year, disease_key)` | Hospital encounters and claims |
| `diseases_silver_04_source_coverage.sql` | `diseases_source_coverage_silver` | `source x area x year` | `(_source_key, area_key, year)` | Source coverage map for disease data |
| `diseases_silver_05_tb_programme.sql` | `diseases_tb_programme_silver` | `area x year x tb_indicator` | `(area_key, year, tb_indicator)` | TB programme indicators (DSTB, DRTB, treatment outcomes) |
| `diseases_silver_06_hospital_claims.sql` | `diseases_hospital_claims_silver` | `facility x year x claim_type` | `(facility_key, year, claim_type)` | Hospital claims data |

## Sources

Disease data comes from four bronze sources:

* `doh_foi_dengue` -- monthly dengue cases and deaths by region (2021-2025, FOI-released, restricted).
* `upnoah_dengue` -- weekly dengue cases by region (2017-2020, public).
* `hdx_dengue` -- weekly dengue alerts (2019-2024, public).
* `ihme_neoplasm` -- province-level neoplasm prevalence and incidence (IHME GBD, non-commercial).
* `globocan_2024` -- national-level cancer estimates (GLOBOCAN, non-commercial).

## Geography matching

Disease sources use different geographic levels:
* FOI dengue: region level (matched via region name to `geography_silver`).
* UP NOAH: region level.
* IHME: province level.
* GLOBOCAN: national level.

Unmatched area names are logged as warnings and excluded from silver.

## Quality checks

Each silver build runs validation gates:
* S01: No null keys.
* S02: No duplicate keys.
* S03: Lineage complete (every row has `_silver_build_id`, `_source_key`, `_source_file`).
* S04: Row count reconciliation (silver rows + disposition rows = bronze input rows).

See [silver quality checks](silver-quality-checks.md) for the full check catalog.

## Known limitations

* Week definition is not reconciled across dengue sources (UP NOAH folds week 53 into 52; HDX uses ISO weeks). See [data gaps](../../02-data/data-gaps.md) G7.
* IHME and GLOBOCAN have different geographic coverage and years. They cannot be directly compared.
* The 2020-2021 dengue data gap in UP NOAH is partially filled by FOI monthly data. See [data gaps](../../02-data/data-gaps.md) G4.

See [bronze diseases](../bronze/diseases.md) for the bronze layer and [silver README](README.md) for the shared build pattern.