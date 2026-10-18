# Glossary

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Terms used across the platform. Domain-specific field definitions are in the [data dictionary](../04-pipeline/gold/data-dictionary.md). Metric formulas are in [metric definitions](../04-pipeline/gold/metric-definitions.md).

## Geography

| Term | Definition |
|---|---|
| **PSGC** | Philippine Standard Geographic Code. The official coding system for geographic areas, maintained by PSA. The platform uses PSGC Q2 2024 as its reference geography. |
| **Region** | The highest subnational level (17–18 regions). The count changes over time (e.g. Negros Island Region was created and dissolved). |
| **Province** | The second level under a region. Highly urbanized cities (HUCs) and independent component cities (ICCs) are administratively separate from provinces. |
| **City/Municipality** | The third level. HUCs and ICCs report directly to the region, not through a province. |
| **Barangay** | The lowest administrative level. Not used as a grain in the current analytical marts. |
| **NCR** | National Capital Region (Metro Manila). Has no provinces; its districts function as province-equivalents. |

## Facilities

| Term | Definition |
|---|---|
| **NHFR** | National Health Facility Registry, maintained by DOH. The platform uses NHFR hospitals as the registry spine. |
| **HFSRB** | Health Facilities and Services Regulatory Board. Issues licences for hospitals, infirmaries, primary care facilities, dialysis clinics, and blood service facilities. |
| **FHSIS** | Field Health Services Information System. Annual DOH reporting of facility counts (BHS, RHU, MHC, CHC) by area. |
| **ABC** | Authorized Bed Capacity. The number of beds a hospital is licensed to operate. |
| **BOR** | Bed Occupancy Rate. The percentage of authorized beds that are occupied. Calculated as implementing beds / authorized beds × 100. |
| **BHS** | Barangay Health Station. The lowest-level primary care facility, typically one per barangay. |
| **RHU** | Rural Health Unit. A primary care facility serving a municipality. |
| **MHC** | Main Health Centre. A larger primary care facility. |
| **CHC** | City Health Centre. A primary care facility in urban areas. |
| **Facility key** | A stable identifier assigned by the platform to each unique facility establishment, used across silver and gold tables. |

## Data concepts

| Term | Definition |
|---|---|
| **Reference year** | The year the data describes (e.g. 2025 poverty incidence). Different from the download date. |
| **Registered vs reported** | Registered data comes from a registry (NHFR, HFSRB). Reported data comes from periodic reporting (FHSIS). They may not agree. |
| **Recorded is not absence** | A facility not listed in a registry does not prove it does not exist. It may be unregistered, unlisted, or listed under a different name. |
| **Bronze** | Raw layer: all columns as STRING, original file names, lineage columns added. No transformations. |
| **Silver** | Cleaned layer: typed columns, standardized names, matched geography, lineage-tracked. One row per business grain. |
| **Gold** | Analytical layer: marts and dimensions designed for dashboard consumption. |
| **Source key** | A stable identifier for a source (YAML entry name). Never changed once in use. |
| **Build ID** | A UUID assigned to each silver or gold build. Used in `build_log` and `build_inputs` for lineage tracing. |
