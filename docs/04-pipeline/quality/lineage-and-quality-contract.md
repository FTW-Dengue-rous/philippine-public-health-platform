# Lineage and quality contract

One contract for lineage and QC identity across every domain (geography, facilities, diseases, workforce, socioeconomic) and every layer. Domain pages and READMEs reference this page and only declare what is specific to their sources.

| | |
|---|---|
| **Version** | 1.3 (2026-10-09). The version lives here, not in the file name, so a new version doesn't break links |
| **Status** | Adopted. Applied in every silver and gold build, in `quality_setup.sql` (`build_log`, `build_inputs`, `row_disposition` and their views) and in every silver QC script |
| **Not built yet** | The per-table config of section 4 (one `silver_tables.yaml`, to-do 15): each silver QC script holds its own lineage expectations. Section 5.1 step 2 (transform reads inputs `VERSION AS OF` the captured version): builds read bronze at its current version; this is recommendation R4 in the [silver rebuild strategy](../silver/rebuild-strategy.md) |
| **Bronze** | Not affected: no bronze table, loader or bronze QC change |

Open items of section 12, as of 2026-10-20:

| # | State |
|---|---|
| O1 | Applied in code: candidate and table-level checks use `batch_id = build:<build_id>`. The column comment in `quality_setup.sql` still predates it (to-do 7a) |
| O2 | Open: one `silver_tables.yaml` (to-do 15) |
| O3 | Each build sets its id in a SQL session variable. Passing `{{job.run_id}}` is part of R4 |
| O4 | Open: retention of bronze versions and landing files |
| O5 | Geography and boundaries keep their own lineage columns (endpoint, batch, checksum); see the [bronze overview](../bronze/README.md) |

Version notes:

- **v1.3:** `row_disposition` stores only the bronze rows that were not loaded (dropped, duplicate, quarantined, merged). Loaded rows are no longer written: about 99% fewer rows, with the same reconciliation check (section 7.1).
- **v1.2:** the lineage columns on silver rows go from 11 to 7 (6 where nothing is unpivoted). Facts that are the same for every row of a file (load time, load id, checksum, build time) are stored once per build in `build_inputs` and `build_log`, and reached by a join (sections 3.3 to 3.5, 13).
- **v1.1:** four clarifications (section 13). No table, column or identifier changes.

Appendix A explains why each lineage column is needed, with examples. Read it first if the column list looks like too much. How the contract is checked in practice: [silver reconciliation](../silver/reconciliation.md) and [silver quality checks](../silver/silver-quality-checks.md).

---

## 1. Decisions

| # | Decision | Rule |
|---|---|---|
| C1 | Identifier meanings | `_load_batch_id` = ingestion execution. `_content_checksum` = sha256 of the source file's bytes. QC execution has its own id (`validation_id` in the QC tables) |
| C2 | Source identifier spelling | `_source_key` in bronze and in silver lineage |
| C3 | Metric-column lineage | `_metric_source_columns` stays a MAP. QC normalises it to sorted JSON when it needs to compare |
| C4 | Lineage requirements | Declared in each silver table's config, including conditional rules |
| C5 | Reconciliation | Two separate checks: bronze row dispositions (input accounting) and silver output validation |
| C6 | Gold lineage | Recorded once per build: input table versions and transformation identity. No row-level lineage in gold rows |
| C7 | Freshness | Checked against the complete set of inputs a build consumed, not only against rows that exist in silver |
| C8 | Combined rows | Every contributing source keeps its own identifiers |

---

## 2. Identifiers

Three different things are identified. They must never share a name.

| Identifier | Answers | Where it lives |
|---|---|---|
| `_source_key` | Which source (YAML entry) | Bronze rows, silver rows, `ingestion_metadata.source_name`, `qc_results.source_key` |
| `_content_checksum` | Which bytes: sha256 of the source file | `ingestion_metadata.content_checksum`, `build_inputs.content_checksum`, row dispositions. **Not a silver column** |
| `_load_batch_id` | Which ingestion execution wrote the bronze rows | `ingestion_metadata.batch_id`, `build_inputs.load_batch_id`, row dispositions. **Not a silver column** |
| `_silver_build_id` (gold: `_gold_build_id`) | Which build wrote the silver or gold rows | Silver / gold rows, build log, build inputs, row dispositions |
| `validation_id` | Which QC execution checked the data | `qc_results`, `run_log`, `table_stats`, `profile` |
| `run_id` | Which job run started the script | QC tables, when a job passes it |

Rules:
- **Source content** is identified by `_source_key` + `_content_checksum`, with file and sheet where a source has several.
- **A load is not the same as content.** The same bytes can be loaded twice, and a loader change can process identical bytes differently. Anything that says "this was checked" must also say which load or table version it checked.
- **The bare name `batch_id` is not used in new silver or gold columns.** It stays where it already exists (`ingestion_metadata.batch_id`, `qc_results.batch_id`) with the meaning fixed in sections 2 and 8.
- **A checksum identifies old content; it does not bring it back.** Reproducing an old result needs the retained source file or a retained bronze table version.

---

## 3. Lineage columns

### 3.1 Naming

- Every lineage column starts with `_`.
- Per-source columns in a combined row are `_<side>_<name>`, e.g. `_incidence_source_row_num`, `_nhfr_source_row_num`.
- Units and business meaning never go in lineage columns.

### 3.2 Bronze (current)

`_rescued_data, _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _ingested_at`

**No bronze table changes are needed for this contract.** Bronze rows do not carry `_load_batch_id` or `_content_checksum`; each build gets them from `ingestion_metadata`, once per input (section 3.5). Bronze tables, loaders and bronze QC stay as they are.

### 3.3 Silver, single-source row

`_silver_build_id, _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _metric_source_columns`

- **Seven columns; six where nothing is unpivoted or renamed** (`_metric_source_columns` is left out there).
- `_source_sheet` is null for CSV sources. Joins and comparisons on it use null-safe equality (`<=>`).
- `_rescued_data` is not carried. Bronze QC B09 confirms there is none; if a source has rescued values, silver handles them as real columns.

**The row carries its address. Facts about the file and the build are stored once per build:**

| Fact | Not a silver column. Found in |
|---|---|
| When the bronze rows were loaded | `build_inputs.ingested_at` |
| Which load wrote them | `build_inputs.load_batch_id` |
| Which file version | `build_inputs.content_checksum` |
| When silver was written | `build_log.finished_at` |

These values are identical for every row of one file or sheet in one build, so repeating them on each row adds columns without adding information.

**Getting them for a silver row:**

```sql
SELECT s.*, v.ingested_at, v.load_batch_id, v.content_checksum, v.silver_loaded_at
FROM public_health.silver.<table> s
JOIN public_health.quality.v_build_lineage v
  ON  v.build_id     =  s._silver_build_id
  AND v.target_table =  'public_health.silver.<table>'
  AND v.source_key   =  s._source_key
  AND v.source_file  =  s._source_file
  AND v.source_sheet <=> s._source_sheet;
```

- `v_build_lineage` is `build_inputs` joined to `build_log` for successful builds (created by `quality_setup.sql`).
- The join returns exactly one row per silver row, because a build records each file or sheet once (section 5).
- **`build_log` and `build_inputs` are therefore required**, not optional: without them the load and file version of a row are not recorded anywhere.

### 3.4 Silver, combined row

Shared columns once, then one group per contributing source:

- Always per side: `_<side>_source_sheet`, `_<side>_source_row_num`
- Per side only when the sides are different sources or files: `_<side>_source_key`, `_<side>_source_file`, `_<side>_as_of_date`

- A side that did not contribute has null lineage. A side that contributed must have it (section 4).
- Columns that are truly identical for all sides are stored once (poverty: one file, so `_source_key`, `_source_file` and `_as_of_date` are shared).
- **One workbook does not guarantee one load.** `build_inputs` has one row per sheet, each with its own `load_batch_id` and `content_checksum`. The join in 3.3 is made once per side, on that side's file and sheet.

### 3.5 Getting the load id and checksum (once per input, not per row)

Step 1 of a build (section 5.1) lists its inputs: the distinct `(_source_key, _source_file, _source_sheet, _ingested_at)` in the bronze rows it will read. Each is looked up in `ingestion_metadata`:

- `source_name = _source_key`
- `retrieved_at = _ingested_at`
- `status = 'processed'`
- sheet equal, null-safe
- same file path

**Exactly one match per input**, and **one `_ingested_at` per file or sheet** in bronze. Zero matches means a missing audit row; more than one means duplicate metadata; two load times in one file means a mixed load. Any of them fails a gate before the transform starts.

- The result is the build's input list, written to `build_inputs` on success. It is never joined onto the silver rows, so it cannot multiply them.
- Rules that need the checksum during the build (for example a row override bound to a file version) read it from this input list.
- The lookup depends on two timestamps being equal. That is acceptable with the exactly-one check. Writing the load id and checksum into bronze would remove the lookup, but it means changing every bronze table; it is **not planned** (decided 2026-10-08: no further bronze revisions).

### 3.6 `_metric_source_columns`

- Type `MAP<STRING, STRING>`: silver column → bronze column it came from, e.g. `{poverty_incidence_pct: 'incidence_2025'}`.
- In a single-source row, the MAP with file, sheet and row number points to one source cell.
- **In a combined row, each metric also identifies its lineage group.** The row has several file, sheet and row references, so the bronze column alone is not enough. The association lives in the table config, not in extra columns:

  ```yaml
  socioeconomic_poverty_silver:
    metric_groups:                    # silver metric column -> lineage group (side)
      poverty_incidence_pct: incidence
      poor_population: magnitude
  ```

  A metric's cell is then: the group's `_<side>_source_sheet` and `_<side>_source_row_num`, plus the bronze column from the MAP. QC checks that every key of the MAP has a group in the config.
- The restriction is on operations that use the MAP value itself (`DISTINCT`, `EXCEPT`, `INTERSECT`, grouping on it). Grouping or joining on ordinary key columns is unaffected.
- **Shared comparison expression** for QC:

  ```sql
  to_json(sort_array(map_entries(_metric_source_columns))) AS metric_source_columns_comparison
  ```

  Map entries are unordered; sorting them gives a stable text.
- Uniqueness checks use business keys. Lineage reproducibility checks include the normalised expression, so this metadata is checked and not simply left out.

### 3.7 Volatile columns

`_silver_build_id` changes on every build. It is left out of rerun-equality checks and declared as `volatile` in the table config.

---

## 4. Lineage requirements per table

Each silver table declares its requirements in its config. The silver QC reads the declaration; it never assumes one fixed column list.

```yaml
socioeconomic_poverty_silver:
  key: [area_key, year]
  lineage:
    always:                         # never null
      - _silver_build_id
      - _source_key
      - _source_file
      - _as_of_date
      - _metric_source_columns
    groups:                         # one group per contributing source
      incidence:
        required_when: "true"       # both sheets always contribute
        columns: [_incidence_source_sheet, _incidence_source_row_num]
      magnitude:
        required_when: "true"
        columns: [_magnitude_source_sheet, _magnitude_source_row_num]
    nullable: []
  inputs:
    - {bronze_table: socioeconomic_psa_poverty_bronze, source_key: psa_poverty, sheet: tab2, side: incidence}
    - {bronze_table: socioeconomic_psa_poverty_bronze, source_key: psa_poverty, sheet: tab6, side: magnitude}
  volatile: [_silver_build_id]

facilities_registry_silver:         # example of conditional rules
  key: [facility_key]
  lineage:
    groups:
      nhfr:
        required_when: "in_nhfr = true"
        columns: [_nhfr_source_key, _nhfr_source_file, _nhfr_source_row_num, _nhfr_as_of_date]
      hfsrb:
        required_when: "in_hfsrb = true"
        columns: [_hfsrb_source_key, _hfsrb_source_file, _hfsrb_source_sheet, _hfsrb_source_row_num,
                  _hfsrb_as_of_date]
    nullable: [_hfsrb_source_sheet]   # CSV sources have no sheet
```

How the QC reads it:
- `always` columns: null count must be 0.
- A group's columns must be not null on rows where `required_when` is true.
- A group's columns **should be null** where `required_when` is false. Lineage for a source that did not contribute is as wrong as missing lineage for one that did.
- `nullable` columns are exempt.

---

## 5. Build records

Two tables in `public_health.quality`: `build_log` and `build_inputs`. **Created by `quality_setup.sql` (section 7), with three views (section 8).** Since v1.2 they are required.

### 5.0 Why these two tables are needed

**The problem they solve.** A silver row now carries only its address and `_silver_build_id` (section 3.3). Four facts were taken off the row: when the bronze rows were loaded, which load wrote them, which file version they came from, and when silver was written. Those facts have to be recorded somewhere, once.

| Table | One row is | What it records | Question it answers |
|---|---|---|---|
| `build_log` | one build of one table, succeeded or failed | Build id, table, start and end time, status, rows written, Delta version written, code version, parameters | Which build produced this table, when, with which code, and did it succeed? |
| `build_inputs` | one input (file, sheet or table) read by one successful build | Bronze table and Delta version read, source key, file, sheet, load id, file checksum, load time, rows read | Exactly which files, loads and file versions was this table built from? |

**What they are used for:**

| Use | How |
|---|---|
| **Row traceability** (replaces four row columns) | A silver row joins to `build_inputs` on build id, source key, file and sheet, and gets its load time, load id and checksum. One row per input per build instead of one value on every silver row |
| **Freshness** (section 6) | Compare the inputs in bronze now with the inputs the latest successful build recorded. Without `build_inputs` there is nothing to compare against |
| **QC identity** (section 8) | A QC result written as `build:<build_id>` points to a `build_log` row. A QC run on a published table finds its build through `target_table_version` |
| **Gold lineage** (section 9) | A gold build records the silver tables and versions it read as `build_inputs` rows. Gold rows need no row-level lineage |
| **Failed builds** | A failed build still gets a `build_log` row with the error. It gets no `build_inputs` rows and is never chosen as the latest build |
| **Reproducing a result** | Input Delta versions plus the code version say what to re-run, as long as the old versions are retained (O4) |

**Why not existing tables:**

| Existing table | Why it is not enough |
|---|---|
| `ingestion_metadata` | Records bronze loads. It does not know which load a silver build consumed, and it can hold several loads of the same file |
| `run_log` | Records QC executions, not builds. A table can be built once and checked many times |
| `table_stats` | Records a table's size and version at QC time, not what went into it |

**Rules:**
- **Append-only.** A build never updates or deletes rows. A rebuilt table gets a new `build_id`; older builds stay as history.
- **One `build_id` per build of one table.** A job that builds three tables writes three `build_log` rows.
- **`build_log`:** one row, written when the build ends, `succeeded` or `failed`.
- **`build_inputs`:** written only after success, one row per file or sheet read (silver) or per silver table read (gold). Reference tables and reviewed repo files are inputs too (`input_kind = table` or `reference`).
- In the poverty pattern, the view `poverty_inputs` already has the content for `build_inputs`.

### 5.0.1 Columns

| `build_log` | Meaning |
|---|---|
| `build_id` | Same value as `_silver_build_id` / `_gold_build_id` on the rows |
| `layer`, `domain`, `target_table` | What was built (full table name) |
| `started_at`, `finished_at` | `finished_at` of a succeeded build is the silver load time |
| `status` | `succeeded` / `failed` |
| `row_count`, `target_table_version` | Rows and Delta version written; null for a failed build |
| `code_version`, `parameters`, `run_id` | Git commit, JSON parameters, job run |
| `error_message` | Why a build failed |

| `build_inputs` | Meaning |
|---|---|
| `build_id`, `target_table` | The build; joins to `build_log` |
| `input_kind` | `bronze_source` / `table` / `reference` |
| `input_table`, `input_table_version` | Table read and its Delta version |
| `source_key`, `source_file`, `source_sheet` | The file or sheet; same values as the silver row's lineage columns |
| `load_batch_id`, `content_checksum`, `ingested_at` | The load and file version consumed |
| `input_rows` | Rows read from this input |
| `reference_version` | Git commit, for reviewed files in the repo |

### 5.0.2 Views

| View | Gives |
|---|---|
| `v_latest_build` | The latest successful build per table. Used by freshness and by gold |
| `v_build_lineage` | `build_inputs` of successful builds with the build time. The join target for silver rows (section 3.3) |
| `v_qc_results_identity` | `qc_results` with `build_id`, `content_checksum` and the checked table version (section 8.1) |
| `v_build_reconciliation` | Per input of each successful build: rows read, rows not loaded by kind, rows loaded (section 7.1) |

### 5.1 Build sequence

| Step | What happens | Written to the quality tables |
|---|---|---|
| 1. Capture candidate inputs | List every file, sheet and table the build is about to read, with load identifiers and Delta versions (a temporary view, as `poverty_inputs` does) | Nothing yet |
| 2. Transform | Build the candidate rows, **reading each input at the version captured in step 1** (`VERSION AS OF <input_table_version>`), so the data validated is the data written | Nothing yet |
| 3. Validate the candidate | Gates, lineage requirements, reconciliation and output validation run on the candidate rows **against the candidate's own captured inputs** | QC results, all with `batch_id = build:<build_id>` (section 8.1) |
| 4. Record success | Write the target table from the validated candidate; read the Delta version that write produced; append one `build_log` row with `status = succeeded` and that `target_table_version`, and the candidate inputs to `build_inputs` | `build_log`, `build_inputs` |
| 5. Downstream | Gold may run | |

- **During steps 1 to 3 the target table still holds the previous build.** Nothing in candidate validation reads or records the target's version.
- **A failed build** appends one `build_log` row with `status = failed` and writes no `build_inputs` rows. The target table is not replaced.
- So `build_inputs` only ever describes successful builds, and `build_log` records both outcomes.
- **Before gold runs:** the silver tables it reads have a `succeeded` latest build, and the gold build records the exact silver Delta versions it consumed (section 9).

---

## 6. Freshness

**Policy:** silver is fresh only if it was built from the complete, current set of bronze inputs. A reload of identical bytes changes the load id without changing business values; silver is still refreshed, so that load identifiers always agree. That is a choice for consistency, not a claim that the data changed.

**Two situations, two checks:**

| Situation | What is compared |
|---|---|
| Checking an **existing published table** (is it still current?) | Current bronze inputs vs `build_inputs` of the latest successful build: the table below |
| Validating a **new build** (section 5.1, step 3) | The candidate's rows vs the candidate's own captured inputs. It is never compared with the previous successful build's inputs |

**Check on an existing table (v1):** verify that silver consumed the expected source files and sheets and the current load identifiers. Any mismatch requires a successful silver refresh.

| Step | Compare | Catches |
|---|---|---|
| 1 | Inputs declared in the table config **vs** files and sheets currently in bronze | A new file or sheet in bronze that silver has never read; a declared input that was never loaded |
| 2 | Inputs in bronze now **vs** `build_inputs` of the latest successful build | An input added or removed since the build |
| 3 | `load_batch_id` and `content_checksum` per input, current **vs** consumed | A reload, or a revised file under the same name |

- Checking only the rows that exist in silver is not enough: a new bronze file that produced no silver rows yet would never be noticed. Steps 1 and 2 close that gap.
- Timestamps identify ingestion executions; checksums identify content. The check uses both.
- A stale silver table fails this check first. Other checks on it are not trusted until it is rebuilt.

---

## 7. Reconciliation

Two checks. One does not replace the other.

### 7.1 Input accounting: `quality.row_disposition`

**Every bronze row a build read is either loaded or has a disposition row saying why it was not.** Only the rows that were not loaded are stored.

| Bronze row | Recorded where |
|---|---|
| Loaded | Not in `row_disposition`. The silver row already carries its bronze row reference (`_source_key`, `_source_file`, `_source_sheet`, `_source_row_num`) |
| Not loaded: `dropped_non_data`, `duplicate_of`, `quarantined` | One row in `row_disposition`, with the reason |
| `merged_into` (it contributed to a silver row built from several bronze rows) | One row in `row_disposition`, with the silver key in `target_key` |

**Why loaded rows are not stored:** they were about 99% of the table (diseases: 117,650 of 118,766 rows per run) and repeated what the silver lineage columns already say. The rows a reviewer needs to see are the ones that did not make it.

| Column | Note |
|---|---|
| `build_id` | The build (`_silver_build_id` on the silver rows) |
| `source_key`, `source_file`, `source_sheet`, `source_row_num` | The bronze row. `source_sheet` is null for CSVs; compare with `<=>` |
| `load_batch_id`, `content_checksum` | Which load and which file version the row reference belongs to. Kept here, unlike on silver rows: this is a log table, and a failed build has dispositions but no `build_inputs` rows |
| `target_table`, `target_key` | The table being built. `target_key` is JSON: the retained bronze row for `duplicate_of`, the silver key for `merged_into` |
| `disposition` | `merged_into` / `duplicate_of` / `quarantined` / `dropped_non_data` |
| `reason` | Why the row was not loaded |
| `recorded_at` | When it was written |

Column names have no leading underscore, the same as `build_inputs`, so the two tables join directly. Created by `quality_setup.sql`.

**Checks, per input file or sheet:**
- Rows read by the build (`build_inputs.input_rows`) = bronze rows of that input (nothing skipped).
- Distinct bronze rows referenced by silver lineage = rows read − rows not loaded. `merged_into` rows count as loaded here, because they contributed.
- Rows loaded is therefore derived: `input_rows` minus the disposition rows. The view `quality.v_build_reconciliation` shows rows read, not loaded by kind, and loaded, per input of each successful build.

- A build that still writes `loaded` rows is not wrong: the view and the checks ignore them. New and revised builds should not write them.
- A row reference without the load and version is ambiguous: row 18 of a file means something else after the file is revised.
- **What is no longer possible:** listing exactly which bronze rows an old build loaded, once its silver table has been replaced. The count per input is still known, and the rows not loaded are still listed.

### 7.2 Output validation

Checked on the silver table itself, after reshaping, joining and de-duplication:
- Rows = the documented expectation (expected list × expected periods, or the rule for that table).
- Key unique and not null.
- Control values match.
- Combining sources did not multiply or lose rows.

Unpivoting makes several silver rows from one bronze row and combining makes one from several, so input counts and output counts are different numbers with different rules. Both are stated per table.

---

## 8. Identity in QC results

`qc_results` keeps its agreed 21 columns. The meaning of each identity column is fixed here.

| Column | Meaning |
|---|---|
| `validation_id` | The QC execution |
| `run_id` | The job run, if any |
| `source_key`, `table_name`, `layer` | What was checked |
| `batch_id` | The data identity the check refers to (table below) |

| Kind of check | `batch_id` value | Also recorded |
|---|---|---|
| Bronze, per source or file | `<source_key>:<content_checksum>` (what bronze QC writes today) | The bronze table version in `table_stats` for the same `validation_id` |
| Silver or gold, **candidate validation** (section 5.1, step 3): every check, table-level or about one input | `build:<build_id>` | For an input-specific check, the input goes in `source_key` (and `column_name` / `detail`); its checksum is in `build_inputs` |
| Silver or gold, on an **already published table**, about the whole table | `build:<build_id>` of the build that wrote the checked version | All contributing loads in `build_inputs` |
| Silver, on an **already published table**, about one input source | `<source_key>:<content_checksum>` | The checked table version in `table_stats`, which gives the build (section 8.1) |

- **A table-level check validates the combined output.** It does not pick one input's identifier (not NHFR's, not HFSRB's). It names the build; `build_inputs` lists every contributing load.
- **Why the table version matters:** identical source bytes can produce different bronze rows after a loader change. `content_checksum` alone cannot show that; the checked table version can.

### 8.1 How a QC execution links to a build

Two cases. They never mix.

| QC runs on | Link to the build | `capture_table_stats` on the target |
|---|---|---|
| A **candidate**, before the target is written (section 5.1, step 3) | `batch_id = build:<build_id>` on every result, including input-specific checks | **Not called.** The target still holds the previous build; recording its version would link the results to the wrong build |
| An **already published table** | `(qc_results.table_name, table_stats.delta_version)` = `(build_log.target_table, build_log.target_table_version)` | Required for every table checked; a result without a checked version cannot be linked |

- **Candidate QC never carries the previous target's version.** The new version exists only after step 4, and is recorded in `build_log.target_table_version` then.
- For a candidate, an input-specific result finds its file version through `build_inputs` on `(build_id, source_key)`.
- The view below takes the build from the `build:` prefix first, and uses the version link only for results without it.

Compatibility view, so the identifiers are visible as columns without changing the table. Created by `quality_setup.sql`:

```sql
CREATE OR REPLACE VIEW public_health.quality.v_qc_results_identity AS
SELECT r.*,
       coalesce(CASE WHEN r.batch_id LIKE 'build:%' THEN substr(r.batch_id, 7) END,
                b.build_id)                                                             AS build_id,
       CASE WHEN r.batch_id NOT LIKE 'build:%' THEN split_part(r.batch_id, ':', 2) END AS content_checksum,
       s.checked_table_version
FROM public_health.quality.qc_results r
LEFT JOIN (
  SELECT validation_id, table_name, max(delta_version) AS checked_table_version
  FROM public_health.quality.table_stats
  GROUP BY validation_id, table_name
) s ON s.validation_id = r.validation_id AND s.table_name = r.table_name
LEFT JOIN public_health.quality.build_log b            -- section 8.1: version link
  ON b.target_table = r.table_name
 AND b.target_table_version = s.checked_table_version
 AND b.status = 'succeeded';
```

---

## 9. Gold lineage

Aggregation changes how lineage is represented. It does not remove traceability.

Recorded **once per gold build**, not in every gold row:
- Input silver tables and the Delta versions consumed (`build_inputs`).
- The build identifier (`build_log.build_id`; gold rows carry `_gold_build_id`).
- The transformation version (Git commit).
- Source dates and scenario parameters, e.g. the stress-test year (`build_log.parameters`).

With retained input versions and the transformation logic, an aggregate can be reproduced. A bridge table listing every contributing silver row per gold row is optional and not planned for v1.

Source keys, as-of dates and silver load times are still useful on gold rows for display, but they do not identify the exact input data on their own.

---

## 10. What each domain declares

| Domain item | Where |
|---|---|
| Lineage column groups and conditional rules | The table's config (section 4) |
| Expected inputs: source keys, files, sheets | The table's config |
| Row classes and disposition reasons | The domain guide |
| Expected output rows and the rule behind them | The domain guide |
| Gates specific to the table | The domain guide |

A domain does not redefine identifiers, naming, the freshness policy or the meaning of `batch_id`.

---

## 11. What needs to change to adopt this

| Item | Change |
|---|---|
| `facilities-silver-plan.md` | `source_key` → `_source_key`; `nhfr_…` / `hfsrb_…` → `_nhfr_…` / `_hfsrb_…`; `batch_id` removed from rows (load id and checksum are in `build_inputs`); keep the MAP; add conditional lineage rules; **trim to the v1.2 column set** (registry: 17 lineage columns → 9); registry table-level QC uses `build:<id>` |
| `socioeconomic-silver-guide.md` and the poverty SQL pattern | Trim to the v1.2 column set: drop the per-side `ingested_at`, `load_batch_id`, `content_checksum` and `_silver_loaded_at` from the output (poverty: 16 → 9). `poverty_inputs` already holds them for `build_inputs` |
| `workforce-silver-plan.md` | Trim to the v1.2 column set (denominator: 16 → 9) |
| `diseases-silver-plan.md` | Done (plan v1.2) |
| Silver builds that write `row_disposition` (v1.3) | Write only the rows that were not loaded. **Done (2026-10-09)** for diseases, facilities, workforce and socioeconomic. Facilities also checks it in a build gate; `workforce_silver_qc.py` S09 uses the derived loaded count |
| Diseases, workforce, geography silver | Follow this contract from the start |
| `quality_setup.sql` | **Done (2026-10-09):** `build_log`, `build_inputs`, `v_latest_build`, `v_build_lineage`, `v_qc_results_identity`. `row_disposition` added the same day |
| Silver QC script (shared) | Read table configs; implement sections 4, 6 and 7 through `DQRun` |
| Bronze tables and loaders | **No change.** Identifiers come from `ingestion_metadata` |
| Bronze QC scripts | No change. They already write `<source_key>:<content_checksum>` |

## 12. Open items for the team

| # | Item |
|---|---|
| O1 | Confirm `build:<build_id>` as the `batch_id` value for table-level checks and all candidate-validation checks, or add a column to `qc_results` instead |
| O2 | Where the silver table configs live: one `config/silver_tables.yaml`, or one file per domain |
| O3 | How the build id is set. The poverty pattern uses a SQL session variable (needs a runtime that supports `DECLARE VARIABLE`); in a job, pass the job run id |
| O4 | How long bronze table versions and landing files are retained, since reproducing an old result depends on it |
| O5 | The API-ingested geography source has no file or row number. Its lineage group needs endpoint and record key in place of file, sheet and row |

## 13. Changes

### v1.3 (2026-10-09): `row_disposition` holds exceptions only

| Item | Change |
|---|---|
| `row_disposition` | Stores only bronze rows that were not loaded. `loaded` rows are no longer written (7.1) |
| Loaded count | Derived: `build_inputs.input_rows` minus the disposition rows. New view `quality.v_build_reconciliation` |
| Reconciliation check | Rows read = bronze rows; rows referenced by silver = rows read − rows not loaded |
| Schema | No table or column change. One view added; column comments updated |
| Size | Diseases: 118,766 rows per run → 1,116 |
| Applied | Diseases, facilities (01–03), workforce (02–04 and `workforce_silver_qc.py` S09), socioeconomic (01–04). Facilities: 8,848 → 1,372 rows per run |

### v1.2 (2026-10-09): fewer lineage columns on silver rows

| Item | Change |
|---|---|
| Removed from silver rows | `_ingested_at`, `_load_batch_id`, `_content_checksum`, `_silver_loaded_at` (and their `_<side>_` forms) |
| Where they are now | `build_inputs.ingested_at / load_batch_id / content_checksum` and `build_log.finished_at`, joined on `_silver_build_id` + source key, file and sheet (3.3) |
| Single-source row | 11 → 7 columns (6 without `_metric_source_columns`) |
| Combined row | Per side: sheet and row number, plus key, file and as-of date only when the sides differ (3.4). Poverty and workforce denominator 16 → 9 |
| Lookup in `ingestion_metadata` | Done once per input when the build lists its inputs, not joined onto rows (3.5) |
| `build_log`, `build_inputs` | Now required, and created by `quality_setup.sql` with three views. Why they are needed: section 5.0 |
| Unchanged | Identifier meanings, bronze, `row_disposition`, freshness, reconciliation, QC identity, gold lineage |
| Why | Fewer columns to explain and maintain; the removed values repeated one fact per file on every row |

### v1.1 (2026-10-09)

Four clarifications from the diseases silver reviews. No schema changes.

| # | Clarification | Section |
|---|---|---|
| 1 | Build sequence written out: capture candidate inputs, transform, validate the candidate against its own inputs, record success, then gold. A failed build logs `failed` and writes no inputs. Freshness on an existing table is a separate check from validating a new build | 5.1, 6 |
| 2 | In a combined row, each metric identifies its lineage group as well as its bronze column, through `metric_groups` in the table config | 3.6 |
| 3 | A QC execution on an already published table links to its build through the checked table version | 8.1 |
| 4 | Candidate validation: every QC result uses `build:<build_id>`, input-specific checks included, and never records the previous target's version. The transform reads inputs at the captured versions. The new target version is recorded in `build_log` after the write | 5.1, 8, 8.1 |

**Not contract changes** (they are domain or implementation items):
- The condition on a lineage group is the domain's to get right. The principle stays: a group is required when that source contributed, not when a value happens to be non-null. A null measurement keeps the lineage of the row it came from.
- Recording table versions and code versions is already in sections 5 and 9; it needs implementing, not redefining.
- Retention of old versions is open item O4.

---

## Appendix A. Why each lineage column is needed

Added 2026-10-09, updated for v1.2. Explanation only; it adds no rule. The rules are in sections 2 to 9. Examples use the diseases domain; the columns are the same in every domain.

### A.1 What lineage is for

Lineage lets us answer five questions about any number on the dashboard:

| # | Question | Example |
|---|---|---|
| Q1 | Where did this value come from? | Which file, sheet, row and column holds the 413,960 dengue cases of 2024? |
| Q2 | Which version of the file was it? | The provider re-issued the file under the same name. Did silver use the old or the new one? |
| Q3 | Which load put it in bronze? | The file was loaded on 4 October and again on 6 October. Which load do the rows belong to? |
| Q4 | Which build produced the silver table? | A check failed. Was it on today's table or last week's? |
| Q5 | Is silver still up to date? | Bronze was reloaded. Has silver been rebuilt since? |

`_source_file` and `_ingested_at` alone answer Q1 partly and Q3 partly. The other identifiers exist because of Q2, Q4 and Q5.

**Seven of them are columns on the silver row. Four are stored once per build** (`build_inputs`, `build_log`) and reached through `_silver_build_id`, because their value is the same for every row of a file (A.5).

### A.2 Summary

| Identifier | In bronze | On the silver row | Answers | Without it |
|---|---|---|---|---|
| `_source_key` | yes | yes | Q1: which source | Rows of two sources in one table cannot be told apart |
| `_source_file` | yes | yes | Q1: which file | Cannot go back to the file |
| `_source_sheet` | yes | yes | Q1: which sheet | Row 18 of a workbook is ambiguous |
| `_source_row_num` | yes | yes | Q1: which row | Cannot point to the exact row; double loads go unnoticed |
| `_metric_source_columns` | no | yes | Q1: which column | After unpivoting, the original column is lost |
| `_as_of_date` | yes | yes | The source's reference date | The dashboard cannot say how current the data is |
| `_ingested_at` | yes | no: `build_inputs.ingested_at` | Q3: when the row was loaded | Cannot find the load |
| `_load_batch_id` | no | no: `build_inputs.load_batch_id` | Q3: which load | Two loads of one file cannot be separated reliably |
| `_content_checksum` | no | no: `build_inputs.content_checksum` | Q2: which file version | A revised file under the same name goes unnoticed |
| `_silver_build_id` | no | yes | Q4: which build | QC results and row dispositions cannot be tied to a table state |
| `_silver_loaded_at` | no | no: `build_log.finished_at` | Q4, Q5: when silver was written | Cannot tell when the table was last refreshed |
| `_rescued_data` | yes | no | Values that did not fit the header | Extra cells in a row would be dropped silently |

### A.3 Each column in detail

#### A.3.1 `_source_key`

- **What it is:** the source's key in the YAML (`doh_foi_dengue`, `upnoah`, `hdx_dengue`, `ihme_gbd`).
- **Why it is needed:**
  - Silver is built by domain, so one silver table holds several sources. `diseases_metric_silver` has eight. Without the key, a dengue row from DOH and one from UP NOAH look the same.
  - It is part of the silver key: `(disease_key, area_key, period_grain, period_key, measure, _source_key)`. Two sources can report the same disease, area and period, and both rows must be kept.
  - Gold chooses a preferred source per question through `source_priority`. It needs the key to choose.
  - QC results are reported per source (`qc_results.source_key`).
- **Note:** the file name is not a substitute. One source can have several files (PSA monthly deaths has five), and one key can cover two bronze tables (`doh_fhsis` covers TB and morbidity).

#### A.3.2 `_source_file`

- **What it is:** the file's path relative to the landing root, e.g. `…/doh_foi_dengue_region_monthly_2021_2025.csv`.
- **Why it is needed:**
  - It is the first step of any trace back to the raw data.
  - Per-file checks depend on it: expected row counts (B03), control totals and reconciliation are all stated per file.
  - It separates files that overlap. The HDX 2021 file repeats 252 rows of the 2016-2021 file; only the file name tells the two copies apart.
- **Why relative, not absolute:** the landing root can move (another workspace or volume) without changing the value.

#### A.3.3 `_source_sheet`

- **What it is:** the sheet name for Excel sources (`Regional Data`, `CNR`, `Sheet1`). Null for CSV.
- **Why it is needed:**
  - A workbook can hold several sheets with different content. Row numbers restart on each sheet, so file plus row number is not unique without the sheet.
  - Sheets of one workbook can be loaded at different times, so each sheet has its own load record.
- **Note:** because it is null for CSV, joins and comparisons use null-safe equality (`<=>`). A plain `=` would silently drop every CSV row.

#### A.3.4 `_source_row_num`

- **What it is:** the row's position in the file or sheet, as the loader read it.
- **Why it is needed:**
  - It completes the address of a bronze row: `(_source_key, _source_file, _source_sheet, _source_row_num)`.
  - It detects double loads. Bronze QC B06 checks that the row number is unique per file and sheet.
  - It is the only stable key for tables with no natural key. `diseases_hospital_encounters_silver` drops `EncounterID` for privacy, so the lineage columns are its key.
  - Row-level fixes point to it. The FHSIS TB 2024 `Philippines` row carries NCR's PSGC code; the override in the area map targets that one row.
  - Reconciliation counts distinct bronze rows through it.

#### A.3.5 `_metric_source_columns`

- **What it is:** a MAP from silver column to the bronze column it came from. Examples: `{value: 'Cases'}` (DOH dengue), `{value: 'july'}` (PSA monthly), `{value: 'val', value_lower: 'lower', value_upper: 'upper'}` (IHME).
- **Why it is needed:**
  - Silver unpivots. One PSA monthly bronze row becomes twelve silver rows, one per month. File, sheet and row number are identical on all twelve. Only the MAP says which of them came from the `july` column.
  - Silver renames. The silver column is always `value`; the MAP keeps the original header.
  - With the row address, it points to one cell of the source file. That is the full answer to Q1.
- **Why a MAP and not one text column:** some rows take several values from several columns (IHME: value, lower, upper).

#### A.3.6 `_as_of_date`

- **What it is:** the reference date of the source, set in the YAML: the date the data was published or extracted.
- **Why it is needed:**
  - It is the date the dashboard shows as "data as of". `_ingested_at` cannot be used for that: it says when we loaded the file, not how current the content is.
  - It supports partial-period flags. The DOH dengue file covers 2025 only up to its extraction date.
  - When a source is re-issued, it shows which release a row belongs to in a way a reader understands.
- **Note:** it is a business date kept in lineage because it describes the source, not the observation.

#### A.3.7 `_ingested_at`

- **What it is:** the timestamp of the bronze load that wrote the row. All rows of one file or sheet in one load share one value.
- **Why it is needed:**
  - It says when the data entered the platform.
  - It is the join key to `ingestion_metadata` (`retrieved_at = _ingested_at`), which is how a build finds the load id and checksum of each input without changing bronze.
- **Where it is kept for silver:** `build_inputs.ingested_at`, one value per input per build. Not a silver column.
  - It shows a mismatch between table and log. Bronze QC B13 found seven files whose rows were loaded on 2026-10-06 while the latest log row was from 2026-10-04.
- **Why it is not enough on its own:** a timestamp says when, not what. Two loads at different times can hold the same bytes, and a timestamp cannot show that the file changed.

#### A.3.8 `_load_batch_id`

- **What it is:** the id of the ingestion execution that wrote the bronze rows (`ingestion_metadata.batch_id`).
- **Why it is needed:**
  - It names the load directly. A timestamp is compared for equality only by convention; an id is made for it.
  - It links a silver row to everything the loader recorded for that load: status, row count, file size, error message.
  - The same file bytes can be processed differently after a loader change. The checksum would be identical; only the load id shows that the rows came from a different execution.
  - Freshness uses it: if the current load id of an input differs from the one silver consumed, silver must be rebuilt.
- **Where it is kept for silver:** `build_inputs.load_batch_id`. Not a silver column.
- **Difference from `_ingested_at`:** same event, but the id is the identifier and the timestamp is a property of it.

#### A.3.9 `_content_checksum`

- **What it is:** the sha256 of the source file's bytes (`ingestion_metadata.content_checksum`).
- **Why it is needed:**
  - It is the only column that identifies the content itself. Name, path and date can all stay the same while the content changes.
  - It detects a silent revision: a provider replaces a file under the same name, and the checksum differs.
  - It proves the opposite too: a reload with the same checksum did not change any value.
  - A row reference is only meaningful with it. "Row 18 of the file" is a different row after the file is revised.
  - QC results for one input are identified by `<source_key>:<content_checksum>`, so a result says exactly which file version it checked.
- **Where it is kept for silver:** `build_inputs.content_checksum`. Not a silver column.
- **Limit:** it identifies old content but does not bring it back. Reproducing an old result needs the retained file or bronze table version.

#### A.3.10 `_silver_build_id`

- **What it is:** one id per build of a silver table. Every row written by that build carries it.
- **Why it is needed:**
  - It ties the rows to their build record: inputs consumed (`build_inputs`), code version, parameters, status (`build_log`).
  - **It is the bridge to the four facts that are not on the row:** load time, load id, checksum and build time.
  - It ties QC to the data. Checks run on the candidate before the table is written and are recorded as `build:<build_id>`; without the id there would be nothing to attach them to.
  - Row dispositions are recorded per build, so "what happened to bronze row 40 in this build" has an answer.
  - Gold records which silver build it read.
- **Why not a build timestamp instead:** a timestamp is not a safe join key, and a failed build has an id and a log row but no written rows.

#### A.3.11 `_silver_loaded_at` (stored as `build_log.finished_at`)

- **What it is:** the timestamp at which the build wrote the table. One value per build.
- **Why it is needed:**
  - It answers "when was this table last refreshed" by looking at the table alone, without the log.
  - It is readable by people; a build id is not.
  - The dashboard's data readiness page can show it.
- **Where it is kept:** `build_log.finished_at`, one value per build. Not a silver column; `SELECT max(finished_at) FROM build_log WHERE target_table = ... AND status = 'succeeded'` answers "last refreshed".

#### A.3.12 `_rescued_data` (bronze only)

- **What it is:** values of a row that did not fit the header, kept as text.
- **Why it is needed in bronze:** bronze must keep everything the file holds. A row wider than its header would otherwise lose cells without a trace. Bronze QC B09 warns when it is filled.
- **Why it is not in silver:** B09 confirms it is empty. If a source ever has rescued values, silver handles them as real columns.

### A.4 Identifiers that look redundant but are not

| Pair | Why both are kept |
|---|---|
| `_ingested_at` and `_load_batch_id` | Both describe the load. The timestamp is what bronze has, and it is the bridge to the log. The id is the proper identifier once the bridge is crossed |
| `_load_batch_id` and `_content_checksum` | Load and content are different things. Same bytes can be loaded twice (two load ids, one checksum). A revised file under the same name is one path with two checksums |
| `_source_file` and `_content_checksum` | The name says where the file is; the checksum says what was in it at the time |
| `_as_of_date` and `_ingested_at` | One is the date of the data, the other the date of our load. A 2023 file loaded today is still 2023 data |
| `_silver_build_id` and `_silver_loaded_at` | The id is for joining to logs and QC. The timestamp (in `build_log`) is for people |

Four cases that show the difference:

| Case | `_source_file` | `_ingested_at` | `_load_batch_id` | `_content_checksum` |
|---|---|---|---|---|
| Same file reloaded, nothing changed | same | new | new | same |
| Provider revised the file, same name | same | new | new | **different** |
| File renamed, same content | **different** | new | new | same |
| Loader code changed, same file | same | new | new | same (the bronze table version shows the difference) |

With `_source_file` and `_ingested_at` only, the first two cases look identical.

### A.5 Why four identifiers are stored once per build, not on every row

- `_ingested_at`, `_load_batch_id` and `_content_checksum` describe a **load of a file or sheet**. Every row of that file has the same value. `_silver_loaded_at` describes a **build**; every row of the table has the same value.
- Repeating them on each row adds four columns and no information. Storing them once per input per build (`build_inputs`) and once per build (`build_log`) keeps the same facts.
- The silver row keeps what is different per row (its address: key, file, sheet, row number) and `_silver_build_id`, which leads to the rest with one join (section 3.3).
- **Where the values come from:** bronze rows have `_ingested_at` but not the load id or checksum; the loader writes those to `ingestion_metadata` only. Adding them to bronze would mean changing every bronze table, which the team decided against (2026-10-08). So each build looks them up once per input (section 3.5): matched on source, path, sheet, `retrieved_at = _ingested_at` and `status = 'processed'`.
- **Exactly one match is required.** Zero matches means the log row is missing; two means duplicate metadata. Either stops the build. This is why the B13 warnings must be cleared before the first silver build.
- **Cost of this choice:** tracing a row to its load or file version needs the join, and the build tables must exist and be kept.

### A.6 Supporting tables, briefly

| Table | One row is | Why it exists |
|---|---|---|
| `ingestion_metadata` | one load of one file or sheet | Source of `_load_batch_id` and `_content_checksum`; record of what the loader did |
| `build_log` | one build of one silver or gold table | Status, row count, table version written, code version. Records failed builds too |
| `build_inputs` | one input consumed by one successful build | The exact files, sheets, loads and versions a table was built from. Basis of the freshness check |
| `row_disposition` | one bronze row that a build read but did not load | Says why: `duplicate_of`, `quarantined`, `dropped_non_data` (or `merged_into`). With `build_inputs.input_rows` it proves no row was lost or counted twice |

### A.7 Worked example: tracing one dashboard number

Dashboard value: registered deaths, one cause, Philippines, July 2024.

| Step | Use | Result |
|---|---|---|
| 1 | The silver row's `_source_key` | `psa_deaths_national_monthly` |
| 2 | `_source_file`, `_source_sheet` | `…/psa_deaths_national_monthly_2024.csv`, no sheet |
| 3 | `_source_row_num` | The cause's row in that file |
| 4 | `_metric_source_columns` | `{value: 'july'}`: the July column of that row |
| 5 | `_silver_build_id` → `build_inputs.content_checksum` | Confirms the file in landing today is the same version silver read |
| 6 | `build_inputs.load_batch_id` | The load record in `ingestion_metadata`: when, how many rows, status |
| 7 | `_silver_build_id` → `build_log` | The build, its inputs in `build_inputs`, and the QC results recorded as `build:<id>` |
| 8 | `_as_of_date` | The date shown beside the chart |

Steps 1 to 4 find the cell. Steps 5 to 7 show that the cell we find today is the one that was used, and that it was checked.

### A.8 Restricted sources

- Lineage columns hold addresses (file, sheet, row), never patient or licensed values.
- For `diseases_hospital_encounters_silver`, QC outputs and row dispositions hold counts and row references only.
- `_source_file` of a restricted source shows a path under `restricted/`. Access to the silver table stays limited.


---

## History of the page

| Date | Change |
|---|---|
| 2026-10-07 – 10-09 | v1.0 to v1.3 written as `lineage-qc-contract.md` (drafts for the team) |
| 2026-10-20 | Moved to `docs/04-pipeline/quality/lineage-and-quality-contract.md`; version and status put inside the page; status set to adopted, with what is not built yet and the state of O1–O5 |