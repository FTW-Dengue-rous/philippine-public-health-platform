# Bronze layer (`src/02_bronze`)

The bronze layer copies every source file into the lakehouse exactly as it arrived. It changes no values: a cell that says "1,234" stays the text "1,234". What bronze adds is a label on every row: which source, which file, which sheet, which row, and when it was loaded.

Bronze has two jobs:

- **Trust.** Every number on the dashboard can be traced back to the file and row it came from.
- **Safe reruns.** Unchanged files are skipped, changed files are reloaded, and silver never builds on a load that failed or skipped its checks.

Cleaning, matching and calculations happen later, in silver and gold. The original data is never lost.

| Setting | What you need to know |
|---|---|
| Catalog / schema | `public_health.bronze` |
| Landing root | `/Volumes/workspace/default/ftw-b12-de/groups/g5_landing` |
| Configuration | One YAML file per domain: `config/sources_<domain>.yaml`. Adding a dataset means adding an entry, not code |
| One command | `run_bronze.py` loads every domain, then runs its bronze QC. See [section 5](#5-run_bronzepy-one-command-for-bronze) |
| Load log | `public_health.bronze.ingestion_metadata`, one row per file or sheet per run |
| Quality results | `public_health.quality.qc_results`, written through `dq_utils.DQRun`. See [section 6](#6-bronze-qc) |
| Gate before silver | `bronze_gate.py` stops a domain's silver build when one of its bronze sources is not cleared. See [section 7](#7-preload-gate-bronze_gatepy) |

If you are rebuilding bronze, start with section 1. If a run failed, go to section 8.

---

## 1. Folder layout and run order

```
config/
├── sources_diseases.yaml        sources_facilities.yaml
├── sources_workforce.yaml       sources_socioeconomic.yaml
├── sources_geography.yaml       (PSGC snapshot: psgc, HDX boundaries: hdx_phl_admin)
└── sources_population.yaml      (psgc_population: QC settings only)
src/
├── 00_setup/
│   ├── ingestion_metadata.sql   creates the shared load log
│   └── quality_setup.sql        creates public_health.quality
├── 02_bronze/
│   ├── run_bronze.py            loader -> QC for every domain
│   ├── diseases_bronze.py       facilities_bronze.py
│   ├── workforce_bronze.py      socioeconomic_bronze.py      (file loaders, same code)
│   ├── geography_bronze.py      (PSGC API snapshot)
│   └── admin_boundaries_bronze.py (HDX administrative boundaries)
└── 05_quality/
    ├── dq_utils.py              DQRun: writes every QC result
    └── bronze/
        ├── diseases_bronze_qc.py  facilities_bronze_qc.py
        ├── workforce_bronze_qc.py socioeconomic_bronze_qc.py   (B00–B15, same code)
        ├── geography_bronze_qc.py          (GB00–GB13)
        ├── admin_boundaries_bronze_qc.py   (HB00–HB14)
        ├── psgc_population_bronze_qc.py    (population payload in the PSGC table)
        └── bronze_gate.py                  (preload gate before silver)
```

**Run order on a fresh workspace**

1. Run `ingestion_metadata.sql` and `quality_setup.sql`. The setup job does both.
2. Land the files and add or update their YAML entries.
3. For admin boundaries, run the HDX ingestion notebook first. It writes the `_runs/<run_id>/handoff.json` the loader reads.
4. Run `run_bronze.py --plan true`. It lists what would load and which QC would rerun, and writes nothing.
5. Run `run_bronze.py`.

**In the pipeline job** (`resources/ph_public_health_job.yml`)

| Task | Runs | Waits for |
|---|---|---|
| `bronze_<domain>`, one per domain (6) | `run_bronze.py --domains <domain> --job_run_id {{job.run_id}}`. `bronze_geography` also runs the population payload QC | `setup` |
| `gate_<domain>`, one per domain (6) | `bronze_gate.py --domains <domain>` | `bronze_<domain>` |
| first silver tasks of each domain | silver builds | `gate_<domain>` (population silver: after geography silver QC) |

The job allows one run at a time (`max_concurrent_runs: 1`). The geography and admin boundaries loaders are only safe with one writer.

---

## 2. Landing

- **Folder = layout = bronze table.** Path: `<domain>/<source>/[<geo>_<grain>/]`.
- **File names:**
  - Period tables: `{source}_{content}_{geo}_{grain}_{years}.{ext}`.
  - Snapshots: `{source}_{content}_{geo}_asof_{yyyymmdd}.{ext}`.
- **Never edit a landed file.** A newer release is a new file in the same folder. A different layout gets its own folder and table.
- **Restricted files** sit under `<domain>/restricted/`. These are FOI releases, the patient-level hospital extract, bed occupancy and IHME GBD. They are never committed to GitHub.
- **PSGC:** the PSGC API job lands a completed snapshot under `geography/psgc_api/raw/version=<version>/run_id=<id>/`: API pages, record files, `manifest.json` and `_SUCCESS`.
- **HDX boundaries:** the HDX ingestion notebook writes prepared files and a `handoff.json` under `admin_boundaries/_runs/<run_id>/`.

---

## 3. The loaders

There are three kinds of loader. Each one writes its own bronze table and checks its own write, but they read different inputs.

| | File loaders (diseases, facilities, workforce, socioeconomic) | `geography_bronze.py` (PSGC) | `admin_boundaries_bronze.py` (HDX) |
|---|---|---|---|
| Reads | The files listed in the domain YAML | The newest completed PSGC landing snapshot | The latest HDX ingestion run's `handoff.json` |
| Writes | One table per source: `<domain>_<source>_<content>_bronze` | The PSGC bronze table (`psgc.bronze_table` in the YAML) | `public_health.bronze.admin_boundaries_bronze` |
| Rerun rule | Only new or changed files load (section 3.4) | Same snapshot already in bronze → no write | Same source version already complete → no write |
| Write | Delta `replaceWhere` per file (`_source_key` + `_source_file`) | Insert-only `MERGE` on the snapshot key | Append of a new source version |
| Load log | One `ingestion_metadata` row per file or sheet | One `ingestion_metadata` row per run | None (limit L4) |
| Lineage columns | `_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`, `_as_of_date`, `_ingested_at`, `_rescued_data` | `source_system`, `source_version`, `source_endpoint`, `batch_id`, `content_checksum`, `raw_path`, `ingested_at` | `_source_key`, `_dataset_id`, `_source_version`, `_batch_id`, `_admin_level`, `_source_file`, `_source_file_sha256`, `_record_sha256` and more |
| Plan mode | `--plan true` | `--write_to_bronze no` (returns the planned action) | `--plan true` (returns LOAD or ALREADY_COMPLETE) |

The four file loaders are the same code. Only `DOMAIN` and the config name differ. The team started with one script per dataset. It moved every domain to this YAML pattern on 2026-10-06, once the file count made per-dataset code unmanageable.

### 3.1 YAML entry (file loaders)

Each dataset is one entry in `config/sources_<domain>.yaml`:

- **Identity:** `source_key`, source name, `as_of_date`, `sharing` (`open`, `public` or `restricted`).
- **Location:** landing path, files and sheets.
- **Reading settings:**
  - `header_mode`: `single` uses the file's header; `names` takes names from the YAML by position; `none` gives `col_0, col_1…` for stacked tables.
  - `data_start_row` and encoding.
- **Contract checks before the write:** `header_check` (expected text at expected positions) and `required_columns`.
- **Target:** the bronze table name.
- **`qc` block:** expected row counts, control totals and values, numeric columns, `skip_checks` and severity overrides. See section 6.1.

### 3.2 Row shape (file loaders)

One bronze row is one data row of one source file or sheet. There is no business key. **Every data column is STRING.**

| Column | Meaning |
|---|---|
| `_source_key` | YAML entry key |
| `_source_file` | Path under the landing root. Also the unit that is replaced on a reload |
| `_source_sheet` | Excel sheet; null for CSV |
| `_source_row_num` | 0-based row number in the file or sheet |
| `_as_of_date` | Release or download date from the YAML, not the load time |
| `_ingested_at` | Load time (UTC). The same for the whole run |
| `_rescued_data` | Cells beyond the last named column, with their positions |

**Extraction rules**

- **Values:** empty cells become null. Excel dates become ISO text. Whole-number floats lose their `.0`. Formulas are read as their saved results.
- **Rows:** fully empty rows are skipped and counted. Footer and note lines are loaded; silver drops them.
- **Column names:** cleaned only for characters Delta does not allow, and made unique ignoring case.

The PSGC loader keeps each original record as JSON (`source_record_json`) plus the nested population JSON. The HDX loader keeps each feature, its properties and its geometry as JSON.

### 3.3 Load sequence (file loaders, per source)

1. **Check before writing**, for every file of the source: `header_check`, `required_columns`, strict decoding, and at least one data row. If any check fails, nothing is written for that source.
2. **Write.** Each file's rows are replaced in one transaction: Delta `replaceWhere` on `_source_key` + `_source_file`, with `mergeSchema`.
3. **Reconcile.** The rows per file in the table must equal the rows read.
4. **Log.** Append one `ingestion_metadata` row per file or sheet. If this write fails, the data stays committed and the run fails. The next run detects it and reloads (section 8).

### 3.4 Incremental loading (file loaders, since version `2026-10-14.1`; current `2026-10-19.1`)

Each run compares every listed file and sheet with its latest `processed` row in `ingestion_metadata`:

| Reason | Detected by | Action |
|---|---|---|
| `new` | No processed row for (source, path, sheet, table) | Load |
| `content_changed` | File sha256 ≠ logged checksum | Reload the file |
| `as_of_date_changed` | YAML `as_of_date` ≠ logged `source_version` | Reload the file |
| `bronze_rows_differ` | Bronze no longer holds exactly that load's rows | Reload the file |
| `no_checksum_logged` | Old log row without a checksum | Reload once |
| `forced` | `--force true`, or the source is in `--force_keys` | Reload all its files |
| unchanged | Everything matches | Skip; log `skipped_duplicate` |

- **Unchanged files keep their rows and `_ingested_at`,** so silver built from them stays fresh.
- **Not detected:** changes to an entry's parsing settings or to loader code. Use `--force_keys <source>` after such a change.
- **A file removed from the YAML** is reported and kept in bronze.

### 3.5 PSGC and HDX loaders

**`geography_bronze.py`** (version `2026-10-19.1`)

- It loads the newest completed PSGC landing batch for the YAML `psgc.version`.
- It first re-validates the batch: marker, manifest, files, record JSON, unique codes and content checksum.
- One run does one of: `load`, `unchanged`, `backfill_audit` (the rows were there but the log row was missing), `repair` (rows partly there, no log row) or `blocked`.
- It returns a handoff: `batch_id`, `content_checksum`, `landing_batch_path`, `expected_record_count`. `run_bronze.py` passes these to the geography QC.

**`admin_boundaries_bronze.py`** (version `2026-10-19.1`)

- It reads the latest HDX ingestion attempt under the YAML `hdx_phl_admin.landing_path`.
- If that attempt is incomplete, it stops. **It never falls back to an older run.**
- It verifies the landing receipt and the staging manifest, then appends the source version, or does nothing if that version is already complete.
- A partly loaded version stops the run. Delete it by hand before you reload.
- It writes `bronze_handoff.json` next to the ingestion handoff. The admin QC reads that file.

---

## 4. `ingestion_metadata`: the shared load log

One append-only table with 15 columns. Every file loader and the PSGC loader write to it:

| Column | Meaning |
|---|---|
| `batch_id` | One per loader run. For PSGC, the landing run id. Equals the PSGC rows' `batch_id` |
| `source_name` | The YAML source key for file sources. For PSGC, the YAML `psgc.source_name` |
| `source_version` | `as_of_date` as text (files) or the PSGC version |
| `content_checksum` | sha256 of the file (files) or the manifest checksum (PSGC) |
| `raw_file_path`, `source_sheet` | What was read |
| `record_count`, `column_count`, `file_size_bytes` | What was loaded |
| `retrieved_at` | Load time (UTC). Equals the rows' `_ingested_at` / `ingested_at` for a `processed` row |
| `status` | `processed`, `failed` or `skipped_duplicate` |
| `endpoint`, `page_count` | API loads only |
| `bronze_table`, `error_message` | Target and failure or skip note |

Silver reads `batch_id` and `content_checksum` from here for lineage. That is why bronze rows carry no load id or checksum column (decision 2026-10-08).

---

## 5. `run_bronze.py`: one command for bronze

`run_bronze.py` runs each domain's loader, then that domain's bronze QC. Domains run in this order: `geography`, `admin_boundaries`, `diseases`, `facilities`, `workforce`, `socioeconomic`. Geography goes first because every silver domain reads it.

### 5.1 Which sources get QC in a run

| Source in this run | QC runs? |
|---|---|
| Loaded (new or changed) | Yes |
| Unchanged, and its bronze QC is **not cleared** (FAIL, CRASHED, STALE or NOT_CHECKED; section 7.1) | **Yes: re-queued** |
| Unchanged and cleared (PASS or WARN) | No |
| Loader failed | No; the run ends failed |

**Shared source keys:** several YAML entries can write QC results under one `source_key` (`source_key_override`; e.g. `doh_fhsis_tb`, `doh_fhsis_tb_tpt`, `doh_fhsis_tb_treatment_success` and `doh_fhsis_morbidity` all write `doh_fhsis`). `run_bronze` looks up the state of that shared key for each entry. When one of them gets QC, all enabled entries under the same key get QC in the same run. The gate reads only the latest run of a key, so that run must cover every entry, or an older FAIL of one entry would be hidden.

**Why the re-queue matters:** before 2026-10-19, an unchanged source was skipped, so a source whose last QC failed stayed failed while the run still reported "complete". Now it is checked again. Typical case: you fix `qc.expected_rows` in the YAML. The file has not changed, but its QC reruns and clears it.

### 5.2 How the result is judged

After QC, `run_bronze.py` reads each checked source's state back from `public_health.quality`. It does not trust the QC script's exit code alone. So `--fail_on_qc false` still reports a FAIL in the summary; it only stops the run from raising. The preload gate still stops that domain's silver.

### 5.3 Geography and admin boundaries

These two loaders have their own input contracts (section 3.5). A thin wrapper in `run_bronze.py` calls each one and maps its outcome to the same result as the file loaders:

| Loader outcome | Counted as |
|---|---|
| PSGC `load`, `repair`, `backfill_audit` / HDX `loaded` | loaded |
| PSGC `unchanged` / HDX `already_complete` | unchanged |
| PSGC `blocked`, any error | failed |

The wrapper then passes the loader's handoff to that domain's QC script.

**Population payload QC.** The geography domain also runs `psgc_population_bronze_qc.py` (config `sources_population.yaml`, source key `psgc_population`). The population JSON sits in the same `geography_bronze` rows, so there is no separate loader. It runs:

- after a geography load, once geography QC has cleared (if geography QC fails, the snapshot itself is in question and the run stops there); or
- when its own state is not cleared (re-queue), even if geography is unchanged.

Its result shows in the geography summary line as `psgc_population: PASS / WARN / FAIL`.

`--force` does not apply to these two domains, and `--force_keys psgc` or `hdx_phl_admin` stops with a clear message. A new snapshot or source version loads by itself.

### 5.4 Options

| Option | Effect |
|---|---|
| `--domains` | `all` (default) or a comma list |
| `--source_keys` | Only these sources. Each is sent to the domain that owns it |
| `--plan true` | Print per file LOAD / skip and which QC would rerun. Writes nothing; runs no QC |
| `--force_keys` | Reload these sources in full (after a parsing-setting or loader change) |
| `--force true` | Reload every selected file source in full. This makes silver stale |
| `--qc false` | Skip bronze QC and the re-queue |
| `--fail_on_qc` | `true` (default): a QC FAIL stops the run before the next domain. `false`: record, report, continue |
| `--job_run_id`, `--code_version` | Passed to every QC script, so `quality.run_log` links to the job run |
| `--repo_root` | The repo folder; found automatically from the script's location |

**Stops:** a failed source does not stop the other sources or domains. The run ends failed with the list. A QC FAIL stops the run before the next domain. The summary names the domains whose bronze changed, so their silver and gold can be rerun.

---

## 6. Bronze QC

Bronze QC checks that each load is **complete and faithful to its source**. It checks no business rules; those belong to silver QC. Every script writes through `dq_utils.DQRun` into `public_health.quality`:

| Table | What it gets |
|---|---|
| `qc_results` | One row per check |
| `run_log` | One row per QC execution |
| `table_stats` | Row count and Delta version of each table checked |
| `profile` | Column profiles. Off for restricted sources, and off by default for geography and admin boundaries |

**Severity policy**

| Severity | Meaning |
|---|---|
| **FAIL** | The load itself is wrong or cannot be traced: missing file, wrong row count, double load, broken lineage, numbers that disagree with a verified control. A FAIL stops the job before silver. |
| **WARN** | The load is faithful, but the source has something a person should look at: blank rows, duplicates, text in a number column, a total that does not add up. |

Bronze keeps the rows in both cases.

**`batch_id`** is `<source_key>:<sha256 of the file or snapshot>` (lineage-qc-contract.md, section 8). `quality.v_qc_results_identity` reads the checksum from it. HDX uses its own `dataset_id:source_version`, where the version is also a sha256.

### 6.1 File domains: B00–B15

The four `<domain>_bronze_qc.py` scripts are the same code.

| Code | Check | Severity |
|---|---|---|
| B00 | QC ran without error (per source) | FAIL |
| B01 | Table exists and has rows for the source | FAIL |
| B02 | Every file listed in the YAML was loaded | FAIL |
| B03 | Rows per file = `qc.expected_rows` | FAIL. **WARN if the file has no expected count yet** |
| B04 | Required columns exist | FAIL |
| B05 | Lineage columns are never null | FAIL |
| B06 | `_source_row_num` unique per file and sheet (no double load) | FAIL |
| B07 | No rows where every data column is empty | WARN |
| B08 | No exact duplicate rows within a file and sheet | WARN |
| B09 | No rescued (overflow) values | WARN |
| B10 | `qc.numeric_columns` can be read as numbers | WARN |
| B11 | Control totals and control values match verified numbers | FAIL |
| B12 | A total column equals the sum of its parts (`qc.row_sum`) | WARN |
| B13 | Rows per file = the loader's log row for the same load | FAIL, **also when it cannot be verified** (no log table, no `processed` row, rows from a different load) |
| B14 | The table holds no files outside the YAML | WARN |
| B15 | Every data column is STRING | FAIL |

**YAML overrides: rules**

- `qc.skip_checks: [B08]` switches a check off. `qc.severity: {B03: WARN}` changes what a failed check produces.
- Only known codes can be used, and B00 cannot be skipped. Severities must be WARN or FAIL.
- Anything else stops that source with B00. Before 2026-10-19, `severity: {B13: PASS}` silently disabled a check.
- Every skip and override is written into that source's B01 `detail`, so a switched-off check stays visible in `qc_results`.

### 6.2 Geography (PSGC): GB00–GB13

`geography_bronze_qc.py` re-validates the landing batch on its own, then compares it with the bronze snapshot.

It needs the loader's four handoff values. `run_bronze.py` passes them. Run on its own with none of them, it reads them from the latest `processed` `ingestion_metadata` row for `psgc` (`batch_id`, `content_checksum`, `raw_file_path`, `record_count`). Pass all four or none.

Every check is FAIL:

| Code | Check |
|---|---|
| GB00 | QC ran without error |
| GB01 | Landing batch is complete and matches the loader's handoff |
| GB02 | Bronze has every required column |
| GB03 | Landing records parse to the expected count |
| GB04, GB05 | Snapshot has rows; row count = landing count |
| GB06, GB07 | `psgc_code` never blank; unique |
| GB08, GB09 | No landing code missing from bronze; no extra bronze code |
| GB10, GB11 | Stored JSON = landed JSON; projected attributes = the loader's extraction |
| GB12 | Snapshot lineage is complete (batch id, raw path, load time) |
| GB13 | Rows = the loader's `processed` log row. WARN if the log table cannot be read |

`--write_results no` prints the results and writes nothing.

### 6.3 Admin boundaries (HDX): HB00–HB14

`admin_boundaries_bronze_qc.py` reads `bronze_handoff.json` and checks one source version at one Delta version. It checks:

- row counts in total and per admin level;
- lineage and fingerprints;
- fingerprint integrity and JSON parsing;
- p-codes and names: present and unique per level;
- feature and geometry types;
- parent references and required property keys.

All are FAIL, and none can be skipped. It also writes `bronze_qc_summary.json` next to the handoff.

### 6.4 Population payload: `psgc_population_bronze_qc.py`

This script checks the population JSON nested in the latest PSGC batch:

| Code | Check |
|---|---|
| B01, B04, B05, B07, B13, B15 | Shared bronze checks |
| B16 | `populations_json` parses |
| B10 | Population values are numbers |

**Expected WARN:** B10 (94 of 127,945 nested values when reviewed on 2026-10-19; the current count is `fail_count` in `qc_results`). The raw text has thousands separators, a leading bracketed note (`(excluding CITY OF ANGELES) 1,234`) or `-`, so it does not cast as it stands. `population_silver` parses these (VALID, VALID_WITH_NOTE, MISSING); silver QC S52 and S53 check the result.

It runs inside `run_bronze.py`, in the geography domain (section 5.3). It writes `run_log` rows with domain `population`. It uses `strict_registry=True`, so every code must exist in `check_registry`.

### 6.5 Reading the results

| View | Use it for |
|---|---|
| `quality.v_open_issues` | Latest results that are not PASS |
| `quality.v_table_health` | One status per table |
| `quality.v_run_errors` | QC scripts whose latest run crashed |

```sql
-- what the gate would stop on, per source
SELECT layer, table_name, source_key, check_id, status, observed, expected, detail
FROM public_health.quality.v_open_issues
WHERE layer = 'bronze' AND status <> 'WARN';

-- files still without a verified row count (B03 is only WARN for these)
SELECT source_key, detail FROM public_health.quality.v_open_issues
WHERE check_id = 'B03' AND expected = 'not set';
```

---

## 7. Preload gate: `bronze_gate.py`

The gate runs before a domain's first silver task. It stops silver when a bronze source the domain reads is not cleared. It reads `public_health.quality` and writes nothing. If it stops, the job shows which source and why.

### 7.1 Source states

| State | Meaning | Blocks? |
|---|---|---|
| PASS | Every check of the latest QC run passed | No |
| WARN | No FAIL, at least one WARN | No |
| FAIL | The latest QC run has a FAIL, including B00 / GB00 / HB00 | **Yes** |
| CRASHED | A bronze QC run of the same domain crashed (`run_log` status ERROR) at or after the source's latest result | **Yes** |
| STALE | The source was loaded again after its latest QC, so QC never saw this load | **Yes** |
| NOT_CHECKED | No bronze QC result at all | **Yes** (`--allow_unchecked true` lets it pass) |

`run_bronze.py` re-queues the same blocking states (section 5.1).

- **STALE needs a load log.** It is only detected for sources that write `ingestion_metadata`, so HDX is not covered (limit L4).
- **PSGC name mapping.** PSGC is matched by its YAML `psgc.source_name`, the name its loader logs.

### 7.2 Which sources it checks

For `--domains <domain>`, the gate checks:

- **(a)** the domain's enabled YAML file sources; and
- **(b)** every bronze source that the domain's latest successful silver build read (`quality.build_log` + `build_inputs`, `input_kind = 'bronze_source'`).

Part (b) catches a source that was switched off in the YAML but is still read by silver.

A key in several domains is checked once per domain and printed as `key (domain)`, e.g. `doh_fhsis_demographic (workforce)` and `doh_fhsis_demographic (facilities)`. `qc_results` has no domain column, so the gate joins each result to its `run_log` row (same `validation_id`) and uses that run's domain. One domain's result never clears the other.

Geography (`psgc` and `psgc_population`) and admin boundaries (`hdx_phl_admin`) are listed in the script. `psgc_population` uses the PSGC load log name, so a new PSGC load makes it STALE until its QC runs again.

| Option | Use |
|---|---|
| `--exclude_keys <key>` | Drop a source the silver build does not read |
| `--source_keys` | Check exactly these sources |

```
bronze_gate.py --domains diseases --repo_root <repo>
bronze_gate.py --domains geography
bronze_gate.py                      # no arguments, or --domains all: every domain (a manual check)
```

In a notebook, set `sys.argv` before `runpy.run_path(...)` to pass arguments. Without them, the gate checks every domain.

### 7.3 What the gate does and does not protect

| Protected | Not protected |
|---|---|
| Silver never builds on a bronze load that failed, crashed, was never checked, or was reloaded after its check | WARN results. These reach silver by design; silver parse statuses, quarantine and silver QC handle them |
| A FAIL left by an earlier run, even if this run's loader changed nothing | Wrong but well-formed content (wrong year, mislabelled area). Bronze checks faithfulness, not correctness |
| A run with `--fail_on_qc false` | A file with no `qc.expected_rows` and a plausible wrong count (B03 is WARN) |
| | Silver run by hand outside the job, unless you run the gate first |

---

## 8. When a run fails: recovery

"Rerun" means `run_bronze.py` again with no flags. Reruns are idempotent:

- each file's rows are replaced, never appended twice;
- the load log is append-only;
- only new or changed files load;
- sources that are not cleared get their QC again.

| # | Scenario | What happens | Fix |
|---|---|---|---|
| 1 | A check before the write fails (header, required column, decoding, no rows) | Nothing written for that source; `failed` log row; other sources continue; run ends failed | Fix the YAML or the file, then rerun. It loads as `new` |
| 2 | Write ok, reconciliation fails | Run fails | Rerun. `bronze_rows_differ` reloads the file; no duplicates |
| 3 | Log row fails to write | Data committed; run fails | Rerun. No `processed` row, so the file reloads; no duplicates |
| 4 | QC FAIL, the file is wrong | Rows stay; run stops; gate stops silver | Land a corrected file. Same name: `content_changed` reloads it. New name: update the YAML, delete the old file's rows on purpose, rerun |
| 5 | QC FAIL caused by the YAML `qc` block (wrong control value) | Run stops; gate stops silver | Fix the YAML and rerun. **The source is re-queued** and its QC reruns, although the file is unchanged |
| 6 | QC FAIL, nothing fixed, someone reruns | The source is re-queued, FAILs again, and the run fails | Fix the cause first |
| 7 | QC script crashes | `run_bronze` reports FAIL; state CRASHED or FAIL; gate stops silver | Fix the environment and rerun; the source is re-queued |
| 8 | Rerun with nothing changed | Every file `skipped_duplicate`; QC only for sources not cleared | Nothing to do |
| 9 | Parsing setting changed in the YAML | Not detected | `--force_keys <source>`, then rerun that domain's silver |
| 10 | Latest HDX ingestion run is incomplete | Admin boundaries task fails; never falls back | Finish or retry the HDX ingestion |
| 11 | PSGC snapshot `blocked` (another snapshot for the same version, or a logged but incomplete batch) | Geography fails; nothing written | Follow the message: review, or delete the partial batch and reload |

Scenarios 5–7 were gaps before 2026-10-19 and are closed by the re-queue and the gate.

**Deliberately not done:**

- writing a `qc_failed` status into `ingestion_metadata` (that would change a contract the API job also uses);
- deleting bronze rows on a QC FAIL (that would lose the evidence).

---

## 9. Reliability in short

| Property | How bronze provides it |
|---|---|
| **Idempotent** | The unit of write is one file or sheet, replaced in one transaction. PSGC uses an insert-only MERGE; HDX skips a complete version. Running twice never doubles rows |
| **Incremental** | Only new, changed, re-dated or forced files load. Unchanged files keep their rows and load time |
| **Gated** | Checks before the write, after the write, and on the stored table. A QC FAIL stops the run, and the gate stops silver |
| **Recoverable** | Every failure has a rerun path (section 8). Landing files are never edited. Delta history keeps earlier versions |
| **Auditable** | One log row per file per run; one QC row per check; QC runs linked to the job run id |

---

## 10. Sharing

`sharing` is set per YAML entry: `open`, `public` or `restricted`.

- **Restricted** covers the FOI files, the patient-level Davao extract, the bed occupancy file and IHME GBD (licence).
- Restricted values are never copied into docs or GitHub, and bronze QC writes no column profile for them.
- Gold publishes restricted data as aggregates only.
- Unity Catalog grants are not applied yet (limit L6).

---

## 11. Inventory (summary)

| Domain | Tables | Main sources |
|---|---|---|
| Diseases | 16 + 2026-10-14 entries (TB programme, PhilHealth claims) | DOH FOI dengue and TB, UP NOAH, HDX dengue, PSA deaths / morbidity / notifiable, FHSIS TB and morbidity, Davao hospital pneumonia, PhilHealth claims, IHME GBD |
| Facilities | 15 | NHFR, HFSRB lists, HDX healthsites, PSA hospital / bed / BHS tables, bed occupancy, FHSIS primary care |
| Workforce | 3 | FHSIS health workers, PSA government practitioners, PSMO oncologists |
| Socioeconomic | 5 | PSA poverty, health expenditure (2), child mortality, PSGC datafile |
| Geography | 2 | PSGC API snapshot (Q2_2024, 43,762 records); HDX COD-AB boundaries (1,747 features: ADM1 17, ADM2 88, ADM3 1,642) |

**Confirm the final counts** from `ingestion_metadata` after the next full run. The per-table inventory is in `docs/bronze.md`.

**Databricks run, 2026-10-19 (PHT)**

| Step | Result |
|---|---|
| Baseline QC (5 domain QC scripts and geography QC, run by hand) | Wrote the first `quality.qc_results` rows for 17 sources whose last QC predated the quality schema. The gate had stopped on them as NOT_CHECKED, as designed |
| `bronze_gate.py`, all domains | 41 sources: 39 PASS, 2 WARN, 0 blocking. Gate passed |
| WARN 1: `philhealth_foi_claims_hospital` B08 | 19 exact repeat rows in the source. Silver sums them (YAML notes) |
| WARN 2: `doh_fhsis_demographic` B08 (workforce table) | 6 identical rows with a blank `area_name` in the 2019 workbook, sheet *Health Workers Part2*. Silver drops blank-area rows |
| `run_bronze.py`, first run (geography, admin boundaries, diseases) | All unchanged. Diseases re-queued the 4 `doh_fhsis` entries; their QC passed (75 checks, 0 FAIL), but the run reported FAIL because it looked them up by entry name, and stopped. Fixed the same day (section 5.1) |
| `run_bronze.py`, second run (override fix, before the population QC change), all 6 domains | 46 sources unchanged (geography 1, admin boundaries 1, diseases 19, facilities 16, workforce 3, socioeconomic 5; `doh_fhsis_demographic` counted in both facilities and workforce). 0 loaded, 0 failed, 0 QC re-queued: every source was already cleared. About 13 minutes in total; the geography loader took about 5 of them, validating the full landing batch even when unchanged |
| `run_bronze.py`, third run (16:25 PHT; file loaders `2026-10-19.1`, timezone-aware load time), all 6 domains | 46 sources unchanged, 0 loaded, 0 failed, 0 QC re-queued. The new load times matched every existing load, so no file reloaded. `psgc_population` was not re-queued: its QC was already cleared. `run_bronze` now prints its state on the geography line even when it is not re-run |
| `run_bronze.py`, fourth run (16:42 PHT; current `run_bronze.py`) | Same result as the third run. The geography line now reports the population state: `psgc_population: WARN (cleared, not re-run)`, so the run log shows it was checked |
| **Bronze closed, 2026-10-19** | Code, QC and docs done. Open WARNs are all explained: B08 `philhealth_foi_claims_hospital` (source repeats), B08 `doh_fhsis_demographic` workforce (blank-area rows), B10 `psgc_population` (text silver parses). The job run (gate tasks before silver) is recorded with the silver revisions |
| Next | The full job, so the six `gate_<domain>` tasks run before silver. Expect `doh_fhsis_demographic` on two gate lines (workforce, facilities) and `psgc_population` under geography |

---

## 12. Known limits and open items

| # | Limit | Current treatment |
|---|---|---|
| L1 | The loader code is copied into four domain files, and the QC code into four QC files | Keep them in sync. A shared module with `--domain` is in the backlog |
| L2 | Parsing-setting and loader-code changes are not detected | `--force_keys`. Backlog: hash the entry's settings into the load log |
| L3 | `mergeSchema` adds unexpected columns silently; no statistical drift checks | Backlog: schema and row-count drift checks on `qc_results` |
| L4 | HDX boundaries write no `ingestion_metadata` row | The gate cannot detect STALE for `hdx_phl_admin`; HB01/HB02 reconcile counts to the manifest instead |
| L5 | Lineage column names differ between file loaders, PSGC and HDX | Silver lineage code is not fully shared. Backlog: align names |
| L6 | `sharing: restricted` is declared only | Backlog: Unity Catalog grants |
| L7 | B03 is only WARN for files with no `qc.expected_rows` | Add expected counts. Query in section 6.5 |
| L8 | Fixed 2026-10-19: `dq_utils._now()` and the four file loaders (`INGESTED_AT`, version `2026-10-19.1`) write timezone-aware UTC; the PSGC and HDX loaders already did. Times are correct on any driver timezone | Same stored values on Databricks, so existing loads still match and are skipped. Tested: the old loader was 8 hours off on a UTC+8 machine |
| L9 | New GB codes are not in `check_registry`; population QC uses `strict_registry=True`, the others False | Add GB01–GB13 to `quality_registry_seed.sql`; switch all scripts to strict after the seed |
| L10 | Facilities entries 1–13 have no `header_check` | A shifted column in a `names` layout would load under the wrong names. Backlog |
| L11 | `_as_of_date` mixes release and download dates; several marked CONFIRM | Backlog: split the two dates |
| L12 | PSGC is ingested twice (API snapshot under geography, datafile under socioeconomic) | The platform stands on the Q2_2024 API snapshot. Backlog: one owner per vintage |
| L13 | Files are read on the driver (largest: PhilHealth claims, 245,405 rows) | Fine today. Backlog: Spark reads for large files |
| L14 | The 2026-10-19 changes ran on Databricks from a notebook (gate, then a clean `run_bronze` over all 6 domains). Not yet run as the job, and the population QC change is not yet run on Databricks | Run the current `run_bronze.py`, then the full job; record both in section 11 |
| L15 | Fixed 2026-10-19: a key in two domains (`doh_fhsis_demographic`) is checked once per domain. A QC result counts only for the domain of its QC run (`run_log.domain`) | A facilities reload still marks the workforce entry STALE too (same load log name). Harmless: it only re-runs that QC |

---

## 13. Running bronze without Databricks

Bronze needs four capabilities. None of them is Databricks-only.

| Capability | Used for | On Databricks | Open-source way |
|---|---|---|---|
| File storage for landing files | `<landing_root>/<domain>/<source>/` folders | Unity Catalog Volume | A local folder or object store. Set `landing_root` (file YAMLs), `psgc.landing_path` and `hdx_phl_admin.landing_path`; keep the layout below them |
| Spark with a versioned table format | One table per source; `replaceWhere` / `MERGE`; `ingestion_metadata`; QC table versions | Delta tables in Unity Catalog | Apache Spark 4.x with open-source Delta Lake |
| Python with `pyyaml` and `openpyxl` | Reading the YAML and the Excel files | Job environment libraries | `pip install pyyaml openpyxl` |
| Running loaders and QC in order, stopping on failure | `run_bronze.py`, then `bronze_gate.py` before silver | Job tasks | `python run_bronze.py`, then `python bronze_gate.py --domains <d>`, from any scheduler. Both exit non-zero on a failure |

**What carries over unchanged**
- The incremental rule (checksum computed in Python).
- YAML-driven loading.
- The lineage columns.
- The QC checks and `dq_utils.py`.
- The re-queue and the gate.

**What to change**
- **Paths:** the landing paths in the YAML files.
- **Three-part names:** keep a `public_health` catalog, or switch to two-part names. The PSGC loader and QC, and the HDX loader, check for three-part names, so relax those checks if you drop the catalog.
- **`/Volumes` paths:** the HDX loader and QC accept only `/Volumes/...` paths. Change `safe_volume_file` / `safe_handoff_path` for another storage root.
- **Timezone:** run the driver on UTC, or apply the `_now()` fix (limit L8).
- **Re-pulling sources:** the PSGC and HDX landing jobs need network access to their APIs. The bronze loaders read only what is already landed.

See `docs/platform-requirements.md` for versions and the full list.

---

## 14. History of updates

| Date | Change |
|---|---|
| 2026-10-04 – 10-05 | First bronze loads per dataset, starting with diseases. Bronze QC written per domain |
| 2026-10-06 | All file domains moved to the YAML-driven loader. Shared `ingestion_metadata` (15 columns) |
| 2026-10-07 | Quality schema `public_health.quality`; bronze QC writes through `DQRun` |
| 2026-10-08 | Bronze table contract fixed: no new columns on existing tables; lineage identifiers come from `ingestion_metadata` |
| 2026-10-14 | Incremental file loaders (`2026-10-14.1`) and `run_bronze.py` for the four file domains |
| 2026-10-15 | PSGC loader writes `ingestion_metadata` and a QC handoff; HDX loader as a job script |
| 2026-10-16 / 10-17 | Full runs 1 and 2, end to end |
| 2026-10-19 | **QC re-queue** in `run_bronze.py`. **Preload gate** (`bronze_gate.py`, one job task per domain). **Geography and admin boundaries in `run_bronze.py`**, with no hard-coded HDX run path and no `admin_boundaries_run_dir` parameter. Geography QC moved to `DQRun` (GB00–GB13, new GB13 log check). All QC scripts: YAML overrides validated and recorded; B13 FAIL when a load cannot be verified. Facilities and population QC `batch_id` back to the contract form. Admin QC: hard-coded handoff path removed. Geography QC runs with no arguments (handoff from `ingestion_metadata`). `run_bronze` maps `source_key_override` (the `doh_fhsis` entries were re-queued as NOT_CHECKED on every run and reported as QC FAIL) and QCs entries that share a key together. Population payload QC moved into `run_bronze` (geography) and the gate; the `qc_bronze_psgc_population` job task is removed. Gate matches results on domain (via `run_log`), so a key shared by two domains is checked per domain. `dq_utils._now()` and the file loaders (`2026-10-19.1`) write timezone-aware UTC |
