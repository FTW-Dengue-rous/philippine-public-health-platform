# Silver QC that no single domain script can do, because each check reads tables of two or more
# domains: the quarantine gate for every silver build, business rules (ratios per population),
# cross-source consistency, timeliness of every silver table, and the PSGC check
# workforce_silver_qc.py does not have. Writes through
# dq_utils.DQRun into public_health.quality, like every other QC script. No quality table is
# changed: only existing columns are written.
#
# When it runs
#   Last step of silver, after every domain silver QC script, before gold.
#   Run order: geography -> population -> domain builds -> <domain>_silver_qc.py -> psgc_population_silver_qc.py
#              -> [silver_cross_domain_qc.py] -> gold
#   As a job task: depends on every silver QC task (geography, population, admin boundaries,
#   facilities, diseases, workforce, socioeconomic). Gold depends on this task.
#
# How to run (Databricks notebook cell or job; no arguments needed)
#   python silver_cross_domain_qc.py
#   python silver_cross_domain_qc.py --fail_on_error false --max_age_years 3
#
# Check codes
#   Code  Check                                                        Attribute       Severity
#   S29   quarantined bronze rows per silver table and source          completeness    GATE: WARN > 0,
#           (latest succeeded build, from quality.v_build_reconciliation)              FAIL > 5 % and > 10 rows
#   S04   workforce PSGC codes found in geography (latest snapshot)    consistency     WARN
#   S08   no data year in the future                                   validity        FAIL
#   S97   ratio per population inside a plausible band (by region)     business rule   WARN
#           beds per 1,000 (facilities registry / latest census year)
#           doctors + nurses + midwives per 10,000 (FHSIS / census, latest year in both)
#   S98   latest data year of each source no older than --max_age_years  timeliness    WARN
#   S99   FHSIS reported population vs census population, same area and year  consistency  WARN
#
# Gate: S29 and S08 can FAIL; a FAIL makes the run raise at the end (dq_utils), so the job task
# fails and gold does not start. Everything else is WARN, for a person to read. Bands, the
# quarantine limits and the list of historical sources are constants below: tune them after the
# first Databricks run, and say why in a comment.
#
# Changes
#   2026-10-14  S29: hdx_healthsites 20 % override removed (runbook incident 2 closed by the
#               GeoJSON-derived Healthsites file). S98: diseases TB programme and hospital claims
#               tables added; three PSA facilities tables that end in 2015 marked historical.
#   2026-10-19  Rule 2a: the years are derived, not typed. S97 beds use the latest census year in
#               population_silver (was RATIO_YEAR = 2024); S97 health workers use the latest year
#               held by both the census and FHSIS; S99 compares every year held by both the census
#               and the FHSIS denominator (was 2020, 2024). Each detail names the years used.
#               Kept as named policy: the S29 limits, the S97 bands, the S99 tolerance.

import argparse
import os
import sys
from datetime import UTC, datetime

from pyspark.sql import SparkSession


def _add_dq_utils_to_path():
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
        "dq_utils.py not found. Looked in:\n  " + "\n  ".join(dict.fromkeys(searched))
    )


_add_dq_utils_to_path()
from dq_utils import DQRun  # noqa: E402

DOMAIN = "cross_domain"
SCRIPT_NAME = "silver_cross_domain_qc.py"


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument(
        "--catalog", default="public_health", help="'' gives two-part names (local tests)"
    )
    p.add_argument("--max_age_years", default="3", help="S98: latest year older than this is stale")
    p.add_argument("--fail_on_error", default="true")
    p.add_argument("--job_run_id", default=None)
    p.add_argument("--code_version", default=None)
    a, _ = p.parse_known_args()
    return a


ARGS = parse_args()
PREFIX = f"{ARGS.catalog}." if ARGS.catalog else ""
SILVER, QUALITY = f"{PREFIX}silver", f"{PREFIX}quality"
GEO = f"{SILVER}.geography_silver"
POP = f"{SILVER}.population_silver"
REG = f"{SILVER}.facilities_registry_silver"
HC = f"{SILVER}.workforce_headcount_silver"
DEN = f"{SILVER}.workforce_area_denominator_silver"

spark = SparkSession.builder.getOrCreate()

CHECKS = {
    "S00": ("QC ran without error", "EXECUTION", "FAIL"),
    "S04": ("PSGC code found in geography", "CONSISTENCY", "WARN"),
    "S29": ("quarantined rows within the limit", "COMPLETENESS", "FAIL"),
    "S08": ("period within expected range", "VALIDITY", "FAIL"),
    "S97": ("ratio per population inside the plausible band", "VALIDITY", "WARN"),
    "S98": ("latest data year of each source is recent", "CONSISTENCY", "WARN"),
    "S99": ("reported population agrees with census population", "CONSISTENCY", "WARN"),
}

# S29 quarantine gate. Fractions of the bronze rows a build read from one source.
#   0 quarantined                         PASS
#   up to the limit, or <= the row floor  WARN  (rows a person should review)
#   above the limit and above the floor   FAIL  (blocks gold)
# Known today: diseases FHSIS TB 18 of 3,493 rows (0.5 %), workforce FHSIS 8 of 4,999 (0.2 %),
# facilities OSM points 2 of 16,032 (0.01 %, coordinates outside the boundaries; 2026-10-14).
QUARANTINE_FAIL_PCT = 5.0
QUARANTINE_MIN_FAIL_ROWS = 10
# Per (target table short name, source_key) override of the limit, in percent. One comment each.
# 2026-10-14: ("facilities_osm_point_silver", "hdx_healthsites"): 20.0 removed. The 2026-10-14
# Healthsites file (coordinates from the GeoJSON outlines) gives every row coordinates, so the
# quarantine share fell from 16.6 % to 0.01 % and the default limit applies (runbook incident 2).
QUARANTINE_FAIL_PCT_BY_SOURCE = {}

# S98: (table, year column, source column or None). Restricted tables are read for max(year) only.
# A table that does not exist yet is skipped.
TIMELINESS = [
    (f"{SILVER}.diseases_metric_silver", "year", "_source_key"),
    (f"{SILVER}.diseases_deaths_age_silver", "year", "_source_key"),
    (f"{SILVER}.diseases_tb_programme_silver", "year", "_source_key"),
    (f"{SILVER}.diseases_hospital_claims_silver", "year", "_source_key"),  # restricted (FOI)
    (f"{SILVER}.facilities_metric_silver", "year", "_source_key"),
    (f"{SILVER}.facilities_bed_occupancy_silver", "year", "_source_key"),  # restricted (FOI)
    (HC, "year", "_source_key"),
    (DEN, "year", "_source_key"),
    (f"{SILVER}.socioeconomic_poverty_silver", "year", "_source_key"),
    (f"{SILVER}.socioeconomic_health_expenditure_share_silver", "year", "_source_key"),
    (f"{SILVER}.socioeconomic_health_expenditure_per_capita_silver", "year", "_source_key"),
    (POP, "population_year", None),
]
# Sources that are history by design: never "stale". One comment per entry; add others from the
# S98 detail after a run.
HISTORICAL_SOURCES = {
    "psa_hospitals_national_annual",  # PSA OpenSTAT national hospitals, 2006-2015 only
    "psa_hospitals_beds_national_annual",  # PSA 9.16 national hospitals and beds, 1990-2015 only
    "psa_hospitals_region_annual_legacy",  # PSA 9.17 (PSY 2024) hospitals by region, 2005-2015 only
}

# S97 plausible bands (business rules, team-owned). A region outside the band is listed, not wrong.
BED_BAND_PER_1000 = (0.3, 5.0)  # PH hospital beds per 1,000 people is about 1
HW_BAND_PER_10000 = (1.0, 60.0)  # FHSIS doctors + nurses + midwives per 10,000
HW_PROFESSIONS = ("doctors", "nurses", "midwives")
FHSIS_KEY = "doh_fhsis_demographic"
S99_TOLERANCE_PCT = 10.0
# Years are derived at run time (census_years, latest_common_year); none are typed here.


def scalar(sql):
    return spark.sql(sql).collect()[0][0]


def listing(sql, limit=20):
    rows = spark.sql(sql).limit(limit).collect()
    return "; ".join(" ".join(str(v) for v in r) for r in rows) or None


def exists(name):
    return spark.catalog.tableExists(name)


def latest_geography():
    return f"""(SELECT psgc_code, geographic_level FROM {GEO}
               WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at) FROM {GEO}))"""


def census_years():
    """Census years held by population_silver (with at least one population value)."""
    return sorted(r[0] for r in spark.sql(
        f"SELECT DISTINCT population_year FROM {POP} WHERE population IS NOT NULL").collect())


def years_in(table, where="true", col="year"):
    return {r[0] for r in spark.sql(f"SELECT DISTINCT {col} FROM {table} WHERE {where}").collect()}


def region_population(year):
    """Census population of each region in a census year (region = first two digits of the code)."""
    return f"""(SELECT substr(p.psgc_code, 1, 2) AS r, max(p.population) AS pop
               FROM {POP} p JOIN {latest_geography()} g ON g.psgc_code = p.psgc_code
               WHERE g.geographic_level = 'Reg' AND p.population_year = {int(year)}
                 AND p.population IS NOT NULL
               GROUP BY 1)"""


def rec(dq, check_id, table, **kw):
    name, ctype, severity = CHECKS[check_id]
    return dq.record(
        check_id, table_name=table, check_name=name, check_type=ctype, severity=severity, **kw
    )


def count(dq, check_id, table, fail_sql, total_sql, **kw):
    return rec(
        dq, check_id, table, fail_count=scalar(fail_sql) or 0, total_count=scalar(total_sql), **kw
    )


# ----------------------------------------------------------------------------------
# S29: quarantine gate, every silver table built with the build pattern
# ----------------------------------------------------------------------------------
def check_quarantine_gate(dq):
    # Latest succeeded build of each silver table, per source. Tables built outside the build
    # pattern (geography, population notebooks) have no build_inputs rows and are not covered.
    rows = spark.sql(f"""
        SELECT r.target_table, r.build_id, r.source_key,
               sum(r.rows_read) AS rows_read, sum(r.rows_quarantined) AS rows_quarantined,
               sum(r.rows_dropped_non_data) AS rows_dropped, sum(r.rows_duplicate) AS rows_duplicate
        FROM {QUALITY}.v_build_reconciliation r
        JOIN {QUALITY}.v_latest_build b ON b.build_id = r.build_id AND b.target_table = r.target_table
        WHERE b.layer = 'silver'
        GROUP BY r.target_table, r.build_id, r.source_key
        ORDER BY r.target_table, r.source_key""").collect()
    if not rows:
        rec(
            dq,
            "S29",
            None,
            status="WARN",
            detail="no silver build found in quality.v_build_reconciliation",
        )
        return
    for r in rows:
        short = r["target_table"].split(".")[-1]
        limit = QUARANTINE_FAIL_PCT_BY_SOURCE.get((short, r["source_key"]), QUARANTINE_FAIL_PCT)
        reasons = listing(
            f"""SELECT reason, count(*) FROM {QUALITY}.row_disposition
                               WHERE build_id = '{r["build_id"]}' AND target_table = '{r["target_table"]}'
                                 AND source_key = '{r["source_key"]}' AND disposition = 'quarantined'
                               GROUP BY reason ORDER BY 2 DESC""",
            5,
        )
        rec(
            dq,
            "S29",
            r["target_table"],
            source_key=r["source_key"],
            batch_id=f"build:{r['build_id']}",
            fail_count=r["rows_quarantined"],
            total_count=r["rows_read"],
            warn_threshold=0.0,
            threshold=limit / 100.0,
            min_fail_rows=QUARANTINE_MIN_FAIL_ROWS,
            column_name="row_disposition = quarantined",
            observed=f"quarantined {r['rows_quarantined']} of {r['rows_read']} rows read "
            f"(also dropped {r['rows_dropped']}, duplicate {r['rows_duplicate']})",
            expected=f"<= {limit}% or <= {QUARANTINE_MIN_FAIL_ROWS} rows",
            detail=reasons,
        )


# ----------------------------------------------------------------------------------
# S04: workforce PSGC codes (the workforce QC script has no geography check)
# ----------------------------------------------------------------------------------
def check_workforce_psgc(dq):
    for table in (HC, DEN):
        if not exists(table):
            continue
        count(
            dq,
            "S04",
            table,
            f"""SELECT count(DISTINCT t.psgc_code) FROM {table} t LEFT ANTI JOIN {latest_geography()} g
                  ON g.psgc_code = t.psgc_code WHERE t.psgc_code IS NOT NULL""",
            f"SELECT count(DISTINCT psgc_code) FROM {table} WHERE psgc_code IS NOT NULL",
            column_name="psgc_code",
            detail="distinct codes not in the latest geography snapshot",
        )


# ----------------------------------------------------------------------------------
# S08 + S98: timeliness of every silver table, per source
# ----------------------------------------------------------------------------------
def check_timeliness(dq):
    this_year = datetime.now(UTC).year  # UTC, same as dq_utils
    max_age = int(ARGS.max_age_years)
    for table, ycol, scol in TIMELINESS:
        if not exists(table):
            continue
        src = scol if scol else "'all'"
        spark.sql(f"""SELECT CAST({src} AS STRING) AS source, max(CAST({ycol} AS INT)) AS latest
                      FROM {table} GROUP BY 1""").createOrReplaceTempView("xd_latest")
        hist = ", ".join(f"'{s}'" for s in sorted(HISTORICAL_SOURCES)) or "''"
        count(
            dq,
            "S08",
            table,
            f"SELECT count(*) FROM {table} WHERE CAST({ycol} AS INT) > {this_year}",
            f"SELECT count(*) FROM {table}",
            column_name=ycol,
            detail=f"rows dated after {this_year}",
        )
        stale = f"latest < {this_year - max_age} AND source NOT IN ({hist})"
        count(
            dq,
            "S98",
            table,
            f"SELECT count(*) FROM xd_latest WHERE {stale}",
            f"SELECT count(*) FROM xd_latest WHERE source NOT IN ({hist})",
            column_name=ycol,
            observed=listing("SELECT source, latest FROM xd_latest ORDER BY latest DESC, source"),
            expected=f"latest year >= {this_year - max_age} (or source listed as historical)",
            detail=listing(
                f"SELECT concat('stale: ', source, ' ', latest) FROM xd_latest WHERE {stale} ORDER BY 1"
            ),
        )


# ----------------------------------------------------------------------------------
# S97: business rules, ratio per population by region
# ----------------------------------------------------------------------------------
def check_ratios(dq):
    census = census_years() if exists(POP) else []
    if exists(REG) and census:
        ratio_year = census[-1]  # latest census: the registry is a current snapshot
        lo, hi = BED_BAND_PER_1000
        spark.sql(f"""
            SELECT p.r, coalesce(b.beds, 0) AS beds, p.pop,
                   round(coalesce(b.beds, 0) * 1000.0 / p.pop, 2) AS per_1000
            FROM {region_population(ratio_year)} p
            LEFT JOIN (SELECT substr(psgc_code, 1, 2) AS r, sum(analysis_beds) AS beds FROM {REG}
                       WHERE facility_status = 'listed' AND facility_category IN ('hospital', 'infirmary')
                         AND psgc_code IS NOT NULL GROUP BY 1) b ON b.r = p.r""").createOrReplaceTempView(
            "xd_beds"
        )
        out = f"per_1000 NOT BETWEEN {lo} AND {hi}"
        count(
            dq,
            "S97",
            REG,
            f"SELECT count(*) FROM xd_beds WHERE {out}",
            "SELECT count(*) FROM xd_beds",
            column_name="analysis_beds per 1,000 population",
            admin_level=1,
            expected=f"{lo} to {hi} per 1,000 (census {ratio_year}, the latest in population_silver)",
            observed=listing("SELECT r, per_1000 FROM xd_beds ORDER BY r", 25),
            detail=listing(
                f"SELECT concat('region ', r, ': ', per_1000) FROM xd_beds WHERE {out} ORDER BY r"
            ),
        )
    hw_years = sorted(set(census) & years_in(HC, f"_source_key = '{FHSIS_KEY}'")) if exists(HC) and census else []
    if hw_years:
        hw_year = hw_years[-1]  # latest year held by both the census and FHSIS
        lo, hi = HW_BAND_PER_10000
        profs = ", ".join(f"'{x}'" for x in HW_PROFESSIONS)
        # Province rows plus city rows add up to the region (FHSIS prints listed cities apart from
        # their province), so region rows are left out to avoid counting twice.
        spark.sql(f"""
            SELECT p.r, coalesce(h.workers, 0) AS workers, p.pop,
                   round(coalesce(h.workers, 0) * 10000.0 / p.pop, 2) AS per_10000
            FROM {region_population(hw_year)} p
            LEFT JOIN (SELECT substr(t.psgc_code, 1, 2) AS r, sum(t.headcount_total) AS workers
                       FROM {HC} t JOIN {latest_geography()} g ON g.psgc_code = t.psgc_code
                       WHERE t._source_key = '{FHSIS_KEY}' AND t.year = {hw_year}
                         AND t.profession IN ({profs}) AND t.total_status = 'ok'
                         AND coalesce(t.analysis_eligible, true)
                         AND g.geographic_level IN ('Prov', 'City')
                       GROUP BY 1) h ON h.r = p.r""").createOrReplaceTempView("xd_hw")
        out = f"per_10000 NOT BETWEEN {lo} AND {hi}"
        count(
            dq,
            "S97",
            HC,
            f"SELECT count(*) FROM xd_hw WHERE {out}",
            "SELECT count(*) FROM xd_hw",
            column_name="doctors+nurses+midwives per 10,000 population",
            admin_level=1,
            source_key=FHSIS_KEY,
            expected=f"{lo} to {hi} per 10,000 (FHSIS {hw_year} / census {hw_year}, latest year in both)",
            observed=listing("SELECT r, per_10000 FROM xd_hw ORDER BY r", 25),
            detail=listing(
                f"SELECT concat('region ', r, ': ', per_10000) FROM xd_hw WHERE {out} ORDER BY r"
            ),
        )


# ----------------------------------------------------------------------------------
# S99: the two population sources agree (gold keeps both, never sums them)
# ----------------------------------------------------------------------------------
def check_population_sources(dq):
    if not (exists(DEN) and exists(POP)):
        return
    common = sorted(set(census_years()) & years_in(DEN))
    if not common:
        rec(dq, "S99", DEN, status="WARN", source_key=FHSIS_KEY,
            detail="no year held by both population_silver and the FHSIS denominator: nothing compared")
        return
    years = ", ".join(str(y) for y in common)
    # Regions, cities and municipalities only: province coverage differs between the two sources
    # (census 2024 provinces exclude HUCs; FHSIS provinces exclude their listed cities).
    spark.sql(f"""
        SELECT d.psgc_code, g.geographic_level AS level, d.year, d.reported_population AS fhsis,
               p.population AS census,
               round(abs(d.reported_population - p.population) * 100.0 / p.population, 1) AS diff_pct
        FROM {DEN} d
        JOIN {latest_geography()} g ON g.psgc_code = d.psgc_code
        JOIN {POP} p ON p.psgc_code = d.psgc_code AND p.population_year = d.year
        WHERE d.year IN ({years}) AND d.population_status = 'ok' AND p.population > 0
          AND g.geographic_level IN ('Reg', 'City', 'Mun')""").createOrReplaceTempView("xd_pop")
    out = f"diff_pct > {S99_TOLERANCE_PCT}"
    count(
        dq,
        "S99",
        DEN,
        f"SELECT count(*) FROM xd_pop WHERE {out}",
        "SELECT count(*) FROM xd_pop",
        column_name="reported_population vs population_silver.population",
        source_key=FHSIS_KEY,
        expected=f"within {S99_TOLERANCE_PCT}% of the census, years {years} (held by both)",
        detail=listing(f"""SELECT psgc_code, level, year, fhsis, 'vs', census, concat(diff_pct, '%')
                             FROM xd_pop WHERE {out} ORDER BY diff_pct DESC"""),
    )


SECTIONS = [
    ("quarantine gate", check_quarantine_gate, None),
    ("workforce PSGC", check_workforce_psgc, HC),
    ("timeliness", check_timeliness, None),
    ("ratios", check_ratios, None),
    ("population sources", check_population_sources, DEN),
]


def main():
    with DQRun(
        layer="silver",
        domain=DOMAIN,
        script_name=SCRIPT_NAME,
        job_run_id=ARGS.job_run_id,
        source_keys="ALL",
        fail_on_error=ARGS.fail_on_error == "true",
        code_version=ARGS.code_version,
        dq_schema=QUALITY,
    ) as dq:
        for name, fn, table in SECTIONS:
            print(f"[{name}]")
            try:
                fn(dq)
            except Exception as e:  # noqa: BLE001  one section erroring does not stop the others
                rec(dq, "S00", table, status="FAIL", detail=f"{name}: {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()