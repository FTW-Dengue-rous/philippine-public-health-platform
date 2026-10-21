# Bronze — quality checks

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Every check that guards the bronze layer: what it tests, which source it runs on, how bad a failure is, and what to do about it. The check IDs, names and severities on this page are the ones in the QC scripts' `CHECKS` dictionaries.

Status date: 2026-10-20. Back to the [bronze overview](README.md). The full reference (loaders, `run_bronze.py`, recovery) is [`src/02_bronze/README.md`](../../../src/02_bronze/README.md); every code across all layers (B, S, G) is in the [quality check catalog](../quality/quality-check-catalog.md).

---

## 1. Summary

Bronze is checked at three points:

| # | When | What | Where it runs | On failure |
|---|---|---|---|---|
| 1 | **Before writing** | Ingestion-contract checks on the file | Inside each loader (`<domain>_bronze.py`, `geography_bronze.py`, `admin_boundaries_bronze.py`) | Nothing is written for that source; a `failed` row goes to `bronze.ingestion_metadata` |
| 2 | **After loading** | Bronze QC on the loaded table | One script per domain, run by `run_bronze.py` right after its loader | Any FAIL stops the run before the next domain |
| 3 | **Before silver** | Preload gate on the stored QC results | `bronze_gate.py`, one job task per domain | The gate raises, so that domain's silver tasks do not start |

Rules that apply to every check:

- Bronze QC checks that a load is **complete and faithful to its source**. It checks no business rules; those belong to silver.
- **FAIL** means the load itself is wrong or cannot be traced: missing file, wrong row count, double load, broken lineage, numbers that disagree with a verified control. It blocks silver.
- **WARN** means the load is faithful, but the source has something a person should read: blank rows, duplicates, text in a number column, a total that does not add up. It does not block. Bronze keeps the rows in both cases.
- Results are written by `dq_utils.DQRun` to `quality.qc_results`, one row per check. The run summary goes to `quality.run_log`, row counts and Delta versions to `quality.table_stats`, column profiles to `quality.profile`.
- No number that a check depends on is typed in a QC script. Expected rows and control values come from `config/sources_<domain>.yaml` (section 3.3).

## 2. Scripts, sources and run order

| Order | Script | What it checks | Codes |
|---|---|---|---|
| 1 | `geography_bronze_qc.py` | PSGC API snapshot in `geography_bronze` (source `psgc`) | GB00–GB13 |
| 1 | `psgc_population_bronze_qc.py` | Population JSON nested in the same `geography_bronze` rows (`psgc_population`) | B00, B01, B04, B05, B07, B10, B13, B15, B16 |
| 2 | `admin_boundaries_bronze_qc.py` | HDX boundaries in `admin_boundaries_bronze` (`hdx_phl_admin`) | HB00–HB14 |
| 3–6 | `diseases_bronze_qc.py`, `facilities_bronze_qc.py`, `workforce_bronze_qc.py`, `socioeconomic_bronze_qc.py` | Every enabled file source of the domain's YAML | B00–B15 |
| — | `bronze_gate.py` | The stored results of all of the above (writes nothing) | — |

All scripts are in `src/05_quality/bronze/` (the domain QC scripts and the gate) and `src/05_quality/` (geography, admin boundaries). `run_bronze.py` runs each one after its domain's loader: geography first, population right after geography QC clears, then admin boundaries and the four file domains. The six `gate_<domain>` job tasks run after the bronze tasks and before silver.

Which sources get QC in a run:

| Source | QC runs? |
|---|---|
| Loaded in this run (new or changed file) | Yes |
| Unchanged, and its QC state is cleared (PASS or WARN) | No |
| Unchanged, and its QC state is **not cleared** (FAIL, CRASHED, STALE or NOT_CHECKED) | **Yes: re-queued** |
| One of several entries that share a `source_key_override` | Yes, together with the others under that key |

Options common to the four file-domain scripts:

| Option | Default | Use |
|---|---|---|
| `--source_keys` | `ALL` | Check only some sources |
| `--fail_on_error` | `true` | `false` records results without raising (for investigation only) |
| `--profile` | `true` | Also write column profiles (never for restricted sources) |
| `--config_path` | found by search | Path to `sources_<domain>.yaml` |
| `--job_run_id` | none | Pass `{{job.run_id}}` from the Databricks job |
| `--code_version` | none | Git commit or tag |

Geography QC takes the loader's handoff (`--landing_batch_path`, `--bronze_batch_id`, `--content_checksum`, `--expected_record_count`); run on its own with none of them, it reads them from the latest `processed` `ingestion_metadata` row for `psgc`. Admin boundaries QC takes `--bronze_handoff_path`; `run_bronze.py` passes it.

## 3. How a result is decided

### 3.1 Status

A check either gives its status directly (PASS or its severity), or gives `fail_count` and `total_count` and lets `dq_utils` decide: PASS when the failing share is at or below the threshold (default 0), otherwise the check's severity.

`B00` / `GB00` / `HB00` "QC ran without error" is recorded as FAIL when a source's checks raise an error, for example a missing table or an invalid YAML override. The other sources still run, and the run fails at the end.

### 3.2 Identity of a result

| Column | Holds |
|---|---|
| `batch_id` | `<source_key>:<sha256 of the file or snapshot>` (lineage contract, section 8). HDX uses `dataset_id:source_version`, where the version is also a sha256 |
| `source_key` | The source checked. Entries with a `source_key_override` write under that key (for example the four `doh_fhsis` entries) |
| `validation_id` | One QC run. Its `run_log` row holds the domain, which the gate uses |
| `observed` / `expected` / `detail` | What was found, what was required, and a short list of the failing files or rows (500 characters at most) |

### 3.3 Where the expected values come from

| Kind of number | Source |
|---|---|
| Rows per file (B03) | `qc.expected_rows` in the source's YAML entry, per file name |
| Published control totals and values (B11) | `qc.control_totals` and `qc.control_values`, each with the published figure and the filter that selects it |
| Columns that must parse as numbers (B10) | `qc.numeric_columns`, with `qc.null_tokens` for markers such as `*` or `-` |
| Total-equals-parts rule (B12) | `qc.row_sum` |
| Rows the loader logged (B13, GB13) | `bronze.ingestion_metadata`, the `processed` row of the same load |
| Required columns (B04, GB02) | `required_columns` in the YAML, or the script's fixed lineage list |

These are expectations tied to one file. When a new file lands, its name changes, the check fails until someone verifies the new value and updates the YAML. That is the intended behaviour.

### 3.4 YAML overrides

- `qc.skip_checks: [B08]` switches a check off for that source. `qc.severity: {B03: WARN}` changes what a failed check produces.
- Only known codes are accepted, B00 cannot be skipped, and a severity must be WARN or FAIL. Anything else stops that source with B00.
- Every skip and override is written into the source's B01 `detail`, so a switched-off check stays visible in `qc_results`.
- Accepted WARNs are explained in the YAML `notes`, not switched off.

### 3.5 Restricted sources (D-47)

Sources with `sharing: restricted` get counts only: no column profile, because a minimum or maximum would copy a record value into `quality.profile`.

## 4. Loader checks (before writing)

The loader checks each file before anything is written. A failure stops that source only; the other sources continue, and the run ends as failed with the list.

| Check | Fails when |
|---|---|
| `header_check` | The title or header rows don't contain the expected text at the expected positions (checked on the raw rows, before YAML column names are applied) |
| `required_columns` | A named column is missing (`header_mode: single`) |
| Encoding | A byte doesn't fit the declared encoding (`encoding_errors: strict`, the default) |
| Data rows | A file or sheet gives no data rows |
| Reconciliation after the write | Rows in the table per file ≠ rows read |
| `ingestion_metadata` write | The load-log row could not be written (the data stays; the next run reloads the file because there is no `processed` row) |

The PSGC loader re-validates the landing batch (marker, manifest, checksums, unique codes) and refuses a second snapshot for the same version. The HDX loader verifies the receipt and manifest and reconciles rows per admin level.

## 5. Code ranges

| Range | Owner |
|---|---|
| B00–B15 | File domains (diseases, facilities, workforce, socioeconomic); same name and meaning in every domain |
| B16 | Population payload (nested JSON) |
| GB00–GB13 | Geography (PSGC API snapshot) |
| HB00–HB14 | Admin boundaries (HDX) |

## 6. File domains: B00–B15

| Code | Check | Severity | Fails when |
|---|---|---|---|
| B00 | QC ran without error | FAIL | The source's checks raised an error, or a YAML override is invalid |
| B01 | Table exists and has rows | FAIL | No table, or no rows for the source. Detail lists every skip and override |
| B02 | All listed files loaded | FAIL | A file in the YAML `files:` list has no rows in the table |
| B03 | Row count matches expected | FAIL (**WARN if the file has no `qc.expected_rows` yet**) | Rows per file ≠ `qc.expected_rows` |
| B04 | Required columns present | FAIL | A required column is missing from the table |
| B05 | Lineage columns not null | FAIL | `_source_key`, `_source_file`, `_source_row_num`, `_as_of_date` or `_ingested_at` is null |
| B06 | Row number unique per file | FAIL | `_source_row_num` repeats within a file and sheet (a double load) |
| B07 | No fully empty rows | WARN | A row where every data column is empty |
| B08 | No exact duplicate rows | WARN | Two rows identical on every data column within one file and sheet |
| B09 | No rescued values | WARN | `_rescued_data` holds cells beyond the last named column |
| B10 | Numeric column parses | WARN | A value in `qc.numeric_columns` is not a number and not a null token |
| B11 | Control totals / values match | FAIL | A published total or value from the YAML differs |
| B12 | Total equals sum of parts | WARN | A `qc.row_sum` total ≠ the sum of its parts |
| B13 | Rows match ingestion metadata | FAIL, **also when it cannot be verified** | Rows per file ≠ the loader's `processed` log row for the **same** load; or no log table, no `processed` row, or rows from a different load |
| B14 | No files outside the YAML | WARN | The table holds a file the YAML no longer lists (kept, never deleted) |
| B15 | Data columns are STRING | FAIL | A data column is not STRING |

B13 became FAIL on 2026-10-19: silver takes each file's load id and checksum from that log row, so an unverifiable load would break silver lineage. The first run with the stricter rule (2026-10-19) found no B13 FAIL.

## 7. Geography (`geography_bronze_qc.py`)

Re-validates the landing batch on its own, then compares it with the bronze snapshot. Every check is FAIL.

| Code | Check | Fails when |
|---|---|---|
| GB00 | QC ran without error | The checks raised an error |
| GB01 | Landing batch matches handoff | The landing manifest's checksum or record count ≠ the loader's handoff |
| GB02 | Required columns present | A required bronze column is missing |
| GB03 | Landing records parse to the expected count | Landed records don't parse to the manifest count |
| GB04 | Snapshot has rows | No bronze rows for the snapshot |
| GB05 | Snapshot row count matches landing | Bronze rows ≠ landing records |
| GB06 | `psgc_code` not blank | A blank code |
| GB07 | `psgc_code` unique | A code repeats in the snapshot |
| GB08 | No landing codes missing from bronze | A landed code is not in bronze |
| GB09 | No bronze codes missing from landing | Bronze has a code that was not landed |
| GB10 | Source JSON matches landing | Stored JSON ≠ landed JSON for a code |
| GB11 | Projected attributes match | A bronze attribute ≠ the loader's extraction from the JSON |
| GB12 | Snapshot lineage complete | Batch id, raw path or load time missing |
| GB13 | Rows match ingestion metadata | Rows ≠ the loader's `processed` log row. WARN if the log table cannot be read |

`--write_results no` prints the results and writes nothing.

## 8. Admin boundaries (`admin_boundaries_bronze_qc.py`)

Checks one HDX source version at one Delta version, from `bronze_handoff.json`. Every check is FAIL and none can be skipped. It also writes `bronze_qc_summary.json` next to the handoff.

| Code | Check |
|---|---|
| HB00 | QC ran without error |
| HB01 | Total row reconciliation |
| HB02 | Row reconciliation per administrative level |
| HB03 | Required lineage and fingerprint completeness |
| HB04 | Record fingerprint unique per administrative level |
| HB05 | Batch identity consistent |
| HB06 | Raw record fingerprint integrity |
| HB07 | Raw feature JSON parses |
| HB08 | Administrative p-code not blank |
| HB09 | Administrative name not blank |
| HB10 | P-code unique within its level |
| HB11 | GeoJSON feature type |
| HB12 | Polygon geometry type |
| HB13 | Administrative parent reference resolves |
| HB14 | Required source property keys present |

## 9. Population (`psgc_population_bronze_qc.py`)

Checks the population JSON nested in the latest PSGC batch of `geography_bronze`. Settings come from `psgc_population` in `sources_population.yaml`. Uses `strict_registry=True`, so every code must exist in `quality.check_registry`. Its `run_log` domain is `population`.

| Code | Check | Severity |
|---|---|---|
| B00 | QC ran without error | FAIL |
| B01 | Table exists and has rows for the latest batch | FAIL |
| B04 | Required columns present | FAIL |
| B05 | Lineage columns not null | FAIL |
| B07 | No fully empty rows | WARN |
| B10 | Population values parse as numbers | WARN |
| B13 | Rows match ingestion metadata | FAIL |
| B15 | Data columns are STRING | FAIL |
| B16 | Nested population payload parses | WARN |

File and sheet checks (B02, B03, B06, B08, B09, B11, B12, B14) are skipped: PSGC is an API source.

## 10. Preload gate (`bronze_gate.py`)

The gate reads `public_health.quality` and writes nothing. It runs before each domain's first silver task.

### 10.1 Source states

| State | Meaning | Blocks? |
|---|---|---|
| PASS | Every check of the latest QC run passed | No |
| WARN | No FAIL, at least one WARN | No |
| FAIL | The latest QC run has a FAIL, including B00 / GB00 / HB00 | **Yes** |
| CRASHED | A bronze QC run of the same domain errored (`run_log` status ERROR) at or after the source's latest result | **Yes** |
| STALE | The source was loaded again after its latest QC, so QC never saw this load | **Yes** |
| NOT_CHECKED | No bronze QC result for the source | **Yes** (`--allow_unchecked true` lets it pass) |

### 10.2 Which sources it checks

- The domain's enabled YAML file sources, plus every bronze source the domain's latest successful silver build read (`build_log` + `build_inputs`). The second part catches a source switched off in the YAML but still read by silver.
- Geography covers `psgc` and `psgc_population`; admin boundaries covers `hdx_phl_admin`.
- A result counts only for the domain of its QC run. A key in two domains (`doh_fhsis_demographic`: workforce and facilities, two bronze tables) is checked once per domain and printed as `key (domain)`.
- STALE needs a load log, so it is detected only for sources that write `ingestion_metadata`. `psgc_population` uses the PSGC log name, so a new PSGC load makes it STALE until its QC runs again.

`run_bronze.py` uses the same states to decide which unchanged sources to re-queue (section 2).

## 11. Latest recorded run

Notebook runs on Databricks, 2026-10-19 (PHT):

| Step | Result |
|---|---|
| First gate run, all domains | Stopped on 17 sources as NOT_CHECKED: their last QC predated the quality schema. A one-time baseline QC run gave them results |
| Gate, all domains | 41 sources: 39 PASS, 2 WARN, 0 blocking. Gate passed |
| `run_bronze.py`, all 6 domains (loaders `2026-10-19.1`) | 46 sources unchanged, 0 loaded, 0 failed, 0 QC re-queued. Geography line: `psgc_population: WARN (cleared, not re-run)` |

The full job run (gate tasks before silver) is recorded with the silver revisions. Results of every run go to [`06-evidence/`](../../06-evidence/README.md).

**Expected WARNs** (reviewed 2026-10-19; the current counts are `fail_count` in `qc_results`):

| Source | Check | Reading |
|---|---|---|
| `philhealth_foi_claims_hospital` | B08 | The source repeats some rows (separate sub-rows of the same hospital, illness and status). Silver sums them |
| `doh_fhsis_demographic` (workforce) | B08 | Identical rows with a blank area below the table, 2019 workbook, sheet *Health Workers Part2*. Silver drops blank-area rows |
| `psgc_population` | B10 | Values with thousands separators, a leading bracketed note or `-`. Silver parses them (VALID, VALID_WITH_NOTE, MISSING); silver QC S52 and S53 check the result |
| Any file without `qc.expected_rows` | B03 | Not verified yet (WARN by design) |

## 12. Reading the results

**What the gate would stop on:**

```sql
SELECT table_name, source_key, check_id, status, observed, expected, detail
FROM public_health.quality.v_open_issues
WHERE layer = 'bronze' AND status <> 'WARN';
```

**Latest result of every bronze check:**

```sql
SELECT table_name, source_key, check_id, check_name, status, fail_count, total_count,
       observed, expected, detail, executed_at
FROM public_health.quality.qc_results
WHERE layer = 'bronze'
QUALIFY row_number() OVER (PARTITION BY table_name, source_key, check_id, column_name, detail
                           ORDER BY executed_at DESC) = 1
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, source_key, check_id;
```

**Summary of the last run of each script:**

```sql
SELECT script_name, domain, status, checks_total, checks_pass, checks_warn, checks_fail,
       started_at, ended_at, validation_id
FROM public_health.quality.run_log
WHERE layer = 'bronze'
QUALIFY row_number() OVER (PARTITION BY script_name ORDER BY started_at DESC) = 1
ORDER BY script_name;
```

**Files still without a verified row count:**

```sql
SELECT source_key, detail FROM public_health.quality.v_open_issues
WHERE check_id = 'B03' AND expected = 'not set';
```

**The gate's view of every source, without stopping:**

```python
import runpy, sys

sys.argv = ["bronze_gate.py", "--allow_unchecked", "true"]  # prints every source's state
runpy.run_path("<repo>/src/05_quality/bronze/bronze_gate.py", run_name="__main__")
```

## 13. When a check fails

| Result | Likely cause | Do |
|---|---|---|
| B00 FAIL "invalid override" | `skip_checks` or `severity` in the YAML names an unknown code, B00, or a severity other than WARN / FAIL | Fix the YAML, then rerun `run_bronze.py` (the source is re-queued) |
| B03 / B11 FAIL | A new file with a different count or total, or a wrong YAML value | Check the file. If it is right, update `expected_rows` / the control in the YAML; rerun |
| B13 FAIL "no processed row" or "different load" | The log row was not written, or the table holds rows from another load | Rerun `run_bronze.py`: a file with no `processed` row reloads |
| B06 FAIL | A double load | Rerun; the loader replaces the file's rows. If it persists, delete that file's rows on purpose and reload |
| GB01 / GB05 / GB08–GB11 FAIL | Landing batch and bronze snapshot disagree | Follow the geography loader's message; a partial batch must be deleted before reloading |
| HB FAIL | HDX run incomplete or changed | Finish or retry the HDX ingestion run, then rerun |
| Gate NOT_CHECKED | No QC result for the source | Run `run_bronze.py` (re-queues it), or that domain's QC script |
| Gate STALE | Loaded after its last QC | Run `run_bronze.py` |
| Gate CRASHED | A QC run of the domain errored | Read `quality.v_run_errors`; fix and rerun |
| WARN | Source gap or disagreement | Compare with the expected WARNs (section 11); a new one goes in the YAML `notes` with its reason |

## 14. Limitations

- Bronze checks faithfulness, not correctness: a wrong but well-formed value (wrong year, mislabelled area) passes. Silver QC and controls catch some of these.
- A file with no `qc.expected_rows` and a plausible wrong count passes B03 as WARN.
- STALE is not detected for HDX boundaries, which write no `ingestion_metadata` row.
- YAML parsing-setting changes are not detected; a changed setting needs `--force_keys`.
- No statistical drift checks (row count or key sums against the previous load) yet.
- `strict_registry` is on for every bronze QC script since 2026-10-21 (`dq_utils.py` default). GB, HB and B16 codes are in `quality_registry_seed.sql` (Step 1b), and the `qc_registry` job task checks the registry after every run (O-17).
- The four file-domain QC scripts are the same code, kept in sync by hand (backlog: one shared module).
- WARNs reach silver by design; the gate does not stop on them.

Open items: [known issues and backlog](../../08-governance/known-issues-and-backlog.md). Decisions D-50 to D-55: [decision log](../../08-governance/decision-log.md).

## 15. History of updates

| Date | Change |
|---|---|
| 2026-10-04 – 10-05 | Bronze QC written per domain |
| 2026-10-07 | Results move to `public_health.quality` through `DQRun` |
| 2026-10-14 | Incremental loaders; `run_bronze.py` runs QC after each file domain |
| 2026-10-15 | PSGC loader writes `ingestion_metadata` and a QC handoff; HDX QC as a job script |
| 2026-10-19 | QC re-queue in `run_bronze.py`; preload gate per domain; geography QC on `DQRun` (GB00–GB13); population QC inside `run_bronze.py` and the gate; YAML overrides validated and recorded; B13 FAIL when a load cannot be verified; one `batch_id` form; gate matches results per domain; timezone-aware UTC timestamps |
| 2026-10-20 | Page written |
| 2026-10-21 | Strict registry on for every bronze QC script (O-17) |
