# =============================================================================
# Silver QC for HDX administrative boundaries (public_health.silver.admin_boundaries_silver)
#
# Checks one persisted HDX boundary snapshot in Silver against its Bronze source and the PSGC
# reference it was reconciled to, and writes the results through dq_utils.DQRun
# (quality.qc_results + quality.run_log). Any FAIL makes the run raise at the end.
#
#   AS01   snapshot exists and has rows (Bronze and Silver)                     FAIL
#   AS02   required boundary fields complete (psgc_code excluded: special
#          structures keep a null code)                                         FAIL
#   AS03   boundary logical key unique (admin_level + boundary_pcode + version)  FAIL
#   AS04   admin level 1/2/3 and Polygon/MultiPolygon only                       FAIL
#   ASB05  Bronze and Silver total rows reconcile                                FAIL
#   AS07   area positive, latitude -90..90, longitude -180..180                 FAIL
#   AS08   PSGC match status valid; null code only for documented special
#          structures                                                          FAIL
#   AS09   recorded PSGC reference snapshot exists and each code is at the
#          right geographic level                                               FAIL
#
# Which snapshot is checked
#   source_version  --source_version if given; otherwise the single HDX version in Silver
#   batch_id        --batch_id if given; otherwise the single batch Silver holds for it.
#   The run stops if Silver holds none or more than one. All tables are read at one fixed
#   Delta version, so every check sees the same data.
#
# How to run (Databricks, Serverless or classic)
#   Python script task:  admin_boundaries_silver_qc.py  [--job_run_id {{job.run_id}}]
#                        [--config_path ...] [--source_version ...] [--batch_id ...]
#                        [--fail_on_error true|false]
#   Notebook cell:       import runpy; runpy.run_path("<repo>/src/05_quality/silver/admin_boundaries_silver_qc.py",
#                                                     run_name="__main__")
#   All parameters are optional; job/widget parameters of the same names work too.
#   Run after admin_boundaries_silver.py.
#
# Changes from the notebook (2026-10-15)
#   - dq_utils.py is found from this file's location and the working directory. The notebook
#     only looked next to __file__, which a notebook does not have (No module named 'dq_utils').
#   - Table names come from config/sources_geography.yaml; source version and batch are found
#     instead of hard-coded.
#
# Rule 2a (2026-10-19)
#   - AS04 reads the admin levels (hdx_phl_admin.required_levels) and geometry types
#     (silver_qc.accepted_geometry_types) from the YAML the build uses, instead of typed lists.
#   - AS08 reads the special-structure names from silver_qc.special_structures, the same lists
#     admin_boundaries_silver.py classifies with.
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
from dq_utils import DQ_SCHEMA, DQRun  # noqa: E402

spark = SparkSession.builder.getOrCreate()


# -----------------------------------------------------------------------------
# Run parameters: command-line arguments (Python script task), then job/widget
# parameters (notebook task), then defaults.
# -----------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser(description="HDX administrative boundaries Silver QC")
    p.add_argument(
        "--config_path", default=None, help="Default: config/sources_geography.yaml above this file"
    )
    p.add_argument(
        "--source_version", default=None, help="Default: the single HDX source version in Silver"
    )
    p.add_argument(
        "--batch_id", default=None, help="Default: the single batch Silver holds for that version"
    )
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
        + "\n  ".join(dict.fromkeys(searched))
    )


ARGS = parse_args()
CONFIG_PATH = find_config(param(ARGS.config_path, "config_path", env="PSGC_CONFIG_PATH"))
with CONFIG_PATH.open(encoding="utf-8") as file:
    config = yaml.safe_load(file)
hdx_cfg = config["sources"]["hdx_phl_admin"]
psgc_cfg = config["sources"]["psgc"]

SILVER_TABLE = hdx_cfg["admin_boundaries_silver_table"]
BRONZE_TABLE = hdx_cfg["bronze_table"]
PSGC_TABLE = psgc_cfg["geography_silver_table"]
REQUESTED_VERSION = param(ARGS.source_version, "source_version")
REQUESTED_BATCH_ID = param(ARGS.batch_id, "batch_id")
JOB_RUN_ID = param(ARGS.job_run_id, "job_run_id")
FAIL_ON_ERROR = param(ARGS.fail_on_error, "fail_on_error", default="true").lower() == "true"
DQ_SCHEMA_NAME = param(ARGS.dq_schema, "dq_schema", default=DQ_SCHEMA)


# AS04 / AS08 settings from the YAML (same values the build uses). A missing list stops the run.
def sql_list(values):
    return ", ".join("'" + str(v).replace("'", "''") + "'" for v in values)


hdx_silver_qc = hdx_cfg.get("silver_qc") or {}
ADMIN_LEVELS = [str(v) for v in hdx_cfg.get("required_levels") or []]
GEOMETRY_TYPES = [str(v) for v in hdx_silver_qc.get("accepted_geometry_types") or []]
_special = hdx_silver_qc.get("special_structures") or {}
SPECIAL_ADM2_PREFIXES = [str(v) for v in _special.get("adm2_name_prefixes") or []]
SPECIAL_ADM2_NAMES = [str(v) for v in _special.get("adm2_names") or []]
SPECIAL_ADM3_PARENTS = [str(v) for v in _special.get("adm3_parent_adm2_names") or []]
for _name, _values in (
    ("hdx_phl_admin.required_levels", ADMIN_LEVELS),
    ("hdx_phl_admin.silver_qc.accepted_geometry_types", GEOMETRY_TYPES),
    (
        "hdx_phl_admin.silver_qc.special_structures",
        SPECIAL_ADM2_PREFIXES + SPECIAL_ADM2_NAMES + SPECIAL_ADM3_PARENTS,
    ),
):
    if not _values:
        raise ValueError(f"{_name} is missing or empty in {CONFIG_PATH}")

# SQL for "this row is a documented special structure" (AS08)
_adm2_terms = [
    f"boundary_name LIKE '{p.replace(chr(39), chr(39) * 2)}%'" for p in SPECIAL_ADM2_PREFIXES
]
if SPECIAL_ADM2_NAMES:
    _adm2_terms.append(f"boundary_name IN ({sql_list(SPECIAL_ADM2_NAMES)})")
_special_terms = []
if _adm2_terms:
    _special_terms.append(f"(admin_level = '2' AND ({' OR '.join(_adm2_terms)}))")
if SPECIAL_ADM3_PARENTS:
    _special_terms.append(
        f"(admin_level = '3' AND adm2_name IN ({sql_list(SPECIAL_ADM3_PARENTS)}))"
    )
SPECIAL_STRUCTURE_SQL = " OR ".join(_special_terms)

print(f"Config          : {CONFIG_PATH}")
print(f"Silver table    : {SILVER_TABLE}")
print(f"Bronze table    : {BRONZE_TABLE}")
print(f"PSGC reference  : {PSGC_TABLE}")


# Read one fixed Delta version so every check sees the same data.
def read_snapshot(table_name):
    version = int(spark.sql(f"DESCRIBE HISTORY {table_name} LIMIT 1").first()["version"])
    print(f"Checking {table_name}: Delta version {version}")
    return spark.read.format("delta").option("versionAsOf", version).table(table_name)


# Return the number calculated by a SQL query.
def count_sql(query):
    return int(spark.sql(query).first()[0])


# =============================================================================
# READ THE PERSISTED SNAPSHOTS.
# =============================================================================
silver_all = read_snapshot(SILVER_TABLE)
bronze_all = read_snapshot(BRONZE_TABLE)
psgc = read_snapshot(PSGC_TABLE)

# Require exactly one source version + batch in Silver; do not guess "latest".
candidates = silver_all
if REQUESTED_VERSION:
    candidates = candidates.filter(F.col("source_version") == REQUESTED_VERSION)
if REQUESTED_BATCH_ID:
    candidates = candidates.filter(F.col("batch_id") == REQUESTED_BATCH_ID)
snapshots = candidates.groupBy("source_version", "batch_id").count().collect()
if len(snapshots) != 1:
    found = [(r["source_version"], r["batch_id"], r["count"]) for r in snapshots]
    raise ValueError(
        f"{SILVER_TABLE} must hold exactly one snapshot"
        + (f" for source_version={REQUESTED_VERSION}" if REQUESTED_VERSION else "")
        + (f" and batch_id={REQUESTED_BATCH_ID}" if REQUESTED_BATCH_ID else "")
        + f"; found {len(found)}: {found}. Run admin_boundaries_silver.py, "
        "or pass --source_version / --batch_id."
    )
SOURCE_VERSION = snapshots[0]["source_version"]
BATCH_ID = snapshots[0]["batch_id"]
print(f"Source version  : {SOURCE_VERSION}")
print(f"Batch ID        : {BATCH_ID}")

silver = silver_all.filter(F.col("source_version") == SOURCE_VERSION)
bronze = bronze_all.filter(F.col("_source_version") == SOURCE_VERSION)
silver.createOrReplaceTempView("beginner_boundaries_silver")
psgc.createOrReplaceTempView("beginner_boundaries_psgc")
silver_rows = silver.count()
bronze_rows = bronze.count()
print(f"Bronze rows: {bronze_rows}; Silver rows: {silver_rows}")

# =============================================================================
# CHECKS: DQRun saves the results, then raises if any check is FAIL.
# =============================================================================
with DQRun(
    layer="silver",
    domain="admin_boundaries",
    script_name="admin_boundaries_silver_qc.py",
    job_run_id=JOB_RUN_ID,
    source_keys="hdx_phl_admin",
    fail_on_error=FAIL_ON_ERROR,
    dq_schema=DQ_SCHEMA_NAME,
    spark=spark,
) as dq:
    # AS01: both source and target snapshots must contain records.
    dq.record(
        "AS01",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="Snapshot exists and has rows",
        check_type="COMPLETENESS",
        severity="FAIL",
        status="PASS" if silver_rows > 0 and bronze_rows > 0 else "FAIL",
        observed=silver_rows,
        expected="Nonempty Bronze and Silver snapshots",
    )

    # AS02: PSGC code is not included here because special structures may have null codes.
    missing = count_sql("""
        SELECT COUNT(*) FROM beginner_boundaries_silver
        WHERE admin_level IS NULL OR TRIM(admin_level) = ''
           OR boundary_pcode IS NULL OR TRIM(boundary_pcode) = ''
           OR boundary_name IS NULL OR TRIM(boundary_name) = ''
           OR source_version IS NULL OR TRIM(source_version) = ''
           OR batch_id IS NULL OR TRIM(batch_id) = ''
           OR record_sha256 IS NULL OR TRIM(record_sha256) = ''
           OR psgc_reference_version IS NULL OR TRIM(psgc_reference_version) = ''
           OR psgc_reference_checksum IS NULL OR TRIM(psgc_reference_checksum) = ''
           OR silver_processed_at IS NULL
    """)
    dq.record(
        "AS02",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="Required boundary fields complete",
        check_type="COMPLETENESS",
        severity="FAIL",
        threshold=0,
        fail_count=missing,
        total_count=silver_rows,
    )

    # AS03: the logical key must identify only one row.
    duplicates = count_sql("""
        SELECT COALESCE(SUM(n - 1), 0) FROM (
            SELECT COUNT(*) AS n FROM beginner_boundaries_silver
            GROUP BY admin_level, boundary_pcode, source_version HAVING COUNT(*) > 1
        )
    """)
    dq.record(
        "AS03",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="Boundary logical key unique",
        check_type="UNIQUENESS",
        severity="FAIL",
        threshold=0,
        fail_count=duplicates,
        total_count=silver_rows,
    )

    # AS04: only the configured admin levels and geometry types are allowed.
    invalid_values = count_sql(f"""
        SELECT COUNT(*) FROM beginner_boundaries_silver
        WHERE admin_level IS NULL OR admin_level NOT IN ({sql_list(ADMIN_LEVELS)})
           OR geometry_type IS NULL OR geometry_type NOT IN ({sql_list(GEOMETRY_TYPES)})
    """)
    dq.record(
        "AS04",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="Administrative and geometry values accepted",
        check_type="VALIDITY",
        severity="FAIL",
        threshold=0,
        fail_count=invalid_values,
        total_count=silver_rows,
        expected=f"admin_level in {ADMIN_LEVELS}; geometry_type in {GEOMETRY_TYPES}",
    )

    # ASB05: compares total counts only (AS05 in the detailed script also compares per level).
    dq.record(
        "ASB05",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="Boundary total rows reconcile",
        check_type="RECONCILIATION",
        severity="FAIL",
        threshold=0,
        fail_count=abs(bronze_rows - silver_rows),
        total_count=bronze_rows,
        observed=silver_rows,
        expected=bronze_rows,
    )

    # AS07: area is positive, latitude is -90..90, longitude is -180..180.
    spatial_issues = count_sql("""
        SELECT COUNT(*) FROM beginner_boundaries_silver
        WHERE area_sqkm IS NULL OR ISNAN(area_sqkm) OR area_sqkm <= 0
           OR ABS(area_sqkm) = CAST('Infinity' AS DOUBLE)
           OR center_lat IS NULL OR ISNAN(center_lat) OR center_lat NOT BETWEEN -90 AND 90
           OR center_lon IS NULL OR ISNAN(center_lon) OR center_lon NOT BETWEEN -180 AND 180
    """)
    dq.record(
        "AS07",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="Spatial attributes valid",
        check_type="RANGE",
        severity="FAIL",
        threshold=0,
        fail_count=spatial_issues,
        total_count=silver_rows,
    )

    # AS08: allow a null PSGC code ONLY for the documented special structures.
    classification_issues = count_sql(f"""
        SELECT COUNT(*) FROM beginner_boundaries_silver
        WHERE psgc_match_status IS NULL
           OR psgc_match_status NOT IN ('CODE_MATCH', 'HIERARCHY_MATCH', 'NAME_LEVEL_MATCH',
                                       'TYPE_CONTEXT_MATCH', 'NAME_VARIANT_MATCH', 'SPECIAL_STRUCTURE')
           OR (psgc_match_status <> 'SPECIAL_STRUCTURE' AND (psgc_code IS NULL OR TRIM(psgc_code) = ''))
           OR (psgc_match_status = 'SPECIAL_STRUCTURE' AND (
                psgc_code IS NOT NULL OR NOT COALESCE({SPECIAL_STRUCTURE_SQL}, FALSE)))
    """)
    dq.record(
        "AS08",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="PSGC match status and special structures valid",
        check_type="CONSISTENCY",
        severity="FAIL",
        threshold=0,
        fail_count=classification_issues,
        total_count=silver_rows,
    )

    # AS09: verify the recorded PSGC reference snapshot and the correct geographic level.
    reference_issues = count_sql("""
        SELECT COUNT(*) FROM beginner_boundaries_silver s
        WHERE NOT EXISTS (
            SELECT 1 FROM beginner_boundaries_psgc p
            WHERE p.source_version = s.psgc_reference_version
              AND p.content_checksum = s.psgc_reference_checksum)
           OR (s.psgc_code IS NOT NULL AND (
            SELECT COUNT(*) FROM beginner_boundaries_psgc p
            WHERE p.psgc_code = s.psgc_code
              AND p.source_version = s.psgc_reference_version
              AND p.content_checksum = s.psgc_reference_checksum
              AND ((s.admin_level = '1' AND p.geographic_level = 'Reg')
                OR (s.admin_level = '2' AND p.geographic_level = 'Prov')
                OR (s.admin_level = '3' AND p.geographic_level IN ('City', 'Mun')))) <> 1)
    """)
    dq.record(
        "AS09",
        table_name=SILVER_TABLE,
        source_key="hdx_phl_admin",
        batch_id=BATCH_ID,
        check_name="PSGC reference snapshot and level valid",
        check_type="REFERENTIAL_INTEGRITY",
        severity="FAIL",
        threshold=0,
        fail_count=reference_issues,
        total_count=silver_rows,
    )

print(f"Admin boundaries Silver QC completed. Results: {DQ_SCHEMA_NAME}.qc_results")
