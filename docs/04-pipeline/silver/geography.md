# Geography Silver Layer Documentation

Owner: Margarette Legaspi
Last updated: 2026-10-15

## Overview

The geography silver layer normalizes PSGC codes, area names, and administrative hierarchies from bronze. It provides the reference geography that all other domains join to.

## Build scripts

| Script | Target table | Grain | Key | Rows | Purpose |
|---|---|---|---|---|---|
| `geography_silver.py` | `geography_silver` | One administrative unit | `area_key` (xxhash64 of PSGC code) | 43,762 | Full PSGC hierarchy: barangay, city/municipality, province, region, country |
| `psgc_population_silver.py` | `geography_population_silver` | `psgc_code x population_year` | `(psgc_code, population_year)` | ~6,500 | Normalized population (2015, 2020, 2024) per PSGC code |
| `admin_boundaries_silver.py` | `admin_boundaries_silver` | One administrative boundary polygon | `psgc_code` | ~43,000 | GeoJSON polygons from HDX for mapping and spatial joins |

## Geography hierarchy

```
Philippines (ph)
  -> Region (17 regions + BARMM)
    -> Province (84 provinces incl. NCR districts)
      -> City/Municipality (1,600+ LGUs)
        -> Barangay (42,000+ barangays)
```

NCR does not have provinces. NCR districts (e.g. Metro Manila 1st District) are treated as province-level for joins. HUCs (highly urbanized cities) have their own PSGC codes and may or may not be grouped with their province.

## Reference geography

PSGC Q2 2024 is the reference snapshot. All area names and codes are matched to this version. PSGC codes change over time; older source data may use codes or names that no longer match.

## Population

Population data comes from `geography_bronze.populations_json`, which is flattened into `geography_population_silver`. Three population years are available:

* 2015 (PSA census)
* 2020 (PSA census)
* 2024 (PSA projection)

The gold layer uses 2024 population for per-capita calculations. Some NCR districts have null population for 2024, which results in null (not zero) per-capita rates.

## Quality checks

* S01: No null `area_key`.
* S02: No duplicate `area_key`.
* S03: Lineage complete.
* S05: Geographic match (all area keys in other domains should resolve to `geography_silver`).

See [silver quality checks](silver-quality-checks.md) for the full check catalog.

## Known issues

* PSGC codes change quarterly. The platform uses Q2 2024 as reference. Future updates require reloading PSGC bronze and rebuilding geography silver.
* Admin boundaries require a manual ingestion step (`admin_boundaries_run_dir` job parameter). See [data gaps](../../02-data/data-gaps.md) G9.
* Some area names in FHSIS do not match PSGC. See [data gaps](../../02-data/data-gaps.md) G8.

See [bronze geography](../bronze/geography.md) for the bronze layer and [silver README](README.md) for the shared build pattern.