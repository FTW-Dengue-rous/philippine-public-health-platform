# =============================================================================
# run_bronze.py
# One command for the bronze layer: runs each domain's loader (incremental: only new or
# changed files load), then that domain's bronze QC for the sources that loaded, plus the
# unchanged sources whose QC is not cleared yet (re-queue).
#
#   domains   diseases, facilities, workforce, socioeconomic   (<domain>_bronze.py, <domain>_bronze_qc.py)
#             geography          (geography_bronze.py, geography_bronze_qc.py,
#                                 config/sources_geography.yaml, source psgc)
#             admin_boundaries   (admin_boundaries_bronze.py, admin_boundaries_bronze_qc.py,
#                                 config/sources_geography.yaml, source hdx_phl_admin)
#   geography also runs psgc_population_bronze_qc.py (config/sources_population.yaml): the
#   population payload sits in the same geography_bronze rows. It runs after a geography load
#   (once geography QC has cleared), or when its own state is not cleared (re-queue).
#   geography and admin_boundaries have their own loader contracts (a landing snapshot / an
#   ingestion handoff instead of YAML file entries). A thin wrapper here calls each one and
#   maps its outcome to the same result as the file loaders, so all domains behave alike.
#
# Day to day
#   Land a file, add or update its YAML entry, run this. Unchanged files are skipped, so
#   bronze rows and load ids stay the same and silver built from them stays fresh.
#
# QC re-queue (why an unchanged source can still get QC)
#   Before: an unchanged source was skipped, so a source whose last QC FAILed stayed
#   failed, and the run still ended "complete". Now every unchanged source is looked up
#   in public_health.quality (bronze_gate.py). If it is FAIL, CRASHED, STALE or
#   NOT_CHECKED, its QC runs again in this run. Typical case: you fixed qc.expected_rows
#   in the YAML; the file did not change, but its QC reruns and clears it.
#
# QC result comes from the data, not from the exit code
#   After QC, the state of every checked source is read back from quality.qc_results.
#   So --fail_on_qc false still reports FAIL in the summary (it only stops raising).
#
# How to run
#   Databricks job, Python script task:  run_bronze.py  --job_run_id {{job.run_id}}  [options]
#   Notebook cell:
#     import sys, runpy
#     sys.argv = ["run_bronze.py", "--plan", "true"]          # first: what would load, nothing written
#     runpy.run_path("/Workspace/Repos/<you>/<repo>/src/02_bronze/run_bronze.py", run_name="__main__")
#
# Options
#   --domains        all (default) or a comma list, e.g. diseases,facilities
#   --source_keys    only these sources (each is sent to the domain that owns it)
#   --plan true      print per file LOAD / skip, and which QC would rerun; write nothing; no QC
#   --force_keys     reload these sources in full (after a YAML parsing-setting or loader change)
#   --force true     reload every selected source in full (old behaviour; makes silver stale)
#                    geography / admin_boundaries have no force: a new snapshot or source
#                    version loads by itself
#   --qc false       skip bronze QC (and the re-queue)
#   --fail_on_qc     true (default): a QC FAIL stops the run; false records, reports and continues
#   --job_run_id     passed to every QC script, so quality.run_log links to the job run
#   --code_version   Git commit, passed to every QC script
#   --repo_root      repo folder; default: found from this file (the folder with src/ and config/)
#
# Order and stops
#   Per domain: loader -> QC (loaded + re-queued keys). A failed source does not stop the
#   other sources or domains; the run ends as failed with the list. A QC FAIL stops the run
#   before the next domain (unless --fail_on_qc false), so nothing downstream starts on a bad load.
#
# Requires the incremental loaders (loader version 2026-10-14.1 or later): they accept
# --plan, --force, --force_keys and --result_path. geography_bronze.py and
# admin_boundaries_bronze.py 2026-10-19.1 or later (plan support). geography_bronze_qc.py
# 2026-10-19.1 or later (DQRun; accepts --job_run_id, --fail_on_error, --code_version).
# bronze_gate.py in the quality folder.
#
# Job note: geography (with the population payload QC) and admin_boundaries run only here; the
# job has no separate bronze load or bronze QC task for them. Their loaders are safe only with one writer at a time.
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

FILE_DOMAINS = ("diseases", "facilities", "workforce", "socioeconomic")
GEO, GEO_KEY = "geography", "psgc"
ADMIN, ADMIN_KEY = "admin_boundaries", "hdx_phl_admin"
FIXED = {GEO: GEO_KEY, ADMIN: ADMIN_KEY}           # domain -> its one source key
POP_KEY, POP_DOMAIN = "psgc_population", "population"   # QC of the population payload in geography_bronze
DOMAINS = (GEO, ADMIN) + FILE_DOMAINS              # geography first: every silver domain reads it


def parse_args():
    p = argparse.ArgumentParser(description="Bronze load (incremental) + bronze QC for every domain")
    p.add_argument("--domains", default="all")
    p.add_argument("--source_keys", default="")
    p.add_argument("--plan", default="false", choices=["true", "false"])
    p.add_argument("--force", default="false", choices=["true", "false"])
    p.add_argument("--force_keys", default="")
    p.add_argument("--qc", default="true", choices=["true", "false"])
    p.add_argument("--fail_on_qc", default="true", choices=["true", "false"])
    p.add_argument("--job_run_id", default=None)
    p.add_argument("--code_version", default=None)
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


def load_gate(path, attempts=3, wait_s=2):
    """Load bronze_gate.py. Retries a FileNotFoundError: right after a file is moved or
    uploaded, the workspace can list it before it can be opened. A notebook saved under the
    name bronze_gate.py is never readable as a file; the error says so."""
    for attempt in range(1, attempts + 1):
        try:
            return runpy.run_path(path, run_name="bronze_gate")
        except FileNotFoundError:
            if attempt == attempts:
                raise SystemExit(f"STOPPED: {path} is listed but cannot be opened after {attempts} tries. "
                                 "If it is a notebook, replace it with a plain .py file (Import -> File).")
            time.sleep(wait_s)


def yaml_keys(cfg_path):
    return set((yaml.safe_load(open(cfg_path, encoding="utf-8")) or {}).get("sources") or {})


def qc_source_keys(cfg_path):
    """{YAML entry name: source_key its QC results are written under}. Same rule as the QC
    scripts and bronze_gate.yaml_sources: source_key_override, else the entry name.
    Several entries can share one source_key (doh_fhsis_tb, doh_fhsis_morbidity, ... -> doh_fhsis)."""
    cfg = yaml.safe_load(open(cfg_path, encoding="utf-8")) or {}
    defaults = cfg.get("defaults") or {}
    out = {}
    for key, entry in (cfg.get("sources") or {}).items():
        e = {**defaults, **(entry or {})}
        out[key] = {"source_key": e.get("source_key_override", key), "enabled": bool(e.get("enabled", True))}
    return out


# -----------------------------------------------------------------------------
# Loaders. Each returns the same result shape:
#   {"loaded": [...], "unchanged": [...], "failed": [...], "would_load": [...], "audit_failed": [...]}
# or None when the loader stopped before it produced a result (error in `err`).
# -----------------------------------------------------------------------------

def load_file_domain(d, p, a, keys, force_keys):
    result_path = os.path.join(tempfile.gettempdir(), f"bronze_result_{d}_{os.getpid()}.json")
    if os.path.exists(result_path):
        os.remove(result_path)
    args = ["--config_path", p["config"], "--result_path", result_path, "--plan", a.plan, "--force", a.force]
    if keys:
        args += ["--source_keys", ",".join(keys)]
    if force_keys:
        args += ["--force_keys", ",".join(force_keys)]
    err = run_script(p["bronze"], args)
    if not os.path.exists(result_path):                # the loader stopped before its result was written
        return None, err or "no result written"
    return json.load(open(result_path, encoding="utf-8")), None


def load_admin_boundaries(p, a):
    # Thin wrapper: the HDX loader has its own contract (ingestion handoff.json in,
    # bronze_handoff.json out), so it is called directly and its outcome is mapped to the
    # common result shape. Its QC needs the bronze_handoff.json path, kept in "handoff".
    if a.force == "true":
        print(f"  note: --force does not apply to {ADMIN}; a new source version loads by itself")
    r = {"loaded": [], "unchanged": [], "failed": [], "would_load": [], "audit_failed": [], "handoff": None}
    try:
        module = runpy.run_path(p["bronze"], run_name="admin_boundaries_bronze")
        out = module["main"](["--config_path", p["config"], "--plan", a.plan])
    except SystemExit as e:
        if e.code not in (None, 0):
            r["failed"].append(ADMIN_KEY)
            return r, f"exit {e.code}"
        out = None
    except Exception as e:
        r["failed"].append(ADMIN_KEY)
        return r, f"{type(e).__name__}: {str(e)[:500]}"
    if a.plan == "true":                               # unchanged too, so the plan shows QC re-queue
        action = out.get("load_action") if isinstance(out, dict) else None
        (r["would_load"] if action == "LOAD" else r["unchanged"]).append(ADMIN_KEY)
        return r, None
    handoff = json.load(open(out, encoding="utf-8"))
    r["handoff"] = str(out)
    (r["loaded"] if handoff.get("write_outcome") == "loaded" else r["unchanged"]).append(ADMIN_KEY)
    return r, None


def load_geography(p, a):
    # Thin wrapper: the PSGC loader loads the latest completed landing snapshot and returns
    # a handoff dict (action, batch_id, content_checksum, landing_batch_path,
    # expected_record_count). Its QC takes those values as arguments, kept in "handoff".
    #   load / repair / backfill_audit -> loaded (QC runs)   unchanged -> unchanged
    #   blocked: preview reports it; a load raises, so the source counts as failed
    if a.force == "true":
        print(f"  note: --force does not apply to {GEO}; a new snapshot loads by itself")
    r = {"loaded": [], "unchanged": [], "failed": [], "would_load": [], "audit_failed": [], "handoff": None}
    try:
        module = runpy.run_path(p["bronze"], run_name="geography_bronze")
        out = module["main"](["--config_path", p["config"],
                              "--write_to_bronze", "no" if a.plan == "true" else "yes"])
    except Exception as e:
        r["failed"].append(GEO_KEY)
        return r, f"{type(e).__name__}: {str(e)[:500]}"
    action = (out or {}).get("action")
    if a.plan == "true":
        if action in ("load", "repair", "backfill_audit"):
            r["would_load"].append(GEO_KEY)
        elif action == "unchanged":                    # so the plan shows QC re-queue
            r["unchanged"].append(GEO_KEY)
        elif action == "blocked":
            r["failed"].append(GEO_KEY)
            return r, f"blocked: {(out or {}).get('load_issue')}"
        return r, None
    r["handoff"] = out
    (r["unchanged"] if action == "unchanged" else r["loaded"]).append(GEO_KEY)
    return r, None


def common_qc_args(a):
    common = ["--fail_on_error", a.fail_on_qc]
    if a.job_run_id:
        common += ["--job_run_id", a.job_run_id]
    if a.code_version:
        common += ["--code_version", a.code_version]
    return common


def qc_args(d, p, a, keys, r):
    common = common_qc_args(a)
    if d == ADMIN:
        return ["--bronze_handoff_path", r["handoff"]] + common
    if d == GEO:                                       # the loader's handoff identifies the snapshot
        h = r["handoff"]
        return ["--config_path", p["config"], "--landing_batch_path", h["landing_batch_path"],
                "--bronze_batch_id", h["batch_id"], "--content_checksum", h["content_checksum"],
                "--expected_record_count", str(h["expected_record_count"])] + common
    return ["--config_path", p["config"], "--source_keys", ",".join(keys)] + common


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

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
        if d in FIXED:
            cfg_path = find_one(root, "config", "sources_geography.yaml")
            if FIXED[d] not in yaml_keys(cfg_path):
                raise SystemExit(f"STOPPED: {FIXED[d]} is not in {cfg_path}")
            keys = {FIXED[d]}
        else:
            cfg_path = find_one(root, "config", f"sources_{d}.yaml")
            keys = yaml_keys(cfg_path)
        plan[d] = {"bronze": find_one(root, "src", f"{d}_bronze.py"), "qc": find_one(root, "src", f"{d}_bronze_qc.py"),
                   "config": cfg_path, "keys": keys,
                   "qc_keys": {} if d in FIXED else qc_source_keys(cfg_path)}
        if d == GEO:
            plan[d]["pop_qc"] = find_one(root, "src", "psgc_population_bronze_qc.py")
            plan[d]["pop_config"] = find_one(root, "config", "sources_population.yaml")
    wanted, forced = csv_list(a.source_keys), csv_list(a.force_keys)
    for k in wanted + forced:
        owners = [d for d in plan if k in plan[d]["keys"]]
        if len(owners) != 1:
            raise SystemExit(f"STOPPED: source key '{k}' is in {len(owners)} of the selected domains: {owners}")
    for k in set(forced) & set(FIXED.values()):
        raise SystemExit(f"STOPPED: --force_keys {k}: this source cannot be forced. A new snapshot or source "
                         "version loads by itself; a partial load must be deleted by hand first.")

    # QC state lookup (bronze_gate.py), only when QC or the plan needs it.
    gate, spark = None, None
    if a.qc == "true":
        gate = load_gate(find_one(root, "src", "bronze_gate.py"))
        from pyspark.sql import SparkSession
        spark = SparkSession.builder.getOrCreate()

    # {source_key: ingestion_metadata.source_name} where they differ (psgc, psgc_population ->
    # 'PSA PSGC'). The STALE check needs it. Keep this line with the gate load above.
    meta_names = gate["metadata_names"](root) if gate else {}

    def states_of(d, keys, p):
        """State per YAML entry name. QC results are stored under the entry's source_key
        (source_key_override), so look that key up and give its state to every entry."""
        if not keys:
            return {}
        sk = {k: (p["qc_keys"].get(k) or {}).get("source_key", k) for k in keys}
        st = gate["source_states"](spark, {sk[k]: d for k in keys}, metadata_names=meta_names)
        return {k: st[sk[k]] for k in keys}

    def pop_state():
        """State of the population payload QC. Its run_log domain is 'population'."""
        return gate["source_states"](spark, {POP_KEY: POP_DOMAIN}, metadata_names=meta_names)[POP_KEY]

    def with_shared_key(keys, p):
        """Add the enabled entries that share a source_key with one in keys. The gate reads the
        latest QC run of a source_key, so that run must cover every entry under it, or an older
        FAIL of a sibling entry would be hidden."""
        info = p["qc_keys"]
        shared = {(info.get(k) or {}).get("source_key") for k in keys} - {None}
        siblings = [k for k, v in sorted(info.items()) if v["source_key"] in shared and v["enabled"]]
        return list(dict.fromkeys(keys + siblings))

    print(f"repo root: {root}\nmode: {'PLAN (nothing written)' if a.plan == 'true' else 'load'}"
          f"{' | force all' if a.force == 'true' else ''}\n")

    summary, failed, qc_failed, qc_not_blocking = [], [], [], []
    for d, p in plan.items():
        keys = [k for k in wanted if k in p["keys"]]
        if wanted and not keys:
            continue                                    # no requested source in this domain
        force_keys = [k for k in forced if k in p["keys"]]

        print(f"========== {d}: bronze {'plan' if a.plan == 'true' else 'load'}")
        started = time.time()
        if d == ADMIN:
            r, err = load_admin_boundaries(p, a)
        elif d == GEO:
            r, err = load_geography(p, a)
        else:
            r, err = load_file_domain(d, p, a, keys, force_keys)
        if r is None:
            failed.append(f"{d}: {err}")
            summary.append({"domain": d, "loaded": [], "unchanged": [], "failed": [], "requeued": [],
                            "would_load": [], "qc": f"loader stopped: {err}"})
            continue
        if r.get("failed") or r.get("audit_failed"):
            failed.append(f"{d}: failed {r.get('failed')}, audit log not written {r.get('audit_failed')}"
                          + (f" ({err})" if err else ""))

        # Re-queue: unchanged sources whose bronze QC is not cleared.
        unchanged = r.get("unchanged") or []
        requeued = []
        if gate and unchanged:
            st = states_of(d, unchanged, p)
            requeued = [k for k in unchanged if st[k]["state"] in gate["BLOCKING"]]
            for k in requeued:
                print(f"  re-queue QC: {k} is {st[k]['state']} ({gate['reason'](st[k])})")

        # Population payload QC (geography only): re-queue when its own state is not cleared.
        pop_requeue = False
        if d == GEO and gate:
            pst = pop_state()
            if pst["state"] in gate["BLOCKING"]:
                pop_requeue = True
                print(f"  re-queue QC: {POP_KEY} is {pst['state']} ({gate['reason'](pst)})")
        shown_requeued = requeued + ([POP_KEY] if pop_requeue else [])

        if a.plan == "true":
            summary.append({"domain": d, "would_load": r.get("would_load") or [], "requeued": shown_requeued})
            continue

        loaded = r.get("loaded") or []
        qc_keys = list(dict.fromkeys(loaded + requeued))
        if qc_keys:
            expanded = with_shared_key(qc_keys, p)
            if len(expanded) > len(qc_keys):
                print(f"  QC also for {[k for k in expanded if k not in qc_keys]} (same source_key)")
            qc_keys = expanded
        qc_status = "not run"
        if qc_keys and gate:
            if d in FIXED and not r.get("handoff"):
                qc_status = "not run: the loader returned no handoff"
                qc_failed.append(d)
            else:
                print(f"\n========== {d}: bronze QC for {qc_keys}")
                qc_err = run_script(p["qc"], qc_args(d, p, a, qc_keys, r))
                st = states_of(d, qc_keys, p)
                stop = gate["blocking"](st)
                warns = [k for k in qc_keys if st[k]["state"] == "WARN"]
                if stop:
                    qc_status = "FAIL " + "; ".join(f"{k}: {gate['reason'](s)}" for k, s in sorted(stop.items()))
                    (qc_failed if a.fail_on_qc == "true" else qc_not_blocking).append(d)
                elif qc_err:                            # script error but every key cleared: report it
                    qc_status = f"FAIL (QC script: {qc_err[:120]})"
                    (qc_failed if a.fail_on_qc == "true" else qc_not_blocking).append(d)
                else:
                    qc_status = f"WARN ({', '.join(warns)})" if warns else "PASS"
        elif not qc_keys:
            qc_status = "nothing loaded, nothing to re-check"

        # Population payload QC: after a geography load, or when re-queued. Not when geography
        # QC did not clear: the snapshot itself is in question, and the run stops there anyway.
        if d == GEO and gate and (loaded or pop_requeue):
            if qc_status.startswith(("FAIL", "not run")):
                pop_status = "not run: geography QC not cleared"
            else:
                print(f"\n========== {d}: bronze QC for {POP_KEY} (population payload)")
                pop_err = run_script(p["pop_qc"], ["--config_path", p["pop_config"]] + common_qc_args(a))
                pst = pop_state()
                if pst["state"] in gate["BLOCKING"]:
                    pop_status = f"FAIL {gate['reason'](pst)}"
                    (qc_failed if a.fail_on_qc == "true" else qc_not_blocking).append(d)
                elif pop_err:
                    pop_status = f"FAIL (QC script: {pop_err[:120]})"
                    (qc_failed if a.fail_on_qc == "true" else qc_not_blocking).append(d)
                else:
                    pop_status = "WARN" if pst["state"] == "WARN" else "PASS"
            qc_status = f"{qc_status} | {POP_KEY}: {pop_status}"
        summary.append({"domain": d, "loaded": loaded, "unchanged": unchanged, "failed": r.get("failed") or [],
                        "requeued": shown_requeued, "qc": qc_status})
        print(f"   {d} done in {time.time() - started:.0f}s\n")
        if qc_failed and a.fail_on_qc == "true":
            break                                       # stop before the next domain

    def show(xs):
        return ",".join(xs) or "-"

    print("\n========== summary")
    for s in summary:
        d = s["domain"]
        if a.plan == "true":
            print(f"  {d:16s} would load: {show(s.get('would_load', []))}\n"
                  f"  {'':16s} QC would rerun: {show(s.get('requeued', []))}")
        else:
            print(f"  {d:16s} loaded: {show(s.get('loaded', []))}\n"
                  f"  {'':16s} unchanged: {show(s.get('unchanged', []))}\n"
                  f"  {'':16s} QC re-queued: {show(s.get('requeued', []))}\n"
                  f"  {'':16s} failed: {show(s.get('failed', []))} | QC: {s['qc']}")
    rerun = [s["domain"] for s in summary if s.get("loaded")]
    if a.plan != "true" and rerun:
        print(f"\nBronze changed for: {rerun}. Rerun their silver builds (gate -> reference -> builds -> silver QC), then gold.")
    if qc_not_blocking:
        print(f"\nQC FAIL recorded but not blocking (--fail_on_qc false): {qc_not_blocking}. "
              "The preload gate (bronze_gate.py) will still stop their silver builds.")
    if failed or qc_failed:
        raise RuntimeError(f"bronze run failed. Loader: {failed or 'ok'}; QC failed: {qc_failed or 'none'}")
    print("\nBronze run complete.")


if __name__ == "__main__":
    main()