# Data marts

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Gold marts built from silver tables for dashboard consumption and analysis. Each mart answers specific business questions from the BQ1 framework (BQ2 is previous scope). See [business context](../../01-context/problem-and-business-context.md) for the full question framework and traceability table.

## Built marts

### `mart_area_service_profile` (v1; superseded as dashboard source by v2)

* **Purpose**: Answers supply-side questions S1 (hospital availability), S2 (bed occupancy), S3 (primary care availability).
* **Grain**: `supply_section x area_level x area_key x year x ownership x facility_level`.
* **Rows**: 2,701 (built 2026-10-13).
* **Script**: `gold_53_mart_area_service_profile.sql`.
* **Schema**: `public_health.gold`.
* **Questions**: S1, S2, S3.
* **Caveats**: See [metric definitions](metric-definitions.md) for formulas and [gold usage rules](gold-usage-rules.md) for interpretation.

### `mart_area_service_profile` (v2, active model)

* **Purpose**: Wide planning-unit mart covering supply, workforce, poverty, and access per province/HUC/NCR.
* **Grain**: One row per planning unit.
* **Rows**: 109 (built 2026-10-15).
* **Columns**: 62.
* **Script**: `gold_v2_53_mart_area_service_profile.sql`.
* **Schema**: `public_health.test_gold2`.
* **Questions**: S1, S2, S3, W1, E1, A1-A2 (partial BQ1).
* **See [data dictionary](data-dictionary.md) for column definitions.

### `mart_area_evidence`

* **Purpose**: Evidence readiness per area (how many sources cover this area).
* **Script**: `gold_55_mart_area_evidence.sql`.
* **Questions**: SUP6 (partial).

### `mart_area_priority`

* **Purpose**: Area priority ranking based on supply indicators.
* **Script**: `gold_56_mart_area_priority.sql`.
* **Questions**: P1 (partial -- supply only; full P1 needs N, A, W, E).

### `mart_area_burden_indicator`

* **Purpose**: Disease burden per area.
* **Script**: `gold_54_mart_area_burden_indicator.sql`.
* **Questions**: N1-N4 (partial).

### `mart_locality_service_presence`

* **Purpose**: Service presence per locality (which services are available where).
* **Script**: `gold_51_mart_locality_service_presence.sql`.
* **Questions**: A1, A2 (partial).

### `mart_base_planning_unit`

* **Purpose**: Base planning unit reference for area-level analysis (province + HUC + NCR rule).
* **Script**: `gold_52_mart_base_planning_unit.sql`.
* **Questions**: BQ1 (analysis unit definition).

### Case study marts

* `mart_tb_case_study` (`gold_61_mart_tb_case_study.sql`) -- TB-specific analysis. Questions: CASE, N4.
* `mart_kidney_case_study` (`gold_62_mart_kidney_case_study.sql`) -- Kidney disease analysis.
* `mart_evidence_readiness` (`gold_71_mart_evidence_readiness.sql`) -- Evidence readiness summary. Questions: SUP6.

## Designed but not built

### `mart_capacity_gap` (BQ1 main mart)

* **Purpose**: One row per analysis area with need, supply, access, workforce and equity indicators side by side.
* **Questions**: BQ1, A1, A2, E1, E2, P1, P2.
* **Inputs**: All domain silver tables.
* **Status**: Not built (verified absent from `test_gold2` on 2026-10-18). The v2 `mart_area_service_profile` (109 rows, 62 columns) partially covers BQ1: supply, primary care, workforce, and poverty per planning unit. Full integration with disease burden (`mart_area_burden_indicator`) is the remaining gap.
* **Build order**: After `mart_base_planning_unit` and all domain fact tables are materialised (done).

### `mart_surge_stress_test` (BQ2 main mart, previous scope)

* **Purpose**: One row per area and scenario: replayed cases, added bed demand, spare beds, shortfall, exceed flag.
* **Questions**: BQ2, D1-D5 (previous scope).
* **Inputs**: `diseases_metric_silver`, `facilities_metric_silver`, `facilities_bed_occupancy_silver`, `scenario_params`.
* **Status**: Needs input. Blocked until admission share and length-of-stay parameters are sourced.

## Built in v2 (test_gold2)

### Fact tables (built 2026-10-15)

| Fact table | Rows | Questions | Silver source |
|---|---|---|---|
| `fact_disease_metric` | 593,171 | N1, N2, N3, N4, SUP1, SUP2, CASE | `diseases_metric_silver`, `diseases_directory_silver` |
| `fact_facility_capacity` | 30,365 | S1, A1, A2, D3, SUP3 | `facilities_registry_silver`, `facilities_metric_silver` |
| `fact_workforce_capacity` | 28,071 | W1, W2, CASE, SUP4 | `workforce_headcount_silver` |
| `fact_area_indicator` | 8,928 | E1, E2, SUP5 | `socioeconomic_poverty_silver`, `facilities_metric_silver` |
| `fact_area_access` | 1,642 | A1, A2, CON1 | `facilities_registry_silver`, `geography_silver` |

### Dimensions

| Dimension | Key columns |
|---|---|
| `dim_geography` | `area_key`, `area_code`, `area_name`, `geographic_level` |
| `dim_facility` | `facility_key`, `facility_level`, `ownership` |
| `dim_disease` | `disease_key`, `disease`, `cause` |
| `dim_date` | `date_key`, `date` |
| `dim_data_source` | `source_key` |
