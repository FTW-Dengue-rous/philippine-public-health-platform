# =============================================================================
# Loads the sources added on 2026-10-14 to bronze and runs their bronze QC.
# Runs the existing loaders and QC scripts unchanged, for the named source keys only,
# so no other bronze file is reloaded and existing silver stays valid.
#
#   diseases    doh_fhsis_tb_tpt, doh_fhsis_tb_treatment_success, philhealth_foi_claims_hospital
#   facilities  hdx_healthsites (2026-09-29 CSV export + 2026-10-14 file derived from the GeoJSON)
#
# Steps (stops at the first failure; nothing after it runs)
#   1. Pre-checks, nothing written: scripts found, YAML entries present, every landing file exists,
#      bronze.ingestion_metadata has source_sheet and content_checksum (runbook incident 3)
#   2. diseases_bronze.py    -> diseases_bronze_qc.py      (diseases keys)
#   3. facilities_bronze.py  -> facilities_bronze_qc.py    (hdx_healthsites)
#   4. Summary: rows per file and sheet vs the YAML expected_rows, latest QC status per table
#
# How to run
#   Databricks job, Python script task:  run_bronze_new_sources.py
#   Notebook cell:
#     import sys, runpy
#     sys.argv = ["run_bronze_new_sources.py"]            # add options here, e.g. "--dry_run", "true"
#     runpy.run_path("/Workspace/Repos/<you>/<repo>/builders/run_bronze_new_sources.py", run_name="__main__")
#
# Options
#   --repo_root      repo folder (default: found from this file's location, else the working directory)
#   --dry_run true   pre-checks only
#   --only           diseases | facilities | all (default all)
#   --fail_on_qc     true (default) stops when a QC script reports FAIL; false records and continues
#   --catalog        public_health (default); '' only for local tests
#
# The scripts are found by file name under <repo_root>/src (exactly one match each), and the
# YAMLs under <repo_root>/config. Pass --diseases_bronze etc. to give a path yourself.
#
# Expected
#   diseases_fhsis_tb_tpt_bronze                 1,748   (sheet TB-TPT)
#   diseases_fhsis_tb_treatment_success_bronze   3,496   (TSR-DSTB 1,748 + TSR-MDRTB 1,748)
#   diseases_philhealth_claims_hospital_bronze   245,405 (B08 WARN: 19 exact repeats, expected)
#   facilities_hdx_healthsites_bronze            16,032 per file (blank X: 3,870 old file, 0 new file)
# =============================================================================

import argparse
import glob
import os
import runpy
import sys
import time

import yaml
from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()

DOMAINS = {
    "diseases": {
        "keys": ["doh_fhsis_tb_tpt", "doh_fhsis_tb_treatment_success", "philhealth_foi_claims_hospital"],
        "config": "sources_diseases.yaml",
        "bronze": "diseases_bronze.py",
        "qc": "diseases_bronze_qc.py",
    },
    "facilities": {
        "keys": ["hdx_healthsites"],
        "config": "sources_facilities.yaml",
        "bronze": "facilities_bronze.py",
        "qc": "facilities_bronze_qc.py",
    },
}
PREFIX = "public_health."                              # set by --catalog
METADATA_COLUMNS = ("source_sheet", "content_checksum")


def parse_args():
    p = argparse.ArgumentParser(description="Bronze load + bronze QC for the 2026-10-14 sources")
    p.add_argument("--repo_root", default=None)
    p.add_argument("--dry_run", default="false", choices=["true", "false"])
    p.add_argument("--only", default="all", choices=["all", "diseases", "facilities"])
    p.add_argument("--fail_on_qc", default="true", choices=["true", "false"])
    p.add_argument("--catalog", default="public_health", help="'' for two-part names (local tests)")
    for d in DOMAINS:
        p.add_argument(f"--{d}_bronze", default=None, help=f"path to {DOMAINS[d]['bronze']}")
        p.add_argument(f"--{d}_qc", default=None, help=f"path to {DOMAINS[d]['qc']}")
        p.add_argument(f"--{d}_config", default=None, help=f"path to {DOMAINS[d]['config']}")
    a, _ = p.parse_known_args()
    return a


def stop(msg):
    raise SystemExit(f"STOPPED: {msg}")


def repo_root(explicit):
    if explicit:
        return os.path.abspath(explicit)
    try:
        here = os.path.dirname(os.path.abspath(__file__))
    except NameError:                                   # pasted into a notebook cell
        here = os.getcwd()
    folder = here
    for _ in range(6):                                  # the folder that holds src/ and config/
        if os.path.isdir(os.path.join(folder, "src")) and os.path.isdir(os.path.join(folder, "config")):
            return folder
        parent = os.path.dirname(folder)
        if parent == folder:
            break
        folder = parent
    stop(f"no folder with src/ and config/ found above {here}. Pass --repo_root")


def find_one(root, sub, name, explicit):
    if explicit:
        if not os.path.isfile(explicit):
            stop(f"not found: {explicit}")
        return explicit
    hits = sorted(glob.glob(os.path.join(root, sub, "**", name), recursive=True))
    hits = [h for h in hits if "/.ipynb_checkpoints/" not in h]
    if len(hits) != 1:
        stop(f"{name}: expected 1 file under {os.path.join(root, sub)}, found {len(hits)}: {hits}. "
             f"Pass its path with the matching --<domain>_bronze / _qc / _config option")
    return hits[0]


def entry_files(cfg, entry):
    """Landing paths of one YAML entry (same rule as the loaders' resolve_files)."""
    root = cfg["landing_root"]
    if entry.get("files"):
        names = [f["name"] if isinstance(f, dict) else f for f in entry["files"]]
        return sorted({os.path.join(root, entry["path"], n) for n in names})
    return sorted(glob.glob(os.path.join(root, entry["path"]))) or [os.path.join(root, entry["path"])]


def precheck(plan):
    print("== 1. pre-checks (nothing is written)")
    problems = []
    for d, p in plan.items():
        cfg = yaml.safe_load(open(p["config"], encoding="utf-8"))
        p["cfg"] = cfg
        print(f"  {d}: bronze {p['bronze']}\n  {' ' * len(d)}  qc     {p['qc']}\n  {' ' * len(d)}  config {p['config']}")
        for key in p["keys"]:
            entry = (cfg.get("sources") or {}).get(key)
            if entry is None:
                problems.append(f"{d}: '{key}' is not in {p['config']} (old YAML?)")
                continue
            for f in entry_files(cfg, entry):
                ok = os.path.isfile(f)
                print(f"    {'ok     ' if ok else 'MISSING'} {key}: {f}")
                if not ok:
                    problems.append(f"{key}: landing file missing: {f}")
    METADATA_TABLE = f"{PREFIX}bronze.ingestion_metadata"
    if spark.catalog.tableExists(METADATA_TABLE):
        cols = {c.lower() for c in spark.table(METADATA_TABLE).columns}
        missing = [c for c in METADATA_COLUMNS if c not in cols]
        if missing:
            problems.append(f"{METADATA_TABLE} has no {missing}: run ingestion_metadata_fix.sql Part 1 first "
                            "(runbook incident 3)")
        else:
            print(f"  ok      {METADATA_TABLE} has {', '.join(METADATA_COLUMNS)}")
    else:
        print(f"  note    {METADATA_TABLE} does not exist yet; the loader creates it")
    if problems:
        for x in problems:
            print("  PROBLEM", x)
        stop(f"{len(problems)} pre-check problem(s). Nothing was run")


def run_script(path, args, label):
    print(f"\n== {label}\n   {os.path.basename(path)} {' '.join(args)}")
    started = time.time()
    saved = sys.argv
    sys.argv = [path, *args]
    try:
        runpy.run_path(path, run_name="__main__")
    except SystemExit as e:
        if e.code not in (None, 0):
            stop(f"{label} exited with {e.code}")
    except Exception as e:
        stop(f"{label} failed: {type(e).__name__}: {str(e)[:500]}")
    finally:
        sys.argv = saved
    print(f"   done in {time.time() - started:.0f}s")


def expected_total(qc):
    exp = (qc or {}).get("expected_rows")
    if isinstance(exp, dict):
        return sum(int(v) for v in exp.values())
    return int(exp) if exp is not None else None


def loaded_rows(p, key):
    """Rows per file and sheet of one source in its bronze table, for the files the YAML lists."""
    entry = p["cfg"]["sources"][key]
    table = entry["bronze_table"].strip('"')
    if not spark.catalog.tableExists(table):
        return table, []
    files = ", ".join("'" + os.path.relpath(f, p["cfg"]["landing_root"]) + "'" for f in entry_files(p["cfg"], entry))
    blank_x = "count_if(nullif(trim(X), '') IS NULL)" if key == "hdx_healthsites" else "CAST(NULL AS BIGINT)"
    return table, spark.sql(f"""
        SELECT _source_file, _source_sheet, count(*) AS n, {blank_x} AS blank_x
        FROM {table}
        WHERE _source_key = '{entry.get("source_key_override", key)}' AND _source_file IN ({files})
        GROUP BY _source_file, _source_sheet ORDER BY 1, 2""").collect()


def check_loaded(p, label):
    """After a bronze load: every listed source must have the YAML expected_rows, else stop before QC."""
    bad = []
    for key in p["keys"]:
        table, rows = loaded_rows(p, key)
        total, want = sum(r.n for r in rows), expected_total(p["cfg"]["sources"][key].get("qc"))
        print(f"   {'ok' if want is None or total == want else 'MISMATCH':8s} {key}: {total} rows in {table} "
              f"(expected {want})")
        if total == 0 or (want is not None and total != want):
            bad.append(key)
    if bad:
        stop(f"{label}: {bad} not loaded as expected. Read the loader output above; QC was not run")


def summary(plan):
    print("\n== 4. summary")
    for d, p in plan.items():
        for key in p["keys"]:
            entry = p["cfg"]["sources"][key]
            table, rows = loaded_rows(p, key)
            total, want = sum(r.n for r in rows), expected_total(entry.get("qc"))
            flag = "ok" if want is None or total == want else "MISMATCH"
            print(f"  {flag:8s} {table}: {total} rows (YAML expected_rows {want})")
            for r in rows:
                extra = f", blank X {r.blank_x}" if r.blank_x is not None else ""
                print(f"           {os.path.basename(r._source_file)} [{r._source_sheet or '-'}]: {r.n}{extra}")
            if spark.catalog.tableExists(f"{PREFIX}quality.v_table_health"):
                for h in spark.sql(f"""
                        SELECT overall_status, checks_fail, checks_warn, last_checked_at
                        FROM {PREFIX}quality.v_table_health
                        WHERE layer = 'bronze' AND (table_name = '{table}' OR table_name = '{table.split('.')[-1]}')""").collect():
                    print(f"           latest QC: {h.overall_status} (fail {h.checks_fail}, warn {h.checks_warn}) "
                          f"at {h.last_checked_at}")


def main():
    global PREFIX
    a = parse_args()
    PREFIX = f"{a.catalog}." if a.catalog else ""
    root = repo_root(a.repo_root)
    print(f"repo root: {root}")
    domains = list(DOMAINS) if a.only == "all" else [a.only]
    plan = {}
    for d in domains:
        spec = DOMAINS[d]
        plan[d] = {
            "keys": spec["keys"],
            "bronze": find_one(root, "src", spec["bronze"], getattr(a, f"{d}_bronze")),
            "qc": find_one(root, "src", spec["qc"], getattr(a, f"{d}_qc")),
            "config": find_one(root, "config", spec["config"], getattr(a, f"{d}_config")),
        }
    precheck(plan)
    if a.dry_run == "true":
        print("\ndry run: pre-checks passed, nothing was run")
        return
    step = 2
    for d, p in plan.items():
        keys = ",".join(p["keys"])
        common = ["--source_keys", keys, "--config_path", p["config"]]
        run_script(p["bronze"], common, f"{step}a. {d} bronze load")
        check_loaded(p, f"{step}a. {d} bronze load")
        run_script(p["qc"], common + ["--fail_on_error", a.fail_on_qc], f"{step}b. {d} bronze QC")
        step += 1
    summary(plan)
    print("\nNext: Healthsites silver chain (builder with newest-file filter -> 00_reference -> 01..04 -> "
          "facilities_silver_qc.py). Diseases silver is unchanged.")


if __name__ == "__main__":
    main()