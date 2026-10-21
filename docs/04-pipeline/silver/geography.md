# Silver — geography

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Geography is the spine of the platform. `geography_silver` is the only table that may define a PSGC code; every other domain maps its area labels to it and is checked against it. The HDX administrative boundaries are matched to it so that maps and point-in-polygon work use the same codes.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.1. Back to the [silver overview](README.md).

## Sources

| Source | Bronze table | Used for |
|---|---|---|
| PSA PSGC, release Q2_2024 (API) | `bronze.geography_bronze` | Every area code, name and level, region to barangay |
| HDX Philippines administrative boundaries (COD-AB) | `bronze.admin_boundaries_bronze` | Polygons for regions, provinces, cities and municipalities |

Settings for both are in `config/sources_geography.yaml`.

## Tables

| Table | One row is | Key | Rows (last build) |
|---|---|---|---|
| `geography_silver` | One PSGC area in one PSGC snapshot | `psgc_code`, `content_checksum` | 43,762 (18 regions, 82 provinces, 149 cities, 1,493 municipalities, 14 sub-municipalities, 42,004 barangays, 2 rows with no level) |
| `admin_boundaries_silver` | One HDX boundary in one source version | `admin_level`, `boundary_pcode`, `source_version` | 1,747 (ADM1 17, ADM2 88, ADM3 1,642) |

Live counts: the build output, or `SELECT count(*)` on the table.

## How `geography_silver` is built

`geography_silver.py` locks exactly one bronze snapshot: the configured PSGC version, with one content checksum. It trims text and turns empty strings into nulls. It repairs the damaged `ñ` (`Ã±` → `ñ`, 456 names in Q2_2024) and keeps the original in `area_name_raw`. It casts nothing and drops no row.

Checks before writing (all FAIL except SG04):

| Code | Check |
|---|---|
| SG01 | Required fields filled |
| SG02 | One row per `psgc_code` and snapshot |
| SG03 | Level is one of Reg, Prov, City, Mun, SubMun, Bgy (list in the YAML), or null |
| SG04 | The hierarchy columns rebuild the code (WARN) |
| SG05 | Bronze rows = candidate rows |
| SG06 | No damaged names left |
| SG07 | Every code is 10 digits (other domains read region, province and city from fixed positions in the code) |

The table is written with a MERGE on `psgc_code + content_checksum`. A rerun on unchanged bronze inserts and updates nothing; a new PSGC release adds a new snapshot beside the old one.

**Rows with no level.** PSA publishes two codes without a level: `0990100000`, a placeholder named "City of Isabela (Not a Province)" (the city itself is `0990101000`), and `1999900000`, the BARMM Special Geographic Area. They stay in the table and are never used as areas. QC GS08 warns when a new release adds or removes such a code.

## How `admin_boundaries_silver` is built

`admin_boundaries_silver.py` reads one HDX snapshot with levels 1 to 3 and matches each boundary to a PSGC code, in this order:

| Match status | Rule |
|---|---|
| `CODE_MATCH` | The HDX P-code turned into a 10-digit PSGC code exists at the right level; for cities and municipalities the names must also agree |
| `HIERARCHY_MATCH` | Same name within the same parent province |
| `NAME_LEVEL_MATCH` | Exactly one area with that name at that level |
| `TYPE_CONTEXT_MATCH` | A city named as a city, resolved by its parent where needed |
| `NAME_VARIANT_MATCH` | Exactly one match after punctuation and encoding are normalised |
| `SPECIAL_STRUCTURE` | Metro Manila districts, the Isabela placeholder and the Special Geographic Area: no one-to-one PSGC area, so the code stays null |

A boundary that matches nothing, or matches more than one area, stops the build. The special structures are listed in `sources_geography.yaml`, read by both the build and the QC. The table is written by deleting the loaded source version and inserting it again.

## Quality checks

Every check of this domain, with its rule and severity: [silver quality checks](silver-quality-checks.md#7-geography-and-boundaries).

| Script | Codes | Highlights |
|---|---|---|
| `geography_silver_qc.py` | GS01–GS08 | Snapshot present, required fields, key unique, accepted levels, bronze = silver, hierarchy (WARN), 10-digit codes (GS07), the no-level codes are the documented ones (GS08, WARN) |
| `admin_boundaries_silver_qc.py` | AS01–AS04, ASB05, AS07–AS09 | Required fields, key unique, levels and geometry types, bronze = silver, valid area and centre point, a null code only for the special structures, every code at the right level in the recorded PSGC snapshot |

## Rules for users

- Join on `psgc_code` within the latest snapshot (`content_checksum` with the latest `silver_processed_at`). Every domain does this.
- A highly urbanized city has its own 5-digit prefix, so its province cannot be read from its code. There is no crosswalk table in silver.
- Barangays are kept but no other domain reports at barangay level.

## Limitations

- One PSGC snapshot (Q2_2024) is used for every year. Areas that changed before it are kept by other domains as named keys (for example `hist:maguindanao`).
- HDX boundaries cover levels 1 to 3 only; 8 municipalities of the Special Geographic Area have no polygon.
- A new PSGC release needs every domain rebuilt from its reference load (`00`), because the reference maps record which snapshot they were built from.
