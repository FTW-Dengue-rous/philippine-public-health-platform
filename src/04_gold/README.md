# Gold data model v2 (combined) — SQL

5 dimensions, 4 facts. Built from data model v1 (`public_health.test_gold`) and the mentor's conceptual model. Target schema: `public_health.test_gold2` (beside v1 in `test_gold`, for comparison).

Naming (decided 2026-10-14 evening): this is **data model v2**. v1 is the as-built model in `test_gold`; v2 is the combined model in `test_gold2`. The files and `build_log` rows were labelled "v4" until this evening (and the mentor proposal called the same model "v3"); those labels are retired. The "v2 / v3 options" in `gold-model-v2-v3-handoff.md` were proposal-stage alternatives, not this model.

## Run order

v2 is self-contained (decided 2026-10-14 evening: the team runs v2 only; nothing reads `test_gold`).

| # | File | Builds | Same as (v1) |
|---|---|---|---|
| 1 | `gold_v2_00_setup.sql` | schema only | — |
| 2 | `gold_v2_11_dim_geography.sql` | `dim_geography` | gold_11 (schema + label only) |
| 3 | `gold_v2_21_dim_facility.sql` | `dim_facility` | gold_21 (schema + label only) |
| 4 | `gold_v2_31_dim_disease.sql` | `dim_disease` | gold_31 (schema + label only) |
| 5 | `gold_v2_12_dim_date.sql` | `dim_date` | replaces gold_12 `dim_period` |
| 6 | `gold_v2_13_dim_data_source.sql` | `dim_data_source` | replaces gold_13 `dim_source` |
| 7 | `gold_v2_20_fact_facility_capacity.sql` | `fact_facility_capacity` | replaces gold_22, gold_23, gold_24 |
| 8 | `gold_v2_30_fact_disease_metric.sql` | `fact_disease_metric` | replaces gold_34, gold_35, gold_32 |
| 9 | `gold_v2_35_fact_workforce_capacity.sql` | `fact_workforce_capacity` | replaces gold_36, gold_33 |
| 10 | `gold_v2_40_fact_area_indicator.sql` | `fact_area_indicator` | replaces gold_14, gold_37, gold_90 |

Every file keeps the v1 write-audit-publish pattern: inputs, candidate, gates, stop on a failed gate, publish, `quality.build_log` / `quality.build_inputs` (with `parameters.model = 'v2'`), summary query.

**All 10 files built on Databricks, 2026-10-14 evening, every gate 0.** dim_geography 1,764; dim_facility 3,957; dim_disease 179 (116 PSA, 46 IHME, 3 programme, 14 PhilHealth packages — the `classification` gate accepts `phic_case_rate_package` since this run); dim_date 783; dim_data_source 23; fact_facility_capacity 30,365 (occupancy 20,488 at three geographic levels x three breakdowns; published 7,302; registry 2,575); fact_disease_metric 222,367; fact_workforce_capacity 28,071; fact_area_indicator 8,928. `test_gold2` no longer reads `test_gold`.

## Key rules

- `date_key` and `data_source_key` keep the v1 hash values (`period_key`, `source_key`), so v1 and v2 keys match.
- `fact_facility_capacity`: always filter `capacity_basis` (`registry_snapshot`, `published_statistic`, `occupancy_report`).
- `fact_disease_metric`: totals use `age_group = 'all_ages'`.
- `fact_area_indicator`: always filter `indicator_name` (and `indicator_category` for population).
- `fact_workforce_capacity`: filter `source_role = 'preferred'`.

## Promoting to `public_health.gold`

Change `public_health.test_gold2` to `public_health.gold` in all 10 files and run them in order.

## Test status (2026-10-14)

- All 7 files parse with sqlfluff (databricks dialect).
- All 7 ran end to end on local Spark 4.0.1 with made-up silver, v1 and quality tables. Every gate returned 0.
- Negative test: a registry row outside `dim_geography` stopped `fact_facility_capacity` with `area_key not in dim_geography = 1` and logged a failed build.
- Local limits: no Delta jar offline, so `DESCRIBE HISTORY` (version) and `CREATE OR REPLACE TABLE` were stubbed in the test harness only.
- **Run on Databricks 2026-10-14 (evening): all 7 files published, every gate 0.** Row counts: dim_geography 1,764; dim_facility 3,957; dim_disease 165; dim_date 783; dim_data_source 23; fact_facility_capacity 8,417 (occupancy 6,345 of which 5,661 suppressed; published 7,302; registry 2,575); fact_disease_metric 222,367 (131,887 metric + 90,480 by-age); fact_workforce_capacity 28,071; fact_area_indicator 8,928.
- After the first run (2026-10-14 evening):
  1. Occupancy suppression at city / municipality grain left 89% of groups without a rate. **Fixed in 20 (two reruns, both gates 0):** occupancy is published at three geographic levels (silver level, `province_excl_huc`, `region`) crossed with three breakdowns (ownership x level as reported; ownership with `hospital_level = 'all'`; `ownership = 'total'` with `hospital_level = 'all'`). Each cell is a full pass over the same records and is suppressed on its own; gates check every level and breakdown reconciles to the 9,145 records. Result: province totals 636 rows / 121 suppressed (provinces with < 3 reporting hospitals that year), region totals 144 / 0. For capacity pressure read `coverage_basis = 'province_excl_huc' AND ownership = 'total' AND hospital_level = 'all'`. Occupancy rows: 20,488.
  2. `hdx_dengue` `is_complete_year` was null on all 32,701 rows because silver 04 only set it for `week_number_unconfirmed` sources. **Fixed 2026-10-14 evening (three iterations, final run clean):** for dated weeks silver 04 now tests contiguity ((last − first)/7 + 1 = dates present) and span (first ≤ 7 Jan, last ≥ 25 Dec) — a year holds 52 or 53 of any weekday, so 51 always means a missing week — and adds `areas_complete` (areas holding every period the source holds) / `all_areas_complete`. Gold 30 sets `is_complete_year` per fact row = source complete AND the area holds every source period, with a gate that it is never null on metric rows. Result for HDX provinces: 2018 complete everywhere; 2017 and 2020 complete for the source but 52/81 and 61/81 provinces; 2016 and 2019 short one week at a year edge; 2021 two weeks. Annual HDX marts filter `is_complete_year = true`; peaks and weekly series do not need it. Still open: D4 itself (label peaks by week number, not date, until decided).
  3. 35 was run from the old `gold_v4_35` file — rerun from `gold_v2_35` so `build_log.parameters.model` reads v2 (table content is identical). Not yet rerun.

## Next

1. Marts on v2: the v1 views (`gold_51`–`gold_71`) read `dim_period`, `dim_source`, `dim_profession`, `fact_workforce`, `fact_population`, `fact_poverty`, `fact_bed_occupancy` and need rewriting to `dim_date`, `dim_data_source`, `fact_workforce_capacity`, `fact_area_indicator`, `fact_facility_capacity`. Suggested order: 51 → 52 → 53 (BQ1 spine), 54 → 55 → 56, 61 / 62 case studies, then the dengue peak-vs-capacity view (core) on the province `total` occupancy rows.
2. TB programme into `fact_disease_metric` (T2): UNION `diseases_tb_programme_silver` in with `metric_name = indicator`; decide how sex and drug_resistance enter the grain.
3. PhilHealth claims into gold: aggregate rows (area x year x package x status) — placement decision pending (extra fact vs `fact_disease_metric` rows with `location_basis = facility_location`). `dim_data_source` needs a `philhealth_foi_claims_hospital` row first.
4. D4 (HDX week convention) — until decided, label peaks by week number.

The table, column, mart and question map is in the gold map workbook (`capstone_gold_v4_map.xlsx` at the time of writing; rename to `capstone_gold_v2_map.xlsx` with the model).