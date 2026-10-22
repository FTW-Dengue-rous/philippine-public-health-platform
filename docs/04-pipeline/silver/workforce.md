# Silver — workforce

Owner: LUNASaan Documentation Team
Last updated: 2026-10-22

Who provides care: public local health workers by profession, area and year (FHSIS), the population figures FHSIS prints beside them, and a directory count of medical oncologists.

Reference: [`src/03_silver/README.md`](../../../src/03_silver/README.md), section 4.4. Back to the [silver overview](README.md).

## Sources

| Source | What it gives | Notes |
|---|---|---|
| DOH FHSIS health workers, 2018–2025 | Doctors, nurses, midwives and six other professions by area, split into LGU-hired and DOH-hired. Public local health workers only (see [Scope and definitions](#scope-and-definitions)) | One workbook per year; layout changes every year; only the 2025 file prints PSGC codes |
| PSA Statistical Yearbook 9.14, 2012–2023 | Government medical practitioners by region | History source for 2012–2017. Its scope is not the same as FHSIS |
| PSMO oncologist directory | Listed medical oncologists by area of practice | One snapshot |

Settings: `config/sources_workforce.yaml`, including the national, area and PSMO control values QC checks.

## Scope and definitions

**What FHSIS counts.** The workforce tabs come from the FHSIS annual demographic data that each LGU submits on Form A1. The FHSIS Manual of Procedures (2018) names this item "total number of public local health workers". It uses it for the indicator "ratio of public health worker to population (LGU and DOH-hired)".

**LGU-hired and DOH-hired.** FHSIS does not publish a definition of either term. We use this working reading:

| Term | Our reading | Basis |
|---|---|---|
| LGU-hired | Health staff the LGU pays: provincial, city or municipal health office, RHUs, health centres, BHS | "Public local health workers" in the FHSIS manual |
| DOH-hired | Staff the DOH pays and deploys to the LGU health system, for example the Nurse Deployment Program and Doctors to the Barrios | The FHSIS manual mentions NDP nurses in field work; the PIDS evaluation of the DOH HRH deployment program |

Both groups together are the LGU primary care workforce. The split is a breakdown of one group, not two separate populations.

**What FHSIS does not count.**

- Private-sector workers.
- Most likely, hospital staff in LGU and DOH hospitals. FHSIS is a field health system. The USAID HRH2030 labour market study reports public hospital staff separately from LGU-hired and DOH-deployed staff.

**Open questions.** We have not confirmed whether job order and contractual staff are counted. We have not confirmed whether DOH-deployed staff placed in hospitals appear in the DOH-hired column. The DOH Epidemiology Bureau holds the Form A1 instructions; request them through FOI.

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

**Expected WARNs:** source consistency (S68–S72), quarantined blank-label rows (S73) and labels under review (S79). S71 is expected to differ: PSA counts government medical practitioners, FHSIS counts public local health workers.

## Rules for users

- Use rows with `analysis_eligible = true` for analysis; the others carry `exclusion_reason` and a `display_label`.
- Nurses before and after 2019 are different series (`series_definition`, `is_break_year`).
- Province rows before 2023 leave out the cities FHSIS lists apart; from 2023 they leave out highly urbanized and independent component cities only (`geo_coverage_basis`).
- FHSIS population in `workforce_area_denominator_silver` is a cross-check; rates use the census population (decision D4 of the workforce plan).
- Oncologist listings repeat across areas; never add them into a regional or national total.
- Call these counts "public local health workers" or "LGU primary care workforce". Do not call them the public-sector or national health workforce.

## Limitations

- The 2019 employer split is incomplete; use totals for 2019.
- A few labels are under review (Davao, San Jose); they are listed in the backlog.
- The PSMO count unit is not confirmed (`count_unit = 'unconfirmed'`).
- FHSIS publishes no definition of LGU-hired and DOH-hired. The readings in [Scope and definitions](#scope-and-definitions) are our working assumption.
- **Workforce scope.** FHSIS counts public local health workers only, for every profession. It excludes private-sector workers and most likely excludes hospital staff. The counts do not represent the whole Philippine health workforce or the whole public sector.
- PSA (`cross_check`) counts government medical practitioners. It has no LGU/DOH split, and its scope can include staff that FHSIS leaves out. Do not treat PSA and FHSIS as the same series.
- Ratios per 10,000 use this limited coverage (numerator: `headcount_total`; denominator: census population). They show recorded primary care supply against population. They do not prove an overall workforce shortage.
- A missing record means the source did not report a count. It does not mean zero workers.
- PSMO oncologists are a separate specialist directory and are outside this scope.

## Sources for the scope

- [FHSIS Manual of Procedures, 2018](https://pdfcoffee.com/the-fhsis-mop-ver-2018-pdf-free.html): Form A1 demographic data; "public local health workers"
- [PIDS DP 2021-07, process evaluation of the DOH HRH Deployment Program](https://pidswebs.pids.gov.ph/CDN/PUBLICATIONS/pidsdps2107.pdf)
- [USAID HRH2030 Philippines, health labour market analysis](https://hrh2030program.org/wp-content/uploads/2020/08/1.1_HRH2030PH_HLMA-Report.pdf)

## History of updates

| Date | Change |
|---|---|
| 2026-10-21 | Workforce scope limitation added: LGU- and DOH-hired only, private sector excluded |
| 2026-10-22 | Scope rewritten from the FHSIS manual: counts are public local health workers (Form A1). Added Scope and definitions, the working reading of LGU-hired and DOH-hired, the likely hospital-staff exclusion, open questions and sources. PSA scope separated from FHSIS. Removed the claim that the counts are the public-sector workforce |
