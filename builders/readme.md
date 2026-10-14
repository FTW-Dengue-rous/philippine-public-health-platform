# builders/

Scripts that **prepare inputs** for the pipeline. They are run by hand, never by the pipeline job.
Each one writes a file that a person reviews before the pipeline uses it.

| Folder | Feeds | What the output is |
|---|---|---|
| `landing/` | bronze | a cleaned or derived copy of a raw file, landed next to the original |
| `silver/` | silver | reference / mapping CSVs that the silver `*_00_reference.sql` step loads |
| `gold/` | gold | (none yet) |

## Rules

1. **Not a pipeline step.** No job task runs a builder. Bronze, silver and gold read only the reviewed output.
2. **Review before use.** Run the script, read its printed report, compare the new CSV with the committed copy (`git diff`), then commit it in the same PR as the change that caused the rerun.
3. **Two copies of each reference CSV.** The Volume copy is what silver reads (`<landing_root>/reference/<domain>/`). The repo copy is the reviewed record (`reference/<domain>/`). Keep them identical.
4. **Decisions live in one place.** A manual decision goes into the builder's decision table or decisions CSV, never into the generated CSV. Editing a generated CSV by hand is lost on the next run.
5. **Stop, don't guess.** Every builder stops and writes nothing when a label matches no rule or a code fails the geography check. Fix the rule or add a decision, then rerun.
6. **Geography first.** All `silver/` builders read PSGC codes only from `public_health.silver.geography_silver` (one snapshot). Rebuild geography silver before running them.

`<landing_root>` = `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing`

## Builders

### landing/build_hdx_healthsites_csv_from_geojson.py
| | |
|---|---|
| Purpose | Fill the X / Y the HDX Healthsites CSV leaves blank for OSM building outlines (3,870 rows, mostly hospitals). Decision D12. |
| Reads | `facilities/hdx_healthsites/raw_geojson/hdx_healthsites_facility_asof_<date>.geojson`, the previous Healthsites CSV (for the column layout and comparison) |
| Writes | `facilities/hdx_healthsites/hdx_healthsites_facility_asof_<date>.csv` (derived file, same 35 columns) |
| Rerun when | A new Healthsites GeoJSON is downloaded |
| Then | Add the new file to `hdx_healthsites.files` in `sources_facilities.yaml`, run `facilities_bronze.py --source_keys hdx_healthsites` |
| Manual input | None |
| Safety | Stops and writes nothing on missing columns, duplicate keys, unusable geometry or an unknown timestamp format. Overwrites `--out` if it exists. |
| Status | Run on the real files 2026-10-14 (16,032 rows, 0 without coordinates) |

### silver/build_diseases_reference_maps.py
| | |
|---|---|
| Purpose | Map every published area label and cause label of the disease sources to an `area_key` / `disease_key` |
| Reads | Diseases bronze tables, `silver.geography_silver` |
| Writes | `reference/diseases/`: `diseases_area_map.csv`, `diseases_cause_map.csv`, `diseases_directory.csv` (becomes `dim_disease`), `diseases_cause_aggregation.csv` |
| Rerun when | A new disease source or file reaches bronze; geography silver gets a new snapshot |
| Then | `diseases_silver_00_reference.sql` |
| Manual input | Decision tables in the script (`HDX_MANUAL`, `IHME_MANUAL`, `ENC_PROV_MANUAL`, `RELATED`, ...) |
| Safety | Stops if the CSVs exist; pass `--overwrite true` to replace them |
| Status | Tested on local Spark 2026-10-09; not yet run on Databricks |

### silver/build_facilities_area_exceptions.py
| | |
|---|---|
| Purpose | Resolve the facility place labels (NHFR, HFSRB, FHSIS, bed occupancy, OSM `addr:city`) that the silver matching rules cannot, each with the rule and evidence that support it |
| Reads | Facilities bronze tables, `silver.geography_silver`, `silver.facilities_area_boundary`, `reference/facilities/facilities_area_decisions.csv` |
| Writes | `reference/facilities/facilities_area_exceptions.csv` |
| Rerun when | A new facility file reaches bronze; geography silver gets a new snapshot; a decision is added |
| Run order | geography silver → admin boundaries silver → `facilities_silver_00a_area_boundary.sql` → this script → `facilities_silver_00_reference.sql` → 01 … 04 |
| Manual input | `facilities_area_decisions.csv` (accept / set / reject, with reviewer and date). **Hand-edited: the script never writes it.** |
| Safety | Stops if a usable row fails the geography check. A stale `accept` sends the row back to `needs_review`. Needs `%pip install shapely`. |
| Status | Run locally 2026-10-12; not yet run on Databricks |

### silver/build_workforce_area_exceptions.py
| | |
|---|---|
| Purpose | Resolve FHSIS health-worker, PSA T9.14 and PSMO area labels; write row-level overrides |
| Reads | Workforce bronze tables, `bronze.ingestion_metadata` (workbook checksums), `silver.geography_silver` |
| Writes | `reference/workforce/`: `workforce_area_exceptions.csv`, `workforce_psmo_area_exceptions.csv`, `workforce_area_override.csv`. When labels need a decision, it writes only `workforce_area_unresolved.csv` (to `--review_dir`) |
| Rerun when | A new FHSIS or PSMO file reaches bronze; geography silver gets a new snapshot; an override is accepted |
| Then | `workforce_silver_00_reference.sql` |
| Manual input | Decision tables in the script (`MANUAL_CODES`, `NAMED_KEYS`, `NAME_VARIANTS_2025`, `OVERRIDES`, `PSMO_AREAS`) |
| Safety | Stops if the CSVs exist (`--overwrite true`), or if an override's workbook checksum changed since review |
| Status | Run on Databricks 2026-10-11 |

### silver/build_socioeconomic_poverty_area_map.py
| | |
|---|---|
| Purpose | Map the areas in the PSA poverty workbook (sheet `tab2`) to PSGC codes, with coverage basis and comparison eligibility |
| Reads | The poverty workbook, the PSGC datafile, `silver.geography_silver` (or a CSV export with `--geography`) |
| Writes | `reference/socioeconomic/socioeconomic_poverty_area_map.csv` |
| Rerun when | PSA publishes a new poverty release; geography silver gets a new snapshot |
| Then | `socioeconomic_silver_00_reference.sql` |
| Manual input | Decision tables in the script (`PROVINCE_NAME_FIXES`, `LISTED_CITIES`, `SUPERSEDED`) |
| Safety | Stops on an unknown area, duplicate keys or codes, or a code with no match in geography silver. Overwrites `--out` if it exists. |
| Status | Codes aligned to the geography silver snapshot 2026-10-13 (Sulu fix) |

## Hand-edited reference files (no builder)

| File | Used by | Note |
|---|---|---|
| `reference/facilities/facilities_area_decisions.csv` | `build_facilities_area_exceptions.py` | Reviewer decisions; the only hand-written input of that builder |
| `reference/facilities/facilities_id_map_override.csv` | facilities silver | Manual facility ID matches |

Never run a builder with its output path pointing at one of these files.

## Adding a builder

1. Put it in the folder of the layer it feeds.
2. Header comment: purpose, inputs, outputs, how to run, rerun trigger, status (last real run).
3. Stop on anything unresolved; write nothing in that case.
4. Add a section to this README.