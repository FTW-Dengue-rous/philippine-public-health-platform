"""Silver QC for PSA health expenditure financing-agent shares.

This module only checks an ALREADY PUBLISHED Silver Delta table.
It DOES NOT create the table or run the Silver transformation.
Run from the repository with a Databricks Runtime Spark session after publication.

Source: PSA Table 9.26, 16 financing agents x 8 years (2016-2023).
Bronze: 18 physical rows = 16 data + 2 intentionally filtered text rows.
A PSA 'a/' value means below 0.05%; it is not an imputed zero.

The shared DQRun writes quality records, so do not execute this script
until the Silver table, shared lineage contract, and QC task are approved.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

# Reuse the team's shared helper without copying or modifying it.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dq_utils import DQRun  # noqa: E402

SILVER_TABLE = "public_health.silver.socioeconomic_health_expenditure_share_silver"
BRONZE_TABLE = "public_health.bronze.socioeconomic_psa_health_expenditure_share_bronze"
SOURCE_KEY = "psa_health_expenditure_share_national_annual"
EXPECTED_YEARS = tuple(range(2016, 2024))
EXPECTED_SOURCE_POSITIONS = {5, *range(7, 22), 23, 25}
EXPECTED_DATA_POSITIONS = {5, *range(7, 22)}
EXPECTED_FILTERED_POSITIONS = {23, 25}


def run_checks(dq: DQRun, spark: SparkSession, *, profile: bool = False) -> None:
    """Log domain-appropriate S01/S02/S03/S07/S08/S09/S11/S12 results."""
    t = SILVER_TABLE
    src = SOURCE_KEY
    exists = spark.catalog.tableExists(t)
    if not exists:
        dq.record(
            "S01",
            table_name=t,
            source_key=src,
            status="FAIL",
            observed="table absent",
            expected="published Delta table with >0 records",
        )
        return

    silver = spark.table(t).where(F.col("_source_key") == src).cache()
    try:
        total = silver.count()
        dq.record(
            "S01",
            table_name=t,
            source_key=src,
            status="PASS" if total > 0 else "FAIL",
            observed=total,
            expected="> 0 rows for configured PSA source",
        )
        if total == 0:
            return

        required = {
            "financing_agent",
            "year",
            "share_pct",
            "share_status",
            "share_source_value",
            "financing_agent_level",
            "_source_key",
            "_source_file",
            "_source_row_num",
        }
        missing = sorted(required.difference(silver.columns))
        if missing:
            dq.record(
                "S00",
                table_name=t,
                source_key=src,
                status="FAIL",
                detail=f"Missing required Silver columns: {missing}",
            )
            return

        key_nulls = silver.where(
            F.col("financing_agent").isNull()
            | (F.trim(F.col("financing_agent")) == "")
            | F.col("year").isNull()
        ).count()
        dq.record(
            "S02",
            table_name=t,
            source_key=src,
            fail_count=key_nulls,
            total_count=total,
            observed=key_nulls,
            expected="zero null or blank (financing_agent, year) keys",
        )

        duplicates = (
            silver.groupBy("financing_agent", "year")
            .count()
            .where(F.col("count") > 1)
            .agg(F.coalesce(F.sum(F.col("count") - 1), F.lit(0)).alias("n"))
            .first()["n"]
        )
        dq.record(
            "S03",
            table_name=t,
            source_key=src,
            fail_count=int(duplicates),
            total_count=total,
            observed=int(duplicates),
            expected="zero duplicate (financing_agent, year) records",
        )

        bad_range = silver.where(
            F.col("share_pct").isNotNull() & ((F.col("share_pct") < 0) | (F.col("share_pct") > 100))
        ).count()
        dq.record(
            "S07",
            table_name=t,
            source_key=src,
            fail_count=bad_range,
            total_count=total,
            column_name="share_pct",
            observed=bad_range,
            expected="every numeric percentage is between 0 and 100",
        )

        bad_years = silver.where(
            F.col("year").isNull() | (~F.col("year").isin(*EXPECTED_YEARS))
        ).count()
        distinct_years = silver.select("year").distinct().count()
        year_failures = bad_years + (1 if distinct_years != 8 else 0)
        dq.record(
            "S08",
            table_name=t,
            source_key=src,
            fail_count=year_failures,
            total_count=total,
            column_name="year",
            observed=f"bad={bad_years}; years={distinct_years}",
            expected="only 2016-2023, with all eight years present",
        )

        # S09 reconciles PHYSICAL source rows, not unpivoted metric cells.
        # This is the accounting invariant: 18 source rows = 16 contributing
        # physical data rows + 2 intentionally filtered note/credit rows.
        bronze = spark.table(BRONZE_TABLE).where(F.col("_source_key") == src)
        positions = [int(r[0]) for r in bronze.select("_source_row_num").collect()]
        observed_positions = set(positions)
        silver_data_positions = {
            int(r[0]) for r in silver.select("_source_row_num").distinct().collect()
        }
        physical_ok = (
            len(positions) == 18
            and len(observed_positions) == 18
            and observed_positions == EXPECTED_SOURCE_POSITIONS
            and silver_data_positions == EXPECTED_DATA_POSITIONS
            and total == 128
            and silver.groupBy("_source_row_num").count().where(F.col("count") != 8).count() == 0
        )
        dq.record(
            "S09",
            table_name=t,
            source_key=src,
            status="PASS" if physical_ok else "FAIL",
            observed=(
                f"bronze_rows={len(positions)}; contributing_positions="
                f"{len(silver_data_positions)}; silver_cells={total}"
            ),
            expected="18 Bronze rows = 16 contributing + 2 filtered; 16 x 8 = 128 Silver cells",
            detail=(
                "Filtered row positions 23 (footnote) and 25 (source credit). "
                "Cell expansion is unpivoting, not additional physical source rows. "
                "Requires shared row-disposition ledger integration before publication."
            ),
        )

        allowed_status = ["ok", "below_0_05_pct", "not_published"]
        invalid_status = silver.where(
            F.col("share_status").isNull()
            | ~F.col("share_status").isin(*allowed_status)
            | (
                (F.col("share_status") == "below_0_05_pct")
                & (
                    (F.lower(F.trim(F.col("share_source_value"))) != "a/")
                    | F.col("share_pct").isNotNull()
                )
            )
            | ((F.col("share_status") == "ok") & F.col("share_pct").isNull())
        ).count()
        dq.record(
            "S11",
            table_name=t,
            source_key=src,
            fail_count=invalid_status,
            total_count=total,
            column_name="share_status",
            observed=invalid_status,
            expected="accepted statuses with faithful a/ representation",
        )

        # S12 applies to truly unexplained missing values only. Explicitly
        # suppressed PSA values ('a/') are counted and reported separately.
        unexplained_nulls = silver.where(
            F.col("share_pct").isNull() & ~F.col("share_status").isin("below_0_05_pct")
        ).count()
        suppressed = silver.where(F.col("share_status") == "below_0_05_pct").count()
        dq.record(
            "S12",
            table_name=t,
            source_key=src,
            fail_count=unexplained_nulls,
            total_count=total,
            column_name="share_pct",
            observed=unexplained_nulls,
            expected="<= 5% unexplained missing values",
            detail=f"Excluded {suppressed} explicitly suppressed PSA a/ values from failure count",
        )

        if profile:
            dq.profile_table(t)
            dq.capture_table_stats(t)
    finally:
        silver.unpersist()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job-run-id", default=None)
    parser.add_argument("--code-version", default=None)
    parser.add_argument("--profile", choices=("true", "false"), default="false")
    args = parser.parse_args()
    spark = SparkSession.builder.getOrCreate()
    with DQRun(
        layer="silver",
        domain="socioeconomic",
        script_name=Path(__file__).name,
        job_run_id=args.job_run_id,
        code_version=args.code_version,
        source_keys=SOURCE_KEY,
        fail_on_error=True,
    ) as dq:
        run_checks(dq, spark, profile=args.profile == "true")


if __name__ == "__main__":
    main()
