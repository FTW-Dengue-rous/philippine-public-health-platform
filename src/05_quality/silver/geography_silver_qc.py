# =============================================================================
# Silver QC for PSGC geography (public_health.silver.geography_silver)
#
# Checks one persisted PSGC snapshot in Silver against its Bronze source and writes the
# results through dq_utils.DQRun (quality.qc_results + quality.run_log). Any FAIL makes the
# run raise at the end, so the tasks that depend on it do not start.
#
#   GS01  snapshot exists and has rows (Bronze and Silver)           FAIL
#   GS02  required geography fields complete                         FAIL
#   GS03  geography logical key unique (psgc_code + content_checksum) FAIL
#   GS04  non-null geographic levels accepted                        FAIL
#   GS05  Bronze to Silver row counts reconcile                      FAIL
#   GS06  PSGC hierarchy components reconstruct the code             WARN
#   GS07  psgc_code is 10 digits (added 2026-10-19)                   FAIL
#   GS08  null-level codes = psgc.silver_qc.null_level_codes          WARN
#         (added 2026-10-19; lists the codes when they differ)
#
# Settings (rule 2a, 2026-10-19): GS04's level list and GS08's codes come from
# psgc.silver_qc in sources_geography.yaml, the same list geography_silver.py SG03 reads.
#
# Which snapshot is checked
#   source_version  YAML psgc.version (Q2_2024), or --source_version
#   batch_id        --batch_id if given; otherwise the single batch Silver holds for that
#                   version. The run stops if Silver holds none or more than one.
#   Both tables are read at one fixed Delta version, so every check sees the same data.
#
# How to run (Databricks, Serverless or classic)
#   Python script task:  geography_silver_qc.py  [--job_run_id {{job.run_id}}]
#                        [--config_path ...] [--source_version ...] [--batch_id ...]
#                        [--fail_on_error true|false]
#   Notebook cell:       import runpy; runpy.run_path("<repo>/src/05_quality/silver/geography_silver_qc.py",
#                                                     run_name="__main__")
#   All parameters are optional; job/widget parameters of the same names work too.
#   Run after geography_silver.py.
#
# Changes from the notebook (2026-10-15)
#   - dq_utils.py and sources_geography.yaml are found from this file's location (and the
#     working directory), not from one person's /Workspace/Users/... folder.
#   - batch_id is no longer hard-coded: after a Bronze reload the old id no longer exists.
# =============================================================================

import argparse
import importlib.util
import os
import sys
from pathlib import Path

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F


# -----------------------------------------------------------------------------
# Find dq_utils.py (same search as the other QC scripts)
# -----------------------------------------------------------------------------
def _start_dirs():
    starts = []
    try:
        starts.append(os.path.dirname(os.path.abspath(__file__)))
    except NameError:
        pass
    starts.append(os.getcwd())
    return starts


def _add_dq_utils_to_path():
    # Looks in this file's folder and the working directory, up to five levels above each, and in
    # any *quality* folder there (e.g. src/05_quality/). Already importable: nothing to do.
    if importlib.util.find_spec("dq_utils") is not None:
        return None
    searched = []
    for start in _start_dirs():
        folder = start
        for _ in range(6):
            candidates = [folder]
            for base in (folder, os.path.join(folder, "src")):
                try:
                    candidates += [os.path.join(base, d) for d in sorted(os.listdir(base))
                                   if "quality" in d.lower() and os.path.isdir(os.path.join(base, d))]
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
        "the quality folder. Looked in:\n  " + "\n  ".join(dict.fromkeys(searched)))


_add_dq_utils_to_path()
from dq_utils import DQ_SCHEMA, DQRun  # noqa: E402

spark = SparkSession.builder.getOrCreate()


# -----------------------------------------------------------------------------
# Run parameters: command-line arguments (Python script task), then job/widget
# parameters (notebook task), then defaults.
# -----------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser(description="PSGC geography Silver QC")
    p.add_argument("--config_path", default=None, help="Default: config/sources_geography.yaml above this file")
    p.add_argument("--source_version", default=None, help="Default: YAML psgc.version")
    p.add_argument("--batch_id", default=None, help="Default: the single batch Silver holds for the version")
    p.add_argument("--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job")
    p.add_argument("--fail_on_error", default=None, help="true (default): raise if any check FAILs")
    p.add_argument("--dq_schema", default=None, help=f"Default {DQ_SCHEMA}")
    a, _ = p.parse_known_args()  # notebook kernels pass their own arguments
    return a


def _dbutils():
    handle = globals().get("dbutils")
    if handle is not None:
        return handle
    try:
        from databricks.sdk.runtime import dbutils as handle
        return handle
    except Exception:
        return None


def param(value, name, env=None, default=None):
    if value is not None and str(value).strip():
        return str(value).strip()
    handle = _dbutils()
    if handle is not None:
        try:
            widget_value = handle.widgets.get(name).strip()
            if widget_value:
                return widget_value
        except Exception:
            pass
    if env and os.environ.get(env, "").strip():
        return os.environ[env].strip()
    return default


def find_config(explicit, name="sources_geography.yaml"):
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise FileNotFoundError(f"Config file not found: {explicit}")
        return path.resolve()
    searched = []
    for start in map(Path, _start_dirs()):
        for folder in (start, *list(start.parents)[:5]):
            candidate = folder / "config" / name
            searched.append(str(candidate))
            if candidate.is_file():
                return candidate.resolve()
    raise FileNotFoundError(
        f"{name} not found. Pass --config_path (or the job parameter config_path). Looked in:\n  "
        + "\n  ".join(dict.fromkeys(searched)))


ARGS = parse_args()
CONFIG_PATH = find_config(param(ARGS.config_path, "config_path", env="PSGC_CONFIG_PATH"))
with CONFIG_PATH.open(encoding="utf-8") as file:
    config = yaml.safe_load(file)
psgc_cfg = config["sources"]["psgc"]

SILVER_TABLE = psgc_cfg["geography_silver_table"]
BRONZE_TABLE = psgc_cfg["bronze_table"]
SOURCE_VERSION = param(ARGS.source_version, "source_version", default=str(psgc_cfg["version"]))
REQUESTED_BATCH_ID = param(ARGS.batch_id, "batch_id")
JOB_RUN_ID = param(ARGS.job_run_id, "job_run_id")
FAIL_ON_ERROR = param(ARGS.fail_on_error, "fail_on_error", default="true").lower() == "true"
DQ_SCHEMA_NAME = param(ARGS.dq_schema, "dq_schema", default=DQ_SCHEMA)

# GS04 / GS08 settings. A missing list stops the run: the checks have no sensible default.
silver_qc_cfg = psgc_cfg.get("silver_qc") or {}
ACCEPTED_LEVELS = [str(v) for v in silver_qc_cfg.get("accepted_geographic_levels") or []]
NULL_LEVEL_CODES = sorted(str(v) for v in silver_qc_cfg.get("null_level_codes") or [])
if not ACCEPTED_LEVELS:
    raise ValueError(f"psgc.silver_qc.accepted_geographic_levels is missing in {CONFIG_PATH}")
if "null_level_codes" not in silver_qc_cfg:
    raise ValueError(f"psgc.silver_qc.null_level_codes is missing in {CONFIG_PATH} (use [] for none)")

print(f"Config         : {CONFIG_PATH}")
print(f"Silver table   : {SILVER_TABLE}")
print(f"Bronze table   : {BRONZE_TABLE}")
print(f"Source version : {SOURCE_VERSION}")
print(f"Batch ID       : {REQUESTED_BATCH_ID or '(single batch in Silver for this version)'}")


# Read one fixed Delta version so every check sees the same data.
def read_snapshot(table_name):
    version = int(spark.sql(f"DESCRIBE HISTORY {table_name} LIMIT 1").first()["version"])
    print(f"Checking {table_name}: Delta version {version}")
    return spark.read.format("delta").option("versionAsOf", version).table(table_name)


# Return the number calculated by a SQL query.
def count_sql(query):
    return int(spark.sql(query).first()[0])


# =============================================================================
# READ THE PERSISTED SILVER SNAPSHOT AND ITS BRONZE SOURCE.
# =============================================================================
silver_all = read_snapshot(SILVER_TABLE)
bronze_all = read_snapshot(BRONZE_TABLE)

# Require exactly one checksum + batch for this version; do not guess "latest".
version_rows = silver_all.filter(F.col("source_version") == SOURCE_VERSION)
if REQUESTED_BATCH_ID:
    version_rows = version_rows.filter(F.col("batch_id") == REQUESTED_BATCH_ID)
snapshots = version_rows.groupBy("content_checksum", "batch_id").count().collect()
if len(snapshots) != 1 or not snapshots[0]["content_checksum"]:
    found = [(r["content_checksum"], r["batch_id"], r["count"]) for r in snapshots]
    raise ValueError(
        f"{SILVER_TABLE} must hold exactly one snapshot for source_version={SOURCE_VERSION}"
        + (f" and batch_id={REQUESTED_BATCH_ID}" if REQUESTED_BATCH_ID else "")
        + f"; found {len(found)}: {found}. Run geography_silver.py, or pass --batch_id."
    )
CHECKSUM = snapshots[0]["content_checksum"]
BATCH_ID = snapshots[0]["batch_id"]
print(f"Snapshot       : checksum {CHECKSUM}, batch {BATCH_ID}")

silver = silver_all.filter(
    (F.col("source_version") == SOURCE_VERSION) & (F.col("content_checksum") == CHECKSUM)
)
bronze = bronze_all.filter(
    (F.col("source_version") == SOURCE_VERSION) & (F.col("content_checksum") == CHECKSUM)
)
silver.createOrReplaceTempView("beginner_geography_silver")
bronze.createOrReplaceTempView("beginner_geography_bronze")
silver_rows = silver.count()
bronze_rows = bronze.count()
print(f"Bronze rows: {bronze_rows}; Silver rows: {silver_rows}")

# =============================================================================
# CHECKS: DQRun saves the results, then raises if any check is FAIL.
# =============================================================================
with DQRun(
    layer="silver",
    domain="geography",
    script_name="geography_silver_qc.py",
    job_run_id=JOB_RUN_ID,
    source_keys="psgc",
    fail_on_error=FAIL_ON_ERROR,
    dq_schema=DQ_SCHEMA_NAME,
    spark=spark,
) as dq:
    # GS01: both tables must contain the requested snapshot.
    dq.record(
        "GS01",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="Snapshot exists and has rows",
        check_type="COMPLETENESS",
        severity="FAIL",
        status="PASS" if silver_rows > 0 and bronze_rows > 0 else "FAIL",
        observed=silver_rows,
        expected="Nonempty Bronze and Silver snapshots",
    )

    # GS02: required fields must not be null or blank.
    missing = count_sql("""
        SELECT COUNT(*) FROM beginner_geography_silver
        WHERE psgc_code IS NULL OR TRIM(psgc_code) = ''
           OR area_name IS NULL OR TRIM(area_name) = ''
           OR source_version IS NULL OR TRIM(source_version) = ''
           OR content_checksum IS NULL OR TRIM(content_checksum) = ''
           OR batch_id IS NULL OR TRIM(batch_id) = ''
           OR silver_processed_at IS NULL
    """)
    dq.record(
        "GS02",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="Required geography fields complete",
        check_type="COMPLETENESS",
        severity="FAIL",
        threshold=0,
        fail_count=missing,
        total_count=silver_rows,
    )

    # GS03: one row per PSGC code and source checksum.
    duplicates = count_sql("""
        SELECT COALESCE(SUM(n - 1), 0) FROM (
            SELECT COUNT(*) AS n FROM beginner_geography_silver
            GROUP BY psgc_code, content_checksum HAVING COUNT(*) > 1
        )
    """)
    dq.record(
        "GS03",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="Geography logical key unique",
        check_type="UNIQUENESS",
        severity="FAIL",
        threshold=0,
        fail_count=duplicates,
        total_count=silver_rows,
    )

    # GS04: null levels are allowed, matching the geography Silver notebook.
    accepted_sql = ", ".join("'" + level.replace("'", "''") + "'" for level in ACCEPTED_LEVELS)
    invalid_levels = count_sql(f"""
        SELECT COUNT(*) FROM beginner_geography_silver
        WHERE geographic_level IS NOT NULL
          AND geographic_level NOT IN ({accepted_sql})
    """)
    dq.record(
        "GS04",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="Non-null geographic levels accepted",
        check_type="VALIDITY",
        severity="FAIL",
        threshold=0,
        fail_count=invalid_levels,
        total_count=silver_rows,
        expected=", ".join(ACCEPTED_LEVELS),
    )

    # GS05: the transformation must preserve the number of source rows.
    dq.record(
        "GS05",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="Bronze to Silver row counts reconcile",
        check_type="RECONCILIATION",
        severity="FAIL",
        threshold=0,
        fail_count=abs(bronze_rows - silver_rows),
        total_count=bronze_rows,
        observed=silver_rows,
        expected=bronze_rows,
    )

    # GS06: hierarchy mismatch remains a WARN, as in the geography Silver notebook.
    hierarchy_issues = count_sql("""
        SELECT COUNT(*) FROM beginner_geography_silver
        WHERE region_code IS NOT NULL AND province_code IS NOT NULL
          AND municipality_code IS NOT NULL AND barangay_code IS NOT NULL
          AND psgc_code <> CONCAT(LPAD(region_code, 2, '0'), LPAD(province_code, 3, '0'),
                                 LPAD(municipality_code, 2, '0'), LPAD(barangay_code, 3, '0'))
    """)
    dq.record(
        "GS06",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="PSGC hierarchy components reconstruct code",
        check_type="CONSISTENCY",
        severity="WARN",
        threshold=0,
        fail_count=hierarchy_issues,
        total_count=silver_rows,
    )

    # GS07: downstream code reads levels from fixed positions of a 10-digit code
    # (population S55, admin boundaries, facilities). Null codes are GS02's job.
    bad_codes = count_sql("""
        SELECT COUNT(*) FROM beginner_geography_silver
        WHERE psgc_code IS NOT NULL AND NOT psgc_code RLIKE '^[0-9]{10}$'
    """)
    dq.record(
        "GS07",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="PSGC code is 10 digits",
        check_type="VALIDITY",
        severity="FAIL",
        threshold=0,
        fail_count=bad_codes,
        total_count=silver_rows,
        column_name="psgc_code",
    )

    # GS08: the null-level rows are the documented placeholders, never areas. A new release
    # that adds or drops one is listed here so the YAML (and anything that filters by level)
    # can be reviewed.
    observed_null_codes = sorted(
        r[0] for r in spark.sql("""
            SELECT DISTINCT psgc_code FROM beginner_geography_silver
            WHERE geographic_level IS NULL AND psgc_code IS NOT NULL
        """).collect()
    )
    unexpected = sorted(set(observed_null_codes) - set(NULL_LEVEL_CODES))
    absent = sorted(set(NULL_LEVEL_CODES) - set(observed_null_codes))
    dq.record(
        "GS08",
        table_name=SILVER_TABLE,
        source_key="psgc",
        batch_id=BATCH_ID,
        check_name="Null-level codes are the documented placeholders",
        check_type="CONSISTENCY",
        severity="WARN",
        status="PASS" if not unexpected and not absent else "WARN",
        fail_count=len(unexpected) + len(absent),
        total_count=len(observed_null_codes),
        observed=",".join(observed_null_codes) or "none",
        expected=",".join(NULL_LEVEL_CODES) or "none",
        column_name="geographic_level",
        detail=(f"new: {','.join(unexpected) or 'none'}; gone: {','.join(absent) or 'none'}. "
                "Update psgc.silver_qc.null_level_codes in sources_geography.yaml after review."),
    )

print(f"Geography Silver QC completed. Results: {DQ_SCHEMA_NAME}.qc_results")