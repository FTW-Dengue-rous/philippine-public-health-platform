# Change log

Dated runs and revisions of the platform, newest first. Pages carry their own history; this page is the one place to see what changed when, and which run proves it.

Status date: 2026-10-20. Add a row for every full run and every change that alters a published table.

---

## 1. Runs

| Date | Run | Result | Evidence |
|---|---|---|---|
| 2026-10-20 | Evidence runs 1–3: full job on the same inputs | **To record:** gate, silver and gold QC summaries; G12 PASS on runs 2 and 3 | [`06-evidence/idempotency/`](../06-evidence/README.md) |
| 2026-10-20 | Workforce rebuild (`00` → `03`) with the Zamboanga Sibugay override; `workforce_silver_qc.py`; `silver_cross_domain_qc.py` | Headcount 28,080, denominator 3,024; workforce QC 0 FAIL; cross-domain 68 checks, 0 FAIL, 10 WARN (`14f27bc1-8c3f-48dd-aa5c-8a6faddd2ed4`) | [Silver quality checks](../04-pipeline/silver/silver-quality-checks.md), section 14 |
| 2026-10-19 | Silver rebuild with the rule 2a and D-44 revisions, every domain and QC | Cross-domain 68 checks, 0 FAIL, 11 WARN (`e56cdd87-64bd-4686-9f32-74ff95622ed6`); diseases QC 143 checks, 0 FAIL, 7 WARN; population QC 19 checks, 0 FAIL, 5 WARN; `silver_rev_d44_verify.sql` steps 1–4 passed | Silver quality checks, section 14 |
| 2026-10-19 | Bronze from a notebook: baseline QC, gate, `run_bronze.py` over 6 domains (four runs) | Gate: 41 sources, 39 PASS, 2 WARN, 0 blocking. `run_bronze`: 46 sources unchanged, 0 failed, 0 re-queued | [Bronze quality checks](../04-pipeline/bronze/bronze-quality-checks.md), section 11 |
| 2026-10-17 | Full run 2, end to end | Figures presented on 2026-10-17 | Root README, "What the data shows" |
| 2026-10-16 | Full run 1, end to end | — | — |
| 2026-10-14 | Silver QC on Databricks, every domain | Diseases 143 / 0 FAIL / 7 WARN; facilities 136 / 0 / 9; socioeconomic 82 / 0 / 3; cross-domain 68 / 0 / 11 | [Runbook](../07-operations/runbook.md), incidents 2 and 5 |

## 2. Revisions

| Date | Layer | Change | Decision |
|---|---|---|---|
| 2026-10-20 | docs | Documentation set: decision log, quality framework and catalog, lineage contract moved, reference maps, operations and governance pages | — |
| 2026-10-20 | job | Runs stay manual; trigger and skip deferred in a safer form; warehouse auto-stop | D-59 |
| 2026-10-20 | silver | Workforce row override for Zamboanga Sibugay 2025 (`accepted`); review rows deferred | D-58 |
| 2026-10-19 | silver | Rule 2a in every silver build and QC file: settings recorded in `build_log.parameters`, controls from the YAML, new gates for new year columns, GS07 / GS08 / S59 | — |
| 2026-10-19 | silver | Full rebuild kept; incremental and layout tuning moved to recommendations | D-57 |
| 2026-10-19 | gold | Proposal values agreed with a reason per value | D-56 |
| 2026-10-19 | bronze | Bronze closed: QC re-queue, preload gate, geography and population QC in `run_bronze.py`, validated overrides, B13 FAIL when unverifiable, timezone-aware UTC (loaders `2026-10-19.1`) | D-50 to D-55 |
| 2026-10-19 | silver | Week convention applied: HDX week ends on its date, UP NOAH ISO weeks | D-44, D-46 |
| 2026-10-18 | gold | `gold_qc.py` (G01–G13); gold promoted to `public_health.gold`, files `gold_01`–`gold_24` | D-48, D-49 |
| 2026-10-18 | all | Coverage evidence (IHME includes HUCs; HDX excludes listed cities); restricted-data basis | D-42, D-43, D-45, D-47 |
| 2026-10-14 | gold | Data model v2: 5 dimensions, 4 facts | D-36 to D-39 |
| 2026-10-14 | bronze | Incremental file loaders (`2026-10-14.1`) and `run_bronze.py`; Healthsites file with coordinates from GeoJSON | — |
| 2026-10-13 | gold | Data model v1 built for comparison | D-35 |
| 2026-10-12 | silver | Admin boundaries fix: one PSGC code per boundary per level (AB07) | D-34 |
| 2026-10-09 | silver | Lineage contract v1.2 / v1.3; write-audit-publish builds | D-24, D-25 |
| 2026-10-08 | bronze | Bronze tables frozen; lineage ids from `ingestion_metadata` | D-20 |
| 2026-10-07 | quality | Quality schema and `DQRun` | D-14, D-15 |
| 2026-10-06 | bronze | Config-driven loading for all domains | D-12 |
| 2026-10-04 | bronze | First bronze loads (diseases) | D-08, D-09 |

## 3. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Page written; evidence runs 1–3 to be recorded |