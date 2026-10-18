# Troubleshooting

Owner: Jemma Santiago
Last updated: 2026-10-15

Common failures, symptoms, diagnostic steps, and fixes.

## Bronze layer

### Header check failure

* **Symptom**: Bronze loader fails with "header_check failed at row N".
* **Cause**: The source file's header rows do not match the YAML `header_check` configuration. A column may have shifted, or the file layout changed.
* **Diagnosis**: Run `python <domain>_bronze.py --show_headers 10 --source_keys <key>` to see the actual header rows.
* **Fix**: Update the `header_check` in the YAML config to match the new layout, or fix the source file.

### Encoding error

* **Symptom**: Loader fails with "encoding error" on a specific byte.
* **Cause**: The file contains bytes that do not fit the declared encoding (default: UTF-8).
* **Fix**: Set `encoding_errors: replace` on the YAML entry to load anyway (replaced bytes are counted and logged). Or fix the file encoding.

### Row count mismatch

* **Symptom**: Bronze QC fails check B02 (row count).
* **Cause**: The file has more or fewer rows than the `expected_rows` in the YAML.
* **Diagnosis**: Check if the source published an updated file with different rows. Update `expected_rows` if the new count is correct.

## Silver layer

### "Missing ingestion_metadata row"

* **Symptom**: Silver build fails at the input capture step with "zero matches".
* **Cause**: Bronze was not loaded, or the `ingestion_metadata` table does not have a `processed` row for the source.
* **Fix**: Run bronze first. Check: `SELECT * FROM public_health.bronze.ingestion_metadata WHERE source_name = '<source_key>' AND status = 'processed'`

### Validation gate failure

* **Symptom**: Silver build fails with "gate failed: <gate_name>".
* **Gates**:
  * `null_keys` — a key column has nulls. Check the source data for missing identifiers.
  * `duplicate_keys` — the key is not unique. Check for duplicate source records.
  * `lineage_incomplete` — `_silver_build_id`, `_source_key`, or `_source_file` is null. Check the build script.
  * `registry: every registry key is in the id map` — a facility_key exists in the registry but not the id map. This happens when a facility's records moved to another facility between builds.
* **Fix**: Inspect the candidate table (the build creates a temporary table before writing). Fix the source data or the matching logic.

### BOR > 150 exclusion

* **Symptom**: Bed occupancy silver has fewer rows than expected.
* **Cause**: Rows with `bor_pct > 150` are excluded as implausible data errors. This is by design.
* **Check**: `SELECT count(*) FROM public_health.quality.row_disposition WHERE reason LIKE '%bor_gt_150%'`

## Admin boundaries

### "Not a /Volumes path"

* **Symptom**: `bronze_admin_boundaries` task fails immediately.
* **Cause**: The `admin_boundaries_run_dir` job parameter is blank.
* **Fix**: Set it to the latest completed ingestion run folder: `/Volumes/.../admin_boundaries/_runs/<RUN_ID>`

## Compute

### "numpy.dtype size changed"

* **Symptom**: A Python task fails with a numpy import error.
* **Cause**: The `geo` environment (shapely) was used for a task that does not need it, or shapely 2.1 was installed (requires numpy 2).
* **Fix**: Use the `default` environment for all tasks except `facilities_silver_04a_osm_locate.py`. The `geo` environment pins `shapely<2.1` and `numpy<2`.

### "SQL warehouses only support executing SQL cells"

* **Symptom**: A notebook fails when run on a SQL warehouse.
* **Cause**: SQL warehouses cannot run Python cells.
* **Fix**: Use serverless Spark compute for Python tasks. SQL warehouse is for `.sql` tasks only.

## Dashboard

### Empty dashboard page

* **Symptom**: A dashboard page shows no data.
* **Cause**: The underlying mart table is empty or the query filter returns no rows.
* **Diagnosis**: Run the dataset query directly in SQL editor. Check `SELECT count(*) FROM public_health.gold.mart_area_service_profile WHERE supply_section = '...'`.
* **Fix**: Rebuild the gold mart. Check that the silver inputs exist and are populated.

## Escalation

| Issue type | Escalate to |
|---|---|
| Source data quality | Data engineer who owns the domain |
| Pipeline job configuration | Team lead (CAN_MANAGE on the job) |
| CI/CD or GitHub secrets | DevOps / team lead |
| Dashboard rendering | Team lead |
| Access or permissions | Workspace admin |
