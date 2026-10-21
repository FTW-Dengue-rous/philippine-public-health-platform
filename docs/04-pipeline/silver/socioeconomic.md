# Silver — socioeconomic

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

The conditions around care: official poverty by area, how health spending is financed, spending per person, and child mortality by background. Poverty is the only table placed on PSGC areas; the others are national or by survey characteristic.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.5. Back to the [silver overview](README.md).

## Sources

| Source | What it gives | Years |
|---|---|---|
| PSA official poverty statistics (tab2, tab6) | Poverty threshold, incidence and poor population, among population, full year | 2021, 2023, 2025 |
| PSA Yearbook 9.26 | Share of current health expenditure by financing agent | 2016–2023 |
| PSA Yearbook 9.24 | Health expenditure per person and its growth | 2016–2023 |
| PSA Yearbook 9.9 (NDHS) | Infant, child and under-five mortality by region, residence, education and wealth | Surveys 2017, 2022 |

Settings: `config/sources_socioeconomic.yaml`, including the control values QC checks.

The poverty source is the PSA Full-Year 2025 release, configured with an as-of date of 2026-08-26. It contains 2021, 2023, and 2025 estimates; the pipeline does not interpolate missing years. A project rule in `socioeconomic_silver_01_poverty.sql` marks incidence or poor-population estimates with a coefficient of variation above 10% as `use_with_caution`. This is a precision flag, not a change to the source estimate.

## Tables

| Table | One row is | Rows (last build) |
|---|---|---|
| `socioeconomic_poverty_silver` (`01`) | One area and reporting year | 322 |
| `socioeconomic_health_expenditure_share_silver` (`02`) | One financing agent and year | 128 |
| `socioeconomic_health_expenditure_per_capita_silver` (`03`) | One national year | 8 |
| `socioeconomic_child_mortality_silver` (`04`) | One background characteristic and survey | 60 |

`05` is a check, not a table: it compares every code of the poverty area map with geography and lists name differences for review.

## How it is built

| Step | File | What happens |
|---|---|---|
| Reference load | `00` | The reviewed poverty area map: key, PSGC code, level, coverage basis, first estimate year, comparison eligibility |
| Poverty | `01` | A row is data because its area is in the map, never because its values look like numbers. Cell status `ok`, `not_published`, `not_computed` or `parse_error`. The two sheets are joined by area and year. Poor population converted from thousands to persons. Coefficient of variation → precision class (`ok`, `use_with_caution`, `unknown`) |
| Expenditure share | `02` | An approved list of 16 financing agents in a 3-level hierarchy; `a/` (below 0.05%) → 0.0 with `is_below_0_05` |
| Per capita | `03` | Rows found by label and position; the growth rate under a year is the growth into that year |
| Child mortality | `04` | An approved list of 30 characteristics; `*` → `suppressed` (null), a value in parentheses → `low_precision` |

Report years, the precision cut-off and the share tolerance are named settings recorded with each build. New-file protection: a bronze year column that the settings do not list stops the build.

## Quality checks

Every check of this domain, with its rule and severity: [silver quality checks](silver-quality-checks.md#12-socioeconomic-socioeconomic_silver_qcpy).

`socioeconomic_silver_qc.py`, codes S01–S10 and S80–S96. Highlights:

| Code | Check |
|---|---|
| S83 | Silver was built from the bronze loads and area map that are there now |
| S84 | Control values from the YAML |
| S86, S87 | Hard limits; value agrees with its flag or status |
| S88 | Exactly the expected rows (years and counts from the build settings) |
| S90 | Area attributes match the area map |
| S91 | Level-1 financing shares add up to the total |
| S93 | Every poverty PSGC code exists once in geography, at the same level |

**Expected WARNs:** S94 (incidence fell by more than 15 points or reached zero), S95 (areas not eligible for comparison with PSGC-based data), S96 (child mortality reference period not confirmed).

## Rules for users

- Poverty is among **population**, **full year**. Do not mix it with family-based or first-semester figures.
- Province rows with `comparison_eligible = false` cover a different population than PSGC province figures (they may include or leave out highly urbanized cities). See `exclusion_reason`.
- Do not interpolate between the published poverty years. A missing estimate remains missing and cannot support a rate or ranking for that year.
- Financing agents form a hierarchy: never add a parent to its children. Only level-1 agents add up to the total.
- Child mortality regions are the 17 regions of the old definition (no Negros Island Region): regional context only.
- `survey_year` is the survey, not the year deaths occurred.

## Limitations

- Coverage of some poverty provinces that include highly urbanized cities is not confirmed by PSA.
- The child mortality reference period is not confirmed (`reference_period` is null).
- Per capita spending changes population basis in 2020 and 2021, so growth across those years is not like for like.
