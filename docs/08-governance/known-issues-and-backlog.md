# Known issues and backlog

Owner: LUNASaan Documentation Team
Last updated: 2026-10-19

## Known issues

| ID | Issue | Impact | Status | Evidence |
|---|---|---|---|---|
| KI1 | `facilities_osm_point_silver` -- resolved | OSM point analysis now available | **Resolved** | Built 2026-10-18 at 13:16 UTC by the bundle-job run (23167081408523), 16,030 rows; verified via the table's Delta history and `qc_results` rows (13:35-14:07 UTC). See [data gaps](../02-data/data-gaps.md) G10 (resolved). |
| KI2 | 71 NHFR-only and 48 HFSRB-only facilities unmatched | Registry has unmatched facilities from both sources | Known | Registry build 2026-10-10: hospitals 1,407 = 1,092 code + 196 name + 71 NHFR-only + 48 HFSRB-only. |
| KI3 | `row_disposition` contains legacy v1.2 rows | Reconciliation may show mixed versions | Open | Old notebook rows mixed with v1.3 SQL rows. The 2026-10-18 pipeline runs replaced silver tables but row_disposition is append-only. |
| KI4 | `facilities_registry_silver__moved` and `__classified` staging tables not cleaned up | Minor clutter in silver schema | Open | Not in Jemma's drop list. Kept after run for review. |
| KI5 | Admin boundaries require manual `admin_boundaries_run_dir` parameter | Every run must set this parameter | Operational gap | Blank parameter fails fast. Until loader treats blank as "skip", this is manual. |
| KI6 | BOR column name inconsistency | Dashboard queries may use `year` or `reporting_year` | Known | Table schema has `year` (int). Some documentation references `reporting_year`. The actual column is `year`. |
| KI7 | FHSIS area name matching | Some area names do not match PSGC | Partially resolved | v1.7 SQL reduces unmatched; earlier notebook builds filtered 3,976 rows. |
| KI8 | Smoke test is a placeholder | No real unit tests | Known | `tests/test_smoke.py` only checks folder existence. |
| KI9 | `quality_setup.sql` section 9 was reverted once | Quality table DDL may not persist | Verified fixed | Re-applied; verify before relying. |
| KI10 | FOI ticket numbers unconfirmed | FOI provenance incomplete | Open | Ticket numbers marked CONFIRM in YAML. Confirm before publishing. |
| KI11 | `gold_qc` task -- resolved | Gold QC now implemented with 14 checks (G00-G13) writing to `qc_results` | **Resolved** | `src/05_quality/gold/gold_qc.py` implements row-count, key uniqueness, grain, FK, freshness, control-total, value-consistency, default-view, selection-contract, range, idempotency, and census-plausibility checks. Implemented 2026-10-19. |
| KI12 | Concurrent runs of the two pipeline jobs race on `CREATE OR REPLACE TABLE` | Manual job run 513012844601841 failed twice on 2026-10-18 (gold_11, then gold_20) while the bundle job ran the same scripts; recovered by run repair | Mitigated - run one job at a time | [2026-10-18 run record](../06-evidence/2026-10-18-new-workspace-run.md). |
| KI13 | Manually created job lacks the OSM silver build steps | `gold_43_ref_osm_healthsite_point` depends on `facilities_osm_point_silver`, which only the bundle job (or a manual run of the facilities 04 scripts) builds | Open | Manual job task list vs `src/03_silver/facilities/`; OSM table built by the bundle run at 13:16 UTC on 2026-10-18. |
| KI14 | Two pipeline jobs execute the same scripts | Duplicate execution paths: manually created 66-task job (553440510410749) and DABs-deployed 72-task bundle job (835555203376044); concurrent-run and drift risk | Open | Both jobs exist in the workspace; consolidation pending. |

## Backlog (planned)

| Priority | Item | Description |
|---|---|---|
| High | Fix admin boundaries blank parameter | Make loader treat blank `admin_boundaries_run_dir` as "skip" (exit 0) |
| Done | Implement gold QC checks | Replaced the `gold_qc.py` placeholder with real checks (G00-G13: row counts, key uniqueness, grain, FK, freshness, control totals, value consistency, default views, selection contract, metric ranges, idempotency, census plausibility) that log to `qc_results` (KI11 resolved). |
| Done | Build `facilities_osm_point_silver` | Built 2026-10-18 (bundle job), 16,030 rows. Resolved. |
| Medium | Clean up `row_disposition` | Remove legacy v1.2 rows; keep only v1.3 dispositions |
| Medium | Drop staging tables | Remove `__moved`, `__classified`, `__records` staging tables |
| Medium | Add real unit tests | Replace smoke test with tests that validate SQL logic and data quality rules |
| Medium | Improve FHSIS area matching | Resolve remaining unmatched area names in facilities metric silver |
| Low | Confirm FOI ticket numbers | Verify and record actual FOI request ticket numbers |
| Low | Schedule the pipeline job | Auto-paused in dev; set cron schedule when moving to prod |
| Low | FHSIS primary-care counts on the dashboard (S3) | The dashboard's Access page shows registry-based presence only. FHSIS BHS/RHU/health-centre counts (S3) exist in `facilities_metric_silver` and v2 gold but have no dashboard widgets; they are query-only. Adding visuals is a backlog item, not a defect. A complete dashboard does not require a page for every supporting question. |
| Partial | Build `mart_capacity_gap` (BQ1) | `public_health.gold.mart_area_service_profile` (109 rows, 62 columns) covers supply, primary care, workforce, and poverty per planning unit. Full BQ1 with disease burden still needs integration with `mart_area_burden_indicator`. |
| Done | Materialise gold fact tables | Built 2026-10-18 in `public_health.gold`: `fact_disease_metric` (593,171), `fact_facility_capacity` (30,365), `fact_workforce_capacity` (28,071), `fact_area_indicator` (8,928), `fact_area_access` (1,642). |
| Medium | Build `mart_surge_stress_test` (BQ2) | Previous scope. Build only if re-scoped; blocked on admission share and LOS parameters. |
| Medium | Build priority scoring (P1-P2) | Gated until N, S, A, W, E validated on the same analysis unit. |
| Medium | Add `age_group` dimension to gold | SUP1 needs an age dimension; gold model has none yet. |
| Low | Clean income class values | E2 needs cleaned income class values (4th*, 1st (as Mun), Special, -). |
