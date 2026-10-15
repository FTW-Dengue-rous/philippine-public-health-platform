# =============================================================================
# Bronze QC for the admin_boundaries domain
#
# Runs after admin_boundaries Bronze loading. Reads committed raw Bronze at one
# Delta version; no source records are cleaned, filtered, corrected or written.
# Checks are SQL executed through spark.sql(). Python handles arguments,
# JSON handoff, batch selection, DQRun logging and the failure gate.
#
# Output through dq_utils.DQRun (public_health.quality):
#   qc_results, run_log, table_stats, and optional profile (--profile true).
#   A blocking failure stops the job before Silver. This script does not create
#   Silver or publish silver_handoff.json: use its successful Job task as the
#   dependency for Silver and the Delta version in its QC summary JSON.
#
# Checks:
#   HB00 QC execution / prerequisite error                  FAIL
#   HB01 total row count matches ingestion manifest         FAIL
#   HB02 row count per administrative level matches         FAIL
#   HB03 required lineage / fingerprint not null            FAIL
#   HB04 raw fingerprint unique per administrative level    FAIL
#   HB05 batch, dataset and source identity match           FAIL
#   HB06 raw fingerprint matches preserved JSON             FAIL
#   HB07 raw feature JSON parses                            FAIL
#   HB08 administrative p-code is not blank                 FAIL
#   HB09 administrative name is not blank                   FAIL
#   HB10 p-code unique per administrative level             FAIL
#   HB11 GeoJSON record type is Feature                     FAIL
#   HB12 geometry type is Polygon or MultiPolygon           FAIL
#   HB13 parent reference exists when parent layer included FAIL
#   HB14 required property keys present                     FAIL
#
# Property keys: matched case-insensitively (HDX COD-AB ships ADM1_PCODE / ADM1_EN;
# a staging step may have lowercased them). The name key accepts adm<n>_name or
# adm<n>_en. SQL is ANSI-mode safe (TRY_ELEMENT_AT, explicit casts) for Serverless.
#
# Names are fixed per check code. Snapshot and batch evidence go in detail.
# Checks cannot be skipped or downgraded in this batch-approval script.
# --fail_on_error false is diagnostic only: no passing summary on failed checks.
# --profile defaults to false because raw JSON may contain large geometry values.
#
# How to run (Databricks Python script task on Serverless)
#   --bronze_handoff_path /Volumes/.../_runs/<run-id>/bronze_handoff.json
#   --fail_on_error true --profile false
# Optional: --job_run_id <job-run-id> --code_version <git-sha>
# Optional: --dq_utils_path /Workspace/.../src/05_quality/dq_utils.py (or its folder).
#   Not needed normally: dq_utils.py is found automatically, and a wrong path
#   falls back to that search instead of failing.
# No hardcoded batch path. Job tasks use command-line arguments only; widgets are
# read only when the file is opened interactively as a notebook (same names as
# the arguments, created on first run). Requires dq_utils.py and the existing
# quality tables to be provisioned. Configure dependencies in the Job.
# The shared dq_utils module must itself support Serverless (no cache/RDD APIs).
# Existing batch QC summary and silver handoff are invalidated before checking,
# preserving the original stale-marker protection. No Bronze rows are changed.
# Runs on Python 3.10+ (no datetime.UTC dependency).
# =============================================================================
import os
os.environ["BRONZE_HANDOFF_PATH"] = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/admin_boundaries/_runs/0b68b72b-7d94-4e0f-ab5b-221f3978acf2/bronze_handoff.json"

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

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


DOMAIN = "admin_boundaries"
SOURCE_KEY = "hdx_phl_admin"
SCRIPT_NAME = "admin_boundaries_bronze_qc.py"
LOADER_VERSION = "2026-10-15.3"
BRONZE_TABLE = "public_health.bronze.admin_boundaries_bronze"
CHECKS = {
    "HB00": ("QC ran without error", "EXECUTION", "FAIL"),
    "HB01": ("Total row reconciliation", "RECONCILIATION", "FAIL"),
    "HB02": ("Administrative-level row reconciliation", "RECONCILIATION", "FAIL"),
    "HB03": ("Required lineage and fingerprint completeness", "COMPLETENESS", "FAIL"),
    "HB04": ("Record fingerprint uniqueness by administrative level", "UNIQUENESS", "FAIL"),
    "HB05": ("Batch identity consistency", "CONSISTENCY", "FAIL"),
    "HB06": ("Raw record fingerprint integrity", "CONSISTENCY", "FAIL"),
    "HB07": ("Raw feature JSON parsing", "VALIDITY", "FAIL"),
    "HB08": ("Nonblank administrative p-code", "COMPLETENESS", "FAIL"),
    "HB09": ("Nonblank administrative name", "COMPLETENESS", "FAIL"),
    "HB10": ("P-code uniqueness within administrative level", "UNIQUENESS", "FAIL"),
    "HB11": ("GeoJSON feature type", "VALIDITY", "FAIL"),
    "HB12": ("Polygon geometry type", "VALIDITY", "FAIL"),
    "HB13": ("Administrative parent reference", "CONSISTENCY", "FAIL"),
    "HB14": ("Required source property keys", "SCHEMA", "FAIL"),
}
DATA_CHECK_IDS = sorted(set(CHECKS) - {"HB00"})
REQUIRED_COLUMNS = [
    "source_feature_json",
    "properties_json",
    "_source_version",
    "_batch_id",
    "_dataset_id",
    "_source_key",
    "_admin_level",
    "_record_sha256",
]

# /Volumes/<catalog>/<schema>/<volume> is 5 path parts; a file inside it is at least 6.
_VOLUME_FILE_PARTS = 6


# -----------------------------------------------------------------------------
# Arguments and input contract
# -----------------------------------------------------------------------------


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Admin boundaries Bronze QC")
    parser.add_argument(
        "--bronze_handoff_path",
        required=True,
        help="Full /Volumes path to the successful load's bronze_handoff.json",
    )
    parser.add_argument(
        "--fail_on_error",
        choices=("true", "false"),
        default="true",
        help="false is diagnostic only; failed QC must not promote to Silver",
    )
    parser.add_argument("--profile", choices=("true", "false"), default="false")
    parser.add_argument("--job_run_id", default=None)
    parser.add_argument("--code_version", default=None)
    parser.add_argument(
        "--dq_utils_path",
        default=None,
        help="Optional full path to dq_utils.py if auto-discovery cannot find it",
    )
    return parser.parse_args(argv)


def safe_handoff_path(value):
    """Validate the bronze_handoff.json path shape only; existence is checked by load_handoff."""
    parts = PurePosixPath(value).parts
    if len(parts) < _VOLUME_FILE_PARTS or parts[:2] != ("/", "Volumes") or ".." in parts:
        raise ValueError("Use a safe /Volumes path to bronze_handoff.json")
    path = Path(value)
    if path.name != "bronze_handoff.json":
        raise ValueError("Expected bronze_handoff.json")
    return path


def load_handoff(value):
    path = safe_handoff_path(value)
    if not path.is_file():
        raise FileNotFoundError(f"bronze_handoff.json not found: {path}")
    h = json.loads(path.read_text(encoding="utf-8"))
    for key in (
        "source_key",
        "dataset_id",
        "source_version",
        "batch_id",
        "bronze_table",
        "expected_by_level",
    ):
        if not h.get(key):
            raise ValueError(f"Missing handoff field: {key}")
    if h.get("status") != "bronze_loaded_pending_qc":
        raise ValueError("Bronze load is not ready for QC")
    if h["source_key"] != SOURCE_KEY:
        raise ValueError(f"Expected source_key {SOURCE_KEY}, got {h['source_key']!r}")
    if h["bronze_table"] != BRONZE_TABLE:
        raise ValueError(f"Expected Bronze destination: {BRONZE_TABLE}")
    if not isinstance(h["source_version"], str) or not re.fullmatch(
        r"[a-f0-9]{64}", h["source_version"]
    ):
        raise ValueError("Invalid SHA-256 source version")
    if h["batch_id"] != f"{h['dataset_id']}:{h['source_version']}":
        raise ValueError("Batch identity mismatch")
    if not isinstance(h["expected_by_level"], dict):
        raise ValueError("expected_by_level must be an object of level -> rows")
    expected = {int(k): int(v) for k, v in h["expected_by_level"].items()}
    if not expected or any(v <= 0 for v in expected.values()):
        raise ValueError("Expected layer counts must be positive")
    if len(expected) != len(h["expected_by_level"]):
        raise ValueError("Duplicate administrative levels in the handoff")
    return path, h, expected


# -----------------------------------------------------------------------------
# SQL checks for one committed batch
# -----------------------------------------------------------------------------
# Views the Python side creates before these run:
#   admin_boundaries_qc_batch     Bronze rows of this source_version at one Delta version
#   admin_boundaries_qc_expected  admin_level INT, expected_rows LONG (from the handoff)
#   admin_boundaries_qc_context   one row: source_key, dataset, source_version, batch_id, ...
#
# ANSI-mode notes (Serverless default): TRY_ELEMENT_AT returns NULL for a missing map key
# where ELEMENT_AT raises; INT -> STRING casts in CONCAT are explicit.

SQL_STATEMENTS = (
    r"""CREATE OR REPLACE TEMP VIEW admin_boundaries_qc_parsed AS
SELECT *,
       FROM_JSON(source_feature_json,
         'STRUCT<type:STRING,properties:MAP<STRING,STRING>,geometry:STRUCT<type:STRING>,_corrupt_record:STRING>',
         MAP('mode','PERMISSIVE','columnNameOfCorruptRecord','_corrupt_record')) AS parsed,
       TRANSFORM_KEYS(FROM_JSON(properties_json, 'MAP<STRING,STRING>'), (k, v) -> LOWER(k)) AS props,
       CAST(_admin_level AS STRING) AS level_str,
       CAST(_admin_level - 1 AS STRING) AS parent_level_str
FROM admin_boundaries_qc_batch""",
    r"""CREATE OR REPLACE TEMP VIEW admin_boundaries_qc_fields AS
SELECT *,
       TRIM(TRY_ELEMENT_AT(props, CONCAT('adm', level_str, '_pcode'))) AS pcode,
       TRIM(COALESCE(TRY_ELEMENT_AT(props, CONCAT('adm', level_str, '_name')),
                     TRY_ELEMENT_AT(props, CONCAT('adm', level_str, '_en')))) AS area_name,
       TRIM(TRY_ELEMENT_AT(props, CONCAT('adm', parent_level_str, '_pcode'))) AS parent_pcode,
       ARRAY_CONTAINS(MAP_KEYS(props), CONCAT('adm', level_str, '_pcode')) AS has_pcode_key,
       (ARRAY_CONTAINS(MAP_KEYS(props), CONCAT('adm', level_str, '_name'))
        OR ARRAY_CONTAINS(MAP_KEYS(props), CONCAT('adm', level_str, '_en'))) AS has_name_key,
       ARRAY_CONTAINS(MAP_KEYS(props), CONCAT('adm', parent_level_str, '_pcode')) AS has_parent_pcode_key
FROM admin_boundaries_qc_parsed""",
    r"""CREATE OR REPLACE TEMP VIEW admin_boundaries_qc_metrics AS
WITH totals AS (
  SELECT COUNT(*) AS actual_rows FROM admin_boundaries_qc_batch
), expected_total AS (
  SELECT SUM(expected_rows) AS expected_rows FROM admin_boundaries_qc_expected
), actual_levels AS (
  SELECT _admin_level AS admin_level, COUNT(*) AS actual_rows
  FROM admin_boundaries_qc_batch GROUP BY _admin_level
), level_comparison AS (
  SELECT COALESCE(a.actual_rows, 0) AS actual_rows,
         COALESCE(e.expected_rows, 0) AS expected_rows
  FROM actual_levels a FULL OUTER JOIN admin_boundaries_qc_expected e
    ON a.admin_level <=> e.admin_level
), duplicate_groups AS (
  SELECT COUNT(*) AS affected_rows FROM admin_boundaries_qc_batch
  GROUP BY _admin_level, _record_sha256 HAVING COUNT(*) > 1
), duplicate_pcode_groups AS (
  SELECT COUNT(*) AS affected_rows FROM admin_boundaries_qc_fields
  WHERE pcode IS NOT NULL AND pcode <> ''
  GROUP BY _admin_level, pcode HAVING COUNT(*) > 1
), parent_pcodes AS (
  SELECT DISTINCT _admin_level AS admin_level, pcode
  FROM admin_boundaries_qc_fields
  WHERE pcode IS NOT NULL AND pcode <> ''
), with_parent_layer AS (
  -- Only levels whose parent layer is in the manifest; expected.admin_level is unique, so
  -- the inner join never multiplies rows.
  SELECT c._admin_level, c.parent_pcode, p.pcode AS found_parent_pcode
  FROM admin_boundaries_qc_fields c
  JOIN admin_boundaries_qc_expected e ON e.admin_level = c._admin_level - 1
  LEFT JOIN parent_pcodes p
    ON p.admin_level = c._admin_level - 1 AND p.pcode = c.parent_pcode
)
SELECT 'HB01' AS check_id, 'Total row reconciliation' AS check_name,
       ABS(a.actual_rows - e.expected_rows) AS fail_count,
       e.expected_rows AS total_count,
       CONCAT('Expected=', CAST(e.expected_rows AS STRING), ', actual=', CAST(a.actual_rows AS STRING)) AS detail
FROM totals a CROSS JOIN expected_total e
UNION ALL
SELECT 'HB02', 'Administrative-level row reconciliation',
       COUNT_IF(actual_rows <> expected_rows), COUNT(*),
       'Compare committed Bronze counts against the manifest for every level'
FROM level_comparison
UNION ALL
SELECT 'HB03', 'Required lineage and fingerprint completeness',
       COUNT_IF(_record_sha256 IS NULL OR _batch_id IS NULL OR _dataset_id IS NULL
                OR _source_key IS NULL OR _admin_level IS NULL), COUNT(*),
       'Required technical metadata must not be null'
FROM admin_boundaries_qc_batch
UNION ALL
SELECT 'HB04', 'Record fingerprint uniqueness by administrative level',
       COALESCE((SELECT SUM(affected_rows) FROM duplicate_groups), 0), actual_rows,
       'Counts all rows belonging to duplicate fingerprint groups'
FROM totals
UNION ALL
SELECT 'HB05', 'Batch identity consistency',
       COUNT_IF(NOT (b._batch_id <=> c.batch_id)
                OR NOT (b._dataset_id <=> c.dataset)
                OR NOT (b._source_key <=> c.source_key)), COUNT(*),
       'Records must match the handoff batch, dataset and source'
FROM admin_boundaries_qc_batch b CROSS JOIN admin_boundaries_qc_context c
UNION ALL
SELECT 'HB06', 'Raw record fingerprint integrity',
       COUNT_IF(NOT (_record_sha256 <=> SHA2(source_feature_json, 256))), COUNT(*),
       'Stored fingerprint must match the preserved raw feature JSON'
FROM admin_boundaries_qc_batch
UNION ALL
SELECT 'HB07', 'Raw feature JSON parsing',
       COUNT_IF(parsed IS NULL OR parsed._corrupt_record IS NOT NULL OR props IS NULL), COUNT(*),
       'Raw feature and properties JSON must parse into the expected GeoJSON structure'
FROM admin_boundaries_qc_fields
UNION ALL
SELECT 'HB08', 'Nonblank administrative p-code',
       COUNT_IF(pcode IS NULL OR pcode = ''), COUNT(*),
       'Each record requires its own administrative-level p-code'
FROM admin_boundaries_qc_fields
UNION ALL
SELECT 'HB09', 'Nonblank administrative name',
       COUNT_IF(area_name IS NULL OR area_name = ''), COUNT(*),
       'Each record requires its own administrative-level name (adm<n>_name or adm<n>_en)'
FROM admin_boundaries_qc_fields
UNION ALL
SELECT 'HB10', 'P-code uniqueness within administrative level',
       COALESCE((SELECT SUM(affected_rows) FROM duplicate_pcode_groups), 0), actual_rows,
       'Counts all rows in duplicate nonblank p-code groups'
FROM totals
UNION ALL
SELECT 'HB11', 'GeoJSON feature type',
       COUNT_IF(NOT (parsed.type <=> 'Feature')), COUNT(*),
       'Every raw record must have type Feature'
FROM admin_boundaries_qc_fields
UNION ALL
SELECT 'HB12', 'Polygon geometry type',
       COUNT_IF(parsed.geometry.type IS NULL OR parsed.geometry.type NOT IN ('Polygon','MultiPolygon')),
       COUNT(*), 'Geometry type must be Polygon or MultiPolygon; topology validation belongs to Silver'
FROM admin_boundaries_qc_fields
UNION ALL
SELECT 'HB13', 'Administrative parent reference',
       COUNT_IF(found_parent_pcode IS NULL), COUNT(*),
       'Validate a parent only when its administrative level is included in the source'
FROM with_parent_layer
UNION ALL
SELECT 'HB14', 'Required source property keys',
       COUNT_IF(NOT COALESCE(c.has_pcode_key, FALSE)
         OR NOT COALESCE(c.has_name_key, FALSE)
         OR (e.admin_level IS NOT NULL AND NOT COALESCE(c.has_parent_pcode_key, FALSE))),
       COUNT(*), 'Check own p-code/name keys and parent p-code key when the parent layer is included'
FROM admin_boundaries_qc_fields c
LEFT JOIN admin_boundaries_qc_expected e ON e.admin_level = c._admin_level - 1""",
)


def run_checks(spark, dq, h, expected, profile):
    if not spark.catalog.tableExists(BRONZE_TABLE):
        raise ValueError("Bronze table does not exist")
    version = int(spark.sql(f"DESCRIBE HISTORY {BRONZE_TABLE} LIMIT 1").first()["version"])
    snapshot = spark.sql(f"SELECT * FROM {BRONZE_TABLE} VERSION AS OF {version}")
    missing = sorted(set(REQUIRED_COLUMNS) - set(snapshot.columns))
    if missing:
        raise ValueError(f"Required Bronze columns are missing: {missing}")
    snapshot.filter(snapshot["_source_version"] == h["source_version"]).createOrReplaceTempView(
        "admin_boundaries_qc_batch"
    )
    spark.createDataFrame(
        [(int(k), int(v)) for k, v in sorted(expected.items())],
        "admin_level INT, expected_rows LONG",
    ).createOrReplaceTempView("admin_boundaries_qc_expected")
    spark.createDataFrame(
        [
            (
                h["source_key"],
                h["dataset_id"],
                h["source_version"],
                h["batch_id"],
                BRONZE_TABLE,
                int(version),
            )
        ],
        "source_key STRING, dataset STRING, source_version STRING, batch_id STRING, "
        "table_name STRING, bronze_delta_version LONG",
    ).createOrReplaceTempView("admin_boundaries_qc_context")
    # Each view statement is independent of data modification; source rows stay raw.
    for statement in SQL_STATEMENTS:
        statement = statement.strip().rstrip(";")
        if statement:
            spark.sql(statement)
    results = spark.sql("SELECT * FROM admin_boundaries_qc_metrics ORDER BY check_id").collect()
    produced = sorted(r["check_id"] for r in results)
    if produced != DATA_CHECK_IDS:
        raise RuntimeError(
            f"QC did not produce exactly the required {len(DATA_CHECK_IDS)} checks: "
            f"expected={DATA_CHECK_IDS}; produced={produced}"
        )
    failures = []
    for r in results:
        check_id = r["check_id"]
        name, kind, severity = CHECKS[check_id]
        fail_count = int(r["fail_count"] or 0)
        total_count = int(r["total_count"] or 0)
        status = "PASS" if fail_count == 0 else severity
        dq.record(
            check_id,
            table_name=BRONZE_TABLE,
            source_key=h["source_key"],
            batch_id=h["batch_id"],
            check_name=name,
            check_type=kind,
            severity=severity,
            status=status,
            fail_count=fail_count,
            total_count=total_count,
            detail=f"Delta version={version}; source_version={h['source_version']}; {r['detail']}",
        )
        if status == "FAIL":
            failures.append(check_id)
    try:
        dq.capture_table_stats(BRONZE_TABLE)
    except Exception as error:
        print(f"note: table statistics skipped ({str(error)[:150]})")
    if profile:
        try:
            dq.profile_table(BRONZE_TABLE)
        except Exception as error:
            print(f"note: column profile skipped ({str(error)[:150]})")
    return version, failures


# -----------------------------------------------------------------------------
# Run and persist audit before applying the Silver gate
# -----------------------------------------------------------------------------


NOTEBOOK_PARAM_DEFAULTS = {
    "bronze_handoff_path": "",
    "fail_on_error": "true",
    "profile": "false",
    "job_run_id": "",
    "code_version": "",
    "dq_utils_path": "",
}


def _running_as_notebook():
    # When a .py file is opened as an interactive notebook, the IPython launcher
    # (db_ipykernel_launcher.py) supplies arguments unrelated to this application.
    return "ipykernel" in Path(sys.argv[0]).name


def _notebook_argv(spark):
    """Interactive notebook only: build argv from widgets so the script stays runnable.

    A Job task passes real command-line arguments and never reaches this. Widgets are
    created with defaults the first time; an existing widget keeps its current value.
    """
    argv = []
    # Escape hatch when widgets are unavailable: environment variables named after the
    # arguments in upper case, e.g. os.environ["BRONZE_HANDOFF_PATH"] = "/Volumes/.../bronze_handoff.json"
    for name in NOTEBOOK_PARAM_DEFAULTS:
        value = (os.environ.get(name.upper()) or "").strip()
        if value:
            argv += [f"--{name}", value]
    if "--bronze_handoff_path" in argv:
        return argv

    dbutils = _get_dbutils(spark)
    if dbutils is None:
        print("note: dbutils is not reachable from this script; widgets were not created.")
        return argv
    argv = []
    for name, default in NOTEBOOK_PARAM_DEFAULTS.items():
        try:
            dbutils.widgets.text(name, default)
            value = (dbutils.widgets.get(name) or "").strip()
        except Exception as error:
            print(f"note: widget {name!r} unavailable ({type(error).__name__}: {str(error)[:120]})")
            value = ""
        if value:
            argv += [f"--{name}", value]
    return argv


def _get_dbutils(spark):
    """Return a dbutils handle, or None. Tries the notebook global, the Serverless SDK, then DBUtils."""
    handle = globals().get("dbutils")
    if handle is not None:
        return handle
    try:
        from databricks.sdk.runtime import dbutils as sdk_dbutils  # Serverless / newer runtimes

        return sdk_dbutils
    except Exception:
        pass
    try:
        from pyspark.dbutils import DBUtils  # classic runtimes

        return DBUtils(spark)
    except Exception:
        return None


def main(argv=None):
    spark = SparkSession.builder.getOrCreate()
    if argv is None and _running_as_notebook():
        argv = _notebook_argv(spark)
        if "--bronze_handoff_path" not in argv:
            raise ValueError(
                "Running as a notebook: fill the 'bronze_handoff_path' widget at the top "
                "(full /Volumes path to bronze_handoff.json) and rerun. "
                "As a Job task, pass --bronze_handoff_path instead."
            )
    args = parse_args(argv)
    # --dq_utils_path is optional. A file or its folder is accepted; a wrong or stale path
    # (e.g. another person's /Workspace/Users/... folder, or an old widget value) falls back
    # to the automatic search instead of stopping the run.
    helper = Path(args.dq_utils_path).expanduser() if args.dq_utils_path else None
    if helper is not None and helper.is_dir():
        helper = helper / "dq_utils.py"
    if helper is not None and helper.name == "dq_utils.py" and helper.is_file():
        sys.path.insert(0, str(helper.resolve().parent))
    else:
        if helper is not None:
            print(f"note: --dq_utils_path {args.dq_utils_path} has no dq_utils.py; "
                  "searching this repo's quality folder instead")
        _add_dq_utils_to_path()
    from dq_utils import DQRun

    print(f"Admin boundaries Bronze QC {LOADER_VERSION}")
    # Validate the path shape before touching anything beside it.
    path = safe_handoff_path(args.bronze_handoff_path)
    # Remove earlier outputs first: a failed rerun must not leave a passing marker.
    summary_path = path.parent / "bronze_qc_summary.json"
    summary_path.unlink(missing_ok=True)
    (path.parent / "silver_handoff.json").unlink(missing_ok=True)
    h = {}
    failures = []
    version = None
    # Leave automatic raising off so DQRun flushes all audit rows before our gate.
    # The script enforces fail_on_error after the context manager has completed.
    with DQRun(
        layer="bronze",
        domain=DOMAIN,
        script_name=SCRIPT_NAME,
        job_run_id=args.job_run_id,
        source_keys=SOURCE_KEY,
        fail_on_error=False,
        code_version=args.code_version,
        spark=spark,
    ) as dq:
        try:
            path, h, expected = load_handoff(args.bronze_handoff_path)
            version, failures = run_checks(spark, dq, h, expected, args.profile == "true")
        except Exception as error:
            failures = ["HB00"]
            name, kind, severity = CHECKS["HB00"]
            dq.record(
                "HB00",
                table_name=BRONZE_TABLE,
                source_key=h.get("source_key", SOURCE_KEY),
                batch_id=h.get("batch_id"),
                check_name=name,
                check_type=kind,
                severity=severity,
                status="FAIL",
                fail_count=1,
                total_count=1,
                detail=f"{type(error).__name__}: {error}",
            )
    # Write only after the shared DQRun audit flush succeeds.
    summary = {
        "status": "FAIL" if failures else "PASS",
        "domain": DOMAIN,
        "layer": "bronze",
        "bronze_table": BRONZE_TABLE,
        "source_key": h.get("source_key"),
        "dataset_id": h.get("dataset_id"),
        "source_version": h.get("source_version"),
        "batch_id": h.get("batch_id"),
        "bronze_delta_version": version,
        "failed_checks": failures,
        "expected_check_ids": DATA_CHECK_IDS,
        "job_run_id": args.job_run_id,
        "quality_run_id": str(dq.run_id) if getattr(dq, "run_id", None) is not None else None,
        "quality_validation_id": (
            str(dq.validation_id) if getattr(dq, "validation_id", None) is not None else None
        ),
        "qc_version": LOADER_VERSION,
        "executed_at": datetime.now(timezone.utc).isoformat(),
    }
    temporary = summary_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    temporary.replace(summary_path)
    print("QC summary:", summary_path)
    if failures:
        if args.fail_on_error == "true":
            raise RuntimeError("Admin boundaries Bronze QC failed: " + ", ".join(failures))
        print("Diagnostic mode: QC failed. Do not continue to Silver.")
    else:
        print("Admin boundaries Bronze QC passed. Silver must read the validated Delta version.")


if __name__ == "__main__":
    main()