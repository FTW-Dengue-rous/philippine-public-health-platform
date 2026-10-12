# Silver QC for the workforce domain. Same approach as diseases_silver_qc.py: every result goes
# through dq_utils.DQRun into public_health.quality (qc_results, run_log, table_stats, profile,
# quarantine), and the script raises at the end if any check is FAIL.
#
# When it runs
#   After the silver build files (workforce_silver_00 ... 04), before gold. The build files have their own gates, which stop a bad
#   build. This script checks the PUBLISHED tables and stores the results, including the
#   reconciliation and review checks that are WARN and therefore not gates.
#
# Tables checked
#   public_health.silver.workforce_headcount_silver
#   public_health.silver.workforce_area_denominator_silver
#   public_health.silver.workforce_specialist_silver
#
# Identity in qc_results
#   batch_id = build:<build_id> of the build that wrote the table being checked. A check about one
#   source puts the source in source_key. capture_table_stats records the table version checked.
#
# How to run
#   python workforce_silver_qc.py
#   python workforce_silver_qc.py --tables headcount,denominator
#   python workforce_silver_qc.py --fail_on_error false
#
# Check codes
#   S01-S12 are the shared silver codes in quality_registry_seed.sql (same names).
#   S60-S79 are workforce codes (CHECKS below). Add them to the registry seed before switching
#   DQRun to strict_registry=True.
#
# Severity policy (same as bronze and diseases)
#   FAIL = the table is wrong, incomplete or cannot be traced.
#   WARN = the table is a faithful copy of the sources, but the sources disagree or have gaps
#          a person should look at

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

DOMAIN = "workforce"
SCRIPT_NAME = "workforce_silver_qc.py"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument(
        "--catalog", default="public_health", help="'' gives two-part names (local tests)"
    )
    p.add_argument(
        "--tables", default="ALL", help="ALL, or any of: headcount,denominator,specialist"
    )
    p.add_argument(
        "--fail_on_error", default="true", help="false = record results but do not raise"
    )
    p.add_argument("--profile", default="true", help="Also write a column profile")
    p.add_argument("--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job")
    p.add_argument("--code_version", default=None)
    a, _ = p.parse_known_args()
    return a


ARGS = parse_args()
PREFIX = f"{ARGS.catalog}." if ARGS.catalog else ""
BRONZE, SILVER, QUALITY = f"{PREFIX}bronze", f"{PREFIX}silver", f"{PREFIX}quality"
HC = f"{SILVER}.workforce_headcount_silver"
DEN = f"{SILVER}.workforce_area_denominator_silver"
SPEC = f"{SILVER}.workforce_specialist_silver"
GEO = f"{SILVER}.geography_silver"
FHSIS = f"{BRONZE}.workforce_fhsis_health_workers_bronze"
PSA = f"{BRONZE}.workforce_psa_gov_practitioners_bronze"
PSMO = f"{BRONZE}.workforce_psmo_oncologists_bronze"
FHSIS_KEY, PSA_KEY, PSMO_KEY = "doh_fhsis_demographic", "psa_gov_practitioners", "psmo_oncologists"

spark = SparkSession.builder.getOrCreate()

# check_id -> (check_name, check_type, severity). One meaning per code; the name never changes.
CHECKS = {
    "S00": ("QC ran without error", "EXECUTION", "FAIL"),
    "S01": ("table exists and has rows", "COMPLETENESS", "FAIL"),
    "S02": ("grain key not null", "COMPLETENESS", "FAIL"),
    "S03": ("grain key unique", "UNIQUENESS", "FAIL"),
    "S06": ("counts non-negative", "VALIDITY", "FAIL"),
    "S08": ("period within expected range", "VALIDITY", "FAIL"),
    "S09": ("bronze to silver rows reconcile", "RECONCILIATION", "FAIL"),
    # workforce codes
    "S60": ("lineage columns not null", "COMPLETENESS", "FAIL"),
    "S61": ("every lineage reference has one build input", "CONSISTENCY", "FAIL"),
    "S62": ("table written by one succeeded build", "CONSISTENCY", "FAIL"),
    "S63": (
        "silver built from the current bronze loads and reference versions",
        "CONSISTENCY",
        "FAIL",
    ),
    "S64": ("national control values match", "RECONCILIATION", "FAIL"),
    "S65": ("area control values match", "RECONCILIATION", "FAIL"),
    "S66": ("accepted values", "VALIDITY", "FAIL"),
    "S67": ("eligibility follows the named rules", "CONSISTENCY", "FAIL"),
    "S68": ("totals equal their mutually exclusive components", "RECONCILIATION", "WARN"),
    "S69": ("split fields add up to the published total", "CONSISTENCY", "WARN"),
    "S70": ("2025 province vs its municipalities and cities", "CONSISTENCY", "WARN"),
    "S71": ("PSA and FHSIS national totals agree 2018-2023", "CONSISTENCY", "WARN"),
    "S72": ("province year-on-year change above 50% outside break years", "CONSISTENCY", "WARN"),
    "S73": ("quarantined bronze rows", "COMPLETENESS", "WARN"),
    "S74": ("denominator lineage groups follow source contribution", "COMPLETENESS", "FAIL"),
    "S75": ("every MAP key has a lineage group", "CONSISTENCY", "FAIL"),
    "S76": ("population agrees across sheets of the same workbook", "CONSISTENCY", "WARN"),
    "S77": (
        "PSMO label matched to a city by name (no province of that name)",
        "CONSISTENCY",
        "WARN",
    ),
    "S78": ("listed oncologist control total", "RECONCILIATION", "FAIL"),
    "S79": ("area label overrides not yet reviewed", "CONSISTENCY", "WARN"),
}

# National controls (plan 9): FHSIS doctors per year; PSA as in bronze B11.
NATIONAL_CONTROLS = [
    (FHSIS_KEY, y, "doctors", n)
    for y, n in [
        (2018, 3131),
        (2019, 3001),
        (2020, 3351),
        (2021, 4046),
        (2022, 4289),
        (2023, 4416),
        (2024, 5099),
        (2025, 5150),
    ]
] + [(PSA_KEY, 2023, "doctors", 4416), (PSA_KEY, 2012, "midwives", 16948)]
# Area controls: national totals cannot prove that values reached the right area.
AREA_CONTROLS = [
    ("Pangasinan", "psgc:0105500000", 2022, "doctors", 76),
    ("Pangasinan", "psgc:0105500000", 2023, "doctors", 97),
    ("City of Dagupan", "psgc:0105518000", 2023, "doctors", 5),
    ("City of Manila", "psgc:1380600000", 2021, "doctors", 304),
    ("BARMM", "psgc:1900000000", 2024, "doctors", 109),
]
PSMO_CONTROL_TOTAL = 419

# Denominator sheets (plan 8.1): (year, sheet). Used to scope the freshness and reconcile checks.
DENOMINATOR_SHEETS = [
    (2018, "Table 3B.2"),
    (2019, "HEALTH WORKERS PART1"),
    (2019, "HEALTH WORKERS PART3"),
    (2020, "HEALTH WORKERS PART1"),
    (2020, "HEALTH WORKERS PART3"),
    (2021, "HEALTH WORKERS PART1"),
    (2022, "HEALTH WORKERS PART1"),
    (2022, "HEALTH WORKERS PART2"),
    (2023, "HEALTH WORKERS PART1"),
    (2024, "Health Workers"),
    (2025, "Health Workers"),
]
FILE_YEAR = "try_cast(regexp_extract(_source_file, '_([0-9]{4})[.]xlsx$', 1) AS INT)"
DEN_FILTER = (
    "("
    + " OR ".join(f"({FILE_YEAR} = {y} AND _source_sheet = '{s}')" for y, s in DENOMINATOR_SHEETS)
    + ")"
)

# Declared inputs per table: (bronze table, _source_key, extra bronze filter). Used by S09 and S63.
DECLARED_INPUTS = {
    HC: [(FHSIS, FHSIS_KEY, "true"), (PSA, PSA_KEY, "true")],
    DEN: [(FHSIS, FHSIS_KEY, DEN_FILTER)],
    SPEC: [(PSMO, PSMO_KEY, "true")],
}

LINEAGE_ALWAYS = [
    "_silver_build_id",
    "_source_key",
    "_source_file",
    "_as_of_date",
    "_metric_source_columns",
]


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
    return "; ".join(" ".join(str(v) for v in r) for r in rows) or None


def table_version(name):
    try:
        return spark.sql(f"DESCRIBE HISTORY {name} LIMIT 1").collect()[0]["version"]
    except Exception:
        return None


class TableQC:
    """Checks for one silver table. Every result carries build:<build_id> of the table's build."""

    def __init__(self, dq, table):
        self.dq, self.table = dq, table
        ids = [r[0] for r in spark.sql(f"SELECT DISTINCT _silver_build_id FROM {table}").collect()]
        self.build_ids = ids
        self.build_id = ids[0] if len(ids) == 1 else None
        self.batch = f"build:{self.build_id}" if self.build_id else None
        self.total_sql = f"SELECT count(*) FROM {table}"

    def _rec(self, check_id, **kw):
        name, ctype, severity = CHECKS[check_id]
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

    # ---- checks shared by the tables ---------------------------------------------
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
        """S62: one build id in the table, in build_log as succeeded with the same row count."""
        if self.build_id is None:
            self.value("S62", f"{len(self.build_ids)} build ids in the table", "1", ok=False)
            return
        rows = spark.sql(f"""SELECT status, row_count FROM {QUALITY}.build_log
                             WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'""").collect()
        n = scalar(self.total_sql)
        ok = len(rows) == 1 and rows[0]["status"] == "succeeded" and rows[0]["row_count"] == n
        self.value(
            "S62",
            f"{len(rows)} build_log row(s)"
            + (f", {rows[0]['status']}, {rows[0]['row_count']} rows" if rows else ""),
            f"1 row, succeeded, {n} rows",
            ok=ok,
        )

    def lineage(self, extra=(), sheet_required_for=None):
        """S60: lineage columns not null (FHSIS rows also need _source_sheet)."""
        cols = LINEAGE_ALWAYS + list(extra)
        where = " OR ".join(f"{c} IS NULL" for c in cols)
        if sheet_required_for:
            where += f" OR (_source_key = '{sheet_required_for}' AND _source_sheet IS NULL)"
        self.count(
            "S60",
            f"SELECT count(*) FROM {self.table} WHERE {where}",
            self.total_sql,
            column_name=", ".join(cols),
        )

    def build_inputs_cover(self, sheet_cols=("_source_sheet",), where_cols=None):
        """S61: every file and sheet the rows point to has exactly one build_inputs row.
        sheet_cols: the sheet column(s) to check (the denominator has one per side)."""
        refs = " UNION ".join(
            f"SELECT DISTINCT _silver_build_id, _source_key, _source_file, {c} AS sheet FROM {self.table}"
            + (f" WHERE {where_cols[i]}" if where_cols and where_cols[i] else "")
            for i, c in enumerate(sheet_cols)
        )
        self.count(
            "S61",
            f"""
            SELECT count(*) FROM (
              SELECT s._source_key, s._source_file, s.sheet, count(v.build_id) AS n
              FROM ({refs}) s
              LEFT JOIN {QUALITY}.v_build_lineage v
                ON v.build_id = s._silver_build_id AND v.target_table = '{self.table}'
               AND v.source_key = s._source_key AND v.source_file = s._source_file AND v.source_sheet <=> s.sheet
              GROUP BY s._source_key, s._source_file, s.sheet) WHERE n <> 1""",
            f"SELECT count(*) FROM ({refs})",
            detail="files or sheets referenced by silver rows without exactly one build_inputs row",
        )

    def freshness(self):
        """S63, per source: the files, sheets and load times in bronze now are the ones the build read;
        and the geography and reference tables are still at the version the build read."""
        for bronze, source_key, extra in DECLARED_INPUTS[self.table]:
            mismatches = scalar(f"""
                WITH now_in_bronze AS (
                  SELECT DISTINCT _source_file AS f, _source_sheet AS s, _ingested_at AS t
                  FROM {bronze} WHERE _source_key = '{source_key}' AND {extra}),
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
                "S63",
                source_key=source_key,
                fail_count=mismatches + (1 if consumed == 0 else 0),
                total_count=max(consumed, 1),
                detail=None
                if (mismatches == 0 and consumed > 0)
                else "bronze has a new, removed or reloaded file or sheet since the build: rebuild silver",
            )
        # table inputs (geography, reviewed reference tables): geography by snapshot, the others by
        # version now vs version read, and row count now vs rows read
        stale, soft = [], []
        for r in spark.sql(f"""SELECT input_table, input_table_version, content_checksum, input_rows
                               FROM {QUALITY}.build_inputs
                               WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                 AND input_kind = 'table'""").collect():
            if r["input_table"] == GEO and r["content_checksum"]:
                # geography: the snapshot matters, not the Delta version (a merge that changes
                # nothing still writes a version)
                now = scalar(f"SELECT max_by(content_checksum, silver_processed_at) FROM {GEO}")
                if now != r["content_checksum"]:
                    stale.append(
                        f"{r['input_table']} snapshot {r['content_checksum'][:12]} -> {str(now)[:12]}"
                    )
                continue
            now = table_version(r["input_table"])
            if (
                r["input_table_version"] is not None
                and now is not None
                and now != r["input_table_version"]
            ):
                rows_now = scalar(f"SELECT count(*) FROM {r['input_table']}")
                if rows_now == r["input_rows"]:
                    soft.append(
                        f"{r['input_table']} {r['input_table_version']} -> {now} ({rows_now} rows)"
                    )
                else:
                    stale.append(f"{r['input_table']} {r['input_table_version']} -> {now}")
        self._rec(
            "S63",
            fail_count=len(stale),
            total_count=None,
            column_name="input_table_version",
            detail="; ".join(stale) or None,
        )
        if soft:
            # same row count as read: likely OPTIMIZE or a rerun that wrote the same rows
            self._rec(
                "S63",
                status="WARN",
                fail_count=len(soft),
                total_count=None,
                column_name="input_table_version",
                detail="version changed, row count unchanged (likely OPTIMIZE or a rerun that wrote the "
                "same rows): " + "; ".join(soft),
            )

    def reconcile(self, referenced_sql_by_source):
        """S09, per source. row_disposition holds only the rows that were NOT loaded (same as
        diseases; quality.v_build_reconciliation), so:
             rows the build read (build_inputs.input_rows) = bronze rows now
             rows silver points to = rows read - rows not loaded (merged_into counts as loaded)"""
        for bronze, source_key, extra in DECLARED_INPUTS[self.table]:
            bronze_rows = scalar(
                f"SELECT count(*) FROM {bronze} WHERE _source_key = '{source_key}' AND {extra}"
            )
            read = scalar(f"""SELECT coalesce(sum(input_rows), 0) FROM {QUALITY}.build_inputs
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND input_kind = 'bronze_source' AND source_key = '{source_key}'""")
            d = spark.sql(f"""SELECT count_if(disposition NOT IN ('loaded', 'merged_into')) AS not_loaded,
                                     count_if(disposition = 'merged_into') AS merged,
                                     count_if(disposition = 'dropped_non_data') AS dropped,
                                     count_if(disposition = 'quarantined') AS quar
                              FROM {QUALITY}.row_disposition
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND source_key = '{source_key}'""").collect()[0]
            referenced = scalar(referenced_sql_by_source(source_key))
            loaded = read - d["not_loaded"]
            ok = (read == bronze_rows) and (referenced == loaded)
            self.value(
                "S09",
                f"rows read {read}, silver references {referenced}",
                f"bronze rows {bronze_rows}, loaded {loaded}",
                ok=ok,
                source_key=source_key,
                detail=f"loaded {loaded} (of which merged {d['merged']}), dropped {d['dropped']}, "
                f"quarantined {d['quar']}",
            )

    def quarantined(self, bronze, source_key):
        """S73: quarantined rows listed for review, and copied to quality.quarantine."""
        q = spark.sql(f"""SELECT count(*) AS n, concat_ws('; ', slice(collect_list(concat(
                                 regexp_extract(source_file, '([0-9]{{4}})[.]xlsx$', 1), ' ', source_sheet,
                                 ' row ', source_row_num, ': ', reason)), 1, 15)) AS rows
                          FROM {QUALITY}.row_disposition
                          WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                            AND source_key = '{source_key}' AND disposition = 'quarantined'""").collect()[
            0
        ]
        self._rec(
            "S73",
            source_key=source_key,
            fail_count=q["n"],
            total_count=scalar(f"SELECT count(*) FROM {bronze} WHERE _source_key = '{source_key}'"),
            detail=q["rows"],
        )
        # always called: an empty DataFrame replaces (clears) the earlier copy in quality.quarantine
        rows = spark.sql(f"""
            SELECT b.* FROM {QUALITY}.row_disposition d
            JOIN {bronze} b
              ON b._source_key = d.source_key AND b._source_file = d.source_file
             AND b._source_sheet <=> d.source_sheet AND b._source_row_num = d.source_row_num
            WHERE d.build_id = '{self.build_id}' AND d.target_table = '{self.table}'
              AND d.disposition = 'quarantined'""")
        self.dq.quarantine(
            rows,
            self.table,
            "S73",
            "area_label_missing_or_code_not_in_geography",
            key_cols=["_source_file", "_source_sheet", "_source_row_num"],
            source_table=bronze,
        )


# ----------------------------------------------------------------------------------
# workforce_headcount_silver
# ----------------------------------------------------------------------------------
STATUSES = "('ok', 'zero_no_data', 'no_report', 'not_published', 'blank', 'marker_undefined')"


def check_headcount(dq, profile):
    t = TableQC(dq, HC)
    total_sql = t.total_sql
    t.basics(["_source_key", "area_key", "year", "profession"])
    t.build_record()
    t.lineage(extra=["_source_row_num"], sheet_required_for=FHSIS_KEY)
    t.build_inputs_cover()
    if t.build_id:
        t.freshness()
        t.reconcile(
            lambda sk: (
                f"""SELECT count(*) FROM (SELECT DISTINCT _source_file, _source_sheet, _source_row_num
                                                         FROM {HC} WHERE _source_key = '{sk}')"""
            )
        )
        t.quarantined(FHSIS, FHSIS_KEY)

    t.count(
        "S06",
        f"""SELECT count(*) FROM {HC}
                       WHERE least(coalesce(headcount_lgu_hired, 0), coalesce(headcount_doh_hired, 0),
                                   coalesce(headcount_male, 0), coalesce(headcount_female, 0),
                                   coalesce(headcount_total, 0)) < 0""",
        total_sql,
        column_name="headcount_*",
    )
    t.count(
        "S08",
        f"""SELECT count(*) FROM {HC}
                       WHERE (_source_key = '{FHSIS_KEY}' AND year NOT BETWEEN 2018 AND 2025)
                          OR (_source_key = '{PSA_KEY}' AND year NOT BETWEEN 2012 AND 2023)""",
        total_sql,
        column_name="year",
    )
    t.count(
        "S66",
        f"""
        SELECT count(*) FROM {HC}
        WHERE profession NOT IN ('doctors','nurses','midwives','dentists','medtech','nutritionists',
                                 'sanitary_engineers','sanitary_inspectors','bhw')
           OR geo_level NOT IN ('country','region','province','city','municipality','special_geographic_area')
           OR split_basis NOT IN ('sex','employer','employer_lgu_only','none')
           OR source_role NOT IN ('preferred','cross_check')
           OR lgu_hired_status NOT IN {STATUSES} OR doh_hired_status NOT IN {STATUSES}
           OR male_status NOT IN {STATUSES} OR female_status NOT IN {STATUSES} OR total_status NOT IN {STATUSES}
           OR NOT area_key RLIKE '^(psgc:[0-9]{{10}}|ph|hist:[a-z_]+)$'""",
        total_sql,
        column_name="profession, geo_level, split_basis, statuses, area_key",
    )
    t.count(
        "S67",
        f"""
        SELECT count(*) FROM {HC}
        WHERE (NOT analysis_eligible AND (exclusion_reason IS NULL OR display_label IS NULL))
           OR (analysis_eligible AND (exclusion_reason IS NOT NULL OR total_status <> 'ok'))
           OR (exclusion_reason = 'reporting_inconsistency'
               AND coalesce(exclusion_rule, '') NOT IN ('R1_PROVINCE_ZERO_CHILDREN_POSITIVE', 'R2_NEW_PROVINCE_FIRST_YEAR_ZERO',
                                                        'R3_PSA_SUSPECT_VALUE', 'R4_TOTAL_ZERO_SPLITS_BLANK',
                                                        'R5_TOTAL_ZERO_SPLIT_POSITIVE'))""",
        total_sql,
        column_name="analysis_eligible, exclusion_reason, exclusion_rule",
        detail=listing(f"""SELECT exclusion_reason, coalesce(exclusion_rule, ''), count(*) FROM {HC}
                               WHERE NOT analysis_eligible GROUP BY 1, 2 ORDER BY 1, 2"""),
    )

    for source_key, year, profession, expected in NATIONAL_CONTROLS:
        observed = scalar(f"""SELECT max(headcount_total) FROM {HC} WHERE _source_key = '{source_key}'
                              AND area_key = 'ph' AND year = {year} AND profession = '{profession}'""")
        t.value(
            "S64",
            observed,
            expected,
            source_key=source_key,
            column_name="headcount_total",
            detail=f"Philippines {year} {profession}",
        )
    for name, area_key, year, profession, expected in AREA_CONTROLS:
        observed = scalar(f"""SELECT max(headcount_total) FROM {HC} WHERE _source_key = '{FHSIS_KEY}'
                              AND area_key = '{area_key}' AND year = {year} AND profession = '{profession}'""")
        t.value(
            "S65",
            observed,
            expected,
            source_key=FHSIS_KEY,
            column_name="headcount_total",
            detail=f"{name} ({area_key}) {year} {profession}",
        )

    # ---- WARN: the sources disagree or have gaps; silver is still a faithful copy -------------
    # S68 (plan 4.5). 2018-2024: region row = the rows listed under it in the same sheet (provinces,
    # listed cities, SGA, each once); national = sum of region rows. 2025: region = rows whose
    # comparison parent is the region (provinces, HUC/ICC, SGA). Only groups where every part is ok.
    recon = f"""
        WITH h AS (SELECT * FROM {HC} WHERE _source_key = '{FHSIS_KEY}'),
        nat AS (
          SELECT p.year, p.profession, 'ph' AS area, p.headcount_total AS published,
                 sum(r.headcount_total) AS parts, bool_and(r.total_status = 'ok') AS all_ok
          FROM h p JOIN h r ON r._source_file = p._source_file AND r._source_sheet = p._source_sheet
                           AND r.profession = p.profession AND r.geo_level = 'region'
          WHERE p.area_key = 'ph' AND p.total_status = 'ok'
          GROUP BY p.year, p.profession, p.headcount_total),
        reg_pub AS (
          SELECT p.year, p.profession, p.area_label_source AS area, p.headcount_total AS published,
                 sum(c.headcount_total) AS parts, bool_and(c.total_status = 'ok') AS all_ok
          FROM h p JOIN h c ON c._source_file = p._source_file AND c._source_sheet = p._source_sheet
                           AND c.profession = p.profession AND c.region_as_published = p.region_as_published
                           AND c.geo_level NOT IN ('region', 'country')
          WHERE p.geo_level = 'region' AND p.year <= 2024 AND p.total_status = 'ok'
          GROUP BY p.year, p.profession, p.area_label_source, p.headcount_total),
        reg25 AS (
          SELECT p.year, p.profession, p.area_label_source AS area, p.headcount_total AS published,
                 sum(c.headcount_total) AS parts, bool_and(c.total_status = 'ok') AS all_ok
          FROM h p JOIN h c ON c.year = p.year AND c.profession = p.profession AND c.parent_area_key = p.area_key
          WHERE p.geo_level = 'region' AND p.year = 2025 AND p.total_status = 'ok'
          GROUP BY p.year, p.profession, p.area_label_source, p.headcount_total)
        SELECT * FROM nat UNION ALL SELECT * FROM reg_pub UNION ALL SELECT * FROM reg25"""
    spark.sql(recon).createOrReplaceTempView("wf_qc_recon")
    t.count(
        "S68",
        "SELECT count(*) FROM wf_qc_recon WHERE all_ok AND published <> parts",
        "SELECT count(*) FROM wf_qc_recon WHERE all_ok",
        source_key=FHSIS_KEY,
        column_name="headcount_total",
        detail=listing("""SELECT year, area, profession, published, 'vs', parts FROM wf_qc_recon
                              WHERE all_ok AND published <> parts ORDER BY profession = 'doctors' DESC, year, area"""),
    )
    t.count(
        "S69",
        f"SELECT count(*) FROM {HC} WHERE split_matches_total = false",
        f"SELECT count(*) FROM {HC} WHERE split_matches_total IS NOT NULL",
        source_key=FHSIS_KEY,
        column_name="split_matches_total",
        detail=listing(
            f"SELECT year, area_label_source, profession FROM {HC} WHERE split_matches_total = false ORDER BY year"
        ),
    )
    t.count(
        "S70",
        f"SELECT count(*) FROM {HC} WHERE array_contains(review_flags, 'province_vs_municipality_sum')",
        f"SELECT count(*) FROM {HC} WHERE year = 2025 AND geo_level = 'province'",
        source_key=FHSIS_KEY,
        column_name="headcount_total",
        detail=listing(f"""SELECT area_label_source, profession, headcount_total FROM {HC}
                               WHERE array_contains(review_flags, 'province_vs_municipality_sum') AND profession = 'doctors'"""),
    )
    t.count(
        "S71",
        f"""SELECT count(*) FROM {HC} p
                       LEFT JOIN {HC} f ON f._source_key = '{FHSIS_KEY}' AND f.area_key = 'ph'
                                       AND f.year = p.year AND f.profession = p.profession
                       WHERE p._source_key = '{PSA_KEY}' AND p.area_key = 'ph' AND p.year BETWEEN 2018 AND 2023
                         AND NOT (p.headcount_total <=> f.headcount_total)""",
        f"SELECT count(*) FROM {HC} WHERE _source_key = '{PSA_KEY}' AND area_key = 'ph' AND year BETWEEN 2018 AND 2023",
        source_key=PSA_KEY,
        column_name="headcount_total",
        detail=listing(f"""SELECT p.year, p.profession, 'PSA', p.headcount_total, 'FHSIS', f.headcount_total FROM {HC} p
                               LEFT JOIN {HC} f ON f._source_key = '{FHSIS_KEY}' AND f.area_key = 'ph'
                                               AND f.year = p.year AND f.profession = p.profession
                               WHERE p._source_key = '{PSA_KEY}' AND p.area_key = 'ph' AND p.year BETWEEN 2018 AND 2023
                                 AND NOT (p.headcount_total <=> f.headcount_total)"""),
    )
    t.count(
        "S72",
        f"SELECT count(*) FROM {HC} WHERE array_contains(review_flags, 'large_change')",
        f"SELECT count(*) FROM {HC} WHERE geo_level = 'province'",
        source_key=FHSIS_KEY,
        column_name="headcount_total",
        detail=listing(f"""SELECT year, area_label_source, profession, headcount_total FROM {HC}
                               WHERE array_contains(review_flags, 'large_change') AND profession IN ('doctors', 'nurses', 'midwives')
                                 AND analysis_eligible ORDER BY year"""),
    )
    t.count(
        "S79",
        f"SELECT count(*) FROM {HC} WHERE area_label_override_status IN ('proposed', 'rejected')",
        total_sql,
        source_key=FHSIS_KEY,
        column_name="area_label_override_status",
        detail=listing(f"""SELECT DISTINCT year, area_label_source, '->', area_key, area_label_override_status FROM {HC}
                               WHERE area_label_override_status IN ('proposed', 'rejected')"""),
    )
    if profile:
        dq.profile_table(HC, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# workforce_area_denominator_silver
# ----------------------------------------------------------------------------------
def check_denominator(dq, profile):
    t = TableQC(dq, DEN)
    total_sql = t.total_sql
    t.basics(["_source_key", "area_key", "year"])
    t.build_record()
    t.lineage(extra=["_population_source_sheet", "_population_source_row_num"])
    t.build_inputs_cover(
        sheet_cols=("_population_source_sheet", "_households_source_sheet"),
        where_cols=(None, "households_source_present"),
    )
    if t.build_id:
        t.freshness()
        t.reconcile(
            lambda sk: (
                f"""
            SELECT count(*) FROM (
              SELECT _source_file, _population_source_sheet, _population_source_row_num FROM {DEN}
              UNION
              SELECT _source_file, _households_source_sheet, _households_source_row_num FROM {DEN}
              WHERE households_source_present)"""
            )
        )

    t.count(
        "S06",
        f"SELECT count(*) FROM {DEN} WHERE reported_population < 0 OR household_estimates < 0",
        total_sql,
        column_name="reported_population, household_estimates",
    )
    t.count(
        "S08",
        f"SELECT count(*) FROM {DEN} WHERE year NOT BETWEEN 2018 AND 2025",
        total_sql,
        column_name="year",
    )
    t.count(
        "S66",
        f"""SELECT count(*) FROM {DEN}
                       WHERE population_status NOT IN ('ok', 'zero_no_data', 'no_report', 'blank')
                          OR households_status NOT IN ('ok', 'zero_no_data', 'no_report', 'blank', 'not_published', 'no_source_row')
                          OR geo_level NOT IN ('country','region','province','city','municipality','special_geographic_area')""",
        total_sql,
        column_name="population_status, households_status, geo_level",
    )
    # S74: a side's lineage is filled exactly when its source contributes (contract 3.4, plan 8.1)
    t.count(
        "S74",
        f"""
        SELECT count(*) FROM {DEN}
        WHERE (population_source_present AND (_population_source_sheet IS NULL OR _population_source_row_num IS NULL))
           OR (NOT population_source_present AND (_population_source_sheet IS NOT NULL OR _population_source_row_num IS NOT NULL))
           OR (households_source_present AND (_households_source_sheet IS NULL OR _households_source_row_num IS NULL))
           OR (NOT households_source_present AND (_households_source_sheet IS NOT NULL OR _households_source_row_num IS NOT NULL))
           OR (households_source_present AND year NOT IN (2019, 2020, 2022, 2024, 2025))""",
        total_sql,
        column_name="_population_source_*, _households_source_*",
    )
    # S75: metric_groups (contract 3.6) covers every MAP key
    t.count(
        "S75",
        f"""
        SELECT count(*) FROM (SELECT DISTINCT metric FROM (SELECT explode(map_keys(_metric_source_columns)) AS metric FROM {DEN}))
        WHERE metric NOT IN ('reported_population', 'household_estimates')""",
        f"SELECT count(DISTINCT metric) FROM (SELECT explode(map_keys(_metric_source_columns)) AS metric FROM {DEN})",
        column_name="_metric_source_columns",
        detail="metric_groups: reported_population -> population, household_estimates -> households",
    )
    # S76 (plan 7.1): population printed on the other sheets of the same workbook. The area of each
    # bronze row on those sheets comes from the headcount table's lineage.
    if spark.catalog.tableExists(HC):
        spark.sql(f"""
            WITH rows AS (
              SELECT DISTINCT area_key, year, _source_file, _source_sheet, _source_row_num
              FROM {HC} WHERE _source_key = '{FHSIS_KEY}'),
            other AS (
              SELECT r.area_key, r.year, r._source_sheet,
                     try_cast(regexp_replace(trim(b.population), '[ ,]', '') AS DOUBLE) AS pop
              FROM rows r
              JOIN {FHSIS} b ON b._source_key = '{FHSIS_KEY}' AND b._source_file = r._source_file
               AND b._source_sheet = r._source_sheet AND b._source_row_num = r._source_row_num)
            SELECT d.year, d.area_label_source, o._source_sheet, o.pop, d.reported_population
            FROM {DEN} d
            JOIN other o ON o.area_key = d.area_key AND o.year = d.year AND o._source_sheet <> d._population_source_sheet
            WHERE d.population_status = 'ok' AND o.pop IS NOT NULL""").createOrReplaceTempView(
            "wf_qc_pop"
        )
        t.count(
            "S76",
            "SELECT count(*) FROM wf_qc_pop WHERE abs(pop - reported_population) > 0.5",
            "SELECT count(*) FROM wf_qc_pop",
            source_key=FHSIS_KEY,
            column_name="reported_population",
            detail=listing("""SELECT year, area_label_source, _source_sheet, cast(pop AS BIGINT), 'vs',
                                         cast(reported_population AS BIGINT)
                                  FROM wf_qc_pop WHERE abs(pop - reported_population) > 0.5"""),
        )
    if profile:
        dq.profile_table(DEN, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# workforce_specialist_silver
# ----------------------------------------------------------------------------------
def check_specialist(dq, profile):
    t = TableQC(dq, SPEC)
    total_sql = t.total_sql
    t.basics(["_source_key", "snapshot_date", "area_label_source"])
    t.build_record()
    t.lineage(extra=["_source_row_num"])
    t.build_inputs_cover()
    if t.build_id:
        t.freshness()
        t.reconcile(lambda sk: f"SELECT count(DISTINCT _source_file, _source_row_num) FROM {SPEC}")
    t.count(
        "S06",
        f"SELECT count(*) FROM {SPEC} WHERE listed_oncologist_count < 0",
        total_sql,
        column_name="listed_oncologist_count",
    )
    t.count(
        "S66",
        f"""SELECT count(*) FROM {SPEC}
                       WHERE count_status NOT IN ('ok', 'blank') OR count_unit <> 'unconfirmed'
                          OR geo_level NOT IN ('region','province','city','municipality','region_area','ncr_district','composite_area')
                          OR (is_composite_area AND component_psgc_codes IS NULL)""",
        total_sql,
        column_name="count_status, count_unit, geo_level",
    )
    t.value(
        "S78",
        scalar(f"SELECT sum(listed_oncologist_count) FROM {SPEC}"),
        PSMO_CONTROL_TOTAL,
        source_key=PSMO_KEY,
        column_name="listed_oncologist_count",
        detail="sum of listings as published; listings repeat across areas, so this is not a unique headcount",
    )
    t.count(
        "S77",
        f"""SELECT count(*) FROM {SPEC}
                       WHERE area_resolution_method = 'name_join' AND geo_level <> 'province'
                         AND NOT (upper(area_label_source) LIKE 'CITY OF %' OR upper(area_label_source) LIKE '% CITY')""",
        total_sql,
        source_key=PSMO_KEY,
        column_name="area_key",
        detail=listing(f"""SELECT area_label_source, '->', area_key FROM {SPEC}
                               WHERE area_resolution_method = 'name_join' AND geo_level <> 'province'
                                 AND NOT (upper(area_label_source) LIKE 'CITY OF %' OR upper(area_label_source) LIKE '% CITY')"""),
    )
    if profile:
        dq.profile_table(SPEC, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------
TABLE_CHECKS = {
    "headcount": (HC, check_headcount),
    "denominator": (DEN, check_denominator),
    "specialist": (SPEC, check_specialist),
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
            if name == "specialist" and not spark.catalog.tableExists(table):
                # optional table: not built is WARN, and its checks are skipped
                cname, ctype, _ = CHECKS["S01"]
                dq.record(
                    "S01",
                    table_name=table,
                    status="WARN",
                    check_name=cname,
                    check_type=ctype,
                    severity="WARN",
                    observed="table not built",
                    expected="built by workforce_silver_04_specialist.sql (optional)",
                )
                continue
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
