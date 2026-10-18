# Assumptions and limitations

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

## Geography

These limitations affect all questions that use geographic matching (BQ1, N1-N4, S1-S2, A1-A2, W1-W2, E1-E2, P1).

* **PSGC Q2 2024 is the reference geography.** All area names and codes are matched to this snapshot. PSGC codes change over time; older source data may use codes or names that no longer match. Unmatched names are logged in `facilities_area_exceptions` and `socioeconomic_silver_05_poverty_geography_check.sql`.
* **NCR has no provinces.** Silver tables handle this by falling back to the region name. Queries that assume every area has a province will return null for NCR districts.
* **HUC and ICC are separate from provinces.** Highly urbanized cities and independent component cities report directly to the region. Province-level rollups exclude them.

## Facility data

* **Recorded is not absence.** A facility not listed in NHFR or HFSRB does not prove it does not exist. It may be unregistered, unlisted, or listed under a variant name.
* **NHFR is the registry spine.** The platform uses NHFR hospitals as the base and matches HFSRB licensed lists to it. Facilities in HFSRB but not in NHFR are added as HFSRB-only rows.
* **Facility matching is not perfect.** The registry matches by NHFR code (numeric) and by normalized name + municipality. 71 NHFR-only and 48 HFSRB-only facilities were unmatched in the latest build. See [known issues](../08-governance/known-issues-and-backlog.md).
* **License numbers are not unique.** Some HFSRB license numbers cover multiple facilities. The source_record_id for HFSRB uses `name:<category>|<norm_name>|<psgc>` to disambiguate.

## Disease data

* **Yearly-only for some sources.** FOI dengue data is monthly; UP NOAH and HDX are weekly. Week definition is not fully reconciled across sources. Week 53 is folded into week 52.
* **Partial years.** 2025 dengue data ends at September. Never compare a partial year with a full year without adjustment.
* **Reporting lag.** The last 1–3 months before extraction are likely incomplete.

## Socioeconomic data

* **Poverty is biennial.** PSA poverty estimates are for 2021, 2023, and 2025. Do not interpolate between survey years.
* **HUC poverty coverage.** PSA poverty statistics include NCR districts but not all HUCs separately. Some HUCs are grouped with their province.
* **CV above 20%.** Estimates with a coefficient of variation above 20% are flagged in the notes column. Treat them as low precision.

## OSM and geospatial

* **OSM is incomplete.** OpenStreetMap healthsites are a community-maintained dataset. Absence from OSM does not mean a facility does not exist.
* **Admin boundaries require manual ingestion.** The admin boundaries loader needs a job parameter (`admin_boundaries_run_dir`) pointing to the latest ingestion run folder. A blank parameter fails fast.

## General

* **No real-world impact claims.** The platform is a data engineering capstone. It does not measure health outcomes or prove causal effects.
* **Population denominators vary by year.** Population comes from PSGC `populations_json` (2015, 2020, 2024). Choose the closest year to the metric's reference year.
* **Restricted data.** Bed occupancy and some FOI releases are for internal use only. See [data governance](../08-governance/data-governance.md).
