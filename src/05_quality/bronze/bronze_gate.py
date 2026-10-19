# =============================================================================
# Bronze QC state per source, read from public_health.quality. One file, two uses:
#
#   1. run_bronze.py imports it. A source that did not change is normally skipped,
#      so its QC does not run again. run_bronze asks this file which unchanged
#      sources are not cleared yet and runs their QC again (re-queue).
#   2. Preload gate. Run it as a job task right before a domain's silver build.
#      It stops the build when a bronze source the build reads is not cleared.
#
# State of one source (from its latest bronze QC run)
#   PASS         every check of the latest run passed
#   WARN         no FAIL, at least one WARN. Does not block; read it in v_open_issues
#   FAIL         the latest run has a FAIL, including B00 / HB00 (QC errored on this source)
#   CRASHED      a bronze QC run of the same domain crashed (run_log status ERROR) at or
#                after the latest result of this source, so the result may be incomplete
#   STALE        the source was loaded again after its latest QC: QC never saw this load
#                (only for sources that write ingestion_metadata)
#   NOT_CHECKED  no bronze QC result for this source at all
#
#   Blocking (the gate stops, run_bronze re-queues): FAIL, CRASHED, STALE, NOT_CHECKED.
#   --allow_unchecked true lets NOT_CHECKED through (for a source that has no QC script yet).
#
# Which sources the gate checks for a domain
#   (a) the enabled file sources of that domain in config/sources_<domain>.yaml, and
#   (b) every bronze source the latest successful silver build of that domain read
#       (quality.build_log + quality.build_inputs, input_kind = 'bronze_source').
#   (b) catches a source that was turned off in the YAML but is still read by silver.
#   --exclude_keys drops a source the silver build does not read (e.g. psa_psgc).
#   A key in several domains is checked once per domain (doh_fhsis_demographic: workforce and
#   facilities, two bronze tables). A QC result counts only for the domain of its QC run
#   (run_log.domain, same validation_id), so one domain's result never clears the other.
#   --source_keys checks only the listed sources.
#   geography (psgc, and psgc_population: the population payload in the same bronze rows) and
#   admin_boundaries (hdx_phl_admin) are not YAML file sources; they are listed in
#   FIXED_SOURCES below, so --domains geography / admin_boundaries works. psgc_population
#   shares the PSGC load log name, so a new PSGC load makes it STALE too.
#
# How to run (preload gate)
#   Databricks job, Python script task before the silver tasks of a domain:
#     bronze_gate.py --domains diseases
#     bronze_gate.py --domains admin_boundaries
#     bronze_gate.py --domains geography
#   By hand (notebook or terminal): no arguments, or --domains all, checks every domain.
#     Notebook cell:  import runpy, sys
#                     sys.argv = ["bronze_gate.py", "--domains", "diseases"]   # optional
#                     runpy.run_path("<repo>/src/05_quality/bronze/bronze_gate.py", run_name="__main__")
#   Exit: raises RuntimeError when a source is blocking, so the silver tasks after it
#   do not start. It writes nothing; the job run shows the reason.
#   Until a fix: fix the file or YAML, run run_bronze.py (it re-queues the QC), then rerun.
#
# Requires: pyspark, pyyaml. Reads quality.qc_results, run_log, build_log, build_inputs
# and bronze.ingestion_metadata. Timestamps in those tables are UTC.
# =============================================================================

import argparse
import glob
import os

import yaml

QUALITY_SCHEMA = "public_health.quality"
METADATA_TABLE = "public_health.bronze.ingestion_metadata"

BLOCKING = ("FAIL", "CRASHED", "STALE", "NOT_CHECKED")

# Sources that are not YAML file sources of their own domain, and the domain their
# bronze QC writes to run_log (the crash lookup matches on it).
FIXED_SOURCES = {
    "geography": {"psgc": "geography", "psgc_population": "population"},
    "admin_boundaries": {"hdx_phl_admin": "admin_boundaries"},
}

# A source whose ingestion_metadata.source_name is not its source_key. The PSGC loader logs
# the YAML psgc.source_name; metadata_names() reads it from config/sources_geography.yaml.
METADATA_NAME_KEYS = {"psgc": ("sources_geography.yaml", "psgc", "source_name"),
                      "psgc_population": ("sources_population.yaml", "psgc_population", "source_name")}


# -----------------------------------------------------------------------------
# State per source
# -----------------------------------------------------------------------------

def state_label(key, domain, pairs):
    """Output key: the source_key, or 'source_key (domain)' when the key is in several domains."""
    return key if sum(1 for k, _ in pairs if k == key) == 1 else f"{key} ({domain})"


def source_states(spark, key_domains, quality_schema=QUALITY_SCHEMA, metadata_table=METADATA_TABLE,
                  metadata_names=None):
    """Return {label: {state, source_key, domain, validation_id, last_qc_at, failed_checks,
    n_warn, crashed_at, last_load_at}}.

    key_domains: {source_key: qc_domain}, or a list of (source_key, qc_domain) pairs when one
    key belongs to several domains (doh_fhsis_demographic: workforce and facilities). A result
    counts for a pair only if its QC run (run_log, same validation_id) was of that domain, so
    one domain's result never clears the other. label = source_key, or 'source_key (domain)'
    for a key listed under several domains.
    metadata_names: {source_key: ingestion_metadata.source_name} where the two differ."""
    pairs = sorted(set(key_domains.items() if isinstance(key_domains, dict) else map(tuple, key_domains)))
    if not pairs:
        return {}
    q = quality_schema
    names = metadata_names or {}
    (spark.createDataFrame([(k, d, names.get(k, k)) for k, d in pairs],
                           "source_key string, domain string, metadata_name string")
     .createOrReplaceTempView("_gate_keys"))

    has_run_log = spark.catalog.tableExists(f"{q}.run_log")
    crash_sql = f"""
      crash AS (
        SELECT k.source_key, k.domain,
               max(g.started_at)                        AS crashed_at,
               max_by(g.validation_id, g.started_at)    AS crash_validation_id
        FROM _gate_keys k
        JOIN {q}.run_log g
          ON g.layer = 'bronze' AND g.status = 'ERROR' AND g.domain = k.domain
         AND (upper(trim(coalesce(g.source_keys, 'ALL'))) = 'ALL'
              OR array_contains(transform(split(g.source_keys, ','), x -> trim(x)), k.source_key))
        GROUP BY k.source_key, k.domain)""" if has_run_log else """
      crash AS (SELECT CAST(NULL AS STRING) AS source_key, CAST(NULL AS STRING) AS domain,
                       CAST(NULL AS TIMESTAMP) AS crashed_at,
                       CAST(NULL AS STRING) AS crash_validation_id WHERE false)"""
    # A result counts for (source_key, domain) only when its QC run was of that domain. Results
    # with no run_log row (none expected: DQRun writes both) are ignored, so the source is
    # NOT_CHECKED and gets its QC again, which is the safe side.
    domain_join = (f"JOIN {q}.run_log g ON g.validation_id = r.validation_id AND g.domain = k.domain"
                   if has_run_log else "")

    rows = spark.sql(f"""
      WITH r AS (
        SELECT r.source_key, k.domain, r.validation_id, r.executed_at, r.status, r.check_id
        FROM {q}.qc_results r
        JOIN _gate_keys k ON r.source_key = k.source_key
        {domain_join}
        WHERE r.layer = 'bronze'),
      latest AS (
        SELECT source_key, domain, max_by(validation_id, executed_at) AS validation_id
        FROM r GROUP BY source_key, domain),
      qc AS (
        SELECT l.source_key, l.domain, l.validation_id,
               max(r.executed_at)                                              AS last_qc_at,
               count_if(coalesce(r.status, '') NOT IN ('PASS', 'WARN'))        AS n_fail,
               count_if(r.status = 'WARN')                                     AS n_warn,
               concat_ws(',', sort_array(collect_set(
                 CASE WHEN coalesce(r.status, '') NOT IN ('PASS', 'WARN') THEN r.check_id END))) AS failed_checks
        FROM latest l
        JOIN r ON r.source_key = l.source_key AND r.domain = l.domain AND r.validation_id = l.validation_id
        GROUP BY l.source_key, l.domain, l.validation_id),
      {crash_sql.strip()}
      SELECT k.source_key, k.domain, qc.validation_id, qc.last_qc_at, qc.n_fail, qc.n_warn,
             qc.failed_checks, c.crashed_at, c.crash_validation_id
      FROM _gate_keys k
      LEFT JOIN qc ON qc.source_key = k.source_key AND qc.domain = k.domain
      LEFT JOIN crash c ON c.source_key = k.source_key AND c.domain = k.domain""").collect()

    loads = {}
    if metadata_table and spark.catalog.tableExists(metadata_table):
        loads = {r["source_key"]: r["last_load_at"] for r in spark.sql(f"""
            SELECT k.source_key, max(m.retrieved_at) AS last_load_at
            FROM {metadata_table} m JOIN _gate_keys k ON m.source_name = k.metadata_name
            WHERE lower(m.status) = 'processed'
            GROUP BY k.source_key""").collect()}

    out = {}
    for r in rows:
        last_qc, crashed, loaded = r["last_qc_at"], r["crashed_at"], loads.get(r["source_key"])
        if r["validation_id"] is None:
            state = "CRASHED" if crashed is not None else "NOT_CHECKED"
        elif r["n_fail"]:
            state = "FAIL"
        elif crashed is not None and (r["crash_validation_id"] == r["validation_id"] or crashed >= last_qc):
            state = "CRASHED"
        elif loaded is not None and loaded > last_qc:
            state = "STALE"
        elif r["n_warn"]:
            state = "WARN"
        else:
            state = "PASS"
        out[state_label(r["source_key"], r["domain"], pairs)] = {
            "state": state, "source_key": r["source_key"], "domain": r["domain"],
            "validation_id": r["validation_id"],
            "last_qc_at": last_qc, "failed_checks": r["failed_checks"] or None,
            "n_warn": r["n_warn"] or 0, "crashed_at": crashed, "last_load_at": loaded,
        }
    spark.catalog.dropTempView("_gate_keys")
    return out


def blocking(states, allow_unchecked=False):
    """Sources whose state stops the gate."""
    stop = set(BLOCKING) - ({"NOT_CHECKED"} if allow_unchecked else set())
    return {k: s for k, s in states.items() if s["state"] in stop}


def reason(s):
    """One line explaining a state, for logs."""
    st = s["state"]
    if st == "FAIL":
        return f"FAIL checks {s['failed_checks']} (validation {s['validation_id']})"
    if st == "CRASHED":
        return f"bronze QC of {s['domain']} crashed at {s['crashed_at']} (see quality.v_run_errors)"
    if st == "STALE":
        return f"loaded {s['last_load_at']} after its latest QC {s['last_qc_at']}"
    if st == "NOT_CHECKED":
        return "no bronze QC result"
    if st == "WARN":
        return f"{s['n_warn']} WARN (see quality.v_open_issues)"
    return "PASS"


def print_states(states, title):
    print(title)
    for k in sorted(states):
        s = states[k]
        print(f"  {s['state']:11s} {k:42s} {reason(s) if s['state'] != 'PASS' else ''}")


# -----------------------------------------------------------------------------
# Which sources a domain's silver build depends on
# -----------------------------------------------------------------------------

def yaml_sources(root):
    """{domain: {source_key: qc_domain}} for the enabled file sources of every sources_<domain>.yaml.
    Same rule as the bronze QC scripts: entry domain, a path and a bronze_table, enabled."""
    found = {}
    for path in sorted(glob.glob(os.path.join(root, "config", "**", "sources_*.yaml"), recursive=True)):
        if "/.ipynb_checkpoints/" in path:
            continue
        cfg = yaml.safe_load(open(path, encoding="utf-8")) or {}
        defaults = cfg.get("defaults") or {}
        for key, entry in (cfg.get("sources") or {}).items():
            e = {**defaults, **(entry or {})}
            if not (e.get("domain") and e.get("path") and e.get("bronze_table") and e.get("enabled", True)):
                continue
            k = e.get("source_key_override", key)
            found.setdefault(e["domain"], {})[k] = e["domain"]
    for d, keys in FIXED_SOURCES.items():
        found.setdefault(d, {}).update(keys)
    return found


def metadata_names(root):
    """{source_key: ingestion_metadata.source_name} for the sources in METADATA_NAME_KEYS."""
    out = {}
    for key, (file_name, entry, field) in METADATA_NAME_KEYS.items():
        hits = glob.glob(os.path.join(root, "config", "**", file_name), recursive=True)
        if hits:
            cfg = yaml.safe_load(open(hits[0], encoding="utf-8")) or {}
            value = ((cfg.get("sources") or cfg).get(entry) or {}).get(field)
            if value:
                out[key] = str(value)
    return out


def consumed_sources(spark, domain, quality_schema=QUALITY_SCHEMA):
    """Bronze sources read by the latest successful silver build of each table in the domain."""
    q = quality_schema
    if not (spark.catalog.tableExists(f"{q}.build_log") and spark.catalog.tableExists(f"{q}.build_inputs")):
        return set()
    spark.createDataFrame([(domain,)], "domain string").createOrReplaceTempView("_gate_domain")
    rows = spark.sql(f"""
        WITH latest AS (
          SELECT target_table, max_by(build_id, finished_at) AS build_id
          FROM {q}.build_log b JOIN _gate_domain d ON b.domain = d.domain
          WHERE b.layer = 'silver' AND b.status = 'succeeded'
          GROUP BY target_table)
        SELECT DISTINCT i.source_key
        FROM {q}.build_inputs i
        JOIN latest l ON l.build_id = i.build_id AND l.target_table = i.target_table
        WHERE i.input_kind = 'bronze_source' AND i.source_key IS NOT NULL""").collect()
    spark.catalog.dropTempView("_gate_domain")
    return {r["source_key"] for r in rows}


def find_repo_root(explicit=None):
    if explicit:
        return os.path.abspath(explicit)
    try:
        here = os.path.dirname(os.path.abspath(__file__))
    except NameError:
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


# -----------------------------------------------------------------------------
# Preload gate
# -----------------------------------------------------------------------------

def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Preload gate: stop a silver build on uncleared bronze sources")
    p.add_argument("--domains", default="",
                   help="comma list of silver domains, e.g. diseases,facilities, or all. "
                        "Default: all, unless --source_keys is given")
    p.add_argument("--source_keys", default="", help="check exactly these sources (added to --domains)")
    p.add_argument("--exclude_keys", default="", help="sources the silver build does not read")
    p.add_argument("--allow_unchecked", default="false", choices=["true", "false"])
    p.add_argument("--repo_root", default=None)
    p.add_argument("--quality_schema", default=QUALITY_SCHEMA)
    p.add_argument("--metadata_table", default=METADATA_TABLE)
    a, _ = p.parse_known_args(argv)
    return a


def csv_list(s):
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def main(argv=None):
    from pyspark.sql import SparkSession

    a = parse_args(argv)
    domains, explicit, excluded = csv_list(a.domains), csv_list(a.source_keys), set(csv_list(a.exclude_keys))
    if not domains and not explicit:
        domains = ["all"]                                # no arguments (e.g. a notebook run): check everything
    spark = SparkSession.builder.getOrCreate()

    root = find_repo_root(a.repo_root)
    by_domain = yaml_sources(root)
    if [d.lower() for d in domains] == ["all"]:
        domains = sorted(by_domain)
        print(f"Checking every domain: {', '.join(domains)}")
    def owners(k):
        """QC domains of a key across every YAML (a key can be in more than one)."""
        return sorted({qd for keys in by_domain.values() for kk, qd in keys.items() if kk == k})

    pairs, origin = set(), {}
    for d in domains:
        from_yaml = by_domain.get(d, {})
        from_builds = consumed_sources(spark, d, a.quality_schema)
        if not from_yaml and not from_builds:
            raise SystemExit(f"STOPPED: domain '{d}' has no YAML file sources and no recorded silver build inputs")
        for k, qd in from_yaml.items():
            pairs.add((k, qd))
        for k in from_builds - set(from_yaml):        # read by silver, not an enabled YAML source here
            pairs.update((k, qd) for qd in (owners(k) or [d]))
        for k in set(from_yaml) | from_builds:
            origin[k] = "yaml+build" if k in from_yaml and k in from_builds else "yaml" if k in from_yaml else "build"
    for k in explicit:
        pairs.update((k, qd) for qd in (owners(k) or [domains[0] if domains else k]))
        origin[k] = "argument"
    pairs = {(k, qd) for k, qd in pairs if k not in excluded}

    states = source_states(spark, sorted(pairs), a.quality_schema, a.metadata_table, metadata_names(root))
    print_states(states, f"Preload gate: {len(states)} bronze source(s) for {', '.join(domains + explicit)}")
    for k in sorted(origin):
        if origin[k] == "build" and any(s["source_key"] == k for s in states.values()):
            print(f"  note: {k} is read by the latest silver build but is not an enabled YAML source")
    stop = blocking(states, a.allow_unchecked == "true")
    if stop:
        raise RuntimeError("Preload gate FAILED. Bronze sources not cleared: "
                           + "; ".join(f"{k} ({reason(s)})" for k, s in sorted(stop.items()))
                           + ". Fix the source or YAML, run run_bronze.py (it re-runs their QC), then rerun.")
    print("Preload gate passed.")


if __name__ == "__main__":
    main()