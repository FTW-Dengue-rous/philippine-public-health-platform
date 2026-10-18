# Business data dictionary

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Plain-language definitions of every column in the dashboard mart, for non-technical readers. For technical column types and silver table definitions, see the [data dictionary](data-dictionary.md). For metric formulas, see [metric definitions](metric-definitions.md).

## `mart_area_service_profile`

This is the table behind the dashboard. Each row is one combination of area, ownership, facility level, and year.

| Column | What it means |
|---|---|
| `supply_section` | Which question this row answers: `S1_hospital_supply` (hospital availability), `S2_hospital_occupancy` (bed occupancy), or `S3_primary_care_supply` (primary care facilities). |
| `area_level` | Whether this row is for a city/municipality or a province. |
| `area_name` | The name of the area (e.g. "Ilocos Norte", "Manila"). |
| `psgc_code` | The official government code for this area. May be blank for some NCR districts. |
| `region_name` | The region this area belongs to. |
| `province_name` | The province this area belongs to. Blank for NCR and highly urbanized cities. |
| `year` | The year this data describes. Blank for S1 (current snapshot, no year). |
| `ownership` | Whether the facilities are government or private. |
| `facility_level` | Hospital level: Level 1, 2, 3, or Specialist. |
| `population` | How many people live in this area. Used to calculate per-capita rates. May be blank for some areas. |
| `hospital_count` | How many hospitals are in this area. |
| `authorized_beds` | Total licensed beds in this area. |
| `beds_per_10000_pop` | Beds per 10,000 people. Higher means more capacity. Blank when population is blank. |
| `avg_bor` | Average bed occupancy rate (S2 only). How full the hospitals are on average. |
| `pct_bor_over_100` | What percentage of hospitals are over 100% occupancy (S2 only). Over 100% means more patients than licensed beds. |
| `facility_count_reporting` | How many hospitals reported occupancy data (S2 only). Shows how complete the data is. |
| `bhs_count` | Number of Barangay Health Stations (S3 only). |
| `rhu_count` | Number of Rural Health Units (S3 only). |
| `health_centers_total` | Total health centres (S3 only). |
| `bhs_per_10000_pop` | BHS per 10,000 people (S3 only). |
| `primary_care_per_10000_pop` | Health centres per 10,000 people (S3 only). |

## Key terms explained

| Term | Plain-language meaning |
|---|---|
| Authorized beds | The number of beds a hospital is licensed to operate. This is not the same as beds actually in use or staffed. |
| Bed occupancy rate (BOR) | The percentage of licensed beds that are occupied. Calculated as beds in use divided by licensed beds, times 100. |
| Baseline eligible | A facility with a complete and comparable occupancy report. Rows that are not baseline eligible are excluded from S2 averages. |
| PSGC code | A unique government code for each area (region, province, city, municipality). The platform uses the Q2 2024 version. |
| HUC | Highly Urbanized City. Reports directly to the region, not through a province. |
| NCR | National Capital Region (Metro Manila). Has no provinces. |
| Snapshot | Data from a single point in time (e.g. the registry is a 2026-09-29 snapshot). Not time-series. |
| Zero vs blank | A zero means the source reported zero facilities. A blank (null) means the source did not report for that area. Never treat blank as zero. |
