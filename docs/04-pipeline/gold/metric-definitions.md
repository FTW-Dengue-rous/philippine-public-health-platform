# Gold — metric definitions

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Every number gold computes, with its formula, denominator, unit, null rule and source. Silver holds counts; **gold computes every rate, share, rank and flag**. If a dashboard figure is not on this page, it is a count copied from a fact.

Status date: 2026-10-20. Back to the [gold overview](README.md).

---

## 1. Rules for every metric

| Rule | Why |
|---|---|
| A metric is null when any input is null. Null is never zero | A zero would look like "nothing there" and raise a gap flag that is a data gap |
| Rates use the **census population** of the unit, except the two FHSIS facility rates | One denominator across domains makes rates comparable (D-39) |
| A rate is normally null when the count year and the population year are more than **2 years** apart | O-15. The kidney mart retains its calculated rates for traceability, but marks such rows `comparison_eligible = false` and gives `outside_alignment_window` as the exclusion reason. |
| A rate is null when the population is null or 0 | A missing denominator gives no valid rate |
| Percentages from a source are never summed or averaged | A share of a share is not a share |
| Marts round rates for display: normally 2 decimals, ratios to whole persons, and distances to 0.1 km | Ranking uses the underlying unrounded value unless the relevant SQL states otherwise. TB notification rates are stored and displayed to 1 decimal. |

## 2. Supply

| Metric | Formula | Unit | Mart | Notes |
|---|---|---|---|---|
| `hospitals_recorded` | Count of listed hospitals in the locality | facilities | 14 | Registry snapshot |
| `hospital_beds` | Sum of `analysis_beds` of listed hospitals | beds | 14 | 0 if no hospital; null if hospitals but no bed count |
| `population_per_hospital` | census population ÷ hospitals | persons | 14 | Null when hospitals = 0 |
| `population_per_hospital_bed` | census population ÷ hospital beds | persons | 14 | Null when beds = 0 |
| `population_per_licensed_primary_care` | census population ÷ licensed primary care facilities | persons | 14 | Null when 0 |
| `beds_per_10k` | unit beds × 10,000 ÷ unit census population | per 10,000 | 16 | Registry analysis beds; window rule applies |
| `government_bed_share` | government beds ÷ all beds | 0–1 | 16 | Null when beds = 0 |
| `population_without_hospital` | Sum of the census population of the unit's localities with no hospital recorded | persons | 16 | Only localities with a count |
| `population_without_licensed_primary_care_recorded` | Same, for licensed primary care | persons | 16 | |
| `reported_bhs_per_10k` | FHSIS BHS × 10,000 ÷ **FHSIS-printed** population | per 10,000 | 16 | Source-specific rate; never compare with a census rate |
| `reported_health_centers_per_10k` | FHSIS health centres × 10,000 ÷ FHSIS-printed population | per 10,000 | 16 | Same |
| `dialysis_stations_per_100k` | stations reported × 100,000 ÷ census population | per 100,000 | 22 | Broad units include their HUCs |
| `stations_known_share` | dialysis facilities with a station count ÷ all dialysis facilities | 0–1 | 22 | Gate 4: compared only when ≥ 0.80. A unit with no dialysis facility passes the station-completeness gate (`coalesce(stations_known_share >= 0.8, true)`) |

### 2.1 Bed occupancy (roll-up)

```
bor_weighted_pct (group) = sum(bor_i × beds_i) ÷ sum(beds_i)       over eligible records (BOR ≤ 150)
rolling up groups      = sum(bor_weighted_pct × bor_weighted_beds_sum) ÷ sum(bor_weighted_beds_sum)
```

- Never take a simple average of rates: a 10-bed and a 500-bed hospital would count the same.
- Gold suppresses groups built from fewer than **3** records (`value_status = 'suppressed'`, measures null).
- Label "eligible records".
- Gold excludes records above 150% as likely data errors. So the rate understates load where many records drop out, mostly in government hospitals.
- HFSRB has not confirmed the bed basis and period (`baseline_validated = false`, O-12).

## 3. Workforce

| Metric | Formula | Unit | Mart |
|---|---|---|---|
| `doctors_per_10k`, `nurses_per_10k`, `midwives_per_10k` | headcount × 10,000 ÷ unit census population | per 10,000 | 16, 21 |
| `bhw_per_10k` | BHW total × 10,000 ÷ census population | per 10,000 | 16, 21 (null for 2025) |
| `bhw_lgu_hired_per_10k` | LGU-hired BHW × 10,000 ÷ census population | per 10,000 | 21 |
| `doh_deployed_share` | DOH-hired core headcount ÷ core headcount | 0–1 | 16 |

Headcounts come from `source_role = 'preferred'` and `analysis_eligible` rows only. `workforce_year` is the latest year in which doctors, nurses and midwives are all usable. Counts are public sector only.

## 4. Burden

| Metric | Formula | Unit | Mart | Notes |
|---|---|---|---|---|
| `rate_per_100k` | value × 100,000 ÷ unit census population | per 100,000 | 17 | Latest year of the source; window rule |
| `tb_notifications_per_100k_2024`, `_2025` | notifications × 100,000 ÷ 2024 census population | per 100,000 | 21 | Both years on the 2024 census |
| `tb_change` | notifications 2025 − notifications 2024 | cases | 21 | |
| `ckd_deaths_per_100k` | IHME CKD deaths × 100,000 ÷ unit census population | per 100,000 | 22 | Bounds shown separately, not rated |
| `annual_cases_per_100k` | annual dengue cases × 100,000 ÷ **latest** census population of the area | per 100,000 | 23 | No window: used only to rank within one year |

## 5. TB programme (T2)

| Metric | Formula | Unit |
|---|---|---|
| `tpt_coverage_pct` | `tpt_given` ÷ `tpt_eligible_contacts` × 100 (TB all forms) | % |
| `ds_treatment_success_rate_pct` | `treatment_success` ÷ `treatment_cohort` × 100, `tb_all_forms` (drug-susceptible) | % |
| `mdr_treatment_success_rate_pct` | Same, `tb_drug_resistant` | % |
| `ds_small_cohort`, `mdr_small_cohort` | cohort < 10 | flag |
| `programme_small_cohort` | both cohorts < 10 (missing counts as 0) | flag (older) |

- All ages, both sexes, FHSIS 2025.
- A rate is null when its denominator is null or 0.
- `tpt_eligible_contacts` is an FHSIS **estimate**: notified cases × 4 × 70%.
- The treatment cohort is the cases with an outcome reported in 2025, not the 2025 notifications.

## 6. Dengue peaks (mart 23)

| Metric | Formula |
|---|---|
| `peak_cases` | Maximum cases over the periods of the year |
| `peak_period_share_pct` | peak ÷ annual cases × 100 |
| `top4_periods_share_pct` | four highest weeks ÷ annual cases × 100 (weekly sources only) |
| `is_complete_year` | Every row of the year is complete (from the fact) |
| `is_near_complete` | Complete, or at least 50 weeks / 12 months reported |
| `is_high_burden_year` | `annual_cases_per_100k` in the top fifth of that source and year, near-complete years only |
| `high_burden_years` | Count of high years for the area and source |
| `repeat_high_burden` | `high_burden_years` ≥ 2 |
| `hospital_beds_recorded` | Registry analysis beds with the same coverage as the published row. The coverage is the region, the city itself, the planning unit, or the planning unit minus the cities listed apart |
| `peak_cases_per_100_beds` | peak cases ÷ beds recorded × 100. Null when beds = 0 or not comparison eligible |

## 7. Quintiles and fifths

**Quintile** (marts 16, 17):

```
quintile = least(5, floor(percent_rank() × 5) + 1)
           over the units that have a value, ordered ascending
```

- 1 = lowest, 5 = highest. Units with equal values share one quintile (`percent_rank` gives ties the same rank).
- A unit without a value has no quintile.

**Highest fifth** (mart 19, `is_high_burden`, the socioeconomic flag): the top 20% counted from the top. It can differ from `quintile = 5` at the boundary and with ties. Tied units get the same treatment, so a fifth can hold more than 20% of the units.

**Why fifths.** BQ1 asks where gaps are *largest*, a relative question. Quintiles are the usual grouping in equity analysis. There is no national planning norm in the data to set an absolute line (D-56).

## 8. Priority (mart 19)

| Metric | Formula |
|---|---|
| `has_hospital_gap` | `beds_per_10k_quintile` = 1 |
| `has_primary_care_gap` | `reported_health_centers_per_10k_quintile` = 1, **or** share of the unit's population without licensed primary care recorded in the highest fifth and > 0. Null only when both inputs are missing |
| `has_workforce_gap` | At least 2 of `doctors_per_10k_quintile`, `nurses_per_10k_quintile`, `midwives_per_10k_quintile` = 1. Null unless all three are known |
| `has_socioeconomic_flag` | `poverty_incidence_pct` in the highest fifth |
| `flags_count` | Number of flags that are true (null counts as not raised) |
| `score` | Σ(weight × flag) ÷ Σ(weight of the known flags). Range 0–1 |
| `rank` | Rank of `score`, highest first; ties broken by burden rate, highest first |
| `ranking_population` | Units ranked for that indicator, weight set and rule |

| `eligibility_config` | A unit gets a rank when |
|---|---|
| `complete_only` (default) | All four flags known and a burden rate |
| `rescale_missing` | At least two flags known and a burden rate |

Under `complete_only` the known weight is 1, so with equal weights `score = flags_count ÷ 4`.

## 9. Distance (mart 20)

```
d = 2 × 6371 × asin( sqrt( sin²(Δlat/2) + cos(lat1) × cos(lat2) × sin²(Δlon/2) ) )      km
```

- Great-circle (haversine), Earth radius 6,371 km, between boundary centroids (`center_lat`, `center_lon`).
- 0 when the locality itself has the facility.
- Null when the locality has no boundary centre and no facility of its own.

## 10. Control figures (not shown, used by checks)

| Figure | Where | Used by |
|---|---|---|
| Listed registry facilities and beds | Silver registry | Gate in gold 06, G07 |
| Published hospitals and authorized beds | Silver facilities metric | Gate in gold 06, G07 |
| Silver ok value total (metric + deaths by age + TB programme) | Silver diseases | Gate in gold 07, G07 |
| Claims filed | Silver claims | Gate in gold 07, G07 (WARN when lower: suppressed region cells) |
| Eligible headcount | Silver workforce | Gate in gold 08, G07 |
| Census population of areas in `dim_geography` | Silver population | Gate in gold 09, G07 |

## 11. History of updates

| Date | Change |
|---|---|
| 2026-10-14 | Formulas written in the mart files |
| 2026-10-19 | `ds_small_cohort`, `mdr_small_cohort` added; values agreed (D-56) |
| 2026-10-20 | Page written from the SQL |
| 2026-10-20 | Rewritten in short, active sentences |
