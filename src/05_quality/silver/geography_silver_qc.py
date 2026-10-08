# Databricks notebook source
# Run this file as a Databricks notebook after the Silver load.
# dq_utils.py must be a Python file in the same quality folder.
# quality_setup.sql must already have been run.
# These checks only read Bronze/Silver and write quality audit results.

import sys
from pathlib import Path

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

# Make the script folder available for importing dq_utils.py.
if "__file__" in globals():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from dq_utils import DQRun

spark = SparkSession.builder.getOrCreate()

# =============================================================================
# 1. SETTINGS: change these when checking a different source batch.
# =============================================================================
SILVER_TABLE = "public_health.silver.geography_silver"
SOURCE_VERSION = "Q2_2024"
BATCH_ID = "6281db6c-127e-40f5-90db-47574d710430"

# Full config path supplied for this Databricks project.
CONFIG_PATH = Path(
    "/Workspace/Users/shiena.arico@ftwfoundation.org/philippine-public-health-platform/config/sources_geography.yaml"
)

with CONFIG_PATH.open(encoding="utf-8") as file:
    config = yaml.safe_load(file)
BRONZE_TABLE = config["sources"]["psgc"]["bronze_table"]


# Read one fixed Delta version so every check sees the same data.
def read_snapshot(table_name):
    version = int(spark.sql(f"DESCRIBE HISTORY {table_name} LIMIT 1").first()["version"])
    print(f"Checking {table_name}: Delta version {version}")
    return spark.read.format("delta").option("versionAsOf", version).table(table_name)


# Return the number calculated by a SQL query.
def count_sql(query):
    return int(spark.sql(query).first()[0])


# =============================================================================
# 2. READ THE PERSISTED SILVER SNAPSHOT AND ITS BRONZE SOURCE.
# =============================================================================
silver_all = read_snapshot(SILVER_TABLE)
bronze_all = read_snapshot(BRONZE_TABLE)

# Require exactly one checksum for this version and batch; do not guess "latest".
checksums = (
    silver_all.filter((F.col("source_version") == SOURCE_VERSION) & (F.col("batch_id") == BATCH_ID))
    .select("content_checksum")
    .distinct()
    .collect()
)
if len(checksums) != 1 or not checksums[0][0]:
    raise ValueError("The selected version/batch must identify exactly one Silver snapshot")
CHECKSUM = checksums[0][0]
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
# 3. CHECKS: DQRun saves the results, then raises if any check is FAIL.
# =============================================================================
with DQRun(
    layer="silver",
    domain="geography",
    script_name="geography_silver_qc_beginner.py",
    source_keys="psgc",
    fail_on_error=True,
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

    # GS04: null levels are allowed, matching the original geography notebook.
    invalid_levels = count_sql("""
        SELECT COUNT(*) FROM beginner_geography_silver
        WHERE geographic_level IS NOT NULL
          AND geographic_level NOT IN ('Reg', 'Prov', 'City', 'Mun', 'SubMun', 'Bgy')
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

    # GS06: hierarchy mismatch remains a WARN, as in the original notebook.
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

print("Geography Silver QC completed. Results: public_health.quality.qc_results")