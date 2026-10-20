# =============================================================================
# 01 — PSGC Geography Bronze to Silver
#
# Transforms PSA PSGC Bronze geography records into a cleaned and validated Silver
# geography table. Script version of the geography_silver notebook (same cells, same order).
#
#   Config   config/sources_geography.yaml (psgc entry), found by walking up from this file
#   Source   public_health.bronze.geography_bronze
#   Target   public_health.silver.geography_silver
#   QC       public_health.quality.qc_results (checks SG01–SG07)
#   Grain    one PSGC geographic area per logical PSGC source snapshot
#   Key      psgc_code + content_checksum
#   Flow     Bronze -> clean/standardize -> DQ checks -> DQ gate -> align table schema -> MERGE
#
# How to run (Databricks, Serverless or classic)
#   Python script task:  geography_silver.py  [--config_path ...] [--job_run_id {{job.run_id}}]
#   Notebook cell:       import runpy; runpy.run_path("<repo>/src/03_silver/geography_silver.py",
#                                                     run_name="__main__")
#   Parameters are optional. Also read from job/widget parameters config_path and job_run_id,
#   and from the environment variable PSGC_CONFIG_PATH.
#
# Behaviour
#   - Creates the Silver table with every column it writes (incl. area_name_raw); on an older
#     table it adds missing columns before the MERGE.
#   - MERGE inserts new keys and updates area_name, area_name_raw and batch_id when they
#     change (batch_id changes when the same content is reloaded into Bronze under a new load).
#     A rerun on unchanged Bronze inserts and updates nothing.
#   - Expected for PSGC Q2_2024: 43,762 rows, 0 duplicate keys, 456 names repaired (SG06),
#     2 null-level rows. Another release gives other numbers; none of them is a check.
#
# Rule 2a (2026-10-19)
#   - Accepted levels come from psgc.silver_qc.accepted_geographic_levels in the YAML (the same
#     list geography_silver_qc.py GS04 reads), not a list typed here.
#   - New SG07 (FAIL): every psgc_code is 10 digits. Population S55, admin boundaries and the
#     facilities builders read region / province / municipality from fixed positions of the code.
# =============================================================================

import argparse
import os
import uuid
from datetime import UTC, datetime
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
    parser = argparse.ArgumentParser(description="PSGC geography Bronze to Silver")
    parser.add_argument(
        "--config_path",
        default=None,
        help="Full path to config/sources_geography.yaml (default: found above this file)",
    )
    parser.add_argument(
        "--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job"
    )
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

with open(CONFIG_PATH, encoding="utf-8") as f:
    config = yaml.safe_load(f)

print(f"Loaded config: {CONFIG_PATH}")


# -----------------------------------------------------------------------------
# Resolve PSGC configuration
# -----------------------------------------------------------------------------
SOURCE_KEY = "psgc"
LAYER = "silver"

psgc_config = config["sources"][SOURCE_KEY]

required_config_keys = ["version", "bronze_table", "geography_silver_table", "qc_results_table"]

missing_keys = [key for key in required_config_keys if key not in psgc_config]

if missing_keys:
    raise ValueError(f"Missing required PSGC configuration: {missing_keys}")

EXPECTED_SOURCE_VERSION = psgc_config["version"]

# Accepted geographic levels (SG03). Shared with geography_silver_qc.py through the YAML.
ACCEPTED_GEOGRAPHIC_LEVELS = [
    str(level)
    for level in (psgc_config.get("silver_qc") or {}).get("accepted_geographic_levels") or []
]
if not ACCEPTED_GEOGRAPHIC_LEVELS:
    raise ValueError(
        "psgc.silver_qc.accepted_geographic_levels is missing or empty in "
        f"{CONFIG_PATH.name}; SG03 has no level list to check against."
    )

SOURCE_TABLE = psgc_config["bronze_table"]
TARGET_TABLE = psgc_config["geography_silver_table"]
QC_TABLE = psgc_config["qc_results_table"]

print(f"Source key       : {SOURCE_KEY}")
print(f"Configured version: {EXPECTED_SOURCE_VERSION}")
print(f"Source table     : {SOURCE_TABLE}")
print(f"Target table     : {TARGET_TABLE}")
print(f"QC results table : {QC_TABLE}")


# -----------------------------------------------------------------------------
# Read Bronze
# -----------------------------------------------------------------------------
bronze_df = spark.table(SOURCE_TABLE)

bronze_row_count = bronze_df.count()

print(f"Source table      : {SOURCE_TABLE}")
print(f"Total Bronze rows : {bronze_row_count:,}")


# -----------------------------------------------------------------------------
# Inspect source snapshots
# -----------------------------------------------------------------------------
snapshot_profile = (
    bronze_df.groupBy("source_version", "content_checksum", "batch_id")
    .agg(
        F.count("*").alias("row_count"),
        F.min("ingested_at").alias("first_ingested_at"),
        F.max("ingested_at").alias("last_ingested_at"),
    )
    .orderBy(F.desc("last_ingested_at"))
)

show(snapshot_profile)


# -----------------------------------------------------------------------------
# Validate configured source version exists
# -----------------------------------------------------------------------------
configured_version_count = bronze_df.filter(
    F.col("source_version") == EXPECTED_SOURCE_VERSION
).count()

if configured_version_count == 0:
    raise ValueError(
        f"No Bronze records found for configured PSGC version '{EXPECTED_SOURCE_VERSION}'."
    )

print(
    f"Found {configured_version_count:,} Bronze rows for source version {EXPECTED_SOURCE_VERSION}"
)


# -----------------------------------------------------------------------------
# Inspect logical snapshots for configured version
# -----------------------------------------------------------------------------
configured_snapshots = (
    bronze_df.filter(F.col("source_version") == EXPECTED_SOURCE_VERSION)
    .groupBy("content_checksum", "batch_id")
    .agg(
        F.count("*").alias("row_count"),
        F.min("ingested_at").alias("first_ingested_at"),
        F.max("ingested_at").alias("last_ingested_at"),
    )
    .orderBy(F.desc("last_ingested_at"))
)

show(configured_snapshots)

snapshot_count = configured_snapshots.count()

print(f"Logical snapshots found for {EXPECTED_SOURCE_VERSION}: {snapshot_count}")


# -----------------------------------------------------------------------------
# Lock the active Bronze snapshot
# -----------------------------------------------------------------------------
snapshot_rows = configured_snapshots.collect()

if len(snapshot_rows) != 1:
    raise ValueError(
        f"Expected exactly 1 logical snapshot for {EXPECTED_SOURCE_VERSION}, "
        f"but found {len(snapshot_rows)}."
    )

active_snapshot = snapshot_rows[0]

ACTIVE_CONTENT_CHECKSUM = active_snapshot["content_checksum"]
ACTIVE_BATCH_ID = active_snapshot["batch_id"]
EXPECTED_ROW_COUNT = active_snapshot["row_count"]

print(f"Source version    : {EXPECTED_SOURCE_VERSION}")
print(f"Content checksum  : {ACTIVE_CONTENT_CHECKSUM}")
print(f"Batch ID          : {ACTIVE_BATCH_ID}")
print(f"Expected rows     : {EXPECTED_ROW_COUNT:,}")


# -----------------------------------------------------------------------------
# Create the source snapshot DataFrame
# -----------------------------------------------------------------------------
source_df = bronze_df.filter(
    (F.col("source_version") == EXPECTED_SOURCE_VERSION)
    & (F.col("content_checksum") == ACTIVE_CONTENT_CHECKSUM)
    & (F.col("batch_id") == ACTIVE_BATCH_ID)
)

source_row_count = source_df.count()

print(f"Selected Bronze rows: {source_row_count:,}")

if source_row_count != EXPECTED_ROW_COUNT:
    raise ValueError(
        f"Snapshot row-count mismatch. Expected {EXPECTED_ROW_COUNT:,}, found {source_row_count:,}."
    )


# -----------------------------------------------------------------------------
# Build geography_candidate
# -----------------------------------------------------------------------------
def clean_string(column_name):
    trimmed = F.trim(F.col(column_name))

    return F.when(trimmed.isNull() | (trimmed == ""), F.lit(None)).otherwise(trimmed)


# The damaged form of ñ, written as escapes so the editor cannot alter it
MOJIBAKE_N = "\u00c3\u00b1"

geography_candidate = source_df.select(
    clean_string("psgc_code").alias("psgc_code"),
    clean_string("correspondence_code").alias("correspondence_code"),
    clean_string("area_name").alias("area_name_raw"),
    F.regexp_replace(clean_string("area_name"), MOJIBAKE_N, "ñ").alias("area_name"),
    clean_string("geographic_level").alias("geographic_level"),
    clean_string("reg").alias("region_code"),
    clean_string("prv").alias("province_code"),
    clean_string("mun").alias("municipality_code"),
    clean_string("bgy").alias("barangay_code"),
    clean_string("city_class").alias("city_class"),
    clean_string("income_classification").alias("income_classification"),
    clean_string("urban_rural").alias("urban_rural"),
    clean_string("island_region").alias("island_region"),
    clean_string("record_status").alias("record_status"),
    clean_string("source_version").alias("source_version"),
    clean_string("content_checksum").alias("content_checksum"),
    clean_string("batch_id").alias("batch_id"),
    F.current_timestamp().alias("silver_processed_at"),
)


# -----------------------------------------------------------------------------
# Verify candidate schema
# -----------------------------------------------------------------------------
geography_candidate.printSchema()


# -----------------------------------------------------------------------------
# Candidate row reconciliation
# -----------------------------------------------------------------------------
candidate_row_count = geography_candidate.count()

print(f"Bronze snapshot rows : {source_row_count:,}")
print(f"Silver candidate rows: {candidate_row_count:,}")


# -----------------------------------------------------------------------------
# Inspect representative rows
# -----------------------------------------------------------------------------
show(
    geography_candidate.select(
        "psgc_code",
        "correspondence_code",
        "area_name",
        "geographic_level",
        "region_code",
        "province_code",
        "municipality_code",
        "barangay_code",
        "urban_rural",
    ).limit(20)
)


# -----------------------------------------------------------------------------
# Create run/validation identifiers
# -----------------------------------------------------------------------------
RUN_ID = JOB_RUN_ID or str(uuid.uuid4())
VALIDATION_ID = str(uuid.uuid4())

print(f"Run ID        : {RUN_ID}")
print(f"Validation ID : {VALIDATION_ID}")
print(f"Batch ID      : {ACTIVE_BATCH_ID}")


# -----------------------------------------------------------------------------
# SG01: NULL / Completeness
# -----------------------------------------------------------------------------
required_columns = ["psgc_code", "area_name", "source_version", "content_checksum", "batch_id"]

null_condition = None

for column_name in required_columns:
    condition = F.col(column_name).isNull()

    null_condition = condition if null_condition is None else null_condition | condition

sg01_fail_count = geography_candidate.filter(null_condition).count()

sg01_total_count = candidate_row_count

print(f"SG01 - Required field failures: {sg01_fail_count:,}")
print(f"Rows evaluated                : {sg01_total_count:,}")


# -----------------------------------------------------------------------------
# Inspect failures only if they exis
# -----------------------------------------------------------------------------
if sg01_fail_count > 0:
    show(
        geography_candidate.filter(null_condition)
        .select("psgc_code", "area_name", "source_version", "content_checksum", "batch_id")
        .limit(50)
    )


# -----------------------------------------------------------------------------
# SG02: Grain uniqueness
# -----------------------------------------------------------------------------
duplicate_keys = (
    geography_candidate.groupBy("psgc_code", "content_checksum").count().filter(F.col("count") > 1)
)

sg02_duplicate_group_count = duplicate_keys.count()

sg02_duplicate_row_count = duplicate_keys.agg(
    F.coalesce(F.sum("count"), F.lit(0)).alias("duplicate_rows")
).first()["duplicate_rows"]

sg02_total_count = candidate_row_count

print(f"SG02 - Duplicate key groups : {sg02_duplicate_group_count:,}")
print(f"Rows affected               : {sg02_duplicate_row_count:,}")
print(f"Rows evaluated              : {sg02_total_count:,}")


# -----------------------------------------------------------------------------
# Show duplicates only when found
# -----------------------------------------------------------------------------
if sg02_duplicate_group_count > 0:
    show(duplicate_keys.orderBy(F.desc("count")).limit(50))


# -----------------------------------------------------------------------------
# Profile geographic_level
# -----------------------------------------------------------------------------
geographic_level_profile = (
    geography_candidate.groupBy("geographic_level")
    .agg(F.count("*").alias("row_count"))
    .orderBy("geographic_level")
)

show(geographic_level_profile)

geographic_level_distinct_count = geography_candidate.select("geographic_level").distinct().count()

print(f"Distinct geographic_level values: {geographic_level_distinct_count}")


# -----------------------------------------------------------------------------
# Inspect the null-level records (2 in Q2_2024; GS08 in the QC compares them with the YAML)
# -----------------------------------------------------------------------------
null_level_rows = geography_candidate.filter(F.col("geographic_level").isNull()).select(
    "psgc_code",
    "correspondence_code",
    "area_name",
    "region_code",
    "province_code",
    "municipality_code",
    "barangay_code",
    "source_version",
)

show(null_level_rows)


# -----------------------------------------------------------------------------
# SG03 Accepted Values (list from the YAML, read at the top)
# -----------------------------------------------------------------------------
invalid_level_condition = F.col("geographic_level").isNotNull() & ~F.col("geographic_level").isin(
    ACCEPTED_GEOGRAPHIC_LEVELS
)

sg03_fail_count = geography_candidate.filter(invalid_level_condition).count()

sg03_null_count = geography_candidate.filter(F.col("geographic_level").isNull()).count()

sg03_total_count = candidate_row_count

print(f"SG03 - Invalid geographic levels : {sg03_fail_count:,}")
print(f"Special/null geographic levels   : {sg03_null_count:,}")
print(f"Rows evaluated                   : {sg03_total_count:,}")


# -----------------------------------------------------------------------------
# SG04 Hierarchy consistency
# -----------------------------------------------------------------------------
expected_psgc_code = F.concat(
    F.lpad(F.col("region_code"), 2, "0"),
    F.lpad(F.col("province_code"), 3, "0"),
    F.lpad(F.col("municipality_code"), 2, "0"),
    F.lpad(F.col("barangay_code"), 3, "0"),
)

hierarchy_mismatch_condition = (
    F.col("region_code").isNotNull()
    & F.col("province_code").isNotNull()
    & F.col("municipality_code").isNotNull()
    & F.col("barangay_code").isNotNull()
    & (F.col("psgc_code") != expected_psgc_code)
)

sg04_fail_count = geography_candidate.filter(hierarchy_mismatch_condition).count()

sg04_total_count = candidate_row_count

print(f"SG04 - Hierarchy/code mismatches : {sg04_fail_count:,}")
print(f"Rows evaluated                   : {sg04_total_count:,}")

if sg04_fail_count > 0:
    show(
        geography_candidate.filter(hierarchy_mismatch_condition)
        .select(
            "psgc_code",
            "area_name",
            "geographic_level",
            "region_code",
            "province_code",
            "municipality_code",
            "barangay_code",
            expected_psgc_code.alias("expected_psgc_code"),
        )
        .limit(50)
    )


# -----------------------------------------------------------------------------
# SG05 Volume reconciliation
# -----------------------------------------------------------------------------
sg05_expected_count = source_row_count
sg05_observed_count = candidate_row_count

sg05_fail_count = abs(sg05_expected_count - sg05_observed_count)

sg05_total_count = sg05_expected_count

print(f"SG05 - Bronze rows   : {sg05_expected_count:,}")
print(f"SG05 - Candidate rows: {sg05_observed_count:,}")
print(f"Row difference       : {sg05_fail_count:,}")


# -----------------------------------------------------------------------------
# SG06 Area name encoding
# -----------------------------------------------------------------------------
sg06_fail_count = geography_candidate.filter(F.col("area_name").contains("\u00c3")).count()
sg06_repaired_count = geography_candidate.filter(
    F.col("area_name") != F.col("area_name_raw")
).count()
print(f"SG06 - Names still damaged: {sg06_fail_count:,}")
print(f"Names repaired            : {sg06_repaired_count:,}")  # 456 for Q2_2024


# -----------------------------------------------------------------------------
# SG07 PSGC code format: 10 digits
# Downstream code reads levels from fixed positions (2 region, 5 province, 7 city /
# municipality digits), so a code of another shape would join to the wrong parent silently.
# -----------------------------------------------------------------------------
bad_code_condition = ~F.col("psgc_code").rlike(r"^[0-9]{10}$")
sg07_fail_count = geography_candidate.filter(bad_code_condition).count()
print(f"SG07 - PSGC codes not 10 digits: {sg07_fail_count:,}")
if sg07_fail_count > 0:
    show(
        geography_candidate.filter(bad_code_condition)
        .select("psgc_code", "area_name", "geographic_level")
        .limit(50)
    )


# -----------------------------------------------------------------------------
# QC result helper
# -----------------------------------------------------------------------------
def make_qc_result(
    check_id,
    check_name,
    check_type,
    fail_count,
    total_count,
    severity,
    column_name=None,
    admin_level=None,
    threshold=0.0,
    observed=None,
    expected=None,
    detail=None,
):
    fail_pct = fail_count / total_count if total_count > 0 else 0.0

    status = "PASS" if fail_pct <= threshold else severity

    return {
        "run_id": RUN_ID,
        "validation_id": VALIDATION_ID,
        "batch_id": ACTIVE_BATCH_ID,
        "source_key": SOURCE_KEY,
        "table_name": TARGET_TABLE,
        "layer": LAYER,
        "executed_at": datetime.now(UTC),
        "check_id": check_id,
        "check_name": check_name,
        "check_type": check_type,
        "column_name": column_name,
        "admin_level": admin_level,
        "status": status,
        "severity": severity,
        "fail_count": int(fail_count),
        "total_count": int(total_count),
        "fail_pct": float(fail_pct),
        "threshold": float(threshold),
        "observed": observed,
        "expected": expected,
        "detail": detail,
    }


# -----------------------------------------------------------------------------
# Define geography QC results
# -----------------------------------------------------------------------------
qc_rows = [
    make_qc_result(
        check_id="SG01",
        check_name="Required geography fields",
        check_type="COMPLETENESS",
        fail_count=sg01_fail_count,
        total_count=sg01_total_count,
        severity="FAIL",
        detail=(
            "Required fields: psgc_code, area_name, source_version, content_checksum, batch_id"
        ),
    ),
    make_qc_result(
        check_id="SG02",
        check_name="Geography grain uniqueness",
        check_type="UNIQUENESS",
        fail_count=sg02_duplicate_row_count,
        total_count=sg02_total_count,
        severity="FAIL",
        detail=(
            f"Logical key: psgc_code + content_checksum. "
            f"Duplicate key groups: {sg02_duplicate_group_count}"
        ),
    ),
    make_qc_result(
        check_id="SG03",
        check_name="Geographic level accepted values",
        check_type="VALIDITY",
        fail_count=sg03_fail_count,
        total_count=sg03_total_count,
        severity="FAIL",
        column_name="geographic_level",
        detail=(
            f"Accepted non-null values: {', '.join(ACCEPTED_GEOGRAPHIC_LEVELS)} "
            "(psgc.silver_qc.accepted_geographic_levels). Preserved special/null records: "
            f"{sg03_null_count}"
        ),
    ),
    make_qc_result(
        check_id="SG04",
        check_name="PSGC hierarchy consistency",
        check_type="CONSISTENCY",
        fail_count=sg04_fail_count,
        total_count=sg04_total_count,
        severity="WARN",
        detail=("Checks whether hierarchy code components reconstruct the 10-digit PSGC code."),
    ),
    make_qc_result(
        check_id="SG05",
        check_name="Bronze to Silver candidate volume reconciliation",
        check_type="RECONCILIATION",
        fail_count=sg05_fail_count,
        total_count=sg05_total_count,
        severity="FAIL",
        observed=str(sg05_observed_count),
        expected=str(sg05_expected_count),
        detail="Expected exact row preservation from Bronze snapshot to Silver candidate.",
    ),
    make_qc_result(
        check_id="SG06",
        check_name="Area name encoding",
        check_type="VALIDITY",
        fail_count=sg06_fail_count,
        total_count=candidate_row_count,
        severity="FAIL",
        column_name="area_name",
        detail=f"No damaged characters after repair. Names repaired: {sg06_repaired_count}",
    ),
    make_qc_result(
        check_id="SG07",
        check_name="PSGC code is 10 digits",
        check_type="VALIDITY",
        fail_count=sg07_fail_count,
        total_count=candidate_row_count,
        severity="FAIL",
        column_name="psgc_code",
        detail="Downstream code reads region, province and city/municipality from fixed positions.",
    ),
]


# -----------------------------------------------------------------------------
# Create the QC DataFrame
# -----------------------------------------------------------------------------
qc_schema = spark.table(QC_TABLE).schema

qc_results_df = spark.createDataFrame(qc_rows, schema=qc_schema)

show(
    qc_results_df.select(
        "check_id",
        "check_name",
        "check_type",
        "status",
        "severity",
        "fail_count",
        "total_count",
        "fail_pct",
    )
)


# -----------------------------------------------------------------------------
# Append results to centralized qc_results
# -----------------------------------------------------------------------------
(qc_results_df.write.mode("append").saveAsTable(QC_TABLE))

print(f"Logged {qc_results_df.count()} QC results for validation {VALIDATION_ID}")


# -----------------------------------------------------------------------------
# DQ gate
# -----------------------------------------------------------------------------
blocking_failure_count = qc_results_df.filter(
    (F.col("status") == "FAIL") & (F.col("severity") == "FAIL")
).count()

if blocking_failure_count > 0:
    raise RuntimeError(
        f"Silver DQ gate failed. "
        f"{blocking_failure_count} blocking check(s) failed. "
        f"Validation ID: {VALIDATION_ID}"
    )

print(f"DQ gate passed. No blocking failures for validation {VALIDATION_ID}.")


# -----------------------------------------------------------------------------
# Create / align the Silver table
# -----------------------------------------------------------------------------
# Create the Silver table if missing (with every column the MERGE writes), and add any
# column an older table is missing. Runs after the DQ gate, so a failed gate changes nothing.
SILVER_COLUMNS = [
    ("psgc_code", "STRING"),
    ("correspondence_code", "STRING"),
    ("area_name", "STRING"),
    ("area_name_raw", "STRING"),
    ("geographic_level", "STRING"),
    ("region_code", "STRING"),
    ("province_code", "STRING"),
    ("municipality_code", "STRING"),
    ("barangay_code", "STRING"),
    ("city_class", "STRING"),
    ("income_classification", "STRING"),
    ("urban_rural", "STRING"),
    ("island_region", "STRING"),
    ("record_status", "STRING"),
    ("source_version", "STRING"),
    ("content_checksum", "STRING"),
    ("batch_id", "STRING"),
    ("silver_processed_at", "TIMESTAMP"),
]
COLUMN_COMMENTS = {
    "area_name": "Area name with the damaged ñ (Ã±) repaired",
    "area_name_raw": "Area name as loaded from Bronze, before the ñ repair",
}

target_schema = ".".join(TARGET_TABLE.split(".")[:2])
spark.sql(f"CREATE SCHEMA IF NOT EXISTS {target_schema}")

if not spark.catalog.tableExists(TARGET_TABLE):
    definitions = ",\n    ".join(
        f"{name} {dtype}"
        + (f" COMMENT '{COLUMN_COMMENTS[name]}'" if name in COLUMN_COMMENTS else "")
        for name, dtype in SILVER_COLUMNS
    )
    spark.sql(f"""
        CREATE TABLE {TARGET_TABLE} (
            {definitions}
        )
        USING DELTA
        COMMENT 'Cleaned PSA PSGC geography records. Grain: one PSGC geographic area per logical source snapshot.'
    """)
    print(f"Created {TARGET_TABLE}")
else:
    existing_columns = {field.name for field in spark.table(TARGET_TABLE).schema.fields}
    previous = None
    for name, dtype in SILVER_COLUMNS:
        if name not in existing_columns:
            position = f" AFTER {previous}" if previous in existing_columns else ""
            comment = f" COMMENT '{COLUMN_COMMENTS[name]}'" if name in COLUMN_COMMENTS else ""
            spark.sql(f"ALTER TABLE {TARGET_TABLE} ADD COLUMNS ({name} {dtype}{comment}{position})")
            existing_columns.add(name)
            print(f"Added missing column {name} to {TARGET_TABLE}")
        previous = name
    print(f"{TARGET_TABLE} has all {len(SILVER_COLUMNS)} Silver columns.")


# -----------------------------------------------------------------------------
# Register candidate as temporary view
# -----------------------------------------------------------------------------
geography_candidate.createOrReplaceTempView("geography_candidate")


# -----------------------------------------------------------------------------
# Idempotent MERGE
# -----------------------------------------------------------------------------
# Key psgc_code + content_checksum. Matched rows are updated only when something changed:
#   - area_name / area_name_raw: name repair (first run after the ñ fix updates 456 rows)
#   - batch_id: the same content was reloaded into Bronze under a new load
# A rerun on unchanged Bronze updates nothing.
spark.sql(f"""
MERGE INTO {TARGET_TABLE} AS target
USING geography_candidate AS source
ON  target.psgc_code = source.psgc_code
AND target.content_checksum = source.content_checksum

WHEN MATCHED AND (
       NOT (target.area_name     <=> source.area_name)
    OR NOT (target.area_name_raw <=> source.area_name_raw)
    OR NOT (target.batch_id      <=> source.batch_id)
) THEN UPDATE SET
    target.area_name           = source.area_name,
    target.area_name_raw       = source.area_name_raw,
    target.batch_id            = source.batch_id,
    target.silver_processed_at = source.silver_processed_at

WHEN NOT MATCHED THEN
INSERT (
    psgc_code,
    correspondence_code,
    area_name,
    area_name_raw,
    geographic_level,

    region_code,
    province_code,
    municipality_code,
    barangay_code,

    city_class,
    income_classification,
    urban_rural,
    island_region,
    record_status,

    source_version,
    content_checksum,
    batch_id,
    silver_processed_at
)
VALUES (
    source.psgc_code,
    source.correspondence_code,
    source.area_name,
    source.area_name_raw,
    source.geographic_level,

    source.region_code,
    source.province_code,
    source.municipality_code,
    source.barangay_code,

    source.city_class,
    source.income_classification,
    source.urban_rural,
    source.island_region,
    source.record_status,

    source.source_version,
    source.content_checksum,
    source.batch_id,
    source.silver_processed_at
)
""")

merge_metrics = (
    spark.sql(f"DESCRIBE HISTORY {TARGET_TABLE} LIMIT 1")
    .select("operation", "operationMetrics")
    .first()
)
if merge_metrics and merge_metrics["operation"] == "MERGE":
    metrics = merge_metrics["operationMetrics"]
    print(
        f"MERGE inserted: {metrics.get('numTargetRowsInserted')}, "
        f"updated: {metrics.get('numTargetRowsUpdated')}"
    )


# -----------------------------------------------------------------------------
# Post-write reconciliation
# -----------------------------------------------------------------------------
silver_snapshot_df = spark.table(TARGET_TABLE).filter(
    F.col("content_checksum") == ACTIVE_CONTENT_CHECKSUM
)

silver_snapshot_count = silver_snapshot_df.count()

print(f"Expected snapshot rows : {EXPECTED_ROW_COUNT:,}")
print(f"Silver snapshot rows   : {silver_snapshot_count:,}")

if silver_snapshot_count != EXPECTED_ROW_COUNT:
    raise RuntimeError(
        f"Post-write reconciliation failed. "
        f"Expected {EXPECTED_ROW_COUNT:,}, "
        f"found {silver_snapshot_count:,}."
    )


# -----------------------------------------------------------------------------
# Post-write uniqueness
# -----------------------------------------------------------------------------
post_write_duplicates = (
    silver_snapshot_df.groupBy("psgc_code", "content_checksum")
    .count()
    .filter(F.col("count") > 1)
    .count()
)

print(f"Post-write duplicate logical keys: {post_write_duplicates:,}")

if post_write_duplicates > 0:
    raise RuntimeError("Post-write uniqueness validation failed.")

stale_batch_rows = silver_snapshot_df.filter(F.col("batch_id") != ACTIVE_BATCH_ID).count()
print(f"Rows not on the active Bronze batch: {stale_batch_rows:,}")
if stale_batch_rows > 0:
    raise RuntimeError(
        f"{stale_batch_rows} Silver rows still point to another Bronze load than {ACTIVE_BATCH_ID}."
    )


# -----------------------------------------------------------------------------
# Final run summary
# -----------------------------------------------------------------------------
print("PSGC Geography Bronze → Silver completed successfully.")
print(f"Source version : {EXPECTED_SOURCE_VERSION}")
print(f"Batch ID       : {ACTIVE_BATCH_ID}")
print(f"Rows published : {silver_snapshot_count:,}")
print(f"Validation ID  : {VALIDATION_ID}")
print(f"Target table   : {TARGET_TABLE}")
