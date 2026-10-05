# Bronze ingestion for the diseases domain (config-driven).
#
# What it does
#   Reads the sources YAML (sources_diseases.yaml or sources.yaml) and loads each
#   source file (CSV or Excel) into its bronze Delta table, exactly as it is in the file.
#
# Rules
#   - Every data column is loaded as STRING. Types are cast in silver.
#   - Column names come from the file header (header_mode: single) or from the
#     YAML (header_mode: names). Stacked tables use col_0, col_1, ... (none).
#   - Lineage columns are added to every row:
#       _rescued_data, _source_key, _source_file, _source_sheet,
#       _source_row_num, _as_of_date, _ingested_at
#   - Safe to re-run: rows from the same _source_file are replaced, not duplicated.
#   - Nothing about a source is hard-coded here. To add a source, add a YAML entry.
#
# How to run
#   python disease_bronze.py                                  # all enabled sources
#   python disease_bronze.py --source_keys doh_foi_dengue,upnoah,hdx_dengue
#   python disease_bronze.py --config_path /Workspace/.../sources_diseases.yaml
#   The YAML is found automatically if it sits next to this file or in a config/
#   folder beside or above it.
#
# Requires: pyyaml, openpyxl. openpyxl is installed on the fly if it is missing,
#           but adding it to the cluster or job libraries is the proper setup.


import argparse
import csv
import glob
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
# Same timestamp for every row of this run.
INGESTED_AT = datetime.now(UTC).replace(tzinfo=None)

CONFIG_NAMES = ("sources_diseases.yaml",)
DOMAIN = "diseases"  # this file only loads entries of this domain


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
    # True for file sources of this domain. In a shared sources.yaml this skips
    # other domains and API sources (entries without `path` or `bronze_table`).
    return (
        entry.get("domain") == DOMAIN
        and bool(entry.get("path"))
        and bool(entry.get("bronze_table"))
        and entry.get("enabled", True)
    )


# Settings a single file in `files:` may override.
FILE_LEVEL_KEYS = (
    "format",
    "sheet",
    "skip_rows",
    "data_start_row",
    "encoding",
    "delimiter",
    "as_of_date",
)


def resolve_files(cfg, entry):
    # Return one dict per file: abs path, relative path and the settings to read it with.
    # A file listed as a dict in `files:` can override the entry settings
    # (sheet, data_start_row, ...).
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
    # Read a CSV into a list of rows. Bad bytes are replaced, never dropped.
    encoding = entry.get("encoding", "utf-8")
    if encoding.lower().replace("-", "") == "utf8":
        encoding = "utf-8-sig"  # also removes a BOM if present
    with open(path, encoding=encoding, errors="replace", newline="") as f:
        return [
            [_to_str(c) for c in row]
            for row in csv.reader(f, delimiter=entry.get("delimiter", ","))
        ]


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
    # Keep original names; replace only characters Delta does not allow.
    names, seen = [], {}
    for i, raw in enumerate(raw_names):
        name = re.sub(r"-\s*\n\s*", "-", (raw or "").strip())  # header wrapped after a hyphen
        name = re.sub(r"[ ,;{}()\n\t=]+", "_", name).strip("_")
        if not name:
            name = f"col_{i}"
        if name in LINEAGE_COLS:
            name = f"src{name}"
        seen[name] = seen.get(name, 0) + 1
        if seen[name] > 1:
            name = f"{name}_{seen[name]}"
        names.append(name)
    return names


def _width(row):
    # Number of cells up to the last non-empty one.
    n = len(row)
    while n and row[n - 1] is None:
        n -= 1
    return n


def build_records(rows, entry):
    # Split raw rows into (column_names, records). Each record keeps its 0-based row number
    # in the file or sheet (for CSV this counts records, so a quoted multi-line cell is one row).
    mode = entry.get("header_mode", "single")
    skip = int(entry.get("skip_rows", 0) or 0)

    if mode == "single":
        # One header row at index skip_rows.
        header = rows[skip][: _width(rows[skip])]
        columns = clean_column_names(header)
        first_data = skip + 1
    elif mode == "names":
        # Names come from the YAML; data starts at data_start_row.
        first_data = int(entry["data_start_row"])
        named = entry["columns"]
        if isinstance(named, dict):  # {position: name}
            named = [named.get(i) for i in range(max(named) + 1)]
        width = max([len(named)] + [_width(r) for r in rows[first_data:]])
        columns = clean_column_names(
            [named[i] if i < len(named) and named[i] else f"col_{i}" for i in range(width)]
        )
    else:
        # none: col_0, col_1, ...
        first_data = int(entry.get("data_start_row", skip) or 0)
        width = max(_width(r) for r in rows[first_data:])
        columns = [f"col_{i}" for i in range(width)]

    n = len(columns)
    records = []
    for row_num in range(first_data, len(rows)):
        row = rows[row_num]
        if _width(row) == 0:  # skip fully empty rows
            continue
        values = (row + [None] * n)[:n]
        extra = [c for c in row[n:] if c is not None]
        rescued = json.dumps({"_extra_values": extra}) if extra else None
        records.append((values, rescued, row_num))
    return columns, records


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


def write_bronze(df, table, rel_paths):
    # Replace rows of the same source files, keep everything else. Safe to re-run.
    if spark.catalog.tableExists(table):
        in_list = ", ".join("'" + p.replace("'", "''") + "'" for p in rel_paths)
        spark.sql(f"DELETE FROM {table} WHERE _source_file IN ({in_list})")
    (
        df.write.format("delta")
        .mode("append")
        .option("mergeSchema", "true")  # bronze only: a new file may add a column
        .saveAsTable(table)
    )


def log_metadata(table, rows):
    # Append one row per file to the ingestion metadata table.
    # CONFIRM: adjust the columns below if the team's table uses different ones.
    schema = (
        "run_id string, source_key string, bronze_table string, source_file string, "
        "source_sheet string, as_of_date date, row_count long, column_count int, "
        "file_size_bytes long, status string, error_message string, ingested_at timestamp"
    )
    try:
        (
            spark.createDataFrame(rows, schema)
            .write.format("delta")
            .mode("append")
            .saveAsTable(table)
        )
    except Exception as e:  # do not lose a good load over logging
        print(f"WARNING: could not write to {table}. Check its columns. {str(e)[:300]}")
        for r in rows:
            print("  metadata row:", r)


# -----------------------------------------------------------------------------
# Ingest one source
# -----------------------------------------------------------------------------


def ingest_source(cfg, entry):
    # Read every file of one source, combine them, and write the bronze table.
    table = entry["bronze_table"]
    files = resolve_files(cfg, entry)
    frames, meta_rows, all_columns = [], [], []

    for f in files:
        st, rel_path = f["settings"], f["rel"]
        fmt = st["format"].lower()
        if fmt == "csv":
            rows, sheet = read_csv_rows(f["abs"], st), None
        elif fmt in ("xlsx", "xlsm"):
            rows, sheet = read_xlsx_rows(f["abs"], st)
        else:
            raise ValueError(f"[{entry['entry_name']}] unsupported format '{fmt}' for {rel_path}")

        columns, records = build_records(rows, st)
        if not records:
            raise ValueError(f"[{entry['entry_name']}] no data rows read from {rel_path}")

        frames.append(to_bronze_df(columns, records, entry, rel_path, sheet, st["as_of_date"]))
        all_columns += [c for c in columns if c not in all_columns]
        meta_rows.append(
            (
                RUN_ID,
                entry["source_key"],
                table,
                rel_path,
                sheet,
                st["as_of_date"],
                len(records),
                len(columns),
                os.path.getsize(f["abs"]),
                "SUCCESS",
                None,
                INGESTED_AT,
            )
        )
        print(
            f"  read {rel_path}"
            + (f" [{sheet}]" if sheet else "")
            + f": {len(records):,} rows, {len(columns)} columns"
        )

    df = frames[0]
    for other in frames[1:]:
        df = df.unionByName(other, allowMissingColumns=True)  # a file may have an extra column
    df = df.select(*all_columns, *LINEAGE_COLS)

    write_bronze(df, table, [f["rel"] for f in files])
    print(f"  wrote {table}")
    return meta_rows


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------


def parse_args():
    p = argparse.ArgumentParser(description="Bronze ingestion for the diseases domain")
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
    args, _ = p.parse_known_args()
    return args


def main():
    args = parse_args()
    config_path = find_config(args.config_path)
    print(f"Config: {config_path}")
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

    # Load each source. One failure does not stop the others.
    results, failures = [], []
    for key in keys:
        entry = sources[key]
        print(f"[{key}]")
        try:
            meta_rows = ingest_source(cfg, entry)
            log_metadata(entry["metadata_table"], meta_rows)
            results += [(key, r[3], r[6], "SUCCESS", None) for r in meta_rows]
        except Exception as e:
            failures.append(key)
            msg = str(e)[:500]
            print(f"  FAILED: {msg}")
            log_metadata(
                entry["metadata_table"],
                [
                    (
                        RUN_ID,
                        entry["source_key"],
                        entry.get("bronze_table"),
                        entry.get("path"),
                        None,
                        None,
                        None,
                        None,
                        None,
                        "FAILED",
                        msg,
                        INGESTED_AT,
                    )
                ],
            )
            results.append((key, entry.get("path"), None, "FAILED", msg))

    # Summary, then fail the run if any source failed.
    spark.createDataFrame(
        results,
        "source_key string, source_file string, row_count long, status string, error string",
    ).show(100, truncate=False)
    if failures:
        raise RuntimeError(f"Bronze ingest failed for: {failures}. Run id {RUN_ID}")
    print(f"Bronze ingest complete. Run id {RUN_ID}")


if __name__ == "__main__":
    main()
