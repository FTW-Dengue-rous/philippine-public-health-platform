# Known issues and backlog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

## Known issues

| ID | Issue | Impact | Status | Evidence |
|---|---|---|---|---|
| KI1 | `facilities_osm_point_silver` not verified to exist | OSM point analysis unavailable | Unverified | Table not found on Databricks (2026-10-14). Documented per user instruction. See [data gaps](../02-data/data-gaps.md) G10. |
| KI2 | 71 NHFR-only and 48 HFSRB-only facilities unmatched | Registry has unmatched facilities from both sources | Known | Registry build 2026-10-10: hospitals 1,407 = 1,092 code + 196 name + 71 NHFR-only + 48 HFSRB-only. |
| KI3 | `row_disposition` contains legacy v1.2 rows | Reconciliation may show mixed versions | Open | Old notebook rows (2,695 id_map + 2×1,977 BOR) mixed with v1.3 SQL rows. Team should decide cleanup. |
| KI4 | `facilities_registry_silver__moved` and `__classified` staging tables not cleaned up | Minor clutter in silver schema | Open | Not in Jemma's drop list. Kept after run for review. |
| KI5 | Admin boundaries require manual `admin_boundaries_run_dir` parameter | Every run must set this parameter | Operational gap | Blank parameter fails fast. Until loader treats blank as "skip", this is manual. |
| KI6 | BOR column name inconsistency | Dashboard queries may use `year` or `reporting_year` | Known | Table schema has `year`; some queries use `reporting_year`. Verify before relying. |
| KI7 | FHSIS area name matching | Some area names do not match PSGC | Partially resolved | v1.7 SQL reduces unmatched; earlier notebook builds filtered 3,976 rows. |
| KI8 | Smoke test is a placeholder | No real unit tests | Known | `tests/test_smoke.py` only checks folder existence. |
| KI9 | `quality_setup.sql` section 9 was reverted once | Quality table DDL may not persist | Verified fixed | Re-applied; verify before relying. |
| KI10 | FOI ticket numbers unconfirmed | FOI provenance incomplete | Open | Ticket numbers marked CONFIRM in YAML. Confirm before publishing. |

## Backlog (planned)

| Priority | Item | Description |
|---|---|---|
| High | Fix admin boundaries blank parameter | Make loader treat blank `admin_boundaries_run_dir` as "skip" (exit 0) |
| High | Build `facilities_osm_point_silver` | Run the OSM point-in-polygon build or remove the unverified doc entry |
| Medium | Clean up `row_disposition` | Remove legacy v1.2 rows; keep only v1.3 dispositions |
| Medium | Drop staging tables | Remove `__moved`, `__classified`, `__records` staging tables |
| Medium | Add real unit tests | Replace smoke test with tests that validate SQL logic and data quality rules |
| Medium | Improve FHSIS area matching | Resolve remaining unmatched area names in facilities metric silver |
| Low | Confirm FOI ticket numbers | Verify and record actual FOI request ticket numbers |
| Low | Schedule the pipeline job | Auto-paused in dev; set cron schedule when moving to prod |
| Low | Dashboard S3 page | S3 page has no widgets yet; only S1 and S2 are populated |
| High | Build `mart_capacity_gap` (BQ1) | Materialise the main capacity-gap mart joining need, supply, access, workforce, equity per area. Needs analysis unit (province + HUC + NCR rule) first. |
| High | Materialise gold fact tables | Build `fact_disease_metric`, `fact_facility_capacity`, `fact_bed_occupancy`, `fact_workforce`, `fact_population`, `fact_socioeconomic` from silver. |
| Medium | Build `mart_surge_stress_test` (BQ2) | Blocked on admission share and LOS parameters. Build once parameters are sourced. |
| Medium | Build priority scoring (P1-P2) | Gated until N, S, A, W, E validated on the same analysis unit. |
| Medium | Add `age_group` dimension to gold | SUP1 needs an age dimension; gold model has none yet. |
| Low | Clean income class values | E2 needs cleaned income class values (4th*, 1st (as Mun), Special, -). |
