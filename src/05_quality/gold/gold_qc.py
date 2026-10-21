# =============================================================================
# Gold QC for the gold data model (public_health.gold): checks the PUBLISHED gold tables and
# writes the results through dq_utils.DQRun (quality.qc_results, run_log, table_stats,
# profile). Any FAIL makes the run raise at the end, so the dashboard refresh (or any task
# that depends on this one) does not start.
#
# The gold build files already gate their own candidate before publishing (write-audit-
# publish). This script is the check AFTER publishing: it proves the published tables are
# the ones the pipeline built, are fresh against their inputs, still reconcile with silver,
# follow the selection contracts, and did not change between two runs on the same inputs.
#
#   Code  Check                                                        Severity
#   G00   QC ran without error (written by DQRun on a crash)           FAIL
#   G01   table has rows                                               FAIL
#   G02   primary key complete and unique                              FAIL
#   G03   grain (natural key) unique                                   FAIL
#   G04   foreign key resolves to its dimension                        FAIL
#   G05   published table = its latest succeeded build (rows; no data FAIL
#         write after the build version - OPTIMIZE / VACUUM ignored)
#   G06   built from the latest build of every input (freshness)       FAIL
#   G07   control total: gold = silver                                 FAIL (claims: WARN when lower)
#   G08   value and value_status consistent; measures on their basis   FAIL
#   G09   default view / mart / seed readable and not empty            FAIL
#   G10   one preferred source per disease series (selection contract) FAIL
#   G11   measure values in a valid range                              FAIL
#   G12   content fingerprint unchanged since the previous QC run      WARN  (idempotency evidence)
#   G13   census population change between censuses plausible         WARN  (business monitoring)
#
# Which data is checked
#   Each of the 9 model tables is read at ONE fixed Delta version (its latest), so every check
#   of a table sees the same data. Silver tables are read as they are now: G06 is what proves
#   gold was built from their latest build.
#
# Idempotency (G12)
#   observed = "rows=<n>;hash=<sum of row hashes>", computed on every column except
#   _gold_build_id (the only column that changes on a rebuild of the same inputs). Run the
#   pipeline twice with no new data: every G12 row should PASS with "same as previous".
#   A WARN means the content changed; detail says whether the inputs' versions changed too.
#
# How to run (Databricks, Serverless or classic)
#   Python script task:  gold_qc.py  [--job_run_id {{job.run_id}}] [--gold_schema public_health.gold]
#                        [--silver_schema public_health.silver] [--profile true|false]
#                        [--check_views true|false] [--fail_on_error true|false]
#   Notebook cell:       import runpy; runpy.run_path("<repo>/src/05_quality/gold/gold_qc.py",
#                                                     run_name="__main__")
#   All parameters are optional; job/widget parameters of the same names work too.
#   Run after the last gold file (gold_24_mart_evidence_readiness.sql).
#
# Registry: G00-G13 are in quality_registry_seed.sql (Step 1b) since 2026-10-21. The script
# runs with the dq_utils default strict_registry=True since 2026-10-21 (O-17: the qc_registry
# task passed in the final runs), so an unknown code stops it. check_name and check_type are
# still passed here, so qc_results reads the same as before.
# =============================================================================

import argparse
import importlib.util
import os
import sys

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
    p = argparse.ArgumentParser(description="Gold QC")
    p.add_argument("--gold_schema", default=None, help="Default public_health.gold")
    p.add_argument("--silver_schema", default=None, help="Default public_health.silver")
    p.add_argument("--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job")
    p.add_argument("--code_version", default=None, help="Git commit, if you pass one")
    p.add_argument(
        "--profile", default=None, help="true (default): column profile of the 9 model tables"
    )
    p.add_argument(
        "--check_views", default=None, help="true (default): G09 on views, marts and seeds"
    )
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


def param(value, name, default=None):
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
    return default


ARGS = parse_args()
GOLD = param(ARGS.gold_schema, "gold_schema", default="public_health.gold")
SILVER = param(ARGS.silver_schema, "silver_schema", default="public_health.silver")
JOB_RUN_ID = param(ARGS.job_run_id, "job_run_id")
CODE_VERSION = param(ARGS.code_version, "code_version")
PROFILE = param(ARGS.profile, "profile", default="true").lower() == "true"
CHECK_VIEWS = param(ARGS.check_views, "check_views", default="true").lower() == "true"
FAIL_ON_ERROR = param(ARGS.fail_on_error, "fail_on_error", default="true").lower() == "true"
DQ = param(ARGS.dq_schema, "dq_schema", default=DQ_SCHEMA)

print(f"Gold schema    : {GOLD}")
print(f"Silver schema  : {SILVER}")
print(f"Quality schema : {DQ}")


# -----------------------------------------------------------------------------
# What is checked: the 9 model tables (keys, grain, foreign keys) and the objects built on them
# -----------------------------------------------------------------------------
FK_GEO = ("dim_geography", "area_key")
FK_DATE = ("dim_date", "date_key")
FK_SRC = ("dim_data_source", "data_source_key")
FK_DIS = ("dim_disease", "disease_key")

MODEL = {
    "dim_geography": dict(
        pk="area_key",
        grain=["area_code"],
        required=["area_code"],
        fks={
            "parent_area_key": FK_GEO,
            "region_key": FK_GEO,
            "province_key": FK_GEO,
            "planning_unit_key": FK_GEO,
            "broad_unit_key": FK_GEO,
        },
    ),
    "dim_facility": dict(
        pk="facility_key",
        grain=["facility_source_id"],
        required=["facility_source_id"],
        fks={"area_key": FK_GEO},
    ),
    "dim_disease": dict(
        pk="disease_key", grain=["disease_code"], required=["disease_code"], fks={}
    ),
    "dim_date": dict(
        pk="date_key",
        grain=["period_basis", "period_label"],
        required=["period_basis", "period_label"],
        fks={},
    ),
    "dim_data_source": dict(
        pk="data_source_key", grain=["source_dataset"], required=["source_dataset"], fks={}
    ),
    "fact_facility_capacity": dict(
        pk="fact_facility_capacity_key",
        grain=[
            "area_key",
            "date_key",
            "data_source_key",
            "capacity_basis",
            "facility_category",
            "ownership",
            "hospital_level",
        ],
        required=[
            "area_key",
            "date_key",
            "data_source_key",
            "capacity_basis",
            "facility_category",
            "ownership",
        ],
        fks={"area_key": FK_GEO, "date_key": FK_DATE, "data_source_key": FK_SRC},
    ),
    "fact_disease_metric": dict(
        pk="fact_disease_metric_key",
        grain=[
            "disease_key",
            "area_key",
            "date_key",
            "data_source_key",
            "age_group",
            "sex",
            "metric_name",
            "metric_basis",
        ],
        required=[
            "disease_key",
            "area_key",
            "date_key",
            "data_source_key",
            "age_group",
            "sex",
            "metric_name",
            "metric_basis",
        ],
        fks={
            "disease_key": FK_DIS,
            "area_key": FK_GEO,
            "date_key": FK_DATE,
            "data_source_key": FK_SRC,
        },
    ),
    "fact_workforce_capacity": dict(
        pk="fact_workforce_capacity_key",
        grain=["area_key", "date_key", "profession_code", "data_source_key"],
        required=["area_key", "date_key", "data_source_key", "profession_code"],
        fks={"area_key": FK_GEO, "date_key": FK_DATE, "data_source_key": FK_SRC},
    ),
    "fact_area_indicator": dict(
        pk="fact_area_indicator_key",
        grain=["area_key", "date_key", "data_source_key", "indicator_name", "indicator_category"],
        required=[
            "area_key",
            "date_key",
            "data_source_key",
            "indicator_name",
            "indicator_category",
        ],
        fks={"area_key": FK_GEO, "date_key": FK_DATE, "data_source_key": FK_SRC},
    ),
}

# Objects built on the model (files 10-24): readable and not empty (G09). Views are re-computed
# from the model tables on every read, so they get no fingerprint.
DERIVED = [
    "source_priority",
    "huc_province_crosswalk",
    "area_coverage_map",
    "ref_osm_healthsite_point",
    "v_facility_capacity_totals",
    "v_disease_metric_totals",
    "v_workforce_preferred",
    "v_area_indicator_latest",
    "mart_locality_service_presence",
    "mart_base_planning_unit",
    "mart_area_service_profile",
    "mart_area_burden_indicator",
    "mart_area_evidence",
    "priority_weight_params",
    "mart_area_priority",
    "fact_area_access",
    "mart_dengue_peak_capacity",
    "mart_tb_case_study",
    "mart_kidney_case_study",
    "mart_evidence_readiness",
]

VOLATILE_COLUMNS = {"_gold_build_id"}  # change on every rebuild of the same inputs


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def scalar(query):
    v = spark.sql(query).first()[0]
    return 0 if v is None else v


def full(name):
    return f"{GOLD}.{name}"


def view(name):
    return f"gq_{name}"  # temp view of the model table at its fixed Delta version


# Delta operations that rewrite files but never change the data (predictive optimization runs
# some of them on its own). A version written by one of these does not count as a new write.
MAINTENANCE_OPS = {
    "OPTIMIZE",
    "VACUUM START",
    "VACUUM END",
    "ANALYZE",
    "SET TBLPROPERTIES",
    "SET TABLE PROPERTIES",
    "ADD CONSTRAINT",
    "CHANGE COLUMN",
    "UPGRADE PROTOCOL",
    "REORG",
    "COMPUTE STATISTICS",
}


def read_fixed(table_name):
    """Latest Delta version of a table, read at that version. Returns (df, version, history),
    history = [(version, operation)] newest first."""
    try:
        history = [
            (int(r["version"]), str(r["operation"]))
            for r in spark.sql(f"DESCRIBE HISTORY {table_name} LIMIT 50").collect()
        ]
        version = history[0][0]
        return (
            spark.read.format("delta").option("versionAsOf", version).table(table_name),
            version,
            history,
        )
    except Exception as e:  # not a Delta table (local test, view)
        print(f"  {table_name}: no Delta history, reading as is ({str(e)[:80]})")
        return spark.table(table_name), None, []


def latest_build(table_name):
    rows = spark.sql(f"""
        SELECT build_id, started_at, finished_at, row_count, target_table_version
        FROM {DQ}.v_latest_build WHERE target_table = '{table_name}'""").collect()
    return rows[0] if rows else None


def previous_observed(check_id, table_name, current_validation_id):
    rows = spark.sql(f"""
        SELECT observed FROM {DQ}.qc_results
        WHERE check_id = '{check_id}' AND table_name = '{table_name}' AND layer = 'gold'
          AND validation_id <> '{current_validation_id}' AND observed IS NOT NULL
        ORDER BY executed_at DESC LIMIT 1""").collect()
    return rows[0]["observed"] if rows else None


def fingerprint(df):
    cols = [c for c in df.columns if c not in VOLATILE_COLUMNS]
    r = (
        df.select(
            F.xxhash64(F.to_json(F.struct(*[F.col(f"`{c}`") for c in cols])))
            .cast("decimal(38,0)")
            .alias("h")
        )
        .agg(F.count(F.lit(1)).alias("n"), F.sum("h").alias("s"))
        .first()
    )
    return f"rows={r['n']};hash={r['s'] if r['s'] is not None else 0}"


# -----------------------------------------------------------------------------
# Read the 9 model tables at one fixed version each
# -----------------------------------------------------------------------------
SNAP = {}
for name in MODEL:
    df, version, history = read_fixed(full(name))
    df.createOrReplaceTempView(view(name))
    SNAP[name] = {
        "version": version,
        "history": history,
        "rows": df.count(),
        "df": df,
        "build": latest_build(full(name)),
    }
    print(f"  {full(name)}: version {version}, {SNAP[name]['rows']} rows")


def batch(name):
    b = SNAP[name]["build"]
    return f"build:{b['build_id']}" if b else None


# =============================================================================
# CHECKS: DQRun saves the results, then raises if any check is FAIL.
# =============================================================================
with DQRun(
    layer="gold",
    domain="gold",
    script_name="gold_qc.py",
    job_run_id=JOB_RUN_ID,
    source_keys="ALL",
    fail_on_error=FAIL_ON_ERROR,
    code_version=CODE_VERSION,
    dq_schema=DQ,
    spark=spark,
) as dq:

    def rec(check_id, name, table, check_name, check_type, severity="FAIL", **kw):
        return dq.record(
            check_id,
            table_name=full(table) if table else None,
            batch_id=batch(table) if table in SNAP else None,
            check_name=check_name,
            check_type=check_type,
            severity=severity,
            **kw,
        )

    # ---------------------------------------------------------------- per model table
    for name, spec in MODEL.items():
        t, v, n = full(name), view(name), SNAP[name]["rows"]
        dq.capture_table_stats(t)
        if PROFILE:
            dq.profile_table(t)

        # G01 rows
        rec(
            "G01",
            name,
            name,
            "Table has rows",
            "COMPLETENESS",
            status="PASS" if n > 0 else "FAIL",
            observed=n,
            expected="> 0",
        )

        # G02 primary key complete and unique
        pk = spec["pk"]
        req = " OR ".join(f"`{c}` IS NULL" for c in [pk] + spec["required"])
        null_keys = scalar(f"SELECT count(*) FROM {v} WHERE {req}")
        dup_pk = scalar(
            f"SELECT coalesce(sum(c - 1), 0) FROM (SELECT count(*) AS c FROM {v} "
            f"GROUP BY `{pk}` HAVING count(*) > 1)"
        )
        rec(
            "G02",
            name,
            name,
            "Primary key complete and unique",
            "UNIQUENESS",
            column_name=pk,
            fail_count=null_keys + dup_pk,
            total_count=n,
            threshold=0,
            detail=f"null key or required column: {null_keys}; duplicate {pk}: {dup_pk}",
        )

        # G03 grain unique
        g = ", ".join(f"`{c}`" for c in spec["grain"])
        dup_grain = scalar(
            f"SELECT coalesce(sum(c - 1), 0) FROM (SELECT count(*) AS c FROM {v} "
            f"GROUP BY {g} HAVING count(*) > 1)"
        )
        rec(
            "G03",
            name,
            name,
            "Grain unique",
            "UNIQUENESS",
            column_name=", ".join(spec["grain"]),
            fail_count=dup_grain,
            total_count=n,
            threshold=0,
        )

        # G04 foreign keys
        for col, (dim, dim_col) in spec["fks"].items():
            total = scalar(f"SELECT count(DISTINCT `{col}`) FROM {v} WHERE `{col}` IS NOT NULL")
            orphans = scalar(f"""
                SELECT count(*) FROM (SELECT DISTINCT `{col}` AS k FROM {v} WHERE `{col}` IS NOT NULL) c
                LEFT ANTI JOIN {view(dim)} d ON d.`{dim_col}` = c.k""")
            rec(
                "G04",
                name,
                name,
                "Foreign key resolves",
                "INTEGRITY",
                column_name=col,
                fail_count=orphans,
                total_count=total,
                threshold=0,
                detail=f"distinct {col} values not in {dim}.{dim_col}",
            )

        # G05 the published table is the one its latest succeeded build wrote
        b = SNAP[name]["build"]
        if b is None:
            rec(
                "G05",
                name,
                name,
                "Published table = latest succeeded build",
                "AUDITABILITY",
                status="FAIL",
                observed="no succeeded build",
                expected="a row in v_latest_build",
                detail="table written outside the gold build files, or build_log not written",
            )
        else:
            problems = []
            if b["row_count"] is not None and int(b["row_count"]) != n:
                problems.append(f"rows {n} <> build {b['row_count']}")
            if b["target_table_version"] is not None and SNAP[name]["version"] is not None:
                built = int(b["target_table_version"])
                later = [
                    f"v{ver} {op}"
                    for ver, op in SNAP[name]["history"]
                    if ver > built and op.upper() not in MAINTENANCE_OPS
                ]
                if SNAP[name]["version"] < built:
                    problems.append(
                        f"version {SNAP[name]['version']} is older than build {built} (restored?)"
                    )
                elif later:
                    problems.append(f"written after build v{built}: {', '.join(later[:5])}")
            rec(
                "G05",
                name,
                name,
                "Published table = latest succeeded build",
                "AUDITABILITY",
                status="FAIL" if problems else "PASS",
                observed=f"version {SNAP[name]['version']}, rows {n}",
                expected=f"version {b['target_table_version']}, rows {b['row_count']}",
                detail="; ".join(problems) or f"build {b['build_id']} finished {b['finished_at']}",
            )

        # G06 freshness: every input table read at the version of its latest build
        if b is not None:
            inputs = spark.sql(f"""
                SELECT i.input_table, i.input_table_version AS used_version,
                       lb.target_table_version AS latest_version, lb.finished_at AS latest_finished_at
                FROM {DQ}.build_inputs i
                LEFT JOIN {DQ}.v_latest_build lb ON lb.target_table = i.input_table
                WHERE i.build_id = '{b["build_id"]}' AND i.target_table = '{t}'
                  AND i.input_kind = 'table' AND i.input_table IS NOT NULL""").collect()
            stale, unknown = [], []
            for r in inputs:
                short = r["input_table"].split(".")[-1]
                if r["latest_version"] is None:
                    unknown.append(short)  # silver written by a notebook: no build row
                elif r["used_version"] is None:
                    if r["latest_finished_at"] and r["latest_finished_at"] > b["started_at"]:
                        stale.append(f"{short} (rebuilt after this build)")
                elif int(r["latest_version"]) > int(r["used_version"]):
                    stale.append(f"{short} v{r['used_version']} -> v{r['latest_version']}")
            rec(
                "G06",
                name,
                name,
                "Built from the latest build of every input",
                "TIMELINESS",
                fail_count=len(stale),
                total_count=len(inputs),
                threshold=0,
                observed=", ".join(stale) or "all inputs current",
                expected="no input rebuilt since this build",
                detail=("no build row (not checked): " + ", ".join(unknown)) if unknown else None,
            )

        # G12 idempotency fingerprint
        fp = fingerprint(SNAP[name]["df"])
        prev = previous_observed("G12", t, dq.validation_id)
        inputs_note = ""
        if b is not None:
            vers = spark.sql(f"""SELECT concat_ws(', ', sort_array(collect_list(concat(
                                     element_at(split(input_table, '[.]'), -1), '@v',
                                     coalesce(CAST(input_table_version AS STRING), '?')))))
                                 FROM {DQ}.build_inputs
                                 WHERE build_id = '{b["build_id"]}' AND target_table = '{t}'
                                   AND input_kind = 'table'""").first()[0]
            inputs_note = f"inputs: {vers}"
        rec(
            "G12",
            name,
            name,
            "Content unchanged since previous QC run (idempotency)",
            "CONSISTENCY",
            severity="WARN",
            status="PASS" if prev is None or prev == fp else "WARN",
            observed=fp,
            expected=prev or "first run: no previous fingerprint",
            detail=(
                "same as previous"
                if prev == fp
                else "first fingerprint"
                if prev is None
                else "content changed since the previous QC run"
            )
            + (f" | {inputs_note}" if inputs_note else ""),
        )

    # ---------------------------------------------------------------- G07 control totals gold = silver
    census = f"""(SELECT psgc_code, CAST(population AS BIGINT) AS population,
                         upper(trim(population_parse_status)) AS st
                  FROM {SILVER}.population_silver
                  WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at)
                                            FROM {SILVER}.population_silver))"""
    controls = [
        (
            "dim_facility",
            "rows = facilities_registry_silver rows",
            f"SELECT count(*) FROM {view('dim_facility')}",
            f"SELECT count(*) FROM {SILVER}.facilities_registry_silver",
        ),
        (
            "dim_facility",
            "analysis_beds = registry total",
            f"SELECT sum(analysis_beds) FROM {view('dim_facility')}",
            f"SELECT sum(analysis_beds) FROM {SILVER}.facilities_registry_silver",
        ),
        (
            "fact_facility_capacity",
            "registry facility_count = listed registry rows",
            f"SELECT sum(facility_count) FROM {view('fact_facility_capacity')} WHERE capacity_basis = 'registry_snapshot'",
            f"SELECT count(*) FROM {SILVER}.facilities_registry_silver WHERE facility_status = 'listed'",
        ),
        (
            "fact_facility_capacity",
            "registry analysis_beds = listed registry total",
            f"SELECT sum(analysis_beds) FROM {view('fact_facility_capacity')} WHERE capacity_basis = 'registry_snapshot'",
            f"SELECT sum(analysis_beds) FROM {SILVER}.facilities_registry_silver WHERE facility_status = 'listed'",
        ),
        (
            "fact_facility_capacity",
            "published hospitals = facilities_metric_silver total",
            f"SELECT sum(facility_count) FROM {view('fact_facility_capacity')} "
            f"WHERE capacity_basis = 'published_statistic' AND facility_category = 'hospital'",
            f"SELECT sum(hospitals) FROM {SILVER}.facilities_metric_silver",
        ),
        (
            "fact_facility_capacity",
            "published authorized_beds = facilities_metric_silver total",
            f"SELECT sum(authorized_beds) FROM {view('fact_facility_capacity')} WHERE capacity_basis = 'published_statistic'",
            f"SELECT sum(authorized_beds) FROM {SILVER}.facilities_metric_silver",
        ),
        (
            "fact_disease_metric",
            "metric + deaths-by-age + TB programme rows = silver rows",
            f"SELECT count(*) FROM {view('fact_disease_metric')} WHERE metric_name NOT LIKE 'claims%'",
            f"""SELECT (SELECT count(*) FROM {SILVER}.diseases_metric_silver)
                  + (SELECT count(*) FROM {SILVER}.diseases_deaths_age_silver)
                  + (SELECT count(*) FROM {SILVER}.diseases_tb_programme_silver)""",
        ),
        (
            "fact_disease_metric",
            "metric + deaths-by-age + TB programme value total = silver ok total",
            f"SELECT sum(value) FROM {view('fact_disease_metric')} WHERE metric_name NOT LIKE 'claims%'",
            f"""SELECT coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN value END) FROM {SILVER}.diseases_metric_silver), 0)
                  + coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN deaths END) FROM {SILVER}.diseases_deaths_age_silver), 0)
                  + coalesce((SELECT sum(CASE WHEN value_status = 'ok' THEN value END) FROM {SILVER}.diseases_tb_programme_silver), 0)""",
        ),
        (
            "fact_workforce_capacity",
            "rows = workforce_headcount_silver rows",
            f"SELECT count(*) FROM {view('fact_workforce_capacity')}",
            f"SELECT count(*) FROM {SILVER}.workforce_headcount_silver",
        ),
        (
            "fact_workforce_capacity",
            "eligible headcount = silver eligible total",
            f"SELECT sum(headcount_total) FROM {view('fact_workforce_capacity')} WHERE analysis_eligible",
            f"SELECT sum(CASE WHEN analysis_eligible THEN headcount_total END) FROM {SILVER}.workforce_headcount_silver",
        ),
        (
            "fact_area_indicator",
            "census population = population_silver total (areas in dim_geography)",
            f"SELECT sum(value) FROM {view('fact_area_indicator')} "
            f"WHERE indicator_name = 'population' AND indicator_category = 'census'",
            f"""SELECT sum(CASE WHEN s.st IN ('VALID', 'VALID_WITH_NOTE') THEN s.population END)
             FROM {census} s LEFT SEMI JOIN {view("dim_geography")} g ON g.psgc_code = s.psgc_code""",
        ),
        (
            "fact_area_indicator",
            "poverty rows = 2 x socioeconomic_poverty_silver rows",
            f"SELECT count(*) FROM {view('fact_area_indicator')} "
            f"WHERE indicator_name IN ('poverty_incidence_pct', 'poor_population')",
            f"SELECT 2 * count(*) FROM {SILVER}.socioeconomic_poverty_silver",
        ),
    ]
    for table, label, gold_sql, silver_sql in controls:
        gv, sv = scalar(gold_sql), scalar(silver_sql)
        diff = abs(float(gv) - float(sv))
        rec(
            "G07",
            table,
            table,
            "Control total gold = silver",
            "RECONCILIATION",
            status="PASS" if diff < 1 else "FAIL",
            observed=gv,
            expected=sv,
            detail=label,
        )

    # Claims: region cells hold every hospital, but a region cell built from fewer than 3 hospitals
    # is suppressed (value null). So gold may be LOWER than silver (WARN), never higher (FAIL).
    gv = scalar(f"""SELECT sum(value) FROM {view("fact_disease_metric")}
                    WHERE metric_name = 'claims_filed' AND coverage_basis = 'facility_location_region'""")
    sv = scalar(f"SELECT sum(claims_count) FROM {SILVER}.diseases_hospital_claims_silver")
    supp = scalar(f"""SELECT count(*) FROM {view("fact_disease_metric")}
                      WHERE metric_name = 'claims_filed' AND coverage_basis = 'facility_location_region'
                        AND value_status = 'suppressed'""")
    rec(
        "G07",
        "fact_disease_metric",
        "fact_disease_metric",
        "Control total gold = silver",
        "RECONCILIATION",
        severity="FAIL",
        status="PASS" if abs(float(gv) - float(sv)) < 1 else ("WARN" if gv < sv else "FAIL"),
        observed=gv,
        expected=sv,
        detail=f"claims_filed at region level = silver claims_count; {supp} region cells suppressed (< 3 hospitals)",
    )

    # ---------------------------------------------------------------- G08 value / status / basis consistency
    consistency = [
        (
            "fact_disease_metric",
            "value filled only when value_status = ok",
            f"SELECT count(*) FROM {view('fact_disease_metric')} WHERE (value IS NULL) = (value_status = 'ok')",
        ),
        (
            "fact_area_indicator",
            "value filled only when value_status = ok",
            f"SELECT count(*) FROM {view('fact_area_indicator')} WHERE (value IS NULL) = (value_status = 'ok')",
        ),
        (
            "fact_facility_capacity",
            "suppressed occupancy row shows no measure",
            f"""SELECT count(*) FROM {view("fact_facility_capacity")} WHERE value_status = 'suppressed'
             AND coalesce(bor_weighted_pct, bor_median_pct, bor_weighted_beds_sum, bor_eligible_record_count) IS NOT NULL""",
        ),
        (
            "fact_facility_capacity",
            "measures only on their own capacity_basis",
            f"""SELECT count(*) FROM {view("fact_facility_capacity")}
             WHERE (capacity_basis = 'occupancy_report' AND (facility_count IS NOT NULL OR authorized_beds IS NOT NULL))
                OR (capacity_basis <> 'occupancy_report' AND coalesce(bor_weighted_pct, bor_median_pct) IS NOT NULL)
                OR (capacity_basis <> 'registry_snapshot' AND coalesce(analysis_beds, dialysis_stations) IS NOT NULL)""",
        ),
        (
            "fact_workforce_capacity",
            "eligible row has a headcount; one preferred source per cell",
            f"""SELECT (SELECT count(*) FROM {view("fact_workforce_capacity")} WHERE analysis_eligible AND headcount_total IS NULL)
                  + (SELECT count(*) FROM (SELECT 1 FROM {view("fact_workforce_capacity")} WHERE source_role = 'preferred'
                                           GROUP BY area_key, date_key, profession_code HAVING count(*) > 1))""",
        ),
        (
            "fact_disease_metric",
            "by-age and by-sex rows never labelled as totals",
            f"""SELECT count(*) FROM {view("fact_disease_metric")}
             WHERE (age_group = 'all_ages' AND (age_min IS NOT NULL OR age_max IS NOT NULL))
                OR sex NOT IN ('male', 'female', 'both_sexes')""",
        ),
    ]
    for table, label, q in consistency:
        rec(
            "G08",
            table,
            table,
            "Value, status and basis consistent",
            "CONSISTENCY",
            fail_count=scalar(q),
            total_count=SNAP[table]["rows"],
            threshold=0,
            detail=label,
        )

    # ---------------------------------------------------------------- G11 valid ranges
    ranges = [
        (
            "fact_facility_capacity",
            "counts and beds >= 0; occupancy 0 to 150",
            f"""SELECT count(*) FROM {view("fact_facility_capacity")}
             WHERE least(facility_count, authorized_beds, analysis_beds, dialysis_stations) < 0
                OR bor_weighted_pct NOT BETWEEN 0 AND 150 OR bor_median_pct NOT BETWEEN 0 AND 150""",
        ),
        (
            "fact_disease_metric",
            "counts >= 0; claims paid <= claims filed",
            f"""SELECT (SELECT count(*) FROM {view("fact_disease_metric")} WHERE value < 0)
                  + (SELECT count(*) FROM {view("fact_disease_metric")} p
                     JOIN {view("fact_disease_metric")} f
                       ON f.disease_key = p.disease_key AND f.area_key = p.area_key AND f.date_key = p.date_key
                      AND f.data_source_key = p.data_source_key AND f.coverage_basis = p.coverage_basis
                      AND f.metric_name = 'claims_filed'
                     WHERE p.metric_name = 'claims_paid' AND p.value > f.value)""",
        ),
        (
            "fact_workforce_capacity",
            "headcounts >= 0",
            f"""SELECT count(*) FROM {view("fact_workforce_capacity")}
             WHERE least(headcount_total, headcount_lgu_hired, headcount_doh_hired) < 0""",
        ),
        (
            "fact_area_indicator",
            "persons >= 0; incidence and shares 0 to 100",
            f"""SELECT count(*) FROM {view("fact_area_indicator")}
             WHERE (indicator_unit = 'persons' AND value < 0)
                OR (indicator_name IN ('poverty_incidence_pct', 'health_expenditure_share_pct')
                    AND value NOT BETWEEN 0 AND 100)""",
        ),
    ]
    for table, label, q in ranges:
        rec(
            "G11",
            table,
            table,
            "Measure values in a valid range",
            "VALIDITY",
            fail_count=scalar(q),
            total_count=SNAP[table]["rows"],
            threshold=0,
            detail=label,
        )

    # ---------------------------------------------------------------- G13 business monitoring (WARN)
    jumps = spark.sql(f"""
        WITH p AS (
          SELECT f.area_key, g.area_name, d.year, f.value,
                 lag(f.value) OVER (PARTITION BY f.area_key ORDER BY d.year) AS prev_value,
                 lag(d.year) OVER (PARTITION BY f.area_key ORDER BY d.year) AS prev_year
          FROM {view("fact_area_indicator")} f
          JOIN {view("dim_date")} d ON d.date_key = f.date_key
          JOIN {view("dim_geography")} g ON g.area_key = f.area_key
          WHERE f.indicator_name = 'population' AND f.indicator_category = 'census' AND f.value_status = 'ok')
        SELECT area_name, prev_year, year, prev_value, value FROM p
        WHERE prev_value > 0 AND (value / prev_value < 0.5 OR value / prev_value > 2)""")
    n_jumps = jumps.count()
    examples = "; ".join(
        f"{r['area_name']} {r['prev_year']}->{r['year']}: {int(r['prev_value'])}->{int(r['value'])}"
        for r in jumps.limit(5).collect()
    )
    n_pairs = scalar(f"""SELECT count(*) - count(DISTINCT area_key) FROM {view("fact_area_indicator")}
                         WHERE indicator_name = 'population' AND indicator_category = 'census' AND value_status = 'ok'""")
    rec(
        "G13",
        "fact_area_indicator",
        "fact_area_indicator",
        "Census population change plausible",
        "BUSINESS_RULE",
        severity="WARN",
        fail_count=n_jumps,
        total_count=n_pairs,
        threshold=0,
        detail=f"area halved or more than doubled between censuses; {examples or 'none'}",
    )

    # ---------------------------------------------------------------- G10 selection contract: preferred source
    try:
        multi = scalar(f"""
            SELECT count(*) FROM (
              SELECT 1 FROM {full("v_disease_metric_totals")} WHERE is_preferred_source
              GROUP BY disease_key, area_key, date_key, metric_name, coalesce(coverage_basis, '-')
              HAVING count(DISTINCT data_source_key) > 1)""")
        total = scalar(f"""SELECT count(*) FROM (SELECT DISTINCT disease_key, area_key, date_key, metric_name,
                                  coverage_basis FROM {full("v_disease_metric_totals")} WHERE is_preferred_source)""")
        rec(
            "G10",
            "fact_disease_metric",
            "v_disease_metric_totals",
            "One preferred source per disease series",
            "BUSINESS_RULE",
            fail_count=multi,
            total_count=total,
            threshold=0,
            detail="disease x area x period x metric x coverage cells with more than one preferred source",
        )
    except Exception as e:
        rec(
            "G10",
            "fact_disease_metric",
            "v_disease_metric_totals",
            "One preferred source per disease series",
            "BUSINESS_RULE",
            status="FAIL",
            detail=f"could not read the view: {str(e)[:300]}",
        )

    # ---------------------------------------------------------------- G09 views, marts and seeds
    if CHECK_VIEWS:
        for name in DERIVED:
            try:
                n = dq.capture_table_stats(full(name))
                rec(
                    "G09",
                    name,
                    name,
                    "View, mart or seed readable and not empty",
                    "COMPLETENESS",
                    status="PASS" if n > 0 else "FAIL",
                    observed=n,
                    expected="> 0",
                )
            except Exception as e:
                rec(
                    "G09",
                    name,
                    name,
                    "View, mart or seed readable and not empty",
                    "COMPLETENESS",
                    status="FAIL",
                    observed="error",
                    expected="> 0",
                    detail=str(e)[:400],
                )

print(f"Gold QC completed. Results: {DQ}.qc_results (layer = 'gold')")
