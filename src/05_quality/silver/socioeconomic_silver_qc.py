# Silver QC for the socioeconomic domain. Same approach as diseases_silver_qc.py: every result
# goes through dq_utils.DQRun into public_health.quality (qc_results, run_log, table_stats,
# profile), and the script raises at the end if any check is FAIL.
#
# When it runs
#   After the silver build files (socioeconomic_silver_00 ... 04), before gold.
#   The build files have their own gates, which stop a bad build. This script checks the
#   PUBLISHED tables and stores the results, including the review checks that are WARN and
#   therefore not gates.
#
# Tables checked
#   public_health.silver.socioeconomic_poverty_silver
#   public_health.silver.socioeconomic_health_expenditure_share_silver
#   public_health.silver.socioeconomic_health_expenditure_per_capita_silver
#   public_health.silver.socioeconomic_child_mortality_silver
#
# Identity in qc_results (lineage-qc-contract.md, section 8)
#   batch_id = build:<build_id> of the build that wrote the table being checked. A check about one
#   source puts the source in source_key. capture_table_stats records the table version checked.
#
# How to run
#   python socioeconomic_silver_qc.py
#   python socioeconomic_silver_qc.py --tables poverty,share
#   python socioeconomic_silver_qc.py --fail_on_error false
#
# Geography (S04, S93)
#   The PSGC codes of the poverty table are validated against public_health.silver.geography_silver,
#   the source of truth for PSGC codes and names. Columns used: psgc_code, area_name and
#   geographic_level (Reg / Prov / City / ..., null for the two placeholder rows).
#   A code that sits on a row with no level fails S93. If the table does not exist, S04 is
#   recorded as WARN "not validated", never as a pass.
#
# Check codes
#   S01-S12 are the shared silver codes in quality_registry_seed.sql (same names).
#   S80-S96 are socioeconomic codes (CHECKS below). They are in quality_registry_seed.sql. Run the
#   seed before switching DQRun to strict_registry=True.
#
# Severity policy (same as bronze and the other domains)
#   FAIL = the table is wrong, incomplete or cannot be traced.
#   WARN = the table is a faithful copy of the source, but something in it needs a person:
#          a value to verify, an open decision, or a definition not confirmed yet.
#
# Row dispositions: quality.row_disposition holds only the bronze rows that were
# NOT loaded, so S09 compares rows read (build_inputs.input_rows) with bronze, and the rows silver
# points to with rows read minus rows not loaded.

import argparse
import os
import sys

from pyspark.sql import SparkSession


# ----------------------------------------------------------------------------------
# Find dq_utils.py (same search as the other QC scripts)
# ----------------------------------------------------------------------------------
def _add_dq_utils_to_path():
    # Looks in this file's folder and the working directory, up to five levels above each, and in
    # any *quality* folder there (e.g. src/05_quality/). Works when __file__ is not set.
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
from dq_utils import DQRun  # noqa: E402

DOMAIN = "socioeconomic"
SCRIPT_NAME = "socioeconomic_silver_qc.py"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument(
        "--catalog", default="public_health", help="'' gives two-part names (local tests)"
    )
    p.add_argument(
        "--tables", default="ALL", help="ALL, or any of: poverty,share,per_capita,child_mortality"
    )
    p.add_argument(
        "--fail_on_error", default="true", help="false = record results but do not raise"
    )
    p.add_argument("--profile", default="true", help="Also write a column profile")
    p.add_argument(
        "--geography_table",
        default=None,
        help="Geography silver table. Default: <catalog>.silver.geography_silver",
    )
    p.add_argument("--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job")
    p.add_argument("--code_version", default=None)
    a, _ = p.parse_known_args()
    return a


ARGS = parse_args()
PREFIX = f"{ARGS.catalog}." if ARGS.catalog else ""
BRONZE, SILVER, QUALITY = f"{PREFIX}bronze", f"{PREFIX}silver", f"{PREFIX}quality"
POV = f"{SILVER}.socioeconomic_poverty_silver"
SHARE = f"{SILVER}.socioeconomic_health_expenditure_share_silver"
PCAP = f"{SILVER}.socioeconomic_health_expenditure_per_capita_silver"
MORT = f"{SILVER}.socioeconomic_child_mortality_silver"
AREA_MAP = f"{SILVER}.socioeconomic_poverty_area_map"

# Geography silver: source of truth for PSGC codes and names (one row per psgc_code).
GEOGRAPHY = ARGS.geography_table or f"{SILVER}.geography_silver"
GEO_CODE, GEO_LEVEL, GEO_NAME = "psgc_code", "geographic_level", "area_name"

POV_BRONZE = "socioeconomic_psa_poverty_bronze"
SHARE_BRONZE = "socioeconomic_psa_health_expenditure_share_bronze"
PCAP_BRONZE = "socioeconomic_psa_health_expenditure_per_capita_bronze"
MORT_BRONZE = "socioeconomic_psa_child_mortality_bronze"
POV_KEY, SHARE_KEY = "psa_poverty", "psa_health_expenditure_share_national_annual"
PCAP_KEY, MORT_KEY = "psa_health_expenditure_per_capita_national_annual", "psa_child_mortality"

spark = SparkSession.builder.getOrCreate()

# check_id -> (check_name, check_type, severity). One meaning per code; the name never changes.
CHECKS = {
    "S00": ("QC ran without error", "EXECUTION", "FAIL"),
    "S01": ("table exists and has rows", "COMPLETENESS", "FAIL"),
    "S02": ("grain key not null", "COMPLETENESS", "FAIL"),
    "S03": ("grain key unique", "UNIQUENESS", "FAIL"),
    "S04": ("PSGC code found in geography", "CONSISTENCY", "WARN"),
    "S07": ("rates within range", "VALIDITY", "WARN"),
    "S08": ("period within expected range", "VALIDITY", "FAIL"),
    "S09": ("bronze to silver rows reconcile", "RECONCILIATION", "FAIL"),
    "S10": ("metric totals preserved", "RECONCILIATION", "FAIL"),
    # socioeconomic codes
    "S80": ("lineage columns not null", "COMPLETENESS", "FAIL"),
    "S81": ("every lineage reference has one build input", "CONSISTENCY", "FAIL"),
    "S82": ("table written by one succeeded build", "CONSISTENCY", "FAIL"),
    "S83": (
        "silver built from the current bronze loads and reference tables",
        "CONSISTENCY",
        "FAIL",
    ),
    "S84": ("control values match", "RECONCILIATION", "FAIL"),
    "S85": ("build inputs carry a load id and file checksum", "COMPLETENESS", "WARN"),
    "S86": ("measure within its hard limits", "VALIDITY", "FAIL"),
    "S87": ("value agrees with its flag or status", "VALIDITY", "FAIL"),
    "S88": ("expected rows present, no others", "COMPLETENESS", "FAIL"),
    "S89": ("metric source columns complete and valid", "CONSISTENCY", "FAIL"),
    "S90": ("area attributes match the area map", "CONSISTENCY", "FAIL"),
    "S91": ("level-1 shares sum to the total", "RECONCILIATION", "FAIL"),
    "S92": ("financing agent hierarchy resolves", "CONSISTENCY", "FAIL"),
    "S93": ("PSGC code unique in geography, at the same level", "CONSISTENCY", "FAIL"),
    "S94": ("incidence fell by more than 15 points or reached zero", "CONSISTENCY", "WARN"),
    "S95": ("rows not eligible for comparison with PSGC-based data", "CONSISTENCY", "WARN"),
    "S96": ("definition not confirmed yet", "COMPLETENESS", "WARN"),
}

# Per table: bronze input, lineage columns that must never be null, the bronze row references a
# silver row carries (sheet expression, row number column), and the silver metric columns that
# must be keys of _metric_source_columns.
TABLES = {
    POV: {
        "bronze": POV_BRONZE,
        "source_key": POV_KEY,
        "lineage": [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_as_of_date",
            "_incidence_source_sheet",
            "_incidence_source_row_num",
            "_magnitude_source_sheet",
            "_magnitude_source_row_num",
            "_metric_source_columns",
        ],
        "refs": [
            ("_incidence_source_sheet", "_incidence_source_row_num"),
            ("_magnitude_source_sheet", "_magnitude_source_row_num"),
        ],
        "metrics": [
            "annual_per_capita_poverty_threshold_php",
            "poverty_incidence_pct",
            "incidence_cv_pct",
            "incidence_se_pp",
            "incidence_ci_low_pct",
            "incidence_ci_high_pct",
            "poor_population",
            "poor_population_cv_pct",
            "poor_population_se",
            "poor_population_ci_low",
            "poor_population_ci_high",
        ],
    },
    SHARE: {
        "bronze": SHARE_BRONZE,
        "source_key": SHARE_KEY,
        "lineage": [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_source_row_num",
            "_as_of_date",
            "_metric_source_columns",
        ],
        "refs": [("_source_sheet", "_source_row_num")],
        "metrics": ["share_pct"],
    },
    PCAP: {
        "bronze": PCAP_BRONZE,
        "source_key": PCAP_KEY,
        "lineage": [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_as_of_date",
            "_amount_source_row_num",
            "_growth_source_row_num",
            "_metric_source_columns",
        ],
        # the source is a CSV, so the table has no sheet column
        "refs": [
            ("CAST(NULL AS STRING)", "_amount_source_row_num"),
            ("CAST(NULL AS STRING)", "_growth_source_row_num"),
        ],
        "metrics": ["per_capita_health_expenditure_php", "growth_rate_pct"],
    },
    MORT: {
        "bronze": MORT_BRONZE,
        "source_key": MORT_KEY,
        "lineage": [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_source_row_num",
            "_as_of_date",
            "_metric_source_columns",
        ],
        "refs": [("_source_sheet", "_source_row_num")],
        "metrics": ["infant_mortality_rate", "child_mortality_rate", "under5_mortality_rate"],
    },
}

# Control values: the same numbers bronze QC checks (sources_socioeconomic.yaml), read from silver.
CONTROLS = {
    POV: [
        (
            "Philippines 2025 poverty incidence (percent)",
            f"SELECT max(poverty_incidence_pct) FROM {POV} WHERE area_key = 'ph' AND year = 2025",
            9.7,
        ),
        (
            "Philippines 2025 annual per capita poverty threshold (pesos)",
            f"SELECT max(annual_per_capita_poverty_threshold_php) FROM {POV} WHERE area_key = 'ph' AND year = 2025",
            35120.89,
        ),
        (
            "Philippines 2025 poor population (persons)",
            f"SELECT max(poor_population) FROM {POV} WHERE area_key = 'ph' AND year = 2025",
            11083030,
        ),
    ],
    SHARE: [
        (
            "Households share 2023 (percent)",
            f"SELECT max(share_pct) FROM {SHARE} WHERE financing_agent = 'Households' AND year = 2023",
            44.4,
        ),
        (
            "Households share 2016 (percent)",
            f"SELECT max(share_pct) FROM {SHARE} WHERE financing_agent = 'Households' AND year = 2016",
            50.5,
        ),
        (
            "Total current health expenditure 2023 (percent)",
            f"SELECT max(share_pct) FROM {SHARE} WHERE agent_level = 0 AND year = 2023",
            100.0,
        ),
    ],
    PCAP: [
        (
            "Per capita health expenditure 2023 (pesos)",
            f"SELECT max(per_capita_health_expenditure_php) FROM {PCAP} WHERE year = 2023",
            11082.68,
        ),
        (
            "Per capita health expenditure 2016 (pesos)",
            f"SELECT max(per_capita_health_expenditure_php) FROM {PCAP} WHERE year = 2016",
            5836.93,
        ),
    ],
    MORT: [
        (
            "NCR infant mortality rate, 2022 survey",
            f"SELECT max(infant_mortality_rate) FROM {MORT} WHERE characteristic = 'NCR' AND survey_year = 2022",
            8,
        ),
        (
            "BARMM under-five mortality rate, 2017 survey",
            f"SELECT max(under5_mortality_rate) FROM {MORT} WHERE characteristic = 'BARMM' AND survey_year = 2017",
            55,
        ),
    ],
}


# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------
def scalar(sql):
    return spark.sql(sql).collect()[0][0]


def same_number(a, b):
    if a is None or b is None:
        return a is None and b is None
    return abs(float(a) - float(b)) < 0.0005


def listing(sql, limit=15):
    """First rows of a query as one short text, for the detail column."""
    rows = spark.sql(sql).limit(limit).collect()
    return " | ".join(" ".join("" if v is None else str(v) for v in r) for r in rows) or None


def table_exists(name):
    try:
        spark.table(name).limit(0).collect()
        return True
    except Exception:
        return False


def bronze_number(col):
    # Bronze text to number: spaces and thousands separators removed. Null when it is not a number.
    return f"try_cast(regexp_replace(trim(`{col}`), '[ ,]', '') AS DECIMAL(20,4))"


class TableQC:
    """Checks for one silver table. Every result carries build:<build_id> of the table's build."""

    def __init__(self, dq, table):
        self.dq, self.table, self.cfg = dq, table, TABLES[table]
        ids = [r[0] for r in spark.sql(f"SELECT DISTINCT _silver_build_id FROM {table}").collect()]
        self.build_ids = ids
        self.build_id = ids[0] if len(ids) == 1 else None
        self.batch = f"build:{self.build_id}" if self.build_id else None
        self.total_sql = f"SELECT count(*) FROM {table}"
        # every bronze row reference of the table, one row per silver row and side
        self.refs_sql = " UNION ALL ".join(
            f"SELECT _silver_build_id, _source_key, _source_file, {sheet} AS source_sheet, {rownum} AS source_row_num "
            f"FROM {table}"
            for sheet, rownum in self.cfg["refs"]
        )

    def _rec(self, check_id, **kw):
        name, ctype, severity = CHECKS[check_id]
        kw.setdefault("source_key", self.cfg["source_key"])
        return self.dq.record(
            check_id,
            table_name=self.table,
            batch_id=self.batch,
            check_name=name,
            check_type=ctype,
            severity=severity,
            **kw,
        )

    def count(self, check_id, fail_sql, total_sql=None, **kw):
        """A check that counts failing rows (or groups). PASS when the count is 0."""
        fail = scalar(fail_sql) or 0
        total = scalar(total_sql) if total_sql else None
        return self._rec(check_id, fail_count=fail, total_count=total, **kw)

    def value(self, check_id, observed, expected, ok=None, **kw):
        """A check that compares one observed value with an expected one."""
        ok = same_number(observed, expected) if ok is None else ok
        return self._rec(
            check_id,
            status="PASS" if ok else CHECKS[check_id][2],
            observed=observed,
            expected=expected,
            **kw,
        )

    # ---- checks shared by the four tables ----------------------------------------
    def basics(self, key):
        total = self.dq.capture_table_stats(self.table)
        self.value("S01", total, "> 0", ok=total > 0)
        self.count(
            "S02",
            f"SELECT count(*) FROM {self.table} WHERE " + " OR ".join(f"{c} IS NULL" for c in key),
            self.total_sql,
            column_name=", ".join(key),
        )
        self.count(
            "S03",
            f"""SELECT count(*) FROM (SELECT 1 FROM {self.table}
                                                    GROUP BY {", ".join(key)} HAVING count(*) > 1)""",
            self.total_sql,
            column_name=", ".join(key),
        )
        return total

    def build_record(self):
        """S82: one build id in the table, and that build is in build_log as succeeded with the same row count."""
        if self.build_id is None:
            self.value("S82", f"{len(self.build_ids)} build ids in the table", "1", ok=False)
            return
        rows = spark.sql(f"""SELECT status, row_count FROM {QUALITY}.build_log
                             WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'""").collect()
        n = scalar(self.total_sql)
        ok = len(rows) == 1 and rows[0]["status"] == "succeeded" and rows[0]["row_count"] == n
        self.value(
            "S82",
            f"{len(rows)} build_log row(s)"
            + (f", {rows[0]['status']}, {rows[0]['row_count']} rows" if rows else ""),
            f"1 row, succeeded, {n} rows",
            ok=ok,
        )

    def lineage(self):
        cols = self.cfg["lineage"]
        self.count(
            "S80",
            f"SELECT count(*) FROM {self.table} WHERE " + " OR ".join(f"{c} IS NULL" for c in cols),
            self.total_sql,
            column_name=", ".join(cols),
        )
        # S81: every (source, file, sheet) the rows point to has exactly one row in build_inputs.
        self.count(
            "S81",
            f"""
            SELECT count(*) FROM (
              SELECT s._source_key, s._source_file, s.source_sheet, count(v.build_id) AS n
              FROM (SELECT DISTINCT _silver_build_id, _source_key, _source_file, source_sheet FROM ({self.refs_sql})) s
              LEFT JOIN {QUALITY}.v_build_lineage v
                ON v.build_id = s._silver_build_id AND v.target_table = '{self.table}'
               AND v.source_key = s._source_key AND v.source_file = s._source_file AND v.source_sheet <=> s.source_sheet
              GROUP BY s._source_key, s._source_file, s.source_sheet) WHERE n <> 1""",
            f"SELECT count(*) FROM (SELECT DISTINCT _source_key, _source_file, source_sheet FROM ({self.refs_sql}))",
            detail="files or sheets referenced by silver rows without exactly one build_inputs row",
        )

    def metric_source_columns(self):
        """S89: _metric_source_columns has exactly the table's metric columns as keys, and every
        value is a column of the bronze table."""
        wanted = ", ".join(f"'{m}'" for m in self.cfg["metrics"])
        bronze_cols = ", ".join(
            f"'{c}'" for c in spark.table(f"{BRONZE}.{self.cfg['bronze']}").columns
        )
        self.count(
            "S89",
            f"""
            SELECT count(*) FROM {self.table}
            WHERE NOT (sort_array(map_keys(_metric_source_columns)) <=> sort_array(array({wanted})))
               OR exists(map_values(_metric_source_columns), v -> v IS NULL OR v NOT IN ({bronze_cols}))""",
            self.total_sql,
            column_name="_metric_source_columns",
            detail=f"expected keys: {', '.join(self.cfg['metrics'])}"[:500],
        )

    def build_inputs(self):
        """S85: each bronze input of the build has its load id and file checksum. They are null when
        the build ran with strict_load_lookup = false and the ingestion log had no matching row."""
        self.count(
            "S85",
            f"""SELECT count(*) FROM {QUALITY}.build_inputs
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND input_kind = 'bronze_source'
                                AND (load_batch_id IS NULL OR content_checksum IS NULL)""",
            f"""SELECT count(*) FROM {QUALITY}.build_inputs
                       WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                         AND input_kind = 'bronze_source'""",
            detail="inputs without a load id or checksum: clear bronze B13, then rebuild with strict_load_lookup = true",
        )

    def freshness(self):
        """S83: the files, sheets and load times in bronze now are the ones the build read.
        A new file, a removed file or a reload all count as a mismatch: rebuild silver."""
        bronze, source_key = f"{BRONZE}.{self.cfg['bronze']}", self.cfg["source_key"]
        mismatches = scalar(f"""
            WITH now_in_bronze AS (
              SELECT DISTINCT _source_file AS f, _source_sheet AS s, _ingested_at AS t
              FROM {bronze} WHERE _source_key = '{source_key}'),
            consumed AS (
              SELECT source_file AS f, source_sheet AS s, ingested_at AS t
              FROM {QUALITY}.build_inputs
              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                AND input_kind = 'bronze_source' AND source_key = '{source_key}')
            SELECT (SELECT count(*) FROM now_in_bronze b LEFT ANTI JOIN consumed c
                      ON c.f = b.f AND c.s <=> b.s AND c.t = b.t)
                 + (SELECT count(*) FROM consumed c LEFT ANTI JOIN now_in_bronze b
                      ON c.f = b.f AND c.s <=> b.s AND c.t = b.t)""")
        consumed = scalar(f"""SELECT count(*) FROM {QUALITY}.build_inputs
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND input_kind = 'bronze_source' AND source_key = '{source_key}'""")
        self._rec(
            "S83",
            fail_count=mismatches + (1 if consumed == 0 else 0),
            total_count=max(consumed, 1),
            detail=None
            if (mismatches == 0 and consumed > 0)
            else "bronze has a new, removed or reloaded file or sheet since the build: rebuild silver",
        )

    def reference_freshness(self, ref_table):
        """S83 for a reference table the build read (poverty: the area map): same row count as the
        build recorded and, where Delta versions are recorded, the same version."""
        rec = spark.sql(f"""SELECT input_rows, input_table_version FROM {QUALITY}.build_inputs
                            WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                              AND input_kind <> 'bronze_source' AND input_table = '{ref_table}'""").collect()
        rows_now = scalar(f"SELECT count(*) FROM {ref_table}")
        version_now = None
        try:
            version_now = spark.sql(f"DESCRIBE HISTORY {ref_table} LIMIT 1").collect()[0]["version"]
        except Exception:
            pass  # not a Delta table (local tests)
        ok = (
            len(rec) == 1
            and rec[0]["input_rows"] == rows_now
            and (
                rec[0]["input_table_version"] is None
                or version_now is None
                or rec[0]["input_table_version"] == version_now
            )
        )
        self.value(
            "S83",
            f"{rows_now} rows, version {version_now}",
            (
                f"{rec[0]['input_rows']} rows, version {rec[0]['input_table_version']}"
                if rec
                else "one build_inputs row for the reference table"
            ),
            ok=ok,
            source_key=None,
            column_name=ref_table,
            detail=None if ok else "the reference table changed since the build: rebuild silver",
        )

    def reconcile(self):
        """S09. row_disposition holds only the rows that were NOT loaded, so:
        rows the build read (build_inputs.input_rows) = bronze rows now
        rows silver points to                         = rows read - rows not loaded"""
        bronze, source_key = f"{BRONZE}.{self.cfg['bronze']}", self.cfg["source_key"]
        bronze_rows = scalar(f"SELECT count(*) FROM {bronze} WHERE _source_key = '{source_key}'")
        read = scalar(f"""SELECT coalesce(sum(input_rows), 0) FROM {QUALITY}.build_inputs
                          WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                            AND input_kind = 'bronze_source' AND source_key = '{source_key}'""")
        d = spark.sql(f"""SELECT count_if(disposition <> 'loaded') AS not_loaded,
                                 count_if(disposition = 'dropped_non_data') AS dropped,
                                 count_if(disposition NOT IN ('loaded', 'dropped_non_data')) AS other
                          FROM {QUALITY}.row_disposition
                          WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                            AND source_key = '{source_key}'""").collect()[0]
        referenced = scalar(f"""SELECT count(*) FROM (SELECT DISTINCT _source_file, source_sheet, source_row_num
                                                      FROM ({self.refs_sql}))""")
        loaded = read - d["not_loaded"]
        reasons = listing(f"""SELECT concat(coalesce(reason, 'no reason'), ' ', count(*)) FROM {QUALITY}.row_disposition
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND source_key = '{source_key}' GROUP BY reason ORDER BY reason""")
        # the socioeconomic builds only drop non-data rows; any other disposition is not expected
        ok = (read == bronze_rows) and (referenced == loaded) and d["other"] == 0
        self.value(
            "S09",
            f"rows read {read}, silver references {referenced}",
            f"bronze rows {bronze_rows}, loaded {loaded}",
            ok=ok,
            detail=f"loaded {loaded}, dropped {d['dropped']} ({reasons}), other dispositions {d['other']}",
        )

    def controls(self):
        for label, sql, expected in CONTROLS[self.table]:
            self.value("S84", scalar(sql), expected, detail=label)

    def common(self, key):
        self.basics(key)
        self.build_record()
        self.lineage()
        self.metric_source_columns()
        if self.build_id:
            self.build_inputs()
            self.freshness()
            self.reconcile()
        self.controls()


# ----------------------------------------------------------------------------------
# socioeconomic_poverty_silver
# ----------------------------------------------------------------------------------
def check_poverty(dq, profile):
    t = TableQC(dq, POV)
    total_sql = t.total_sql
    t.common(["area_key", "year"])
    if t.build_id:
        t.reference_freshness(AREA_MAP)

    t.count(
        "S08",
        f"SELECT count(*) FROM {POV} WHERE year NOT IN (2021, 2023, 2025)",
        total_sql,
        column_name="year",
    )

    # S88: exactly the area-years the area map expects (an area starts at its first_estimate_year)
    t.count(
        "S88",
        f"""
        WITH expected AS (
          SELECT m.area_key, y.year FROM {AREA_MAP} m
          CROSS JOIN (SELECT explode(array(2021, 2023, 2025)) AS year) y
          WHERE y.year >= try_cast(m.first_estimate_year AS INT))
        SELECT (SELECT count(*) FROM expected e LEFT ANTI JOIN {POV} s ON s.area_key = e.area_key AND s.year = e.year)
             + (SELECT count(*) FROM {POV} s LEFT ANTI JOIN expected e ON s.area_key = e.area_key AND s.year = e.year)""",
        f"""SELECT count(*) FROM {AREA_MAP} m CROSS JOIN (SELECT explode(array(2021, 2023, 2025)) AS year) y
                WHERE y.year >= try_cast(m.first_estimate_year AS INT)""",
        column_name="area_key, year",
        detail="area-years missing from silver, or in silver but not expected",
    )

    # S10: sums in silver equal the same sums taken from bronze (footnote rows hold no numbers)
    for sheet, silver_col, bronze_expr, label in [
        (
            "tab2",
            "poverty_incidence_pct",
            " + ".join(
                f"coalesce(sum({bronze_number(f'incidence_{y}')}), 0)" for y in (2021, 2023, 2025)
            ),
            "incidence_2021 + incidence_2023 + incidence_2025",
        ),
        (
            "tab6",
            "poor_population",
            " + ".join(
                f"coalesce(sum(round({bronze_number(f'poor_pop_{y}')} * 1000)), 0)"
                for y in (2021, 2023, 2025)
            ),
            "poor_pop_2021 + poor_pop_2023 + poor_pop_2025, times 1,000",
        ),
    ]:
        s = scalar(f"SELECT sum({silver_col}) FROM {POV}")
        b = scalar(f"""SELECT {bronze_expr} FROM {BRONZE}.{POV_BRONZE}
                       WHERE _source_key = '{POV_KEY}' AND _source_sheet = '{sheet}'""")
        t.value("S10", s, b, column_name=f"{silver_col} (bronze {sheet}: {label})")

    # S86: hard limits. CV has no upper limit and a poor population of zero is allowed.
    t.count(
        "S86",
        f"""
        SELECT count(*) FROM {POV}
        WHERE poverty_incidence_pct < 0 OR poverty_incidence_pct > 100
           OR annual_per_capita_poverty_threshold_php <= 0
           OR incidence_cv_pct < 0 OR incidence_se_pp < 0
           OR poor_population < 0 OR poor_population_cv_pct < 0 OR poor_population_se < 0""",
        total_sql,
        column_name="poverty_incidence_pct, annual_per_capita_poverty_threshold_php, poor_population, cv, se",
    )
    # S07: confidence limits around the estimate
    t.count(
        "S07",
        f"""
        SELECT count(*) FROM {POV}
        WHERE NOT (incidence_ci_low_pct <= poverty_incidence_pct AND poverty_incidence_pct <= incidence_ci_high_pct)
           OR incidence_ci_low_pct < 0
           OR NOT (poor_population_ci_low <= poor_population AND poor_population <= poor_population_ci_high)
           OR poor_population_ci_low < 0""",
        total_sql,
        column_name="incidence and poor population confidence limits",
        detail=listing(f"""SELECT concat(geo_name_source, ' ', year) FROM {POV}
                               WHERE NOT (incidence_ci_low_pct <= poverty_incidence_pct AND poverty_incidence_pct <= incidence_ci_high_pct)
                                  OR incidence_ci_low_pct < 0
                                  OR NOT (poor_population_ci_low <= poor_population AND poor_population <= poor_population_ci_high)
                                  OR poor_population_ci_low < 0 ORDER BY 1"""),
    )
    # S87: the three main measures are never null; a below-threshold flag goes with a zero;
    #      precision is 'unknown' exactly where the CV is not available.
    t.count(
        "S87",
        f"""
        SELECT count(*) FROM {POV}
        WHERE poverty_incidence_pct IS NULL OR annual_per_capita_poverty_threshold_php IS NULL OR poor_population IS NULL
           OR is_incidence_below_0_05 IS NULL OR is_poor_population_below_50 IS NULL
           OR (is_incidence_below_0_05 AND poverty_incidence_pct <> 0)
           OR (is_poor_population_below_50 AND poor_population <> 0)
           OR (poverty_incidence_pct = 0 AND coalesce(incidence_source_notes, '') RLIKE '(^|[ ,])c/' AND NOT is_incidence_below_0_05)
           OR (incidence_cv_pct IS NULL) <> (incidence_precision = 'unknown')
           OR (poor_population_cv_pct IS NULL) <> (poor_population_precision = 'unknown')
           OR incidence_precision NOT IN ('ok', 'use_with_caution', 'unknown')
           OR poor_population_precision NOT IN ('ok', 'use_with_caution', 'unknown')
           OR (incidence_precision = 'use_with_caution') <> coalesce(incidence_cv_pct > 10, false)
           OR (poor_population_precision = 'use_with_caution') <> coalesce(poor_population_cv_pct > 10, false)
           OR poverty_population_basis <> 'population' OR reporting_period <> 'full_year'""",
        total_sql,
        column_name="measures, below-threshold flags, precision, basis",
    )

    # S90: the area columns are the ones of the area map, and a superseded or coverage-unconfirmed
    #      area is never marked comparison-eligible without the map saying so.
    t.count(
        "S90",
        f"""
        SELECT (SELECT count(*) FROM {POV} s LEFT ANTI JOIN {AREA_MAP} m ON m.area_key = s.area_key)
             + (SELECT count(*) FROM {POV} s JOIN {AREA_MAP} m ON m.area_key = s.area_key
                WHERE NOT (s.geo_level <=> m.geo_level) OR NOT (s.psgc_code <=> m.psgc_code)
                   OR NOT (s.geo_name_source <=> m.geo_name_source)
                   OR NOT (s.geo_coverage_basis <=> m.geo_coverage_basis)
                   OR NOT (s.comparison_eligible <=> CAST(m.comparison_eligible AS BOOLEAN))
                   OR NOT (s.exclusion_reason <=> m.exclusion_reason))
             + (SELECT count(*) FROM {POV}
                WHERE (is_superseded_area AND comparison_eligible)
                   OR (comparison_eligible AND exclusion_reason IS NOT NULL)
                   OR (NOT comparison_eligible AND exclusion_reason IS NULL)
                   OR NOT area_key RLIKE '^(psgc:[0-9]{{10}}|ph|ncr-district:[0-9]|hist:[a-z_]+)$'
                   OR (psgc_code IS NOT NULL AND area_key <> concat('psgc:', psgc_code)))""",
        total_sql,
        column_name="area_key, geo_level, psgc_code, comparison_eligible, exclusion_reason",
    )

    check_poverty_geography(t)

    # ---- WARN: the table is a faithful copy; a person needs to look ---------------------------
    # S94 (decision D4): a fall of more than 15 points between two releases, or an incidence of zero
    fell = f"""
        SELECT geo_name_source, year, previous_pct, poverty_incidence_pct FROM (
          SELECT geo_name_source, year, poverty_incidence_pct,
                 lag(poverty_incidence_pct) OVER (PARTITION BY area_key ORDER BY year) AS previous_pct
          FROM {POV})
        WHERE poverty_incidence_pct = 0 OR previous_pct - poverty_incidence_pct > 15"""
    t.count(
        "S94",
        f"SELECT count(*) FROM ({fell})",
        total_sql,
        column_name="poverty_incidence_pct",
        detail=listing(f"""SELECT concat(geo_name_source, ' ', year, ': ', coalesce(cast(previous_pct AS STRING), 'n/a'),
                                             ' to ', poverty_incidence_pct) FROM ({fell}) ORDER BY 1"""),
    )
    # S95 (decision D2): rows that must not be compared with PSGC-based population or facilities as is
    t.count(
        "S95",
        f"SELECT count(DISTINCT area_key) FROM {POV} WHERE NOT comparison_eligible",
        f"SELECT count(DISTINCT area_key) FROM {POV}",
        column_name="comparison_eligible",
        detail=listing(f"""SELECT concat(exclusion_reason, ' ', count(DISTINCT area_key)) FROM {POV}
                               WHERE NOT comparison_eligible GROUP BY exclusion_reason ORDER BY 1"""),
    )

    if profile:
        dq.profile_table(POV, exclude=("_silver_build_id",))


def check_poverty_geography(t):
    """S04 and S93: every PSGC code of the poverty table exists once in the geography silver table,
    at the same level. A code on a geography row with no level (a placeholder row) fails S93.
    Validation only: nothing is taken from geography."""
    coded = f"SELECT DISTINCT area_key, geo_name_source, geo_level, psgc_code FROM {POV} WHERE psgc_code IS NOT NULL"
    coded_n = f"SELECT count(*) FROM ({coded})"
    if not table_exists(GEOGRAPHY):
        t._rec(
            "S04",
            status="WARN",
            source_key=None,
            column_name="psgc_code",
            total_count=scalar(coded_n),
            observed="not validated",
            expected=f"{GEOGRAPHY} exists",
            detail="geography silver not available: PSGC codes of the poverty table are NOT validated yet",
        )
        return
    geo = f"""SELECT lpad(trim({GEO_CODE}), 10, '0') AS psgc_code, {GEO_NAME} AS geo_name,
                     CASE lower(trim({GEO_LEVEL})) WHEN 'reg' THEN 'region' WHEN 'prov' THEN 'province'
                          ELSE lower(trim({GEO_LEVEL})) END AS geo_level
              FROM {GEOGRAPHY}
              WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at) FROM {GEOGRAPHY})"""
    missing = f"SELECT m.* FROM ({coded}) m LEFT ANTI JOIN ({geo}) g ON g.psgc_code = m.psgc_code"
    t.count(
        "S04",
        f"SELECT count(*) FROM ({missing})",
        coded_n,
        source_key=None,
        column_name="psgc_code",
        detail=listing(
            f"SELECT concat(geo_name_source, ' ', psgc_code) FROM ({missing}) ORDER BY 1"
        ),
    )
    wrong = f"""
        SELECT m.geo_name_source, m.psgc_code, m.geo_level, g.geo_level AS geography_level, g.n
        FROM ({coded}) m
        JOIN (SELECT psgc_code, count(*) AS n, max(geo_level) AS geo_level, count(DISTINCT geo_level) AS levels
              FROM ({geo}) GROUP BY psgc_code) g ON g.psgc_code = m.psgc_code
        WHERE g.n > 1 OR g.levels > 1 OR g.geo_level IS NULL OR g.geo_level <> m.geo_level"""
    t.count(
        "S93",
        f"SELECT count(*) FROM ({wrong})",
        coded_n,
        source_key=None,
        column_name="psgc_code, geo_level",
        detail=listing(f"""SELECT concat(geo_name_source, ' ', psgc_code, ': ', geo_level, ' vs ',
                                             coalesce(geography_level, 'no level'), ', ', n, ' row(s)')
                               FROM ({wrong}) ORDER BY 1"""),
    )


# ----------------------------------------------------------------------------------
# socioeconomic_health_expenditure_share_silver
# ----------------------------------------------------------------------------------
def check_share(dq, profile):
    t = TableQC(dq, SHARE)
    total_sql = t.total_sql
    t.common(["financing_agent", "year"])
    t.count(
        "S08",
        f"SELECT count(*) FROM {SHARE} WHERE year NOT BETWEEN 2016 AND 2023",
        total_sql,
        column_name="year",
    )
    # S88: 16 agents, each with the 8 years
    t.count(
        "S88",
        f"""
        SELECT abs((SELECT count(DISTINCT financing_agent) FROM {SHARE}) - 16)
             + (SELECT count(*) FROM (SELECT financing_agent FROM {SHARE} GROUP BY financing_agent
                                      HAVING count(DISTINCT year) <> 8 OR count(*) <> 8))""",
        "SELECT 16",
        column_name="financing_agent, year",
        detail="expected 16 agents x 8 years = 128 rows",
    )
    s = scalar(f"SELECT sum(share_pct) FROM {SHARE}")
    b = scalar(
        "SELECT "
        + " + ".join(f"coalesce(sum({bronze_number(f'share_{y}')}), 0)" for y in range(2016, 2024))
        + f" FROM {BRONZE}.{SHARE_BRONZE} WHERE _source_key = '{SHARE_KEY}'"
    )
    t.value(
        "S10", s, b, column_name="share_pct (bronze share_2016 ... share_2023, a/ counted as 0)"
    )
    t.count(
        "S86",
        f"SELECT count(*) FROM {SHARE} WHERE share_pct < 0 OR share_pct > 100",
        total_sql,
        column_name="share_pct",
    )
    t.count(
        "S87",
        f"""SELECT count(*) FROM {SHARE}
                       WHERE share_pct IS NULL OR is_below_0_05 IS NULL OR (is_below_0_05 AND share_pct <> 0)""",
        total_sql,
        column_name="share_pct, is_below_0_05",
    )
    # S91: only level-1 agents add up to the total (rounded to one decimal in the source)
    t.count(
        "S91",
        f"""
        SELECT count(*) FROM (
          SELECT year, sum(CASE WHEN agent_level = 1 THEN share_pct END) AS level_1,
                 max(CASE WHEN agent_level = 0 THEN share_pct END) AS total
          FROM {SHARE} GROUP BY year)
        WHERE NOT (total <=> 100) OR NOT (abs(level_1 - total) <= 0.2)""",
        f"SELECT count(DISTINCT year) FROM {SHARE}",
        column_name="share_pct",
        detail=listing(f"""SELECT concat(year, ' ', sum(CASE WHEN agent_level = 1 THEN share_pct END))
                               FROM {SHARE} GROUP BY year ORDER BY year"""),
    )
    # S92: one total, every other agent has a parent in the table one level above it
    t.count(
        "S92",
        f"""
        WITH a AS (SELECT DISTINCT financing_agent, parent_agent, agent_level FROM {SHARE})
        SELECT abs((SELECT count(*) FROM a WHERE agent_level = 0) - 1)
             + (SELECT count(*) FROM a WHERE agent_level NOT IN (0, 1, 2, 3)
                   OR (agent_level = 0) <> (parent_agent IS NULL))
             + (SELECT count(*) FROM a c LEFT JOIN a p ON p.financing_agent = c.parent_agent
                WHERE c.agent_level > 0 AND NOT (p.agent_level <=> c.agent_level - 1))""",
        f"SELECT count(DISTINCT financing_agent) FROM {SHARE}",
        column_name="financing_agent, parent_agent, agent_level",
    )
    if profile:
        dq.profile_table(SHARE, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# socioeconomic_health_expenditure_per_capita_silver
# ----------------------------------------------------------------------------------
def check_per_capita(dq, profile):
    t = TableQC(dq, PCAP)
    total_sql = t.total_sql
    t.common(["year"])
    t.count(
        "S08",
        f"SELECT count(*) FROM {PCAP} WHERE year NOT BETWEEN 2016 AND 2023",
        total_sql,
        column_name="year",
    )
    n = spark.sql(
        f"SELECT count(*) AS n, count(DISTINCT year) AS d, min(year) AS lo, max(year) AS hi FROM {PCAP}"
    ).collect()[0]
    t.value(
        "S88",
        f"{n['n']} rows, {n['d']} years, {n['lo']} to {n['hi']}",
        "8 rows, 8 years, 2016 to 2023",
        ok=(n["n"], n["d"], n["lo"], n["hi"]) == (8, 8, 2016, 2023),
        column_name="year",
    )
    t.count(
        "S86",
        f"SELECT count(*) FROM {PCAP} WHERE per_capita_health_expenditure_php <= 0",
        total_sql,
        column_name="per_capita_health_expenditure_php",
    )
    # S87: both measures present; the growth period under a year is the growth into that year
    t.count(
        "S87",
        f"""
        SELECT count(*) FROM {PCAP}
        WHERE per_capita_health_expenditure_php IS NULL OR growth_rate_pct IS NULL OR is_revised IS NULL
           OR NOT (growth_period <=> concat(CAST(year - 1 AS STRING), '-', right(CAST(year AS STRING), 2)))""",
        total_sql,
        column_name="per_capita_health_expenditure_php, growth_rate_pct, growth_period",
    )
    # S07: a negative growth rate is valid; a very large change in either direction is worth a look
    t.count(
        "S07",
        f"SELECT count(*) FROM {PCAP} WHERE growth_rate_pct NOT BETWEEN -50 AND 50",
        total_sql,
        column_name="growth_rate_pct",
        detail="growth outside -50 to 50 percent",
    )
    if profile:
        dq.profile_table(PCAP, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# socioeconomic_child_mortality_silver
# ----------------------------------------------------------------------------------
def check_child_mortality(dq, profile):
    t = TableQC(dq, MORT)
    total_sql = t.total_sql
    rates = ["infant_mortality_rate", "child_mortality_rate", "under5_mortality_rate"]
    reliab = [
        "infant_mortality_reliability",
        "child_mortality_reliability",
        "under5_mortality_reliability",
    ]
    t.common(["characteristic_group", "characteristic", "survey_year"])
    t.count(
        "S08",
        f"SELECT count(*) FROM {MORT} WHERE survey_year NOT IN (2017, 2022)",
        total_sql,
        column_name="survey_year",
    )
    # S88: 30 characteristics (17 regions, 2 residence, 6 education, 5 wealth), each in both surveys
    g = {
        r["characteristic_group"]: r["n"]
        for r in spark.sql(
            f"SELECT characteristic_group, count(DISTINCT characteristic) AS n FROM {MORT} GROUP BY 1"
        ).collect()
    }
    expected_groups = {"Region": 17, "Residence": 2, "Mother's Education": 6, "Wealth quintile": 5}
    incomplete = scalar(f"""SELECT count(*) FROM (SELECT 1 FROM {MORT} GROUP BY characteristic_group, characteristic
                                                  HAVING count(DISTINCT survey_year) <> 2 OR count(*) <> 2)""")
    t.value(
        "S88",
        ", ".join(f"{k} {v}" for k, v in sorted(g.items()))
        + f", {incomplete} without both surveys",
        ", ".join(f"{k} {v}" for k, v in sorted(expected_groups.items()))
        + ", 0 without both surveys",
        ok=g == expected_groups and incomplete == 0,
        column_name="characteristic_group, characteristic, survey_year",
    )
    s = scalar(f"SELECT sum({' + '.join(f'coalesce({c}, 0)' for c in rates)}) FROM {MORT}")
    b = scalar(
        "SELECT "
        + " + ".join(
            f"coalesce(sum(try_cast(regexp_extract(trim(`{c}`), '^[(]?([0-9]+)[)]?$', 1) AS INT)), 0)"
            for c in [f"{m}_{y}" for m in ("imr", "cmr", "u5mr") for y in (2017, 2022)]
        )
        + f" FROM {BRONZE}.{MORT_BRONZE} WHERE _source_key = '{MORT_KEY}'"
    )
    t.value("S10", s, b, column_name="three rates, both surveys (bronze imr / cmr / u5mr columns)")
    t.count(
        "S86",
        f"SELECT count(*) FROM {MORT} WHERE " + " OR ".join(f"{c} < 0" for c in rates),
        total_sql,
        column_name=", ".join(rates),
    )
    # S87: a rate is null exactly when it is suppressed; reliability has one of three values
    t.count(
        "S87",
        f"SELECT count(*) FROM {MORT} WHERE "
        + " OR ".join(
            f"({r} IS NULL) <> ({q} = 'suppressed') OR {q} IS NULL OR {q} NOT IN ('ok', 'low_precision', 'suppressed')"
            for r, q in zip(rates, reliab, strict=True)
        ),
        total_sql,
        column_name=", ".join(reliab),
        detail=listing(f"""SELECT concat('suppressed rates: ',
                                 count_if(infant_mortality_reliability = 'suppressed') + count_if(child_mortality_reliability = 'suppressed')
                                 + count_if(under5_mortality_reliability = 'suppressed'), ', low precision: ',
                                 count_if(infant_mortality_reliability = 'low_precision') + count_if(child_mortality_reliability = 'low_precision')
                                 + count_if(under5_mortality_reliability = 'low_precision')) FROM {MORT}"""),
    )
    # S07: under-five mortality covers infant mortality, so it should not be lower
    t.count(
        "S07",
        f"SELECT count(*) FROM {MORT} WHERE under5_mortality_rate < infant_mortality_rate",
        total_sql,
        column_name="under5_mortality_rate, infant_mortality_rate",
        detail=listing(f"""SELECT concat(characteristic, ' ', survey_year) FROM {MORT}
                               WHERE under5_mortality_rate < infant_mortality_rate ORDER BY 1"""),
    )
    # S96 (decision D7): the window before the survey that the rates cover is not confirmed
    t.count(
        "S96",
        f"SELECT count(*) FROM {MORT} WHERE reference_period IS NULL",
        total_sql,
        column_name="reference_period",
        detail="reference period of the rates is not confirmed: do not state one on the dashboard",
    )
    if profile:
        dq.profile_table(MORT, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------
TABLE_CHECKS = {
    "poverty": (POV, check_poverty),
    "share": (SHARE, check_share),
    "per_capita": (PCAP, check_per_capita),
    "child_mortality": (MORT, check_child_mortality),
}


def main():
    wanted = (
        list(TABLE_CHECKS)
        if ARGS.tables.strip().upper() == "ALL"
        else [t.strip() for t in ARGS.tables.split(",") if t.strip()]
    )
    unknown = [t for t in wanted if t not in TABLE_CHECKS]
    if unknown:
        raise KeyError(f"Unknown table(s) {unknown}. Choose from {list(TABLE_CHECKS)}")

    # DQRun writes qc_results, table_stats, profile and run_log on exit, then raises if any FAIL.
    with DQRun(
        layer="silver",
        domain=DOMAIN,
        script_name=SCRIPT_NAME,
        job_run_id=ARGS.job_run_id,
        source_keys=ARGS.tables,
        fail_on_error=ARGS.fail_on_error == "true",
        code_version=ARGS.code_version,
        dq_schema=QUALITY,
    ) as dq:
        for name in wanted:
            table, fn = TABLE_CHECKS[name]
            print(f"[{name}] {table}")
            try:
                fn(dq, ARGS.profile == "true")
            except Exception as e:
                # One table erroring is recorded as a failed check; the others still run.
                cname, ctype, severity = CHECKS["S00"]
                dq.record(
                    "S00",
                    table_name=table,
                    status="FAIL",
                    check_name=cname,
                    check_type=ctype,
                    severity=severity,
                    detail=f"{type(e).__name__}: {e}",
                )


if __name__ == "__main__":
    main()
