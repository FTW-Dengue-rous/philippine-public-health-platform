# Data governance

Owner: Jemma Santiago
Last updated: 2026-10-18

## Ownership

The person responsible for a domain's Bronze implementation also owns its Silver implementation and domain documentation.

| Domain | Bronze owner | Silver owner | Documentation owner |
|---|---|---|---|
| Facilities | Cristina Villota, Via Cabuyao | Cristina Villota, Via Cabuyao | Cristina Villota, Via Cabuyao |
| Diseases | Jemma Santiago | Jemma Santiago | Jemma Santiago |
| Geography | Margarette Legaspi | Margarette Legaspi | Margarette Legaspi |
| Population | Margarette Legaspi | Margarette Legaspi | Margarette Legaspi |
| PSGC ingestion | Shiena Arico | -- | Shiena Arico |
| Socioeconomic | Virna Pomendia | Virna Pomendia | Virna Pomendia |
| Workforce | Virna Pomendia | Virna Pomendia | Virna Pomendia |
| Dashboard | -- | -- | Cristina Villota |
| CI/CD and DevOps | -- | -- | Jemma Santiago |

PSGC ingestion is distinct from the broader geography domain. Shiena Arico owns the PSGC API ingestion pipeline; Margarette Legaspi owns geography bronze, silver, and documentation.

For documents that span multiple domains or have no single domain owner, the LUNASaan Documentation Team is the maintenance owner.

See [team and timeline](team-and-timeline.md) for the full team roster.

## Access boundaries

### Unity Catalog

* Catalog: `public_health` — created by the setup job.
* Schemas: `bronze`, `silver`, `gold`, `quality`.
* Access is managed via Databricks workspace permissions and Unity Catalog grants.
* The bundle (`databricks.yml`) defines job-level permissions for the prod target.

### Landing volume

* `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing` — shared team volume.
* Open data and restricted data live in the same volume. Restricted data is in subfolders marked `restricted/`.

## Sharing classes

| Class | Sources | Rule |
|---|---|---|
| Open | PSA, HDX, UP NOAH, PSMO, DOH public releases | Can be shared with attribution. Check per-source license. |
| Restricted | DOH FOI releases (dengue, bed occupancy, hospital beds) | Internal use only. Must not be redistributed outside the project workspace. |
| Non-commercial | IHME, GLOBOCAN | For research only. May not be used commercially. Attribution required. |

## Source provenance

Every bronze row carries `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, and `_ingested_at`. The `ingestion_metadata` table records the load batch ID and content checksum for each source file. Silver rows carry `_silver_build_id` which links to `build_log` and `build_inputs` for full lineage. See the [lineage contract](../lineage-qc-contract_v1.3.md).

## Sensitive data handling

* **No patient-level data.** All data is aggregated or facility-level.
* **No PII in the warehouse.** Facility names and addresses are public registry data.
* **FOI-released data** is stored in `restricted/` folders and not synced by the DABs bundle.
* **Small-cell suppression** is not applied because there are no individual-level counts. Facility counts by area are public.

## Change responsibilities

| Change type | Who | Process |
|---|---|---|
| Add a new source | Domain owner | Add YAML entry, place file in landing, run bronze, add silver build, update docs |
| Update a source file | Domain owner | Replace file in landing, run bronze (incremental), rebuild silver |
| Change business rules | Domain owner + team lead | Update silver SQL, rebuild, verify row counts, update metric definitions |
| Change YAML config | Domain owner | Update config, force-reload bronze if parsing changed, rebuild silver |
| Change job configuration | Team lead | Update `resources/*.yml`, deploy bundle |
| Change permissions | Team lead or workspace admin | Update `databricks.yml` or Unity Catalog grants |

## How to update sources

1. Place the new or updated file in the correct landing folder (per the YAML config).
2. Run `run_bronze.py --domains <domain>` to load it incrementally.
3. Run the domain's silver SQL scripts in order.
4. Check QC results and row counts.
5. Rebuild gold if affected.
6. Update the source's `as_of_date` in the YAML if the file is a new snapshot.
7. Update `expected_rows` in the YAML if the row count changed.

After any change, verify: row counts match, QC has no ERROR failures, dashboard shows current data.
