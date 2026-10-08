# =============================================================================
# Bronze QC for the socioeconomic domain
#
# What it does
#   Runs after socioeconomic_bronze.py. Reads the bronze tables as stored and checks
#   that each load is complete and faithful to the source file.
#
# Output (public_health.quality, written through dq_utils.DQRun)
#   qc_results    one row per check result, status PASS, WARN or FAIL
#   run_log       one row for this QC execution
#   table_stats   row count and Delta version of every table checked
#   profile       null / blank / distinct / min / max per column (--profile true).
#                 Not written for sources marked sharing: restricted, because min / max
#                 would copy real values (patient or licensed data) out of the table.
#   The script raises an error if any check is FAIL, so a job stops before silver.
#
# Checks (settings come from the `qc:` block of each YAML entry)
#   B01 table exists and has rows                               FAIL
#   B02 every file listed in the YAML was loaded                FAIL
#   B03 row count per file matches qc.expected_rows             FAIL
#       (WARN if a loaded file has no expected count yet)
#   B04 required columns exist                                  FAIL
#   B05 lineage columns are never null                          FAIL
#   B06 _source_row_num is unique per file (no double load)     FAIL
#   B07 no rows where every data column is empty                WARN
#   B08 no exact duplicate rows within a file and sheet         WARN
#   B09 no rows with rescued (overflow) values                  WARN
#   B10 qc.numeric_columns can be read as numbers               WARN
#   B11 control totals / control values match (verified numbers) FAIL
#   B12 a total column equals the sum of its parts (qc.row_sum) WARN
#   B13 rows per file match the ingestion metadata (same load)  FAIL
#   B14 table holds no files outside the YAML (stale loads)     WARN
#   B15 every data column is STRING                             FAIL
#   A source can switch a check off with qc.skip_checks: [B08], or change what a
#   failed check produces with qc.severity: {B03: WARN}.
#
# Severity policy
#   FAIL = the load itself is wrong or cannot be traced (missing file, wrong row count,
#          double load, broken lineage, wrong numbers against a verified control).
#   WARN = the load is faithful but the source has something to look at (blank rows,
#          duplicates, text in a number column, a total that does not add up).
#   Bronze keeps the rows either way; a FAIL only stops the job before silver.
#
# One meaning per code: check_name is fixed per code. The column, file or
# control label goes to column_name / detail, never into the name.
#
# How to run
#   python socioeconomic_bronze_qc.py
#   python socioeconomic_bronze_qc.py --source_keys psa_poverty --fail_on_error false
#   In a Databricks job, pass --job_run_id {{job.run_id}}
#
# Requires: pyyaml, dq_utils.py (found automatically in the quality folder), quality_setup.sql already run.
# =============================================================================

import argparse
import os
import re
import sys

import yaml
from pyspark.sql import SparkSession


def _add_dq_utils_to_path():
    # Find dq_utils.py and put its folder on sys.path. Looks in this file's folder and the
    # working directory, up to five levels above each, and in any *quality* folder there
    # (e.g. src/05_quality/). Works when __file__ is not set (notebook cell, %run, exec).
    starts = [os.getcwd()]
    try:
        starts.insert(0, os.path.dirname(os.path.abspath(__file__)))
    except NameError:
        pass
    searched = []
    for start in starts:
        folder = start
        for _ in range(6):
            candidates = [folder]
            for base in (
                folder,
                os.path.join(folder, "src"),
            ):  # <folder>/05_quality or <folder>/src/05_quality
                try:
                    candidates += [
                        os.path.join(base, d)
                        for d in sorted(os.listdir(base))
                        if "quality" in d.lower() and os.path.isdir(os.path.join(base, d))
                    ]
                except OSError:
                    pass
            for c in candidates:
                searched.append(c)
                if os.path.isfile(os.path.join(c, "dq_utils.py")):
                    if c not in sys.path:
                        sys.path.insert(0, c)
                    return c
            parent = os.path.dirname(folder)
            if parent == folder:
                break
            folder = parent
    raise ModuleNotFoundError(
        "dq_utils.py not found. It must be a Python FILE named dq_utils.py (not a notebook) in "
        "the quality folder. Looked in:\n  " + "\n  ".join(dict.fromkeys(searched))
    )


_add_dq_utils_to_path()
from dq_utils import DQRun  # noqa: E402

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

CONFIG_NAMES = ("sources_socioeconomic.yaml",)  # config file for this domain
DOMAIN = "socioeconomic"  # this file only checks entries of this domain
SCRIPT_NAME = "socioeconomic_bronze_qc.py"

# check_id: (check_name, check_type, severity). Same values as quality_registry_seed.sql.
CHECKS = {
    "B00": ("QC ran without error", "EXECUTION", "FAIL"),
    "B01": ("table exists and has rows", "COMPLETENESS", "FAIL"),
    "B02": ("all listed files loaded", "COMPLETENESS", "FAIL"),
    "B03": ("row count matches expected", "RECONCILIATION", "FAIL"),
    "B04": ("required columns present", "SCHEMA", "FAIL"),
    "B05": ("lineage columns not null", "COMPLETENESS", "FAIL"),
    "B06": ("row number unique per file", "UNIQUENESS", "FAIL"),
    "B07": ("no fully empty rows", "COMPLETENESS", "WARN"),
    "B08": ("no exact duplicate rows", "UNIQUENESS", "WARN"),
    "B09": ("no rescued values", "SCHEMA", "WARN"),
    "B10": ("numeric column parses", "VALIDITY", "WARN"),
    "B11": ("control totals / values match", "RECONCILIATION", "FAIL"),
    "B12": ("total equals sum of parts", "CONSISTENCY", "WARN"),
    "B13": ("rows match ingestion metadata", "RECONCILIATION", "FAIL"),
    "B14": ("no files outside the YAML", "CONSISTENCY", "WARN"),
    "B15": ("data columns are STRING", "SCHEMA", "FAIL"),
}


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
    except NameError:
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
# Helpers
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


def bronze_name(raw):
    # Same rule the bronze loader uses for column names (including "." -> "_").
    return re.sub(r"[ ,;{}()\n\t=.]+", "_", str(raw).strip()).strip("_")


def q(col):
    return "`" + col.replace("`", "``") + "`"


def sql_str(s):
    return "'" + str(s).replace("'", "''") + "'"


def scalar(sql):
    return spark.sql(sql).collect()[0][0]


def num(col, as_type="double"):
    # SQL to read a string column as a number: ignores spaces and thousands separators.
    return f"try_cast(regexp_replace({q(col)}, '[ ,]', '') AS {as_type})"


def same_number(got, want):
    # Control values may be whole numbers (deaths) or decimals (rates, shares).
    return got is not None and want is not None and abs(float(got) - float(want)) < 1e-6


def expected_files(entry):
    # Distinct files listed in the YAML (one file may be listed once per sheet).
    # Returned as paths relative to landing_root, the same text the loader stores in _source_file.
    if entry.get("files"):
        names = [
            os.path.join(entry["path"], f["name"] if isinstance(f, dict) else f)
            for f in entry["files"]
        ]
        return list(dict.fromkeys(names))
    return None if any(ch in entry["path"] for ch in "*?[") else [entry["path"]]


def required_columns(entry):
    # Columns the table must have: required_columns, YAML column names (header_mode: names,
    # entry level and per file) and column_map keys, minus optional_columns.
    names = list(entry.get("required_columns") or [])
    layouts = []
    if entry.get("header_mode") == "names" and entry.get("columns"):
        layouts.append(entry["columns"])
    for f in entry.get("files") or []:
        if isinstance(f, dict):
            names += f.get("required_columns") or []
            if f.get("columns") and f.get("header_mode", entry.get("header_mode")) == "names":
                layouts.append(f["columns"])
    for named in layouts:
        names += [c for c in (named.values() if isinstance(named, dict) else named) if c]
    names += list(entry.get("column_map") or {})
    optional = {bronze_name(c).lower() for c in entry.get("optional_columns") or []}
    cleaned = [bronze_name(c) for c in names]
    return [c for c in dict.fromkeys(cleaned) if c.lower() not in optional]


def latest_metadata(cfg, entry):
    # Latest successful load per file from the ingestion metadata log.
    # Returns {relative_file: {"rows", "batch_id", "loaded_at"}}, or None if the log cannot be read.
    # The latest load is picked by its loader batch_id (not by timestamp alone), and the rows
    # of that one load are summed (a workbook has one log row per sheet).
    # batch_id for QC = source_key:sha256 of the file, i.e. the exact file version checked.
    table = entry.get("metadata_table")
    if not table or not spark.catalog.tableExists(table):
        return None
    rows = spark.sql(f"""
        WITH ok AS (
          SELECT batch_id, raw_file_path, content_checksum, record_count, retrieved_at
          FROM {table}
          WHERE source_name = {sql_str(entry["source_key"])}
            AND bronze_table = {sql_str(entry["bronze_table"])}
            AND lower(status) = 'processed'),
        last AS (
          SELECT raw_file_path, max_by(batch_id, retrieved_at) AS batch_id
          FROM ok GROUP BY raw_file_path)
        SELECT o.raw_file_path, max(o.content_checksum) AS checksum, sum(o.record_count) AS n,
               max(o.retrieved_at) AS loaded_at
        FROM ok o JOIN last l ON o.raw_file_path = l.raw_file_path AND o.batch_id <=> l.batch_id
        GROUP BY o.raw_file_path""").collect()
    root = cfg["landing_root"].rstrip("/") + "/"
    out = {}
    for r in rows:
        rel = (
            r["raw_file_path"][len(root) :]
            if r["raw_file_path"].startswith(root)
            else r["raw_file_path"]
        )
        out[rel] = {
            "rows": r["n"],
            "loaded_at": r["loaded_at"],
            "batch_id": f"{entry['source_key']}:{r['checksum']}" if r["checksum"] else None,
        }
    return out


# -----------------------------------------------------------------------------
# Checks for one source
# -----------------------------------------------------------------------------


def run_checks(dq, cfg, entry, profile):
    t = entry["bronze_table"]
    key = entry["source_key"]
    qc = entry.get("qc", {}) or {}
    skip = qc.get("skip_checks") or []
    overrides = qc.get("severity") or {}  # e.g. severity: {B03: WARN}

    def rec(check_id, ok=None, **kw):
        # One result row. Name and type come from CHECKS; severity from CHECKS or qc.severity.
        # ok=True/False -> PASS or the check's severity, so no check hard-codes FAIL or WARN.
        # With fail_count and no ok/status, DQRun computes the status the same way.
        name, ctype, severity = CHECKS[check_id]
        severity = str(overrides.get(check_id, severity)).upper()
        if ok is not None:
            kw["status"] = "PASS" if ok else severity
        return dq.record(
            check_id,
            table_name=t,
            source_key=key,
            check_name=name,
            check_type=ctype,
            severity=severity,
            skip=skip,
            **kw,
        )

    # B01 table exists and has rows for this source
    if not spark.catalog.tableExists(t):
        rec("B01", ok=False, observed="missing", expected="exists")
        return

    # Scope: every row check below looks only at this source's rows, so another source
    # sharing the table cannot change the result. B14 and B15 look at the whole table.
    df = spark.table(t)
    v = "_qc_scope"
    df.where(f"_source_key = {sql_str(key)}").createOrReplaceTempView(v)
    total = scalar(f"SELECT count(*) FROM {v}")
    rec("B01", ok=total > 0, observed=total, expected="> 0")
    try:  # stats are extra; an error here must not stop the checks
        dq.capture_table_stats(t)
    except Exception as e:
        print(f"  note: table stats skipped ({str(e)[:150]})")
    if total == 0:
        return

    columns = df.columns
    lower_cols = {c.lower() for c in columns}
    data_cols = [c for c in columns if c not in LINEAGE_COLS]
    loaded = {
        r["_source_file"]: (r["n"], r["loaded_at"])
        for r in spark.sql(
            f"SELECT _source_file, count(*) AS n, max(_ingested_at) AS loaded_at FROM {v} "
            "GROUP BY _source_file"
        ).collect()
    }
    per_file = {f: n for f, (n, _) in loaded.items()}
    meta = latest_metadata(cfg, entry)  # None if the log cannot be read
    batch = {f: m["batch_id"] for f, m in (meta or {}).items()}

    # B02 every file in the YAML was loaded
    files = expected_files(entry)
    if files is not None:
        missing = [f for f in files if f not in per_file]
        rec(
            "B02",
            ok=not missing,
            observed=len(files) - len(missing),
            expected=len(files),
            detail=f"missing: {missing}" if missing else None,
        )

    # B03 row count per file (all sheets of a file together). expected_rows is the count of
    #     the file version that was verified; a revised file needs the YAML updated.
    #     A loaded file with no expected count is a WARN, so a new file cannot pass unverified.
    exp = qc.get("expected_rows")
    for f, n in sorted(per_file.items()):
        if files is not None and f not in files:  # files outside the YAML are reported by B14
            continue
        want = exp.get(os.path.basename(f)) if isinstance(exp, dict) else exp
        if want is None:
            rec(
                "B03",
                status="WARN",
                observed=n,
                expected="not set",
                batch_id=batch.get(f),
                detail=f"{f}: no qc.expected_rows for this file; verify the count and add it to the YAML",
            )
        else:
            rec("B03", ok=n == want, observed=n, expected=want, detail=f, batch_id=batch.get(f))

    # B04 required columns exist (compared without case, like the loader)
    required = required_columns(entry)
    if required:
        missing_cols = [c for c in required if c.lower() not in lower_cols]
        rec(
            "B04",
            ok=not missing_cols,
            observed=len(required) - len(missing_cols),
            expected=len(required),
            detail=f"missing: {missing_cols}; table has: {data_cols}" if missing_cols else None,
        )

    # B05 lineage columns never null (_rescued_data and _source_sheet may be null)
    must = ["_source_file", "_source_row_num", "_as_of_date", "_ingested_at"]
    nulls = scalar(f"SELECT count(*) FROM {v} WHERE " + " OR ".join(f"{c} IS NULL" for c in must))
    nulls += scalar(f"SELECT count(*) FROM {t} WHERE _source_key IS NULL")
    rec("B05", fail_count=nulls, total_count=total)

    # B06 one row per file, sheet and row number (catches a double load).
    #     Bronze keeps one version per file path, so a repeat here is a repeated load.
    dup_rownum = scalar(f"""
        SELECT coalesce(sum(n - 1), 0) FROM (
          SELECT count(*) AS n FROM {v}
          GROUP BY _source_file, _source_sheet, _source_row_num HAVING count(*) > 1)""")
    rec("B06", fail_count=dup_rownum, total_count=total)

    # B07 rows with every data column empty
    blank = scalar(
        f"SELECT count(*) FROM {v} WHERE "
        + " AND ".join(f"coalesce(trim({q(c)}), '') = ''" for c in data_cols)
    )
    rec("B07", fail_count=blank, total_count=total)

    # B08 exact duplicate rows within a file and sheet (legend lines repeat across sheets)
    col_list = ", ".join(q(c) for c in data_cols)
    dups = scalar(f"""
        SELECT coalesce(sum(n - 1), 0) FROM (
          SELECT count(*) AS n FROM {v}
          GROUP BY _source_file, _source_sheet, {col_list} HAVING count(*) > 1)""")
    rec("B08", fail_count=dups, total_count=total)

    # B09 rescued values (rows wider than the header)
    rescued = scalar(f"SELECT count(*) FROM {v} WHERE _rescued_data IS NOT NULL")
    rec("B09", fail_count=rescued, total_count=total)

    # B10 numeric columns can be parsed (values stay strings in bronze).
    #     qc.max_non_numeric_rows_per_file allows known text rows (tag row, footers).
    allowed = int(qc.get("max_non_numeric_rows_per_file", 0))
    tokens = ", ".join(sql_str(x) for x in qc.get("null_tokens", [])) or "''"
    for raw in qc.get("numeric_columns", []):
        c = bronze_name(raw)
        if c.lower() not in lower_cols:
            rec(
                "B10",
                ok=False,
                column_name=c,
                observed="missing",
                expected="column exists",
                detail="column listed in qc.numeric_columns is not in the table",
            )
            continue
        rows = spark.sql(f"""
            SELECT _source_file, count(*) AS n FROM {v}
            WHERE {q(c)} IS NOT NULL AND trim({q(c)}) NOT IN ({tokens}) AND {num(c)} IS NULL
            GROUP BY _source_file""").collect()
        worst = max([r["n"] for r in rows], default=0)
        rec(
            "B10",
            ok=worst <= allowed,
            column_name=c,
            fail_count=sum(r["n"] for r in rows),
            total_count=total,
            observed=worst,
            expected=f"<= {allowed} per file",
            detail="; ".join(f"{r['_source_file']}: {r['n']}" for r in rows) or None,
        )

    # B11a control totals by group. Use only numbers verified against the published source.
    #      Summed over all files of the source, or over one file when control_totals.file is set
    #      (needed when two files overlap).
    ct = qc.get("control_totals")
    if ct:
        g, c = bronze_name(ct["group_by"]), bronze_name(ct["sum"])
        one_file = ct.get("file")
        scope = f"WHERE _source_file LIKE {sql_str('%' + one_file)}" if one_file else ""
        actual = {
            str(r[0]): r[1]
            for r in spark.sql(
                f"SELECT {q(g)}, sum({num(c)}) FROM {v} {scope} GROUP BY {q(g)}"
            ).collect()
        }
        batch_of = next((b for f, b in batch.items() if one_file and f.endswith(one_file)), None)
        for group, want in ct["expected"].items():
            got = actual.get(str(group))
            rec(
                "B11",
                ok=same_number(got, want),
                column_name=c,
                observed=got,
                expected=want,
                detail=f"control total: {g} = {group}" + (f" ({one_file})" if one_file else ""),
                batch_id=batch_of,
            )

    # B11b control values: one known number picked out by a filter (name the file in `where`)
    for cv in qc.get("control_values", []):
        c = bronze_name(cv["column"])
        got = scalar(f"SELECT sum({num(c)}) FROM {v} WHERE ({cv['where']})")
        rec(
            "B11",
            ok=same_number(got, cv["expected"]),
            column_name=c,
            observed=got,
            expected=cv["expected"],
            detail=f"control value: {cv['label']}",
        )

    # B12 total column equals the sum of its parts, on rows where every value is a number.
    #     A mismatch can be the source's own inconsistency, so bronze only flags it (WARN).
    rs = qc.get("row_sum")
    if rs:
        tot, parts = bronze_name(rs["total"]), [bronze_name(x) for x in rs["parts"]]
        all_numeric = f"{num(tot)} IS NOT NULL AND " + " AND ".join(
            num(x) + " IS NOT NULL" for x in parts
        )
        r = spark.sql(f"""
            SELECT count(*) AS n,
                   count_if(abs({num(tot)} - ({" + ".join(num(x) for x in parts)})) > 0.5) AS bad
            FROM {v} WHERE {all_numeric}""").collect()[0]
        if r["n"] == 0:  # nothing compared is not a pass
            rec(
                "B12",
                status="WARN",
                column_name=tot,
                fail_count=0,
                total_count=0,
                detail="no comparable rows: no row has numbers in the total and every part",
            )
        else:
            rec(
                "B12",
                fail_count=r["bad"],
                total_count=r["n"],
                column_name=tot,
                detail=f"{tot} vs sum of {len(parts)} columns; rows with a non-numeric value are not compared",
            )

    # B13 rows per file equal what the loader logged for the SAME load. The load is matched on
    #     _ingested_at = retrieved_at; if table and log come from different loads, the counts
    #     are not comparable and the result is WARN, not FAIL.
    if meta is None:
        rec("B13", status="WARN", detail=f"metadata log not found: {entry.get('metadata_table')}")
    else:
        for f, (n, loaded_at) in sorted(loaded.items()):
            if files is not None and f not in files:
                continue
            m = meta.get(f)
            if m is None:
                rec(
                    "B13",
                    status="WARN",
                    observed=n,
                    expected="a processed row in the log",
                    detail=f,
                )
            elif m["loaded_at"] != loaded_at:
                rec(
                    "B13",
                    status="WARN",
                    observed=n,
                    expected=m["rows"],
                    batch_id=m["batch_id"],
                    detail=f"{f}: table load {loaded_at} and latest log row {m['loaded_at']} are different loads; rerun the load",
                )
            else:
                rec(
                    "B13",
                    ok=n == m["rows"],
                    observed=n,
                    expected=m["rows"],
                    detail=f,
                    batch_id=m["batch_id"],
                )

    # B14 nothing in the table that the YAML does not list (old file names, other sources)
    if files is not None:
        stray = sorted(f for f in per_file if f not in files)
        shared = {e["source_key"] for e in cfg["_sources"].values() if e.get("bronze_table") == t}
        other = [
            r
            for r in spark.sql(
                f"SELECT _source_key, count(*) AS n FROM {t} "
                f"WHERE _source_key <> {sql_str(key)} GROUP BY 1"
            ).collect()
            if r["_source_key"] not in shared
        ]
        n_stray = sum(per_file[f] for f in stray) + sum(r["n"] for r in other)
        rec(
            "B14",
            fail_count=n_stray,
            total_count=total + sum(r["n"] for r in other),
            detail=(
                "; ".join(
                    [f"file not in YAML: {f} ({per_file[f]} rows)" for f in stray]
                    + [f"other source_key: {r['_source_key']} ({r['n']} rows)" for r in other]
                )
                or None
            ),
        )

    # B15 bronze contract: every data column is STRING
    not_string = [
        f"{f.name} {f.dataType.simpleString()}"
        for f in df.schema.fields
        if f.name not in LINEAGE_COLS and f.dataType.simpleString() != "string"
    ]
    rec(
        "B15",
        ok=not not_string,
        observed=len(data_cols) - len(not_string),
        expected=len(data_cols),
        detail=f"not string: {not_string}" if not_string else None,
    )

    # Column profile last, so a profiling error cannot stop the checks above.
    # Skipped for restricted sources: min / max would copy real values into quality.profile.
    if profile and entry.get("sharing") != "restricted":
        try:
            dq.profile_table(t)
        except Exception as e:
            print(f"  note: profile skipped ({str(e)[:150]})")


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------


def parse_args():
    p = argparse.ArgumentParser(description="Bronze QC for the socioeconomic domain")
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
        "--fail_on_error",
        default="true",
        choices=["true", "false"],
        help="Raise an error if any check is FAIL",
    )
    p.add_argument(
        "--profile",
        default="true",
        choices=["true", "false"],
        help="Also write a column profile of every table to quality.profile",
    )
    p.add_argument(
        "--job_run_id",
        default=None,
        help="Databricks job run id ({{job.run_id}}); a new id is made if omitted",
    )
    p.add_argument("--code_version", default=None, help="Git commit or tag of this code")
    args, _ = p.parse_known_args()
    return args


def main():
    args = parse_args()
    config_path = find_config(args.config_path)
    print(f"Config: {config_path}")
    cfg, sources = load_config(config_path)
    cfg["_sources"] = sources

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

    # DQRun writes qc_results, table_stats, profile and run_log on exit, then raises if any FAIL.
    with DQRun(
        layer="bronze",
        domain=DOMAIN,
        script_name=SCRIPT_NAME,
        job_run_id=args.job_run_id,
        source_keys=args.source_keys,
        fail_on_error=args.fail_on_error == "true",
        code_version=args.code_version,
    ) as dq:
        for key in keys:
            entry = sources[key]
            print(f"[{key}]")
            try:
                run_checks(dq, cfg, entry, profile=args.profile == "true")
            except Exception as e:
                # One source erroring is recorded as a failed check; the others still run.
                name, ctype, severity = CHECKS["B00"]
                dq.record(
                    "B00",
                    table_name=entry.get("bronze_table"),
                    source_key=entry["source_key"],
                    status="FAIL",
                    check_name=name,
                    check_type=ctype,
                    severity=severity,
                    detail=f"{type(e).__name__}: {e}",
                )


if __name__ == "__main__":
    main()
