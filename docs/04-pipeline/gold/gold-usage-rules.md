# Gold — usage rules

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Every query, chart and export must follow these rules. The facts hold overlapping rows on purpose. So a plain `SUM` over a fact is almost always wrong. Read this page before you add up anything.

Status date: 2026-10-20. Back to the [gold overview](README.md).

---

## 1. Start from the right object

| You want | Use | Not |
|---|---|---|
| A dashboard figure for a business question | The mart for that question ([data marts](data-marts.md)) | The facts |
| An ad hoc total | A default view (`v_*`) | The raw fact |
| A list of facilities | `dim_facility` joined to `dim_geography` | `fact_facility_capacity` |
| Latest population, poverty, spending | `v_area_indicator_latest` | `fact_area_indicator` without a period filter |
| A map of health facility points | `ref_osm_healthsite_point` | — never as a count |

## 2. Selection contract per fact

A total is valid only when the query filters **every** column in the second column. The default view applies the filters for you.

| Fact | A total is valid only with | Default view |
|---|---|---|
| `fact_facility_capacity` | `capacity_basis` **and** `coverage_basis` **and** `ownership` **and** `hospital_level` **and** `value_status = 'ok'`. Registry rows: sum over ownership and level. Published rows: `ownership = 'total'`. Occupancy rows: `ownership = 'total' AND hospital_level = 'all'` | `v_facility_capacity_totals` |
| `fact_disease_metric` | **one** source (preferred in `source_priority`) **and** `metric_name` **and** `age_group = 'all_ages'` **and** `sex = 'both_sexes'` **and** one `coverage_basis` (claims: one `facility_location*` level) | `v_disease_metric_totals` (`is_preferred_source`) |
| `fact_workforce_capacity` | `source_role = 'preferred'` **and** `profession_code` **and** `analysis_eligible` | `v_workforce_preferred` |
| `fact_area_indicator` | `indicator_name` **and** `indicator_category` **and** `value_status = 'ok'` **and** one period | `v_area_indicator_latest` (`is_latest_period`) |

**Why each filter matters:**

| Fact | Overlap the filter removes |
|---|---|
| Facility capacity | Three bases count the same hospitals: registry today, PSA yearly, occupancy. Occupancy comes at three geographic levels and three breakdowns. Published rows have `total` beside government and private |
| Disease metric | Several sources per disease. 20 age bands beside the all-ages row. Male and female beside both sexes. Claims at three levels |
| Workforce | PSA beside FHSIS for 2018–2023; country, region, province and locality rows together |
| Area indicator | Several years. Census and FHSIS population. A financing agent beside its parent |

## 3. Never add these together

| Never add | Because |
|---|---|
| Rows of different `capacity_basis` | They count the same facilities in different ways |
| Rows of different `data_source_key` | Sources overlap; pick one through `source_priority` |
| Country, region, province and locality rows | A region already contains its provinces |
| A province and the cities its source lists apart | Check `area_coverage_map` first |
| Occupancy or claims rows of different `coverage_basis` | Each level is a full pass over the same records |
| An age band to the all-ages row, a sex to both sexes | The bands already add up to the total |
| A cause with its children (`parent_disease_key`) | The parent already contains them |
| Different `classification` lists | PSA, IHME, TB programme and PhilHealth packages describe different things |
| Modelled (IHME) with registered or reported values | Different kinds of figure |
| Census and FHSIS population | Two sources of the same quantity |
| Percentages (poverty incidence, shares, occupancy) | A share of a share is not a share; occupancy rolls up bed-weighted only ([metric definitions](metric-definitions.md)) |
| A financing agent with its parent | Only level-1 shares add up to 100 |

## 4. Denominators

| Rate | Denominator | Label |
|---|---|---|
| Beds, workforce, poverty and burden comparisons | Census population of the planning unit | "per 10,000 population (census <year>)" |
| FHSIS BHS and health centres per 10,000 | Population printed in the same FHSIS workbook | "per 10,000 FHSIS-reported population (<year>)" |

Never compare an FHSIS-population rate with a census-population rate. Never interpolate between census years. Leave a rate null when the count and population years are more than 2 years apart.

## 5. Wording rules

| Say | Not | Why |
|---|---|---|
| "No hospital recorded as of <date>" | "No hospital" | The registry may miss facilities (O-02) |
| "Lowest 20% of planning units" | "Inadequate", "underserved" | No national norm in the data (D-56) |
| "Authorized beds" | "Available beds", "staffed beds" | Licensed capacity only |
| "Straight-line distance" | "Travel distance", "travel time" | No road network |
| "Notified TB cases" | "TB cases" | Notifications reflect detection and reporting |
| "Claims at hospitals in <area>" | "Claims of residents of <area>" | The area is where the hospital delivered care |
| "Amount claimed" | "Amount paid" | The release gives the amount claimed |
| "Peak cases per 100 beds (relative)" | "Beds needed", "would exceed capacity" | No admission or length-of-stay assumption (BQ2 is stretch 2) |
| "Health workers (public sector)" | "Health workers" | Private practitioners are not counted |
| "Modelled estimate (IHME)" | A plain number | Modelled values carry uncertainty |
| "Highest observed week" for an incomplete year | "Peak" | A missing week could hold the peak |

## 6. Restricted data and attribution

| Data | Rule |
|---|---|
| FOI releases: DOH dengue (`doh_foi_dengue`), hospital beds and occupancy (`doh_foi_hospital_beds`), PhilHealth claims | **Aggregates only.** Gold suppresses cells built from fewer than 3 records or hospitals. The dashboard shows them blank with the reason. No row-level export. Nobody redistributes the raw files (D-47) |
| IHME GBD | No row-level export (non-commercial user agreement). Show the IHME attribution line on every chart |
| OpenStreetMap points | Show "© OpenStreetMap contributors" (ODbL 1.0). Never a facility count |
| Open PSA and DOH sources | Show the source name and as-of date |

`dim_data_source.sharing` and `license` say which rule applies to each source. The full policy (who may see what, suppression, attribution) is in [data governance](../../08-governance/data-governance.md).

## 7. Nulls

- Null means "not available". It is **never zero**.
- Every null in a mart has a reason in `exclusion_reason`, `mapping_outcome`, `value_status` or a `*_exclusion_reason` column. Show it.
- Do not use `coalesce(x, 0)` on a measure. If a chart needs a number, leave the cell blank and add the reason to the tooltip.

## 8. Joining

| Join | Rule |
|---|---|
| Fact → dimension | On the key (`area_key`, `date_key`, `data_source_key`, `disease_key`). Every key resolves (gold QC G04) |
| `dim_facility` → `dim_geography` | On `area_key`. **Never** join `dim_facility` to `fact_facility_capacity` |
| A HUC → its province | `huc_province_crosswalk` |
| A published row → its planning unit | `area_coverage_map` (`mapping_outcome IN ('direct', 'aggregate')`) |
| Null-safe comparisons | Use `<=>` on nullable grain columns (`hospital_level`, `coverage_basis`) |

## 9. Time

- Show the year of every indicator; sources differ.
- Weekly HDX periods are "week ending <date>"; UP NOAH weeks are ISO weeks. Year is the ISO year, so the first days of January can belong to the year before.
- Mark 2020–2022 as the pandemic period (`is_pandemic_period`) on trend charts.
- The registry is a 2026 snapshot; say so next to any 2024–2025 comparison.

## 10. History of updates

| Date | Change |
|---|---|
| 2026-10-14 | Selection contract per fact and the default views (review point 2); two denominators (review point 3) |
| 2026-10-18 | D-47 restricted rule |
| 2026-10-20 | Page written. The restricted-data section links to the data governance page |
| 2026-10-20 | Rewritten in short, active sentences |
