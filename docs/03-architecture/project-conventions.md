# Project conventions

The naming, layout and coding rules every file in this repository follows. Follow them for new work; fix old work when you touch it.

Status date: 2026-10-20.

---

## 1. Repository layout

```
config/
├── sources_<domain>.yaml          one entry per source
└── reference/<domain>/*.csv       reviewed reference maps (generated, never hand-edited)
builders/silver/build_*.py         generate the reference CSVs
resources/*.yml                    job definitions
src/
├── 00_setup/                      schemas (incl. gold), ingestion_metadata.sql, quality_setup.sql, migrations
├── 01_ingestion/                  API landing jobs (not in the pipeline job)
├── 02_bronze/                     <domain>_bronze.py, run_bronze.py, geography/admin loaders
├── 03_silver/<domain>/            <domain>_silver_NN_<content>.sql (+ .py where needed)
├── 04_gold/
│   ├── dimension/ fact/ mart/     gold_NN_<object>.sql
└── 05_quality/
    ├── dq_utils.py
    ├── bronze/ silver/ gold/      <domain>_<layer>_qc.py, bronze_gate.py
docs/                              this documentation
```

Every `src/` layer folder has a `README.md` with the full reference for that layer. `docs/` holds the overview and cross-cutting pages.

## 2. Names

### Schemas and tables

| Object | Pattern | Example |
|---|---|---|
| Catalog | `public_health` | — |
| Schemas | `bronze`, `silver`, `gold`, `quality` | — |
| Bronze table | `<domain>_<source>_<content>_bronze` | `diseases_upnoah_dengue_regional_bronze` |
| Silver table | `<domain>_<content>_silver` | `diseases_metric_silver` |
| Silver staging | `<table>__classified`, `__inputs`, `__candidate`, `__gates` | `diseases_metric_silver__candidate` |
| Gold dimension | `dim_<entity>` | `dim_geography` |
| Gold fact | `fact_<subject>` | `fact_disease_metric` |
| Gold mart | `mart_<subject>` (view) | `mart_area_priority` |
| Gold default view | `v_<fact>_<selection>` | `v_disease_metric_totals` |
| Gold reference | `ref_<subject>` (outside the model) | `ref_osm_healthsite_point` |
| Quality views | `v_<subject>` | `v_open_issues` |

- Put the domain first in bronze and silver names (D-09). It makes tables easy to find and group.
- Use `fact_` and `dim_` in gold only (D-07).
- `fact_area_access` is a view in `mart/` despite its name. The dashboard reads it, so the name stays.

### Files

| File | Pattern |
|---|---|
| Bronze loader | `src/02_bronze/<domain>_bronze.py` |
| Silver build | `src/03_silver/<domain>/<domain>_silver_NN_<content>.sql`; `00` = reference load; `00a`, `04a` = helper steps |
| Gold build | `src/04_gold/<folder>/gold_NN_<object>.sql`; one number sequence across folders = run order |
| QC script | `src/05_quality/<layer>/<domain>_<layer>_qc.py` |
| Config | `config/sources_<domain>.yaml` |
| Reference CSV | `config/reference/<domain>/<domain>_<map>.csv` |

Add new files at the end of a sequence (25, 26…). Do not renumber existing files.

### Landing files

| Kind | Pattern |
|---|---|
| Folder | `<landing_root>/<domain>/<source>/[<geo>_<grain>/]` — one folder = one layout = one bronze table |
| Restricted folder | `<landing_root>/<domain>/restricted/` |
| Period table | `{source}_{content}_{geo}_{grain}_{years}.{ext}` |
| Snapshot | `{source}_{content}_{geo}_asof_{yyyymmdd}.{ext}` |

Never edit a landed file. A newer release is a new file in the same folder.

### Columns

| Kind | Rule | Example |
|---|---|---|
| Lineage | Leading underscore | `_source_key`, `_silver_build_id` |
| Surrogate key | `<entity>_key`, BIGINT `xxhash64` of the natural key | `area_key` |
| Natural code | `<entity>_code` | `area_code`, `disease_code` |
| Flags | `is_` / `has_` | `is_complete_year`, `has_hospital_recorded` |
| Status | `<thing>_status` | `value_status` |
| Reason | `exclusion_reason`, `mapping_outcome` | — |
| Units in the name | `_pct`, `_php`, `_km`, `_sqkm` | `bor_weighted_pct` |

## 3. Code style

| Rule | Why |
|---|---|
| Plain `.py` and `.sql` files, not notebooks | Diffable in pull requests; runnable outside Databricks |
| Header comment in every file: purpose, inputs, outputs, how to run, checks | The next person reads the file without the docs |
| SQL first; Python for file loading, reference builders, geometry and QC (D-05) | The team knows SQL best |
| Parameters as command-line arguments; notebook widgets only as a fallback | Same script runs in a job, a notebook or a shell |
| No values hard-coded per dataset; sources live in YAML (D-12) | Adding data is a config change |
| Silver casts with `try_cast` and keeps a status; gold uses `CAST` with ANSI mode on | A bad value is visible in silver and stops gold |
| Timestamps in UTC, timezone-aware (D-54) | Correct on any driver timezone |
| Every build: write candidate → gates → publish → `build_log` + `build_inputs` | A failed build leaves the published table untouched |

### Numbers in code (review rule, 2026-10-19)

| Kind of number | Example | Rule |
|---|---|---|
| Expected value for one file | `expected_rows`, control totals | Keep. Name the file or published source next to it |
| Observation about the data | "94 of 127,945 values" | Date it ("checked 2026-10-19") or point to the live number in `qc_results` |
| Number the logic depends on | A code list, a count of named areas | Move to config or derive at run time. Add a check that fails if the assumption breaks |

## 4. Configuration

- One YAML entry per source: identity, location, reading settings, `header_check`, `required_columns`, target table, `sharing`, `qc` block, notes.
- `sharing` is one of `open`, `public`, `restricted`.
- `qc.skip_checks` and `qc.severity` accept known codes only, never `*00`, and only WARN or FAIL (D-53). Explain accepted WARNs in the entry notes.
- Reference CSVs are generated by `builders/`. A manual decision goes into the builder's decision table with reviewer and date. Never edit a CSV by hand.

## 5. Quality codes and statuses

| Prefix | Layer | Range |
|---|---|---|
| `B` | Bronze file domains | B00–B16 |
| `GB` | Bronze geography (PSGC) | GB00–GB13 |
| `HB` | Bronze admin boundaries | HB00–HB14 |
| `S` | Silver shared and per domain | S00–S99 |
| `GS`, `AS` | Silver QC: geography, boundaries | GS01–GS08; AS01–AS09 and ASB05 |
| `SG`, `AB` | Silver build checks: geography, boundaries | SG01–SG07; AB01–AB07 |
| `G` | Gold | G00–G13 |

- `*00` always means "the QC script crashed".
- A code has one meaning and is never reused.
- QC statuses: `PASS`, `WARN`, `FAIL`; run status adds `ERROR`.
- Gate states: `PASS`, `WARN`, `FAIL`, `CRASHED`, `STALE`, `NOT_CHECKED`.
- `qc_results.batch_id`: `<source_key>:<content_checksum>` for bronze; `build:<build_id>` for table-level silver and gold checks.

## 6. Git and pull requests

| Item | Convention |
|---|---|
| Integration branch | `dev` (Asset Bundle target `dev`) |
| Work branches | `feature/<topic>` (for example `feature/quality-tables-setup`) |
| Pull requests | Into `dev`; at least one reviewer; CI must pass |
| Commit messages | Imperative, say what changed: "Add preload gate per domain" |
| Docs | Update the page in the same pull request as the code |
| Never commit | Restricted landing files, FOI request or release documents, tokens |

Confirm the `main` branch rule and the review count with the team, then update this table.

## 7. Decision and issue IDs

| ID | Use | Where |
|---|---|---|
| `D-NN` | A decision made | Decision log |
| `O-NN` | An open decision | Decision log |
| `F-NN` | A finding in the data (silver) | Domain silver pages |
| Incident N | A pipeline incident | Runbook |

Never rewrite an old decision. Add a new one that replaces it.

## 8. Documentation style

- Version a page inside the page, never in its file name (for example the [lineage and quality contract](../04-pipeline/quality/lineage-and-quality-contract.md)).
- Write for the next data person, who rebuilds or queries the pipeline without us.
- Short sentences, active voice. Imperatives for steps; plain statements for facts.
- Put the reason next to the rule.
- Tables for lists of the same kind of thing; prose for reasoning.
- Name files, tables and columns exactly, in `code`.
- Date every result. Never write "run on Databricks" until it has run there.
- Describe the concept first, the Databricks implementation second.
- End every page with a dated history table.

## 9. History of updates

| Date | Change |
|---|---|
| 2026-10-19 | Page written, with the rule for numbers in code (rule 2a) |
| 2026-10-20 | Silver QC codes GS / AS and build checks SG / AB separated; no gold setup file; version a page inside the page |