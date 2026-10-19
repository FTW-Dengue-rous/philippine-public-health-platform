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
#
# Added 2026-10-12 (population codes S51-S58; no change to the Silver notebook)
#   S51  lineage columns not null (source_version, content_checksum,        FAIL
#        batch_id, silver_processed_at)
#   S52  population filled exactly when the status is VALID or              FAIL
#        VALID_WITH_NOTE; VALID_WITH_NOTE exactly when a note was moved out
#   S53  rows without a usable population (MISSING / INVALID), listed       WARN
#   S54  every geography area has a row for every census year               WARN
#   S55  province / region total = sum of its cities and municipalities     WARN
#        (moved here from the last cell of psgc_population_silver.ipynb so
#        the result is stored in qc_results)
#   S56  national census total matches the PSA release (control)            WARN until confirmed
#   S57  one population snapshot, same PSGC release as geography Silver     WARN
#   S58  change between census years above 30% (province / city / mun)      WARN
#   S59  population years = the configured census years (added 2026-10-19) FAIL
#   strict_registry is False for now (same as the other silver QC scripts), so
#   these codes do not need to be registered yet. They are in Step 1 of
#   quality_registry_seed.sql; when silver QC is final, run the seed and pass
#   --strict_registry true (or change the default below).
#
# Fixed 2026-10-12: VALID_WITH_NOTE (added to the Silver notebook on
# 2026-10-11) is an approved parse status. Before, S09 counted those rows
# (32 on 2026-10-12) as invalid and failed.
#
# Fixed 2026-10-19 (silver revision 1, to-do 5e)
#   * One S00 row per crash. The except block records S00 and no longer
#     re-raises: DQRun.__exit__ wrote a second S00 for the same error.
#     The run still fails: S00 is a FAIL, so DQRun raises at exit when
#     --fail_on_error is true (the default).
#   * SCRIPT_NAME = psgc_population_silver_qc.py (the file name). Runs before
#     this date are in quality.run_log under population_silver_qc.py.
#   * S09: the Bronze observation view no longer builds an unused population
#     column (it removed commas only, unlike the Silver parse). S09 joins on
#     the grain and checks the Silver parse status; it never read that column.
#   * Census years and the S56 national controls moved to sources_population.yaml
#     (psgc_population.silver_qc). New S59 FAILs when the table holds a year the
#     YAML does not list, so a new census cannot slip past S54 and S56.
#
# Expected WARNs (known source gaps, not bugs; checked on the 2026-10-12 run, PSGC
# Q2_2024 payload). The live lists are in the qc_results detail of S54, S55, S56.
#   S54/S56: Negros Island Region has no 2015 / 2020 region rows; Sulu has no
#            2024 rows.
#   S55: Maguindanao del Norte 2015 and 2020 (province total excludes Cotabato
#        City), Benguet 2015 (444,224 vs 446,224 in the source).
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
SCRIPT_NAME = "psgc_population_silver_qc.py"  # the file name (2026-10-19)

SILVER_TABLE = "public_health.silver.population_silver"
GEOGRAPHY_SILVER_TABLE = "public_health.silver.geography_silver"

REQUIRED_COLUMNS = [
    "psgc_code",
    "population_year",
    "population",
    "population_raw",
    "population_parse_status",
    "population_note",
    "source_version",
    "content_checksum",
    "batch_id",
    "silver_processed_at",
]

APPROVED_PARSE_STATUS = ("VALID", "VALID_WITH_NOTE", "MISSING", "INVALID")
USABLE_PARSE_STATUS = ("VALID", "VALID_WITH_NOTE")  # population is a number

# S54 / S58 settings. PSGC level names (geography Silver vocabulary) and the S58 tolerance,
# which is part of the check's meaning (its name says 30 percent).
AREA_LEVELS = ("Reg", "Prov", "City", "Mun", "SubMun", "Bgy")
MAX_CHANGE_PCT = 30.0
# Census years (S54, S59) and the national control totals (S56) are data facts, so they live in
# sources_population.yaml under psgc_population.silver_qc (moved there 2026-10-19).

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
    # population codes (see header)
    "S51": ("population lineage columns not null", "COMPLETENESS", "FAIL"),
    "S52": ("population filled exactly when the status is valid", "VALIDITY", "FAIL"),
    "S53": ("rows without a usable population", "COMPLETENESS", "WARN"),
    "S54": ("every geography area has a row for every census year", "COMPLETENESS", "WARN"),
    "S55": ("area total equals the sum of its cities and municipalities", "CONSISTENCY", "WARN"),
    "S56": ("national census total matches the PSA release", "RECONCILIATION", "WARN"),
    "S57": ("one population snapshot from the current PSGC release", "CONSISTENCY", "WARN"),
    "S58": ("change between census years above 30 percent", "VALIDITY", "WARN"),
    "S59": ("population years are the configured census years", "CONSISTENCY", "FAIL"),
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


def silver_qc_settings(entry):
    """Census years and national controls from psgc_population.silver_qc in the YAML.
    A missing or malformed block stops the run (recorded as S00): the checks have no
    sensible default for these numbers."""
    sq = entry.get("silver_qc") or {}
    years = sorted(int(y) for y in (sq.get("census_years") or []))
    ctl = sq.get("control_totals") or {}
    expected = {int(y): int(n) for y, n in (ctl.get("expected") or {}).items()}
    if not years:
        raise KeyError(f"{SOURCE_KEY}.silver_qc.census_years is missing or empty in the YAML")
    if not expected:
        raise KeyError(f"{SOURCE_KEY}.silver_qc.control_totals.expected is missing in the YAML")
    if set(expected) - set(years):
        raise ValueError(
            f"control_totals years {sorted(set(expected) - set(years))} are not census_years {years}"
        )
    return {
        "census_years": years,
        "national_control": expected,
        "control_confirmed": bool(ctl.get("confirmed", False)),
        "control_tolerance_pct": float(ctl.get("tolerance_pct", 0.1)),
        "control_source": ctl.get("source"),
    }


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
            p.population AS population_raw
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
        total_count=silver_count,  # was missing: the log printed fail=0/None (fixed 2026-10-19)
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
           OR population_parse_status NOT IN ('VALID', 'VALID_WITH_NOTE', 'MISSING', 'INVALID')
        """
    )

    valid_without_raw = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE population_parse_status IN ('VALID', 'VALID_WITH_NOTE')
          AND population_raw IS NULL
        """
    )

    valid_without_population = scalar(
        f"""
        SELECT COUNT(*)
        FROM {table_name}
        WHERE population_parse_status IN ('VALID', 'VALID_WITH_NOTE')
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

    # S51-S58: added checks (see header). Same table, same DQRun session.
    run_population_checks(
        dq, table_name, geography_table, silver_count, skip, overrides, silver_qc_settings(entry)
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


def listing(sql, limit=15):
    """First rows of a query as one short text, for the detail column."""
    rows = spark.sql(sql).limit(limit).collect()
    return "; ".join(" ".join(str(v) for v in row) for row in rows) or None


def run_population_checks(dq, table_name, geography_table, silver_count, skip, overrides, settings):
    """S51-S59. Reads population Silver and geography Silver only; changes nothing.
    settings: census years and national controls from the YAML (silver_qc_settings)."""
    usable = "population_parse_status IN ('VALID', 'VALID_WITH_NOTE')"
    # Latest geography snapshot (geography Silver keeps one row per psgc_code per content_checksum)
    geo = f"""(SELECT psgc_code, geographic_level FROM {geography_table}
              WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at)
                                        FROM {geography_table}))"""
    levels = ", ".join(f"'{x}'" for x in AREA_LEVELS)
    census_years = settings["census_years"]
    years = ", ".join(str(y) for y in census_years)

    def rec(check_id, **kwargs):
        return record(dq, check_id, table_name, SOURCE_KEY, skip, overrides, **kwargs)

    # S59 - the years in the table are exactly the configured census years. Guards S54 and S56:
    # a census year added to the payload but not to the YAML would otherwise go unchecked.
    observed_years = [
        r[0]
        for r in spark.sql(
            f"SELECT DISTINCT population_year FROM {table_name} "
            "WHERE population_year IS NOT NULL ORDER BY 1"
        ).collect()
    ]
    rec(
        "S59",
        status="PASS" if observed_years == census_years else "FAIL",
        observed=",".join(str(y) for y in observed_years),
        expected=",".join(str(y) for y in census_years),
        column_name="population_year",
        detail="update psgc_population.silver_qc.census_years (and control_totals) in "
        "sources_population.yaml when PSA adds a census year",
    )

    # S51 - lineage columns not null (auditability)
    lineage = ["source_version", "content_checksum", "batch_id", "silver_processed_at"]
    missing_lineage = scalar(
        f"SELECT COUNT(*) FROM {table_name} WHERE " + " OR ".join(f"{c} IS NULL" for c in lineage)
    )
    rec(
        "S51",
        status="PASS" if missing_lineage == 0 else "FAIL",
        fail_count=missing_lineage,
        total_count=silver_count,
        column_name=", ".join(lineage),
    )

    # S52 - value agrees with its parse status
    status_mismatch = scalar(f"""
        SELECT COUNT(*) FROM {table_name}
        WHERE (population IS NOT NULL) <> COALESCE({usable}, FALSE)
           OR ((population_parse_status = 'VALID_WITH_NOTE')
               <> (population_note IS NOT NULL AND TRIM(population_note) <> ''))""")
    rec(
        "S52",
        status="PASS" if status_mismatch == 0 else "FAIL",
        fail_count=status_mismatch,
        total_count=silver_count,
        column_name="population, population_parse_status, population_note",
        detail="VALID* rows need a number; MISSING / INVALID stay null (never 0); "
        "VALID_WITH_NOTE exactly when a note was moved out",
    )

    # S53 - rows without a usable population (completeness, for a person to read)
    unusable = scalar(f"SELECT COUNT(*) FROM {table_name} WHERE NOT COALESCE({usable}, FALSE)")
    rec(
        "S53",
        status="PASS" if unusable == 0 else "WARN",
        fail_count=unusable,
        total_count=silver_count,
        column_name="population_parse_status",
        detail=listing(f"""SELECT population_parse_status, population_year, COUNT(*) FROM {table_name}
                           WHERE NOT COALESCE({usable}, FALSE) GROUP BY 1, 2 ORDER BY 1, 2"""),
    )

    # S54 - every geography area has a row for every census year
    spark.sql(f"""
        SELECT g.geographic_level AS level, y.year, g.psgc_code
        FROM {geo} g
        CROSS JOIN (SELECT EXPLODE(ARRAY({years})) AS year) y
        LEFT ANTI JOIN {table_name} p ON p.psgc_code = g.psgc_code AND p.population_year = y.year
        WHERE g.geographic_level IN ({levels})""").createOrReplaceTempView("population_qc_gaps")
    gaps = scalar("SELECT COUNT(*) FROM population_qc_gaps")
    expected_rows = scalar(
        f"SELECT COUNT(*) * {len(census_years)} FROM {geo} WHERE geographic_level IN ({levels})"
    )
    rec(
        "S54",
        status="PASS" if gaps == 0 else "WARN",
        fail_count=gaps,
        total_count=expected_rows,
        column_name="psgc_code, population_year",
        detail=listing("""SELECT level, year, COUNT(*) FROM population_qc_gaps GROUP BY 1, 2
                          ORDER BY CASE level WHEN 'Reg' THEN 1 WHEN 'Prov' THEN 2 WHEN 'City' THEN 3
                                   WHEN 'Mun' THEN 4 WHEN 'SubMun' THEN 5 ELSE 6 END, year"""),
    )

    # S55 - totals equal their parts (the notebook's last cell, now recorded).
    # Parts are City + Mun rows (never SubMun: Manila's districts are inside the City of Manila).
    # Province = parts with the same 5-digit prefix (HUCs carry their own prefix, so they are left
    # out, matching 2024 province totals that exclude HUCs). Region = parts with the same 2 digits.
    spark.sql(f"""
        WITH v AS (
          SELECT p.psgc_code, p.population_year AS year, p.population, g.geographic_level AS level
          FROM {table_name} p JOIN {geo} g ON g.psgc_code = p.psgc_code
          WHERE COALESCE({usable}, FALSE)),
        parts AS (SELECT * FROM v WHERE level IN ('City', 'Mun')),
        prov AS (
          SELECT 'province' AS kind, t.psgc_code, t.year, t.population AS published,
                 SUM(c.population) AS parts
          FROM v t JOIN parts c ON SUBSTR(c.psgc_code, 1, 5) = SUBSTR(t.psgc_code, 1, 5) AND c.year = t.year
          WHERE t.level = 'Prov' GROUP BY t.psgc_code, t.year, t.population),
        reg AS (
          SELECT 'region' AS kind, t.psgc_code, t.year, t.population AS published,
                 SUM(c.population) AS parts
          FROM v t JOIN parts c ON SUBSTR(c.psgc_code, 1, 2) = SUBSTR(t.psgc_code, 1, 2) AND c.year = t.year
          WHERE t.level = 'Reg' GROUP BY t.psgc_code, t.year, t.population)
        SELECT * FROM prov UNION ALL SELECT * FROM reg""").createOrReplaceTempView(
        "population_qc_rollup"
    )
    for kind, admin_level in (("province", 2), ("region", 1)):
        bad = scalar(
            f"SELECT COUNT(*) FROM population_qc_rollup WHERE kind = '{kind}' AND published <> parts"
        )
        rec(
            "S55",
            status="PASS" if bad == 0 else "WARN",
            fail_count=bad,
            total_count=scalar(f"SELECT COUNT(*) FROM population_qc_rollup WHERE kind = '{kind}'"),
            column_name=f"population ({kind})",
            admin_level=admin_level,
            detail=listing(f"""SELECT psgc_code, year, published, 'vs', parts FROM population_qc_rollup
                               WHERE kind = '{kind}' AND published <> parts ORDER BY year, psgc_code"""),
        )

    # S56 - national total vs the PSA census release (accuracy). Sum of region rows; a region
    # without a row that year (checked 2026-10-12: NIR in 2015 and 2020) is filled with the sum of
    # its cities and municipalities. Controls, tolerance and confirmed flag come from the YAML.
    confirmed = settings["control_confirmed"]
    tolerance = settings["control_tolerance_pct"]
    for year, expected in settings["national_control"].items():
        observed = scalar(f"""
            WITH v AS (
              SELECT p.psgc_code, p.population, g.geographic_level AS level
              FROM {table_name} p JOIN {geo} g ON g.psgc_code = p.psgc_code
              WHERE p.population_year = {year} AND COALESCE({usable}, FALSE)),
            regions AS (SELECT DISTINCT SUBSTR(psgc_code, 1, 2) AS r FROM {geo} WHERE geographic_level = 'Reg'),
            reg AS (SELECT SUBSTR(psgc_code, 1, 2) AS r, MAX(population) AS pop FROM v
                    WHERE level = 'Reg' GROUP BY 1),
            lgu AS (SELECT SUBSTR(psgc_code, 1, 2) AS r, SUM(population) AS pop FROM v
                    WHERE level IN ('City', 'Mun') GROUP BY 1)
            SELECT COALESCE(SUM(COALESCE(reg.pop, lgu.pop)), 0)
            FROM regions LEFT JOIN reg ON reg.r = regions.r LEFT JOIN lgu ON lgu.r = regions.r""")
        diff_pct = abs(observed - expected) * 100.0 / expected
        severity = "FAIL" if confirmed else "WARN"
        record(
            dq,
            "S56",
            table_name,
            SOURCE_KEY,
            skip,
            {**overrides, "S56": severity},
            status="PASS" if diff_pct <= tolerance else severity,
            observed=observed,
            expected=expected,
            column_name="population",
            admin_level=0,
            detail=f"{year}: difference {observed - expected:+,} ({diff_pct:.3f}%), tolerance "
            f"{tolerance}%; control: {settings['control_source'] or 'sources_population.yaml'}"
            + ("" if confirmed else "; control not confirmed yet"),
        )

    # S57 - one population snapshot, from the same PSGC release as geography Silver (timeliness)
    snapshots = scalar(f"SELECT COUNT(DISTINCT content_checksum) FROM {table_name}")
    pop_checksum = scalar(f"SELECT MAX(content_checksum) FROM {table_name}")
    geo_checksum = scalar(
        f"SELECT max_by(content_checksum, silver_processed_at) FROM {geography_table}"
    )
    rec(
        "S57",
        status="PASS" if snapshots == 1 and pop_checksum == geo_checksum else "WARN",
        observed=f"{snapshots} snapshot(s); population {str(pop_checksum)[:12]}, geography {str(geo_checksum)[:12]}",
        expected="1 snapshot, same as geography Silver",
        column_name="content_checksum",
        detail="Population and geography come from the same PSGC payload: rerun the population "
        "notebook after geography takes a new release",
    )

    # S58 - business rule: plausible change between census years
    spark.sql(f"""
        SELECT p.psgc_code, g.geographic_level AS level, p.population_year AS year, p.population,
               LAG(p.population) OVER (PARTITION BY p.psgc_code ORDER BY p.population_year) AS previous
        FROM {table_name} p JOIN {geo} g ON g.psgc_code = p.psgc_code
        WHERE COALESCE({usable}, FALSE) AND g.geographic_level IN ('Prov', 'City', 'Mun')
    """).createOrReplaceTempView("population_qc_change")
    change = f"previous > 0 AND ABS(population - previous) * 100.0 / previous > {MAX_CHANGE_PCT}"
    jumps = scalar(f"SELECT COUNT(*) FROM population_qc_change WHERE {change} OR population = 0")
    rec(
        "S58",
        status="PASS" if jumps == 0 else "WARN",
        fail_count=jumps,
        total_count=scalar("SELECT COUNT(*) FROM population_qc_change WHERE previous IS NOT NULL"),
        column_name="population",
        detail=listing(f"""SELECT psgc_code, level, year, previous, 'to', population FROM population_qc_change
                           WHERE {change} OR population = 0 ORDER BY year, psgc_code"""),
    )


def parse_args():
    parser = argparse.ArgumentParser(description="Silver QC for PSGC population data")
    parser.add_argument("--config_path", default=None)
    parser.add_argument(
        "--fail_on_error",
        default="true",
        choices=["true", "false"],
    )
    parser.add_argument(
        "--strict_registry",
        default="false",
        choices=["true", "false"],
        help="false until silver QC is final; true needs every code in quality.check_registry "
        "(quality_registry_seed.sql)",
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
        strict_registry=args.strict_registry == "true",
    ) as dq:
        # A crash is recorded once, here, with the table and source key. No re-raise:
        # DQRun.__exit__ would record a second S00 for the same error. S00 is a FAIL,
        # so DQRun still raises at exit (fail_on_error) and the job task fails.
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


if __name__ == "__main__":
    main()