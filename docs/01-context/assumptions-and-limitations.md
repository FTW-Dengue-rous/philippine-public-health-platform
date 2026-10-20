# Assumptions and limitations

This page lists what the platform assumes and what it cannot tell you. Carry these into every chart, comparison and conclusion.

Owner: LUNASaan Documentation Team
Last updated: 2026-10-20

Each row names where the limit is handled, so you can check it in the data.

---

## 1. Assumptions

| ID | Assumption | Why we accept it | Where it shows |
|---|---|---|---|
| AS-01 | The Q2 2024 PSGC snapshot is the single geography for all years | One code set lets every domain join. Older areas are kept as named keys (for example `hist:maguindanao`) | `dim_geography.snapshot_date` |
| AS-02 | The facility registry (NHFR + HFSRB) lists the facilities that exist | It is the official registry. "Recorded" means listed, not proven to exist or not exist | `has_hospital_recorded` |
| AS-03 | Authorized beds stand in for capacity | No staffed-bed data is available | `authorized_beds`, `analysis_beds_basis` |
| AS-04 | A count and a population can be compared when their years differ by 2 years or less | Census years are 2015, 2020, 2024 only | Mart rates are null outside the window (O-15) |
| AS-05 | IHME province estimates include their HUCs | Death rates only fall in the normal range with HUC population included (D-42) | `area_coverage_map` |
| AS-06 | HDX dengue province rows exclude the cities the source lists separately | Cities report more cases than their province in 27 of 28 pairs (D-43) | `area_coverage_map` |
| AS-07 | HDX dengue dates close their week; week numbers are ISO weeks | Matches DOH counts in 714 region-weeks (D-44) | `dim_date.period_basis` |
| AS-08 | UP NOAH regional dengue counts are DOH counts by ISO week, not approximations | UP NOAH data dictionary (D-46) | `source_priority` |
| AS-09 | Bed occupancy (BOR) above 150% is a reporting error, not real load | Values reach above 1,000% | `baseline_eligible`, `exclusion_reason` |
| AS-10 | Planning units are each province without its HUCs, each HUC, and NCR | Sources publish HUCs apart from provinces | `mart_base_planning_unit` (proposal, O-01) |
| AS-11 | The mart values (poverty bands 10/20/30%, gap fifths, the "two of three" rule, 3 weight sets, 80% dialysis completeness) are judgements, not published standards | Agreed by the team with a reason per value (D-56); evidence queries in `gold_o13_evidence.sql` | `mart_area_priority`, `mart_kidney_case_study` |

## 2. Limitations: what the data cannot tell you

| ID | Limitation | Effect | Treatment |
|---|---|---|---|
| LM-01 | Disease data is counts of cases and deaths, not admissions | Bed sufficiency per disease cannot be answered | BQ2 stays a stretch goal; core dengue view compares peaks to capacity only |
| LM-02 | Capacity is a 2026 registry snapshot; disease and population are 2024–2025 | Years differ across the comparison | Labelled on every chart |
| LM-03 | "No hospital recorded" is not "no hospital" | An unlisted facility looks like a gap | Wording "recorded" everywhere |
| LM-04 | Distances are straight-line between area centres | Travel time and roads are not measured | Labelled "straight-line"; nearest *locality with* a recorded hospital |
| LM-05 | OpenStreetMap points are crowd-sourced and uneven | Not a facility count; absence from OSM does not mean a facility does not exist | Map layer and distance only (`ref_osm_healthsite_point`) |
| LM-06 | Sources count provinces differently (with or without HUCs) | Some province figures are not comparable | `not_separable` / `comparison_eligible = false`, with a reason |
| LM-07 | Sulu has no 2024 census count in the source | No Sulu rates | Population null, no fallback to 2020 (D-41) |
| LM-08 | Weighted occupancy uses eligible records only (BOR ≤ 150) | Understates load where many records exceed 150, mostly government hospitals | Labelled "eligible records" |
| LM-09 | BOR bed basis and reporting period not confirmed by HFSRB | Occupancy definitions are provisional | `bor_basis_confirmed = false`, `period_confirmed = false` (O-12) |
| LM-10 | PhilHealth claims show the place of care, not the patient's residence | Cannot measure travel for care | Claims geography = facility location |
| LM-11 | PhilHealth claims series have breaks: COVID 2020–2021, 2024 case-rate change, IHD with MI definition change in 2025 | Amounts and some counts are not comparable across breaks | Flags in silver; notes in marts and charts |
| LM-12 | Workforce nurse series changes definition in 2019; hospital series in 2013 | Trends across the break mislead | `is_break_year` flags |
| LM-13 | IHME values are modelled, not reported | Different meaning from registered counts | `value_type = modelled`; kept separate in marts |
| LM-14 | Restricted sources are published as aggregates only; cells under 3 suppressed | Small areas may show "suppressed" | `value_status = 'suppressed'` ([data governance](../08-governance/data-governance.md)) |
| LM-15 | Some area labels still await review (18 FHSIS TB SGA rows, 34 Davao city labels, 21 claims pairs, San Jose in Oriental Mindoro) | Those rows are held back | Quarantine or `REVIEW` flags with reasons, recorded in `quality.row_disposition` |
| LM-16 | Admin boundaries cover ADM1–ADM3 only; 8 SGA municipalities have no polygon | No map shape or density for them | `has_boundary = false` |
| LM-17 | Preventive TB treatment coverage is estimated from one FHSIS year (2025) | No trend | Single-year view in mart 21 |
| LM-18 | Disease sources report in different period grains: DOH FOI dengue by month, UP NOAH and HDX by ISO week, the rest by year | Periods cannot be added or compared across grains; a 53rd ISO week stays its own week (AS-07) | Every silver row keeps its source's period and `period_basis`; read `diseases_source_coverage_silver` (periods expected, present and missing per source and year) before comparing |
| LM-19 | The DOH FOI dengue release is a snapshot: it covers January 2021 to September 2025 (file as of 2025-09-30) | 2025 totals are not a full year; comparing them with full years understates 2025 | Partial coverage is recorded in `diseases_source_coverage_silver`; charts label 2025 as partial |
| LM-20 | PSA poverty estimates are biennial (2021, 2023, 2025) and carry a published coefficient of variation | No yearly poverty series; estimates with a CV above the build setting (10%) are low precision | Never interpolate between reporting years; `incidence_precision` and `poor_population_precision` say `ok`, `use_with_caution` or `unknown` |
| LM-21 | HFSRB licence numbers are not unique; some cover more than one facility | Grouping or deduplicating facilities by licence number is wrong | The id map keys a row without a usable NHFR code by `name:<category>|<normalised name>|<municipality PSGC code>`; join on `facility_key` |
| LM-22 | NCR areas and highly urbanized cities have no province in the PSGC spine | Province rollups leave them out; a query that assumes every area has a province gets nulls for NCR | Region rollups include them; the HUC-to-province crosswalk is backlog item 19 |

## 3. How far the results go

The platform measures recorded availability: facilities listed, beds authorized, workers counted, cases reported. A recorded facility, an authorized bed or a counted worker does not prove a service was delivered to a patient. The platform measures no health outcomes and proves no causal effects or real-world impact; it is a data engineering capstone. And a missing value is never a zero: a population can be null (`population_silver`), a published count can be "no report" (`no_report_measures`), and a restricted cell can be suppressed (LM-14). Read the status before treating an empty cell as zero.

## 4. Engineering limitations

These affect how the pipeline runs, not what the data means. The backlog tracks them: [known issues and backlog](../08-governance/known-issues-and-backlog.md).

| ID | Limitation | Current treatment |
|---|---|---|
| EL-01 | Silver observation tables and gold are full rebuilds on every run, even when no bronze file changed. Cost grows with total rows, not new rows | Deliberate at current volume (D-57): every gate checks the whole table and a rule change reaches every row. Recommended cost order: skip unchanged runs, then per-domain skip, then per-source incremental when a domain reaches millions of rows. Full explanation: [silver rebuild strategy](../04-pipeline/silver/rebuild-strategy.md) |
| EL-02 | Silver reads bronze at its current version, not a pinned version | Silver runs right after bronze QC in the same job |
| EL-03 | `check_registry` not seeded; most QC scripts run with `strict_registry=False` | Seed at the end of the project (O-17) |
| EL-04 | Bronze loader and QC code copied into four domain files | Kept identical by hand; shared module in backlog |
| EL-05 | `sharing: restricted` is declared, not enforced by grants | Unity Catalog grants in backlog |
| EL-06 | Parsing-setting changes in YAML are not detected | Reload with `--force_keys` |
| EL-07 | The team runs on a personal Databricks workspace | The FTW org workspace could not reach the external volume |
| EL-08 | The job has no trigger or active schedule; runs are started by hand | Data arrives through people, so whoever lands it starts the job (D-59). Trigger and skip rules are recommendations R0, R1 |
| EL-09 | CI checks on `dev` fail and automated tests are thin | Fixed after submission; more pytest coverage is in the backlog |
| EL-10 | HDX admin boundaries are landed by hand: the ingestion notebook in `src/01_ingestion` runs outside the job and writes the handoff the loader validates; no `ingestion_metadata` row is written (KI-06) | A boundaries update needs a person, and the gate cannot detect a stale source the usual way | Procedure in the [setup guide](../07-operations/setup-guide.md), section 3; the gate reconciles counts to the manifest (HB01 / HB02) |

## 5. History of updates

| Date | Change |
|---|---|
| 2026-10-19 | Page written from the decision log, layer overviews and gold README |
| 2026-10-19 | EL-01 rewritten for D-57 (full rebuild kept; cost recommendations); AS-11 updated for D-56 |
| 2026-10-20 | EL-08 (manual runs, D-59) and EL-09 (CI on `dev`) added |
| 2026-10-20 | Integrated the second limitations draft: owner and update-date header added; LM-01 reworded (counts, not admissions); LM-18 to LM-22 added (period grains, partial 2025 dengue, poverty precision, licence numbers, NCR and HUC provinces); LM-05, LM-14 and LM-15 sharpened; "How far the results go" section added; EL-10 added (manual boundaries ingestion) |
