# Known issues and backlog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

## Known issues

| ID | Issue | Impact | Status | Evidence |
|---|---|---|---|---|
| KI1 | `facilities_osm_point_silver` -- resolved | OSM point analysis now available | **Resolved** | Built successfully on 2026-10-15 with 16,030 rows. Confirmed via COUNT(*) query 2026-10-18. See [data gaps](../02-data/data-gaps.md) G10 (resolved). |
| KI2 | 71 NHFR-only and 48 HFSRB-only facilities unmatched | Registry has unmatched facilities from both sources | Known | Registry build 2026-10-10: hospitals 1,407 = 1,092 code + 196 name + 71 NHFR-only + 48 HFSRB-only. |
| KI3 | `row_disposition` contains legacy v1.2 rows | Reconciliation may show mixed versions | Open | Old notebook rows mixed with v1.3 SQL rows. The 2026-10-15 full pipeline run replaced silver tables but row_disposition is append-only. |
| KI4 | `facilities_registry_silver__moved` and `__classified` staging tables not cleaned up | Minor clutter in silver schema | Open | Not in Jemma's drop list. Kept after run for review. |
| KI5 | Admin boundaries require manual `admin_boundaries_run_dir` parameter | Every run must set this parameter | Operational gap | Blank parameter fails fast. Until loader treats blank as "skip", this is manual. |
| KI6 | BOR column name inconsistency | Dashboard queries may use `year` or `reporting_year` | Known | Table schema has `year` (int). Some documentation references `reporting_year`. The actual column is `year`. |
| KI7 | FHSIS area name matching | Some area names do not match PSGC | Partially resolved | v1.7 SQL reduces unmatched; earlier notebook builds filtered 3,976 rows. |
| KI8 | Smoke test is a placeholder | No real unit tests | Known | `tests/test_smoke.py` only checks folder existence. |
| KI9 | `quality_setup.sql` section 9 was reverted once | Quality table DDL may not persist | Verified fixed | Re-applied; verify before relying. |
| KI10 | FOI ticket numbers unconfirmed | FOI provenance incomplete | Open | Ticket numbers marked CONFIRM in YAML. Confirm before publishing. |

## Backlog (planned)

| Priority | Item | Description |
|---|---|---|
| High | Fix admin boundaries blank parameter | Make loader treat blank `admin_boundaries_run_dir` as "skip" (exit 0) |
| Done | Build `facilities_osm_point_silver` | Built 2026-10-15, 16,030 rows. Resolved. |
| Medium | Clean up `row_disposition` | Remove legacy v1.2 rows; keep only v1.3 dispositions |
| Medium | Drop staging tables | Remove `__moved`, `__classified`, `__records` staging tables |
| Medium | Add real unit tests | Replace smoke test with tests that validate SQL logic and data quality rules |
| Medium | Improve FHSIS area matching | Resolve remaining unmatched area names in facilities metric silver |
| Low | Confirm FOI ticket numbers | Verify and record actual FOI request ticket numbers |
| Low | Schedule the pipeline job | Auto-paused in dev; set cron schedule when moving to prod |
| Low | FHSIS primary-care counts on the dashboard (S3) | The dashboard's Access page shows registry-based presence only. FHSIS BHS/RHU/health-centre counts (S3) exist in `facilities_metric_silver` and v2 gold but have no dashboard widgets; they are query-only. Adding visuals is a backlog item, not a defect. A complete dashboard does not require a page for every supporting question. |
| Partial | Build `mart_capacity_gap` (BQ1) | `test_gold2.mart_area_service_profile` (109 rows, 62 columns) covers supply, primary care, workforce, and poverty per planning unit. Full BQ1 with disease burden still needs integration with `mart_area_burden_indicator`. |
| Done | Materialise gold fact tables | Built 2026-10-15 in `test_gold2`: `fact_disease_metric` (593,171), `fact_facility_capacity` (30,365), `fact_workforce_capacity` (28,071), `fact_area_indicator` (8,928), `fact_area_access` (1,642). |
| Medium | Build `mart_surge_stress_test` (BQ2) | Previous scope. Build only if re-scoped; blocked on admission share and LOS parameters. |
| Medium | Build priority scoring (P1-P2) | Gated until N, S, A, W, E validated on the same analysis unit. |
| Medium | Add `age_group` dimension to gold | SUP1 needs an age dimension; gold model has none yet. |
| Low | Clean income class values | E2 needs cleaned income class values (4th*, 1st (as Mun), Special, -). |
