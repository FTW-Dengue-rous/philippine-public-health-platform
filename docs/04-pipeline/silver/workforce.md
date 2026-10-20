# Silver — workforce

Who provides care: public health workers by profession, area and year, the population figures FHSIS prints beside them, and a directory count of medical oncologists.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.4. Back to the [silver overview](README.md).

## Sources

| Source | What it gives | Notes |
|---|---|---|
| DOH FHSIS health workers, 2018–2025 | Doctors, nurses, midwives and six other professions by area | One workbook per year; layout changes every year; only the 2025 file prints PSGC codes |
| PSA Statistical Yearbook 9.14, 2012–2023 | Government medical practitioners by region | History source for 2012–2017 |
| PSMO oncologist directory | Listed medical oncologists by area of practice | One snapshot |

Settings: `config/sources_workforce.yaml`, including the national, area and PSMO control values QC checks.

## Tables

| Table | One row is | Rows (last build) |
|---|---|---|
| `workforce_headcount_silver` (`02`) | One profession in one area and year from one source | 28,080 |
| `workforce_area_denominator_silver` (`03`) | One area and year: population and households as FHSIS prints them | 3,024 |
| `workforce_specialist_silver` (`04`) | One PSMO area listing in one snapshot | 52 |

## How it is built

| Step | File | What happens |
|---|---|---|
| Reference load | `00` | Area exceptions, row overrides (each bound to the workbook checksum it was written for) and PSMO exceptions |
| Resolve areas | `01` | Every FHSIS label is resolved once: row override → the printed PSGC code (2025) → exceptions → name, level and parent region. No match, or more than one, stops the build. Also writes the settings shared by `02` and `03` |
| Headcounts | `02` | Professions reshaped to rows; a status per cell (`ok`, `no_report`, `blank`, `zero_no_data` …); `analysis_eligible` with named rules R1–R5 for reported inconsistencies; split by sex (2018) or by employer (from 2019) |
| Denominators | `03` | FHSIS population and households per area and year; two lineage groups, because they can come from different sheets |
| Oncologists | `04` | PSMO listings; composite labels ("Negros Oriental / Dumaguete City") stay one row and are never split or summed |

Shared settings, set once in `01` and recorded with each build: the files that print codes (2025), the year province rows change coverage (2023), the nurse series break (2019), and the number of regions in the geography snapshot. New-file protection: a new PSA year column, an FHSIS year without a denominator sheet, or a profession without a printed label stops the build.

**Source roles:** PSA is preferred for 2012–2017; FHSIS from 2018. PSA rows for 2018–2023 are kept as `cross_check`.

## Quality checks

Every check of this domain, with its rule and severity: [silver quality checks](silver-quality-checks.md#11-workforce-workforce_silver_qcpy).

`workforce_silver_qc.py`, codes S01–S09 and S60–S79. Highlights:

| Code | Check |
|---|---|
| S63 | Silver was built from the bronze loads and reference versions that are there now |
| S64, S65 | National and area control values from the YAML |
| S66, S67 | Accepted values; every exclusion follows a named rule |
| S68, S69 | Totals equal their parts; employer or sex splits add up (WARN) |
| S71 | PSA and FHSIS national totals agree where both exist (WARN) |
| S72 | Province change above 50% outside break years (WARN) |
| S73 | Quarantined rows listed (WARN) |
| S78 | PSMO listed total |

**Expected WARNs:** source consistency (S68–S72), quarantined blank-label rows (S73) and labels under review (S79).

## Rules for users

- Use rows with `analysis_eligible = true` for analysis; the others carry `exclusion_reason` and a `display_label`.
- Nurses before and after 2019 are different series (`series_definition`, `is_break_year`).
- Province rows before 2023 leave out the cities FHSIS lists apart; from 2023 they leave out highly urbanized and independent component cities only (`geo_coverage_basis`).
- FHSIS population in `workforce_area_denominator_silver` is a cross-check; rates use the census population (decision D4 of the workforce plan).
- Oncologist listings repeat across areas; never add them into a regional or national total.

## Limitations

- The 2019 employer split is incomplete; use totals for 2019.
- A few labels are under review (Davao, San Jose); they are listed in the backlog.
- The PSMO count unit is not confirmed (`count_unit = 'unconfirmed'`).
