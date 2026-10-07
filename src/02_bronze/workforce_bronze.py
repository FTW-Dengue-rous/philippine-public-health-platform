# =============================================================================
# Bronze ingestion for the workforce domain (config-driven).
#
# What it does
#   Reads config/sources_workforce.yaml and loads each source file (CSV or Excel) into
#   its bronze Delta table. Values are kept as they are in the file, with the
#   extraction conventions listed below.
#
# Extraction conventions (documented, applied to every source)
#   - Every data column is loaded as STRING. Types are cast in silver.
#   - Empty and whitespace-only cells become null. Fully empty rows are skipped
#     (the skipped count is printed per file).
#   - Excel dates become ISO text (2017-11-26T17:23:00); whole-number floats lose
#     the ".0" (2016.0 -> "2016"). Excel formulas are read as their cached results
#     (openpyxl data_only=True); they are not recalculated.
#   - Title and header rows before the data are skipped as configured
#     (skip_rows / data_start_row). Footer lines after the data are loaded.
#   - Cells beyond the last named column go to _rescued_data with their position.
#   - The landing file is never changed; it stays the original record.
#
# Column names
#   From the file header (header_mode: single), from the YAML (names), or col_0,
#   col_1, ... (none). Characters Delta does not allow, and ".", become "_".
#   Names are made unique case-insensitively (A, A, A_2 -> A, A_2, A_2_2).
#
# Lineage columns on every row
#   _rescued_data, _source_key, _source_file, _source_sheet, _source_row_num,
#   _as_of_date, _ingested_at
#
# Safety checks, in order, per source
#   1. header_check (YAML): the physical header/title rows of each file or sheet must
#      contain the expected text at the expected positions. Runs on the raw rows,
#      before any YAML column names are applied. Catches shifted or inserted columns.
#   2. required_columns (YAML, header_mode single): named columns must exist.
#   3. Each file must give at least one data row.
#   Any failure stops that source before anything is written.
#   4. Write: rows of the same source and files are replaced in ONE transaction
#      (Delta replaceWhere). Other files and sources are untouched.
#   5. Reconciliation: rows in the table for each file are counted after the write
#      and must equal the rows read.
#   6. Audit: one ingestion_metadata row per file/sheet (team schema, unchanged).
#      If the log cannot be written, the data stays committed but the run fails.
#   Every run reloads the selected sources; there is no skip of unchanged files.
#
# How to run
#   python workforce_bronze.py                                  # all enabled sources
#   python workforce_bronze.py --source_keys psmo_oncologists,psa_gov_practitioners
#   python workforce_bronze.py --show_headers 8 --source_keys psmo_oncologists   # print rows, write nothing
#   python workforce_bronze.py --config_path /Workspace/.../sources_workforce.yaml
#   The YAML is found automatically if it sits next to this file or in a config/
#   folder beside or above it.
#
# Requires: pyyaml, openpyxl
# =============================================================================

import argparse
import csv
import functools
import glob
import hashlib
import json
import os
import re
import uuid
from datetime import UTC, date, datetime

import yaml
from pyspark.sql import SparkSession
from pyspark.sql.types import (
    DateType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)

spark = SparkSession.builder.getOrCreate()

LOADER_VERSION = "2026-10-06.2"  # printed at start; bump when parsing behaviour changes
LINEAGE_COLS = [
    "_rescued_data",
    "_source_key",
    "_source_file",
    "_source_sheet",
    "_source_row_num",
    "_as_of_date",
    "_ingested_at",
]
RUN_ID = str(uuid.uuid4())  # one id per run, written to the metadata log
INGESTED_AT = datetime.now(UTC).replace(tzinfo=None)  # same timestamp for every row of this run

CONFIG_NAMES = ("sources_workforce.yaml",)  # config file for this domain
DOMAIN = "workforce"  # this file only loads entries of this domain


def find_config(explicit=None):
    # Locate the YAML. Use --config_path if given; otherwise look next to this file,
    # in the working directory, and in config/ folders up to five levels above them.
    if explicit:
        if not os.path.isfile(explicit):
            raise FileNotFoundError(f"--config_path does not exist: {explicit}")
        return os.path.abspath(explicit)
    starts = [os.getcwd()]
    try:
        starts.insert(0, os.path.dirname(os.path.abspath(__file__)))
    except NameError:  # __file__ is not set in some runners
        pass
    searched = []
    for start in starts:
        folder = start
        for _ in range(6):
            for sub in ("", "config", "configs", "conf"):
                searched.append(os.path.join(folder, sub))
                for name in CONFIG_NAMES:
                    candidate = os.path.join(folder, sub, name)
                    if os.path.isfile(candidate):
                        return candidate
            parent = os.path.dirname(folder)
            if parent == folder:
                break
            folder = parent
    raise FileNotFoundError(
        f"None of {CONFIG_NAMES} found. Pass --config_path with its full path. Looked in:\n  "
        + "\n  ".join(dict.fromkeys(searched))
    )


# -----------------------------------------------------------------------------
# Config helpers
# -----------------------------------------------------------------------------


def load_config(path):
    # Read the YAML and merge `defaults` into every source entry.
    with open(path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    for required in ("landing_root", "sources"):
        if required not in cfg:
            raise KeyError(f"'{required}' is missing at the top level of {path}")
    defaults = cfg.get("defaults", {})
    sources = {}
    for key, entry in cfg["sources"].items():
        merged = {**defaults, **entry}
        merged["source_key"] = entry.get("source_key_override", key)
        merged["entry_name"] = key
        sources[key] = merged
    return cfg, sources


def loadable(entry):
    # True for enabled file sources of this domain (entries with `path` and `bronze_table`).
    return (
        entry.get("domain") == DOMAIN
        and bool(entry.get("path"))
        and bool(entry.get("bronze_table"))
        and entry.get("enabled", True)
    )


# Settings a single file in `files:` may override.
# header_mode and columns are per file too: one source can hold files (or sheets) whose
# layout changes by year. The bronze table then has the union of their columns.
FILE_LEVEL_KEYS = (
    "format",
    "sheet",
    "skip_rows",
    "data_start_row",
    "encoding",
    "encoding_errors",
    "delimiter",
    "as_of_date",
    "header_mode",
    "columns",
    "required_columns",
    "header_check",
)


def resolve_files(cfg, entry):
    # Return one dict per file: abs path, relative path and the settings to read it with.
    # A file listed as a dict in `files:` can override the entry settings (sheet, data_start_row, ...).
    root = cfg["landing_root"]
    items = []
    if entry.get("files"):
        for item in entry["files"]:
            item = item if isinstance(item, dict) else {"name": item}
            items.append((os.path.join(entry["path"], item["name"]), item))
    else:
        for abs_path in sorted(glob.glob(os.path.join(root, entry["path"]))):
            items.append((os.path.relpath(abs_path, root), {}))
    if not items:
        raise FileNotFoundError(
            f"[{entry['entry_name']}] nothing matches {os.path.join(root, entry['path'])}"
        )

    out = []
    for rel, item in items:
        settings = {**entry, **{k: item[k] for k in FILE_LEVEL_KEYS if k in item}}
        if "format" not in item and "format" not in entry:
            settings["format"] = os.path.splitext(rel)[1].lstrip(".").lower()
        elif "format" not in item and entry.get("files"):
            ext = os.path.splitext(rel)[1].lstrip(".").lower()  # mixed csv/xlsx in one entry
            settings["format"] = ext or entry["format"]
        abs_path = os.path.join(root, rel)
        if not os.path.exists(abs_path):
            raise FileNotFoundError(f"[{entry['entry_name']}] file not found: {abs_path}")
        if not isinstance(settings.get("as_of_date"), date):
            raise ValueError(f"[{entry['entry_name']}] as_of_date missing or not a date for {rel}")
        out.append({"abs": abs_path, "rel": rel, "settings": settings})
    return out


# -----------------------------------------------------------------------------
# File readers (return raw rows as lists of strings)
# -----------------------------------------------------------------------------


def _require(package):
    import importlib

    try:
        return importlib.import_module(package)
    except ModuleNotFoundError:
        import subprocess
        import sys

        print(f"  installing {package} (not found on this cluster)")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", package])
        importlib.invalidate_caches()
        return importlib.import_module(package)


def _to_str(v):
    # Turn any cell value into a string; empty cells become None.
    if v is None:
        return None
    if isinstance(v, (datetime, date)):
        return v.isoformat()
    if isinstance(v, float) and v.is_integer():
        return str(int(v))  # Excel stores whole numbers as floats: 2016.0 -> "2016"
    s = str(v)
    return s if s.strip() != "" else None


def read_csv_rows(path, entry):
    # Read a CSV into a list of rows. Decoding is strict by default: a byte that does not
    # fit the encoding stops the source with a clear error. Set encoding_errors: replace
    # on an entry to load anyway; replaced bytes (U+FFFD) are then counted and reported.
    encoding = entry.get("encoding", "utf-8")
    if encoding.lower().replace("-", "") == "utf8":
        encoding = "utf-8-sig"  # also removes a BOM if present
    errors = entry.get("encoding_errors", "strict")
    try:
        with open(path, encoding=encoding, errors=errors, newline="") as f:
            rows = [
                [_to_str(c) for c in row]
                for row in csv.reader(f, delimiter=entry.get("delimiter", ","))
            ]
    except UnicodeDecodeError as e:
        raise ValueError(
            f"[{entry['entry_name']}] {os.path.basename(path)} is not valid {encoding} "
            f"(byte {e.start}: {e.object[e.start : e.start + 8]!r}). Fix encoding in the YAML, "
            f"or set encoding_errors: replace to load with replacement characters."
        ) from None
    replaced = sum(c.count("\ufffd") for row in rows for c in row if c)
    return rows, replaced


def read_xlsx_rows(path, entry):
    # Read one sheet of an Excel workbook into a list of rows.
    openpyxl = _require("openpyxl")
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheet = entry.get("sheet")
    if sheet is None:
        sheet = wb.sheetnames[0]
    if sheet not in wb.sheetnames:
        raise ValueError(
            f"[{entry['entry_name']}] sheet '{sheet}' not found. Available sheets: {wb.sheetnames}"
        )
    rows = [[_to_str(c) for c in row] for row in wb[sheet].iter_rows(values_only=True)]
    wb.close()
    return rows, sheet


def clean_column_names(raw_names):
    # Keep original names; replace only characters Delta does not allow, plus "."
    # (Spark reads a dot in a column name as a nested field). Names are made unique
    # case-insensitively against every name already used: A, A, A_2 -> A, A_2, A_2_2.
    names, used = [], set()
    for i, raw in enumerate(raw_names):
        base = re.sub(r"-\s*\n\s*", "-", (raw or "").strip())  # header wrapped after a hyphen
        base = re.sub(r"[ ,;{}()\n\t=.]+", "_", base).strip("_")
        if not base:
            base = f"col_{i}"
        if base in LINEAGE_COLS:
            base = f"src{base}"
        name, k = base, 1
        while name.lower() in used:
            k += 1
            name = f"{base}_{k}"
        used.add(name.lower())
        names.append(name)
    return names


def _width(row):
    # Number of cells up to the last non-empty one.
    n = len(row)
    while n and row[n - 1] is None:
        n -= 1
    return n


def _norm(text):
    # Lower case, single spaces: used to compare header text.
    return re.sub(r"\s+", " ", str(text or "")).strip().lower()


def check_header(rows, entry, rel_path):
    # Compare the physical title/header rows with header_check in the YAML, before any
    # column names are applied. Each check is {row: n, expect: {position: text}}; the cell
    # must CONTAIN the text (case and spacing ignored). Returns a list of problems.
    checks = entry.get("header_check") or []
    if isinstance(checks, dict):
        checks = [checks]
    problems = []
    for chk in checks:
        r = int(chk["row"])
        row = rows[r] if r < len(rows) else []
        for pos, text in (chk.get("expect") or {}).items():
            pos = int(pos)
            got = row[pos] if pos < len(row) else None
            if _norm(text) not in _norm(got):
                problems.append(f"row {r} col {pos}: expected '{text}', found '{got}'")
    return problems


def build_records(rows, entry):
    # Split raw rows into (column_names, records, skipped_blank_rows). Each record keeps
    # its 0-based row number in the file or sheet (for CSV this counts records, so a
    # quoted multi-line cell is one row).
    mode = entry.get("header_mode", "single")
    skip = int(entry.get("skip_rows", 0) or 0)

    if mode == "single":  # one header row at index skip_rows
        header = rows[skip][: _width(rows[skip])]
        columns = clean_column_names(header)
        first_data = skip + 1
    elif mode == "names":  # names come from the YAML; data starts at data_start_row
        first_data = int(entry["data_start_row"])
        named = entry["columns"]
        if isinstance(named, dict):  # {position: name}
            named = [named.get(i) for i in range(max(named) + 1)]
        width = max([len(named)] + [_width(r) for r in rows[first_data:]])
        columns = clean_column_names(
            [named[i] if i < len(named) and named[i] else f"col_{i}" for i in range(width)]
        )
    else:  # none: col_0, col_1, ...
        first_data = int(entry.get("data_start_row", skip) or 0)
        width = max(_width(r) for r in rows[first_data:])
        columns = [f"col_{i}" for i in range(width)]

    n = len(columns)
    records, blank = [], 0
    for row_num in range(first_data, len(rows)):
        row = rows[row_num]
        if _width(row) == 0:  # skip fully empty rows
            blank += 1
            continue
        values = (row + [None] * n)[:n]
        extra = {str(n + j): c for j, c in enumerate(row[n:]) if c is not None}  # keep positions
        rescued = json.dumps({"_extra_values": extra}) if extra else None
        records.append((values, rescued, row_num))
    return columns, records, blank


# -----------------------------------------------------------------------------
# Bronze write and metadata log
# -----------------------------------------------------------------------------


def to_bronze_df(columns, records, entry, rel_path, sheet, as_of):
    # Build the Spark DataFrame: data columns as strings, then the lineage columns.
    schema = StructType(
        [StructField(c, StringType(), True) for c in columns]
        + [
            StructField("_rescued_data", StringType(), True),
            StructField("_source_key", StringType(), False),
            StructField("_source_file", StringType(), False),
            StructField("_source_sheet", StringType(), True),
            StructField("_source_row_num", IntegerType(), False),
            StructField("_as_of_date", DateType(), False),
            StructField("_ingested_at", TimestampType(), False),
        ]
    )
    data = [
        tuple(values) + (rescued, entry["source_key"], rel_path, sheet, row_num, as_of, INGESTED_AT)
        for values, rescued, row_num in records
    ]
    return spark.createDataFrame(data, schema)


def _sql_str(s):
    return "'" + str(s).replace("'", "''") + "'"


def write_bronze(df, table, source_key, rel_paths):
    # Replace rows of this source's files in ONE transaction, keep everything else.
    writer = df.write.format("delta").option(
        "mergeSchema", "true"
    )  # bronze only: a new file may add a column
    if spark.catalog.tableExists(table):
        in_list = ", ".join(_sql_str(p) for p in rel_paths)
        predicate = f"_source_key = {_sql_str(source_key)} AND _source_file IN ({in_list})"
        writer = writer.mode("overwrite").option("replaceWhere", predicate)
    else:
        writer = writer.mode("append")
    writer.saveAsTable(table)


def rows_in_table(table, source_key, rel_paths):
    # Rows currently in the table per file of this source.
    if not spark.catalog.tableExists(table):
        return {}
    in_list = ", ".join(_sql_str(p) for p in rel_paths)
    return {
        r["_source_file"]: r["n"]
        for r in spark.sql(f"""
        SELECT _source_file, count(*) AS n FROM {table}
        WHERE _source_key = {_sql_str(source_key)} AND _source_file IN ({in_list})
        GROUP BY _source_file""").collect()
    }


# Ingestion metadata
METADATA_SCHEMA = [
    ("batch_id", "string"),  # one id per loader run, shared by all its files
    ("source_name", "string"),  # YAML source key
    ("source_version", "string"),  # as_of_date of the file (ISO text)
    ("endpoint", "string"),  # API endpoint; null for files
    ("content_checksum", "string"),  # sha256 of the file bytes
    ("raw_file_path", "string"),  # full landing path
    ("record_count", "bigint"),  # rows written to bronze (reconciled after the write)
    ("page_count", "int"),  # API pages; null for files
    ("retrieved_at", "timestamp"),  # load time (UTC)
    ("status", "string"),  # processed | failed (in_progress, skipped_duplicate: API job)
    ("bronze_table", "string"),
    ("source_sheet", "string"),
    ("column_count", "int"),
    ("file_size_bytes", "bigint"),
    ("error_message", "string"),  # error, or a warning on a processed row (replaced bytes)
]


def metadata_row(**values):
    # One metadata row as a tuple in METADATA_SCHEMA order; missing values are null.
    unknown = set(values) - {name for name, _ in METADATA_SCHEMA}
    if unknown:
        raise KeyError(f"not in METADATA_SCHEMA: {sorted(unknown)}")
    return tuple(values.get(name) for name, _ in METADATA_SCHEMA)


@functools.cache
def file_checksum(path):
    # sha256 of a file, read in 1 MB chunks, cached per path (a workbook listed once per sheet is hashed once).
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def log_metadata(table, rows):
    # Append one row per file to the ingestion metadata table. Columns the existing table
    # does not have yet are left out (with a warning). Returns True if the log was written.
    schema = ", ".join(f"{name} {dtype}" for name, dtype in METADATA_SCHEMA)
    try:
        df = spark.createDataFrame(rows, schema)
        if spark.catalog.tableExists(table):
            existing = {c.lower() for c in spark.table(table).columns}
            missing = [c for c in df.columns if c.lower() not in existing]
            if missing:
                print(f"  note: {table} has no columns {missing}; they are not logged")
                df = df.select(*[c for c in df.columns if c.lower() in existing])
        df.write.format("delta").mode("append").saveAsTable(table)
        return True
    except Exception as e:
        print(f"  AUDIT FAILED: could not write to {table}. {str(e)[:300]}")
        for r in rows:
            print("  metadata row:", r)
        return False


# -----------------------------------------------------------------------------
# Ingest one source
# -----------------------------------------------------------------------------


def read_file(f, entry):
    # Read one file (or sheet) into raw rows. Returns rows, sheet name, replaced-byte count.
    st, rel_path = f["settings"], f["rel"]
    fmt = st["format"].lower()
    if fmt == "csv":
        rows, replaced = read_csv_rows(f["abs"], st)
        return rows, None, replaced
    if fmt in ("xlsx", "xlsm"):
        rows, sheet = read_xlsx_rows(f["abs"], st)
        return rows, sheet, 0
    raise ValueError(f"[{entry['entry_name']}] unsupported format '{fmt}' for {rel_path}")


def ingest_source(cfg, entry):
    # Read every file of one source, check it, combine, write, reconcile.
    table = entry["bronze_table"]
    files = resolve_files(cfg, entry)

    frames, pending, all_columns, problems = [], [], [], []
    canonical = {}  # lower-case name -> first spelling seen (VALID FROM = Valid From)

    for f in files:
        st, rel_path = f["settings"], f["rel"]
        rows, sheet, replaced = read_file(f, entry)
        where = rel_path + (f" [{sheet}]" if sheet else "")

        # 1. Physical layout check, before any YAML names are applied.
        problems += [f"{where}: {p}" for p in check_header(rows, st, rel_path)]

        columns, records, blank = build_records(rows, st)
        columns = [canonical.setdefault(c.lower(), c) for c in columns]

        # 2. Required named columns (header_mode single).
        have = {c.lower() for c in columns}
        missing = [
            c for c in clean_column_names(st.get("required_columns") or []) if c.lower() not in have
        ]
        if missing:
            problems.append(f"{where}: missing required columns {missing}. Found: {columns}")

        # 3. At least one data row.
        if not records:
            problems.append(f"{where}: no data rows")
            continue

        frames.append(to_bronze_df(columns, records, entry, rel_path, sheet, st["as_of_date"]))
        all_columns += [c for c in columns if c not in all_columns]
        warning = f"warning: {replaced} undecodable bytes replaced" if replaced else None
        pending.append(
            {"f": f, "sheet": sheet, "rows": len(records), "cols": len(columns), "warning": warning}
        )
        print(
            f"  read {where}: {len(records):,} rows, {len(columns)} columns"
            + (f", {blank} blank rows skipped" if blank else "")
            + (f", {warning}" if warning else "")
        )

    if problems:
        raise ValueError("pre-load checks failed, nothing written:\n    " + "\n    ".join(problems))

    df = frames[0]
    for other in frames[1:]:
        df = df.unionByName(other, allowMissingColumns=True)  # a file may have an extra column
    df = df.select(*all_columns, *LINEAGE_COLS)

    # 4. Atomic replace of this source's files.
    rel_paths = list(dict.fromkeys(f["rel"] for f in files))
    write_bronze(df, table, entry["source_key"], rel_paths)

    # 5. Reconcile rows read vs rows in the table, per file.
    expected = {}
    for p in pending:
        expected[p["f"]["rel"]] = expected.get(p["f"]["rel"], 0) + p["rows"]
    actual = rows_in_table(table, entry["source_key"], rel_paths)
    off = {rel: (n, actual.get(rel)) for rel, n in expected.items() if actual.get(rel) != n}
    if off:
        raise ValueError(
            f"written to {table}, but row counts do not reconcile (read, in table): {off}"
        )
    print(f"  wrote {table} (reconciled {sum(expected.values()):,} rows)")

    return [
        metadata_row(
            batch_id=RUN_ID,
            source_name=entry["source_key"],
            source_version=p["f"]["settings"]["as_of_date"].isoformat(),
            content_checksum=file_checksum(p["f"]["abs"]),
            raw_file_path=p["f"]["abs"],
            record_count=p["rows"],
            retrieved_at=INGESTED_AT,
            status="processed",
            bronze_table=table,
            source_sheet=p["sheet"],
            column_count=p["cols"],
            file_size_bytes=os.path.getsize(p["f"]["abs"]),
            error_message=p["warning"],
        )
        for p in pending
    ]


def show_headers(cfg, entry, n):
    # Print the first n raw rows of every file/sheet of a source. Writes nothing.
    # Use it to fill header_check in the YAML.
    for f in resolve_files(cfg, entry):
        rows, sheet, _ = read_file(f, entry)
        print(f"  {f['rel']}" + (f" [{sheet}]" if sheet else ""))
        for i, row in enumerate(rows[:n]):
            cells = {j: c for j, c in enumerate(row) if c is not None}
            print(f"    row {i}: {json.dumps(cells, ensure_ascii=False)[:300]}")


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------


def parse_args():
    p = argparse.ArgumentParser(description="Bronze ingestion for the workforce domain")
    p.add_argument(
        "--config_path",
        default=None,
        help="Full path to the sources YAML (found automatically if omitted)",
    )
    p.add_argument(
        "--source_keys",
        default="ALL",
        help="Comma-separated source keys, or ALL for every enabled source",
    )
    p.add_argument(
        "--show_headers",
        type=int,
        default=0,
        help="Print the first N raw rows of each file and exit without writing",
    )
    args, _ = p.parse_known_args()
    return args


def main():
    args = parse_args()
    config_path = find_config(args.config_path)
    print(f"Config: {config_path}  |  loader {LOADER_VERSION}  |  run {RUN_ID}")
    cfg, sources = load_config(config_path)

    # Pick the sources to load. ALL skips entries marked enabled: false.
    if args.source_keys.strip().upper() == "ALL":
        keys = [k for k, e in sources.items() if loadable(e)]
        skipped = [k for k in sources if k not in keys]
        if skipped:
            print(f"Skipped (other domain, API source, or enabled: false): {skipped}")
    else:
        keys = [k.strip() for k in args.source_keys.split(",") if k.strip()]
    unknown = [k for k in keys if k not in sources]
    if unknown:
        raise KeyError(f"Not in {config_path}: {unknown}. Available: {list(sources)}")

    if args.show_headers:
        for key in keys:
            print(f"[{key}]")
            show_headers(cfg, sources[key], args.show_headers)
        return

    # Load each source. One failure does not stop the others.
    results, failures, audit_failures = [], [], []
    for key in keys:
        entry = sources[key]
        print(f"[{key}]")
        try:
            meta_rows = ingest_source(cfg, entry)
            if not log_metadata(entry["metadata_table"], meta_rows):
                audit_failures.append(key)
            names = [name for name, _ in METADATA_SCHEMA]
            m = dict(zip(names, zip(*meta_rows, strict=True), strict=True))
            results += [
                (key, p, n, s.upper(), None)
                for p, n, s in zip(m["raw_file_path"], m["record_count"], m["status"], strict=True)
            ]
        except Exception as e:
            failures.append(key)
            msg = str(e)[:500]
            print(f"  FAILED: {msg}")
            if not log_metadata(
                entry["metadata_table"],
                [
                    metadata_row(
                        batch_id=RUN_ID,
                        source_name=entry["source_key"],
                        raw_file_path=os.path.join(cfg["landing_root"], entry.get("path") or ""),
                        retrieved_at=INGESTED_AT,
                        status="failed",
                        bronze_table=entry.get("bronze_table"),
                        error_message=msg,
                    )
                ],
            ):
                audit_failures.append(key)
            results.append((key, entry.get("path"), None, "FAILED", msg))

    # Summary, then fail the run if any source or audit write failed.
    spark.createDataFrame(
        results,
        "source_key string, source_file string, row_count long, status string, error string",
    ).show(100, truncate=False)
    if failures or audit_failures:
        raise RuntimeError(
            f"Bronze ingest failed for: {failures}; audit log not written for: "
            f"{sorted(set(audit_failures))}. Run id {RUN_ID}"
        )
    print(f"Bronze ingest complete. Run id {RUN_ID}")


if __name__ == "__main__":
    main()
