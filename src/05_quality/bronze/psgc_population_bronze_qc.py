# =============================================================================
# Bronze QC for PSGC population data
#
# Source architecture
#   The PSA PSGC API is loaded into the shared geography_bronze table.
#   Population observations are retained in the nested populations_json column.
#
# Bronze checks focus on:
#   - table/load completeness
#   - required schema
#   - PSGC-specific lineage
#   - empty rows
#   - ingestion metadata reconciliation
#   - Bronze schema contract
#   - nested population JSON parsing
#   - nested population numeric parsing
#
# Population business rules such as:
#   - non-negative population
#   - valid population year
#   - population grain uniqueness
#   - parent/child PSGC consistency
#
# belong to Silver QC.
# =============================================================================

import argparse
import os
import sys

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

# -----------------------------------------------------------------------------
# Locate shared dq_utils.py
# -----------------------------------------------------------------------------


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


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

CONFIG_NAMES = ("sources.yaml",)

SOURCE_KEY = "psgc"
DOMAIN = "population"
SCRIPT_NAME = "psgc_population_bronze_qc.py"


# These are ingestion/lineage columns rather than source data columns.
TECHNICAL_COLS = {
    "source_system",
    "source_version",
    "source_endpoint",
    "batch_id",
    "content_checksum",
    "raw_path",
    "ingested_at",
}


# PSGC-specific lineage contract.
LINEAGE_COLS = {
    "source_system",
    "source_version",
    "source_endpoint",
    "batch_id",
    "content_checksum",
    "raw_path",
    "ingested_at",
}


# Fixed meanings of the Bronze check IDs.
#
# B05 is intentionally included here because PSGC has its own valid lineage
# structure even though it does not use the diseases file/sheet lineage fields.
CHECKS = {
    "B00": (
        "QC ran without error",
        "EXECUTION",
        "FAIL",
    ),
    "B01": (
        "table exists and has rows",
        "COMPLETENESS",
        "FAIL",
    ),
    "B04": (
        "required columns present",
        "SCHEMA",
        "FAIL",
    ),
    "B05": (
        "lineage columns not null",
        "COMPLETENESS",
        "FAIL",
    ),
    "B07": (
        "no fully empty rows",
        "COMPLETENESS",
        "WARN",
    ),
    "B10": (
        "numeric column parses",
        "VALIDITY",
        "WARN",
    ),
    "B13": (
        "rows match ingestion metadata",
        "RECONCILIATION",
        "FAIL",
    ),
    "B15": (
        "data columns are STRING",
        "SCHEMA",
        "FAIL",
    ),
    "B16": (
        "nested population payload parses",
        "VALIDITY",
        "WARN",
    ),
}


POPULATION_JSON_SCHEMA = """
ARRAY<STRUCT<
    id: BIGINT,
    population: STRING,
    psgc: STRING,
    year: INT
>>
""".strip()


# -----------------------------------------------------------------------------
# YAML helpers
# -----------------------------------------------------------------------------


def find_config(explicit=None):
    """Locate config/sources.yaml unless --config_path was supplied."""

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
                    candidate = os.path.join(
                        folder,
                        sub,
                        name,
                    )

                    if os.path.isfile(candidate):
                        return candidate

            parent = os.path.dirname(folder)

            if parent == folder:
                break

            folder = parent

    raise FileNotFoundError(
        f"None of {CONFIG_NAMES} found. "
        "Pass --config_path with its full path.\n" + "\n".join(dict.fromkeys(searched))
    )


def load_config(path):
    """Load sources.yaml and return the PSGC source entry."""

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


# -----------------------------------------------------------------------------
# SQL helpers
# -----------------------------------------------------------------------------


def q(column):
    """Quote a Spark SQL identifier."""

    return "`" + column.replace("`", "``") + "`"


def sql_str(value):
    """Safely quote a SQL string literal."""

    return "'" + str(value).replace("'", "''") + "'"


def scalar(sql):
    """Return the first scalar result from a Spark SQL query."""

    return spark.sql(sql).collect()[0][0]


def required_columns(entry):
    """Read required_columns from the source YAML."""

    qc = entry.get("qc") or {}

    return list(dict.fromkeys(qc.get("required_columns") or []))


# -----------------------------------------------------------------------------
# Batch handling
# -----------------------------------------------------------------------------


def latest_batch(table_name, source_name, source_version):
    """
    Return the latest PSGC batch based on ingested_at.

    The geography_bronze table contains batch_id and ingested_at, so no
    file-based source lineage is required.
    """

    rows = (
        spark.table(table_name)
        .where(
            (F.col("source_system") == source_name) & (F.col("source_version") == source_version)
        )
        .select(
            "batch_id",
            "content_checksum",
            "ingested_at",
        )
        .orderBy(F.col("ingested_at").desc_nulls_last())
        .limit(1)
        .collect()
    )

    return rows[0].asDict() if rows else None


# -----------------------------------------------------------------------------
# Nested population views
# -----------------------------------------------------------------------------


def create_population_views(table_name, batch_id):
    """
    Create temporary views from the nested populations_json payload.

    psgc_population_payloads:
        One row per geography_bronze record.

    psgc_population_observations:
        One row per nested population observation.
    """

    batch_filter = sql_str(batch_id)

    spark.sql(
        f"""
        CREATE OR REPLACE TEMP VIEW psgc_population_payloads AS
        SELECT
            psgc_code AS parent_psgc_code,
            area_name,
            geographic_level,
            source_version,
            batch_id,
            content_checksum,
            populations_json,

            from_json(
                populations_json,
                {sql_str(POPULATION_JSON_SCHEMA)}
            ) AS population_items

        FROM {table_name}

        WHERE batch_id = {batch_filter}
        """
    )

    spark.sql(
        """
        CREATE OR REPLACE TEMP VIEW psgc_population_observations AS

        SELECT
            parent_psgc_code,
            area_name,
            geographic_level,
            source_version,
            batch_id,
            content_checksum,

            population_item.psgc AS population_psgc_code,
            population_item.year AS population_year,
            population_item.population AS population_raw,

            TRY_CAST(
                REPLACE(
                    TRIM(population_item.population),
                    ',',
                    ''
                )
                AS BIGINT
            ) AS population

        FROM psgc_population_payloads

        LATERAL VIEW EXPLODE(
            population_items
        ) exploded AS population_item
        """
    )


# -----------------------------------------------------------------------------
# Main Bronze checks
# -----------------------------------------------------------------------------


def run_checks(dq, entry, profile=True):
    table_name = entry["bronze_table"]
    source_name = entry["source_name"]
    source_version = entry["version"]

    qc = entry.get("qc") or {}

    skip = set(qc.get("skip_checks") or [])

    severity_overrides = {
        str(key): str(value).upper() for key, value in (qc.get("severity") or {}).items()
    }

    def rec(check_id, ok=None, **kwargs):
        """
        Record one standardized DQ result.

        DQRun handles the final status/severity behavior.
        """

        name, check_type, default_severity = CHECKS[check_id]

        severity = severity_overrides.get(
            check_id,
            default_severity,
        )

        if ok is not None:
            kwargs["status"] = "PASS" if ok else severity

        return dq.record(
            check_id,
            table_name=table_name,
            source_key=SOURCE_KEY,
            check_name=name,
            check_type=check_type,
            severity=severity,
            skip=skip,
            **kwargs,
        )

    # -------------------------------------------------------------------------
    # B01 — table exists and latest PSGC batch has rows
    # -------------------------------------------------------------------------

    if not spark.catalog.tableExists(table_name):
        rec(
            "B01",
            ok=False,
            observed="missing",
            expected="exists",
        )

        return

    df = spark.table(table_name)

    latest = latest_batch(
        table_name,
        source_name,
        source_version,
    )

    if latest is None or not latest.get("batch_id"):
        rec(
            "B01",
            ok=False,
            observed=0,
            expected="> 0",
            detail="No PSGC batch found.",
        )

        return

    batch_id = latest["batch_id"]

    scoped = df.where(F.col("batch_id") == batch_id)

    total = scoped.count()

    rec(
        "B01",
        ok=total > 0,
        observed=total,
        expected="> 0",
        batch_id=batch_id,
    )

    # Capture standard table statistics through dq_utils.
    try:
        dq.capture_table_stats(table_name)
    except Exception as exc:
        print(f"  note: table stats skipped ({str(exc)[:150]})")

    if total == 0:
        return

    # -------------------------------------------------------------------------
    # B04 — required columns
    # -------------------------------------------------------------------------

    actual_columns = {column.lower() for column in df.columns}

    required = required_columns(entry)

    missing = [column for column in required if column.lower() not in actual_columns]

    rec(
        "B04",
        ok=not missing,
        observed=len(required) - len(missing),
        expected=len(required),
        detail=(f"missing: {missing}" if missing else None),
        batch_id=batch_id,
    )

    # -------------------------------------------------------------------------
    # B05 — PSGC lineage columns are not null
    #
    # Unlike diseases Bronze, PSGC does not have:
    #   _source_key
    #   _source_file
    #   _source_row_num
    #
    # Instead it has its own valid lineage contract:
    #   source_system
    #   source_version
    #   source_endpoint
    #   batch_id
    #   content_checksum
    #   raw_path
    #   ingested_at
    # -------------------------------------------------------------------------

    missing_lineage_columns = [
        column for column in LINEAGE_COLS if column.lower() not in actual_columns
    ]

    if missing_lineage_columns:
        rec(
            "B05",
            ok=False,
            observed=0,
            expected=len(LINEAGE_COLS),
            detail=(f"missing lineage columns: {missing_lineage_columns}"),
            batch_id=batch_id,
        )

    else:
        lineage_null_counts = {}

        for column in LINEAGE_COLS:
            null_count = scoped.where(
                F.col(column).isNull() | (F.trim(F.col(column).cast("string")) == "")
            ).count()

            lineage_null_counts[column] = null_count

        total_lineage_nulls = sum(lineage_null_counts.values())

        rec(
            "B05",
            ok=total_lineage_nulls == 0,
            observed=total_lineage_nulls,
            expected=0,
            detail=(f"null/blank counts: {lineage_null_counts}" if total_lineage_nulls else None),
            batch_id=batch_id,
        )

    # -------------------------------------------------------------------------
    # B07 — no completely empty rows
    # -------------------------------------------------------------------------

    data_columns = [column for column in df.columns if column not in TECHNICAL_COLS]

    if data_columns:
        empty_condition = " AND ".join(
            (f"coalesce(trim(cast({q(column)} AS STRING)), '') = ''") for column in data_columns
        )

        blank = scoped.where(empty_condition).count()

    else:
        blank = 0

    rec(
        "B07",
        fail_count=blank,
        total_count=total,
        batch_id=batch_id,
    )

    # -------------------------------------------------------------------------
    # B13 — Bronze row count matches ingestion metadata
    # -------------------------------------------------------------------------

    metadata_table = entry.get("metadata_table")

    if not metadata_table or not spark.catalog.tableExists(metadata_table):
        rec(
            "B13",
            status="FAIL",
            observed=total,
            expected="processed ingestion_metadata row",
            detail=(f"metadata table not found: {metadata_table}"),
            batch_id=batch_id,
        )

    else:
        metadata_rows = spark.sql(
            f"""
            SELECT
                batch_id,
                record_count,
                status

            FROM {metadata_table}

            WHERE batch_id = {sql_str(batch_id)}

              AND source_name = {sql_str(source_name)}

              AND source_version = {sql_str(source_version)}

              AND bronze_table = {sql_str(table_name)}

              AND lower(status) = 'processed'

            ORDER BY retrieved_at DESC

            LIMIT 1
            """
        ).collect()

        if not metadata_rows:
            rec(
                "B13",
                status="FAIL",
                observed=total,
                expected="processed ingestion_metadata row",
                detail=(f"No processed metadata row for batch {batch_id}"),
                batch_id=batch_id,
            )

        else:
            expected_count = metadata_rows[0]["record_count"]

            rec(
                "B13",
                ok=total == expected_count,
                observed=total,
                expected=expected_count,
                detail=f"batch_id={batch_id}",
                batch_id=batch_id,
            )

    # -------------------------------------------------------------------------
    # B15 — source/data columns are STRING
    #
    # Technical ingestion columns are excluded because they are metadata,
    # not raw source fields.
    # -------------------------------------------------------------------------

    not_string = [
        (f"{field.name} {field.dataType.simpleString()}")
        for field in df.schema.fields
        if field.name not in TECHNICAL_COLS and field.dataType.simpleString() != "string"
    ]

    rec(
        "B15",
        ok=not not_string,
        observed=(len(data_columns) - len(not_string)),
        expected=len(data_columns),
        detail=(f"not string: {not_string}" if not_string else None),
        batch_id=batch_id,
    )

    # -------------------------------------------------------------------------
    # Nested population checks
    # -------------------------------------------------------------------------

    create_population_views(
        table_name,
        batch_id,
    )

    # -------------------------------------------------------------------------
    # B16 — populations_json structure parses
    # -------------------------------------------------------------------------

    payload_total = scalar(
        """
        SELECT count(*)
        FROM psgc_population_payloads
        WHERE populations_json IS NOT NULL
        """
    )

    malformed_json = scalar(
        """
        SELECT count(*)
        FROM psgc_population_payloads

        WHERE populations_json IS NOT NULL

          AND population_items IS NULL
        """
    )

    rec(
        "B16",
        fail_count=malformed_json,
        total_count=payload_total,
        column_name="populations_json",
        detail=(
            "Non-null populations_json values that "
            "could not be parsed as "
            "ARRAY<STRUCT<id,population,psgc,year>>"
        ),
        batch_id=batch_id,
    )

    # -------------------------------------------------------------------------
    # B10 — nested population values parse as BIGINT
    # -------------------------------------------------------------------------

    observation_total = scalar(
        """
        SELECT count(*)
        FROM psgc_population_observations
        """
    )

    invalid_population = scalar(
        """
        SELECT count(*)

        FROM psgc_population_observations

        WHERE population_raw IS NOT NULL

          AND TRY_CAST(
                REPLACE(
                    TRIM(population_raw),
                    ',',
                    ''
                )
                AS BIGINT
              ) IS NULL
        """
    )

    rec(
        "B10",
        fail_count=invalid_population,
        total_count=observation_total,
        column_name="populations_json.population",
        detail=("Nested population values with non-null raw text that cannot be parsed as BIGINT"),
        batch_id=batch_id,
    )

    # -------------------------------------------------------------------------
    # Standard profiling through DQRun
    # -------------------------------------------------------------------------

    if profile and entry.get("sharing") != "restricted":
        try:
            dq.profile_table(
                table_name,
                where=f"batch_id = {sql_str(batch_id)}",
            )
        except Exception as exc:
            print(f"  note: Bronze table profile skipped ({str(exc)[:150]})")

        try:
            dq.profile_table("psgc_population_observations")
        except Exception as exc:
            print(f"  note: nested population profile skipped ({str(exc)[:150]})")


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------


def parse_args():
    parser = argparse.ArgumentParser(description="Bronze QC for PSGC population data")

    parser.add_argument(
        "--config_path",
        default=None,
    )

    parser.add_argument(
        "--fail_on_error",
        default="true",
        choices=["true", "false"],
    )

    parser.add_argument(
        "--profile",
        default="true",
        choices=["true", "false"],
    )

    parser.add_argument(
        "--job_run_id",
        default=None,
    )

    parser.add_argument(
        "--code_version",
        default=None,
    )

    return parser.parse_known_args()[0]


def main():
    args = parse_args()

    config_path = find_config(args.config_path)

    print(f"Config: {config_path}")

    _, entry = load_config(config_path)

    print(f"[{SOURCE_KEY}] {entry.get('source_name')}")

    print(f"Bronze table: {entry.get('bronze_table')}")

    with DQRun(
        layer="bronze",
        domain=DOMAIN,
        script_name=SCRIPT_NAME,
        job_run_id=args.job_run_id,
        source_keys=SOURCE_KEY,
        fail_on_error=(args.fail_on_error == "true"),
        code_version=args.code_version,
        strict_registry=True,
    ) as dq:
        try:
            run_checks(
                dq,
                entry,
                profile=(args.profile == "true"),
            )

        except Exception as exc:
            name, check_type, severity = CHECKS["B00"]

            dq.record(
                "B00",
                table_name=entry.get("bronze_table"),
                source_key=SOURCE_KEY,
                status="FAIL",
                check_name=name,
                check_type=check_type,
                severity=severity,
                detail=(f"{type(exc).__name__}: {exc}"),
            )

            raise


if __name__ == "__main__":
    main()
