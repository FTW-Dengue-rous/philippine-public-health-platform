# Data marts

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Gold marts built from silver tables for dashboard consumption and analysis. See [business questions](../../01-context/problem-and-business-context.md#analytical-questions) for the full question-to-mart mapping.

## Built marts

### `mart_area_service_profile`

* **Purpose**: Answers supply-side questions S1 (hospital availability), S2 (bed occupancy), S3 (primary care availability).
* **Grain**: `supply_section x area_level x area_key x year x ownership x facility_level`.
* **Rows**: ~2,784.
* **Script**: `gold_53_mart_area_service_profile.sql`.
* **Questions**: S1, S2, S3.
* **Caveats**: See [metric definitions](metric-definitions.md) for formulas and [gold usage rules](gold-usage-rules.md) for interpretation.

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
* **Status**: Designed, not built. Needs one analysis unit for province-level facts (province + HUC + NCR rule).
* **Build order**: After `mart_base_planning_unit` and all domain fact tables are materialised.

### `mart_surge_stress_test` (BQ2 main mart)

* **Purpose**: One row per area and scenario: replayed cases, added bed demand, spare beds, shortfall, exceed flag.
* **Questions**: BQ2, D1-D5.
* **Inputs**: `diseases_metric_silver`, `facilities_metric_silver`, `facilities_bed_occupancy_silver`, `scenario_params`.
* **Status**: Needs input. Blocked until admission share and length-of-stay parameters are sourced.

### Gold fact tables

The business question framework references six gold fact tables. Silver data exists for all; gold materialisation is pending.

| Fact table | Questions | Silver source |
|---|---|---|
| `fact_disease_metric` | N1, N2, N3, N4, SUP1, SUP2, CASE | `diseases_metric_silver`, `diseases_directory_silver` |
| `fact_facility_capacity` | S1, A1, A2, D3, SUP3 | `facilities_registry_silver`, `facilities_metric_silver` |
| `fact_bed_occupancy` | S2, D3 | `facilities_bed_occupancy_silver` |
| `fact_workforce` | W1, W2, CASE, SUP4 | `workforce_headcounts_silver` |
| `fact_population` | N4, W1, A1, CASE | `geography_population_silver` |
| `fact_socioeconomic` | E1, E2, SUP5 | `socioeconomic_poverty_silver`, `socioeconomic_health_expenditure_share_silver` |

### Dimensions

| Dimension | Key columns |
|---|---|
| `dim_geography` | `psgc_code`, `area_name`, `geographic_level`, `region_name`, `province_name` |
| `dim_period` | `year`, `month`, `week` |
| `dim_disease` | `disease`, `cause`, `cause_group`, `value_type`, `age_group` |
| `dim_source` | `_source_key`, `_source_file` |
| `dim_facility` | `facility_key`, `facility_level`, `ownership` |
| `dim_profession` | `profession`, `employer_type` |
