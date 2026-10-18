# FOI data request log

Owner: LUNASaan Documentation Team
Last updated: 2026-10-15

Data obtained through the Philippine eFOI portal (freedom of information requests to DOH).

| Request | Source key | Ticket number | Date requested | Status | Sharing class | Notes |
|---|---|---|---|---|---|---|
| Dengue surveillance (cases/deaths by region × month, 2021–2025) | `doh_foi_dengue` | CONFIRM | ~2025-09 | Received | Restricted | File ends at 2025-09; partial year. Last months likely incomplete due to reporting lag. |
| Hospital beds by municipality, 2018–2025 | `doh_foi_hospital_beds` | DOH-984883683631 | CONFIRM | Received | Restricted | Restricted folder. |
| Bed occupancy by hospital, 2020–2025 | `doh_foi_bed_occupancy` | CONFIRM | CONFIRM | Received | Restricted | Superseded by HFSRB bed data, kept for lineage. |

**Ticket numbers marked CONFIRM** were not verified against the actual FOI response. Confirm before publishing.

## Restricted data handling

FOI-released data is stored in the `restricted/` folder under the landing volume. It is not redistributed outside the project workspace. See [data governance](../08-governance/data-governance.md) for sharing rules.
