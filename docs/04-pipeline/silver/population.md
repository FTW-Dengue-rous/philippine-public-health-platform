# Population Silver Layer Documentation

Owner: Margarette Legaspi
Last updated: 2026-10-18

## Overview

The population silver layer normalizes population data from `geography_bronze.populations_json` into a flat table. It is built by `psgc_population_silver.py` in `src/03_silver/`.

## Target table

| Property | Value |
|---|---|
| Table | `public_health.silver.population_silver` |
| Script | `psgc_population_silver.py` |
| Grain | `psgc_code x population_year` |
| Key | `(psgc_code, population_year)` |
| Rows | ~6,500 |

## Columns

| Column | Type | Description |
|---|---|---|
| `psgc_code` | STRING | PSA PSGC code (Q2 2024 reference) |
| `population_year` | INT | Year of the population estimate (2015, 2020, or 2024) |
| `population` | LONG | Population count |
| `area_name` | STRING | Area name from geography_silver |
| `geographic_level` | STRING | Barangay, City/Mun, Province, Region, or Country |

## Population years

* **2015**: PSA 2015 Census of Population.
* **2020**: PSA 2020 Census of Population.
* **2024**: PSA 2024 population projection (closest to current).

The gold layer uses 2024 population for per-capita calculations. Some NCR districts have null population for 2024, which results in null (not zero) per-capita rates. See [assumptions and limitations](../../01-context/assumptions-and-limitations.md).

## Quality checks

* S01: No null `(psgc_code, population_year)` keys.
* S02: No duplicate keys.
* S03: Lineage complete.

See [silver quality checks](silver-quality-checks.md) for the full check catalog.

## Known issues

* Not all PSGC codes have population for all three years. Missing years result in null population.
* Population projections diverge from actual census counts. Do not mix years in comparisons.

See [bronze population](../bronze/population.md) for the bronze layer and [geography silver](geography.md) for the geography hierarchy.