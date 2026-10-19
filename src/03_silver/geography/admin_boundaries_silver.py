# =============================================================================
# 02 — HDX Administrative Boundaries Bronze to Silver
#
# Transforms HDX Philippines Administrative Boundaries from Bronze into a validated Silver
# dataset reconciled to PSGC codes. Script version of the admin_boundaries_silver notebook
# (same cells, same order).
#
#   Config     config/sources_geography.yaml (psgc and hdx_phl_admin entries)
#   Source     public_health.bronze.admin_boundaries_bronze
#   Reference  public_health.silver.geography_silver (run geography_silver.py first)
#   Target     public_health.silver.admin_boundaries_silver
#   QC         public_health.quality.qc_results (checks AB01–AB06; AB07 stops the run)
#   Grain      one ADM1 / ADM2 / ADM3 boundary feature per HDX source version
#   Key        admin_level + boundary_pcode + source_version
#
# Flow
#   Bronze -> parse/standardize -> spatial and grain checks -> PSGC reconciliation
#   (CODE_MATCH, HIERARCHY_MATCH, NAME_LEVEL_MATCH, TYPE_CONTEXT_MATCH, NAME_VARIANT_MATCH,
#   SPECIAL_STRUCTURE) -> DQ checks -> QC results -> DQ gate -> align table schema ->
#   replace this source version (DELETE + insert-only MERGE) -> post-MERGE checks.
#
# How to run (Databricks, Serverless or classic)
#   Python script task:  admin_boundaries_silver.py  [--config_path ...] [--job_run_id {{job.run_id}}]
#                        [--prove_idempotency true|false] [--diagnostics true|false]
#   Notebook cell:       import runpy; runpy.run_path("<repo>/src/03_silver/admin_boundaries_silver.py",
#                                                     run_name="__main__")
#   Parameters are optional. Also read from job/widget parameters of the same names, and the
#   config path from the environment variable PSGC_CONFIG_PATH.
#
# Changes from the notebook
#   - Config found from this file's location (no cwd-relative ../../ path; works on Serverless).
#   - The Silver table gets any candidate column it is missing before the MERGE (older copies).
#   - run_id uses --job_run_id when given. The duplicate "create table" cell is removed.
#   - The idempotency proof and the closing diagnostic queries can be switched off.
#
# Rule 2a (2026-10-19)
#   - The SPECIAL_STRUCTURE names (Metropolitan Manila*, City of Isabela (not a province),
#     Special Geographic Area and its ADM3 children) come from
#     hdx_phl_admin.silver_qc.special_structures in the YAML. AS08 in
#     admin_boundaries_silver_qc.py reads the same lists; before, each file typed its own copy.
#   - Other values stay: admin levels and geometry types were already read from the YAML; the
#     latitude / longitude bounds are the globe's; the PSGC padding (8 / 5 / 3 zeros) is the
#     10-digit code format, and a candidate of another length stops the run.
# =============================================================================

import argparse
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

spark = SparkSession.builder.getOrCreate()


# -----------------------------------------------------------------------------
# Run parameters: command-line arguments (Python script task), then job/widget
# parameters (notebook task), then environment variables.
# -----------------------------------------------------------------------------


def parse_args():
    parser = argparse.ArgumentParser(description="HDX administrative boundaries Bronze to Silver")
    parser.add_argument("--config_path", default=None,
                        help="Full path to config/sources_geography.yaml (default: found above this file)")
    parser.add_argument("--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job")
    parser.add_argument("--prove_idempotency", default=None,
                        help="true (default): rerun the MERGE and assert 0 inserts/updates")
    parser.add_argument("--diagnostics", default=None,
                        help="true (default): print match-status, duplicate-code and name checks")
    args, _ = parser.parse_known_args()  # notebook kernels pass their own arguments
    return args


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
    # First non-blank value of: argument, job/widget parameter, environment variable, default.
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


def _start_dirs():
    starts = []
    try:
        starts.append(Path(__file__).resolve().parent)
    except NameError:
        pass
    starts.append(Path.cwd())
    return starts


def find_config(explicit, name="sources_geography.yaml"):
    # Explicit path, or walk up from this file (and the working directory):
    # src/03_silver -> src -> repo root (has config/).
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise FileNotFoundError(f"Config file not found: {explicit}")
        return path.resolve()
    searched = []
    for start in _start_dirs():
        for folder in (start, *list(start.parents)[:5]):
            candidate = folder / "config" / name
            searched.append(str(candidate))
            if candidate.is_file():
                return candidate.resolve()
    raise FileNotFoundError(
        f"{name} not found. Pass --config_path (or the job parameter config_path). "
        "Looked in:\n  " + "\n  ".join(dict.fromkeys(searched))
    )


def show(df, n=20):
    # Replaces the notebook display function; also works in a Python script task.
    df.show(n, truncate=False)


ARGS = parse_args()
CONFIG_PATH = find_config(param(ARGS.config_path, "config_path", env="PSGC_CONFIG_PATH"))
JOB_RUN_ID = param(ARGS.job_run_id, "job_run_id")

with open(CONFIG_PATH, "r", encoding="utf-8") as f:
    config = yaml.safe_load(f)

print(f"Loaded config: {CONFIG_PATH}")

import re

PROVE_IDEMPOTENCY = param(ARGS.prove_idempotency, "prove_idempotency", default="true").lower() == "true"
DIAGNOSTICS = param(ARGS.diagnostics, "diagnostics", default="true").lower() == "true"

if not config or "sources" not in config:
    raise ValueError(
        "Invalid configuration: missing top-level 'sources' section."
    )

required_source_sections = [
    "psgc",
    "hdx_phl_admin",
]

missing_sections = [
    section
    for section in required_source_sections
    if section not in config["sources"]
]

if missing_sections:
    raise ValueError(
        f"Missing required source configuration: {missing_sections}"
    )


# -----------------------------------------------------------------------------
# Name helper used by CODE_MATCH (ADM3 name agreement)
# -----------------------------------------------------------------------------

NAME_STOP_WORDS = ["city", "of", "capital", "municipality", ""]

def name_words(column):
    repaired = F.regexp_replace(column, "\u00c3\u00b1", "ñ")
    cleaned = F.regexp_replace(
        F.translate(F.lower(repaired), "ñ", "n"), r"[^a-z0-9]+", " "
    )
    return F.array_except(
        F.split(F.trim(cleaned), " "),
        F.array(*[F.lit(w) for w in NAME_STOP_WORDS]),
    )


# -----------------------------------------------------------------------------
# Resolve configuration sections
# -----------------------------------------------------------------------------
sources_cfg = config["sources"]

psgc_cfg = sources_cfg["psgc"]
hdx_cfg = sources_cfg["hdx_phl_admin"]


# Validate required HDX configuration
required_hdx_keys = [
    "source_name",
    "dataset_id",
    "bronze_table",
    "admin_boundaries_silver_table",
    "qc_results_table",
    "required_levels",
    "layer_pattern",
    "silver_qc",
]

missing_hdx_keys = [
    key
    for key in required_hdx_keys
    if key not in hdx_cfg
]

if missing_hdx_keys:
    raise ValueError(
        f"Missing HDX configuration keys: {missing_hdx_keys}"
    )


# Validate Silver DQ configuration
silver_qc_cfg = hdx_cfg["silver_qc"]

if not isinstance(silver_qc_cfg, dict):
    raise ValueError(
        "hdx_phl_admin.silver_qc must be a YAML mapping."
    )

required_silver_qc_keys = [
    "required_columns",
    "accepted_geometry_types",
    "special_structures",
]

missing_silver_qc_keys = [
    key
    for key in required_silver_qc_keys
    if key not in silver_qc_cfg
]

if missing_silver_qc_keys:
    raise ValueError(
        f"Missing Silver DQ configuration keys: "
        f"{missing_silver_qc_keys}"
    )


# Validate PSGC reference configuration
if "geography_silver_table" not in psgc_cfg:
    raise ValueError(
        "Missing PSGC configuration key: "
        "'geography_silver_table'"
    )

print("Configuration sections validated successfully.")


# -----------------------------------------------------------------------------
# Resolve Runtime Configuration
# -----------------------------------------------------------------------------
SOURCE_KEY = "hdx_phl_admin"

SOURCE_NAME = hdx_cfg["source_name"]
DATASET_ID = hdx_cfg["dataset_id"]

BRONZE_TABLE = hdx_cfg["bronze_table"]
SILVER_TABLE = hdx_cfg["admin_boundaries_silver_table"]
PSGC_TABLE = psgc_cfg["geography_silver_table"]
QC_TABLE = hdx_cfg["qc_results_table"]

REQUIRED_LEVELS = [
    str(level)
    for level in hdx_cfg["required_levels"]
]

LAYER_PATTERN = hdx_cfg["layer_pattern"]

SILVER_REQUIRED_COLUMNS = (
    silver_qc_cfg["required_columns"]
)

SILVER_GEOMETRY_TYPES = (
    silver_qc_cfg["accepted_geometry_types"]
)

# HDX boundaries with no one-to-one PSGC area (SPECIAL_STRUCTURE). Same lists as AS08 in QC.
_special_cfg = silver_qc_cfg["special_structures"] or {}
SPECIAL_ADM2_PREFIXES = [str(v) for v in _special_cfg.get("adm2_name_prefixes") or []]
SPECIAL_ADM2_NAMES = [str(v) for v in _special_cfg.get("adm2_names") or []]
SPECIAL_ADM3_PARENTS = [str(v) for v in _special_cfg.get("adm3_parent_adm2_names") or []]
if not (SPECIAL_ADM2_PREFIXES or SPECIAL_ADM2_NAMES or SPECIAL_ADM3_PARENTS):
    raise ValueError(
        "hdx_phl_admin.silver_qc.special_structures has no names. "
        "List adm2_name_prefixes, adm2_names and adm3_parent_adm2_names."
    )


print("Runtime configuration resolved.")
print(f"Source        : {SOURCE_NAME}")
print(f"Dataset       : {DATASET_ID}")
print(f"Bronze        : {BRONZE_TABLE}")
print(f"Silver        : {SILVER_TABLE}")
print(f"PSGC reference: {PSGC_TABLE}")
print(f"QC results    : {QC_TABLE}")
print(f"Admin levels  : {REQUIRED_LEVELS}")
print(f"Special ADM2  : prefixes {SPECIAL_ADM2_PREFIXES}, names {SPECIAL_ADM2_NAMES}")
print(f"Special ADM3  : children of {SPECIAL_ADM3_PARENTS}")


# -----------------------------------------------------------------------------
# Validate Required Input Tables
# -----------------------------------------------------------------------------
required_input_tables = {
    "Bronze source": BRONZE_TABLE,
    "PSGC reference": PSGC_TABLE,
    "QC results": QC_TABLE,
}

missing_tables = [
    f"{label}: {table_name}"
    for label, table_name in required_input_tables.items()
    if not spark.catalog.tableExists(table_name)
]

if missing_tables:
    raise ValueError(
        "Required pipeline table(s) not found:\n"
        + "\n".join(missing_tables)
    )

print("Required input tables are available.")

for label, table_name in required_input_tables.items():
    print(f"{label:<15}: {table_name}")

print(
    f"Silver target   : {SILVER_TABLE} "
    f"({'exists' if spark.catalog.tableExists(SILVER_TABLE) else 'will be created'})"
)


# -----------------------------------------------------------------------------
# Profile Bronze source snapshots
# -----------------------------------------------------------------------------
bronze_snapshot_summary = (
    spark.table(BRONZE_TABLE)
    .groupBy(
        "_source_version",
        "_batch_id"
    )
    .agg(
        F.count("*").alias("row_count"),
        F.countDistinct("_source_file").alias("source_file_count"),
        F.sort_array(
            F.collect_set("_source_file")
        ).alias("source_files")
    )
    .orderBy("_source_version", "_batch_id")
)

show(bronze_snapshot_summary)


# -----------------------------------------------------------------------------
# Select and Validate Bronze Snapshot
# -----------------------------------------------------------------------------
snapshot_rows = [
    row.asDict()
    for row in bronze_snapshot_summary.collect()
]

if len(snapshot_rows) == 0:
    raise ValueError(
        "No HDX administrative-boundary snapshot found in Bronze."
    )

if len(snapshot_rows) > 1:
    raise ValueError(
        "Multiple HDX source snapshots found in Bronze. "
        "An explicit snapshot-selection rule is required."
    )


# Current MVP: exactly one source snapshot is available
snapshot = snapshot_rows[0]

selected_source_version = snapshot["_source_version"]
selected_batch_id = snapshot["_batch_id"]
bronze_row_count = snapshot["row_count"]
source_files = snapshot["source_files"]


# Derive administrative levels from configured file-name pattern
observed_levels = []
unrecognized_files = []

for source_file in source_files:
    match = re.search(
        LAYER_PATTERN,
        source_file,
        flags=re.IGNORECASE
    )

    if match:
        observed_levels.append(match.group(1))
    else:
        unrecognized_files.append(source_file)

observed_levels = sorted(set(observed_levels))


# Validate source-file contract
if unrecognized_files:
    raise ValueError(
        f"Unable to determine admin level for file(s): "
        f"{unrecognized_files}"
    )

if observed_levels != sorted(REQUIRED_LEVELS):
    raise ValueError(
        f"Administrative-level mismatch. "
        f"Expected {sorted(REQUIRED_LEVELS)}, "
        f"observed {observed_levels}."
    )


# Select only the validated snapshot
selected_bronze = (
    spark.table(BRONZE_TABLE)
    .filter(
        (F.col("_source_version") == selected_source_version)
        &
        (F.col("_batch_id") == selected_batch_id)
    )
)


print("Bronze snapshot contract passed.")
print(f"Source version : {selected_source_version}")
print(f"Batch ID       : {selected_batch_id}")
print(f"Row count      : {bronze_row_count}")
print(f"Expected levels: {sorted(REQUIRED_LEVELS)}")
print(f"Observed levels: {observed_levels}")
print(f"Source files   : {source_files}")


# -----------------------------------------------------------------------------
# Build Standardized Silver Candidate Base
# -----------------------------------------------------------------------------
# Extract and standardize HDX administrative-boundary attributes

silver_candidate_base = (
    selected_bronze

    # -----------------------------------------
    # Administrative level from source filename
    # -----------------------------------------
    .withColumn(
        "admin_level",
        F.regexp_extract(
            F.col("_source_file"),
            LAYER_PATTERN,
            1
        )
    )

    # -----------------------------------------
    # Source hierarchy codes
    # -----------------------------------------
    .withColumn(
        "adm1_pcode",
        F.trim(
            F.get_json_object(
                F.col("properties_json"),
                "$.adm1_pcode"
            )
        )
    )
    .withColumn(
        "adm2_pcode",
        F.trim(
            F.get_json_object(
                F.col("properties_json"),
                "$.adm2_pcode"
            )
        )
    )
    .withColumn(
        "adm3_pcode",
        F.trim(
            F.get_json_object(
                F.col("properties_json"),
                "$.adm3_pcode"
            )
        )
    )

    # -----------------------------------------
    # Source hierarchy names
    # -----------------------------------------
    .withColumn(
        "adm1_name",
        F.trim(
            F.get_json_object(
                F.col("properties_json"),
                "$.adm1_name"
            )
        )
    )
    .withColumn(
        "adm2_name",
        F.trim(
            F.get_json_object(
                F.col("properties_json"),
                "$.adm2_name"
            )
        )
    )
    .withColumn(
        "adm3_name",
        F.trim(
            F.get_json_object(
                F.col("properties_json"),
                "$.adm3_name"
            )
        )
    )

    # -----------------------------------------
    # Current feature identity
    # -----------------------------------------
    .withColumn(
        "boundary_pcode",
        F.when(
            F.col("admin_level") == "3",
            F.col("adm3_pcode")
        )
        .when(
            F.col("admin_level") == "2",
            F.col("adm2_pcode")
        )
        .when(
            F.col("admin_level") == "1",
            F.col("adm1_pcode")
        )
    )
    .withColumn(
        "boundary_name",
        F.when(
            F.col("admin_level") == "3",
            F.col("adm3_name")
        )
        .when(
            F.col("admin_level") == "2",
            F.col("adm2_name")
        )
        .when(
            F.col("admin_level") == "1",
            F.col("adm1_name")
        )
    )

    # -----------------------------------------
    # Spatial attributes
    # -----------------------------------------
    .withColumn(
        "area_sqkm",
        F.get_json_object(
            F.col("properties_json"),
            "$.area_sqkm"
        ).cast("double")
    )
    .withColumn(
        "center_lat",
        F.get_json_object(
            F.col("properties_json"),
            "$.center_lat"
        ).cast("double")
    )
    .withColumn(
        "center_lon",
        F.get_json_object(
            F.col("properties_json"),
            "$.center_lon"
        ).cast("double")
    )

    # -----------------------------------------
    # Temporal/source version attributes
    # -----------------------------------------
    .withColumn(
        "valid_on",
        F.to_date(
            F.get_json_object(
                F.col("properties_json"),
                "$.valid_on"
            )
        )
    )
    .withColumn(
        "valid_to",
        F.to_date(
            F.get_json_object(
                F.col("properties_json"),
                "$.valid_to"
            )
        )
    )
    .withColumn(
        "boundary_version",
        F.get_json_object(
            F.col("properties_json"),
            "$.version"
        )
    )

    # -----------------------------------------
    # Select standardized fields + lineage
    # -----------------------------------------
    .select(
        "admin_level",
        "boundary_pcode",
        "boundary_name",
        "adm1_pcode",
        "adm1_name",
        "adm2_pcode",
        "adm2_name",

        F.col("geometry_json"),
        F.col("geometry_type"),

        "area_sqkm",
        "center_lat",
        "center_lon",
        "valid_on",
        "valid_to",
        "boundary_version",

        F.col("_source_version").alias("source_version"),
        F.col("_batch_id").alias("batch_id"),
        F.col("_source_file").alias("source_file"),
        F.col("_source_file_sha256").alias("source_file_sha256"),
        F.col("_source_crs").alias("source_crs"),
        F.col("_record_sha256").alias("record_sha256")
    )
)


show(
    silver_candidate_base
    .select(
        "admin_level",
        "boundary_pcode",
        "boundary_name",
        "adm1_name",
        "adm2_name",
        "area_sqkm",
        "center_lat",
        "center_lon",
        "geometry_type"
    )
    .orderBy(
        "admin_level",
        "boundary_pcode"
    )
    .limit(20)
)


# -----------------------------------------------------------------------------
# Validate spatial attributes
# -----------------------------------------------------------------------------
spatial_metrics = (
    silver_candidate_base
    .agg(
        F.count("*").alias("row_count"),

        F.sum(
            F.when(F.col("area_sqkm").isNull(), 1).otherwise(0)
        ).alias("area_null_count"),

        F.sum(
            F.when(
                F.col("area_sqkm") <= 0,
                1
            ).otherwise(0)
        ).alias("invalid_area_count"),

        F.sum(
            F.when(F.col("center_lat").isNull(), 1).otherwise(0)
        ).alias("latitude_null_count"),

        F.sum(
            F.when(F.col("center_lon").isNull(), 1).otherwise(0)
        ).alias("longitude_null_count"),

        F.sum(
            F.when(
                ~F.col("center_lat").between(-90, 90),
                1
            ).otherwise(0)
        ).alias("invalid_latitude_count"),

        F.sum(
            F.when(
                ~F.col("center_lon").between(-180, 180),
                1
            ).otherwise(0)
        ).alias("invalid_longitude_count"),

        F.min("area_sqkm").alias("min_area_sqkm"),
        F.max("area_sqkm").alias("max_area_sqkm"),
        F.min("center_lat").alias("min_center_lat"),
        F.max("center_lat").alias("max_center_lat"),
        F.min("center_lon").alias("min_center_lon"),
        F.max("center_lon").alias("max_center_lon")
    )
    .collect()[0]
)

print("Spatial validation summary")
print(f"Rows              : {spatial_metrics['row_count']}")
print(f"Area nulls        : {spatial_metrics['area_null_count']}")
print(f"Invalid area      : {spatial_metrics['invalid_area_count']}")
print(f"Latitude nulls    : {spatial_metrics['latitude_null_count']}")
print(f"Longitude nulls   : {spatial_metrics['longitude_null_count']}")
print(f"Invalid latitude  : {spatial_metrics['invalid_latitude_count']}")
print(f"Invalid longitude : {spatial_metrics['invalid_longitude_count']}")

print("\nObserved ranges")
print(
    f"Area sqkm : "
    f"{spatial_metrics['min_area_sqkm']} "
    f"to {spatial_metrics['max_area_sqkm']}"
)
print(
    f"Latitude  : "
    f"{spatial_metrics['min_center_lat']} "
    f"to {spatial_metrics['max_center_lat']}"
)
print(
    f"Longitude : "
    f"{spatial_metrics['min_center_lon']} "
    f"to {spatial_metrics['max_center_lon']}"
)


spatial_issue_count = (
    spatial_metrics["area_null_count"]
    + spatial_metrics["invalid_area_count"]
    + spatial_metrics["latitude_null_count"]
    + spatial_metrics["longitude_null_count"]
    + spatial_metrics["invalid_latitude_count"]
    + spatial_metrics["invalid_longitude_count"]
)

if spatial_issue_count > 0:
    raise ValueError(
        f"Spatial validation failed: "
        f"{spatial_issue_count} issue(s) found."
    )

print("\nSpatial validation passed.")


# -----------------------------------------------------------------------------
# Grain and Logical-Key Validation
# -----------------------------------------------------------------------------
# Validate Silver grain and source-native identity

grain_metrics = (
    silver_candidate_base
    .agg(
        F.count("*").alias("row_count"),

        F.countDistinct(
            F.struct(
                "admin_level",
                "boundary_pcode",
                "source_version"
            )
        ).alias("distinct_logical_keys"),

        F.sum(
            F.when(
                F.col("admin_level").isNull()
                | (F.trim(F.col("admin_level")) == "")
                | F.col("boundary_pcode").isNull()
                | (F.trim(F.col("boundary_pcode")) == "")
                | F.col("boundary_name").isNull()
                | (F.trim(F.col("boundary_name")) == "")
                | F.col("source_version").isNull()
                | (F.trim(F.col("source_version")) == ""),
                1
            ).otherwise(0)
        ).alias("identity_issue_count"),

        F.sum(
            F.when(F.col("admin_level") == "1", 1).otherwise(0)
        ).alias("adm1_count"),

        F.sum(
            F.when(F.col("admin_level") == "2", 1).otherwise(0)
        ).alias("adm2_count"),

        F.sum(
            F.when(F.col("admin_level") == "3", 1).otherwise(0)
        ).alias("adm3_count")
    )
    .collect()[0]
)

grain_row_count = grain_metrics["row_count"]
distinct_logical_keys = grain_metrics["distinct_logical_keys"]

duplicate_logical_keys = (
    grain_row_count - distinct_logical_keys
)


print("Grain validation summary")
print(f"Rows                  : {grain_row_count}")
print(f"Distinct logical keys : {distinct_logical_keys}")
print(f"Duplicate rows        : {duplicate_logical_keys}")
print(f"Identity issues       : {grain_metrics['identity_issue_count']}")

print("\nAdministrative-level distribution")
print(f"ADM1 : {grain_metrics['adm1_count']}")
print(f"ADM2 : {grain_metrics['adm2_count']}")
print(f"ADM3 : {grain_metrics['adm3_count']}")


if grain_row_count != bronze_row_count:
    raise ValueError(
        f"Row-count mismatch before reconciliation: "
        f"Bronze={bronze_row_count}, "
        f"candidate={grain_row_count}."
    )

if duplicate_logical_keys > 0:
    raise ValueError(
        f"Grain validation failed: "
        f"{duplicate_logical_keys} duplicate logical-key row(s)."
    )

if grain_metrics["identity_issue_count"] > 0:
    raise ValueError(
        f"Grain validation failed: "
        f"{grain_metrics['identity_issue_count']} "
        f"source identity issue(s)."
    )

print("\nGrain validation passed.")


# -----------------------------------------------------------------------------
# Select PSGC Reference Snapshot
# -----------------------------------------------------------------------------
# Profile available PSGC Silver snapshots
psgc_snapshot_summary = (
    spark.table(PSGC_TABLE)
    .groupBy(
        "source_version",
        "content_checksum"
    )
    .agg(
        F.count("*").alias("row_count")
    )
)

psgc_snapshots = [
    row.asDict()
    for row in psgc_snapshot_summary.collect()
]


if len(psgc_snapshots) == 0:
    raise ValueError(
        "No PSGC reference snapshot found in Silver."
    )

if len(psgc_snapshots) > 1:
    raise ValueError(
        "Multiple PSGC reference snapshots found. "
        "An explicit PSGC snapshot-selection rule is required."
    )


# Select the validated PSGC snapshot
psgc_snapshot = psgc_snapshots[0]

selected_psgc_source_version = (
    psgc_snapshot["source_version"]
)

selected_psgc_checksum = (
    psgc_snapshot["content_checksum"]
)


# Keep only geographic levels relevant to HDX ADM1–ADM3
psgc_admin_ref = (
    spark.table(PSGC_TABLE)
    .filter(
        (F.col("source_version") == selected_psgc_source_version)
        &
        (F.col("content_checksum") == selected_psgc_checksum)
        &
        (F.col("geographic_level").isin(
            "Reg",
            "Prov",
            "City",
            "Mun"
        ))
    )
    .select(
        "psgc_code",
        "area_name",
        "geographic_level",
        "region_code",
        "province_code",
        "municipality_code",
        "city_class",
        "source_version",
        "content_checksum"
    )
)


# Compact diagnostic only
psgc_level_summary = (
    psgc_admin_ref
    .groupBy("geographic_level")
    .count()
    .orderBy("geographic_level")
)

print("PSGC reference snapshot selected.")
print(
    f"Source version : "
    f"{selected_psgc_source_version}"
)
print(
    f"Checksum       : "
    f"{selected_psgc_checksum}"
)

show(psgc_level_summary)


# -----------------------------------------------------------------------------
# Validate PSGC code uniqueness
# -----------------------------------------------------------------------------
psgc_uniqueness_metrics = (
    psgc_admin_ref
    .agg(
        F.count("*").alias("row_count"),
        F.countDistinct("psgc_code").alias("distinct_psgc_codes"),

        F.sum(
            F.when(
                F.col("psgc_code").isNull()
                | (F.trim(F.col("psgc_code")) == ""),
                1
            ).otherwise(0)
        ).alias("missing_psgc_code_count")
    )
    .collect()[0]
)

psgc_row_count = psgc_uniqueness_metrics["row_count"]
distinct_psgc_codes = psgc_uniqueness_metrics["distinct_psgc_codes"]

duplicate_psgc_codes = (
    psgc_row_count - distinct_psgc_codes
)


print("PSGC reference uniqueness summary")
print(f"Rows                : {psgc_row_count}")
print(f"Distinct PSGC codes : {distinct_psgc_codes}")
print(f"Duplicate codes     : {duplicate_psgc_codes}")
print(
    f"Missing PSGC codes  : "
    f"{psgc_uniqueness_metrics['missing_psgc_code_count']}"
)


if duplicate_psgc_codes > 0:
    raise ValueError(
        f"PSGC reference is not unique: "
        f"{duplicate_psgc_codes} duplicate PSGC code row(s) found."
    )

if psgc_uniqueness_metrics["missing_psgc_code_count"] > 0:
    raise ValueError(
        "PSGC reference contains missing PSGC codes."
    )

print("\nPSGC reference uniqueness validation passed.")


# -----------------------------------------------------------------------------
# Derive PSGC candidate code from HDX P-code
# -----------------------------------------------------------------------------
boundary_with_candidate = (
    silver_candidate_base

    # Remove the PH prefix while preserving leading zeros
    .withColumn(
        "pcode_body",
        F.regexp_replace(
            F.col("boundary_pcode"),
            r"^PH",
            ""
        )
    )

    # Expected PSGC geographic level for reconciliation
    .withColumn(
        "expected_psgc_level",
        F.when(
            F.col("admin_level") == "1",
            F.lit("Reg")
        )
        .when(
            F.col("admin_level") == "2",
            F.lit("Prov")
        )
        .when(
            F.col("admin_level") == "3",
            F.lit("City_or_Mun")
        )
    )

    # Construct the 10-digit PSGC candidate
    .withColumn(
        "candidate_psgc_code",
        F.when(
            F.col("admin_level") == "1",
            F.concat(
                F.col("pcode_body"),
                F.lit("00000000")
            )
        )
        .when(
            F.col("admin_level") == "2",
            F.concat(
                F.col("pcode_body"),
                F.lit("00000")
            )
        )
        .when(
            F.col("admin_level") == "3",
            F.concat(
                F.col("pcode_body"),
                F.lit("000")
            )
        )
    )
)


candidate_code_metrics = (
    boundary_with_candidate
    .agg(
        F.count("*").alias("row_count"),

        F.sum(
            F.when(
                ~F.col("boundary_pcode").rlike(r"^PH\d+$"),
                1
            ).otherwise(0)
        ).alias("invalid_hdx_pcode_count"),

        F.sum(
            F.when(
                ~F.col("candidate_psgc_code").rlike(r"^\d{10}$"),
                1
            ).otherwise(0)
        ).alias("invalid_candidate_code_count")
    )
    .collect()[0]
)


print("PSGC candidate-code validation")
print(f"Rows                  : {candidate_code_metrics['row_count']}")
print(
    f"Invalid HDX P-codes   : "
    f"{candidate_code_metrics['invalid_hdx_pcode_count']}"
)
print(
    f"Invalid PSGC candidates: "
    f"{candidate_code_metrics['invalid_candidate_code_count']}"
)


if candidate_code_metrics["invalid_hdx_pcode_count"] > 0:
    raise ValueError(
        "Invalid HDX boundary P-code format detected."
    )

if candidate_code_metrics["invalid_candidate_code_count"] > 0:
    raise ValueError(
        "Invalid 10-digit PSGC candidate code detected."
    )

print("\nCandidate PSGC code derivation passed.")


# -----------------------------------------------------------------------------
# Direct PSGC Code Reconciliation (CODE_MATCH)
# -----------------------------------------------------------------------------
direct_match = (
    boundary_with_candidate.alias("b")
    .join(
        F.broadcast(
            psgc_admin_ref
            .select(
                F.col("psgc_code").alias("ref_psgc_code"),
                F.col("area_name").alias("ref_area_name"),
                F.col("geographic_level").alias("ref_geographic_level")
            )
        ).alias("p"),
        F.col("b.candidate_psgc_code") == F.col("p.ref_psgc_code"),
        "left"
    )
    .withColumn(
        "level_compatible",
        F.when(
            (F.col("admin_level") == "1")
            & (F.col("ref_geographic_level") == "Reg"),
            True
        )
        .when(
            (F.col("admin_level") == "2")
            & (F.col("ref_geographic_level") == "Prov"),
            True
        )
        .when(
            (F.col("admin_level") == "3")
            & F.col("ref_geographic_level").isin("City", "Mun"),
            True
        )
        .otherwise(False)
    )
    .withColumn("b_words", name_words(F.col("boundary_name")))
    .withColumn("p_words", name_words(F.col("ref_area_name")))
    .withColumn(
        "names_agree",
        (F.col("admin_level") != "3")
        | (
            (F.size("b_words") > 0) & (F.size("p_words") > 0)
            & (
                (F.size(F.array_except("b_words", "p_words")) == 0)
                | (F.size(F.array_except("p_words", "b_words")) == 0)
            )
        ),
    )
    .withColumn(
        "psgc_code",
        F.when(
            F.col("ref_psgc_code").isNotNull()
            & F.col("level_compatible")
            & F.col("names_agree"),
            F.col("ref_psgc_code")
        )
    )
    .withColumn(
        "psgc_match_status",
        F.when(
            F.col("psgc_code").isNotNull(),
            F.lit("CODE_MATCH")
        )
    )
)


direct_match_metrics = (
    direct_match
    .agg(
        F.count("*").alias("row_count"),

        F.sum(
            F.when(
                F.col("psgc_match_status") == "CODE_MATCH",
                1
            ).otherwise(0)
        ).alias("code_match_count"),

        F.sum(
            F.when(
                F.col("ref_psgc_code").isNotNull()
                & ~F.col("level_compatible"),
                1
            ).otherwise(0)
        ).alias("wrong_level_count"),

        F.sum(
            F.when(
                F.col("ref_psgc_code").isNotNull()
                & F.col("level_compatible")
                & ~F.col("names_agree"),
                1
            ).otherwise(0)
        ).alias("name_mismatch_count"),

        F.sum(
            F.when(
                F.col("ref_psgc_code").isNull(),
                1
            ).otherwise(0)
        ).alias("no_direct_match_count")
    )
    .collect()[0]
)


print("Direct PSGC reconciliation")
print(f"Rows             : {direct_match_metrics['row_count']}")
print(f"CODE_MATCH       : {direct_match_metrics['code_match_count']}")
print(f"Wrong level      : {direct_match_metrics['wrong_level_count']}")
print(f"Name mismatch    : {direct_match_metrics['name_mismatch_count']}")
print(f"No direct match  : {direct_match_metrics['no_direct_match_count']}")


if direct_match_metrics["wrong_level_count"] > 0:
    raise ValueError(
        "Direct PSGC reconciliation found code matches "
        "at incompatible geographic levels."
    )


direct_match = direct_match.drop("b_words", "p_words", "names_agree")


# -----------------------------------------------------------------------------
# Prepare hierarchy matching fields
# -----------------------------------------------------------------------------
# Basic text normalization used only for reconciliation keys.
# Original source names remain unchanged.

def normalize_basic(column):
    return F.lower(
        F.trim(
            F.regexp_replace(
                F.regexp_replace(
                    column,
                    r"\s*\([^)]*\)",   # remove all bracketed text
                    ""
                ),
                r"\s+",
                " "
            )
        )
    )


# ---------------------------------------------------------
# 1. HDX rows that did not get a direct PSGC code match
# ---------------------------------------------------------

unresolved = (
    direct_match
    .filter(
        F.col("psgc_code").isNull()
    )
    .withColumn(
        "boundary_name_basic",
        normalize_basic(
            F.col("boundary_name")
        )
    )
    .withColumn(
        "adm2_name_basic",
        normalize_basic(
            F.col("adm2_name")
        )
    )
)


# ---------------------------------------------------------
# 2. PSGC province lookup
# ---------------------------------------------------------

psgc_province_ref = (
    psgc_admin_ref
    .filter(
        F.col("geographic_level") == "Prov"
    )
    .select(
        F.col("psgc_code").alias("province_psgc_code"),
        F.col("area_name").alias("province_name")
    )
    .withColumn(
        "province_name_basic",
        normalize_basic(
            F.col("province_name")
        )
    )
)


# ---------------------------------------------------------
# 3. PSGC City / Municipality hierarchy reference
#
# Canonical PSGC code structure is used to derive
# the parent province code.
# ---------------------------------------------------------

psgc_city_mun_ref = (
    psgc_admin_ref
    .filter(
        F.col("geographic_level").isin(
            "City",
            "Mun"
        )
    )
    .select(
        F.col("psgc_code").alias("candidate_psgc_code"),
        F.col("area_name").alias("candidate_area_name"),
        F.col("geographic_level").alias("candidate_geographic_level")
    )
    .withColumn(
        "parent_province_psgc_code",
        F.concat(
            F.substring(
                F.col("candidate_psgc_code"),
                1,
                5
            ),
            F.lit("00000")
        )
    )
    .join(
        F.broadcast(psgc_province_ref),
        F.col("parent_province_psgc_code")
        == F.col("province_psgc_code"),
        "left"
    )
    .withColumn(
        "candidate_name_basic",
        normalize_basic(
            F.col("candidate_area_name")
        )
    )
)


# ---------------------------------------------------------
# Diagnostic only
# ---------------------------------------------------------

unresolved_level_summary = (
    unresolved
    .groupBy("admin_level")
    .count()
    .orderBy("admin_level")
)

print("Hierarchy reconciliation preparation complete.")
print(
    f"Unresolved after direct CODE_MATCH: "
    f"{unresolved.count()}"
)
show(unresolved_level_summary)


# -----------------------------------------------------------------------------
# Evaluate hierarchy-match candidates
# -----------------------------------------------------------------------------
# ADM3 rows are the only rows eligible for this hierarchy rule.
# Match on:
#   boundary name + parent province name

unresolved_adm3 = (
    unresolved
    .filter(F.col("admin_level") == "3")
    .alias("h")
)

hierarchy_ref = (
    psgc_city_mun_ref
    .select(
        F.col("candidate_psgc_code")
            .alias("hierarchy_psgc_code"),
        F.col("candidate_area_name")
            .alias("hierarchy_area_name"),
        F.col("candidate_geographic_level")
            .alias("hierarchy_geographic_level"),
        F.col("candidate_name_basic"),
        F.col("province_name_basic")
            .alias("candidate_province_name_basic")
    )
    .alias("p")
)


hierarchy_match_candidates = (
    unresolved_adm3
    .join(
        F.broadcast(hierarchy_ref),
        (
            F.col("h.boundary_name_basic")
            == F.col("p.candidate_name_basic")
        )
        &
        (
            F.col("h.adm2_name_basic")
            == F.col("p.candidate_province_name_basic")
        ),
        "left"
    )
)


# Count how many PSGC candidates each HDX boundary received
hierarchy_candidate_summary = (
    hierarchy_match_candidates
    .groupBy(
        F.col("h.admin_level").alias("admin_level"),
        F.col("h.boundary_pcode").alias("boundary_pcode"),
        F.col("h.source_version").alias("source_version")
    )
    .agg(
        F.countDistinct(
            "hierarchy_psgc_code"
        ).alias("candidate_count"),

        F.first(
            "hierarchy_psgc_code",
            ignorenulls=True
        ).alias("hierarchy_psgc_code")
    )
)


# Diagnostic distribution:
# 0 = no hierarchy match
# 1 = safe unique hierarchy match
# >1 = ambiguous and must NOT be auto-resolved
hierarchy_candidate_distribution = (
    hierarchy_candidate_summary
    .groupBy("candidate_count")
    .count()
    .orderBy("candidate_count")
)

show(hierarchy_candidate_distribution)


ambiguous_hierarchy_count = (
    hierarchy_candidate_summary
    .filter(F.col("candidate_count") > 1)
    .count()
)

if ambiguous_hierarchy_count > 0:
    raise ValueError(
        f"Hierarchy reconciliation found "
        f"{ambiguous_hierarchy_count} ambiguous boundary row(s). "
        f"Do not auto-resolve ambiguous matches."
    )

print("Hierarchy candidate evaluation passed.")
print(
    f"Ambiguous hierarchy matches: "
    f"{ambiguous_hierarchy_count}"
)


# -----------------------------------------------------------------------------
# Apply Unique HIERARCHY_MATCH Results
# -----------------------------------------------------------------------------
# Keep only unique hierarchy matches
unique_hierarchy_matches = (
    hierarchy_candidate_summary
    .filter(F.col("candidate_count") == 1)
    .select(
        "admin_level",
        "boundary_pcode",
        "source_version",
        "hierarchy_psgc_code"
    )
)


# Join the hierarchy result, but retain only ONE copy
# of the logical-key columns from the base dataset.
working_recon = (
    direct_match.alias("b")
    .join(
        F.broadcast(unique_hierarchy_matches).alias("h"),
        (
            (F.col("b.admin_level") == F.col("h.admin_level"))
            &
            (F.col("b.boundary_pcode") == F.col("h.boundary_pcode"))
            &
            (F.col("b.source_version") == F.col("h.source_version"))
        ),
        "left"
    )
    .select(
        "b.*",
        F.col("h.hierarchy_psgc_code")
            .alias("_hierarchy_psgc_code")
    )
    .withColumn(
        "psgc_code",
        F.coalesce(
            F.col("psgc_code"),
            F.col("_hierarchy_psgc_code")
        )
    )
    .withColumn(
        "psgc_match_status",
        F.when(
            F.col("psgc_match_status").isNotNull(),
            F.col("psgc_match_status")
        )
        .when(
            F.col("_hierarchy_psgc_code").isNotNull(),
            F.lit("HIERARCHY_MATCH")
        )
    )
    .drop("_hierarchy_psgc_code")
)


# Reconciliation status after hierarchy matching
hierarchy_status_summary = (
    working_recon
    .groupBy("psgc_match_status")
    .count()
    .orderBy("psgc_match_status")
)

show(hierarchy_status_summary)


remaining_unresolved_count = (
    working_recon
    .filter(F.col("psgc_code").isNull())
    .count()
)

print(
    f"Remaining unresolved after HIERARCHY_MATCH: "
    f"{remaining_unresolved_count}"
)


# -----------------------------------------------------------------------------
# Evaluate NAME_LEVEL_MATCH Candidates
# -----------------------------------------------------------------------------
# Normalize city names for fallback matching.
# Examples:
#   "City of Isabela" -> "isabela"
#   "Sagay City"      -> "sagay"

def normalize_city_name(column):
    normalized = normalize_basic(column)

    return F.trim(
        F.regexp_replace(
            F.regexp_replace(
                normalized,
                r"^city of\s+",
                ""
            ),
            r"\s+city$",
            ""
        )
    )


# ---------------------------------------------------------
# Remaining unresolved after HIERARCHY_MATCH
# ---------------------------------------------------------

unresolved_after_hierarchy = (
    working_recon
    .filter(F.col("psgc_code").isNull())
    .withColumn(
        "boundary_name_basic",
        normalize_basic(F.col("boundary_name"))
    )
    .withColumn(
        "boundary_name_city_normalized",
        normalize_city_name(F.col("boundary_name"))
    )
)


# ---------------------------------------------------------
# ADM2 → Province name matching
# ---------------------------------------------------------

province_name_ref = (
    psgc_admin_ref
    .filter(F.col("geographic_level") == "Prov")
    .select(
        F.col("psgc_code").alias("name_level_psgc_code"),
        F.col("area_name").alias("name_level_area_name")
    )
    .withColumn(
        "reference_name_basic",
        normalize_basic(F.col("name_level_area_name"))
    )
)


adm2_name_candidates = (
    unresolved_after_hierarchy
    .filter(F.col("admin_level") == "2")
    .alias("h")
    .join(
        F.broadcast(province_name_ref).alias("p"),
        F.col("h.boundary_name_basic")
        == F.col("p.reference_name_basic"),
        "left"
    )
    .groupBy(
        F.col("h.admin_level").alias("admin_level"),
        F.col("h.boundary_pcode").alias("boundary_pcode"),
        F.col("h.source_version").alias("source_version")
    )
    .agg(
        F.countDistinct(
            "name_level_psgc_code"
        ).alias("candidate_count"),

        F.first(
            "name_level_psgc_code",
            ignorenulls=True
        ).alias("name_level_psgc_code")
    )
)


# ---------------------------------------------------------
# ADM3 → City/Municipality name matching
# ---------------------------------------------------------

city_mun_name_ref = (
    psgc_admin_ref
    .filter(
        F.col("geographic_level").isin("City", "Mun")
    )
    .select(
        F.col("psgc_code").alias("name_level_psgc_code"),
        F.col("area_name").alias("name_level_area_name")
    )
    .withColumn(
        "reference_name_normalized",
        normalize_city_name(F.col("name_level_area_name"))
    )
)


adm3_name_candidates = (
    unresolved_after_hierarchy
    .filter(F.col("admin_level") == "3")
    .alias("h")
    .join(
        F.broadcast(city_mun_name_ref).alias("p"),
        F.col("h.boundary_name_city_normalized")
        == F.col("p.reference_name_normalized"),
        "left"
    )
    .groupBy(
        F.col("h.admin_level").alias("admin_level"),
        F.col("h.boundary_pcode").alias("boundary_pcode"),
        F.col("h.source_version").alias("source_version")
    )
    .agg(
        F.countDistinct(
            "name_level_psgc_code"
        ).alias("candidate_count"),

        F.first(
            "name_level_psgc_code",
            ignorenulls=True
        ).alias("name_level_psgc_code")
    )
)


# ---------------------------------------------------------
# Combine candidate results
# ---------------------------------------------------------

name_level_candidate_summary = (
    adm2_name_candidates
    .unionByName(adm3_name_candidates)
)


name_level_distribution = (
    name_level_candidate_summary
    .groupBy(
        "admin_level",
        "candidate_count"
    )
    .count()
    .orderBy(
        "admin_level",
        "candidate_count"
    )
)

show(name_level_distribution)


unique_name_level_count = (
    name_level_candidate_summary
    .filter(F.col("candidate_count") == 1)
    .count()
)

ambiguous_name_level_count = (
    name_level_candidate_summary
    .filter(F.col("candidate_count") > 1)
    .count()
)

print(
    f"Unique NAME_LEVEL candidates : "
    f"{unique_name_level_count}"
)

print(
    f"Ambiguous candidates         : "
    f"{ambiguous_name_level_count}"
)


# -----------------------------------------------------------------------------
# Apply validated NAME_LEVEL_MATCH
# -----------------------------------------------------------------------------
# Keep only unambiguous name + level matches
unique_name_level_matches = (
    name_level_candidate_summary
    .filter(F.col("candidate_count") == 1)
    .select(
        "admin_level",
        "boundary_pcode",
        "source_version",
        "name_level_psgc_code"
    )
)


# Apply only to rows that are still unresolved
working_recon = (
    working_recon.alias("b")
    .join(
        F.broadcast(unique_name_level_matches).alias("n"),
        (
            (F.col("b.admin_level") == F.col("n.admin_level"))
            &
            (F.col("b.boundary_pcode") == F.col("n.boundary_pcode"))
            &
            (F.col("b.source_version") == F.col("n.source_version"))
        ),
        "left"
    )
    .select(
        "b.*",
        F.col("n.name_level_psgc_code")
            .alias("_name_level_psgc_code")
    )
    .withColumn(
        "psgc_code",
        F.coalesce(
            F.col("psgc_code"),
            F.col("_name_level_psgc_code")
        )
    )
    .withColumn(
        "psgc_match_status",
        F.when(
            F.col("psgc_match_status").isNotNull(),
            F.col("psgc_match_status")
        )
        .when(
            F.col("_name_level_psgc_code").isNotNull(),
            F.lit("NAME_LEVEL_MATCH")
        )
    )
    .drop("_name_level_psgc_code")
)


# Reconciliation status after NAME_LEVEL_MATCH
name_level_status_summary = (
    working_recon
    .groupBy("psgc_match_status")
    .count()
    .orderBy("psgc_match_status")
)

show(name_level_status_summary)


remaining_unresolved_count = (
    working_recon
    .filter(F.col("psgc_code").isNull())
    .count()
)

print(
    f"Remaining unresolved after NAME_LEVEL_MATCH: "
    f"{remaining_unresolved_count}"
)


# -----------------------------------------------------------------------------
# Evaluate TYPE_CONTEXT_MATCH Candidates
# -----------------------------------------------------------------------------
# ---------------------------------------------------------
# Remaining unresolved after NAME_LEVEL_MATCH
# ---------------------------------------------------------

unresolved_after_name_level = (
    working_recon
    .filter(F.col("psgc_code").isNull())
    .withColumn(
        "boundary_name_city_normalized",
        normalize_city_name(F.col("boundary_name"))
    )
    .withColumn(
        "adm2_name_basic",
        normalize_basic(F.col("adm2_name"))
    )
)


# ---------------------------------------------------------
# Identify unresolved ADM3 records explicitly named as cities
# ---------------------------------------------------------

city_like_unresolved = (
    unresolved_after_name_level
    .filter(
        (F.col("admin_level") == "3")
        &
        F.col("boundary_name").rlike(
            r"(?i)(^city of\s+| city(?:\s*\([^)]*\))?$)"
        )
    )
)


# ---------------------------------------------------------
# PSGC City-only reference
# ---------------------------------------------------------

psgc_city_ref = (
    psgc_city_mun_ref
    .filter(
        F.col("candidate_geographic_level") == "City"
    )
    .select(
        F.col("candidate_psgc_code")
            .alias("type_psgc_code"),
        F.col("candidate_area_name")
            .alias("type_area_name"),
        F.col("province_name_basic")
            .alias("type_province_name_basic")
    )
    .withColumn(
        "type_city_name_normalized",
        normalize_city_name(F.col("type_area_name"))
    )
)


# ---------------------------------------------------------
# Generate City candidates
# ---------------------------------------------------------

type_context_candidates = (
    city_like_unresolved.alias("h")
    .join(
        F.broadcast(psgc_city_ref).alias("p"),
        F.col("h.boundary_name_city_normalized")
        == F.col("p.type_city_name_normalized"),
        "left"
    )
    .withColumn(
        "_parent_matches",
        F.col("h.adm2_name_basic")
        == F.col("p.type_province_name_basic")
    )
)


# ---------------------------------------------------------
# Evaluate uniqueness and parent-province disambiguation
# ---------------------------------------------------------

type_context_summary = (
    type_context_candidates
    .groupBy(
        F.col("h.admin_level").alias("admin_level"),
        F.col("h.boundary_pcode").alias("boundary_pcode"),
        F.col("h.boundary_name").alias("boundary_name"),
        F.col("h.adm2_name").alias("adm2_name"),
        F.col("h.source_version").alias("source_version")
    )
    .agg(
        F.countDistinct(
            "type_psgc_code"
        ).alias("candidate_count"),

        F.countDistinct(
            F.when(
                F.col("_parent_matches"),
                F.col("type_psgc_code")
            )
        ).alias("parent_candidate_count"),

        F.first(
            "type_psgc_code",
            ignorenulls=True
        ).alias("_single_candidate_code"),

        F.first(
            F.when(
                F.col("_parent_matches"),
                F.col("type_psgc_code")
            ),
            ignorenulls=True
        ).alias("_parent_candidate_code")
    )
    .withColumn(
        "type_context_psgc_code",
        F.when(
            F.col("candidate_count") == 1,
            F.col("_single_candidate_code")
        )
        .when(
            (F.col("candidate_count") > 1)
            & (F.col("parent_candidate_count") == 1),
            F.col("_parent_candidate_code")
        )
    )
    .drop(
        "_single_candidate_code",
        "_parent_candidate_code"
    )
)


show(
    type_context_summary
    .select(
        "boundary_pcode",
        "boundary_name",
        "adm2_name",
        "candidate_count",
        "parent_candidate_count",
        "type_context_psgc_code"
    )
    .orderBy("boundary_pcode")
)


safe_type_context_count = (
    type_context_summary
    .filter(
        F.col("type_context_psgc_code").isNotNull()
    )
    .count()
)

print(
    f"Safe TYPE_CONTEXT matches: "
    f"{safe_type_context_count}"
)


# -----------------------------------------------------------------------------
# Apply Safe TYPE_CONTEXT_MATCH Results
# -----------------------------------------------------------------------------
safe_type_context_matches = (
    type_context_summary
    .filter(
        F.col("type_context_psgc_code").isNotNull()
    )
    .select(
        "admin_level",
        "boundary_pcode",
        "source_version",
        "type_context_psgc_code"
    )
)


working_recon = (
    working_recon.alias("b")
    .join(
        F.broadcast(safe_type_context_matches).alias("t"),
        (
            (F.col("b.admin_level") == F.col("t.admin_level"))
            &
            (F.col("b.boundary_pcode") == F.col("t.boundary_pcode"))
            &
            (F.col("b.source_version") == F.col("t.source_version"))
        ),
        "left"
    )
    .select(
        "b.*",
        F.col("t.type_context_psgc_code")
            .alias("_type_context_psgc_code")
    )
    .withColumn(
        "psgc_code",
        F.coalesce(
            F.col("psgc_code"),
            F.col("_type_context_psgc_code")
        )
    )
    .withColumn(
        "psgc_match_status",
        F.when(
            F.col("psgc_match_status").isNotNull(),
            F.col("psgc_match_status")
        )
        .when(
            F.col("_type_context_psgc_code").isNotNull(),
            F.lit("TYPE_CONTEXT_MATCH")
        )
    )
    .drop("_type_context_psgc_code")
)


type_context_status_summary = (
    working_recon
    .groupBy("psgc_match_status")
    .count()
    .orderBy("psgc_match_status")
)

show(type_context_status_summary)


remaining_unresolved_count = (
    working_recon
    .filter(F.col("psgc_code").isNull())
    .count()
)

print(
    f"Remaining unresolved after TYPE_CONTEXT_MATCH: "
    f"{remaining_unresolved_count}"
)


# -----------------------------------------------------------------------------
# Inspect the remaining unresolved boundaries
# -----------------------------------------------------------------------------
remaining_unresolved = (
    working_recon
    .filter(F.col("psgc_code").isNull())
    .select(
        "admin_level",
        "boundary_pcode",
        "boundary_name",
        "adm1_name",
        "adm2_name",
        "candidate_psgc_code"
    )
    .orderBy(
        "admin_level",
        "boundary_pcode"
    )
)

show(remaining_unresolved)

print(
    "Remaining unresolved records:",
    remaining_unresolved.count()
)


# -----------------------------------------------------------------------------
# Evaluate controlled NAME_VARIANT_MATCH
# -----------------------------------------------------------------------------
# Controlled normalization used only as a reconciliation key.
# Original HDX and PSGC names remain unchanged.

def normalize_variant_name(column):
    return F.trim(
        F.regexp_replace(
            F.regexp_replace(
                normalize_city_name(
                    F.regexp_replace(
                        F.regexp_replace(
                            column,
                            "\u00c3\u00b1",
                            "ñ"
                        ),
                        "\u00c3\u2018",
                        "Ñ"
                    )
                ),
                r"[-–—]",
                " "
            ),
            r"\s+",
            " "
        )
    )


# ---------------------------------------------------------
# Only unresolved ADM3 rows outside the special-structure parents (YAML)
# ---------------------------------------------------------

variant_source = (
    working_recon
    .filter(
        F.col("psgc_code").isNull()
        &
        (F.col("admin_level") == "3")
        &
        (
            ~F.coalesce(F.col("adm2_name"), F.lit("")).isin(SPECIAL_ADM3_PARENTS)
            if SPECIAL_ADM3_PARENTS else F.lit(True)
        )
    )
    .withColumn(
        "variant_name_key",
        normalize_variant_name(
            F.col("boundary_name")
        )
    )
)


# ---------------------------------------------------------
# PSGC City / Municipality reference with same normalization
# ---------------------------------------------------------

variant_psgc_ref = (
    psgc_admin_ref
    .filter(
        F.col("geographic_level").isin(
            "City",
            "Mun"
        )
    )
    .select(
        F.col("psgc_code")
            .alias("variant_psgc_code"),
        F.col("area_name")
            .alias("variant_psgc_name")
    )
    .withColumn(
        "variant_reference_key",
        normalize_variant_name(
            F.col("variant_psgc_name")
        )
    )
)


# ---------------------------------------------------------
# Evaluate candidate uniqueness
# ---------------------------------------------------------

variant_candidate_summary = (
    variant_source.alias("h")
    .join(
        F.broadcast(variant_psgc_ref).alias("p"),
        F.col("h.variant_name_key")
        == F.col("p.variant_reference_key"),
        "left"
    )
    .groupBy(
        F.col("h.admin_level").alias("admin_level"),
        F.col("h.boundary_pcode").alias("boundary_pcode"),
        F.col("h.boundary_name").alias("boundary_name"),
        F.col("h.source_version").alias("source_version")
    )
    .agg(
        F.countDistinct(
            "variant_psgc_code"
        ).alias("candidate_count"),

        F.first(
            "variant_psgc_code",
            ignorenulls=True
        ).alias("name_variant_psgc_code")
    )
)


show(
    variant_candidate_summary
    .select(
        "boundary_pcode",
        "boundary_name",
        "candidate_count",
        "name_variant_psgc_code"
    )
    .orderBy("boundary_pcode")
)


safe_variant_count = (
    variant_candidate_summary
    .filter(F.col("candidate_count") == 1)
    .count()
)

ambiguous_variant_count = (
    variant_candidate_summary
    .filter(F.col("candidate_count") > 1)
    .count()
)

print(f"Safe NAME_VARIANT matches : {safe_variant_count}")
print(f"Ambiguous variant matches : {ambiguous_variant_count}")


# -----------------------------------------------------------------------------
# Apply NAME_VARIANT_MATCH
# -----------------------------------------------------------------------------
# Keep only unique controlled name-variant matches
safe_variant_matches = (
    variant_candidate_summary
    .filter(F.col("candidate_count") == 1)
    .select(
        "admin_level",
        "boundary_pcode",
        "source_version",
        "name_variant_psgc_code"
    )
)


# Apply NAME_VARIANT_MATCH to still-unresolved rows
working_recon = (
    working_recon.alias("b")
    .join(
        F.broadcast(safe_variant_matches).alias("v"),
        (
            (F.col("b.admin_level") == F.col("v.admin_level"))
            &
            (F.col("b.boundary_pcode") == F.col("v.boundary_pcode"))
            &
            (F.col("b.source_version") == F.col("v.source_version"))
        ),
        "left"
    )
    .select(
        "b.*",
        F.col("v.name_variant_psgc_code")
            .alias("_name_variant_psgc_code")
    )
    .withColumn(
        "psgc_code",
        F.coalesce(
            F.col("psgc_code"),
            F.col("_name_variant_psgc_code")
        )
    )
    .withColumn(
        "psgc_match_status",
        F.when(
            F.col("psgc_match_status").isNotNull(),
            F.col("psgc_match_status")
        )
        .when(
            F.col("_name_variant_psgc_code").isNotNull(),
            F.lit("NAME_VARIANT_MATCH")
        )
    )
    .drop("_name_variant_psgc_code")
)


variant_status_summary = (
    working_recon
    .groupBy("psgc_match_status")
    .count()
    .orderBy("psgc_match_status")
)

show(variant_status_summary)


remaining_unresolved_count = (
    working_recon
    .filter(F.col("psgc_code").isNull())
    .count()
)

print(
    f"Remaining unresolved after NAME_VARIANT_MATCH: "
    f"{remaining_unresolved_count}"
)


# -----------------------------------------------------------------------------
# Classify Legitimate SPECIAL_STRUCTURE Records
# -----------------------------------------------------------------------------
# Identify legitimate HDX administrative structures that do not
# have a direct one-to-one equivalent in the selected PSGC reference.

# Names come from hdx_phl_admin.silver_qc.special_structures (YAML).
adm2_special_name = F.lit(False)
for prefix in SPECIAL_ADM2_PREFIXES:
    adm2_special_name = adm2_special_name | F.col("boundary_name").startswith(prefix)
if SPECIAL_ADM2_NAMES:
    adm2_special_name = adm2_special_name | F.col("boundary_name").isin(SPECIAL_ADM2_NAMES)

special_structure_condition = (
    # ADM2 special structures (Metro Manila, Isabela City placeholder, BARMM SGA)
    ((F.col("admin_level") == "2") & adm2_special_name)

    |

    # ADM3 children of the BARMM Special Geographic Area
    (
        (F.col("admin_level") == "3")
        &
        (F.col("adm2_name").isin(SPECIAL_ADM3_PARENTS) if SPECIAL_ADM3_PARENTS else F.lit(False))
    )
)


working_recon = (
    working_recon
    .withColumn(
        "psgc_match_status",
        F.when(
            F.col("psgc_match_status").isNotNull(),
            F.col("psgc_match_status")
        )
        .when(
            special_structure_condition,
            F.lit("SPECIAL_STRUCTURE")
        )
    )
)


# ---------------------------------------------------------
# Validate reconciliation completeness
# ---------------------------------------------------------

reconciliation_summary = (
    working_recon
    .groupBy("psgc_match_status")
    .count()
    .orderBy("psgc_match_status")
)

show(reconciliation_summary)


special_structure_count = (
    working_recon
    .filter(
        F.col("psgc_match_status") == "SPECIAL_STRUCTURE"
    )
    .count()
)

unclassified_count = (
    working_recon
    .filter(
        F.col("psgc_match_status").isNull()
    )
    .count()
)

unexpected_null_psgc_count = (
    working_recon
    .filter(
        F.col("psgc_code").isNull()
        &
        (F.col("psgc_match_status") != "SPECIAL_STRUCTURE")
    )
    .count()
)


if unclassified_count > 0:
    raise ValueError(
        f"Reconciliation incomplete: "
        f"{unclassified_count} row(s) remain unclassified."
    )

if unexpected_null_psgc_count > 0:
    raise ValueError(
        f"Reconciliation integrity failed: "
        f"{unexpected_null_psgc_count} unexpected NULL PSGC code(s)."
    )


print("PSGC reconciliation classification passed.")
print(f"Total boundaries       : {bronze_row_count}")
print(f"Special structures     : {special_structure_count}")
print(f"Unclassified records   : {unclassified_count}")
print(f"Unexpected NULL PSGC   : {unexpected_null_psgc_count}")


# -----------------------------------------------------------------------------
# Build the final Silver candidate
# -----------------------------------------------------------------------------
silver_candidate = (
    working_recon

    # Human-readable explanation of how PSGC reconciliation was achieved
    .withColumn(
        "psgc_match_detail",
        F.when(
            F.col("psgc_match_status") == "CODE_MATCH",
            F.lit(
                "Direct HDX P-code to PSGC code match."
            )
        )
        .when(
            F.col("psgc_match_status") == "HIERARCHY_MATCH",
            F.lit(
                "Unique normalized City/Municipality name "
                "plus parent province match."
            )
        )
        .when(
            F.col("psgc_match_status") == "NAME_LEVEL_MATCH",
            F.lit(
                "Unique normalized name match within the "
                "expected PSGC geographic level."
            )
        )
        .when(
            F.col("psgc_match_status") == "TYPE_CONTEXT_MATCH",
            F.lit(
                "City-type match resolved using geographic "
                "type and parent context where required."
            )
        )
        .when(
            F.col("psgc_match_status") == "NAME_VARIANT_MATCH",
            F.lit(
                "Controlled punctuation or encoding normalization "
                "used for a unique PSGC name match."
            )
        )
        .when(
            F.col("psgc_match_status") == "SPECIAL_STRUCTURE",
            F.lit(
                "HDX administrative structure has no one-to-one "
                "equivalent in the selected PSGC reference."
            )
        )
    )

    # Preserve the exact PSGC reference snapshot used
    .withColumn(
        "psgc_reference_version",
        F.lit(selected_psgc_source_version)
    )
    .withColumn(
        "psgc_reference_checksum",
        F.lit(selected_psgc_checksum)
    )

    # Silver processing lineage
    .withColumn(
        "silver_processed_at",
        F.current_timestamp()
    )

    # Final Silver contract only.
    # Temporary reconciliation/helper columns are intentionally excluded.
    .select(
        "admin_level",
        "boundary_pcode",
        "boundary_name",

        "adm1_pcode",
        "adm1_name",
        "adm2_pcode",
        "adm2_name",

        "candidate_psgc_code",
        "psgc_code",
        "psgc_match_status",
        "psgc_match_detail",

        "area_sqkm",
        "center_lat",
        "center_lon",
        "geometry_type",
        "geometry_json",
        "source_crs",

        "valid_on",
        "valid_to",
        "boundary_version",

        "source_version",
        "batch_id",
        "source_file",
        "source_file_sha256",
        "record_sha256",

        "psgc_reference_version",
        "psgc_reference_checksum",
        "silver_processed_at"
    )
)


print("Final Silver candidate created.")

silver_candidate.printSchema()

show(
    silver_candidate
    .select(
        "admin_level",
        "boundary_pcode",
        "boundary_name",
        "psgc_code",
        "psgc_match_status",
        "area_sqkm",
        "center_lat",
        "center_lon"
    )
    .orderBy(
        "admin_level",
        "boundary_pcode"
    )
    .limit(20)
)


# -----------------------------------------------------------------------------
# Inspect QC configuration and QC target schema
# -----------------------------------------------------------------------------
# Validate that the final Silver candidate satisfies
# the configured DQ contract before running quality checks.

missing_required_columns = [
    column_name
    for column_name in SILVER_REQUIRED_COLUMNS
    if column_name not in silver_candidate.columns
]

if missing_required_columns:
    raise ValueError(
        f"Silver DQ contract failed. "
        f"Missing required column(s): "
        f"{missing_required_columns}"
    )


print("Admin Boundaries Silver DQ contract validated.")
print(
    f"Required columns : "
    f"{SILVER_REQUIRED_COLUMNS}"
)
print(
    f"Geometry types   : "
    f"{SILVER_GEOMETRY_TYPES}"
)
print(
    f"Admin levels     : "
    f"{REQUIRED_LEVELS}"
)


# -----------------------------------------------------------------------------
# Compute DQ metrics
# -----------------------------------------------------------------------------
accepted_match_statuses = [
    "CODE_MATCH",
    "HIERARCHY_MATCH",
    "NAME_LEVEL_MATCH",
    "TYPE_CONTEXT_MATCH",
    "NAME_VARIANT_MATCH",
    "SPECIAL_STRUCTURE",
]


# Compact PSGC lookup used only for referential-integrity validation
psgc_code_lookup = (
    psgc_admin_ref
    .select(
        F.col("psgc_code").alias("dq_ref_psgc_code")
    )
    .distinct()
)


dq_input = (
    silver_candidate.alias("s")
    .join(
        F.broadcast(psgc_code_lookup).alias("p"),
        F.col("s.psgc_code") == F.col("p.dq_ref_psgc_code"),
        "left"
    )
)


# ---------------------------------------------------------
# AB01 — Required-field completeness condition
# ---------------------------------------------------------

required_field_issue = None

for column_name in SILVER_REQUIRED_COLUMNS:
    condition = (
        F.col(column_name).isNull()
        |
        (
            F.trim(
                F.col(column_name).cast("string")
            ) == ""
        )
    )

    required_field_issue = (
        condition
        if required_field_issue is None
        else required_field_issue | condition
    )


# ---------------------------------------------------------
# Compute DQ metrics in one main aggregation
# ---------------------------------------------------------

dq_metrics = (
    dq_input
    .agg(
        F.count("*").alias("silver_row_count"),

        # AB01 — Completeness
        F.sum(
            F.when(
                required_field_issue,
                1
            ).otherwise(0)
        ).alias("completeness_fail_count"),

        # AB02 — Logical-key uniqueness
        F.countDistinct(
            F.struct(
                "admin_level",
                "boundary_pcode",
                "source_version"
            )
        ).alias("distinct_logical_keys"),

        # AB03 — Accepted values
        F.sum(
            F.when(
                F.col("admin_level").isNull()
                |
                ~F.col("admin_level").isin(REQUIRED_LEVELS),
                1
            ).otherwise(0)
        ).alias("invalid_admin_level_count"),

        F.sum(
            F.when(
                F.col("geometry_type").isNull()
                |
                ~F.col("geometry_type").isin(
                    SILVER_GEOMETRY_TYPES
                ),
                1
            ).otherwise(0)
        ).alias("invalid_geometry_type_count"),

        # AB05 — PSGC reconciliation integrity
        F.sum(
            F.when(
                F.col("psgc_match_status").isNull()
                |
                ~F.col("psgc_match_status").isin(
                    accepted_match_statuses
                ),
                1
            ).otherwise(0)
        ).alias("invalid_match_status_count"),

        F.sum(
            F.when(
                (F.col("psgc_match_status") != "SPECIAL_STRUCTURE")
                &
                F.col("psgc_code").isNull(),
                1
            ).otherwise(0)
        ).alias("unexpected_null_psgc_count"),

        F.sum(
            F.when(
                F.col("psgc_code").isNotNull()
                &
                F.col("dq_ref_psgc_code").isNull(),
                1
            ).otherwise(0)
        ).alias("invalid_psgc_reference_count"),

        F.sum(
            F.when(
                (F.col("psgc_match_status") == "SPECIAL_STRUCTURE")
                &
                F.col("psgc_code").isNotNull(),
                1
            ).otherwise(0)
        ).alias("special_structure_psgc_issue_count"),

        F.sum(
            F.when(
                F.col("psgc_match_status") == "SPECIAL_STRUCTURE",
                1
            ).otherwise(0)
        ).alias("special_structure_count"),

        # AB06 — Spatial validity
        F.sum(
            F.when(
                F.col("area_sqkm").isNull()
                |
                (F.col("area_sqkm") <= 0)
                |
                F.col("center_lat").isNull()
                |
                ~F.col("center_lat").between(-90, 90)
                |
                F.col("center_lon").isNull()
                |
                ~F.col("center_lon").between(-180, 180),
                1
            ).otherwise(0)
        ).alias("spatial_fail_count")
    )
    .collect()[0]
)


silver_row_count = dq_metrics["silver_row_count"]

duplicate_row_count = (
    silver_row_count
    - dq_metrics["distinct_logical_keys"]
)

volume_difference = abs(
    bronze_row_count - silver_row_count
)


print("AB01 — Completeness")
print(
    "Failures:",
    dq_metrics["completeness_fail_count"]
)

print("\nAB02 — Logical-key uniqueness")
print("Duplicate rows:", duplicate_row_count)

print("\nAB03 — Accepted values")
print(
    "Invalid admin levels:",
    dq_metrics["invalid_admin_level_count"]
)
print(
    "Invalid geometry types:",
    dq_metrics["invalid_geometry_type_count"]
)

print("\nAB04 — Bronze → Silver volume")
print("Bronze rows:", bronze_row_count)
print("Silver rows:", silver_row_count)
print("Difference :", volume_difference)

print("\nAB05 — PSGC reconciliation")
print(
    "Invalid match statuses:",
    dq_metrics["invalid_match_status_count"]
)
print(
    "Unexpected NULL PSGC:",
    dq_metrics["unexpected_null_psgc_count"]
)
print(
    "Invalid PSGC references:",
    dq_metrics["invalid_psgc_reference_count"]
)
print(
    "Special-structure PSGC issues:",
    dq_metrics["special_structure_psgc_issue_count"]
)
print(
    "Special structures:",
    dq_metrics["special_structure_count"]
)

print("\nAB06 — Spatial validity")
print(
    "Spatial failures:",
    dq_metrics["spatial_fail_count"]
)


# -----------------------------------------------------------------------------
# Build QC Audit Records
# -----------------------------------------------------------------------------
# Create identifiers for this validation execution

run_id = JOB_RUN_ID or str(uuid.uuid4())
validation_id = str(uuid.uuid4())
executed_at = datetime.now(timezone.utc)


def calculate_fail_pct(fail_count, total_count):
    if total_count == 0:
        return 0.0

    return round(
        (fail_count / total_count) * 100,
        4
    )


# ---------------------------------------------------------
# Combine related metrics per DQ check
# ---------------------------------------------------------

accepted_value_fail_count = (
    dq_metrics["invalid_admin_level_count"]
    + dq_metrics["invalid_geometry_type_count"]
)

psgc_integrity_issue_count = (
    dq_metrics["invalid_match_status_count"]
    + dq_metrics["unexpected_null_psgc_count"]
    + dq_metrics["invalid_psgc_reference_count"]
    + dq_metrics["special_structure_psgc_issue_count"]
)


# ---------------------------------------------------------
# Build QC audit rows
# ---------------------------------------------------------

qc_rows = [
    {
        "run_id": run_id,
        "validation_id": validation_id,
        "batch_id": selected_batch_id,
        "source_key": SOURCE_KEY,
        "table_name": SILVER_TABLE,
        "layer": "silver",
        "executed_at": executed_at,

        "check_id": "AB01",
        "check_name": "Required field completeness",
        "check_type": "COMPLETENESS",
        "column_name": None,
        "admin_level": None,

        "status": (
            "PASS"
            if dq_metrics["completeness_fail_count"] == 0
            else "FAIL"
        ),
        "severity": "FAIL",

        "fail_count": dq_metrics["completeness_fail_count"],
        "total_count": silver_row_count,
        "fail_pct": calculate_fail_pct(
            dq_metrics["completeness_fail_count"],
            silver_row_count
        ),
        "threshold": 0.0,

        "observed": str(
            dq_metrics["completeness_fail_count"]
        ),
        "expected": "0 missing required Silver fields",

        "detail": (
            "Validates configured "
            "hdx_phl_admin.silver_qc.required_columns."
        ),
    },

    {
        "run_id": run_id,
        "validation_id": validation_id,
        "batch_id": selected_batch_id,
        "source_key": SOURCE_KEY,
        "table_name": SILVER_TABLE,
        "layer": "silver",
        "executed_at": executed_at,

        "check_id": "AB02",
        "check_name": "Logical key uniqueness",
        "check_type": "UNIQUENESS",
        "column_name": None,
        "admin_level": None,

        "status": (
            "PASS"
            if duplicate_row_count == 0
            else "FAIL"
        ),
        "severity": "FAIL",

        "fail_count": duplicate_row_count,
        "total_count": silver_row_count,
        "fail_pct": calculate_fail_pct(
            duplicate_row_count,
            silver_row_count
        ),
        "threshold": 0.0,

        "observed": str(duplicate_row_count),
        "expected": "0 duplicate logical keys",

        "detail": (
            "Logical key = "
            "admin_level + boundary_pcode + source_version."
        ),
    },

    {
        "run_id": run_id,
        "validation_id": validation_id,
        "batch_id": selected_batch_id,
        "source_key": SOURCE_KEY,
        "table_name": SILVER_TABLE,
        "layer": "silver",
        "executed_at": executed_at,

        "check_id": "AB03",
        "check_name": "Accepted administrative and geometry values",
        "check_type": "ACCEPTED_VALUES",
        "column_name": None,
        "admin_level": None,

        "status": (
            "PASS"
            if accepted_value_fail_count == 0
            else "FAIL"
        ),
        "severity": "FAIL",

        "fail_count": accepted_value_fail_count,
        "total_count": silver_row_count,
        "fail_pct": calculate_fail_pct(
            accepted_value_fail_count,
            silver_row_count
        ),
        "threshold": 0.0,

        "observed": (
            f"invalid_admin_level="
            f"{dq_metrics['invalid_admin_level_count']}; "
            f"invalid_geometry_type="
            f"{dq_metrics['invalid_geometry_type_count']}"
        ),

        "expected": (
            f"admin_level in {REQUIRED_LEVELS}; "
            f"geometry_type in {SILVER_GEOMETRY_TYPES}"
        ),

        "detail": (
            "Validates configured administrative levels "
            "and geometry types."
        ),
    },

    {
        "run_id": run_id,
        "validation_id": validation_id,
        "batch_id": selected_batch_id,
        "source_key": SOURCE_KEY,
        "table_name": SILVER_TABLE,
        "layer": "silver",
        "executed_at": executed_at,

        "check_id": "AB04",
        "check_name": "Bronze to Silver row-count reconciliation",
        "check_type": "VOLUME",
        "column_name": None,
        "admin_level": None,

        "status": (
            "PASS"
            if volume_difference == 0
            else "FAIL"
        ),
        "severity": "FAIL",

        "fail_count": volume_difference,
        "total_count": bronze_row_count,
        "fail_pct": calculate_fail_pct(
            volume_difference,
            bronze_row_count
        ),
        "threshold": 0.0,

        "observed": (
            f"bronze={bronze_row_count}; "
            f"silver_candidate={silver_row_count}"
        ),

        "expected": (
            "Bronze and Silver candidate row counts are equal"
        ),

        "detail": (
            "The transformation must preserve one Silver "
            "candidate per selected Bronze boundary feature."
        ),
    },

    {
        "run_id": run_id,
        "validation_id": validation_id,
        "batch_id": selected_batch_id,
        "source_key": SOURCE_KEY,
        "table_name": SILVER_TABLE,
        "layer": "silver",
        "executed_at": executed_at,

        "check_id": "AB05",
        "check_name": "PSGC reconciliation integrity",
        "check_type": "REFERENTIAL_INTEGRITY",
        "column_name": "psgc_code",
        "admin_level": None,

        "status": (
            "PASS"
            if psgc_integrity_issue_count == 0
            else "WARN"
        ),
        "severity": "WARN",

        "fail_count": psgc_integrity_issue_count,
        "total_count": silver_row_count,
        "fail_pct": calculate_fail_pct(
            psgc_integrity_issue_count,
            silver_row_count
        ),
        "threshold": 0.0,

        "observed": (
            f"integrity_issues={psgc_integrity_issue_count}; "
            f"special_structures="
            f"{dq_metrics['special_structure_count']}"
        ),

        "expected": (
            "0 unexplained PSGC reconciliation issues; "
            "documented special structures allowed"
        ),

        "detail": (
            "SPECIAL_STRUCTURE records may retain NULL psgc_code. "
            "All other mapped PSGC codes must exist in the "
            "selected PSGC reference snapshot."
        ),
    },

    {
        "run_id": run_id,
        "validation_id": validation_id,
        "batch_id": selected_batch_id,
        "source_key": SOURCE_KEY,
        "table_name": SILVER_TABLE,
        "layer": "silver",
        "executed_at": executed_at,

        "check_id": "AB06",
        "check_name": "Spatial attribute validity",
        "check_type": "RANGE",
        "column_name": None,
        "admin_level": None,

        "status": (
            "PASS"
            if dq_metrics["spatial_fail_count"] == 0
            else "FAIL"
        ),
        "severity": "FAIL",

        "fail_count": dq_metrics["spatial_fail_count"],
        "total_count": silver_row_count,
        "fail_pct": calculate_fail_pct(
            dq_metrics["spatial_fail_count"],
            silver_row_count
        ),
        "threshold": 0.0,

        "observed": str(
            dq_metrics["spatial_fail_count"]
        ),

        "expected": (
            "area_sqkm > 0; "
            "valid latitude and longitude ranges"
        ),

        "detail": (
            "Validates spatial attributes used for downstream "
            "facility-access and geographic analysis."
        ),
    },
]


# ---------------------------------------------------------
# Use the centralized QC table schema
# ---------------------------------------------------------

qc_target_schema = spark.table(QC_TABLE).schema

qc_results_df = spark.createDataFrame(
    qc_rows,
    schema=qc_target_schema
)


show(
    qc_results_df
    .select(
        "check_id",
        "check_name",
        "status",
        "severity",
        "fail_count",
        "total_count",
        "observed"
    )
    .orderBy("check_id")
)


# -----------------------------------------------------------------------------
# Write QC Results Idempotently and Verify Persistence
# -----------------------------------------------------------------------------
# Register the current QC results as a temporary MERGE source
qc_results_df.createOrReplaceTempView(
    "admin_boundaries_qc_results"
)


# Insert only QC records that do not already exist
spark.sql(f"""
MERGE INTO {QC_TABLE} AS target

USING admin_boundaries_qc_results AS source

ON  target.validation_id = source.validation_id
AND target.check_id = source.check_id

WHEN NOT MATCHED THEN
  INSERT *
""")


# ---------------------------------------------------------
# Verify persisted QC records
# ---------------------------------------------------------

persisted_qc = (
    spark.table(QC_TABLE)
    .filter(
        F.col("validation_id") == validation_id
    )
)

expected_qc_count = len(qc_rows)

persisted_qc_metrics = (
    persisted_qc
    .agg(
        F.count("*").alias("row_count"),
        F.countDistinct("check_id").alias("distinct_check_count")
    )
    .collect()[0]
)

persisted_qc_count = persisted_qc_metrics["row_count"]
distinct_check_count = persisted_qc_metrics["distinct_check_count"]


if persisted_qc_count != expected_qc_count:
    raise ValueError(
        f"QC persistence validation failed: "
        f"expected {expected_qc_count} rows, "
        f"found {persisted_qc_count}."
    )

if distinct_check_count != expected_qc_count:
    raise ValueError(
        f"QC persistence validation failed: "
        f"expected {expected_qc_count} unique checks, "
        f"found {distinct_check_count}."
    )


print("QC results persisted successfully.")
print(f"Validation ID        : {validation_id}")
print(f"Expected QC records  : {expected_qc_count}")
print(f"Persisted QC records : {persisted_qc_count}")
print(f"Distinct checks      : {distinct_check_count}")


show(
    persisted_qc
    .select(
        "check_id",
        "status",
        "severity",
        "fail_count",
        "total_count"
    )
    .orderBy("check_id")
)


# -----------------------------------------------------------------------------
# DQ Gate Before Silver Promotion
# -----------------------------------------------------------------------------
current_qc = (
    spark.table(QC_TABLE)
    .filter(
        F.col("validation_id") == validation_id
    )
)

blocking_failures = (
    current_qc
    .filter(
        (F.col("status") == "FAIL")
        &
        (F.col("severity") == "FAIL")
    )
    .count()
)

if blocking_failures > 0:
    raise ValueError(
        f"Silver promotion blocked: "
        f"{blocking_failures} blocking DQ check(s) failed. "
        f"validation_id={validation_id}"
    )

print("DQ gate passed.")
print(f"Blocking failures: {blocking_failures}")
print(f"Validation ID: {validation_id}")


# -----------------------------------------------------------------------------
# Ensure the Silver target table exists
# -----------------------------------------------------------------------------
# Create the Silver table from the candidate schema if it is missing. If it exists (for
# example an older copy in a teammate's workspace), add any candidate column it lacks, so the
# change report and the INSERT * MERGE below can resolve every column.
if not spark.catalog.tableExists(SILVER_TABLE):
    (
        silver_candidate
        .limit(0)
        .write
        .format("delta")
        .mode("overwrite")
        .saveAsTable(SILVER_TABLE)
    )

    print(f"Created Silver table: {SILVER_TABLE}")

else:
    target_types = {
        field.name: field.dataType.simpleString()
        for field in spark.table(SILVER_TABLE).schema.fields
    }
    previous = None
    added = []
    for field in silver_candidate.schema.fields:
        if field.name not in target_types:
            position = f" AFTER `{previous}`" if previous in target_types else ""
            spark.sql(
                f"ALTER TABLE {SILVER_TABLE} "
                f"ADD COLUMNS (`{field.name}` {field.dataType.simpleString()}{position})"
            )
            target_types[field.name] = field.dataType.simpleString()
            added.append(field.name)
        previous = field.name

    type_differences = [
        f"{field.name}: table {target_types[field.name]} vs candidate {field.dataType.simpleString()}"
        for field in silver_candidate.schema.fields
        if target_types[field.name] != field.dataType.simpleString()
    ]
    extra_columns = sorted(set(target_types) - set(silver_candidate.columns))

    print(f"Silver table already exists: {SILVER_TABLE}")
    print(f"Columns added      : {added or 'none'}")
    if type_differences:
        print("Type differences (review if the MERGE fails):")
        for difference in type_differences:
            print(f"  {difference}")
    if extra_columns:
        print(f"Table-only columns (not in the candidate; review if the MERGE fails): {extra_columns}")

spark.table(SILVER_TABLE).printSchema()


# -----------------------------------------------------------------------------
# Change report: PSGC code and match status vs the current Silver table
# -----------------------------------------------------------------------------
changed = (
    silver_candidate.alias("c")
    .join(
        spark.table(SILVER_TABLE).alias("t"),
        on=["admin_level", "boundary_pcode", "source_version"],
        how="full",
    )
    .filter(
        ~F.col("c.psgc_code").eqNullSafe(F.col("t.psgc_code"))
        | ~F.col("c.psgc_match_status").eqNullSafe(F.col("t.psgc_match_status"))
    )
    .select(
        "boundary_pcode",
        F.col("c.boundary_name").alias("boundary_name"),
        F.col("c.adm2_name").alias("adm2_name"),
        F.col("t.psgc_code").alias("old_psgc_code"),
        F.col("c.psgc_code").alias("new_psgc_code"),
        F.col("t.psgc_match_status").alias("old_status"),
        F.col("c.psgc_match_status").alias("new_status"),
    )
    .orderBy("boundary_pcode")
)
show(changed)
print(f"Changed rows: {changed.count()}")


# -----------------------------------------------------------------------------
# AB07: one boundary per PSGC code per level
# -----------------------------------------------------------------------------
duplicate_psgc_count = (
    silver_candidate
    .filter(F.col("psgc_code").isNotNull())
    .groupBy("admin_level", "psgc_code", "source_version")
    .count()
    .filter("count > 1")
    .count()
)
print(f"AB07 — PSGC codes on more than one boundary: {duplicate_psgc_count}")
if duplicate_psgc_count > 0:
    raise ValueError(f"AB07: {duplicate_psgc_count} PSGC codes are on more than one boundary.")


# -----------------------------------------------------------------------------
# Replace this source version (rows are re-inserted by the MERGE below)
# -----------------------------------------------------------------------------
# added candidate_version so this notebook works when a new boundary file arrives
candidate_versions = [
    row["source_version"]
    for row in silver_candidate.select("source_version").distinct().collect()
]
version_list = ", ".join(f"'{v}'" for v in candidate_versions)

spark.sql(f"""
DELETE FROM {SILVER_TABLE}
WHERE source_version IN ({version_list})
""")


# -----------------------------------------------------------------------------
# Merge Validated Records into Silver Idempotently
# -----------------------------------------------------------------------------
# Register the validated Silver candidate as the MERGE source
silver_candidate.createOrReplaceTempView(
    "admin_boundaries_silver_candidate"
)


# Insert only logical keys that do not already exist
spark.sql(f"""
MERGE INTO {SILVER_TABLE} AS target

USING admin_boundaries_silver_candidate AS source

ON  target.admin_level = source.admin_level
AND target.boundary_pcode = source.boundary_pcode
AND target.source_version = source.source_version

WHEN NOT MATCHED THEN
  INSERT *
""")


print("Silver MERGE completed successfully.")
print(f"Target table: {SILVER_TABLE}")
print(
    "Logical key: "
    "admin_level + boundary_pcode + source_version"
)


# -----------------------------------------------------------------------------
# Post-MERGE Silver validation
# -----------------------------------------------------------------------------
# Validate the persisted Silver rows for the current source snapshot
silver_post_merge = (
    spark.table(SILVER_TABLE)
    .filter(
        F.col("source_version") == selected_source_version
    )
    .agg(
        F.count("*").alias("row_count"),

        F.countDistinct(
            F.struct(
                "admin_level",
                "boundary_pcode",
                "source_version"
            )
        ).alias("distinct_logical_keys")
    )
    .collect()[0]
)


persisted_row_count = silver_post_merge["row_count"]
persisted_distinct_keys = silver_post_merge["distinct_logical_keys"]

persisted_duplicate_rows = (
    persisted_row_count - persisted_distinct_keys
)


# Validate persisted snapshot
if persisted_row_count != silver_row_count:
    raise ValueError(
        f"Silver row-count mismatch. "
        f"Expected {silver_row_count}, "
        f"found {persisted_row_count}."
    )

if persisted_duplicate_rows != 0:
    raise ValueError(
        f"Silver contains "
        f"{persisted_duplicate_rows} duplicate logical-key row(s)."
    )


# Read latest Delta operation metrics
latest_merge = (
    spark.sql(
        f"DESCRIBE HISTORY {SILVER_TABLE}"
    )
    .select(
        "operation",
        "operationMetrics"
    )
    .first()
)

merge_metrics = latest_merge["operationMetrics"]

rows_inserted = int(
    merge_metrics.get("numTargetRowsInserted", "0")
)

rows_updated = int(
    merge_metrics.get("numTargetRowsUpdated", "0")
)


print("Post-MERGE Silver validation passed.")
print(f"Source version        : {selected_source_version}")
print(f"Expected rows         : {silver_row_count}")
print(f"Persisted rows        : {persisted_row_count}")
print(f"Distinct logical keys : {persisted_distinct_keys}")
print(f"Duplicate rows        : {persisted_duplicate_rows}")

print("\nLatest MERGE metrics")
print(f"Rows inserted : {rows_inserted}")
print(f"Rows updated  : {rows_updated}")


# -----------------------------------------------------------------------------
# Prove Silver MERGE idempotency (reruns the same MERGE; expect 0 inserts / 0 updates)
# -----------------------------------------------------------------------------
if PROVE_IDEMPOTENCY:
    # Intentionally rerun the same validated Silver candidate
    # to prove that the MERGE is idempotent.

    silver_candidate.createOrReplaceTempView(
        "admin_boundaries_silver_candidate"
    )


    spark.sql(f"""
    MERGE INTO {SILVER_TABLE} AS target

    USING admin_boundaries_silver_candidate AS source

    ON  target.admin_level = source.admin_level
    AND target.boundary_pcode = source.boundary_pcode
    AND target.source_version = source.source_version

    WHEN NOT MATCHED THEN
      INSERT *
    """)


    # ---------------------------------------------------------
    # Read the rerun MERGE metrics
    # ---------------------------------------------------------

    rerun_operation = (
        spark.sql(
            f"DESCRIBE HISTORY {SILVER_TABLE}"
        )
        .select(
            "operation",
            "operationMetrics"
        )
        .first()
    )

    rerun_metrics = rerun_operation["operationMetrics"]

    rerun_rows_inserted = int(
        rerun_metrics.get("numTargetRowsInserted", "0")
    )

    rerun_rows_updated = int(
        rerun_metrics.get("numTargetRowsUpdated", "0")
    )


    # ---------------------------------------------------------
    # Validate persisted current source snapshot
    # ---------------------------------------------------------

    rerun_snapshot = (
        spark.table(SILVER_TABLE)
        .filter(
            F.col("source_version") == selected_source_version
        )
        .agg(
            F.count("*").alias("row_count"),

            F.countDistinct(
                F.struct(
                    "admin_level",
                    "boundary_pcode",
                    "source_version"
                )
            ).alias("distinct_logical_keys")
        )
        .collect()[0]
    )

    rerun_row_count = rerun_snapshot["row_count"]

    rerun_duplicate_rows = (
        rerun_row_count
        - rerun_snapshot["distinct_logical_keys"]
    )


    # ---------------------------------------------------------
    # Idempotency assertions
    # ---------------------------------------------------------

    if rerun_rows_inserted != 0:
        raise ValueError(
            f"Idempotency failed: "
            f"{rerun_rows_inserted} row(s) were inserted "
            f"when the same snapshot was rerun."
        )

    if rerun_rows_updated != 0:
        raise ValueError(
            f"Idempotency failed: "
            f"{rerun_rows_updated} row(s) were updated "
            f"when the same snapshot was rerun."
        )

    if rerun_row_count != silver_row_count:
        raise ValueError(
            f"Idempotency failed: "
            f"expected {silver_row_count} persisted rows, "
            f"found {rerun_row_count}."
        )

    if rerun_duplicate_rows != 0:
        raise ValueError(
            f"Idempotency failed: "
            f"{rerun_duplicate_rows} duplicate logical-key row(s) found."
        )


    print("Silver idempotency validation passed.")
    print(f"Rows inserted on rerun : {rerun_rows_inserted}")
    print(f"Rows updated on rerun  : {rerun_rows_updated}")
    print(f"Persisted rows         : {rerun_row_count}")
    print(f"Duplicate logical keys : {rerun_duplicate_rows}")
else:
    rerun_rows_inserted = rerun_rows_updated = "skipped"
    rerun_row_count = persisted_row_count
    rerun_duplicate_rows = persisted_duplicate_rows
    print("Idempotency proof skipped (--prove_idempotency false).")


# -----------------------------------------------------------------------------
# Final Silver pipeline summary
# -----------------------------------------------------------------------------
psgc_resolved_count = (
    silver_row_count
    - dq_metrics["special_structure_count"]
)

final_summary = [
    ("Source", SOURCE_NAME),
    ("Source version", selected_source_version),
    ("Batch ID", selected_batch_id),

    ("Bronze input rows", str(bronze_row_count)),
    ("Silver candidate rows", str(silver_row_count)),
    ("Silver persisted rows", str(rerun_row_count)),

    (
        "PSGC-resolved boundaries",
        str(psgc_resolved_count)
    ),
    (
        "Special structures",
        str(dq_metrics["special_structure_count"])
    ),

    (
        "Duplicate logical keys",
        str(rerun_duplicate_rows)
    ),
    (
        "Blocking DQ failures",
        str(blocking_failures)
    ),

    ("DQ validation ID", validation_id),

    (
        "Idempotency rerun inserts",
        str(rerun_rows_inserted)
    ),
    (
        "Idempotency rerun updates",
        str(rerun_rows_updated)
    ),

    ("Silver target", SILVER_TABLE),
]


final_summary_df = spark.createDataFrame(
    final_summary,
    ["metric", "value"]
)

show(final_summary_df)


# -----------------------------------------------------------------------------
# Diagnostics (were the SQL cells at the end of the notebook)
# -----------------------------------------------------------------------------
if DIAGNOSTICS:
    print("Boundaries per PSGC match status")
    show(spark.sql(f"""
        SELECT psgc_match_status, count(*) AS boundaries
        FROM {SILVER_TABLE}
        GROUP BY psgc_match_status ORDER BY boundaries DESC
    """))

    print("PSGC codes on more than one boundary (expect none)")
    show(spark.sql(f"""
        SELECT admin_level, psgc_code, count(*) AS boundaries
        FROM {SILVER_TABLE}
        WHERE psgc_code IS NOT NULL
        GROUP BY admin_level, psgc_code HAVING count(*) > 1
    """))

    print("ADM3 CODE_MATCH rows whose HDX and PSGC names still differ after normalization")
    MOJIBAKE_N = "\u00c3\u00b1"   # damaged ñ, written as escapes
    show(spark.sql(rf"""
        WITH names AS (
          SELECT
            b.boundary_pcode,
            b.boundary_name,
            b.adm2_name,
            b.psgc_code,
            g.area_name AS psgc_name,
            lower(trim(b.boundary_name)) AS b_raw,
            lower(trim(replace(g.area_name, '{MOJIBAKE_N}', 'ñ'))) AS p_raw
          FROM {SILVER_TABLE} AS b
          INNER JOIN {PSGC_TABLE} AS g
            ON g.psgc_code = b.psgc_code
           AND g.source_version = b.psgc_reference_version
           AND g.content_checksum = b.psgc_reference_checksum
          WHERE b.admin_level = '3'
            AND b.psgc_match_status = 'CODE_MATCH'
            AND b.source_version = '{selected_source_version}'
        ),
        cleaned AS (
          SELECT
            *,
            trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
              b_raw, r'^city of ', ''), r' city$', ''), r'\s*\([^)]*\)', ''), r'[^a-z0-9ñ]+', ' ')) AS b_name,
            trim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
              p_raw, r'^city of ', ''), r' city$', ''), r'\s*\([^)]*\)', ''), r'[^a-z0-9ñ]+', ' ')) AS p_name
          FROM names
        )
        SELECT boundary_pcode, boundary_name, adm2_name, psgc_code, psgc_name
        FROM cleaned
        WHERE b_name <> p_name
        ORDER BY boundary_pcode
    """), n=100)