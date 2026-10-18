# Workforce Silver Layer Documentation

Owner: Virna Pomendia
Last updated: 2026-10-18

## Overview

The workforce silver layer cleans, types, and geographically matches public health workforce data from bronze. Scripts live in `src/03_silver/` and build into `public_health.silver.workforce_*`.

## Build scripts

| Script | Target table | Grain | Key | Purpose |
|---|---|---|---|---|
| `workforce_silver_00_reference.sql` | `workforce_profession_reference_silver` | One profession | `profession_key` | Profession name normalization and categorization |
| `workforce_silver_01_fhsis_areas.sql` | `workforce_fhsis_areas_silver` | `area x year` | `(area_key, year)` | FHSIS reporting areas for workforce data |
| `workforce_silver_02_headcount.sql` | `workforce_headcount_silver` | `area x year x profession x source` | `(area_key, year, profession_key, _source_key)` | Workforce headcounts by area, year, and profession |
| `workforce_silver_03_denominator.sql` | `workforce_denominator_silver` | `area x year` | `(area_key, year)` | Population denominators for per-capita workforce ratios |
| `workforce_silver_04_specialist.sql` | `workforce_specialist_silver` | `area x year x specialty x source` | `(area_key, year, specialty, _source_key)` | Specialist workforce (PSMO data) |

## Sources

Workforce data comes from two bronze sources:

* `doh_fhsis_demographic` -- FHSIS reports workforce headcounts by province and city (2018-2025). Covers doctors, nurses, midwives, RHMs, dentists, and other public health workers.
* `psa_gov_practitioners` -- PSA reports government health practitioners by region (annual). Covers doctors, nurses, midwives, and dentists.

## Geography matching

* FHSIS provides province and city/municipality level data. Area names are matched to `geography_silver` via PSGC codes and name normalization.
* PSA provides region-level data only. Region names are matched to `geography_silver`.
* Unmatched FHSIS area names are a known issue. See [data gaps](../../02-data/data-gaps.md) G8.

## Profession normalization

The `workforce_profession_reference_silver` table maps source-specific profession names to a standard set:

* Doctors (general practitioners, specialists)
* Nurses
* Midwives
* Rural Health Midwives (RHM)
* Dentists
* Medical Technologists
* Other public health workers

## Quality checks

Each silver build runs validation gates:
* S01: No null keys.
* S02: No duplicate keys.
* S03: Lineage complete.
* S04: Row count reconciliation.
* S05: Geographic match (warnings for unmatched areas).

See [silver quality checks](silver-quality-checks.md) for the full check catalog.

## Known limitations

* FHSIS coverage is incomplete. Not all areas report every year. A zero count means the source reported zero; a null means no report was filed.
* PSA covers region level only, not province/city.
* Workforce data does not include private-sector health workers.
* Some FHSIS area names do not match PSGC. See [data gaps](../../02-data/data-gaps.md) G8.

See [bronze workforce](../bronze/workforce.md) for the bronze layer and [silver README](README.md) for the shared build pattern.