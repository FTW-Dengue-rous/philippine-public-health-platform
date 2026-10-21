# Silver — population

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Census population for every PSGC area, used by gold as the denominator for rates (cases, beds or health workers per population). It comes from the same PSGC payload as the geography table, so its codes always match the spine.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.1. Back to the [silver overview](README.md).

## Source

| Source | Bronze table | Content |
|---|---|---|
| PSA PSGC, release Q2_2024 | `bronze.geography_bronze`, column `populations_json` | Census counts per area: POPCEN 2015, CPH 2020, POPCEN 2024 |

Settings: `config/sources_population.yaml` (census years and national control totals under `psgc_population.silver_qc`).

## Table

| Table | One row is | Key | Rows (last build) |
|---|---|---|---|
| `population_silver` | One area in one census year | `psgc_code`, `population_year`, `source_version` | 127,945 |

## How it is built

`psgc_population_silver.py` unpacks the nested population list of each geography record into one row per area and year. Each value gets a parse status:

| Status | Meaning | `population` |
|---|---|---|
| `VALID` | Digits only, after removing commas and spaces | The number |
| `VALID_WITH_NOTE` | As `VALID`, with a leading bracketed note moved to `population_note`, e.g. "(excluding CITY OF ANGELES) 1,234" | The number |
| `MISSING` | Null, empty or "-" | Null, never 0 |
| `INVALID` | Anything else | Null; the original stays in `population_raw` |

The build stops before replacing the table if a key is duplicated or a status is not one of the four.

## Quality checks

Every check of this domain, with its rule and severity: [silver quality checks](silver-quality-checks.md#8-population-psgc_population_silver_qcpy).

`psgc_population_silver_qc.py`:

| Code | Check | Severity |
|---|---|---|
| S01–S03 | Table has rows; key not null and unique | FAIL |
| S04 | Every code is in geography | WARN |
| S06, S08 | No negative population; years are plausible census years | FAIL |
| S09 | Bronze observations = silver rows, statuses valid | FAIL |
| S51, S52 | Lineage filled; value agrees with its status | FAIL |
| S53 | Rows without a usable population, listed | WARN |
| S54 | Every area has a row for every census year | WARN |
| S55 | Province and region totals = sum of their cities and municipalities | WARN |
| S56 | National total matches the PSA release, within 0.1% (control values in the YAML) | WARN until confirmed |
| S57 | One population snapshot, from the same PSGC release as geography | WARN |
| S58 | Change between census years above 30% | WARN |
| S59 | The years in the table are exactly the configured census years | FAIL |

**Expected WARNs** (source gaps, not errors; the live lists are in the `qc_results` detail):

- S54, S56: the Negros Island Region has no region row for 2015 and 2020; Sulu has no 2024 rows.
- S55: Maguindanao del Norte 2015 and 2020 (province total leaves out Cotabato City); Benguet 2015 (444,224 published against 446,224 in its parts); regions changed by the Negros Island Region and BARMM regrouping.
- S53, S58: a few missing cells and large changes, listed in the detail.

## Rules for users

- Use `population` only where the status is `VALID` or `VALID_WITH_NOTE`. A missing value is null, never 0.
- Census years are 2015, 2020 and 2024. A rate for another year needs a stated rule for which census year is its denominator; gold states it in [metric definitions](../gold/metric-definitions.md).
- Gold does not use a generic “closest year” fallback. Its cross-domain rates require a population year within two years of the count year; otherwise the rate is null. Sulu remains null where the 2024 denominator is unavailable.
- A province total in 2024 leaves out its highly urbanized cities, like the PSGC itself.

## Limitations

- Population is the census count only; there are no yearly projections in silver.
- When a new census year arrives, add it to `census_years` (and its control) in the YAML; S59 fails until you do.
