# Metric definitions

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Authoritative formulas for all metrics in the gold marts and dashboard. Other documents link here.

## S1 — Hospital availability

### `hospital_count`

* **Numerator**: Count of facilities in `facilities_registry_silver` where `facility_category = 'hospital'`.
* **Grain**: Area (city/municipality or province) × ownership × facility level.
* **Aggregation**: Sum across facilities in the same area, ownership, and level.

### `authorized_beds`

* **Definition**: Sum of Authorized Bed Capacity (ABC) from the registry.
* **Source column**: `facilities_registry_silver.authorized_beds`.
* **Aggregation**: Sum per area × ownership × level.

### `analysis_beds`

* **Definition**: Beds used for analysis. May differ from authorized beds when a facility's implemented beds are known.
* **Source column**: `facilities_registry_silver.analysis_beds`.

### `beds_per_10000_pop`

* **Formula**: `authorized_beds / population × 10000`.
* **Numerator**: `authorized_beds` (sum of ABC in the area).
* **Denominator**: Population from `population_silver` (2024 preferred).
* **Scaling**: Per 10,000 population.
* **Interpretation**: Higher means more bed capacity relative to population. WHO benchmark: typically 10–30 beds per 10,000 population.
* **Limitation**: Population year may not match facility snapshot year. Use the closest available.

## S2 — Bed occupancy

### `bor_pct` (Bed Occupancy Rate)

* **Formula**: `implementing_beds / authorized_beds × 100`.
* **Numerator**: `implementing_beds` (actual beds in use).
* **Denominator**: `authorized_beds` (licensed capacity).
* **Source**: `facilities_bed_occupancy_silver.bor_pct`.
* **Unit**: Percentage.
* **Reference year**: 2025 (latest).

### `avg_bor`

* **Definition**: Average `bor_pct` across hospitals in an area.
* **Filter**: `baseline_eligible = true` (facilities with comparable reports).
* **Exclusions**: `bor_pct > 150` (implausible, excluded as data error), `bor_pct IS NULL`, private-only-year rows, level missing.

### `pct_bor_over_100`

* **Definition**: Percentage of reporting hospitals with `bor_pct > 100`.
* **Formula**: `count(bor_pct > 100) / count(bor_pct IS NOT NULL) × 100`.
* **Interpretation**: Over 100% means more patients than licensed beds. May indicate undercounting of beds or overcrowding.

### Weighted BOR

* **Definition**: Sum of implementing beds / sum of authorized beds × 100, weighted by bed count.
* **2025 example**: Government weighted BOR 97.9%, private 55.4%.

## S3 — Primary care availability

### `bhs_count`, `rhu_count`, `mhc_count`, `chc_count`

* **Source**: `facilities_metric_silver` where `_source_key = 'doh_fhsis_demographic'`.
* **Coverage**: 1,422 rows, 2018–2025, 215 areas.
* **Grain**: Province and city × year.

### `health_centers_total`

* **Definition**: `COALESCE(health_centers_total, mhc + chc)`.

### `bhs_per_10000_pop`

* **Formula**: `bhs_count / population × 10000`.
* **Denominator**: `facilities_metric_silver.population` (BIGINT, from FHSIS).

### `rhu_per_10000_pop`

* **Formula**: `rhu_count / population × 10000`.

### `primary_care_per_10000_pop`

* **Formula**: `COALESCE(health_centers_total, mhc + chc) / population × 10000`.

## Interpretation rules

* **Zero vs missing**: A zero count means the source reported zero. A null means the source did not report for that area/year. Never treat null as zero.
* **Double counting**: National totals are not the sum of regional totals if HUCs are counted separately. Province totals exclude HUCs and ICCs.
* **Partial years**: 2025 dengue data ends at September. Do not compare partial-year totals with full-year totals.
* **Rates require both numerator and denominator.** If population is null (e.g. NCR districts), the rate is null, not zero.
