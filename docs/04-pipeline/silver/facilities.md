# Facilities silver

Owner: Cristina Villota, Via Cabuyao
Last updated: 2026-10-15

The facilities domain has five silver tables built from 15 bronze sources. All builds are v1.7 SQL scripts.

## Tables

### `facilities_id_map_silver`

* **Grain**: One source facility identifier.
* **Key**: `(_source_key, source_record_id)`.
* **Rows**: 5,254 (build 2026-10-10).
* **Script**: `facilities_silver_01_registry.sql`.
* **`source_record_id`**: `nhfr:<nhfr_id>` for NHFR, `name:<category>|<norm_name>|<psgc>` for HFSRB.
* **Purpose**: Maps source identifiers to stable `facility_key` values. One facility can have multiple source records (one per source).

### `facilities_registry_silver`

* **Grain**: One facility establishment.
* **Key**: `facility_key` (unique, enforced by validation gate).
* **Rows**: 3,954 (build 2026-10-10).
* **Script**: `facilities_silver_01_registry.sql`.
* **Sources**: NHFR hospitals (spine) + 4 HFSRB licensed lists (hospitals, infirmaries, primary care, dialysis clinics).
* **Matching**: NHFR code (numeric, with place/name agreement) then normalized name + municipality.
* **Result**: 1,407 hospitals (1,092 code match + 196 name match + 71 NHFR-only + 48 HFSRB-only), 602 infirmaries, 1,158 primary care, 787 dialysis clinics.
* **Uniqueness**: Tested by validation gate (duplicate facility_key fails the build). Not enforced by a primary key constraint.

### `facilities_metric_silver`

* **Grain**: Area × year × ownership × source.
* **Key**: `(area_key, year, ownership, _source_key)`.
* **Rows**: 2,988 (build 2026-10-12).
* **Script**: `facilities_silver_02_metric.sql`.
* **Sources**: PSA hospitals/beds (region annual, national annual), PSA BHS (region annual), DOH FHSIS (province/city annual).
* **Columns**: `hospitals`, `authorized_beds`, `bhs`, `rhu`, `mhc`, `chc`, `health_centers_total`, `barangays`, `population`.
* **Wide layout**: One row per source per area per year per ownership. Each source keeps its own `_source_key`.

### `facilities_bed_occupancy_silver`

* **Grain**: Hospital × year.
* **Key**: `(facility_key, reporting_year)`.
* **Rows**: 1,977 (build 2026-10-12).
* **Script**: `facilities_silver_03_bed_occupancy.sql`.
* **Source**: DOH FOI bed occupancy (restricted).
* **Exclusions**: 815 private-only-year, 107 BOR > 150, 34 level missing, 17 BOR null, 1 exact duplicate.
* **Filter**: `baseline_eligible = true` for comparable reports.
* **2025**: 418 government (299 eligible, weighted BOR 97.9) + 744 private (704 eligible, weighted BOR 55.4).
* **Warnings**: 110 BOR > 150 (excluded), 281 BOR > 100 (over capacity), 1 city unresolved.

### `facilities_osm_point_silver`

* **Grain**: OSM healthsite point.
* **Key**: `osm_id`.
* **Status**: UNVERIFIED. Table not found on Databricks (2026-10-14). Documented per user instruction.
* **Script**: `facilities_silver_04_osm_point.sql` + `facilities_silver_04a_osm_locate.py`.
* **Source**: HDX healthsites (OSM extract).
* **Limitation**: OSM is community-maintained. Absence from OSM does not mean a facility does not exist.

## Reference tables

`facilities_silver_00_reference.sql` creates reference tables from CSVs in `config/reference/facilities/`:
* Facility categories (hospital, infirmary, primary care, dialysis clinic, blood service).
* Ownership normalization.
* Service level mappings.

## Area boundaries

`facilities_silver_00a_area_boundary.sql` creates area boundary reference for geographic joins.

## Area evidence

`facilities_area_evidence.sql` — area-level evidence summary for the facilities domain.

## Area exceptions

`builders/silver/build_facilities_area_exceptions.py` — generates reviewed area exception mappings for unmatched geography names.
