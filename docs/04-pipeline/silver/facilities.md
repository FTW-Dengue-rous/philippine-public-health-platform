# Silver — facilities

Where care is offered: one registry of facility establishments with their beds, the facility counts that agencies publish, hospital bed occupancy, and health sites mapped in OpenStreetMap. Every facility and point is placed in a PSGC city or municipality.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.3. Back to the [silver overview](README.md).

## Sources

| Source | What it gives | Notes |
|---|---|---|
| DOH NHFR (National Health Facility Registry) | The facility list with location and beds | The spine of the registry |
| DOH HFSRB licensed facilities | Licensed hospitals and their authorized bed capacity (ABC) | Joined to NHFR |
| PSA Statistical Yearbook 9.16–9.19 | Published counts of hospitals and beds by region and year | Hospital definition changes in 2013 |
| DOH FHSIS BGY & BHS | Barangay health stations and related counts | |
| HFSRB FOI release | Anonymous hospital records with bed days, 2018–2025 | Restricted |
| Healthsites.io / OpenStreetMap | Health facility points | Newest file only |
| HDX boundaries (via geography) | City and municipality polygons | For point-in-polygon |

Settings: `config/sources_facilities.yaml`.

## Tables

| Table | One row is | Rows (last build) |
|---|---|---|
| `facilities_area_boundary` (`00a`) | One PSGC city or municipality with its HDX polygon | 1,642 |
| `facilities_id_map_silver` (`01`) | One source identifier and the facility it belongs to | 5,257 |
| `facilities_registry_silver` (`01`) | One facility establishment | 3,957 |
| `facilities_metric_silver` (`02`) | One area, year, ownership and source: a published count | 2,988 |
| `facilities_bed_occupancy_silver` (`03`) | One anonymous hospital record of one year (restricted) | 9,145 |
| `facilities_osm_point_silver` (`04a` + `04`) | One located OSM health facility | 16,030 |

## How it is built

| Step | File | What happens |
|---|---|---|
| Boundaries | `00a` | A polygon is accepted for a city or municipality only if the names agree or the HDX match was name-based: `hdx`, `name_conflict` or `no_boundary` |
| Reference load | `00` | Area exceptions and identifier overrides; stops if they were built from another geography snapshot |
| Registry | `01` | NHFR is the spine. HFSRB joins on the NHFR id only if place or name agrees; otherwise on exact name and municipality code; no fuzzy matching. `facility_key` is reused from the previous build, so a facility keeps its key. `authorized_beds` = HFSRB ABC; `analysis_beds` = ABC, else NHFR beds, with `analysis_beds_basis` saying which. A service of an existing hospital is marked, not counted as a new facility |
| Published counts | `02` | PSA and FHSIS counts reshaped to rows; `*` and `-` become null with `no_report_measures`; the 2013 hospital definition break is flagged and a gate checks it is still visible in the data |
| Bed occupancy | `03` | Bed occupancy rate recomputed from bed days and compared with the printed one; `exclusion_reason` decides `baseline_eligible`. Never matched to registry facilities |
| OSM points | `04a`, `04` | Point in polygon, else nearest boundary within 1 km, else an exception, else `addr:city`; points outside the Philippines quarantined |

Area resolution order everywhere: reviewed exception → the source's own code (NHFR) → name, level and parent. Only exceptions marked `auto`, `corroborated` or `reviewed` are used.

New-file protection: a PSA table with a year column outside the expected range, an FHSIS file with an unknown layout, or a bed occupancy sheet that is not in the settings stops the build.

## Quality checks

Every check of this domain, with its rule and severity: [silver quality checks](silver-quality-checks.md#10-facilities-facilities_silver_qcpy).

`facilities_silver_qc.py`, codes S01–S11 and S13–S28. Highlights:

| Code | Check |
|---|---|
| S16 | Silver was built from the bronze loads and exceptions that are there now |
| S18 | NHFR id unique in the registry |
| S21 | Control totals from the YAML (NHFR facilities and beds, bed occupancy records) |
| S23 | Bed definitions consistent |
| S24 | Bed occupancy eligibility follows its rules |
| S11 | Points inside the Philippines bounding box; break year still visible |

**Expected WARNs:** S28 (quarantined rows), S26 (FHSIS NCR 2025), S25 (bed occupancy above 100%), S11 / S27 (OSM points placed by `addr:city`).

## Rules for users

- `facility_key` is stable across runs; join on it, not on names.
- Use `analysis_beds` with `analysis_beds_basis`; `authorized_beds` is HFSRB only.
- "Recorded" means listed in the registry. It does not prove that no facility exists.
- Bed occupancy is aggregate only (restricted): cells from fewer than 3 records are suppressed in gold.
- PSA hospital counts before and after 2013 use different definitions.

## Limitations

- The bed basis and reporting period of the bed occupancy release are not confirmed by the provider (`bor_basis_confirmed = false`, `period_confirmed = false`).
- OSM coverage depends on volunteers; it is a cross-check, not a registry.
- Rebuilding the exceptions means rebuilding every facilities step (`00`, `01`–`04`), then diseases `06`, which reads the registry.
