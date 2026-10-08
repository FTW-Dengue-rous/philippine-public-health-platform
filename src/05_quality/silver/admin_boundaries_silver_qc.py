# Databricks notebook source
# Databricks notebook source
# Run this file as a Databricks notebook after the Silver load.
# dq_utils.py must be a Python file in the same quality folder.
# quality_setup.sql must already have been run.
# These checks only read Bronze/Silver and write quality audit results.

from pathlib import Path
import sys
from pyspark.sql import SparkSession, functions as F

# Make the script folder available for importing dq_utils.py.
if "__file__" in globals():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from dq_utils import DQRun

spark = SparkSession.builder.getOrCreate()

# =============================================================================
# 1. SETTINGS: change these when checking a different source batch.
# =============================================================================
SILVER_TABLE = "public_health.silver.admin_boundaries_silver"
BRONZE_TABLE = "public_health.bronze.admin_boundaries_bronze"
PSGC_TABLE = "public_health.silver.geography_silver"
SOURCE_VERSION = "032db5d91fcb8a13aef378d6b4453da7225ef7f0fb9c0a1c3bf3c2205d0010d6"
BATCH_ID = "cod-ab-phl:" + SOURCE_VERSION


# Read one fixed Delta version so every check sees the same data.
def read_snapshot(table_name):
    version = int(spark.sql(f"DESCRIBE HISTORY {table_name} LIMIT 1").first()["version"])
    print(f"Checking {table_name}: Delta version {version}")
    return spark.read.format("delta").option("versionAsOf", version).table(table_name)


# Return the number calculated by a SQL query.
def count_sql(query):
    return int(spark.sql(query).first()[0])

# =============================================================================
# 2. READ THE PERSISTED SNAPSHOTS.
# =============================================================================
silver = read_snapshot(SILVER_TABLE).filter(F.col("source_version") == SOURCE_VERSION)
bronze = read_snapshot(BRONZE_TABLE).filter(F.col("_source_version") == SOURCE_VERSION)
psgc = read_snapshot(PSGC_TABLE)
silver.createOrReplaceTempView("beginner_boundaries_silver")
psgc.createOrReplaceTempView("beginner_boundaries_psgc")
silver_rows = silver.count()
bronze_rows = bronze.count()
print(f"Bronze rows: {bronze_rows}; Silver rows: {silver_rows}")

# =============================================================================
# 3. CHECKS: DQRun saves the results, then raises if any check is FAIL.
# =============================================================================
with DQRun(layer="silver", domain="admin_boundaries", script_name="admin_boundaries_silver_qc_beginner.py",
           source_keys="hdx_phl_admin", fail_on_error=True) as dq:

    # AS01: both source and target snapshots must contain records.
    dq.record("AS01", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="Snapshot exists and has rows", check_type="COMPLETENESS",
              severity="FAIL", status="PASS" if silver_rows > 0 and bronze_rows > 0 else "FAIL",
              observed=silver_rows, expected="Nonempty Bronze and Silver snapshots")

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
    dq.record("AS02", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="Required boundary fields complete", check_type="COMPLETENESS",
              severity="FAIL", threshold=0, fail_count=missing, total_count=silver_rows)

    # AS03: the logical key must identify only one row.
    duplicates = count_sql("""
        SELECT COALESCE(SUM(n - 1), 0) FROM (
            SELECT COUNT(*) AS n FROM beginner_boundaries_silver
            GROUP BY admin_level, boundary_pcode, source_version HAVING COUNT(*) > 1
        )
    """)
    dq.record("AS03", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="Boundary logical key unique", check_type="UNIQUENESS",
              severity="FAIL", threshold=0, fail_count=duplicates, total_count=silver_rows)

    # AS04: only ADM1/2/3 and polygon boundary types are allowed.
    invalid_values = count_sql("""
        SELECT COUNT(*) FROM beginner_boundaries_silver
        WHERE admin_level IS NULL OR admin_level NOT IN ('1', '2', '3')
           OR geometry_type IS NULL OR geometry_type NOT IN ('Polygon', 'MultiPolygon')
    """)
    dq.record("AS04", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="Administrative and geometry values accepted", check_type="VALIDITY",
              severity="FAIL", threshold=0, fail_count=invalid_values, total_count=silver_rows)

    # ASB05: this beginner check compares total counts only.
    # It has its own code because AS05 in the detailed script also compares counts per level.
    dq.record("ASB05", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="Boundary total rows reconcile", check_type="RECONCILIATION",
              severity="FAIL", threshold=0, fail_count=abs(bronze_rows - silver_rows),
              total_count=bronze_rows, observed=silver_rows, expected=bronze_rows)

    # AS07: area is positive, latitude is -90..90, longitude is -180..180.
    spatial_issues = count_sql("""
        SELECT COUNT(*) FROM beginner_boundaries_silver
        WHERE area_sqkm IS NULL OR ISNAN(area_sqkm) OR area_sqkm <= 0
           OR ABS(area_sqkm) = CAST('Infinity' AS DOUBLE)
           OR center_lat IS NULL OR ISNAN(center_lat) OR center_lat NOT BETWEEN -90 AND 90
           OR center_lon IS NULL OR ISNAN(center_lon) OR center_lon NOT BETWEEN -180 AND 180
    """)
    dq.record("AS07", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="Spatial attributes valid", check_type="RANGE",
              severity="FAIL", threshold=0, fail_count=spatial_issues, total_count=silver_rows)

    # AS08: allow a null PSGC code ONLY for the documented special structures.
    classification_issues = count_sql("""
        SELECT COUNT(*) FROM beginner_boundaries_silver
        WHERE psgc_match_status IS NULL
           OR psgc_match_status NOT IN ('CODE_MATCH', 'HIERARCHY_MATCH', 'NAME_LEVEL_MATCH',
                                       'TYPE_CONTEXT_MATCH', 'NAME_VARIANT_MATCH', 'SPECIAL_STRUCTURE')
           OR (psgc_match_status <> 'SPECIAL_STRUCTURE' AND (psgc_code IS NULL OR TRIM(psgc_code) = ''))
           OR (psgc_match_status = 'SPECIAL_STRUCTURE' AND (
                psgc_code IS NOT NULL OR NOT COALESCE(
                    (admin_level = '2' AND (boundary_name LIKE 'Metropolitan Manila%'
                        OR boundary_name IN ('City of Isabela (not a province)', 'Special Geographic Area')))
                    OR (admin_level = '3' AND adm2_name = 'Special Geographic Area'), FALSE)))
    """)
    dq.record("AS08", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="PSGC match status and special structures valid", check_type="CONSISTENCY",
              severity="FAIL", threshold=0, fail_count=classification_issues, total_count=silver_rows)

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
    dq.record("AS09", table_name=SILVER_TABLE, source_key="hdx_phl_admin", batch_id=BATCH_ID,
              check_name="PSGC reference snapshot and level valid", check_type="REFERENTIAL_INTEGRITY",
              severity="FAIL", threshold=0, fail_count=reference_issues, total_count=silver_rows)

print("Admin boundaries Silver QC completed. Results: public_health.quality.qc_results")