# =============================================================================
# Silver QC for PSGC population data
#
# Source architecture
#   PSA PSGC population is retained in geography_bronze.populations_json.
#   population_silver explodes the nested payload to one row per
#   psgc_code x population_year x source_version.
#
# This script validates the Silver table after transformation and before Gold.
# It does not modify the Silver table.
#
# Registry-aligned Silver checks used here
#   S00  QC ran without error
#   S01  table exists and has rows
#   S02  documented grain key is not null
#   S03  documented grain is unique
#   S04  PSGC code exists in geography Silver
#   S06  population counts are non-negative
#   S08  population year is within the configured expected range
#   S09  Bronze population observations reconcile to Silver rows
#
# Population-specific diagnostics
#   The script also validates the population_parse_status contract and that
#   VALID rows retain population_raw. These are reported in the S09 detail
#   because the shared registry currently reserves S09 for reconciliation.
# =============================================================================

import argparse
import os
import sys

import yaml
from pyspark.sql import SparkSession


def _add_dq_utils_to_path():
    """Find dq_utils.py in the project and add its directory to sys.path."""
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
            for base in (folder, os.path.join(folder, "src")):
                try:
                    candidates += [
                        os.path.join(base, name)
                        for name in sorted(os.listdir(base))
                        if "quality" in name.lower() and os.path.isdir(os.path.join(base, name))
                    ]
                except OSError:
                    pass

            for candidate in candidates:
                searched.append(candidate)
                if os.path.isfile(os.path.join(candidate, "dq_utils.py")):
                    if candidate not in sys.path:
                        sys.path.insert(0, candidate)
                    return candidate

            parent = os.path.dirname(folder)
            if parent == folder:
                break
            folder = parent

    raise ModuleNotFoundError(
        "dq_utils.py not found. Looked in:\n  " + "\n  ".join(dict.fromkeys(searched))
    )


_add_dq_utils_to_path()
from dq_utils import DQRun  # noqa: E402

spark = SparkSession.builder.getOrCreate()

CONFIG_NAMES = ("sources_population.yaml", "sources.yaml")
SOURCE_KEY = "psgc_population"
DOMAIN = "population"
SCRIPT_NAME = "population_silver_qc.py"

SILVER_TABLE = "public_health.silver.population_silver"
GEOGRAPHY_SILVER_TABLE = "public_health.silver.geography_silver"

REQUIRED_COLUMNS = [
    "psgc_code",
    "population_year",
    "population",
    "population_raw",
    "population_parse_status",
    "source_version",
    "batch_id",
    "silver_processed_at",
]

APPROVED_PARSE_STATUS = ("VALID", "MISSING", "INVALID")

# The registry already assigns these meanings to S-codes. Do not create a
# population-specific duplicate code without first changing the registry.
CHECKS = {
    "S00": ("QC ran without error", "EXECUTION", "FAIL"),
    "S01": ("table exists and has rows", "COMPLETENESS", "FAIL"),
    "S02": ("grain key not null", "COMPLETENESS", "FAIL"),
    "S03": ("grain key unique", "UNIQUENESS", "FAIL"),
    "S04": ("PSGC code found in geography", "CONSISTENCY", "WARN"),
    "S06": ("counts non-negative", "VALIDITY", "FAIL"),
    "S08": ("period within expected range", "VALIDITY", "FAIL"),
    "S09": ("bronze to silver rows reconcile", "RECONCILIATION", "FAIL"),
}


def find_config(explicit=None):
    """Locate the population YAML unless --config_path was supplied."""
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
                for name in CONFIG_NAMES:
                    candidate = os.path.join(folder, sub, name)
                    searched.append(candidate)
                    if os.path.isfile(candidate):
                        return os.path.abspath(candidate)

            parent = os.path.dirname(folder)
            if parent == folder:
                break
            folder = parent

    raise FileNotFoundError(
        f"None of {CONFIG_NAMES} found. Pass --config_path with its full path.\n"
        + "\n".join(dict.fromkeys(searched))
    )


def load_config(path):
    with open(path, encoding="utf-8") as file:
        config = yaml.safe_load(file) or {}

    sources = config.get("sources")
    if not isinstance(sources, dict):
        raise KeyError("'sources' is missing or is not a mapping")

    if SOURCE_KEY not in sources:
        raise KeyError(f"'{SOURCE_KEY}' is missing from {path}")

    entry = dict(sources[SOURCE_KEY] or {})
    entry["source_key"] = SOURCE_KEY
    entry["entry_name"] = SOURCE_KEY
    return config, entry


def scalar(sql):
    return spark.sql(sql).collect()[0][0]


def record(dq, check_id, table_name, source_key, skip, overrides, **kwargs):
    name, check_type, default_severity = CHECKS[check_id]
    severity = overrides.get(check_id, default_severity)

    return dq.record(
        check_id,
        table_name=table_name,
        source_key=source_key,
        check_name=name,
        check_type=check_type,
        severity=severity,
        skip=skip,
        **kwargs,
    )


def latest_population_year_range(silver_table):
    """
    Return the observed Silver year range.

    The source configuration does not currently provide a fixed expected
    population-year range, so S08 uses a basic calendar sanity bound rather
    than inventing a source-specific range.
    """
    return (
        spark.sql(
            f"""
        SELECT
            MIN(population_year) AS min_year,
            MAX(population_year) AS max_year
        FROM {silver_table}
        """
        )
        .collect()[0]
        .asDict()
    )


def create_bronze_population_observations(entry):
    """Recreate the Bronze population observation grain for reconciliation."""
    bronze_table = entry["bronze_table"]

    spark.sql(
        f"""
        CREATE OR REPLACE TEMP VIEW population_bronze_observations AS
        SELECT
            g.psgc_code AS psgc_code,
            p.year AS population_year,
            g.source_version AS source_version,
            p.population AS population_raw,
            TRY_CAST(
                REGEXP_REPLACE(TRIM(p.population), ',', '')
                AS BIGINT
            ) AS population
        FROM {bronze_table} g
        LATERAL VIEW EXPLODE(
            FROM_JSON(
                g.populations_json,
                'ARRAY<STRUCT<
                    id: BIGINT,
                    population: STRING,
                    psgc: STRING,
                    year: INT
                >>'
            )
        ) x AS p
        WHERE g.populations_json IS NOT NULL
        """
    )


def run_checks(dq, entry):
    table_name = entry.get("silver_table", SILVER_TABLE)
    geography_table = entry.get(
        "geography_silver_table",
        GEOGRAPHY_SILVER_TABLE,
    )

    qc = entry.get("qc") or {}
    skip = set(qc.get("skip_checks") or [])
    overrides = {str(k): str(v).upper() for k, v in (qc.get("severity") or {}).items()}

    # -------------------------------------------------------------------------
    # S01 — Silver table exists and has rows.
    # -------------------------------------------------------------------------
    table_exists = spark.catalog.tableExists(table_name)

    if not table_exists:
        record(
            dq,
            "S01",
            table_name,
            SOURCE_KEY,
            skip,
            overrides,
            status="FAIL",
            detail=f"table_exists={table_exists}",
        )
        raise RuntimeError(f"S01 FAIL: Silver table does not exist: {table_name}")

    silver_df = spark.table(table_name)
    silver_count = silver_df.count()

    record(
        dq,
        "S01",
        table_name,
        SOURCE_KEY,
        skip,
        overrides,
        status="PASS" if silver_count > 0 else "FAIL",
        detail=f"row_count={silver_count}",
    )

    if silver_count == 0:
        raise RuntimeError(f"S01 FAIL: Silver table contains 0 rows: {table_name}")

    # -------------------------------------------------------------------------
    # S02 — Grain key is not null.
    #
    # Expected grain:
    #   psgc_code x population_year x source_version
    # -------------------------------------------------------------------------
    missing_grain = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE psgc_code IS NULL
           OR population_year IS NULL
           OR source_version IS NULL
        """
    )

    record(
        dq,
        "S02",
        table_name,
        SOURCE_KEY,
        skip,
        overrides,
        status="PASS" if missing_grain == 0 else "FAIL",
        fail_count=missing_grain,
        total_count=silver_count,
        detail=("NULL values in psgc_code, population_year, or source_version"),
    )

    # -------------------------------------------------------------------------
    # S03 — Grain is unique.
    # -------------------------------------------------------------------------
    duplicate_grains = scalar(
        f"""
        SELECT COUNT(*)
        FROM (
            SELECT
                psgc_code,
                population_year,
                source_version,
                COUNT(*) AS row_count
            FROM {table_name}
            GROUP BY psgc_code, population_year, source_version
            HAVING COUNT(*) > 1
        )
        """
    )

    record(
        dq,
        "S03",
        table_name,
        SOURCE_KEY,
        skip,
        overrides,
        status="PASS" if duplicate_grains == 0 else "FAIL",
        fail_count=duplicate_grains,
        detail=("Duplicate groups at grain (psgc_code, population_year, source_version)"),
    )

    # -------------------------------------------------------------------------
    # S04 — PSGC code exists in geography Silver.
    #
    # WARN is intentional because the shared registry defines this check as a
    # consistency check and allows retired/renamed PSGC codes.
    # -------------------------------------------------------------------------
    geography_exists = spark.catalog.tableExists(geography_table)

    if not geography_exists:
        record(
            dq,
            "S04",
            table_name,
            SOURCE_KEY,
            skip,
            overrides,
            status="WARN",
            fail_count=0,
            total_count=silver_count,
            detail=f"geography Silver table not found: {geography_table}",
        )
    else:
        missing_geography_codes = scalar(
            f"""
            SELECT COUNT(*)
            FROM (
                SELECT DISTINCT p.psgc_code
                FROM {table_name} p
                LEFT JOIN {geography_table} g
                    ON p.psgc_code = g.psgc_code
                WHERE p.psgc_code IS NOT NULL
                  AND g.psgc_code IS NULL
            )
            """
        )

        record(
            dq,
            "S04",
            table_name,
            SOURCE_KEY,
            skip,
            overrides,
            status="PASS" if missing_geography_codes == 0 else "WARN",
            fail_count=missing_geography_codes,
            total_count=silver_count,
            detail=("Distinct population PSGC codes not found in geography Silver"),
        )

    # -------------------------------------------------------------------------
    # S06 — Population is non-negative when present.
    # -------------------------------------------------------------------------
    negative_population = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE population IS NOT NULL
          AND population < 0
        """
    )

    record(
        dq,
        "S06",
        table_name,
        SOURCE_KEY,
        skip,
        overrides,
        status="PASS" if negative_population == 0 else "FAIL",
        fail_count=negative_population,
        total_count=silver_count,
        column_name="population",
        detail="Non-null population values must be >= 0",
    )

    # -------------------------------------------------------------------------
    # S08 — Population year is within a basic calendar sanity range.
    #
    # No fixed source-specific year range is present in the population YAML,
    # so this avoids asserting an unsupported historical range.
    # -------------------------------------------------------------------------
    invalid_years = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE population_year IS NOT NULL
          AND (population_year < 1900 OR population_year > 2100)
        """
    )

    year_range = latest_population_year_range(table_name)

    record(
        dq,
        "S08",
        table_name,
        SOURCE_KEY,
        skip,
        overrides,
        status="PASS" if invalid_years == 0 else "FAIL",
        fail_count=invalid_years,
        total_count=silver_count,
        column_name="population_year",
        detail=(
            "Population year must be between 1900 and 2100; "
            f"observed_range={year_range['min_year']}..{year_range['max_year']}"
        ),
    )

    # -------------------------------------------------------------------------
    # S09 — Bronze nested population observations reconcile to Silver.
    #
    # Because one Bronze geography row can contain many population observations,
    # this compares the exploded Bronze population grain to the Silver grain,
    # not raw geography_bronze row count to population_silver row count.
    # -------------------------------------------------------------------------
    create_bronze_population_observations(entry)

    bronze_observation_count = scalar("SELECT COUNT(*) FROM population_bronze_observations")
    silver_observation_count = scalar(f"SELECT COUNT(*) FROM {table_name}")

    bronze_not_in_silver = scalar(
        f"""
        SELECT COUNT(*)
        FROM population_bronze_observations b
        LEFT ANTI JOIN {table_name} s
            ON b.psgc_code = s.psgc_code
           AND b.population_year = s.population_year
           AND b.source_version = s.source_version
        """
    )

    silver_not_in_bronze = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name} s
        LEFT ANTI JOIN population_bronze_observations b
            ON s.psgc_code = b.psgc_code
           AND s.population_year = b.population_year
           AND s.source_version = b.source_version
        """
    )

    # Population-specific Silver diagnostics retained in the reconciliation
    # detail because S09 is the registry-approved reconciliation code.
    invalid_status = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE population_parse_status IS NULL
           OR population_parse_status NOT IN ('VALID', 'MISSING', 'INVALID')
        """
    )

    valid_without_raw = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE population_parse_status = 'VALID'
          AND population_raw IS NULL
        """
    )

    valid_without_population = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE population_parse_status = 'VALID'
          AND population IS NULL
        """
    )

    reconciliation_ok = (
        bronze_observation_count == silver_observation_count
        and bronze_not_in_silver == 0
        and silver_not_in_bronze == 0
        and invalid_status == 0
        and valid_without_raw == 0
        and valid_without_population == 0
    )

    record(
        dq,
        "S09",
        table_name,
        SOURCE_KEY,
        skip,
        overrides,
        status="PASS" if reconciliation_ok else "FAIL",
        fail_count=(
            bronze_not_in_silver
            + silver_not_in_bronze
            + invalid_status
            + valid_without_raw
            + valid_without_population
        ),
        total_count=max(bronze_observation_count, silver_observation_count),
        detail=(
            "Bronze/Silver population observation reconciliation; "
            f"bronze_rows={bronze_observation_count}, "
            f"silver_rows={silver_observation_count}, "
            f"bronze_not_in_silver={bronze_not_in_silver}, "
            f"silver_not_in_bronze={silver_not_in_bronze}, "
            f"invalid_parse_status={invalid_status}, "
            f"valid_without_raw={valid_without_raw}, "
            f"valid_without_population={valid_without_population}"
        ),
    )

    # Final schema check is intentionally informational here. S02 covers the
    # documented grain and the Silver build defines the remaining columns.
    missing_columns = [c for c in REQUIRED_COLUMNS if c not in silver_df.columns]
    if missing_columns:
        raise RuntimeError(f"Silver table is missing required columns: {missing_columns}")

    print(f"  Silver rows: {silver_count:,}")
    print(
        "  Grain: psgc_code x population_year x source_version "
        f"({duplicate_grains:,} duplicate groups)"
    )
    print(
        "  Population parse status: "
        + ", ".join(
            f"{row['population_parse_status']}={row['count']:,}"
            for row in (
                silver_df.groupBy("population_parse_status")
                .count()
                .orderBy("population_parse_status")
                .collect()
            )
        )
    )


def parse_args():
    parser = argparse.ArgumentParser(description="Silver QC for PSGC population data")
    parser.add_argument("--config_path", default=None)
    parser.add_argument(
        "--fail_on_error",
        default="true",
        choices=["true", "false"],
    )
    parser.add_argument("--job_run_id", default=None)
    parser.add_argument("--code_version", default=None)
    return parser.parse_known_args()[0]


def main():
    args = parse_args()
    config_path = find_config(args.config_path)
    print(f"Config: {config_path}")

    _, entry = load_config(config_path)

    print(f"[{SOURCE_KEY}] {entry.get('source_name', 'PSA PSGC')}")
    print(f"Silver table: {entry.get('silver_table', SILVER_TABLE)}")

    with DQRun(
        layer="silver",
        domain=DOMAIN,
        script_name=SCRIPT_NAME,
        job_run_id=args.job_run_id,
        source_keys=SOURCE_KEY,
        fail_on_error=args.fail_on_error == "true",
        code_version=args.code_version,
        strict_registry=True,
    ) as dq:
        try:
            run_checks(dq, entry)
        except Exception as exc:
            name, check_type, severity = CHECKS["S00"]
            dq.record(
                "S00",
                table_name=entry.get("silver_table", SILVER_TABLE),
                source_key=SOURCE_KEY,
                status="FAIL",
                check_name=name,
                check_type=check_type,
                severity=severity,
                detail=f"{type(exc).__name__}: {exc}",
            )
            raise


if __name__ == "__main__":
    main()
