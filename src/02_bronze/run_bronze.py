# =============================================================================
# run_bronze.py
# One command for the bronze layer: runs each domain's loader (incremental: only new or
# changed files load), then that domain's bronze QC for the sources that actually loaded.
#
#   domains   diseases, facilities, workforce, socioeconomic   (<domain>_bronze.py, <domain>_bronze_qc.py)
#
# Day to day
#   Land a file, add or update its YAML entry, run this. Unchanged files are skipped, so
#   bronze rows and load ids stay the same and silver built from them stays fresh.
#
# How to run
#   Databricks job, Python script task:  run_bronze.py  [options]
#   Notebook cell:
#     import sys, runpy
#     sys.argv = ["run_bronze.py", "--plan", "true"]          # first: what would load, nothing written
#     runpy.run_path("/Workspace/Repos/<you>/<repo>/scripts/run_bronze.py", run_name="__main__")
#
# Options
#   --domains        all (default) or a comma list, e.g. diseases,facilities
#   --source_keys    only these sources (each is sent to the domain whose YAML has it)
#   --plan true      print per file LOAD / skip and the reason; write nothing; no QC
#   --force_keys     reload these sources in full (after a YAML parsing-setting or loader change)
#   --force true     reload every selected source in full (old behaviour; makes silver stale)
#   --qc false       skip bronze QC
#   --fail_on_qc     true (default): a QC FAIL stops the run; false records and continues
#   --repo_root      repo folder; default: found from this file (the folder with src/ and config/)
#
# Order and stops
#   Per domain: loader -> QC (loaded keys only). A failed source does not stop the other
#   sources or domains; the run ends as failed with the list. A QC FAIL stops the run
#   (unless --fail_on_qc false), so nothing downstream starts on a bad load.
#
# Requires the incremental loaders (loader version 2026-10-14.1 or later): they accept
# --plan, --force, --force_keys and --result_path.
# =============================================================================

import argparse
import glob
import json
import os
import runpy
import sys
import tempfile
import time

import yaml

DOMAINS = ("diseases", "facilities", "workforce", "socioeconomic")


def parse_args():
    p = argparse.ArgumentParser(description="Bronze load (incremental) + bronze QC for every domain")
    p.add_argument("--domains", default="all")
    p.add_argument("--source_keys", default="")
    p.add_argument("--plan", default="false", choices=["true", "false"])
    p.add_argument("--force", default="false", choices=["true", "false"])
    p.add_argument("--force_keys", default="")
    p.add_argument("--qc", default="true", choices=["true", "false"])
    p.add_argument("--fail_on_qc", default="true", choices=["true", "false"])
    p.add_argument("--repo_root", default=None)
    a, _ = p.parse_known_args()
    return a


def csv_list(s):
    return [x.strip() for x in s.split(",") if x.strip()]


def repo_root(explicit):
    if explicit:
        return os.path.abspath(explicit)
    try:
        here = os.path.dirname(os.path.abspath(__file__))
    except NameError:                                   # pasted into a notebook cell
        here = os.getcwd()
    folder = here
    for _ in range(6):
        if os.path.isdir(os.path.join(folder, "src")) and os.path.isdir(os.path.join(folder, "config")):
            return folder
        parent = os.path.dirname(folder)
        if parent == folder:
            break
        folder = parent
    raise SystemExit(f"STOPPED: no folder with src/ and config/ above {here}. Pass --repo_root")


def find_one(root, sub, name):
    hits = [h for h in sorted(glob.glob(os.path.join(root, sub, "**", name), recursive=True))
            if "/.ipynb_checkpoints/" not in h]
    if len(hits) != 1:
        raise SystemExit(f"STOPPED: {name}: expected 1 file under {os.path.join(root, sub)}, found {len(hits)}: {hits}")
    return hits[0]


def run_script(path, args):
    """Run a script as __main__ in this process (reuses the Spark session). Returns the error or None."""
    saved = sys.argv
    sys.argv = [path, *args]
    try:
        runpy.run_path(path, run_name="__main__")
        return None
    except SystemExit as e:
        return None if e.code in (None, 0) else f"exit {e.code}"
    except Exception as e:
        return f"{type(e).__name__}: {str(e)[:500]}"
    finally:
        sys.argv = saved


def main():
    a = parse_args()
    root = repo_root(a.repo_root)
    domains = list(DOMAINS) if a.domains.strip().lower() == "all" else csv_list(a.domains)
    bad = [d for d in domains if d not in DOMAINS]
    if bad:
        raise SystemExit(f"STOPPED: unknown domain(s) {bad}. Use {', '.join(DOMAINS)} or all")

    # Scripts and YAMLs, and which domain each requested source key belongs to.
    plan = {}
    for d in domains:
        cfg_path = find_one(root, "config", f"sources_{d}.yaml")
        keys = set((yaml.safe_load(open(cfg_path, encoding="utf-8")).get("sources") or {}))
        plan[d] = {"bronze": find_one(root, "src", f"{d}_bronze.py"), "qc": find_one(root, "src", f"{d}_bronze_qc.py"),
                   "config": cfg_path, "keys": keys}
    wanted, forced = csv_list(a.source_keys), csv_list(a.force_keys)
    for k in wanted + forced:
        owners = [d for d in plan if k in plan[d]["keys"]]
        if len(owners) != 1:
            raise SystemExit(f"STOPPED: source key '{k}' is in {len(owners)} of the selected domains' YAMLs: {owners}")
    print(f"repo root: {root}\nmode: {'PLAN (nothing written)' if a.plan == 'true' else 'load'}"
          f"{' | force all' if a.force == 'true' else ''}\n")

    summary, failed, qc_failed = [], [], []
    for d, p in plan.items():
        keys = [k for k in wanted if k in p["keys"]]
        if wanted and not keys:
            continue                                    # no requested source in this domain
        force_keys = [k for k in forced if k in p["keys"]]
        result_path = os.path.join(tempfile.gettempdir(), f"bronze_result_{d}_{os.getpid()}.json")
        if os.path.exists(result_path):
            os.remove(result_path)
        args = ["--config_path", p["config"], "--result_path", result_path, "--plan", a.plan, "--force", a.force]
        if keys:
            args += ["--source_keys", ",".join(keys)]
        if force_keys:
            args += ["--force_keys", ",".join(force_keys)]

        print(f"========== {d}: bronze {'plan' if a.plan == 'true' else 'load'}")
        started = time.time()
        err = run_script(p["bronze"], args)
        if not os.path.exists(result_path):            # the loader stopped before its result was written
            failed.append(f"{d}: {err or 'no result written'}")
            summary.append((d, "-", "-", "-", f"loader stopped: {err}"))
            continue
        r = json.load(open(result_path, encoding="utf-8"))
        if r.get("failed") or r.get("audit_failed"):
            failed.append(f"{d}: failed {r.get('failed')}, audit log not written {r.get('audit_failed')}")
        if a.plan == "true":
            summary.append((d, ",".join(r["would_load"]) or "-", "", "", "plan only"))
            continue

        qc_status = "not run"
        if r["loaded"] and a.qc == "true":
            print(f"\n========== {d}: bronze QC for {r['loaded']}")
            qc_err = run_script(p["qc"], ["--config_path", p["config"], "--source_keys", ",".join(r["loaded"]),
                                          "--fail_on_error", a.fail_on_qc])
            qc_status = "PASS" if not qc_err else f"FAIL ({qc_err[:120]})"
            if qc_err:
                qc_failed.append(d)
        elif not r["loaded"]:
            qc_status = "nothing loaded"
        summary.append((d, ",".join(r["loaded"]) or "-", ",".join(r["unchanged"]) or "-",
                        ",".join(r["failed"]) or "-", qc_status))
        print(f"   {d} done in {time.time() - started:.0f}s\n")
        if qc_failed and a.fail_on_qc == "true":
            break                                       # stop before the next domain

    print("\n========== summary")
    for d, loaded, unchanged, fail, qc in summary:
        if a.plan == "true":
            print(f"  {d:14s} would load: {loaded}")
        else:
            print(f"  {d:14s} loaded: {loaded}\n  {'':14s} unchanged: {unchanged}\n  {'':14s} failed: {fail} | QC: {qc}")
    rerun = [d for d, loaded, *_ in summary if loaded not in ("-", "")]
    if a.plan != "true" and rerun:
        print(f"\nBronze changed for: {rerun}. Rerun their silver builds (reference -> builds -> silver QC), then gold.")
    if failed or qc_failed:
        raise RuntimeError(f"bronze run failed. Loader: {failed or 'ok'}; QC failed: {qc_failed or 'none'}")
    print("\nBronze run complete.")


if __name__ == "__main__":
    main()