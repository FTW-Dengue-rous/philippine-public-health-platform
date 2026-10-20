# Quality check catalog

Every check code in the platform, in one list. A code has one meaning in every domain and is never reused. `*00` always means "the QC script crashed".

The names and severities here are the ones in the scripts (`CHECKS` dictionaries and recorded `check_name`). How each check works, what fails it and what to do: [bronze quality checks](../bronze/bronze-quality-checks.md), [silver quality checks](../silver/silver-quality-checks.md), and the gold README (`src/04_gold/README.md`). Rules for severities and gates: [quality control framework](quality-control-framework.md).

Status date: 2026-10-20. Back to the [quality overview](README.md).

---

## 1. Code ranges

| Prefix | Layer | Script | Range |
|---|---|---|---|
| `B` | Bronze, file domains and population payload | `<domain>_bronze_qc.py`, `psgc_population_bronze_qc.py` | B00–B16 |
| `GB` | Bronze, PSGC API snapshot | `geography_bronze_qc.py` | GB00–GB13 |
| `HB` | Bronze, HDX boundaries | `admin_boundaries_bronze_qc.py` | HB00–HB14 |
| `SG` | Silver build checks, geography (before the write) | `geography_silver.py` | SG01–SG07 |
| `AB` | Silver build checks, boundaries (before the write) | `admin_boundaries_silver.py` | AB01–AB07 |
| `GS` | Silver QC, geography | `geography_silver_qc.py` | GS01–GS08 |
| `AS`, `ASB` | Silver QC, boundaries | `admin_boundaries_silver_qc.py` | AS01–AS09, ASB05 |
| `S` | Silver QC, shared and per domain | `<domain>_silver_qc.py`, `psgc_population_silver_qc.py`, `silver_cross_domain_qc.py` | S00–S99 |
| `G` | Gold QC | `gold_qc.py` | G00–G13 |

Silver S ranges: S00–S12 shared; S13–S28 facilities; S29 cross-domain; S30–S50 diseases; S51–S59 population; S60–S79 workforce; S80–S96 socioeconomic; S97–S99 cross-domain.

## 2. Bronze

### 2.1 File domains and population (B)

| Code | Check | Severity |
|---|---|---|
| B00 | QC ran without error | FAIL |
| B01 | Table exists and has rows for the source | FAIL |
| B02 | Every file listed in the YAML was loaded | FAIL |
| B03 | Rows per file = `qc.expected_rows` | FAIL (WARN when the file has no expected count) |
| B04 | Required columns present | FAIL |
| B05 | Lineage columns not null | FAIL |
| B06 | `_source_row_num` unique per file and sheet (no double load) | FAIL |
| B07 | No fully empty rows | WARN |
| B08 | No exact duplicate rows within a file and sheet | WARN |
| B09 | No rescued (overflow) values | WARN |
| B10 | `qc.numeric_columns` parse as numbers | WARN |
| B11 | Control totals and values match verified numbers | FAIL |
| B12 | Total column equals the sum of its parts (`qc.row_sum`) | WARN |
| B13 | Rows per file = the loader's `processed` log row for the same load | FAIL, also when it can't be verified |
| B14 | No files in the table outside the YAML | WARN |
| B15 | Every data column is STRING | FAIL |
| B16 | Nested population payload parses (population only) | WARN |

Population QC runs B00, B01, B04, B05, B07, B10, B13, B15 and B16; file and sheet checks do not apply to an API source.

### 2.2 PSGC snapshot (GB)

Every GB check is FAIL (GB13 is WARN only when the load log can't be read).

| Code | Check |
|---|---|
| GB00 | QC ran without error |
| GB01 | Landing batch is complete and matches the loader's handoff |
| GB02 | Bronze has every required column |
| GB03 | Landing records parse to the expected count |
| GB04 | Snapshot has rows |
| GB05 | Snapshot row count = landing count |
| GB06 | `psgc_code` never blank |
| GB07 | `psgc_code` unique in the snapshot |
| GB08 | No landing code missing from bronze |
| GB09 | No bronze code missing from landing |
| GB10 | Stored JSON = landed JSON |
| GB11 | Projected attributes = the loader's extraction |
| GB12 | Snapshot lineage complete (batch id, raw path, load time) |
| GB13 | Rows = the loader's `processed` log row (WARN if the log can't be read) |

### 2.3 HDX boundaries (HB)

Every HB check is FAIL and none can be skipped.

| Code | Check |
|---|---|
| HB00 | QC ran without error |
| HB01 | Total row reconciliation |
| HB02 | Row reconciliation per administrative level |
| HB03 | Required lineage and fingerprint completeness |
| HB04 | Record fingerprint unique per administrative level |
| HB05 | Batch identity consistent |
| HB06 | Raw record fingerprint integrity |
| HB07 | Raw feature JSON parses |
| HB08 | Administrative p-code not blank |
| HB09 | Administrative name not blank |
| HB10 | P-code unique within its level |
| HB11 | GeoJSON feature type |
| HB12 | Polygon geometry type |
| HB13 | Administrative parent reference resolves |
| HB14 | Required source property keys present |

## 3. Silver

### 3.1 Geography and boundaries

Build checks, recorded before the write:

| Code | Check | Severity |
|---|---|---|
| SG01 | Required geography fields | FAIL |
| SG02 | Geography grain uniqueness | FAIL |
| SG03 | Geographic level accepted values | FAIL |
| SG04 | PSGC hierarchy consistency | WARN |
| SG05 | Bronze to silver candidate volume reconciliation | FAIL |
| SG06 | Area name encoding | FAIL |
| SG07 | PSGC code is 10 digits | FAIL |
| AB01 | Required field completeness | FAIL |
| AB02 | Logical key uniqueness | FAIL |
| AB03 | Accepted administrative and geometry values | FAIL |
| AB04 | Bronze to silver row-count reconciliation | FAIL |
| AB05 | PSGC reconciliation integrity | WARN |
| AB06 | Spatial attribute validity | FAIL |
| AB07 | One boundary per PSGC code per level (stops the run) | FAIL |

QC on the published tables:

| Code | Check | Severity |
|---|---|---|
| GS01 | Snapshot exists and has rows (bronze and silver) | FAIL |
| GS02 | Required geography fields complete | FAIL |
| GS03 | Logical key unique (`psgc_code + content_checksum`) | FAIL |
| GS04 | Non-null geographic levels accepted (list from the YAML) | FAIL |
| GS05 | Bronze to silver row counts reconcile | FAIL |
| GS06 | PSGC hierarchy components reconstruct the code | WARN |
| GS07 | `psgc_code` is 10 digits | FAIL |
| GS08 | Null-level codes are the documented placeholders | WARN |
| AS01 | Snapshot exists and has rows (bronze and silver) | FAIL |
| AS02 | Required boundary fields complete | FAIL |
| AS03 | Logical key unique (`admin_level + boundary_pcode + source_version`) | FAIL |
| AS04 | Administrative and geometry values accepted | FAIL |
| ASB05 | Bronze and silver total rows reconcile | FAIL |
| AS07 | Spatial attributes valid (area, latitude, longitude) | FAIL |
| AS08 | PSGC match status and special structures valid | FAIL |
| AS09 | PSGC reference snapshot and level valid | FAIL |

### 3.2 Shared codes (S00–S12)

| Code | Check | Type | Severity | Used by |
|---|---|---|---|---|
| S00 | QC ran without error | execution | FAIL | population, facilities, diseases, workforce, socioeconomic, cross-domain |
| S01 | table exists and has rows | completeness | FAIL | population, facilities, diseases, workforce, socioeconomic |
| S02 | grain key not null | completeness | FAIL | population, facilities, diseases, workforce, socioeconomic |
| S03 | grain key unique | uniqueness | FAIL | population, facilities, diseases, workforce, socioeconomic |
| S04 | PSGC code found in geography | consistency | WARN | population, facilities, socioeconomic, cross-domain |
| S05 | admin level valid | validity | FAIL | facilities |
| S06 | counts non-negative | validity | FAIL | population, facilities, diseases, workforce |
| S07 | rates within range | validity | WARN | socioeconomic |
| S08 | period within expected range | validity | FAIL | population, facilities, diseases, workforce, socioeconomic, cross-domain |
| S09 | bronze to silver rows reconcile | reconciliation | FAIL | population, facilities, diseases, workforce, socioeconomic |
| S10 | metric totals preserved | reconciliation | FAIL | diseases, socioeconomic |
| S11 | accepted values | validity | WARN | facilities |
| S12 | metric null rate under threshold | completeness | WARN | diseases |

### 3.3 Facilities (S13–S28)

| Code | Check | Type | Severity | Used by |
|---|---|---|---|---|
| S13 | lineage columns not null | completeness | FAIL | facilities |
| S14 | every lineage reference has one build input | consistency | FAIL | facilities |
| S15 | table written by a succeeded build | consistency | FAIL | facilities |
| S16 | silver built from the current bronze loads and reference versions | consistency | FAIL | facilities |
| S17 | one processed ingestion_metadata row and one load time per input | consistency | FAIL | facilities |
| S18 | each NHFR id in at most one registry facility | uniqueness | FAIL | facilities |
| S19 | registry lineage groups follow in_nhfr / in_hfsrb | completeness | FAIL | facilities |
| S20 | every MAP key has a lineage group | consistency | FAIL | facilities |
| S21 | control totals match | reconciliation | FAIL | facilities |
| S22 | id map and registry keys agree | consistency | FAIL | facilities |
| S23 | bed columns follow their definitions | consistency | FAIL | facilities |
| S24 | bed occupancy eligibility follows the named rules | consistency | FAIL | facilities |
| S25 | bed occupancy rate above 100 or above the baseline maximum | validity | WARN | facilities |
| S26 | FHSIS region equals its provinces and listed cities | reconciliation | WARN | facilities |
| S27 | OSM points placed by city tag only, or tag disagrees with coordinates | completeness | WARN | facilities |
| S28 | quarantined bronze rows | completeness | WARN | facilities |

### 3.4 Cross-domain (S29, S97–S99)

| Code | Check | Type | Severity | Used by |
|---|---|---|---|---|
| S29 | quarantined rows within the limit | completeness | FAIL | cross-domain |
| S97 | ratio per population inside the plausible band | validity | WARN | cross-domain |
| S98 | latest data year of each source is recent | consistency | WARN | cross-domain |
| S99 | reported population agrees with census population | consistency | WARN | cross-domain |

S29 is a band, not a plain threshold: PASS at 0; WARN up to 5% of the rows read or 10 rows; FAIL above both.

### 3.5 Diseases (S30–S50)

| Code | Check | Type | Severity | Used by |
|---|---|---|---|---|
| S30 | lineage columns not null | completeness | FAIL | diseases |
| S31 | every lineage reference has one build input | consistency | FAIL | diseases |
| S32 | table written by one succeeded build | consistency | FAIL | diseases |
| S33 | silver built from the current bronze loads | consistency | FAIL | diseases |
| S34 | control values match | reconciliation | FAIL | diseases |
| S35 | modelled value within its bounds | validity | FAIL | diseases |
| S36 | value, status and definitions consistent | validity | FAIL | diseases |
| S37 | disease and area keys resolve | validity | FAIL | diseases |
| S38 | aggregation set sums to all causes | reconciliation | FAIL | diseases |
| S39 | aggregation set members do not overlap | consistency | FAIL | diseases |
| S40 | months sum to the published year total | consistency | WARN | diseases |
| S41 | country equals regions plus foreign | consistency | WARN | diseases |
| S42 | national totals agree between PSA tables | consistency | WARN | diseases |
| S43 | weekly series has no gaps | completeness | WARN | diseases |
| S44 | dengue sources agree on a common basis | consistency | WARN | diseases |
| S45 | quarantined rows are the reviewed kind only | validity | FAIL | diseases |
| S46 | age groups sum to the metric total | reconciliation | FAIL | diseases |
| S47 | hospital encounter review flags | validity | WARN | diseases |
| S48 | coverage table matches the metric table | consistency | FAIL | diseases |
| S49 | mapped area codes exist in geography silver | validity | FAIL | diseases |
| S50 | source-printed area codes agree with geography silver | consistency | WARN | diseases |

### 3.6 Population (S51–S59)

| Code | Check | Type | Severity | Used by |
|---|---|---|---|---|
| S51 | population lineage columns not null | completeness | FAIL | population |
| S52 | population filled exactly when the status is valid | validity | FAIL | population |
| S53 | rows without a usable population | completeness | WARN | population |
| S54 | every geography area has a row for every census year | completeness | WARN | population |
| S55 | area total equals the sum of its cities and municipalities | consistency | WARN | population |
| S56 | national census total matches the PSA release | reconciliation | WARN | population |
| S57 | one population snapshot from the current PSGC release | consistency | WARN | population |
| S58 | change between census years above 30 percent | validity | WARN | population |
| S59 | population years are the configured census years | consistency | FAIL | population |

S56 becomes FAIL once `confirmed: true` is set for the controls in `sources_population.yaml`.

### 3.7 Workforce (S60–S79)

| Code | Check | Type | Severity | Used by |
|---|---|---|---|---|
| S60 | lineage columns not null | completeness | FAIL | workforce |
| S61 | every lineage reference has one build input | consistency | FAIL | workforce |
| S62 | table written by one succeeded build | consistency | FAIL | workforce |
| S63 | silver built from the current bronze loads and reference versions | consistency | FAIL | workforce |
| S64 | national control values match | reconciliation | FAIL | workforce |
| S65 | area control values match | reconciliation | FAIL | workforce |
| S66 | accepted values | validity | FAIL | workforce |
| S67 | eligibility follows the named rules | consistency | FAIL | workforce |
| S68 | totals equal their mutually exclusive components | reconciliation | WARN | workforce |
| S69 | split fields add up to the published total | consistency | WARN | workforce |
| S70 | 2025 province vs its municipalities and cities | consistency | WARN | workforce |
| S71 | PSA and FHSIS national totals agree 2018-2023 | consistency | WARN | workforce |
| S72 | province year-on-year change above 50% outside break years | consistency | WARN | workforce |
| S73 | quarantined bronze rows | completeness | WARN | workforce |
| S74 | denominator lineage groups follow source contribution | completeness | FAIL | workforce |
| S75 | every MAP key has a lineage group | consistency | FAIL | workforce |
| S76 | population agrees across sheets of the same workbook | consistency | WARN | workforce |
| S77 | PSMO label matched to a city by name (no province of that name) | consistency | WARN | workforce |
| S78 | listed oncologist control total | reconciliation | FAIL | workforce |
| S79 | area label overrides not yet reviewed | consistency | WARN | workforce |

### 3.8 Socioeconomic (S80–S96)

| Code | Check | Type | Severity | Used by |
|---|---|---|---|---|
| S80 | lineage columns not null | completeness | FAIL | socioeconomic |
| S81 | every lineage reference has one build input | consistency | FAIL | socioeconomic |
| S82 | table written by one succeeded build | consistency | FAIL | socioeconomic |
| S83 | silver built from the current bronze loads and reference tables | consistency | FAIL | socioeconomic |
| S84 | control values match | reconciliation | FAIL | socioeconomic |
| S85 | build inputs carry a load id and file checksum | completeness | WARN | socioeconomic |
| S86 | measure within its hard limits | validity | FAIL | socioeconomic |
| S87 | value agrees with its flag or status | validity | FAIL | socioeconomic |
| S88 | expected rows present, no others | completeness | FAIL | socioeconomic |
| S89 | metric source columns complete and valid | consistency | FAIL | socioeconomic |
| S90 | area attributes match the area map | consistency | FAIL | socioeconomic |
| S91 | level-1 shares sum to the total | reconciliation | FAIL | socioeconomic |
| S92 | financing agent hierarchy resolves | consistency | FAIL | socioeconomic |
| S93 | PSGC code unique in geography, at the same level | consistency | FAIL | socioeconomic |
| S94 | incidence fell by more than 15 points or reached zero | consistency | WARN | socioeconomic |
| S95 | rows not eligible for comparison with PSGC-based data | consistency | WARN | socioeconomic |
| S96 | definition not confirmed yet | completeness | WARN | socioeconomic |

## 4. Gold (G)

| Code | Check | Severity |
|---|---|---|
| G00 | QC ran without error | FAIL |
| G01 | Table has rows | FAIL |
| G02 | Primary key complete and unique | FAIL |
| G03 | Grain (natural key) unique | FAIL |
| G04 | Foreign key resolves to its dimension | FAIL |
| G05 | Published table = its latest succeeded build (rows; no data write after the build version) | FAIL |
| G06 | Built from the latest build of every input (freshness) | FAIL |
| G07 | Control total: gold = silver | FAIL (claims: WARN when lower) |
| G08 | Value and `value_status` consistent; measures on their basis | FAIL |
| G09 | Default view, mart or seed readable and not empty | FAIL |
| G10 | One preferred source per disease series (selection contract) | FAIL |
| G11 | Measure values in a valid range | FAIL |
| G12 | Content fingerprint unchanged since the previous QC run (idempotency) | WARN |
| G13 | Census population change between censuses plausible | WARN |

## 5. The same idea under different codes

Each silver domain took its own block of codes, so one idea can have several codes:

| Idea | Diseases | Facilities | Workforce | Socioeconomic | Population | Gold |
|---|---|---|---|---|---|---|
| Lineage columns not null | S30 | S13 | S60 | S80 | S51 | — |
| Each lineage reference has one build input | S31 | S14 | S61 | S81 | — | — |
| Written by one succeeded build | S32 | S15 | S62 | S82 | — | G05 |
| Built from the current inputs (freshness) | S33 | S16 | S63 | S83 | S57 | G06 |
| Control values | S34 | S21 | S64, S65, S78 | S84 | S56 | G07 |
| Quarantined rows listed | S45 | S28 | S73 | — | — | — |

## 6. Registry

Codes and their default severity live in `public_health.quality.check_registry`, filled by `quality_registry_seed.sql`. The seed does not yet hold every code (GB, HB, B16, S59, the G codes; O-17), so the scripts run with `strict_registry=False`, except population QC. Once the seed is complete, every script switches to `strict_registry=True` and an unknown code stops the run (to-do 7).

## 7. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Page written from the QC scripts' check lists |