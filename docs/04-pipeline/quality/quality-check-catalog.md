# Quality check catalog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Every check code in the platform, in one list. A code has one meaning in every domain and is never reused. `*00` always means "the QC script crashed".

The names and severities here are the ones in the scripts (`CHECKS` dictionaries and recorded `check_name`). How each check works, what fails it and what to do: [bronze quality checks](../bronze/bronze-quality-checks.md), [silver quality checks](../silver/silver-quality-checks.md), and [gold analytical validation and traceability](../gold/analytical-validation-and-traceability.md). Rules for severities and gates: [quality control framework](quality-control-framework.md).

Thresholds and failure actions per code are in [silver quality checks](../silver/silver-quality-checks.md) ("Fails when" column, section 16) and [bronze quality checks](../bronze/bronze-quality-checks.md). FAIL stops the job; WARN is recorded and reviewed.

Status date: 2026-10-21. Back to the [quality overview](README.md).

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

SQL build gates in silver and gold have names, not codes. The layer pages list them per file ([silver](../silver/silver-quality-checks.md) section 4, [gold](../gold/analytical-validation-and-traceability.md) section 3).

## 2. Bronze

### 2.1 File domains and population (B)

| Code | Check | Severity |
|---|---|---|
| B00 | QC ran without error | FAIL |
| B01 | Table exists and has rows for the source | FAIL |
| B02 | The loader loaded every file the YAML lists | FAIL |
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
| B13 | Rows per file = the loader's `processed` log row for the same load | FAIL, also when the loader log is unreadable |
| B14 | No files in the table outside the YAML | WARN |
| B15 | Every data column is STRING | FAIL |
| B16 | Nested population payload parses (population only) | WARN |

Population QC runs B00, B01, B04, B05, B07, B10, B13, B15 and B16; file and sheet checks do not apply to an API source.

### 2.2 PSGC snapshot (GB)

Every GB check is FAIL. GB13 is WARN only when the load log is unreadable.

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
| GB13 | Rows = the loader's `processed` log row (WARN if the log is unreadable) |

### 2.3 HDX boundaries (HB)

Every HB check is FAIL. No override can skip one.

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

| Code | Check | Severity | Used by |
|---|---|---|---|
| S00 | QC ran without error | FAIL | All |
| S01 | Table exists and has rows | FAIL | All |
| S02 | Grain key not null | FAIL | All |
| S03 | Grain key unique | FAIL | All |
| S04 | PSGC code found in geography | WARN | Population, facilities, socioeconomic, cross-domain (workforce) |
| S05 | Admin level valid | FAIL | Facilities |
| S06 | Counts non-negative | FAIL | Population, facilities, diseases, workforce |
| S07 | Rates within range | WARN | Socioeconomic |
| S08 | Period within expected range | FAIL | All domains, cross-domain |
| S09 | Bronze to silver rows reconcile | FAIL | All domains |
| S10 | Metric totals preserved | FAIL | Diseases, socioeconomic |
| S11 | Accepted values | WARN | Facilities |
| S12 | Metric null rate under threshold | WARN | Diseases |

### 3.3 Facilities (S13–S28)

| Code | Check | Severity |
|---|---|---|
| S13 | Lineage columns not null | FAIL |
| S14 | Each file or sheet referenced has one build input | FAIL |
| S15 | Table written by the latest succeeded build | FAIL |
| S16 | Built from the current bronze loads and reference versions | FAIL (WARN: same rows, new reference version) |
| S17 | One load time and one ingestion-log row per input | FAIL |
| S18 | NHFR id in at most one facility | FAIL |
| S19 | Registry lineage groups follow `in_nhfr` / `in_hfsrb` | FAIL |
| S20 | Every metric source key has a lineage group | FAIL |
| S21 | Control totals match | FAIL (WARN on a new file) |
| S22 | Id map and registry keys agree | FAIL |
| S23 | Bed columns follow their definitions | FAIL |
| S24 | Bed occupancy eligibility follows the named rules | FAIL |
| S25 | BOR above 100% | WARN |
| S26 | FHSIS region = its provinces + listed cities | WARN |
| S27 | OSM points placed by city tag only, or tag disagrees | WARN |
| S28 | Quarantined bronze rows | WARN |

### 3.4 Cross-domain (S29, S97–S99, and shared codes it runs)

| Code | Check | Severity |
|---|---|---|
| S00 | QC ran without error | FAIL |
| S04 | PSGC code found in geography (workforce) | WARN |
| S08 | Period within expected range (no future year) | FAIL |
| S29 | Quarantined rows within the limit | Banded: PASS at 0; WARN up to 5% or ≤ 10 rows; FAIL above both |
| S97 | Ratio per population inside the plausible band | WARN |
| S98 | Latest data year of each source is recent | WARN |
| S99 | Reported population agrees with census | WARN |

### 3.5 Diseases (S30–S50)

| Code | Check | Severity |
|---|---|---|
| S30 | Lineage columns not null | FAIL |
| S31 | Each lineage reference has one build input | FAIL |
| S32 | Written by one succeeded build | FAIL |
| S33 | Built from the current bronze loads | FAIL |
| S34 | Control values match | FAIL |
| S35 | Modelled value within its bounds | FAIL |
| S36 | Value, status and definitions consistent | FAIL |
| S37 | Disease and area keys resolve | FAIL |
| S38 | Aggregation set sums to all causes | FAIL |
| S39 | Aggregation set members don't overlap | FAIL |
| S40 | Months sum to the published year total | WARN |
| S41 | Country = regions + foreign | WARN |
| S42 | National totals agree between PSA tables | WARN |
| S43 | Weekly series has no gaps | WARN |
| S44 | Dengue sources agree on a common basis | WARN |
| S45 | Quarantined rows are the reviewed kind only | FAIL |
| S46 | Age groups sum to the metric total | FAIL |
| S47 | Hospital encounter review flags | WARN |
| S48 | Coverage table matches the metric table | FAIL |
| S49 | Mapped area codes exist in geography | FAIL |
| S50 | Source-printed codes agree with geography | WARN |

### 3.6 Population (S51–S59)

| Code | Check | Severity |
|---|---|---|
| S51 | Lineage columns not null | FAIL |
| S52 | Population filled exactly when valid | FAIL |
| S53 | Rows without a usable population | WARN |
| S54 | Every area has every census year | WARN |
| S55 | Area total = its cities and municipalities | WARN |
| S56 | National total matches the PSA release | WARN (FAIL once `confirmed: true`) |
| S57 | One snapshot from the current PSGC release | WARN |
| S58 | Change between census years above 30% | WARN |
| S59 | Years are the configured census years | FAIL |

### 3.7 Workforce (S60–S79)

| Code | Check | Severity |
|---|---|---|
| S60 | Lineage columns not null | FAIL |
| S61 | Each lineage reference has one build input | FAIL |
| S62 | Written by one succeeded build | FAIL |
| S63 | Built from the current bronze loads and reference versions | FAIL (WARN: same rows, new version) |
| S64 | National control values match | FAIL |
| S65 | Area control values match | FAIL |
| S66 | Accepted values | FAIL |
| S67 | Eligibility follows the named rules | FAIL |
| S68 | Totals equal their components | WARN |
| S69 | Splits add up to the total | WARN |
| S70 | 2025 province vs its municipalities and cities | WARN |
| S71 | PSA and FHSIS national totals agree | WARN |
| S72 | Province change above 50% outside break years | WARN |
| S73 | Quarantined bronze rows | WARN |
| S74 | Denominator lineage groups follow source contribution | FAIL |
| S75 | Every metric source key has a lineage group | FAIL |
| S76 | Population agrees across sheets of one workbook | WARN |
| S77 | PSMO label matched to a city by name | WARN |
| S78 | Listed oncologist control total | FAIL |
| S79 | Area label overrides not reviewed | WARN |

### 3.8 Socioeconomic (S80–S96)

| Code | Check | Severity |
|---|---|---|
| S80 | Lineage columns not null | FAIL |
| S81 | Each lineage reference has one build input | FAIL |
| S82 | Written by one succeeded build | FAIL |
| S83 | Built from the current bronze loads and reference tables | FAIL |
| S84 | Control values match | FAIL |
| S85 | Build inputs carry a load id and file checksum | WARN |
| S86 | Measure within its hard limits | FAIL |
| S87 | Value agrees with its flag or status | FAIL |
| S88 | Expected rows present, no others | FAIL |
| S89 | Metric source columns complete and valid | FAIL |
| S90 | Area attributes match the area map | FAIL |
| S91 | Level-1 shares sum to the total | FAIL |
| S92 | Financing agent hierarchy resolves | FAIL |
| S93 | PSGC code unique in geography, same level | FAIL |
| S94 | Incidence fell by more than 15 points, or reached zero | WARN |
| S95 | Rows not eligible for comparison with PSGC data | WARN |
| S96 | Definition not confirmed yet | WARN |

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

G07 has 13 controls. G08 has six consistency rules. The [gold validation page](../gold/analytical-validation-and-traceability.md), section 4, lists both.

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

This page is for people. The scripts use a table instead: `public_health.quality.check_registry`. It holds the same codes, with their layer, type and default severity.

| Item | How it works |
|---|---|
| Filled by | `quality_registry_seed.sql`, in the setup job, on every run. It only adds missing codes, so a rerun changes nothing |
| Checked by | `qc_registry`, the last task of the pipeline job (`quality_registry_check.sql`). It fails when a script uses a code the registry does not hold, or holds under another layer |
| Holds today | Every code on this page (since 2026-10-21) |
| Strict mode | On since 2026-10-21. `strict_registry=True` is the default in `dq_utils.py` and in `psgc_population_silver_qc.py`; `qc_registry` passed in the final runs first. An unknown code now stops its QC script. The first strict run is the next job run (O-17) |

**Adding a check code:** add it to the script, to this page, and to Step 1b of `quality_registry_seed.sql`, in the same pull request. If you forget the seed, `qc_registry` fails and names the code.

## 7. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Page written from the QC scripts' check lists (silver chat) |
| 2026-10-20 | Merged with the gold pass: S tables per domain, the gold validation link, named build gates, G07/G08 pointer |
| 2026-10-21 | Section 6 rewritten: the seed holds every code and runs in the setup job; the `qc_registry` job task checks it; only the switch to `strict_registry=True` is left (O-17) |
| 2026-10-21 | Section 6: strict mode on (O-17 closed) |
