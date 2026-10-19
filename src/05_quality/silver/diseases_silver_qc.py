# =============================================================================
# Runs QC on the published diseases Silver tables.
#
# All results go through dq_utils.DQRun into public_health.quality:
#   - qc_results
#   - run_log
#   - table_stats
#   - profile
#   - quarantine
#
# The script raises at the end if any check has status = FAIL.
#
#
# When it runs:
#   Run after diseases_silver_00 ... diseases_silver_06 and before Gold.
#
#   The Silver build files have their own hard gates.
#   This script checks the published tables and records the QC results.
#
#   Some cross-source checks are WARN only.
#   They highlight source disagreements or gaps without blocking the pipeline.
#
#
# Tables checked:
#   public_health.silver.diseases_metric_silver
#   public_health.silver.diseases_deaths_age_silver
#   public_health.silver.diseases_hospital_encounters_silver
#   public_health.silver.diseases_source_coverage_silver
#   public_health.silver.diseases_tb_programme_silver
#   public_health.silver.diseases_hospital_claims_silver
#
# Restricted tables:
#   diseases_hospital_encounters_silver
#   diseases_hospital_claims_silver
#
#   Restricted by our own commitment in each request (D-47): academic use, reported in
#   aggregate only; gold suppresses cells built from fewer than 3 records or hospitals.
#   For restricted tables, record counts only.
#   Do not write column profiles or quarantine copies (no row leaves the table).
#
#
# Reference table:
#   public_health.silver.geography_silver
#
#   Used by S49 and S50 to validate PSGC codes and geography levels.
#   These checks use only the latest geography snapshot.
#
#
# QC lineage:
#   batch_id = build:<build_id> of the Silver build that created the table.
#
#   For checks tied to one source:
#     source_key = that source
#
#   capture_table_stats() records the Delta table version checked.
#
#   See lineage-qc-contract.md, section 8.
#
#
# Run examples:
#   python diseases_silver_qc.py
#
#   python diseases_silver_qc.py \
#       --tables metric,deaths_age
#
#   python diseases_silver_qc.py \
#       --fail_on_error false
#
#   python diseases_silver_qc.py \
#       --geography_table silver.geography_silver
#
#
# Check codes:
#   S01-S12
#     Shared Silver QC codes from quality_registry_seed.sql.
#
#   S30-S50
#     Diseases-specific QC codes defined in this script.
#
#   Add all diseases-specific codes to quality_registry_seed.sql before using
#   DQRun with strict_registry=True.
#
#
# Severity:
#   FAIL
#     The published table is incorrect, incomplete or not traceable.
#     FAIL blocks the pipeline when fail_on_error=True.
#
#   WARN
#     The Silver table correctly reflects the source, but the source data has
#     a disagreement, gap or issue that needs review.
#
#
# Important behavior:
#   - S09 counts merged_into rows as loaded, matching quality.v_build_reconciliation.
#
#   - S09 and S33 reconcile by Bronze table, not only by source_key.
#     This is required because TB programme reads two Bronze tables that both use
#     source_key = doh_fhsis.
#
#   - S12 on diseases_hospital_claims_silver checks the share of claims whose
#     hospital has no facility_key. It becomes WARN above 10%.
#
#   - S34 records FAIL with observed = None when its control query returns no row.
#     Other checks continue to run.
#
#   - S45 writes quarantine rows through dq_utils.
#     dq_utils replaces the previous quarantine state for the same check scope.
#
#   - Metric profiling excludes value_lower and value_upper because of the
#     IHME licence.
#
#   - S49 and S50 use the latest geography snapshot only.
#
#   - S08 checks weekly rows as ISO weeks (2026-10-19, D-44 and D-46):
#       HDX      period_basis iso_week_ending_date, period_key = the date that closes the week
#       UP NOAH  period_basis iso_week, period_key yyyy-Www
#     Both: 7 days, week 1 to 52 / 53 of the ISO year, week and year = ISO week and year of
#     period_end. The old values week_number_unconfirmed and source_date_unconfirmed now fail S08.
# =============================================================================

import argparse
import os
import sys

from pyspark.sql import SparkSession


# ----------------------------------------------------------------------------------
# Find dq_utils.py (same search as the bronze QC scripts)
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
                    candidates += [os.path.join(base, d) for d in sorted(os.listdir(base))
                                   if "quality" in d.lower() and os.path.isdir(os.path.join(base, d))]
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
        "the quality folder. Looked in:\n  " + "\n  ".join(dict.fromkeys(searched)))


_add_dq_utils_to_path()
from dq_utils import DQRun  # noqa: E402

DOMAIN = "diseases"
SCRIPT_NAME = "diseases_silver_qc.py"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", default="public_health", help="'' gives two-part names (local tests)")
    p.add_argument("--tables", default="ALL",
                   help="ALL, or any of: metric,deaths_age,hospital_encounters,coverage,tb_programme,hospital_claims")
    p.add_argument("--fail_on_error", default="true", help="false = record results but do not raise")
    p.add_argument("--profile", default="true", help="Also write a column profile (never for restricted tables)")
    p.add_argument("--geography_table", default="silver.geography_silver",
                   help="schema.table of the PSGC geography table, without the catalog")
    p.add_argument("--job_run_id", default=None, help="Pass {{job.run_id}} from a Databricks job")
    p.add_argument("--code_version", default=None)
    a, _ = p.parse_known_args()
    return a


ARGS = parse_args()
PREFIX = f"{ARGS.catalog}." if ARGS.catalog else ""
BRONZE, SILVER, QUALITY = f"{PREFIX}bronze", f"{PREFIX}silver", f"{PREFIX}quality"
METRIC = f"{SILVER}.diseases_metric_silver"
AGE = f"{SILVER}.diseases_deaths_age_silver"
ENC = f"{SILVER}.diseases_hospital_encounters_silver"
COV = f"{SILVER}.diseases_source_coverage_silver"
TBP = f"{SILVER}.diseases_tb_programme_silver"
CLM = f"{SILVER}.diseases_hospital_claims_silver"
DIRECTORY = f"{SILVER}.diseases_directory_silver"
AGG = f"{SILVER}.diseases_cause_aggregation"
GEOGRAPHY = f"{PREFIX}{ARGS.geography_table}"

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
    "S10": ("metric totals preserved", "RECONCILIATION", "FAIL"),
    "S12": ("metric null rate under threshold", "COMPLETENESS", "WARN"),
    # diseases codes
    "S30": ("lineage columns not null", "COMPLETENESS", "FAIL"),
    "S31": ("every lineage reference has one build input", "CONSISTENCY", "FAIL"),
    "S32": ("table written by one succeeded build", "CONSISTENCY", "FAIL"),
    "S33": ("silver built from the current bronze loads", "CONSISTENCY", "FAIL"),
    "S34": ("control values match", "RECONCILIATION", "FAIL"),
    "S35": ("modelled value within its bounds", "VALIDITY", "FAIL"),
    "S36": ("value, status and definitions consistent", "VALIDITY", "FAIL"),
    "S37": ("disease and area keys resolve", "VALIDITY", "FAIL"),
    "S38": ("aggregation set sums to all causes", "RECONCILIATION", "FAIL"),
    "S39": ("aggregation set members do not overlap", "CONSISTENCY", "FAIL"),
    "S40": ("months sum to the published year total", "CONSISTENCY", "WARN"),
    "S41": ("country equals regions plus foreign", "CONSISTENCY", "WARN"),
    "S42": ("national totals agree between PSA tables", "CONSISTENCY", "WARN"),
    "S43": ("weekly series has no gaps", "COMPLETENESS", "WARN"),
    "S44": ("dengue sources agree on a common basis", "CONSISTENCY", "WARN"),
    "S45": ("quarantined rows are the reviewed kind only", "VALIDITY", "FAIL"),
    "S46": ("age groups sum to the metric total", "RECONCILIATION", "FAIL"),
    "S47": ("hospital encounter review flags", "VALIDITY", "WARN"),
    "S48": ("coverage table matches the metric table", "CONSISTENCY", "FAIL"),
    "S49": ("mapped area codes exist in geography silver", "VALIDITY", "FAIL"),
    "S50": ("source-printed area codes agree with geography silver", "CONSISTENCY", "WARN"),
}

# Control values: the same numbers bronze QC checks (sources_diseases.yaml), read from silver.
CONTROLS = [
    # (label, sql returning one number, expected)
    *[(f"DOH FOI dengue cases {y}",
       f"SELECT sum(value) FROM {METRIC} WHERE _source_key = 'doh_foi_dengue' AND measure = 'cases' AND year = {y}", n)
      for y, n in [(2021, 80919), (2022, 264390), (2023, 214638), (2024, 413960), (2025, 240540)]],
    *[(f"PSA all-cause deaths {y} (monthly table, year row)",
       f"SELECT value FROM {METRIC} WHERE _source_key = 'psa_deaths_national_monthly' AND disease_key = 'all_causes' "
       f"AND period_grain = 'year' AND year = {y}", n)
      for y, n in [(2020, 613936), (2021, 879429), (2022, 679766), (2023, 694821), (2024, 701884)]],
    *[(f"FHSIS TB notifications, all forms, Philippines {y}",
       f"SELECT value FROM {METRIC} WHERE _source_key = 'doh_fhsis' AND disease_key = 'tb_all_forms' "
       f"AND area_key = 'ph' AND year = {y}", n)
      for y, n in [(2024, 544948), (2025, 535254)]],
]

# Expected inputs per silver table: (bronze table, _source_key). Step 1 of the freshness check.
DECLARED_INPUTS = {
    METRIC: [("diseases_doh_foi_dengue_bronze", "doh_foi_dengue"),
             ("diseases_upnoah_dengue_regional_bronze", "upnoah"),
             ("diseases_hdx_dengue_bronze", "hdx_dengue"),
             ("diseases_psa_deaths_national_monthly_bronze", "psa_deaths_national_monthly"),
             ("diseases_psa_deaths_region_annual_bronze", "psa_deaths_region_annual"),
             ("diseases_psa_deaths_national_annual_bronze", "psa_deaths_national_annual"),
             ("diseases_fhsis_tb_bronze", "doh_fhsis"),
             ("diseases_ihme_gbd_bronze", "ihme_gbd")],
    AGE: [("diseases_psa_deaths_region_annual_bronze", "psa_deaths_region_annual")],
    ENC: [("diseases_davao_hospital_pneumonia_bronze", "davao_hospital_pneumonia")],
    TBP: [("diseases_fhsis_tb_tpt_bronze", "doh_fhsis"),
          ("diseases_fhsis_tb_treatment_success_bronze", "doh_fhsis")],
    CLM: [("diseases_philhealth_claims_hospital_bronze", "philhealth_foi_claims_hospital")],
}

# TB programme controls: Philippines, all ages, both sexes (FHSIS 2025 workbook, verified against
# the printed national rows on 2026-10-14). The year belongs to the control, not to the SQL.
TBP_CONTROL_YEAR = 2025
TBP_CONTROLS = [("tpt_given", "not_applicable", 120108), ("tpt_eligible_contacts", "not_applicable", 1498711.2),
                ("treatment_cohort", "drug_susceptible", 414185), ("treatment_success", "drug_susceptible", 382547),
                ("treatment_cohort", "drug_resistant", 7721), ("treatment_success", "drug_resistant", 5030)]
# TODO (rule 2a): CONTROLS, TBP_CONTROLS and CLM_CONTROLS repeat values that bronze QC reads from
# sources_diseases.yaml. Read them from the YAML instead (pending the current repo copy of the file).

# PhilHealth claims: sum of Claims Count per admission year, all rows (sources_diseases.yaml entry 19,
# qc.control_totals). Silver holds these minus the quarantined rows (blank illness).
CLM_CONTROLS = {2016: 1709849, 2017: 1626227, 2018: 1706320, 2019: 2018226, 2020: 804669,
                2021: 622815, 2022: 920348, 2023: 1177840, 2024: 1451867, 2025: 1540811}

LINEAGE_ALWAYS = ["_silver_build_id", "_source_key", "_source_file", "_source_row_num", "_as_of_date"]

# S08 sanity floor per table: a year below it can only be a parse error. Set to the earliest year
# each table's sources cover; the ceiling is always the current year.
YEAR_FLOOR = {"metric": 2000, "tb_programme": 2015, "hospital_claims": 2016}

# S44: UP NOAH has no Negros Island Region, so these region keys (VI, VII, NIR) are compared as one
# combined area. A known exception of the source, not a count.
UPNOAH_COMBINED_REGIONS = ("psgc:0600000000", "psgc:0700000000", "psgc:1800000000")

# Sources whose PSGC code is printed in the source file. Every other source gets its code from
# diseases_area_map, which build_diseases_reference_maps.py already checks against geography.
SOURCE_PRINTED_AREA_CODES = ("doh_fhsis",)

# Silver geo_level -> the geographic_level values geography silver may hold for that code.
# Same mapping as GEO_LEVELS in build_diseases_reference_maps.py.
GEO_LEVELS = {"region": ("Reg",), "province": ("Prov",), "city": ("City",), "municipality": ("Mun",),
              "city_municipality": ("City", "Mun")}


# ----------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------
def scalar(sql):
    rows = spark.sql(sql).collect()
    return rows[0][0] if rows else None


def same_number(a, b):
    if a is None or b is None:
        return a is None and b is None
    return abs(float(a) - float(b)) < 0.0005


class TableQC:
    """Checks for one silver table. Every result carries build:<build_id> of the table's build."""

    def __init__(self, dq, table):
        self.dq, self.table = dq, table
        ids = [r[0] for r in spark.sql(f"SELECT DISTINCT _silver_build_id FROM {table}").collect()]
        self.build_ids = ids
        self.build_id = ids[0] if len(ids) == 1 else None
        self.batch = f"build:{self.build_id}" if self.build_id else None

    def _rec(self, check_id, **kw):
        name, ctype, severity = CHECKS[check_id]
        return self.dq.record(check_id, table_name=self.table, batch_id=self.batch,
                              check_name=name, check_type=ctype, severity=severity, **kw)

    def count(self, check_id, fail_sql, total_sql=None, **kw):
        """A check that counts failing rows (or groups). PASS when the count is 0."""
        fail = scalar(fail_sql) or 0
        total = scalar(total_sql) if total_sql else None
        return self._rec(check_id, fail_count=fail, total_count=total, **kw)

    def value(self, check_id, observed, expected, ok=None, **kw):
        """A check that compares one observed value with an expected one."""
        ok = same_number(observed, expected) if ok is None else ok
        return self._rec(check_id, status="PASS" if ok else CHECKS[check_id][2],
                         observed=observed, expected=expected, **kw)

    # ---- checks shared by the tables ---------------------------------------------
    def basics(self, key):
        total = self.dq.capture_table_stats(self.table)
        self.value("S01", total, "> 0", ok=total > 0)
        self.count("S02", f"SELECT count(*) FROM {self.table} WHERE " + " OR ".join(f"{c} IS NULL" for c in key),
                   f"SELECT count(*) FROM {self.table}", column_name=", ".join(key))
        self.count("S03", f"""SELECT count(*) FROM (SELECT 1 FROM {self.table}
                                                    GROUP BY {', '.join(key)} HAVING count(*) > 1)""",
                   f"SELECT count(*) FROM {self.table}", column_name=", ".join(key))
        return total

    def build_record(self):
        """S32: one build id in the table, and that build is in build_log as succeeded with the same row count."""
        if self.build_id is None:
            self.value("S32", f"{len(self.build_ids)} build ids in the table", "1", ok=False)
            return
        rows = spark.sql(f"""SELECT status, row_count FROM {QUALITY}.build_log
                             WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'""").collect()
        n = scalar(f"SELECT count(*) FROM {self.table}")
        ok = len(rows) == 1 and rows[0]["status"] == "succeeded" and rows[0]["row_count"] == n
        self.value("S32", f"{len(rows)} build_log row(s)" + (f", {rows[0]['status']}, {rows[0]['row_count']} rows" if rows else ""),
                   f"1 row, succeeded, {n} rows", ok=ok)

    def lineage(self, sheet_nullable=True, extra=()):
        cols = LINEAGE_ALWAYS + list(extra) + ([] if sheet_nullable else ["_source_sheet"])
        self.count("S30", f"SELECT count(*) FROM {self.table} WHERE " + " OR ".join(f"{c} IS NULL" for c in cols),
                   f"SELECT count(*) FROM {self.table}", column_name=", ".join(cols))
        # S31: every (source, file, sheet) the rows point to has exactly one row in build_inputs.
        self.count("S31", f"""
            SELECT count(*) FROM (
              SELECT s._source_key, s._source_file, s._source_sheet, count(v.build_id) AS n
              FROM (SELECT DISTINCT _silver_build_id, _source_key, _source_file, _source_sheet FROM {self.table}) s
              LEFT JOIN {QUALITY}.v_build_lineage v
                ON v.build_id = s._silver_build_id AND v.target_table = '{self.table}'
               AND v.source_key = s._source_key AND v.source_file = s._source_file AND v.source_sheet <=> s._source_sheet
              GROUP BY s._source_key, s._source_file, s._source_sheet) WHERE n <> 1""",
                   f"SELECT count(*) FROM (SELECT DISTINCT _source_key, _source_file, _source_sheet FROM {self.table})",
                   detail="files or sheets referenced by silver rows without exactly one build_inputs row")

    def freshness(self):
        """S33, per source: the files, sheets and load times in bronze now are the ones the build read.
        A new file, a removed file or a reload all count as a mismatch: rebuild silver."""
        for bronze_short, source_key in DECLARED_INPUTS[self.table]:
            bronze = f"{BRONZE}.{bronze_short}"
            mismatches = scalar(f"""
                WITH now_in_bronze AS (
                  SELECT DISTINCT _source_file AS f, _source_sheet AS s, _ingested_at AS t
                  FROM {bronze} WHERE _source_key = '{source_key}'),
                consumed AS (
                  SELECT source_file AS f, source_sheet AS s, ingested_at AS t
                  FROM {QUALITY}.build_inputs
                  WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                    AND input_kind = 'bronze_source' AND source_key = '{source_key}'
                    AND input_table = '{bronze}')
                SELECT (SELECT count(*) FROM now_in_bronze b LEFT ANTI JOIN consumed c
                          ON c.f = b.f AND c.s <=> b.s AND c.t = b.t)
                     + (SELECT count(*) FROM consumed c LEFT ANTI JOIN now_in_bronze b
                          ON c.f = b.f AND c.s <=> b.s AND c.t = b.t)""")
            consumed = scalar(f"""SELECT count(*) FROM {QUALITY}.build_inputs
                                  WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                    AND input_kind = 'bronze_source' AND source_key = '{source_key}'
                                    AND input_table = '{bronze}'""")
            self._rec("S33", source_key=source_key, column_name=bronze_short, fail_count=mismatches + (1 if consumed == 0 else 0),
                      total_count=max(consumed, 1),
                      detail=None if (mismatches == 0 and consumed > 0) else
                      "bronze has a new, removed or reloaded file or sheet since the build: rebuild silver")

    def reconcile(self):
        """S09, per source. row_disposition holds only the rows that were NOT loaded, so:
             rows the build read (build_inputs.input_rows) = bronze rows now
             rows silver points to                         = rows read - rows not loaded"""
        for bronze_short, source_key in DECLARED_INPUTS[self.table]:
            bronze = f"{BRONZE}.{bronze_short}"
            # the files and sheets of this bronze table (two bronze tables can share a source key)
            scope = f"""(SELECT DISTINCT _source_file AS f, _source_sheet AS s FROM {bronze}
                         WHERE _source_key = '{source_key}')"""
            bronze_rows = scalar(f"SELECT count(*) FROM {bronze} WHERE _source_key = '{source_key}'")
            read = scalar(f"""SELECT coalesce(sum(input_rows), 0) FROM {QUALITY}.build_inputs
                              WHERE build_id = '{self.build_id}' AND target_table = '{self.table}'
                                AND input_kind = 'bronze_source' AND source_key = '{source_key}'
                                AND input_table = '{bronze}'""")
            d = spark.sql(f"""SELECT count_if(disposition NOT IN ('loaded', 'merged_into')) AS not_loaded,
                                     count_if(disposition = 'dropped_non_data') AS dropped,
                                     count_if(disposition = 'duplicate_of') AS dup,
                                     count_if(disposition = 'quarantined') AS quar
                              FROM {QUALITY}.row_disposition r
                              JOIN {scope} x ON x.f = r.source_file AND x.s <=> r.source_sheet
                              WHERE r.build_id = '{self.build_id}' AND r.target_table = '{self.table}'
                                AND r.source_key = '{source_key}'""").collect()[0]
            referenced = scalar(f"""SELECT count(*) FROM (SELECT DISTINCT _source_file, _source_sheet, _source_row_num
                                                          FROM {self.table} t
                                                          JOIN {scope} x ON x.f = t._source_file AND x.s <=> t._source_sheet
                                                          WHERE _source_key = '{source_key}')""")
            # merged_into rows count as loaded (they contributed). When the silver row keeps only the
            # first bronze row as its reference (hospital claims: repeats are summed), the other merged
            # rows are not referenced by any silver row; they are subtracted here.
            merged_unreferenced = scalar(f"""
                SELECT count(*) FROM {QUALITY}.row_disposition r
                JOIN {scope} x ON x.f = r.source_file AND x.s <=> r.source_sheet
                LEFT ANTI JOIN (SELECT DISTINCT _source_file, _source_sheet, _source_row_num FROM {self.table}
                                WHERE _source_key = '{source_key}') t
                  ON t._source_file = r.source_file AND t._source_sheet <=> r.source_sheet
                 AND t._source_row_num = r.source_row_num
                WHERE r.build_id = '{self.build_id}' AND r.target_table = '{self.table}'
                  AND r.source_key = '{source_key}' AND r.disposition = 'merged_into'""") or 0
            loaded = read - d["not_loaded"]
            ok = (read == bronze_rows) and (referenced == loaded - merged_unreferenced)
            self.value("S09", f"rows read {read}, silver references {referenced}",
                       f"bronze rows {bronze_rows}, loaded {loaded} - merged into another row {merged_unreferenced}",
                       ok=ok, source_key=source_key, column_name=bronze_short,
                       detail=f"loaded {loaded}, dropped {d['dropped']}, duplicate {d['dup']}, quarantined {d['quar']}, "
                              f"merged into another row {merged_unreferenced}")

    def geography(self, has_level=True):
        """S49 and S50, per source: every psgc: area key exists in geography silver, and (when the
        table has geo_level) at a level that agrees with it. Keys without a PSGC code (ph, foreign,
        hist:...) are not checked here; S37 checks their format.
          S49 FAIL  sources mapped through diseases_area_map. A failure means the area map is older
                    than geography silver: rerun build_diseases_reference_maps.py, then 00 to 04.
          S50 WARN  sources that print their own code (FHSIS TB). A failure is a source code that
                    the PSGC snapshot does not hold, or a provisional level (01 section 4g)."""
        if not spark.catalog.tableExists(GEOGRAPHY):
            self._rec("S49", status="FAIL", observed="table not found", expected=GEOGRAPHY,
                      detail="geography silver is needed for S49 and S50: build it first, or pass --geography_table")
            return
        level_ok = " OR ".join(
            f"(m.geo_level = '{silver_level}' AND g.level IN ({', '.join(repr(v) for v in geo_levels)}))"
            for silver_level, geo_levels in GEO_LEVELS.items()) + (
            # the Special Geographic Area (TB programme) is a geography row with no level
            " OR (m.geo_level = 'special_geographic_area' AND g.level IS NULL AND g.code = '1999900000')"
        ) if has_level else "g.code IS NOT NULL"
        level_col = "geo_level" if has_level else "CAST(NULL AS STRING)"
        rows = spark.sql(f"""
            WITH g AS (
              SELECT DISTINCT lpad(trim(psgc_code), 10, '0') AS code, geographic_level AS level FROM {GEOGRAPHY}
                  WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at) FROM {GEOGRAPHY})),
            m AS (
              SELECT DISTINCT _source_key, area_key, {level_col} AS geo_level
              FROM {self.table} WHERE area_key LIKE 'psgc:%')
            SELECT m._source_key, m.area_key, m.geo_level,
                   max(CASE WHEN g.code IS NOT NULL THEN 1 ELSE 0 END) AS found,
                   max(CASE WHEN {level_ok} THEN 1 ELSE 0 END)         AS level_agrees,
                   concat_ws('/', sort_array(collect_set(g.level)))    AS geography_levels
            FROM m LEFT JOIN g ON g.code = substr(m.area_key, 6)
            GROUP BY m._source_key, m.area_key, m.geo_level""").collect()
        for source_key in sorted({r["_source_key"] for r in rows}):
            mine = [r for r in rows if r["_source_key"] == source_key]
            missing = sorted(r["area_key"] for r in mine if r["found"] == 0)
            wrong_level = sorted(f"{r['area_key']} silver {r['geo_level']}, geography {r['geography_levels'] or 'no level'}"
                                 for r in mine if r["found"] == 1 and r["level_agrees"] == 0)
            notes = []
            if missing:
                notes.append(f"{len(missing)} not in geography, e.g. {', '.join(missing[:5])}")
            if wrong_level:
                notes.append(f"{len(wrong_level)} at another level, e.g. {'; '.join(wrong_level[:5])}")
            self._rec("S50" if source_key in SOURCE_PRINTED_AREA_CODES else "S49", source_key=source_key,
                      fail_count=len(missing) + len(wrong_level), total_count=len(mine),
                      column_name="area_key, geo_level" if has_level else "area_key",
                      detail=" | ".join(notes) or None)


# ----------------------------------------------------------------------------------
# diseases_metric_silver
# ----------------------------------------------------------------------------------
def check_metric(dq, profile):
    t = TableQC(dq, METRIC)
    key = ["disease_key", "area_key", "period_grain", "period_key", "measure", "_source_key"]
    total_sql = f"SELECT count(*) FROM {METRIC}"
    t.basics(key)
    t.build_record()
    t.lineage(extra=["_metric_source_columns"])
    if t.build_id:
        t.freshness()
        t.reconcile()

    t.count("S06", f"SELECT count(*) FROM {METRIC} WHERE value < 0", total_sql, column_name="value")
    t.count("S08", f"""
        SELECT count(*) FROM {METRIC}
        WHERE year IS NULL OR year NOT BETWEEN {YEAR_FLOOR['metric']} AND year(current_date())
           OR (period_grain = 'year'  AND NOT period_key RLIKE '^[0-9]{{4}}$')
           OR (period_grain = 'month' AND (NOT period_key RLIKE '^[0-9]{{4}}-M[0-9]{{2}}$' OR month NOT BETWEEN 1 AND 12))
           OR (period_grain = 'week'  AND period_basis = 'iso_week'
               AND NOT period_key RLIKE '^[0-9]{{4}}-W[0-9]{{2}}$')
           OR (period_grain = 'week'  AND period_basis = 'iso_week_ending_date'
               AND (NOT period_key RLIKE '^[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}$'
                    OR period_end <> to_date(period_key)))
           -- D-44 / D-46: a weekly row is one ISO week (7 days) with the ISO week and year of its end
           OR (period_grain = 'week'
               AND (period_basis NOT IN ('iso_week', 'iso_week_ending_date')
                    OR week IS NULL OR week NOT BETWEEN 1 AND weekofyear(make_date(year, 12, 28))
                    OR period_start IS NULL OR period_end IS NULL
                    OR period_end <> date_add(period_start, 6)
                    OR weekofyear(period_end) <> week
                    OR extract(YEAROFWEEK FROM period_end) <> year))
           OR period_grain NOT IN ('year', 'month', 'week')""", total_sql,
            column_name="period_key, period_basis, year, week, period_start, period_end")
    t.count("S12", f"SELECT count(*) FROM {METRIC} WHERE value IS NULL", total_sql, column_name="value",
            threshold=0.05)
    t.count("S35", f"""SELECT count(*) FROM {METRIC}
                       WHERE value_type = 'modelled' AND NOT (value_lower <= value AND value <= value_upper)""",
            f"SELECT count(*) FROM {METRIC} WHERE value_type = 'modelled'", source_key="ihme_gbd",
            column_name="value_lower, value, value_upper")
    t.count("S36", f"""SELECT count(*) FROM {METRIC}
                       WHERE (value IS NULL) = (value_status = 'ok')
                          OR measure_definition IS NULL OR value_unit IS NULL OR location_basis IS NULL
                          OR value_type IS NULL OR geo_level IS NULL""", total_sql,
            column_name="value, value_status, measure_definition, value_unit, location_basis")
    t.count("S37", f"""
        SELECT (SELECT count(*) FROM {METRIC} m LEFT ANTI JOIN {DIRECTORY} d ON d.disease_key = m.disease_key)
             + (SELECT count(*) FROM {METRIC}
                WHERE NOT area_key RLIKE '^(psgc:[0-9]{{10}}|ph|foreign|hist:[a-z_]+)$')""", total_sql,
            column_name="disease_key, area_key")
    # S49, S50: the PSGC codes behind the area keys exist in geography silver at the stated level
    t.geography()

    # S10: sums in silver equal the same sums taken from bronze
    for source_key, measure, bronze_short, col in [
            ("doh_foi_dengue", "cases", "diseases_doh_foi_dengue_bronze", "Cases"),
            ("doh_foi_dengue", "deaths", "diseases_doh_foi_dengue_bronze", "Deaths"),
            ("upnoah", "cases", "diseases_upnoah_dengue_regional_bronze", "DC_DOH"),
            ("psa_deaths_region_annual", "deaths", "diseases_psa_deaths_region_annual_bronze", "total")]:
        s = scalar(f"SELECT sum(value) FROM {METRIC} WHERE _source_key = '{source_key}' AND measure = '{measure}'")
        b = scalar(f"""SELECT sum(try_cast(regexp_replace(trim(`{col}`), '[ ,]', '') AS DECIMAL(20,4)))
                       FROM {BRONZE}.{bronze_short} WHERE _source_key = '{source_key}'""")
        t.value("S10", s, b, source_key=source_key, column_name=f"{measure} (bronze column {col})")

    # S34: verified control values
    for label, sql, expected in CONTROLS:
        t.value("S34", scalar(sql), expected, detail=label)

    # S45: the only accepted quarantine is the reviewed special-area list (finding F9)
    if t.build_id:
        q = spark.sql(f"""SELECT count(*) AS n, count_if(coalesce(reason, '') <> 'area_unresolved') AS other
                          FROM {QUALITY}.row_disposition
                          WHERE build_id = '{t.build_id}' AND target_table = '{METRIC}'
                            AND disposition = 'quarantined'""").collect()[0]
        t.value("S45", f"{q['n']} quarantined, {q['other']} with another reason", "only reason area_unresolved",
                ok=q["other"] == 0, source_key="doh_fhsis",
                detail="FHSIS TB special geographic area codes 19999..... stay out of silver until reviewed")
        # keep the quarantined bronze rows where a reviewer can read them (not a restricted source)
        rows = spark.sql(f"""
            SELECT b._source_file, b._source_sheet, b._source_row_num, b.psgc_code, b.area_name
            FROM {QUALITY}.row_disposition d
            JOIN {BRONZE}.diseases_fhsis_tb_bronze b
              ON b._source_key = d.source_key AND b._source_file = d.source_file
             AND b._source_sheet <=> d.source_sheet AND b._source_row_num = d.source_row_num
            WHERE d.build_id = '{t.build_id}' AND d.target_table = '{METRIC}' AND d.disposition = 'quarantined'""")
        dq.quarantine(rows, METRIC, "S45", "area_unresolved",
                      key_cols=["_source_file", "_source_sheet", "_source_row_num"],
                      source_table=f"{BRONZE}.diseases_fhsis_tb_bronze")

    # S38: every approved aggregation set adds up to all causes, wherever all causes is published
    t.count("S38", f"""
        SELECT count(*) FROM (
          SELECT m._source_key, m.area_key, m.period_grain, m.period_key, g.aggregation_set,
                 sum(m.value) AS set_sum, max(a.value) AS all_causes
          FROM {METRIC} m
          JOIN {AGG} g ON g.disease_key = m.disease_key AND g.reconciles_to = 'all_causes'
           AND m.year >= try_cast(g.year_from AS INT) AND (g.year_to IS NULL OR m.year <= try_cast(g.year_to AS INT))
          JOIN {METRIC} a ON a.disease_key = 'all_causes' AND a._source_key = m._source_key
           AND a.area_key = m.area_key AND a.period_grain = m.period_grain AND a.period_key = m.period_key
           AND a.measure = m.measure
          WHERE m.measure = 'deaths' AND m.value_status = 'ok'
          GROUP BY m._source_key, m.area_key, m.period_grain, m.period_key, g.aggregation_set)
        WHERE NOT (set_sum <=> all_causes)""",
            f"""SELECT count(*) FROM {METRIC} WHERE disease_key = 'all_causes' AND measure = 'deaths'""",
            detail="groups = source x area x period where the member rows do not sum to all_causes")
    t.count("S39", f"""
        SELECT count(*) FROM {AGG} g
        JOIN {DIRECTORY} d1 ON d1.disease_key = g.disease_key
        LEFT JOIN {DIRECTORY} d2 ON d2.disease_key = d1.parent_disease_key
        JOIN {AGG} p ON p.aggregation_set = g.aggregation_set
         AND p.disease_key IN (d1.parent_disease_key, d2.parent_disease_key)""",
            f"SELECT count(*) FROM {AGG}", detail="a member whose parent or grandparent is also a member")

    # ---- WARN: the sources disagree or have gaps; silver is still a faithful copy -------------
    t.count("S40", f"""
        SELECT count(*) FROM (
          SELECT disease_key, year,
                 sum(CASE WHEN period_grain = 'month' THEN value END) AS months,
                 count(CASE WHEN period_grain = 'month' AND value_status = 'ok' THEN 1 END) AS n_months,
                 max(CASE WHEN period_grain = 'year' THEN value END) AS year_total
          FROM {METRIC} WHERE _source_key = 'psa_deaths_national_monthly'
          GROUP BY disease_key, year) WHERE n_months = 12 AND NOT (months <=> year_total)""",
            f"""SELECT count(*) FROM {METRIC} WHERE _source_key = 'psa_deaths_national_monthly' AND period_grain = 'year'""",
            source_key="psa_deaths_national_monthly", detail="cause-years where 12 months do not sum to the Total column")
    t.count("S41", f"""
        SELECT count(*) FROM (
          SELECT disease_key, year,
                 sum(CASE WHEN geo_level IN ('region', 'foreign') THEN value END) AS parts,
                 max(CASE WHEN geo_level = 'country' THEN value END) AS country
          FROM {METRIC} WHERE _source_key = 'psa_deaths_region_annual'
          GROUP BY disease_key, year) WHERE NOT (parts <=> country)""",
            f"""SELECT count(*) FROM {METRIC} WHERE _source_key = 'psa_deaths_region_annual' AND geo_level = 'country'""",
            source_key="psa_deaths_region_annual", detail="cause-years where regions + foreign do not sum to Philippines")
    t.count("S42", f"""
        SELECT count(*) FROM {METRIC} a
        JOIN {METRIC} b ON b.disease_key = a.disease_key AND b.year = a.year
        WHERE a._source_key = 'psa_deaths_national_monthly' AND a.period_grain = 'year'
          AND b._source_key = 'psa_deaths_region_annual' AND b.area_key = 'ph'
          AND NOT (a.value <=> b.value)""",
            f"""SELECT count(*) FROM {METRIC} a
                JOIN {METRIC} b ON b.disease_key = a.disease_key AND b.year = a.year
                WHERE a._source_key = 'psa_deaths_national_monthly' AND a.period_grain = 'year'
                  AND b._source_key = 'psa_deaths_region_annual' AND b.area_key = 'ph'""",
            detail="cause-years held by both tables where the monthly table and the region table give different national totals")
    t.count("S43", f"""
        SELECT count(DISTINCT area_key) FROM (
          SELECT area_key, datediff(to_date(period_key), lag(to_date(period_key)) OVER (PARTITION BY area_key ORDER BY period_key)) AS gap
          FROM (SELECT DISTINCT area_key, period_key FROM {METRIC} WHERE _source_key = 'hdx_dengue'))
        WHERE gap <> 7""",
            f"SELECT count(DISTINCT area_key) FROM {METRIC} WHERE _source_key = 'hdx_dengue'",
            source_key="hdx_dengue", detail="areas whose weekly dates are not all 7 days apart")
    # S44: DOH FOI and UP NOAH, on the years BOTH hold completely at region level. The years come
    # from diseases_source_coverage_silver at run time (they were typed as 2022-2024 until
    # 2026-10-19). UP NOAH has no Negros Island Region, so UPNOAH_COMBINED_REGIONS are one area.
    combined = ", ".join(f"'{k}'" for k in UPNOAH_COMBINED_REGIONS)
    common_years = f"""(SELECT year FROM {COV}
                        WHERE _source_key IN ('doh_foi_dengue', 'upnoah') AND geo_level = 'region'
                        GROUP BY year HAVING count(DISTINCT _source_key) = 2 AND bool_and(is_complete_year))"""
    years_used = [r[0] for r in spark.sql(f"SELECT year FROM {common_years} ORDER BY 1").collect()]
    t.count("S44", f"""
        WITH x AS (
          SELECT _source_key, year,
                 CASE WHEN area_key IN ({combined}) THEN 'regions VI + VII + NIR' ELSE area_key END AS area,
                 sum(value) AS cases
          FROM {METRIC}
          WHERE _source_key IN ('doh_foi_dengue', 'upnoah') AND measure = 'cases' AND year IN {common_years}
          GROUP BY 1, 2, 3)
        SELECT count(*) FROM (SELECT * FROM x WHERE _source_key = 'doh_foi_dengue') d
        JOIN (SELECT * FROM x WHERE _source_key = 'upnoah') u ON u.year = d.year AND u.area = d.area
        WHERE abs(d.cases - u.cases) > 0.10 * greatest(d.cases, u.cases)""",
            f"""SELECT count(*) FROM (SELECT DISTINCT year,
                       CASE WHEN area_key IN ({combined}) THEN 'x' ELSE area_key END
                FROM {METRIC} WHERE _source_key = 'upnoah' AND year IN {common_years})""",
            detail=f"region-years where annual dengue cases differ by more than 10% between DOH FOI and UP NOAH; "
                   f"complete common years: {', '.join(map(str, years_used)) or 'none'}")

    if profile:
        # value_lower / value_upper are filled only for IHME: their min / max would copy single IHME
        # rows into quality.profile, and the IHME licence allows no row-level export.
        dq.profile_table(METRIC, exclude=("_silver_build_id", "value_lower", "value_upper"))


# ----------------------------------------------------------------------------------
# diseases_deaths_age_silver
# ----------------------------------------------------------------------------------
def check_deaths_age(dq, profile):
    t = TableQC(dq, AGE)
    total_sql = f"SELECT count(*) FROM {AGE}"
    t.basics(["disease_key", "area_key", "year", "age_group", "_source_key"])
    t.build_record()
    t.lineage(extra=["_metric_source_columns"])
    if t.build_id:
        t.freshness()
        t.reconcile()
    t.count("S06", f"SELECT count(*) FROM {AGE} WHERE deaths < 0", total_sql, column_name="deaths")
    t.count("S12", f"SELECT count(*) FROM {AGE} WHERE deaths IS NULL", total_sql, column_name="deaths",
            threshold=0.05)
    t.count("S37", f"SELECT count(*) FROM {AGE} a LEFT ANTI JOIN {DIRECTORY} d ON d.disease_key = a.disease_key",
            total_sql, column_name="disease_key")
    # S49: the region codes exist in geography silver (code only; the level is checked on the metric table)
    t.geography(has_level=False)
    # S46: the 20 age groups of a cause, area and year add up to the total in the metric table
    t.count("S46", f"""
        SELECT count(*) FROM (
          SELECT disease_key, area_key, year, sum(deaths) AS by_age, count(*) AS n FROM {AGE}
          GROUP BY disease_key, area_key, year) a
        LEFT JOIN {METRIC} m
          ON m._source_key = 'psa_deaths_region_annual' AND m.disease_key = a.disease_key
         AND m.area_key = a.area_key AND m.year = a.year
        WHERE a.n <> 20 OR NOT (cast(m.value AS BIGINT) <=> a.by_age)""",
            f"SELECT count(*) FROM (SELECT DISTINCT disease_key, area_key, year FROM {AGE})",
            detail="cause x area x year groups without 20 age groups, or not equal to the metric table total")
    if profile:
        dq.profile_table(AGE, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# diseases_hospital_encounters_silver   (RESTRICTED: counts only; never profiled or quarantined)
# ----------------------------------------------------------------------------------
def check_hospital_encounters(dq, profile):
    t = TableQC(dq, ENC)
    total_sql = f"SELECT count(*) FROM {ENC}"
    t.basics(["_source_key", "_source_file", "_source_sheet", "_source_row_num"])
    t.build_record()
    t.lineage(sheet_nullable=False)
    if t.build_id:
        t.freshness()
        t.reconcile()
    t.count("S36", f"""SELECT count(*) FROM {ENC}
                       WHERE (date_status = 'ok') <> occupancy_eligible
                          OR (occupancy_eligible AND (admission_date IS NULL OR discharge_date IS NULL))
                          OR age_group IS NULL OR is_inpatient_confirmed IS NULL""", total_sql,
            column_name="date_status, occupancy_eligible, age_group")
    # S47: review counts. Kept in the table with a flag; shown here so a person looks at them.
    for column, where, note in [
            ("date_status", "date_status <> 'ok'", "not used for occupancy"),
            ("is_long_stay", "is_long_stay",
             "published length of stay above long_stay_days (diseases_silver_03; value in build_log.parameters)"),
            ("death_fields_consistent", "NOT death_fields_consistent", "Result and DeathDate disagree"),
            ("patient_location_status", "patient_location_status <> 'ok'", "province or city not resolved"),
            ("age_group", "age_group = 'unknown'", "age missing or negative")]:
        t.count("S47", f"SELECT count(*) FROM {ENC} WHERE {where}", total_sql, column_name=column, detail=note)
    # no profile: minimum and maximum would copy patient values into quality.profile


# ----------------------------------------------------------------------------------
# diseases_source_coverage_silver
# ----------------------------------------------------------------------------------
def check_coverage(dq, profile):
    t = TableQC(dq, COV)
    t.basics(["_source_key", "disease_scope", "geo_level", "period_grain", "year"])
    t.build_record()
    # S48: same sources, levels, grains and years as the metric table, and the same period counts
    t.count("S48", f"""
        WITH m AS (SELECT _source_key, geo_level, period_grain, year, count(DISTINCT period_key) AS periods
                   FROM {METRIC} GROUP BY _source_key, geo_level, period_grain, year)
        SELECT (SELECT count(*) FROM m LEFT ANTI JOIN {COV} c
                  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
                 AND c.period_grain = m.period_grain AND c.year = m.year AND c.periods_present = m.periods)
             + (SELECT count(*) FROM {COV} c LEFT ANTI JOIN m
                  ON c._source_key = m._source_key AND c.geo_level = m.geo_level
                 AND c.period_grain = m.period_grain AND c.year = m.year)""",
            f"SELECT count(*) FROM {COV}",
            detail="coverage rows that do not match the metric table: rerun diseases_silver_04 after 01")
    if profile:
        dq.profile_table(COV, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# diseases_tb_programme_silver   (diseases_silver_05)
# ----------------------------------------------------------------------------------
def check_tb_programme(dq, profile):
    t = TableQC(dq, TBP)
    total_sql = f"SELECT count(*) FROM {TBP}"
    t.basics(["indicator", "drug_resistance", "area_key", "year", "age_group", "sex", "_source_key"])
    t.build_record()
    t.lineage(sheet_nullable=False, extra=["_metric_source_columns"])
    if t.build_id:
        t.freshness()
        t.reconcile()
    t.count("S06", f"SELECT count(*) FROM {TBP} WHERE value < 0", total_sql, column_name="value")
    t.count("S08", f"SELECT count(*) FROM {TBP} WHERE year IS NULL OR year NOT BETWEEN {YEAR_FLOOR['tb_programme']} AND year(current_date())",
            total_sql, column_name="year")
    t.count("S36", f"""SELECT count(*) FROM {TBP}
                       WHERE (value IS NULL) = (value_status = 'ok')
                          OR indicator_definition IS NULL OR value_unit IS NULL OR value_type IS NULL
                          OR location_basis IS NULL OR geo_level IS NULL
                          OR (value_unit = 'count' AND value <> floor(value))""", total_sql,
            column_name="value, value_status, indicator_definition, value_unit")
    t.count("S37", f"""
        SELECT (SELECT count(*) FROM {TBP} m LEFT ANTI JOIN {DIRECTORY} d ON d.disease_key = m.disease_key)
             + (SELECT count(*) FROM {TBP} WHERE NOT area_key RLIKE '^(psgc:[0-9]{{10}}|ph)$')""", total_sql,
            column_name="disease_key, area_key")
    # S50 (WARN): FHSIS prints its own codes; the build already quarantines codes not in geography
    t.geography()
    for indicator, resistance, expected in TBP_CONTROLS:
        t.value("S34", scalar(f"""SELECT sum(value) FROM {TBP} WHERE area_key = 'ph' AND year = {TBP_CONTROL_YEAR}
                                  AND indicator = '{indicator}' AND drug_resistance = '{resistance}'
                                  AND age_group = 'all_ages' AND sex = 'both_sexes'"""), expected,
                source_key="doh_fhsis", detail=f"Philippines {TBP_CONTROL_YEAR} {indicator} {resistance}")
    if t.build_id:
        q = spark.sql(f"""SELECT count(*) AS n, count_if(coalesce(reason, '') <> 'psgc_not_in_geography') AS other
                          FROM {QUALITY}.row_disposition
                          WHERE build_id = '{t.build_id}' AND target_table = '{TBP}' AND disposition = 'quarantined'""").collect()[0]
        t.value("S45", f"{q['n']} quarantined, {q['other']} with another reason", "only reason psgc_not_in_geography",
                ok=q["other"] == 0, source_key="doh_fhsis",
                detail="area rows whose printed PSGC code is not in the geography snapshot")
    # S12: share of cells with no report ('*' or blank) per indicator; WARN above 10%
    for indicator in ("tpt_given", "tpt_eligible_contacts", "treatment_cohort", "treatment_success"):
        t.count("S12", f"SELECT count(*) FROM {TBP} WHERE indicator = '{indicator}' AND value IS NULL",
                f"SELECT count(*) FROM {TBP} WHERE indicator = '{indicator}'", column_name=f"value ({indicator})",
                threshold=0.10)
    if profile:
        dq.profile_table(TBP, exclude=("_silver_build_id",))


# ----------------------------------------------------------------------------------
# diseases_hospital_claims_silver   (diseases_silver_06; RESTRICTED: counts only, never profiled
# or quarantined, so no row of the FOI release is copied into the quality schema)
# ----------------------------------------------------------------------------------
def check_hospital_claims(dq, profile):
    t = TableQC(dq, CLM)
    total_sql = f"SELECT count(*) FROM {CLM}"
    bronze = f"{BRONZE}.diseases_philhealth_claims_hospital_bronze"
    t.basics(["year", "facility_name_norm", "area_key", "disease_key", "claim_status", "_source_key"])
    t.build_record()
    t.lineage(sheet_nullable=False, extra=["_metric_source_columns"])
    if t.build_id:
        t.freshness()
        t.reconcile()       # merged_into rows count as loaded
    t.count("S06", f"SELECT count(*) FROM {CLM} WHERE claims_count < 0 OR claims_amount_php < 0", total_sql,
            column_name="claims_count, claims_amount_php")
    t.count("S08", f"SELECT count(*) FROM {CLM} WHERE year IS NULL OR year NOT BETWEEN {YEAR_FLOOR['hospital_claims']} AND year(current_date())",
            total_sql, column_name="year")
    t.count("S36", f"""SELECT count(*) FROM {CLM}
                       WHERE claim_status NOT IN ('paid', 'denied', 'returned_to_hospital', 'in_process')
                          OR ownership NOT IN ('Government', 'Private') OR amount_basis <> 'amount_claimed'
                          OR location_basis <> 'facility_location' OR source_rows < 1
                          OR is_covid_period IS NULL OR is_amount_series_break IS NULL OR is_preliminary IS NULL
                          OR is_package_definition_change IS NULL
                          OR (facility_key IS NULL) <> (facility_match_method IN ('unmatched', 'ambiguous'))""",
            total_sql, column_name="claim_status, ownership, amount_basis, flags, facility_match_method")
    t.count("S37", f"""
        SELECT (SELECT count(*) FROM {CLM} m LEFT ANTI JOIN {DIRECTORY} d ON d.disease_key = m.disease_key)
             + (SELECT count(*) FROM {CLM} WHERE NOT area_key RLIKE '^psgc:[0-9]{{10}}$'
                                              OR geo_level NOT IN ('city', 'municipality'))""", total_sql,
            column_name="disease_key, area_key, geo_level")
    t.geography()
    # S10 and S34: totals per year. Silver + the quarantined bronze rows (blank illness) = bronze = control
    quarantined = f"""
        SELECT try_cast(b.Admit_Year AS INT) AS year, sum(try_cast(b.Claims_Count AS BIGINT)) AS n,
               sum(try_cast(b.Claims_Amount AS DECIMAL(20,2))) AS amt
        FROM {QUALITY}.row_disposition d
        JOIN {bronze} b ON b._source_key = d.source_key AND b._source_file = d.source_file
         AND b._source_sheet <=> d.source_sheet AND b._source_row_num = d.source_row_num
        WHERE d.build_id = '{t.build_id}' AND d.target_table = '{CLM}' AND d.disposition = 'quarantined'
        GROUP BY 1"""
    for col, bcol, label in (("claims_count", "Claims_Count", "claims count"),
                             ("claims_amount_php", "Claims_Amount", "claims amount")):
        s = scalar(f"""SELECT sum({col}) + coalesce((SELECT sum({'n' if col == 'claims_count' else 'amt'})
                                                      FROM ({quarantined})), 0) FROM {CLM}""")
        b = scalar(f"SELECT sum(try_cast({bcol} AS DECIMAL(20,2))) FROM {bronze} "
                   f"WHERE _source_key = 'philhealth_foi_claims_hospital'")
        t.value("S10", s, b, source_key="philhealth_foi_claims_hospital",
                column_name=f"{col} (bronze column {bcol})", detail=f"silver {label} + quarantined rows = bronze")
    by_year = {r["year"]: r["n"] for r in spark.sql(f"""
        SELECT s.year, s.n + coalesce(q.n, 0) AS n
        FROM (SELECT year, sum(claims_count) AS n FROM {CLM} GROUP BY year) s
        LEFT JOIN ({quarantined}) q ON q.year = s.year""").collect()}
    for year, expected in CLM_CONTROLS.items():
        t.value("S34", by_year.get(year), expected, source_key="philhealth_foi_claims_hospital",
                detail=f"claims filed {year}, all statuses (silver + quarantined rows)")
    if t.build_id:
        q = spark.sql(f"""SELECT count(*) AS n, count_if(coalesce(reason, '') <> 'illness_missing') AS other
                          FROM {QUALITY}.row_disposition
                          WHERE build_id = '{t.build_id}' AND target_table = '{CLM}' AND disposition = 'quarantined'""").collect()[0]
        t.value("S45", f"{q['n']} quarantined, {q['other']} with another reason", "only reason illness_missing",
                ok=q["other"] == 0, source_key="philhealth_foi_claims_hospital",
                detail="rows with a blank Illness Description")
    # S12 (WARN above 10%): claims at hospitals with no facility_key (not in facilities_registry_silver)
    t.count("S12", f"SELECT coalesce(sum(CASE WHEN facility_key IS NULL THEN claims_count END), 0) FROM {CLM}",
            f"SELECT sum(claims_count) FROM {CLM}", column_name="facility_key (share of claims)", threshold=0.10,
            source_key="philhealth_foi_claims_hospital")
    # no profile: restricted release


# ----------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------
TABLE_CHECKS = {
    "metric": (METRIC, check_metric),
    "deaths_age": (AGE, check_deaths_age),
    "hospital_encounters": (ENC, check_hospital_encounters),
    "coverage": (COV, check_coverage),
    "tb_programme": (TBP, check_tb_programme),
    "hospital_claims": (CLM, check_hospital_claims),
}


def main():
    wanted = list(TABLE_CHECKS) if ARGS.tables.strip().upper() == "ALL" else \
        [t.strip() for t in ARGS.tables.split(",") if t.strip()]
    unknown = [t for t in wanted if t not in TABLE_CHECKS]
    if unknown:
        raise KeyError(f"Unknown table(s) {unknown}. Choose from {list(TABLE_CHECKS)}")

    # DQRun writes qc_results, table_stats, profile and run_log on exit, then raises if any FAIL.
    with DQRun(layer="silver", domain=DOMAIN, script_name=SCRIPT_NAME, job_run_id=ARGS.job_run_id,
               source_keys=ARGS.tables, fail_on_error=ARGS.fail_on_error == "true",
               code_version=ARGS.code_version, dq_schema=QUALITY) as dq:
        for name in wanted:
            table, fn = TABLE_CHECKS[name]
            print(f"[{name}] {table}")
            try:
                fn(dq, ARGS.profile == "true")
            except Exception as e:
                # One table erroring is recorded as a failed check; the others still run.
                cname, ctype, severity = CHECKS["S00"]
                dq.record("S00", table_name=table, status="FAIL", check_name=cname, check_type=ctype,
                          severity=severity, detail=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()