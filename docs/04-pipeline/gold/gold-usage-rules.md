# Gold usage rules

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Rules for querying and interpreting gold mart data.

## Aggregation

* **Never sum across ownership** without checking. Government and private are separate dimensions. Summing them gives a total, but hides the ownership split.
* **Never sum across facility levels** without checking. Level 1, 2, 3, and Specialist hospitals have different capacity profiles.
* **National totals are not the sum of regional totals** if HUCs and ICCs are counted separately. Province rollups exclude HUCs and ICCs.

## Filters

* For S2 bed occupancy, always filter `baseline_eligible = true` to get comparable reports.
* For disease data, filter `age_group = 'All ages'` unless you specifically need an age breakdown.
* Exclude `Philippines` and `Foreign` rows from regional sums. They are national totals, not regional.

## Source priority

* For BHS counts: PSA BHS by region (`psa_bhs_region_annual`) covers 2006–2023 at region level. FHSIS (`doh_fhsis_demographic`) covers 2018–2025 at province/city level. Use FHSIS for province/city analysis and PSA for longer historical trends.
* For hospital counts: NHFR/HFSRB registry (current snapshot) for facility-level analysis. PSA annual for historical trends.

## Population denominator

* Use the closest population year to the metric's reference year. Available: 2015, 2020, 2024.
* If population is null (e.g. NCR districts in some sources), the rate is null, not zero.

## Zero vs missing

* A zero count means the source reported zero.
* A null means the source did not report for that area/year.
* Never treat null as zero in aggregations.

## Restricted data

* S2 bed occupancy uses FOI-restricted data. Do not export or share S2 results outside the project workspace.
* See [data governance](../../08-governance/data-governance.md) for sharing classes.
