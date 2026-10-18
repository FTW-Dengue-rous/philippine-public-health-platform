# Silver layer

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

The silver layer applies cleaning, typing, geographic matching, and lineage tracking. Each domain has numbered SQL scripts in `src/03_silver/`. Silver tables are the direct inputs to gold fact tables and marts that answer the platform's business questions (BQ1 and sub-questions; BQ2 is previous scope). See [business context](../../01-context/problem-and-business-context.md) for the question-to-source traceability.

## Build pattern

Every silver build script follows the same pattern:

1. **Declare build IDs and settings** — UUIDs for `build_log`, strict load lookup flag.
2. **Capture inputs** — list distinct `(_source_key, _source_file, _source_sheet, _ingested_at)` from bronze. Look up each in `ingestion_metadata` (exactly one match per input). Write to `build_inputs`.
3. **Read bronze** — `VERSION AS OF` the captured ingestion timestamp for reproducibility.
4. **Transform** — type columns, rename via `column_map`, match geography, apply business rules.
5. **Validate** — check for null keys, duplicate keys, lineage completeness. If validation fails, log the failed build and leave the target unchanged.
6. **Write** — `CREATE OR REPLACE` the target table with the complete new state.
7. **Record** — append to `build_log` (build metadata) and `row_disposition` (rows not loaded: dropped, duplicate, quarantined, merged).

## Facilities silver tables

| Table | Grain | Key | Rows (latest build) | Script |
|---|---|---|---|---|
| `facilities_id_map_silver` | One source facility identifier | `(_source_key, source_record_id)` | 5,257 | `facilities_silver_01_registry.sql` |
| `facilities_registry_silver` | One facility establishment | `facility_key` | 3,957 | `facilities_silver_01_registry.sql` |
| `facilities_metric_silver` | Area x year x ownership x source | `(area_key, year, ownership, _source_key)` | 2,988 | `facilities_silver_02_metric.sql` |
| `facilities_bed_occupancy_silver` | Hospital x year | `(facility_key, year)` | 9,145 | `facilities_silver_03_bed_occupancy.sql` |
| `facilities_osm_point_silver` | OSM healthsite point | `osm_id` | 16,030 | `facilities_silver_04_osm_point.sql` |

**Build date**: 2026-10-15 (full pipeline run). See [evidence](../../06-evidence/README.md).

The bed occupancy table now includes all years 2018-2025 (9,145 rows, 8,150 baseline eligible). The earlier 2026-10-12 build had 1,977 rows because it filtered to 2025 baseline-eligible only. Use `baseline_eligible = true` for comparable-report analysis. The actual year column is named `year` (int), not `reporting_year`.

### Facility matching

* NHFR hospitals are the registry spine.
* HFSRB licensed lists (hospitals, infirmaries, primary care, dialysis) are matched to NHFR by:
  1. Numeric NHFR code match (with place/name agreement check).
  2. Normalized name + municipality match.
* Unmatched HFSRB facilities become HFSRB-only rows.
* Unmatched NHFR facilities become NHFR-only rows.
* Ambiguous NHFR codes (multiple HFSRB facilities with the same code) are quarantined in `row_disposition`.
* `source_record_id`: `nhfr:<nhfr_id>` for NHFR, `name:<category>|<norm_name>|<psgc>` for HFSRB.

### Text normalization

* `fac_norm`: upper case, ñ → N, remove non-alphanumeric, collapse spaces.
* `fac_place`: strips city/municipality prefixes and suffixes (HUC, ICC, CC, CAPITAL), expands abbreviations (STA → SANTA, STO → SANTO).
* `fac_place_key`: removes spaces for comparison.

## Other domains

See per-domain docs:

* [Geography](geography.md)
* [Diseases](diseases.md)
* [Socioeconomic](socioeconomic.md)
* [Workforce](workforce.md)
* [Population](population.md)
* [Silver quality checks](silver-quality-checks.md)

## Lineage

Silver rows carry lineage columns per the [shared contract](../../lineage-qc-contract_v1.3.md). Load-time facts (batch id, checksum) are in `build_inputs`, reached by a join on `_silver_build_id`.

```sql
SELECT s.*, v.ingested_at, v.load_batch_id, v.content_checksum
FROM public_health.silver.<table> s
JOIN public_health.quality.v_build_lineage v
  ON  v.build_id     =  s._silver_build_id
  AND v.target_table =  'public_health.silver.<table>'
  AND v.source_key   =  s._source_key
  AND v.source_file  =  s._source_file
  AND v.source_sheet <=> s._source_sheet;
```
