# Silver QC for the facilities domain. Same approach as diseases_silver_qc.py and
# workforce_silver_qc.py: every result goes through dq_utils.DQRun into public_health.quality
# (qc_results, run_log, table_stats, profile, quarantine), and the script raises at the end if any
# check is FAIL.
# Follows facilities-silver-plan.md v2.1 (sections 5 and 6) and lineage-qc-contract.md v1.3.
#
# When it runs
#   After the facilities silver builds (00a, exceptions script, 00, 01 ... 04), before gold. The
#   build files have their own gates, which stop a bad build. This script checks the PUBLISHED
#   tables and stores the results, including the review checks that are WARN and therefore not gates.
#   Run order: 00a -> exceptions script -> 00 -> 01 -> 02 -> 03 -> 04a -> 04 -> [facilities_silver_qc.py]
#
# Tables checked
#   public_health.silver.facilities_registry_silver       (full candidate; delisted rows keep the
#   public_health.silver.facilities_id_map_silver          build that last read them, plan 5.3)
#   public_health.silver.facilities_metric_silver
#   public_health.silver.facilities_bed_occupancy_silver  (restricted: no profile, no row copies)
#   public_health.silver.facilities_osm_point_silver
#
# Identity in qc_results (lineage-qc-contract.md section 8, plan 6.4)
#   Whole-table check: batch_id = build:<build_id> of the latest succeeded build (quality.build_log).
#   Check about one input: batch_id = <source_key>:<content_checksum> of the file the build read
#   (build_inputs), source_key filled. FHSIS (8 files, no single checksum) keeps build:<build_id>.
#   capture_table_stats records the table version checked.
#
# How to run (Databricks notebook cell or job; no arguments needed)
#   python facilities_silver_qc.py
#   python facilities_silver_qc.py --tables registry,osm_point
#   python facilities_silver_qc.py --fail_on_error false
#   In a notebook, set sys.argv first to change an option: sys.argv = ["x", "--tables", "metric"]
#   dq_utils.py must be a Python FILE in the quality folder (same search as the other QC scripts).
#
# Check codes
#   Shared codes from quality_registry_seed.sql, same names and severities: S00-S06, S08, S09, S11.
#   S13-S28 are facilities codes (CHECKS below), in the free block between the shared codes and
#   diseases (S30-S50); workforce is S60-S79, socioeconomic S80-S96. S29 is kept free. Add S13-S28
#   to the registry seed before switching DQRun to strict_registry=True.
#
#   Code  Check                                                         Tables          Severity
#   S01   table exists and has rows                                     all             FAIL
#   S02   grain key not null                                            all             FAIL
#   S03   grain key unique                                              all             FAIL
#   S04   PSGC code found in geography (latest snapshot)                all but id map  WARN
#   S05   area level fits the table, area_key = psgc:<code> or a named key  reg/met/BOR/OSM  FAIL
#   S06   counts non-negative                                           reg/met/BOR/OSM FAIL
#   S08   year within the source's range                                metric, BOR     FAIL
#   S09   bronze rows read = bronze now; rows referenced = read - not loaded (per source)  FAIL
#   S11   accepted values                                               all             WARN
#   S13   lineage columns not null                                      all             FAIL
#   S14   every file / sheet the rows point to has one build_inputs row all             FAIL
#   S15   latest succeeded build wrote the table with this row count    all             FAIL
#   S16   bronze files, load times, geography snapshot and reference tables unchanged since the build  FAIL
#   S17   one load time and one processed ingestion_metadata row per file / sheet  all  FAIL
#   S18   NHFR id in at most one registry facility                      registry        FAIL
#   S19   NHFR / HFSRB lineage groups filled exactly when in_nhfr / in_hfsrb  registry  FAIL
#   S20   every _metric_source_columns key has a lineage group / measure  registry, metric  FAIL
#   S21   control totals (NHFR facilities and beds, BOR rows)           registry, BOR   FAIL (WARN on a new file)
#   S22   id map and registry facility keys agree both ways             id map          FAIL
#   S23   authorized / analysis beds follow their definitions           registry        FAIL
#   S24   BOR eligibility follows exclusion_reason                      BOR             FAIL
#   S25   BOR above 100 percent                                         BOR             WARN
#   S26   FHSIS region = its provinces + listed cities (bhs, barangays) metric          WARN
#   S27   OSM points placed by city tag only / tag disagrees with coordinates  OSM      WARN
#   S28   quarantined bronze rows per source (copied to quality.quarantine, never for BOR)  WARN
#   Not covered: "rerun gives the same rows" (plan 6.3, needs a second build) and S10 / S12.
#
# Severity policy (same as bronze, diseases and workforce)
#   FAIL = the table is wrong, incomplete or cannot be traced.
#   WARN = the table is a faithful copy of the sources, but the sources disagree or have gaps
#          a person should look at.
#
# Updated 2026-10-12 (review before the first Databricks run)
#   * S16: a reference table with a new Delta version but the same row count is WARN, not FAIL
#     (00 / 00a rerun with CREATE OR REPLACE). A changed row count still FAILs.
#   * S21: the NHFR controls count only rows of the current build (carried not_listed rows are
#     left out).
#   * S24 / S06 (bed occupancy): service_level '' counts as missing; negative BOR rows that are
#     excluded as bor_negative do not FAIL S06.
#   * quality.quarantine (S28) is replaced per run by dq_utils, also when nothing is quarantined.
# Updated 2026-10-14
#   * hdx_healthsites is read from its newest file only (LATEST_FILE_SOURCES): S09, S16 and S28 compare
#     the build with that file, not with every snapshot in bronze.
# Updated 2026-10-19 (rule 2a: no number the logic depends on is typed here)
#   * S21 controls are read from sources_facilities.yaml, the numbers bronze QC checks:
#       nhfr_facilities  doh_nhfr qc.expected_rows
#       nhfr_beds        doh_nhfr qc.control_values item with column 'Bed Capacity'
#       bor_rows         doh_foi_hospital_beds qc.expected_rows
#     A missing value is S00 FAIL for the table, so a YAML edit cannot switch S21 off.
#   * Build settings are read from build_log.parameters of the table's latest succeeded build:
#       bed occupancy  bor_baseline_max (S24, S25), bor_expected_sheets (S08 years)
#       metric         hospital_definition_break_year (S11)
#       OSM points     ph_bbox (S11)
#     A build written before 2026-10-19 lacks the newer keys: S00 FAIL for that table says which
#     build to rerun.
#   * S08 year ceilings are the current year, not 2025; floors are named in YEAR_FLOOR.

import argparse
import functools
import json
import os
import sys

import yaml
from pyspark.sql import SparkSession


# ----------------------------------------------------------------------------------
# Find dq_utils.py (same search as the other QC scripts)
# ----------------------------------------------------------------------------------
def _add_dq_utils_to_path():
    # Looks in this file's folder and the working directory, up to five levels above each, and in
    # any *quality* folder there (e.g. src/05_quality/). Works when __file__ is not set.
    # Already importable (on sys.path, or a job's library): nothing to do.
    import importlib.util

    if importlib.util.find_spec("dq_utils") is not None:
        return None
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

DOMAIN = "facilities"
SCRIPT_NAME = "facilities_silver_qc.py"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument(
        "--catalog", default="public_health", help="'' gives two-part names (local tests)"
    )
    p.add_argument(
        "--tables",
        default="ALL",
        help="ALL, or any of: registry,id_map,metric,bed_occupancy,osm_point",
    )
    p.add_argument(
        "--fail_on_error", default="true", help="false = record results but do not raise"
    )
    p.add_argument(
        "--profile", default="true", help="Also write a column profile (never for bed occupancy)"
    )
    p.add_argument(
        "--config_path",
        default=None,
        help="Full path to sources_facilities.yaml (found automatically if omitted)",
    )
    p.add_argument("--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job")
    p.add_argument("--code_version", default=None)
    a, _ = p.parse_known_args()  # parse_known_args: notebook kernels pass their own arguments
    return a


ARGS = parse_args()
PREFIX = f"{ARGS.catalog}." if ARGS.catalog else ""
BRONZE, SILVER, QUALITY = f"{PREFIX}bronze", f"{PREFIX}silver", f"{PREFIX}quality"
REG = f"{SILVER}.facilities_registry_silver"
IDMAP = f"{SILVER}.facilities_id_map_silver"
MET = f"{SILVER}.facilities_metric_silver"
BOR = f"{SILVER}.facilities_bed_occupancy_silver"
OSM = f"{SILVER}.facilities_osm_point_silver"
GEO = f"{SILVER}.geography_silver"

spark = SparkSession.builder.getOrCreate()

# check_id -> (check_name, check_type, severity). One meaning per code; the name never changes.
CHECKS = {
    "S00": ("QC ran without error", "EXECUTION", "FAIL"),
    "S01": ("table exists and has rows", "COMPLETENESS", "FAIL"),
    "S02": ("grain key not null", "COMPLETENESS", "FAIL"),
    "S03": ("grain key unique", "UNIQUENESS", "FAIL"),
    "S04": ("PSGC code found in geography", "CONSISTENCY", "WARN"),
    "S05": ("admin level valid", "VALIDITY", "FAIL"),
    "S06": ("counts non-negative", "VALIDITY", "FAIL"),
    "S08": ("period within expected range", "VALIDITY", "FAIL"),
    "S09": ("bronze to silver rows reconcile", "RECONCILIATION", "FAIL"),
    "S11": ("accepted values", "VALIDITY", "WARN"),
    # facilities codes
    "S13": ("lineage columns not null", "COMPLETENESS", "FAIL"),
    "S14": ("every lineage reference has one build input", "CONSISTENCY", "FAIL"),
    "S15": ("table written by a succeeded build", "CONSISTENCY", "FAIL"),
    "S16": (
        "silver built from the current bronze loads and reference versions",
        "CONSISTENCY",
        "FAIL",
    ),
    "S17": (
        "one processed ingestion_metadata row and one load time per input",
        "CONSISTENCY",
        "FAIL",
    ),
    "S18": ("each NHFR id in at most one registry facility", "UNIQUENESS", "FAIL"),
    "S19": ("registry lineage groups follow in_nhfr / in_hfsrb", "COMPLETENESS", "FAIL"),
    "S20": ("every MAP key has a lineage group", "CONSISTENCY", "FAIL"),
    "S21": ("control totals match", "RECONCILIATION", "FAIL"),
    "S22": ("id map and registry keys agree", "CONSISTENCY", "FAIL"),
    "S23": ("bed columns follow their definitions", "CONSISTENCY", "FAIL"),
    "S24": ("bed occupancy eligibility follows the named rules", "CONSISTENCY", "FAIL"),
    "S25": ("bed occupancy rate above 100 or above the baseline maximum", "VALIDITY", "WARN"),
    "S26": ("FHSIS region equals its provinces and listed cities", "RECONCILIATION", "WARN"),
    "S27": (
        "OSM points placed by city tag only, or tag disagrees with coordinates",
        "COMPLETENESS",
        "WARN",
    ),
    "S28": ("quarantined bronze rows", "COMPLETENESS", "WARN"),
}

# Declared bronze inputs per table: (bronze table, _source_key). Used by S09, S16 and S29.
HFSRB = [
    ("facilities_hfsrb_hospitals_bronze", "doh_hfsrb_hospitals"),
    ("facilities_hfsrb_infirmaries_bronze", "doh_hfsrb_infirmaries"),
    ("facilities_hfsrb_primary_care_bronze", "doh_hfsrb_primary_care"),
    ("facilities_hfsrb_dialysis_clinics_bronze", "doh_hfsrb_dialysis_clinics"),
]
DECLARED_INPUTS = {
    REG: [("facilities_nhfr_bronze", "doh_nhfr")] + HFSRB,
    IDMAP: [("facilities_nhfr_bronze", "doh_nhfr")] + HFSRB,
    MET: [
        ("facilities_psa_hospitals_region_annual_bronze", "psa_hospitals_region_annual"),
        ("facilities_psa_beds_region_annual_bronze", "psa_beds_region_annual"),
        ("facilities_psa_hospitals_national_annual_bronze", "psa_hospitals_national_annual"),
        (
            "facilities_psa_hospitals_beds_national_annual_bronze",
            "psa_hospitals_beds_national_annual",
        ),
        (
            "facilities_psa_hospitals_region_annual_legacy_bronze",
            "psa_hospitals_region_annual_legacy",
        ),
        ("facilities_psa_bhs_region_annual_bronze", "psa_bhs_region_annual"),
        ("facilities_fhsis_primary_care_bronze", "doh_fhsis_demographic"),
    ],
    # since 2026-10-14 the HFSRB FOI release (entry 12a); entry 12 (bed_occupancy) stays in bronze, not read
    BOR: [("facilities_bed_occupancy_bronze", "doh_foi_hospital_beds")],
    OSM: [("facilities_hdx_healthsites_bronze", "hdx_healthsites")],
}
# Tables a build reads that it also writes (its own previous version): never "stale" for S16
SELF_INPUTS = {REG: {REG, IDMAP}, IDMAP: {IDMAP}}
# Sources whose build reads only the newest file (latest _as_of_date) although bronze keeps every
# snapshot (YAML load_mode latest_file, enforced in the build): S09, S16 and S28 compare the build
# with that file only. Same rule as fac_osm_latest_file in facilities_silver_04_osm_point.sql.
LATEST_FILE_SOURCES = {"hdx_healthsites"}


def bronze_scope(bronze, source_key):
    """WHERE clause for the bronze rows a build is expected to read for one source."""
    cond = f"_source_key = '{source_key}'"
    if source_key in LATEST_FILE_SOURCES:
        cond += (
            f" AND _as_of_date = (SELECT max(_as_of_date) FROM {BRONZE}.{bronze}"
            f" WHERE _source_key = '{source_key}')"
        )
    return cond


# Controls (plan 6.3): name -> (source_key, expected value, content_checksum of the file the value
# belongs to). The values come from sources_facilities.yaml (load_controls below, 2026-10-19).
#   checksum None: the value is compared (FAIL on a difference); the detail shows the checksum of
#                  the file the build read, so it can be pasted here after the first Databricks run.
#   checksum set:  a build that read another file gives WARN "new artifact, update control" instead
#                  of comparing (a new file is expected to change the value).
CONTROL_CHECKSUMS = {"nhfr_facilities": None, "nhfr_beds": None, "bor_rows": None}

# S08: a year below the floor can only be a parse error (earliest year each source covers); the
# ceiling is the current year. Bed occupancy years come from the build's bor_expected_sheets.
YEAR_FLOOR = {"metric": 1990, "doh_fhsis_demographic": 2018}
CONFIG_NAME = "sources_facilities.yaml"


# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------
def find_config(explicit=None):
    # Same search as the bronze QC scripts: --config_path, else this file's folder and the working
    # directory, and their config/ folders, up to five levels above each.
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
                candidate = os.path.join(folder, sub, CONFIG_NAME)
                searched.append(candidate)
                if os.path.isfile(candidate):
                    return candidate
            parent = os.path.dirname(folder)
            if parent == folder:
                break
            folder = parent
    raise FileNotFoundError(
        f"{CONFIG_NAME} not found. Pass --config_path. Looked in:\n  "
        + "\n  ".join(dict.fromkeys(searched))
    )


@functools.lru_cache(maxsize=1)
def load_controls():
    """S21 controls from sources_facilities.yaml: name -> (source_key, expected, checksum).
    Raises (S00 FAIL for the table being checked) when a value is missing."""
    with open(find_config(ARGS.config_path), encoding="utf-8") as f:
        sources = (yaml.safe_load(f) or {}).get("sources") or {}

    def qc(key):
        if key not in sources:
            raise KeyError(f"{CONFIG_NAME}: source {key} missing (needed for S21)")
        return sources[key].get("qc") or {}

    def rows(key):
        n = qc(key).get("expected_rows")
        if not isinstance(n, int):
            raise ValueError(
                f"{CONFIG_NAME}: {key} qc.expected_rows must be one number for S21, got {n!r}"
            )
        return n

    beds = [
        cv["expected"]
        for cv in qc("doh_nhfr").get("control_values") or []
        if cv.get("column") == "Bed Capacity"
    ]
    if len(beds) != 1:
        raise ValueError(
            f"{CONFIG_NAME}: doh_nhfr needs exactly one qc.control_values item with column 'Bed Capacity'"
        )
    values = {
        "nhfr_facilities": ("doh_nhfr", rows("doh_nhfr")),
        "nhfr_beds": ("doh_nhfr", beds[0]),
        "bor_rows": ("doh_foi_hospital_beds", rows("doh_foi_hospital_beds")),
    }
    return {k: (sk, v, CONTROL_CHECKSUMS[k]) for k, (sk, v) in values.items()}


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


def local_name(name):
    """Table names in build_inputs are three-part (public_health.silver.x); with --catalog ''
    (local tests) they are read as two-part names."""
    if name and not PREFIX and name.count(".") == 2:
        return name.split(".", 1)[1]
    return name


def table_version(name):
    try:
        return spark.sql(f"DESCRIBE HISTORY {name} LIMIT 1").collect()[0]["version"]
    except Exception:  # noqa: BLE001 (a table without Delta history: no version to compare)
        return None


def latest_geography():
    return f"""(SELECT psgc_code, geographic_level FROM {GEO}
               WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at) FROM {GEO}))"""


SGA_CODE = "1999900000"  # Special Geographic Area: a geography row with no level


def level_check(table, levels, named_keys=None):
    """S05 (plan 6.3 'PSGC completeness'): a row with a code has area_key psgc:<code> and a
    geography level allowed for the table; a row without a code has one of the named keys."""
    lv = ", ".join(f"'{x}'" for x in levels)
    named = f"t.area_key RLIKE '{named_keys}'" if named_keys else "false"
    return f"""SELECT count(*) FROM {table} t
               LEFT JOIN {latest_geography()} g ON g.psgc_code = t.psgc_code
               WHERE CASE WHEN t.psgc_code IS NULL THEN NOT ({named})
                          ELSE t.area_key <> concat('psgc:', t.psgc_code)
                            OR NOT (coalesce(g.geographic_level, '') IN ({lv}) OR t.psgc_code = '{SGA_CODE}')
                     END"""


class TableQC:
    """Checks for one silver table. Every result carries build:<build_id> of the latest succeeded
    build of the table (quality.build_log)."""

    def __init__(self, dq, table):
        self.dq, self.table = dq, table
        rows = spark.sql(f"""SELECT build_id, row_count, parameters FROM {QUALITY}.build_log
                             WHERE target_table = '{table}' AND status = 'succeeded'
                             ORDER BY finished_at DESC, build_id DESC LIMIT 1""").collect()
        self.build_id = rows[0]["build_id"] if rows else None
        self.logged_rows = rows[0]["row_count"] if rows else None
        self.params = json.loads(rows[0]["parameters"]) if rows and rows[0]["parameters"] else {}
        self.batch = f"build:{self.build_id}" if self.build_id else None
        self.total_sql = f"SELECT count(*) FROM {table}"
        self.this_build = f"_silver_build_id = '{self.build_id}'"

    def param(self, key):
        """A build setting from build_log.parameters of the latest succeeded build (rule 2a)."""
        if key not in self.params:
            raise KeyError(
                f"build_log.parameters of the latest {self.table} build has no '{key}': "
                f"rebuild the table with the 2026-10-19 build file"
            )
        return self.params[key]

    def checksums(self, source_key):
        """content_checksum(s) of one source as read by this build (build_inputs)."""
        if self.build_id is None:
            return []
        return [
            r[0]
            for r in spark.sql(f"""
            SELECT DISTINCT content_checksum FROM {QUALITY}.build_inputs
            WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
              AND input_kind = 'bronze_source' AND source_key = '{source_key}'
              AND content_checksum IS NOT NULL ORDER BY 1""").collect()
        ]

    def _rec(self, check_id, **kw):
        """Plan 6.4: a check about one input of a published table is identified by that input,
        <source_key>:<content_checksum> (the version checked is in table_stats). A source read from
        several files (FHSIS, 8 files) has no single checksum and keeps build:<build_id>."""
        name, ctype, severity = CHECKS[check_id]
        batch = self.batch
        sk = kw.get("source_key")
        if sk:
            sums = self.checksums(sk)
            if len(sums) == 1:
                batch = f"{sk}:{sums[0]}"
        return self.dq.record(
            check_id,
            table_name=self.table,
            batch_id=batch,
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

    def control(self, name, observed, column_name=None, detail=None):
        """S21: control total of one source file (plan 6.3)."""
        source_key, expected, checksum = load_controls()[name]
        sums = self.checksums(source_key)
        now = ", ".join(c[:12] for c in sums) or "none"
        if checksum and checksum not in sums:
            return self._rec(
                "S21",
                status="WARN",
                observed=observed,
                expected=expected,
                source_key=source_key,
                column_name=column_name,
                detail=f"new artifact {now}: check the value in {CONFIG_NAME}, then update CONTROL_CHECKSUMS['{name}']",
            )
        return self.value(
            "S21",
            observed,
            expected,
            source_key=source_key,
            column_name=column_name,
            detail=f"{detail} (control from {CONFIG_NAME}); file checksum {now}"
            + ("" if checksum else " (control checksum not set)"),
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

    def build_record(self, carried_ok_sql=None):
        """S15: the latest succeeded build in build_log wrote this table with this row count. A
        rebuilt table has only that build id; a full-candidate table (registry, id map) may keep
        rows from an earlier build only where carried_ok_sql is true (plan 5.3)."""
        if self.build_id is None:
            self.value("S15", "no succeeded build in build_log", "1 succeeded build", ok=False)
            return
        n = scalar(self.total_sql)
        other = scalar(f"SELECT count(*) FROM {self.table} WHERE NOT ({self.this_build})")
        bad_other = scalar(
            f"SELECT count(*) FROM {self.table} WHERE NOT ({self.this_build})"
            + (f" AND NOT ({carried_ok_sql})" if carried_ok_sql else "")
        )
        ok = self.logged_rows == n and bad_other == 0
        self.value(
            "S15",
            f"build_log {self.logged_rows} rows; table {n} rows, {other} from earlier builds"
            f" ({bad_other} not allowed)",
            f"{n} rows, earlier-build rows only where allowed",
            ok=ok,
        )

    def lineage_not_null(self, cols, where=None):
        """S13: lineage columns not null (on rows of this build, or the rows `where` selects)."""
        cond = " OR ".join(f"{c} IS NULL" for c in cols)
        flt = f" AND ({where})" if where else ""
        self.count(
            "S13",
            f"SELECT count(*) FROM {self.table} WHERE ({cond}){flt}",
            f"SELECT count(*) FROM {self.table} WHERE true{flt}",
            column_name=", ".join(cols),
        )

    def build_inputs_cover(self, refs_sql):
        """S14: every (source_key, file, sheet) the rows point to has exactly one build_inputs row.
        refs_sql returns columns build_id, source_key, source_file, sheet."""
        self.count(
            "S14",
            f"""
            SELECT count(*) FROM (
              SELECT s.source_key, s.source_file, s.sheet, count(v.build_id) AS n
              FROM ({refs_sql}) s
              LEFT JOIN {QUALITY}.v_build_lineage v
                ON v.build_id = s.build_id AND v.target_table = '{self.table}'
               AND v.source_key = s.source_key AND v.source_file = s.source_file AND v.source_sheet <=> s.sheet
              GROUP BY s.source_key, s.source_file, s.sheet) WHERE n <> 1""",
            f"SELECT count(*) FROM ({refs_sql})",
            detail="files or sheets referenced by silver rows without exactly one build_inputs row",
        )

    def freshness(self):
        """S16, per source: the files, sheets and load times in bronze now are the ones the build
        read; and the geography / reference tables are still at the version the build read."""
        for bronze, source_key in DECLARED_INPUTS[self.table]:
            mismatches = scalar(f"""
                WITH now_in_bronze AS (
                  SELECT DISTINCT _source_file AS f, _source_sheet AS s, _ingested_at AS t
                  FROM {BRONZE}.{bronze} WHERE {bronze_scope(bronze, source_key)}),
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
                "S16",
                source_key=source_key,
                fail_count=mismatches + (1 if consumed == 0 else 0),
                total_count=max(consumed, 1),
                detail=None
                if (mismatches == 0 and consumed > 0)
                else "bronze has a new, removed or reloaded file or sheet since the build: rebuild silver",
            )
        stale, soft, skipped = [], [], SELF_INPUTS.get(self.table, set())
        for r in spark.sql(f"""SELECT input_table, input_table_version, content_checksum, input_rows
                               FROM {QUALITY}.build_inputs
                               WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                 AND input_kind <> 'bronze_source'""").collect():
            name = local_name(r["input_table"])
            if name in skipped:
                continue
            if name == GEO and r["content_checksum"]:
                # geography: the snapshot matters, not the Delta version (a merge that changes
                # nothing still writes a version)
                now = scalar(f"SELECT max_by(content_checksum, silver_processed_at) FROM {GEO}")
                if now != r["content_checksum"]:
                    stale.append(f"{name} snapshot {r['content_checksum'][:12]} -> {str(now)[:12]}")
                continue
            now = table_version(name)
            if (
                r["input_table_version"] is not None
                and now is not None
                and now != r["input_table_version"]
            ):
                # a rerun of 00 / 00a with CREATE OR REPLACE writes a new version with the same rows
                rows_now = scalar(f"SELECT count(*) FROM {name}")
                if rows_now != r["input_rows"]:
                    stale.append(f"{name} {r['input_table_version']} -> {now}")
                else:
                    soft.append(f"{name} {r['input_table_version']} -> {now} ({rows_now} rows)")
        self._rec(
            "S16",
            fail_count=len(stale),
            total_count=None,
            column_name="input_table_version",
            detail="; ".join(stale) or None,
        )
        if soft:
            self._rec(
                "S16",
                status="WARN",
                column_name="input_table_version",
                detail="new version, same row count (rebuilt with the same rows?): "
                + "; ".join(soft),
            )

    def ingestion(self):
        """S17, per source (plan 6.3, contract 3.5): every file or sheet in bronze has one load time
        and exactly one processed ingestion_metadata row (same join as the builds)."""
        for bronze, source_key in DECLARED_INPUTS[self.table]:
            r = spark.sql(f"""
                WITH files AS (
                  SELECT _source_file, _source_sheet, count(DISTINCT _ingested_at) AS loads,
                         max(_ingested_at) AS ingested_at
                  FROM {BRONZE}.{bronze} WHERE _source_key = '{source_key}'
                  GROUP BY _source_file, _source_sheet),
                matched AS (
                  SELECT f._source_file, f._source_sheet, f.loads, count(m.batch_id) AS n
                  FROM files f
                  LEFT JOIN {BRONZE}.ingestion_metadata m
                    ON m.source_name = '{source_key}' AND lower(m.status) = 'processed'
                   AND endswith(m.raw_file_path, concat('/', f._source_file))
                   AND m.source_sheet <=> f._source_sheet AND m.retrieved_at = f.ingested_at
                  GROUP BY f._source_file, f._source_sheet, f.loads)
                SELECT count(*) AS total, count_if(loads <> 1 OR n <> 1) AS bad,
                       concat_ws('; ', slice(collect_list(CASE WHEN loads <> 1 OR n <> 1 THEN
                         concat(_source_file, coalesce(concat(' / ', _source_sheet), ''),
                                ' loads=', loads, ' metadata rows=', n) END), 1, 5)) AS detail
                FROM matched""").collect()[0]
            self._rec(
                "S17",
                source_key=source_key,
                fail_count=r["bad"],
                total_count=r["total"],
                detail=r["detail"] or None,
            )

    def reconcile(self, referenced_sql_by_source):
        """S09, per source. row_disposition holds only the rows that were NOT loaded (contract v1.3,
        quality.v_build_reconciliation), so:
             rows the build read (build_inputs.input_rows) = bronze rows now
             rows silver points to = rows read - rows not loaded (merged_into counts as loaded)"""
        for bronze, source_key in DECLARED_INPUTS[self.table]:
            bronze_rows = scalar(
                f"SELECT count(*) FROM {BRONZE}.{bronze} WHERE {bronze_scope(bronze, source_key)}"
            )
            read = scalar(f"""SELECT coalesce(sum(input_rows), 0) FROM {QUALITY}.build_inputs
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND input_kind = 'bronze_source' AND source_key = '{source_key}'""")
            d = spark.sql(f"""SELECT count_if(disposition NOT IN ('loaded', 'merged_into')) AS not_loaded,
                                     count_if(disposition = 'merged_into') AS merged,
                                     count_if(disposition = 'duplicate_of') AS dup,
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
                detail=f"loaded {loaded} (of which merged {d['merged']}), duplicate {d['dup']}, "
                f"dropped {d['dropped']}, quarantined {d['quar']}",
            )

    def quarantined(self, copy_rows=True):
        """S28: quarantined bronze rows, per source, with reasons; copied to quality.quarantine
        (never for restricted sources)."""
        for bronze, source_key in DECLARED_INPUTS[self.table]:
            q = spark.sql(f"""SELECT count(*) AS n,
                                     concat_ws('; ', collect_set(reason)) AS reasons
                              FROM {QUALITY}.row_disposition
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND source_key = '{source_key}' AND disposition = 'quarantined'""").collect()[
                0
            ]
            by_reason = listing(f"""SELECT reason, count(*) FROM {QUALITY}.row_disposition
                                    WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                      AND source_key = '{source_key}' AND disposition = 'quarantined'
                                    GROUP BY reason ORDER BY 2 DESC""")
            self._rec(
                "S28",
                source_key=source_key,
                fail_count=q["n"],
                total_count=scalar(
                    f"SELECT count(*) FROM {BRONZE}.{bronze} WHERE {bronze_scope(bronze, source_key)}"
                ),
                detail=by_reason,
            )
            if copy_rows:
                rows = spark.sql(f"""
                    SELECT b.*, d.reason AS _quarantine_reason FROM {QUALITY}.row_disposition d
                    JOIN {BRONZE}.{bronze} b
                      ON b._source_key = d.source_key AND b._source_file = d.source_file
                     AND b._source_sheet <=> d.source_sheet AND b._source_row_num = d.source_row_num
                    WHERE d.build_id = '{self.build_id}' AND d.target_table = '{self.table}'
                      AND d.source_key = '{source_key}' AND d.disposition = 'quarantined'""")
                self.dq.quarantine(
                    rows,
                    self.table,
                    "S28",
                    "see _quarantine_reason (row_disposition.reason)",
                    key_cols=["_source_file", "_source_sheet", "_source_row_num"],
                    source_table=f"{BRONZE}.{bronze}",
                )

    def psgc_in_geography(self, col="psgc_code", where="true"):
        """S04: every PSGC code is in the latest geography snapshot."""
        self.count(
            "S04",
            f"""SELECT count(*) FROM {self.table} t
                              LEFT ANTI JOIN {latest_geography()} g ON g.psgc_code = t.{col}
                              WHERE t.{col} IS NOT NULL AND {where}""",
            f"SELECT count(*) FROM {self.table} WHERE {col} IS NOT NULL AND {where}",
            column_name=col,
        )


def side_refs(table, side, build_id, source_key=None):
    """Distinct bronze rows referenced by one side of the registry, as (build_id, key, file, sheet, row)."""
    sheet = "_hfsrb_source_sheet" if side == "hfsrb" else "CAST(NULL AS STRING)"
    flt = f" AND _{side}_source_key = '{source_key}'" if source_key else ""
    return f"""SELECT DISTINCT _silver_build_id AS build_id, _{side}_source_key AS source_key,
                      _{side}_source_file AS source_file, {sheet} AS sheet, _{side}_source_row_num AS row_num
               FROM {table} WHERE _silver_build_id = '{build_id}' AND _{side}_source_key IS NOT NULL{flt}"""


# ----------------------------------------------------------------------------------
# facilities_registry_silver
# ----------------------------------------------------------------------------------
NHFR_GROUP = ["_nhfr_source_key", "_nhfr_source_file", "_nhfr_source_row_num", "_nhfr_as_of_date"]
HFSRB_GROUP = [
    "_hfsrb_source_key",
    "_hfsrb_source_file",
    "_hfsrb_source_sheet",
    "_hfsrb_source_row_num",
    "_hfsrb_as_of_date",
]
# metric_groups (plan 5.4): MAP key -> side. Keys whose value names the side ('nhfr:...' /
# 'hfsrb:...') take it from the value.
REG_METRIC_GROUPS = {
    "nhfr_reported_beds": "nhfr",
    "nhfr_licensing_status": "nhfr",
    "hfsrb_abc": "hfsrb",
    "dialysis_stations": "hfsrb",
    "license_valid_until": "hfsrb",
    "blood_service_type": "hfsrb",
    "facility_name": "prefix",
    "ownership": "prefix",
    "service_level": "prefix",
}


def check_registry(dq, profile):
    t = TableQC(dq, REG)
    total_sql = t.total_sql
    t.basics(["facility_key"])
    t.build_record(carried_ok_sql="facility_status = 'not_listed'")
    t.lineage_not_null(
        ["_silver_build_id", "_metric_source_columns", "_first_build_id", "_row_hash"]
    )

    # S19: a side group is filled exactly when that side contributed (plan 5.4, contract section 4)
    def filled(cols):
        return " AND ".join(f"{c} IS NOT NULL" for c in cols)

    def empty(cols):
        return " AND ".join(f"{c} IS NULL" for c in cols)

    t.count(
        "S19",
        f"""SELECT count(*) FROM {REG}
                       WHERE NOT ((in_nhfr AND {filled(NHFR_GROUP)}) OR (NOT in_nhfr AND {empty(NHFR_GROUP)}))
                          OR NOT ((in_hfsrb AND {filled(HFSRB_GROUP)}) OR (NOT in_hfsrb AND {empty(HFSRB_GROUP)}))
                          OR (facility_status = 'listed' AND NOT (in_nhfr OR in_hfsrb))""",
        total_sql,
        column_name="_nhfr_*, _hfsrb_*, in_nhfr, in_hfsrb",
    )
    # S20: every MAP key has a group, and that group is filled on the row
    side_case = (
        "CASE "
        + " ".join(
            f"WHEN m.key = '{k}' THEN "
            + ("split_part(m.value, ':', 1)" if v == "prefix" else f"'{v}'")
            for k, v in REG_METRIC_GROUPS.items()
        )
        + " END"
    )
    t.count(
        "S20",
        f"""SELECT count(*) FROM (
                         SELECT r.in_nhfr, r.in_hfsrb, {side_case} AS side
                         FROM {REG} r LATERAL VIEW explode(r._metric_source_columns) m AS key, value)
                       WHERE side IS NULL OR side NOT IN ('nhfr', 'hfsrb')
                          OR (side = 'nhfr' AND NOT in_nhfr) OR (side = 'hfsrb' AND NOT in_hfsrb)""",
        f"SELECT sum(size(_metric_source_columns)) FROM {REG}",
        column_name="_metric_source_columns",
        detail="keys: " + ", ".join(f"{k}->{v}" for k, v in REG_METRIC_GROUPS.items()),
    )
    if t.build_id:
        refs = f"""SELECT build_id, source_key, source_file, sheet FROM ({side_refs(REG, "nhfr", t.build_id)})
                   UNION SELECT build_id, source_key, source_file, sheet FROM ({side_refs(REG, "hfsrb", t.build_id)})"""
        t.build_inputs_cover(f"SELECT DISTINCT * FROM ({refs})")
        t.freshness()
        t.ingestion()
        t.reconcile(
            lambda sk: (
                f"""SELECT count(*) FROM (
                                     {side_refs(REG, "nhfr" if sk == "doh_nhfr" else "hfsrb", t.build_id, sk)})"""
            )
        )
        t.quarantined()
    t.psgc_in_geography()
    # S05: a facility is placed in a city / municipality. Manila keeps its district code (SubMun,
    # NHFR's level), rolled up to the city where LGUs are compared (plan 11.4).
    t.count(
        "S05",
        level_check(REG, ["City", "Mun", "SubMun"]),
        total_sql,
        column_name="psgc_code, area_key",
        detail="registry facilities need a city / municipality / Manila district code",
    )
    t.count(
        "S06",
        f"""SELECT count(*) FROM {REG}
                       WHERE least(coalesce(nhfr_reported_beds, 0), coalesce(hfsrb_abc, 0), coalesce(authorized_beds, 0),
                                   coalesce(analysis_beds, 0), coalesce(dialysis_stations, 0)) < 0""",
        total_sql,
        column_name="beds, dialysis_stations",
    )
    t.count(
        "S11",
        f"""SELECT count(*) FROM {REG}
                       WHERE facility_category NOT IN ('hospital', 'infirmary', 'primary_care', 'dialysis_clinic')
                          OR match_method NOT IN ('nhfr_id', 'name_municipality', 'nhfr_only', 'hfsrb_only', 'manual')
                          OR coalesce(analysis_beds_basis, 'authorized') NOT IN ('authorized', 'nhfr_reported')
                          OR facility_status NOT IN ('listed', 'not_listed')
                          OR ownership NOT IN ('Government', 'Private')
                          OR geo_resolution_method NOT IN ('source_code', 'name_level_parent', 'name_level_other_region',
                                                           'city_in_province_column', 'exception')""",
        total_sql,
        column_name="facility_category, match_method, analysis_beds_basis, facility_status, ownership, "
        "geo_resolution_method",
    )
    t.count(
        "S18",
        f"""SELECT count(*) FROM (SELECT nhfr_id FROM {REG} WHERE nhfr_id IS NOT NULL
                                             GROUP BY nhfr_id HAVING count(*) > 1)""",
        f"SELECT count(DISTINCT nhfr_id) FROM {REG}",
        column_name="nhfr_id",
    )
    # S23 (plan 2.8): authorized = ABC; analysis = ABC else NHFR; the basis names the side used
    t.count(
        "S23",
        f"""SELECT count(*) FROM {REG}
                       WHERE NOT (authorized_beds <=> hfsrb_abc)
                          OR NOT (analysis_beds <=> coalesce(hfsrb_abc, nhfr_reported_beds))
                          OR NOT (analysis_beds_basis <=> CASE WHEN hfsrb_abc IS NOT NULL THEN 'authorized'
                                                               WHEN nhfr_reported_beds IS NOT NULL THEN 'nhfr_reported' END)""",
        total_sql,
        column_name="authorized_beds, analysis_beds, analysis_beds_basis",
    )
    t.control(
        "nhfr_facilities",
        scalar(f"SELECT count(*) FROM {REG} WHERE in_nhfr AND {t.this_build}"),
        column_name="in_nhfr",
        detail="NHFR facilities in the registry = NHFR rows",
    )
    t.control(
        "nhfr_beds",
        scalar(f"SELECT sum(nhfr_reported_beds) FROM {REG} WHERE in_nhfr AND {t.this_build}"),
        column_name="nhfr_reported_beds",
        detail="sum of NHFR Bed_Capacity",
    )
    if profile:
        dq.profile_table(REG, exclude=("_silver_build_id", "_row_hash"))


# ----------------------------------------------------------------------------------
# facilities_id_map_silver
# ----------------------------------------------------------------------------------
def check_id_map(dq, profile):
    t = TableQC(dq, IDMAP)
    total_sql = t.total_sql
    t.basics(["_source_key", "source_record_id"])
    t.build_record(
        carried_ok_sql="true"
    )  # identifiers not read again keep their last build (plan 2.6)
    t.lineage_not_null(
        [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_source_row_num",
            "_as_of_date",
            "facility_key",
            "_first_build_id",
        ]
    )
    t.count(
        "S13",
        f"""SELECT count(*) FROM {IDMAP} WHERE _source_key <> 'doh_nhfr' AND _source_sheet IS NULL""",
        f"SELECT count(*) FROM {IDMAP} WHERE _source_key <> 'doh_nhfr'",
        column_name="_source_sheet",
        detail="HFSRB identifiers come from workbook sheets",
    )
    if t.build_id:
        t.build_inputs_cover(f"""SELECT DISTINCT _silver_build_id AS build_id, _source_key AS source_key,
                                        _source_file AS source_file, _source_sheet AS sheet
                                 FROM {IDMAP} WHERE {t.this_build}""")
        t.freshness()
        t.ingestion()
    t.count(
        "S11",
        f"""SELECT count(*) FROM {IDMAP}
                       WHERE match_status NOT IN ('matched', 'new_facility', 'ambiguous_code_own_facility',
                                                  'service_of_existing_facility', 'candidate', 'ambiguous')
                          OR match_method NOT IN ('nhfr_id', 'name_municipality', 'manual', 'new')
                          OR _source_key NOT IN ('doh_nhfr', 'doh_hfsrb_hospitals', 'doh_hfsrb_infirmaries',
                                                 'doh_hfsrb_primary_care', 'doh_hfsrb_dialysis_clinics')""",
        total_sql,
        column_name="match_status, match_method, _source_key",
    )
    # S22: every id map key is a registry facility, and every registry facility has an identifier
    if spark.catalog.tableExists(REG):
        t.count(
            "S22",
            f"""SELECT count(*) FROM (SELECT DISTINCT facility_key FROM {IDMAP}) m
                           LEFT ANTI JOIN {REG} r ON r.facility_key = m.facility_key""",
            f"SELECT count(DISTINCT facility_key) FROM {IDMAP}",
            column_name="facility_key",
            detail="id map keys missing from the registry",
        )
        t.count(
            "S22",
            f"""SELECT count(*) FROM {REG} r
                           LEFT ANTI JOIN {IDMAP} m ON m.facility_key = r.facility_key""",
            f"SELECT count(*) FROM {REG}",
            column_name="facility_key",
            detail="registry facilities without an identifier in the id map",
        )
    if profile:
        dq.profile_table(IDMAP, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# facilities_metric_silver
# ----------------------------------------------------------------------------------
MEASURES = [
    "hospitals",
    "authorized_beds",
    "bhs",
    "rhu",
    "mhc",
    "chc",
    "health_centers_total",
    "barangays",
    "population",
]


def check_metric(dq, profile):
    t = TableQC(dq, MET)
    total_sql = t.total_sql
    t.basics(["area_key", "year", "ownership", "_source_key"])
    t.build_record()
    t.lineage_not_null(
        [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_source_row_num",
            "_as_of_date",
            "_metric_source_columns",
        ]
    )
    # S20: every MAP key is a measure column of the table
    t.count(
        "S20",
        f"""SELECT count(*) FROM (SELECT explode(map_keys(_metric_source_columns)) AS k FROM {MET})
                       WHERE k NOT IN ({", ".join(f"'{m}'" for m in MEASURES)})""",
        f"SELECT sum(size(_metric_source_columns)) FROM {MET}",
        column_name="_metric_source_columns",
    )
    if t.build_id:
        t.build_inputs_cover(f"""SELECT DISTINCT _silver_build_id AS build_id, _source_key AS source_key,
                                        _source_file AS source_file, _source_sheet AS sheet
                                 FROM {MET} WHERE {t.this_build}""")
        t.freshness()
        t.ingestion()
        t.reconcile(
            lambda sk: (
                f"""SELECT count(*) FROM (SELECT DISTINCT _source_file, _source_sheet, _source_row_num
                                                         FROM {MET} WHERE _source_key = '{sk}')"""
            )
        )
        t.quarantined()
    t.psgc_in_geography()
    t.count(
        "S05",
        level_check(MET, ["Reg", "Prov", "City", "Mun"], "^(ph|hist:[a-z_]+|sga:[a-z]+)$"),
        total_sql,
        column_name="psgc_code, area_key",
        detail="region, province or city / municipality code, or a named key",
    )
    t.count(
        "S06",
        f"SELECT count(*) FROM {MET} WHERE least({', '.join(f'coalesce({m}, 0)' for m in MEASURES)}) < 0",
        total_sql,
        column_name=", ".join(MEASURES),
    )
    t.count(
        "S08",
        f"""SELECT count(*) FROM {MET}
                       WHERE year NOT BETWEEN {YEAR_FLOOR["metric"]} AND year(current_date())
                          OR (_source_key = 'doh_fhsis_demographic'
                              AND year < {YEAR_FLOOR["doh_fhsis_demographic"]})""",
        total_sql,
        column_name="year",
    )
    t.count(
        "S11",
        f"""SELECT count(*) FROM {MET}
                       WHERE ownership NOT IN ('total', 'government', 'private')
                          OR coalesce(series_definition, 'none') NOT IN ('none', 'hospitals_incl_infirmaries',
                                                                          'general_and_specialty_hospitals')
                          OR NOT area_key RLIKE '^(psgc:[0-9]{{10}}|ph|hist:[a-z_]+|sga:[a-z]+)$'
                          OR (is_break_year AND year <> {int(t.param("hospital_definition_break_year"))})""",
        total_sql,
        column_name="ownership, series_definition, area_key, is_break_year",
    )
    # S26 (plan 4.3): FHSIS region row = its provinces (without their listed cities) + listed cities,
    # per file (one file per year), for bhs and barangays
    spark.sql(f"""
        WITH f AS (SELECT * FROM {MET} WHERE _source_key = 'doh_fhsis_demographic'
                     AND region_as_published IS NOT NULL),
        is_region AS (SELECT *, coalesce(psgc_code LIKE '__00000000', false) AS region_row FROM f),
        parts AS (
          SELECT _source_file, year, region_as_published,
                 sum(bhs) AS bhs, count_if(bhs IS NULL) AS bhs_missing,
                 sum(barangays) AS barangays, count_if(barangays IS NULL) AS barangays_missing,
                 count(*) AS n_parts
          FROM is_region WHERE NOT region_row AND area_key <> 'ph'
          GROUP BY _source_file, year, region_as_published),
        cmp AS (
          SELECT r.year, r.region_as_published AS region, 'bhs' AS measure, r.bhs AS published,
                 p.bhs AS parts, p.bhs_missing = 0 AND r.bhs IS NOT NULL AS all_parts, p.n_parts
          FROM is_region r JOIN parts p
            ON p._source_file = r._source_file AND p.year = r.year AND p.region_as_published = r.region_as_published
          WHERE r.region_row
          UNION ALL
          SELECT r.year, r.region_as_published, 'barangays', r.barangays,
                 p.barangays, p.barangays_missing = 0 AND r.barangays IS NOT NULL, p.n_parts
          FROM is_region r JOIN parts p
            ON p._source_file = r._source_file AND p.year = r.year AND p.region_as_published = r.region_as_published
          WHERE r.region_row)
        SELECT * FROM cmp""").createOrReplaceTempView("fac_qc_fhsis_region")
    t.count(
        "S26",
        "SELECT count(*) FROM fac_qc_fhsis_region WHERE all_parts AND published <> parts",
        "SELECT count(*) FROM fac_qc_fhsis_region WHERE all_parts",
        source_key="doh_fhsis_demographic",
        column_name="bhs, barangays",
        detail=listing("""SELECT year, region, measure, published, 'vs', parts FROM fac_qc_fhsis_region
                              WHERE all_parts AND published <> parts ORDER BY year, region"""),
    )
    if profile:
        dq.profile_table(MET, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# facilities_bed_occupancy_silver (restricted). Source since 2026-10-14: doh_foi_hospital_beds
# (2018-2025, both ownerships, city / municipality, bed days); private_only_year no longer exists.
# ----------------------------------------------------------------------------------
def check_bed_occupancy(dq, profile):
    t = TableQC(dq, BOR)
    total_sql = t.total_sql
    # build settings of 03 (rule 2a): the baseline maximum and the sheets (years) it expects
    v = float(t.param("bor_baseline_max"))
    BOR_BASELINE_MAX = int(v) if v.is_integer() else v
    bor_years = sorted(int(y) for y in t.param("bor_expected_sheets"))
    t.basics(["_source_key", "_source_file", "_source_sheet", "_source_row_num"])
    t.build_record()
    t.lineage_not_null(
        [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_source_sheet",
            "_source_row_num",
            "_as_of_date",
            "_metric_source_columns",
        ]
    )
    if t.build_id:
        t.build_inputs_cover(f"""SELECT DISTINCT _silver_build_id AS build_id, _source_key AS source_key,
                                        _source_file AS source_file, _source_sheet AS sheet
                                 FROM {BOR} WHERE {t.this_build}""")
        t.freshness()
        t.ingestion()
        t.reconcile(
            lambda sk: (
                f"""SELECT count(*) FROM (SELECT DISTINCT _source_file, _source_sheet, _source_row_num
                                                         FROM {BOR} WHERE _source_key = '{sk}')"""
            )
        )
        t.quarantined(copy_rows=False)  # restricted source: no row copies outside silver
    t.psgc_in_geography()
    t.count(
        "S05",
        level_check(BOR, ["Prov", "City", "Mun", "SubMun"], "^(hist:[a-z_]+|ncr-district:[1-4])$"),
        total_sql,
        column_name="psgc_code, area_key",
        detail="province or city / municipality code, or a named key",
    )
    t.control(
        "bor_rows",
        scalar(total_sql),
        detail="bed occupancy data rows (anonymous records, never de-duplicated)",
    )
    t.count(
        "S06",
        f"""SELECT count(*) FROM {BOR}
                       WHERE (bor_pct < 0 AND coalesce(exclusion_reason, '') <> 'bor_negative')
                          OR authorized_beds < 0 OR implementing_beds < 0 OR inpatient_bed_days < 0""",
        total_sql,
        column_name="bor_pct, authorized_beds, implementing_beds, inpatient_bed_days",
    )
    t.count(
        "S08",
        f"SELECT count(*) FROM {BOR} WHERE year NOT IN ({', '.join(str(y) for y in bor_years)})",
        total_sql,
        column_name="year",
        detail=f"years = bor_expected_sheets of the build: {bor_years}",
    )
    t.count(
        "S11",
        f"""SELECT count(*) FROM {BOR}
                       WHERE sharing <> 'restricted'
                          OR ownership NOT IN ('government', 'private')
                          OR coalesce(service_level, 'Level 1') NOT IN ('Level 1', 'Level 2', 'Level 3')
                          OR coalesce(exclusion_reason, 'none') NOT IN ('none', 'bor_null', 'bor_negative', 'bor_gt_150',
                                                                         'level_missing', 'exact_duplicate')
                          OR bor_bed_basis NOT IN ('authorized', 'implementing')
                          OR hospital_type NOT IN ('General', 'Specialty') OR hospital_type IS NULL""",
        total_sql,
        column_name="sharing, ownership, service_level, exclusion_reason, bor_bed_basis, hospital_type",
    )
    # S24 (plan 3.3): eligibility is derived from exclusion_reason, and each reason matches the data
    t.count(
        "S24",
        f"""SELECT count(*) FROM {BOR}
                       WHERE NOT (baseline_eligible <=> (exclusion_reason IS NULL))
                          OR (exclusion_reason = 'bor_null' AND bor_pct IS NOT NULL)
                          OR (exclusion_reason = 'bor_gt_150' AND NOT bor_pct > {BOR_BASELINE_MAX})
                          OR (exclusion_reason = 'level_missing'
                              AND (nullif(trim(service_level), '') IS NOT NULL OR hospital_type <> 'General'))
                          OR (exclusion_reason IS NULL AND (bor_pct IS NULL OR bor_pct > {BOR_BASELINE_MAX}
                                                            OR (hospital_type = 'General'
                                                                AND nullif(trim(service_level), '') IS NULL)))
                          OR NOT (is_bor_over_100 <=> (bor_pct > 100))""",
        total_sql,
        column_name="baseline_eligible, exclusion_reason, is_bor_over_100",
        detail=listing(
            f"SELECT coalesce(exclusion_reason, 'eligible'), count(*) FROM {BOR} GROUP BY 1 ORDER BY 2 DESC"
        ),
    )
    t.count(
        "S25",
        f"SELECT count(*) FROM {BOR} WHERE bor_pct > 100",
        f"SELECT count(*) FROM {BOR} WHERE bor_pct IS NOT NULL",
        column_name="bor_pct",
        detail=listing(f"""SELECT year, CASE WHEN bor_pct > {BOR_BASELINE_MAX} THEN 'above {BOR_BASELINE_MAX}'
                                                ELSE '100 to {BOR_BASELINE_MAX}' END, count(*)
                               FROM {BOR} WHERE bor_pct > 100 GROUP BY 1, 2 ORDER BY 1, 2"""),
    )
    # no profile: a column profile would copy min / max values of a restricted source


# ----------------------------------------------------------------------------------
# facilities_osm_point_silver
# ----------------------------------------------------------------------------------
def check_osm_point(dq, profile):
    t = TableQC(dq, OSM)
    total_sql = t.total_sql
    lon_min, lat_min, lon_max, lat_max = (
        float(v) for v in t.param("ph_bbox")
    )  # 04 setting (rule 2a)
    t.basics(["osm_type", "osm_id"])
    t.build_record()
    t.lineage_not_null(
        [
            "_silver_build_id",
            "_source_key",
            "_source_file",
            "_source_row_num",
            "_as_of_date",
            "_metric_source_columns",
        ]
    )
    if t.build_id:
        t.build_inputs_cover(f"""SELECT DISTINCT _silver_build_id AS build_id, _source_key AS source_key,
                                        _source_file AS source_file, _source_sheet AS sheet
                                 FROM {OSM} WHERE {t.this_build}""")
        t.freshness()
        t.ingestion()
        t.reconcile(
            lambda sk: (
                f"""SELECT count(*) FROM (SELECT DISTINCT _source_file, _source_sheet, _source_row_num
                                                         FROM {OSM} WHERE _source_key = '{sk}')"""
            )
        )
        t.quarantined()
    t.psgc_in_geography()
    t.count(
        "S05",
        level_check(OSM, ["City", "Mun"]),
        total_sql,
        column_name="psgc_code, area_key",
        detail="OSM points are placed in a city / municipality boundary",
    )
    t.count(
        "S11",
        f"""SELECT count(*) FROM {OSM}
                       WHERE location_precision NOT IN ('point', 'municipality')
                          OR (location_precision = 'point') <> (coordinate_status = 'ok')
                          OR (location_precision = 'point' AND (longitude NOT BETWEEN {lon_min} AND {lon_max}
                                                                OR latitude NOT BETWEEN {lat_min} AND {lat_max}))
                          OR (location_precision = 'municipality' AND (longitude IS NOT NULL OR latitude IS NOT NULL))
                          OR geo_resolution_method NOT IN ('point_in_polygon', 'nearest_boundary', 'exception', 'addr_city_name')
                          OR (geo_resolution_method IN ('point_in_polygon', 'nearest_boundary')) <> (location_precision = 'point')
                          OR sharing <> 'open' OR NOT license LIKE 'ODbL%'""",
        total_sql,
        column_name="location_precision, coordinates, geo_resolution_method, sharing, license",
    )
    t.count("S06", f"SELECT count(*) FROM {OSM} WHERE beds < 0", total_sql, column_name="beds")
    t.count(
        "S27",
        f"SELECT count(*) FROM {OSM} WHERE location_precision = 'municipality'",
        total_sql,
        column_name="location_precision",
        detail="placed by addr:city only (no coordinates); expected near 0 with the GeoJSON-derived file (D12)",
    )
    t.count(
        "S27",
        f"SELECT count(*) FROM {OSM} WHERE addr_city_conflict",
        total_sql,
        column_name="addr_city_conflict",
        detail=listing(f"""SELECT geo_name_source, count(*) FROM {OSM} WHERE addr_city_conflict
                               GROUP BY 1 ORDER BY 2 DESC"""),
    )
    if profile:
        dq.profile_table(OSM, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------
TABLE_CHECKS = {
    "registry": (REG, check_registry),
    "id_map": (IDMAP, check_id_map),
    "metric": (MET, check_metric),
    "bed_occupancy": (BOR, check_bed_occupancy),
    "osm_point": (OSM, check_osm_point),
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
            except Exception as e:  # noqa: BLE001
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
