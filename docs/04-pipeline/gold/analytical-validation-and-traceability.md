# Analytical validation and traceability

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Each business question traces from the dashboard query back through gold marts, silver tables, bronze tables, and source files. This page documents the full chain.

## Traceability chain

```
Dashboard query
  -> Gold mart (public_health.test_gold2.*)
    -> Silver table (public_health.silver.*)
      -> Bronze table (public_health.bronze.*)
        -> Landing file (/Volumes/.../g5_landing/...)
          -> Source provider (DOH, PSA, HDX, etc.)
```

Each step is recorded:
* Gold -> Silver: `build_log` and `build_inputs` in the quality schema.
* Silver -> Bronze: `_silver_build_id` on each silver row links to `build_log`.
* Bronze -> Landing: `ingestion_metadata` records the load batch ID and content checksum.
* Each silver row carries `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`.

## Per-question traceability

### Built and verified

| Question | Gold table | Silver sources | Bronze sources | Source files |
|---|---|---|---|---|
| S1 | `mart_area_service_profile` (S1_hospital_supply) | `facilities_registry_silver`, `population_silver` | `facilities_doh_nhfr_hospitals_bronze`, `facilities_doh_hfsrb_hospitals_bronze`, `geography_bronze` | NHFR CSV, HFSRB XLSX, PSGC API |
| S2 | `mart_area_service_profile` (S2_hospital_occupancy) | `facilities_bed_occupancy_silver` | `facilities_doh_foi_bed_occupancy_bronze` | FOI bed occupancy XLSX |
| S3 | `mart_area_service_profile` (S3_primary_care_supply) | `facilities_metric_silver` | `facilities_doh_fhsis_demographic_bronze` | FHSIS XLSX |

### Silver exists, gold designed

| Question | Gold table (designed) | Silver sources | Bronze sources | Source files |
|---|---|---|---|---|
| N1-N4 | `fact_disease_metric`, `mart_area_burden_indicator` | `diseases_metric_silver`, `diseases_directory_silver` | `diseases_doh_foi_dengue_bronze`, `diseases_upnoah_dengue_*_bronze`, `diseases_hdx_dengue_*_bronze`, `diseases_ihme_*_bronze` | FOI dengue CSV, UP NOAH XLSX, HDX CSV, IHME CSV |
| W1-W2 | `fact_workforce_capacity` | `workforce_headcounts_silver`, `workforce_denominator_silver` | `workforce_doh_fhsis_demographic_bronze`, `workforce_psa_gov_practitioners_bronze` | FHSIS XLSX, PSA CSV |
| E1-E2 | `fact_area_indicator` | `socioeconomic_poverty_silver` | `socioeconomic_psa_poverty_bronze` | PSA poverty XLSX |
| A1-A2 | `mart_locality_service_presence`, `fact_area_access` | `facilities_registry_silver`, `geography_silver` | `facilities_doh_nhfr_hospitals_bronze` | NHFR CSV, PSGC API |
| SUP6 | `mart_evidence_readiness`, `mart_area_evidence` | Quality schema tables | Quality schema | N/A (internal) |

### Needs input or gated

| Question | Blocker |
|---|---|
| D1-D5 | Previous scope. If re-scoped, needs dengue admission share and length-of-stay parameters from clinical literature or DOH. |
| P1-P2 | Gated: needs N, S, A, W, E validated on the same analysis unit (province + HUC + NCR) first. |
| BQ1 (mart_capacity_gap) | Needs the province/HUC/NCR analysis unit rule implemented in `mart_base_planning_unit`. |
| BQ2 (mart_surge_stress_test) | Previous scope. If re-scoped, needs D2 parameters (admission share, LOS). |

## How to trace a row

To trace a `mart_area_service_profile` row back to its source file:

```sql
-- 1. Find the build ID for the mart row
SELECT _silver_build_id, _source_key, _source_file
FROM public_health.test_gold2.mart_area_service_profile
WHERE supply_section = 'S1_hospital_supply'
  AND area_name = 'Ilocos Norte'
  AND ownership = 'Government'
LIMIT 5;

-- 2. Look up the build inputs
SELECT * FROM public_health.quality.build_inputs
WHERE build_id = '<build_id>'
ORDER BY source_key;

-- 3. Find the bronze load batch
SELECT * FROM public_health.bronze.ingestion_metadata
WHERE source_name = '<source_key>'
  AND status = 'processed'
ORDER BY ingested_at DESC LIMIT 5;

-- 4. Read the bronze table at that version
SELECT * FROM public_health.bronze.facilities_doh_nhfr_hospitals_bronze
VERSION AS OF TIMESTAMP '<ingested_at>'
WHERE _source_key = '<source_key>'
LIMIT 10;
```

## Validation status

| Layer | What is validated | How | Status |
|---|---|---|---|
| Bronze | Row count, null keys, header check, numeric columns, control totals | `src/05_quality/bronze/*` scripts, `dq_utils.DQRun` | Verified on Databricks runs (2026-10-09 to 2026-10-13) |
| Silver | Null keys, duplicate keys, lineage completeness, row count reconciliation, geographic match | `src/05_quality/silver/*` scripts | Verified for facilities and geography domains. Other domains: silver builds run, QC scripts exist. |
| Cross-domain | Geography joins across domains, source coverage | `src/05_quality/silver/silver_cross_domain_qc.py` | Script exists, runs as last silver task before gold. |
| Gold | Mart row counts, key columns, metric ranges | `src/05_quality/gold/gold_qc.py` | Placeholder script: no checks implemented, nothing logged (KI11). Gold objects' row counts verified by COUNT(*) in the [2026-10-18 run record](../../06-evidence/2026-10-18-new-workspace-run.md). |

## Unverified claims

The following are documented but not independently verified:
* Dashboard -- all eight pages (v2 model) are populated with widgets; datasets query `test_gold2` views (verified 2026-10-18). Widget-level values have not been independently spot-checked.
* `facilities_osm_point_silver` -- resolved: built 2026-10-18, 16,030 rows (bundle-job run; verified via table Delta history). See [known issues](../../08-governance/known-issues-and-backlog.md).
* Gold v2 fact tables (`fact_disease_metric`, `fact_workforce_capacity`, `fact_area_indicator`) -- row counts verified 2026-10-18 (see [findings report](findings-report.md)); content verification is pending.
* Silver QC for diseases, workforce, and socioeconomic domains -- scripts exist and run; socioeconomic results verified in `quality.qc_results` (all four tables PASS; poverty 6 WARN, child mortality 3 WARN). Diseases and workforce results have not been reviewed in detail.
* Handover -- a formal handover walkthrough has not been conducted (see [team and timeline](../../08-governance/team-and-timeline.md#handover-readiness)).
