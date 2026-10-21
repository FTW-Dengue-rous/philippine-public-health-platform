# =============================================================================
# Config-driven Bronze ingestion for the facilities domain.
# Uses the shared Bronze ingestion contract documented in:
#   docs/bronze_ingestion_contract.md
#
# Config:
#   config/sources_facilities.yaml
#
# Output:
#   Loads each configured CSV or Excel source into its assigned Bronze Delta table.
#
# Bronze keeps source values as STRING and adds standard lineage columns.
# Type casting and business cleaning happen in Silver.
#
# Run examples:
#   python facilities_bronze.py
#
#   python facilities_bronze.py \
#       --source_keys doh_nhfr,psa_hospitals_beds_national_annual
#
#   python facilities_bronze.py \
#       --show_headers 8 \
#       --source_keys psa_hospitals_region_annual_legacy
#
#   python facilities_bronze.py --plan true
#   python facilities_bronze.py --force_keys <key1>,<key2>
#   python facilities_bronze.py --force true
#
# Requires:
#   pyyaml
#   openpyxl
#
# Next step:
#   facilities_bronze_qc.py
# =============================================================================

import argparse
import csv
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

LOADER_VERSION = (
    "2026-10-19.1"  # printed at start; bump when parsing or timestamp behaviour changes
)
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
# Same timestamp for every row and log row of this run. Timezone-aware UTC (2026-10-19): PySpark stores
# it as that exact instant on any driver. The old naive value was read in the driver's OS timezone,
# so off Databricks it was shifted (8 hours on a UTC+8 laptop). Same stored values on Databricks.
INGESTED_AT = datetime.now(UTC)

CONFIG_NAMES = ("sources_facilities.yaml",)  # config file for this domain
DOMAIN = "facilities"  # this file only loads entries of this domain


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
    # Import a package; if it is missing, install it for this run and import again.
    # Better long term: add it to the cluster or job libraries.
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
    replaced = sum(c.count("�") for row in rows for c in row if c)
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


# Ingestion metadata: the team's documented columns first (shared with the API ingestion),
# then the file-load extras (null for API rows). One row per file, or per sheet.
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
    ("status", "string"),  # processed | failed | skipped_duplicate (in_progress: API job)
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


def file_checksum(path, _cache={}):
    # sha256 of a file, read in 1 MB chunks, cached per path (a workbook listed once per sheet is hashed once).
    if path not in _cache:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        _cache[path] = h.hexdigest()
    return _cache[path]


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


def ingest_source(cfg, entry, files=None):
    # Read the given files of one source (default: all), check them, combine, write, reconcile.
    # Only these files' rows are replaced; the source's other files stay as they are.
    table = entry["bronze_table"]
    files = resolve_files(cfg, entry) if files is None else files

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


# -----------------------------------------------------------------------------
# Incremental loading: which files of a source need loading
# -----------------------------------------------------------------------------

METADATA_NEEDED = (
    "source_name",
    "raw_file_path",
    "source_sheet",
    "bronze_table",
    "content_checksum",
    "source_version",
    "record_count",
    "retrieved_at",
    "batch_id",
    "status",
)


def last_loads(metadata_table, source_names):
    # Latest 'processed' row per (source, file path, sheet, bronze table) for the given sources.
    # Returns {(source, path, table): [rows, one per sheet]}, or None when the log cannot be used
    # (then every file is loaded, as before).
    if not spark.catalog.tableExists(metadata_table):
        return {}
    have = {c.lower() for c in spark.table(metadata_table).columns}
    missing = [c for c in METADATA_NEEDED if c not in have]
    if missing:
        print(
            f"  note: {metadata_table} has no columns {missing}; every file is loaded "
            "(run ingestion_metadata_fix.sql Part 1 to enable incremental loading)"
        )
        return None
    names = ", ".join(_sql_str(s) for s in sorted(set(source_names)))
    rows = spark.sql(f"""
        SELECT source_name, raw_file_path, source_sheet, bronze_table, content_checksum, source_version,
               record_count, retrieved_at, batch_id
        FROM (SELECT *, row_number() OVER (
                        PARTITION BY source_name, raw_file_path, coalesce(source_sheet, ''), bronze_table
                        ORDER BY retrieved_at DESC) AS rn
              FROM {metadata_table}
              WHERE lower(status) = 'processed' AND source_name IN ({names}))
        WHERE rn = 1""").collect()
    out = {}
    for r in rows:
        out.setdefault((r.source_name, r.raw_file_path, r.bronze_table), []).append(r)
    return out


def bronze_loads(table, source_key):
    # Rows in the bronze table per (file, sheet, load time) for one source.
    if not spark.catalog.tableExists(table):
        return {}
    return {
        (r._source_file, r._source_sheet, r._ingested_at): r.n
        for r in spark.sql(f"""
        SELECT _source_file, _source_sheet, _ingested_at, count(*) AS n FROM {table}
        WHERE _source_key = {_sql_str(source_key)}
        GROUP BY _source_file, _source_sheet, _ingested_at""").collect()
    }


def plan_source(entry, files, loads, in_bronze, force):
    # One item per file: {"rel", "files", "reason", "prior"}. reason None = unchanged (skip);
    # prior = the logged load(s) the bronze rows come from. A workbook listed once per sheet is
    # one item: if any of its sheets needs loading, all of them are loaded.
    table, key = entry["bronze_table"], entry["source_key"]
    by_file = {}
    for f in files:
        by_file.setdefault(f["rel"], []).append(f)
    plan = []
    for rel, fs in by_file.items():
        reason = "forced" if force else ("metadata_unavailable" if loads is None else None)
        prior = []
        for f in fs:
            if reason:
                break
            st = f["settings"]
            logged = loads.get((key, f["abs"], table), [])
            if st["format"].lower() in ("xlsx", "xlsm"):
                sheet = st.get("sheet")  # None = first sheet: any logged sheet of this file
                logged = [r for r in logged if sheet is None or r.source_sheet == sheet]
            else:
                logged = [r for r in logged if r.source_sheet is None]
            if not logged:
                reason = "new"
                break
            last = max(logged, key=lambda r: r.retrieved_at)
            if not last.content_checksum:
                reason = "no_checksum_logged"
            elif last.content_checksum != file_checksum(f["abs"]):
                reason = "content_changed"
            elif last.source_version != st["as_of_date"].isoformat():
                reason = "as_of_date_changed"
            else:
                rows_now = sum(
                    n
                    for (fl, sh, _), n in in_bronze.items()
                    if fl == rel and sh == last.source_sheet
                )
                rows_of_load = in_bronze.get((rel, last.source_sheet, last.retrieved_at), 0)
                if not rows_now == rows_of_load == last.record_count:
                    reason = "bronze_rows_differ"
            if reason:
                break
            prior.append(last)
        plan.append({"rel": rel, "files": fs, "reason": reason, "prior": [] if reason else prior})
    return plan


def skipped_rows(entry, item):
    # ingestion_metadata rows for an unchanged file: status skipped_duplicate, this run's time,
    # and the load the bronze rows still come from.
    return [
        metadata_row(
            batch_id=RUN_ID,
            source_name=entry["source_key"],
            source_version=r.source_version,
            content_checksum=r.content_checksum,
            raw_file_path=r.raw_file_path,
            record_count=r.record_count,
            retrieved_at=INGESTED_AT,
            status="skipped_duplicate",
            bronze_table=entry["bronze_table"],
            source_sheet=r.source_sheet,
            file_size_bytes=os.path.getsize(r.raw_file_path),
            error_message=f"unchanged: bronze rows are from load {r.batch_id} "
            f"({r.retrieved_at:%Y-%m-%d %H:%M:%S} UTC)",
        )
        for r in item["prior"]
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


def write_result(path, result):
    # Optional JSON for a runner: which sources loaded, were unchanged or failed in this run.
    if path:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, default=str)


def parse_args():
    p = argparse.ArgumentParser(description="Bronze ingestion for the facilities domain")
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
    p.add_argument(
        "--plan",
        default="false",
        choices=["true", "false"],
        help="Print which files would load and why, then exit without writing",
    )
    p.add_argument(
        "--force",
        default="false",
        choices=["true", "false"],
        help="Reload every file of the selected sources, changed or not",
    )
    p.add_argument(
        "--force_keys",
        default="",
        help="Comma-separated source keys to reload in full (after a YAML settings or loader change)",
    )
    p.add_argument(
        "--log_skipped",
        default="true",
        choices=["true", "false"],
        help="Write a skipped_duplicate row to ingestion_metadata for each unchanged file",
    )
    p.add_argument(
        "--result_path",
        default=None,
        help="Also write the loaded / skipped / failed source keys to this JSON file",
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

    force_keys = {k.strip() for k in args.force_keys.split(",") if k.strip()}
    unknown = sorted(force_keys - set(keys))
    if unknown:
        raise KeyError(f"--force_keys not among the selected sources: {unknown}")

    # Load each source: only its new or changed files. One failure does not stop the others.
    results, failures, audit_failures = [], [], []
    loaded, unchanged, planned = [], [], {}
    log_cache = {}  # metadata table -> latest processed loads
    for key in keys:
        entry = sources[key]
        print(f"[{key}]")
        try:
            files = resolve_files(cfg, entry)
            mt = entry["metadata_table"]
            if mt not in log_cache:
                log_cache[mt] = last_loads(mt, [sources[k]["source_key"] for k in keys])
            in_bronze = bronze_loads(entry["bronze_table"], entry["source_key"])
            plan = plan_source(
                entry,
                files,
                loads=log_cache[mt],
                in_bronze=in_bronze,
                force=args.force == "true" or key in force_keys,
            )
            for item in plan:
                print(
                    f"  {'LOAD' if item['reason'] else 'skip'}  {item['rel']}  ({item['reason'] or 'unchanged'})"
                )
            listed = {f["rel"] for f in files}
            gone = sorted({fl for (fl, _, _) in in_bronze if fl not in listed})
            if gone:
                print(
                    f"  note: in {entry['bronze_table']} but not in the YAML any more (kept): {gone}"
                )
            to_load = [f for item in plan if item["reason"] for f in item["files"]]
            planned[key] = {item["rel"]: item["reason"] for item in plan}
            if args.plan == "true":
                continue

            meta_rows = ingest_source(cfg, entry, to_load) if to_load else []
            skip_items = [item for item in plan if not item["reason"]]
            skip_meta = (
                [r for item in skip_items for r in skipped_rows(entry, item)]
                if args.log_skipped == "true"
                else []
            )
            if (meta_rows or skip_meta) and not log_metadata(mt, meta_rows + skip_meta):
                audit_failures.append(key)
            (loaded if to_load else unchanged).append(key)
            if meta_rows:
                m = dict(zip([name for name, _ in METADATA_SCHEMA], zip(*meta_rows)))
                results += [
                    (key, p, n, s.upper(), None)
                    for p, n, s in zip(m["raw_file_path"], m["record_count"], m["status"])
                ]
            results += [
                (key, r.raw_file_path, r.record_count, "SKIPPED", "unchanged")
                for item in skip_items
                for r in item["prior"]
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

    write_result(
        args.result_path,
        {
            "run_id": RUN_ID,
            "domain": DOMAIN,
            "plan_only": args.plan == "true",
            "loaded": loaded,
            "unchanged": unchanged,
            "failed": failures,
            "audit_failed": sorted(set(audit_failures)),
            "would_load": sorted(k for k, p in planned.items() if any(p.values())),
            "files": planned,
        },
    )
    if args.plan == "true":
        print(
            f"Plan only: nothing written. Would load: "
            f"{sorted(k for k, p in planned.items() if any(p.values())) or 'nothing'}"
        )
        return

    # Summary, then fail the run if any source or audit write failed.
    if results:
        spark.createDataFrame(
            results,
            "source_key string, source_file string, row_count long, status string, error string",
        ).show(100, truncate=False)
    print(
        f"Loaded: {loaded or 'nothing'} | unchanged: {unchanged or 'none'} | failed: {failures or 'none'}"
    )
    if failures or audit_failures:
        raise RuntimeError(
            f"Bronze ingest failed for: {failures}; audit log not written for: "
            f"{sorted(set(audit_failures))}. Run id {RUN_ID}"
        )
    print(f"Bronze ingest complete. Run id {RUN_ID}")


if __name__ == "__main__":
    main()
