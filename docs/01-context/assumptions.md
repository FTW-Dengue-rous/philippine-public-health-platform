# Assumptions

This page lists what the platform assumes to be true. Each assumption shapes the results. If one turns out wrong, the results that depend on it change too.

Status date: 2026-10-20. Each row names where the assumption shows in the data, so you can check it.

Limits of the study and the data, and the team's recommendations, are in [limitations and recommendations](limitations-and-recommendations.md).

---

## 1. Assumptions

| ID | Assumption | Why the team accepts it | Where it shows |
|---|---|---|---|
| AS-01 | The Q2 2024 PSGC snapshot is the one geography for all years | One code set lets every domain join. Older areas keep named keys, for example `hist:maguindanao` | `dim_geography.snapshot_date` |
| AS-02 | The facility registry (NHFR and HFSRB) lists the facilities that exist | It is the official registry. "Recorded" means listed. It does not prove that a facility exists or not | `has_hospital_recorded` |
| AS-03 | Authorized beds stand in for capacity | No source gives staffed beds | `authorized_beds`, `analysis_beds_basis` |
| AS-04 | A count and a population are comparable when their years differ by 2 years or less | Census years are 2015, 2020 and 2024 only | Mart rates are null outside the window (O-15) |
| AS-05 | IHME province estimates include their HUCs | Death rates fall in the normal range only when the HUC population is included (D-42) | `area_coverage_map` |
| AS-06 | HDX dengue province rows exclude the cities the source lists apart | Cities report more cases than their province in 27 of 28 pairs (D-43) | `area_coverage_map` |
| AS-07 | Each HDX dengue date closes its week. Week numbers are ISO weeks | This reading matches DOH counts in 714 region-weeks (D-44) | `dim_date.period_basis` |
| AS-08 | UP NOAH regional dengue counts are DOH counts by ISO week, not approximations | The UP NOAH data dictionary says so (D-46) | `source_priority` |
| AS-09 | A bed occupancy rate (BOR) above 150% is a reporting error, not real load | Some values exceed 1,000% | `baseline_eligible`, `exclusion_reason` |
| AS-10 | Planning units are each province without its HUCs, each HUC, and NCR | Sources publish HUCs apart from their provinces | `mart_base_planning_unit` (O-01) |
| AS-11 | The mart values are team judgements, not published standards: poverty bands 10/20/30%, gap fifths, the "two of three" rule, 3 weight sets, 80% dialysis completeness | The team agreed each value with a reason (D-56). `gold_o13_evidence.sql` holds the evidence queries | `mart_area_priority`, `mart_kidney_case_study` |

## 2. History of updates

| Date | Change |
|---|---|
| 2026-10-19 | Written as section 1 of "Assumptions and limitations" |
| 2026-10-19 | AS-11 updated for D-56 |
| 2026-10-20 | Split into its own page. Data limitations (LM-xx) moved to [limitations and recommendations](limitations-and-recommendations.md). Engineering limitations (EL-xx) moved to [known issues and backlog](../08-governance/known-issues-and-backlog.md) |
