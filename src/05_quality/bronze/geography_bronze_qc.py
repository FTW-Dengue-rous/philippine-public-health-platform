# =============================================================================
# geography_bronze_qc.py
# Bronze QC for the geography domain (PSGC snapshot, source_key psgc).
#
# What it does
#   Runs after geography_bronze.py. Re-validates the completed PSGC landing batch the loader
#   used, then checks that the Bronze snapshot is a complete, faithful copy of it: same
#   records, same keys, same projected attributes, correct lineage, and the same row count
#   the loader logged. It changes nothing in landing, Bronze or Silver.
#
# Output (public_health.quality, written through dq_utils.DQRun, like the other bronze QC)
#   qc_results    one row per check, status PASS / WARN / FAIL
#   run_log       one row for this QC execution (domain geography, source_keys psgc)
#   table_stats   row count and Delta version of the Bronze table
#   profile       only with --profile true (populations_json is large)
#   qc_results.batch_id = psgc:<content_checksum>, the exact snapshot checked.
#   The loader's own batch id (a run UUID) is kept in detail.
#
# Checks (one fixed meaning per code)
#   GB00 QC ran without error                                  FAIL
#   GB01 landing batch is complete and matches the handoff     FAIL
#   GB02 Bronze has every required column                      FAIL
#   GB03 landing records parse to the expected count           FAIL
#   GB04 snapshot has rows                                     FAIL
#   GB05 snapshot row count equals the landing count           FAIL
#   GB06 psgc_code is never blank                              FAIL
#   GB07 psgc_code is unique in the snapshot                   FAIL
#   GB08 no landing code is missing from Bronze                FAIL
#   GB09 no Bronze code is missing from landing                FAIL
#   GB10 stored source JSON equals the landed JSON             FAIL
#   GB11 projected attributes equal the loader's extraction    FAIL
#   GB12 snapshot lineage (batch id, raw path, load time)      FAIL
#   GB13 rows equal the loader's ingestion_metadata count      FAIL
#        (WARN if the metadata table cannot be read)
#   Codes replace the old GEO_LB_<name> codes (2026-10-19). Add them to
#   quality_registry_seed.sql; GB12 and GB13 belong in v_check_attribute_override as
#   auditability.
#
# Gate
#   Results are written first, then the script raises if any check is FAIL
#   (--fail_on_error true, the default). In run_bronze.py a FAIL stops the run; the preload
#   gate (bronze_gate.py) then keeps geography silver from building on this snapshot.
#
# How to run
#   Normally from run_bronze.py --domains geography, which passes the loader's handoff.
#   By hand:
#     python geography_bronze_qc.py --landing_batch_path /Volumes/.../run_id=<id> \
#       --bronze_batch_id <loader batch id> --content_checksum <sha256> \
#       --expected_record_count 43762 [--job_run_id {{job.run_id}}] [--fail_on_error true]
#     --write_results no prints the results and writes nothing (dry run).
#   With none of the four handoff arguments, the script uses the latest 'processed'
#   ingestion_metadata row for psgc (batch_id, content_checksum, raw_file_path,
#   record_count), so a notebook run needs no arguments:
#     python geography_bronze_qc.py [--fail_on_error false]
#   Pass all four or none; a partial set stops with an error.
#   --run_id is still accepted as the old name of --job_run_id.
#
# Requires: pyyaml, pyspark, dq_utils.py (found automatically in the quality folder),
# quality_setup.sql already run. Runs on Python 3.10+.
# =============================================================================

import argparse
import hashlib
import json
import os
import re
import sys
import traceback
from pathlib import Path

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

QC_VERSION = "2026-10-19.2"
DOMAIN = "geography"
SOURCE_KEY = "psgc"
SCRIPT_NAME = "geography_bronze_qc.py"
DEFAULT_METADATA_TABLE = "public_health.bronze.ingestion_metadata"

# check_id: (check_name, check_type, severity). Same values go into quality_registry_seed.sql.
CHECKS = {
    "GB00": ("QC ran without error", "EXECUTION", "FAIL"),
    "GB01": ("landing batch matches handoff", "CONSISTENCY", "FAIL"),
    "GB02": ("required columns present", "SCHEMA", "FAIL"),
    "GB03": ("landing records parse to expected count", "RECONCILIATION", "FAIL"),
    "GB04": ("snapshot has rows", "COMPLETENESS", "FAIL"),
    "GB05": ("snapshot row count matches landing", "RECONCILIATION", "FAIL"),
    "GB06": ("psgc_code not blank", "COMPLETENESS", "FAIL"),
    "GB07": ("psgc_code unique", "UNIQUENESS", "FAIL"),
    "GB08": ("no landing codes missing from bronze", "RECONCILIATION", "FAIL"),
    "GB09": ("no bronze codes missing from landing", "RECONCILIATION", "FAIL"),
    "GB10": ("source JSON matches landing", "CONSISTENCY", "FAIL"),
    "GB11": ("projected attributes match", "CONSISTENCY", "FAIL"),
    "GB12": ("snapshot lineage complete", "COMPLETENESS", "FAIL"),
    "GB13": ("rows match ingestion metadata", "RECONCILIATION", "FAIL"),
}

# Source attributes the loader projects from each record (same list as geography_bronze.py).
SOURCE_FIELDS = [
    "area_name", "correspondence_code", "geographic_level", "reg", "prv", "mun", "bgy",
    "old_name", "city_class", "income_classification", "urban_rural", "island_region",
]
LINEAGE_COLUMNS = [
    "source_system", "source_version", "source_endpoint", "content_checksum", "batch_id",
    "raw_path", "ingested_at",
]


# -----------------------------------------------------------------------------
# dq_utils and config discovery (same search as the other QC scripts)
# -----------------------------------------------------------------------------

def _add_dq_utils_to_path():
    # Find dq_utils.py and put its folder on sys.path. Looks in this file's folder and the
    # working directory, up to five levels above each, and in any *quality* folder there.
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


def find_config(explicit=None):
    # Explicit path, or sources_geography.yaml beside this file / the working directory or in
    # a config folder up to five levels above them.
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise FileNotFoundError(f"Config file not found: {explicit}")
        return path.resolve()
    starts = [Path.cwd()]
    if "__file__" in globals():
        starts.insert(0, Path(__file__).resolve().parent)
    for start in starts:
        for parent in (start, *list(start.parents)[:5]):
            for sub in ("", "config", "configs", "conf"):
                candidate = parent / sub / "sources_geography.yaml"
                if candidate.is_file():
                    return candidate
    raise FileNotFoundError("sources_geography.yaml not found. Pass --config_path with its full path.")


def qualified_table(name):
    parts = name.split(".")
    if len(parts) != 3 or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", p) for p in parts):
        raise ValueError(f"Table names must be catalog.schema.table: {name}")
    return ".".join(f"`{part}`" for part in parts)


# -----------------------------------------------------------------------------
# Landing re-validation (independent of the loader; same rules)
# -----------------------------------------------------------------------------

def matching_manifest(path, source, version, endpoint):
    marker, manifest_path = path / "_SUCCESS", path / "manifest.json"
    if not marker.is_file() or not manifest_path.is_file():
        return None
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("Manifest must be a JSON object.")
    if manifest.get("status") != "landed":
        return None
    if (manifest.get("source_name"), manifest.get("source_version"), manifest.get("endpoint")) != (
            source, version, endpoint):
        return None
    if marker.read_text(encoding="utf-8").strip() != manifest.get("run_id"):
        raise ValueError("Success marker does not match manifest run_id.")
    return manifest


def validate_batch(path, manifest):
    # Returns (record file paths, record count). Raises on any landing inconsistency.
    for field in ("page_count", "record_count", "landed_record_count", "expected_record_count"):
        value = manifest.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"Invalid manifest count: {field}.")
    if manifest["page_count"] < 1 or manifest["record_count"] < 1:
        raise ValueError("Empty batches cannot be loaded into Bronze.")
    names = manifest.get("files")
    if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
        raise ValueError("Manifest files must be a list of filenames.")
    expected = {name for page in range(1, manifest["page_count"] + 1)
                for name in (f"page_{page:04d}.json", f"records_page_{page:04d}.ndjson")}
    if len(names) != len(expected) or set(names) != expected:
        raise ValueError("Manifest file list does not match its page count.")
    actual = {p.name for p in path.iterdir() if p.name.startswith(("page_", "records_page_"))}
    if actual != expected:
        raise ValueError("Landing page files do not match manifest.")
    hashes, seen, record_paths, total = [], set(), [], 0
    for page in range(1, manifest["page_count"] + 1):
        raw = json.loads((path / f"page_{page:04d}.json").read_text(encoding="utf-8"))
        results = raw.get("results") if isinstance(raw, dict) else None
        if isinstance(results, dict):
            results = results.get("psgc_data", results.get("data"))
        if not isinstance(results, list):
            raise ValueError("Raw API page has no supported results list.")
        record_path = path / f"records_page_{page:04d}.ndjson"
        record_paths.append(str(record_path))
        page_records = []
        with record_path.open(encoding="utf-8") as source:
            for line in source:
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("Landed record is not a JSON object.")
                code = record.get("code")
                if code is None or (isinstance(code, str) and not code.strip()):
                    code = record.get("psgc_code")
                if not isinstance(code, str) or not code.strip():
                    raise ValueError("Missing or non-string geographic code.")
                if code in seen:
                    raise ValueError("Duplicate geographic code in landing batch.")
                seen.add(code)
                version = record.get("version")
                if version is not None and str(version) != manifest["source_version"]:
                    raise ValueError("Record version does not match landing manifest.")
                canonical = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
                hashes.append(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
                page_records.append(record)
                total += 1
        if results != page_records:
            raise ValueError("Raw API page and landed records differ.")
    if any(manifest[f] != total for f in ("record_count", "landed_record_count", "expected_record_count")):
        raise ValueError("Landed counts do not reconcile with manifest.")
    checksum = hashlib.sha256("\n".join(sorted(hashes)).encode("utf-8")).hexdigest()
    if checksum != manifest.get("content_checksum"):
        raise ValueError("Landing content checksum does not match manifest.")
    return record_paths, total


# -----------------------------------------------------------------------------
# Dry-run recorder (--write_results no): same interface as DQRun, writes nothing
# -----------------------------------------------------------------------------

class PrintOnly:
    validation_id = run_id = "dry-run"

    def __init__(self):
        self.results = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def record(self, check_id, status=None, **kw):
        self.results.append((check_id, status))
        print(f"  {status:4} {check_id} {kw.get('check_name')}"
              + (f" | fail={kw.get('fail_count')}/{kw.get('total_count')}" if kw.get("fail_count") is not None else "")
              + (f" | observed={kw.get('observed')} expected={kw.get('expected')}" if kw.get("observed") is not None else ""))
        return status

    def capture_table_stats(self, table):
        return None

    def profile_table(self, table):
        return None


# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------

def run_checks(spark, dq, args, failures):
    cfg_path = find_config(args.config_path)
    config = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("YAML must be a mapping.")
    cfg = config.get("sources", config)[SOURCE_KEY]
    table = cfg["bronze_table"]
    qualified_table(table)
    metadata_table = str(cfg.get("metadata_table") or DEFAULT_METADATA_TABLE)
    source_name, version = str(cfg["source_name"]), str(cfg["version"])
    endpoint = str(cfg["endpoint"]).strip("/")
    if args.handoff_from is None:
        handoff_from_metadata(spark, args, metadata_table, source_name, table)
    batch = f"{SOURCE_KEY}:{args.content_checksum}"
    context = json.dumps({"source_version": version, "source_endpoint": endpoint,
                          "bronze_batch_id": args.bronze_batch_id,
                          "landing_batch_path": args.landing_batch_path,
                          "handoff_from": args.handoff_from}, separators=(",", ":"))

    def rec(check_id, bad, fail_count=None, total_count=None, column=None,
            observed=None, expected=None, detail="", status=None):
        # One result. PASS, or the check's severity when bad; status overrides (e.g. WARN).
        name, kind, severity = CHECKS[check_id]
        status = status or ("PASS" if not bad else severity)
        if status == "FAIL":
            failures.append(check_id)
        dq.record(check_id, table_name=table, source_key=SOURCE_KEY, batch_id=batch,
                  check_name=name, check_type=kind, severity=severity, status=status,
                  column_name=column, fail_count=fail_count, total_count=total_count,
                  observed=None if observed is None else str(observed),
                  expected=None if expected is None else str(expected),
                  detail=(f"{detail}; " if detail else "") + context)

    # GB01 landing batch: complete, valid, and the one the loader handed over
    root = Path(cfg["landing_path"]).resolve()
    landing = Path(args.landing_batch_path).resolve()
    if not landing.is_relative_to(root):
        raise ValueError("landing_batch_path must be inside the configured landing_path.")
    manifest = matching_manifest(landing, source_name, version, endpoint)
    if manifest is None:
        raise ValueError("Landing batch is incomplete or does not match the YAML source/version/endpoint.")
    paths, count = validate_batch(landing, manifest)
    matches = manifest["content_checksum"] == args.content_checksum and count == args.expected_record_count
    rec("GB01", not matches, observed=f"checksum={manifest['content_checksum'][:12]}…, records={count}",
        expected=f"checksum={args.content_checksum[:12]}…, records={args.expected_record_count}",
        detail="marker, manifest, files, JSON, counts, unique codes and content checksum validated")
    if not matches:
        raise ValueError("Landing manifest does not match the loader's handoff.")

    # Rebuild the loader's projection of the landed records
    raw = spark.read.text(paths)

    def value(name):
        return F.get_json_object(F.col("value"), f"$.{name}")

    def nonblank(expr):
        return F.when(F.length(F.trim(expr)) > 0, expr)

    source_df = raw.select(
        F.coalesce(nonblank(value("code")), nonblank(value("psgc_code"))).alias("psgc_code"),
        *[value(name).alias(name) for name in SOURCE_FIELDS],
        value("status").alias("record_status"),
        value("version").alias("record_version"),
        F.coalesce(value("populations"), value("population_data")).alias("populations_json"),
        F.col("value").alias("source_record_json"),
    )

    # GB02 required columns
    if not spark.catalog.tableExists(table):
        raise ValueError(f"Bronze table does not exist: {table}")
    base = spark.table(table)
    missing = sorted((set(source_df.columns) | set(LINEAGE_COLUMNS)) - set(base.columns))
    rec("GB02", bool(missing), observed=missing or "none", expected="no missing columns")
    if missing:
        raise ValueError(f"Bronze columns missing: {missing}")
    try:                                               # stats are extra; must not stop the checks
        dq.capture_table_stats(table)
    except Exception as e:
        print(f"  note: table stats skipped ({str(e)[:150]})")

    target_df = base.filter((F.col("source_system") == source_name) & (F.col("source_version") == version)
                            & (F.col("source_endpoint") == endpoint)
                            & (F.col("content_checksum") == args.content_checksum))
    total, source_count = target_df.count(), source_df.count()

    rec("GB03", source_count != count, observed=source_count, expected=count)
    rec("GB04", total == 0, observed=total, expected="> 0")
    rec("GB05", total != count, observed=total, expected=count)

    blank = F.col("psgc_code").isNull() | (F.length(F.trim("psgc_code")) == 0)
    n_blank = target_df.filter(blank).count()
    rec("GB06", n_blank > 0, fail_count=n_blank, total_count=total, column="psgc_code")

    dups = (target_df.groupBy("psgc_code").count().filter(F.col("count") > 1)
            .agg(F.sum(F.col("count") - 1).alias("n")).first()["n"] or 0)
    rec("GB07", dups > 0, fail_count=int(dups), total_count=total, column="psgc_code",
        detail="counts extra records per code")

    source_keys = source_df.select("psgc_code").distinct()
    target_keys = target_df.select("psgc_code").distinct()
    n_missing = source_keys.join(target_keys, "psgc_code", "left_anti").count()
    rec("GB08", n_missing > 0, fail_count=n_missing, total_count=source_count, column="psgc_code")
    n_extra = target_keys.join(source_keys, "psgc_code", "left_anti").count()
    rec("GB09", n_extra > 0, fail_count=n_extra, total_count=total, column="psgc_code")

    joined = target_df.alias("t").join(source_df.alias("s"), "psgc_code")
    n_keys = target_keys.count()
    payload_bad = ~F.col("t.source_record_json").eqNullSafe(F.col("s.source_record_json"))
    n_payload = joined.filter(payload_bad).select("psgc_code").distinct().count()
    rec("GB10", n_payload > 0, fail_count=n_payload, total_count=n_keys, column="source_record_json",
        detail="exact landed JSON text comparison")

    attr_bad = F.lit(False)
    for name in source_df.columns:
        if name not in ("psgc_code", "source_record_json"):
            attr_bad = attr_bad | ~F.col(f"t.{name}").eqNullSafe(F.col(f"s.{name}"))
    n_attr = joined.filter(attr_bad).select("psgc_code").distinct().count()
    rec("GB11", n_attr > 0, fail_count=n_attr, total_count=n_keys,
        detail="every projected attribute, using the loader's extraction rules")

    lineage_bad = (~F.col("batch_id").eqNullSafe(F.lit(args.bronze_batch_id)) | F.col("raw_path").isNull()
                   | (F.length(F.trim("raw_path")) == 0) | F.col("ingested_at").isNull())
    n_lineage = target_df.filter(lineage_bad).count()
    rec("GB12", n_lineage > 0, fail_count=n_lineage, total_count=total,
        detail="raw_path / ingested_at may be kept from the first load of an identical snapshot")

    # GB13 rows equal the loader's 'processed' audit row for this batch (same idea as B13)
    if not spark.catalog.tableExists(metadata_table):
        rec("GB13", True, status="WARN", observed="metadata table not found", expected=metadata_table)
    else:
        logged = spark.sql(f"""
            SELECT max_by(record_count, retrieved_at) AS n
            FROM {qualified_table(metadata_table)}
            WHERE batch_id = :batch AND source_name = :source AND bronze_table = :tbl
              AND lower(status) = 'processed'""",
            args={"batch": args.bronze_batch_id, "source": source_name, "tbl": table}).first()["n"]
        rec("GB13", logged is None or int(logged) != total, observed=total,
            expected="no processed audit row" if logged is None else int(logged),
            detail=f"{metadata_table}, batch_id = loader batch id")

    if args.profile == "true":
        try:
            dq.profile_table(table)
        except Exception as e:
            print(f"  note: profile skipped ({str(e)[:150]})")


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------

HANDOFF_ARGS = ("landing_batch_path", "bronze_batch_id", "content_checksum", "expected_record_count")


def validate_handoff(args, error):
    if args.expected_record_count is None or int(args.expected_record_count) < 1:
        error("expected_record_count must be positive")
    if not re.fullmatch(r"[0-9a-f]{64}", str(args.content_checksum or "")):
        error("content_checksum must be a SHA-256 hex string")
    if not args.landing_batch_path or not args.bronze_batch_id:
        error("landing_batch_path and bronze_batch_id must not be empty")


def handoff_from_metadata(spark, args, metadata_table, source_name, table):
    """Fill the four handoff values from the latest 'processed' ingestion_metadata row of this
    source and bronze table. The loader writes the same values there (raw_file_path = landing
    batch folder, record_count = rows of the snapshot)."""
    if not spark.catalog.tableExists(metadata_table):
        raise ValueError(f"No handoff arguments and {metadata_table} not found. "
                         "Run geography_bronze.py or pass the four handoff arguments.")
    row = spark.sql(f"""
        SELECT batch_id, content_checksum, raw_file_path, record_count, retrieved_at
        FROM {qualified_table(metadata_table)}
        WHERE source_name = :source AND bronze_table = :tbl AND lower(status) = 'processed'
        ORDER BY retrieved_at DESC LIMIT 1""", args={"source": source_name, "tbl": table}).first()
    if row is None:
        raise ValueError(f"No handoff arguments and no processed {metadata_table} row for "
                         f"{source_name} / {table}. Run geography_bronze.py first.")
    args.landing_batch_path = row["raw_file_path"]
    args.bronze_batch_id = row["batch_id"]
    args.content_checksum = row["content_checksum"]
    args.expected_record_count = None if row["record_count"] is None else int(row["record_count"])

    def error(msg):
        raise ValueError(f"ingestion_metadata handoff row is not usable: {msg}")
    validate_handoff(args, error)
    args.handoff_from = f"ingestion_metadata (processed {row['retrieved_at']})"
    print(f"Handoff from {metadata_table}: batch {args.bronze_batch_id}, "
          f"checksum {args.content_checksum[:12]}…, {args.expected_record_count} records")


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Geography (PSGC) bronze QC")
    p.add_argument("--config_path", default=None)
    # The loader handoff. run_bronze passes all four. Leave all four out to use the latest
    # 'processed' ingestion_metadata row for this source (manual or notebook runs).
    p.add_argument("--landing_batch_path", default=None)
    p.add_argument("--bronze_batch_id", default=None)
    p.add_argument("--content_checksum", default=None)
    p.add_argument("--expected_record_count", default=None, type=int)
    p.add_argument("--job_run_id", default=None, help="Databricks {{job.run_id}}")
    p.add_argument("--run_id", default=None, help="old name of --job_run_id (still accepted)")
    p.add_argument("--code_version", default=None, help="Git commit or tag of this code")
    p.add_argument("--fail_on_error", choices=("true", "false"), default="true",
                   help="true: raise after writing results if any check is FAIL")
    p.add_argument("--profile", choices=("true", "false"), default="false")
    p.add_argument("--write_results", choices=("yes", "no"), default="yes",
                   help="no: print results only, write nothing")
    args, _ = p.parse_known_args(argv)                 # notebook kernels pass their own arguments
    given = [n for n in HANDOFF_ARGS if getattr(args, n) is not None]
    if given and len(given) < len(HANDOFF_ARGS):
        p.error("pass all four handoff arguments or none: " + ", ".join("--" + n for n in HANDOFF_ARGS))
    args.handoff_from = "arguments" if given else None
    if given:
        validate_handoff(args, p.error)
    args.job_run_id = args.job_run_id or args.run_id
    return args


def main(argv=None):
    args = parse_args(argv)
    print(f"Geography bronze QC {QC_VERSION}")
    spark = SparkSession.builder.getOrCreate()
    failures = []
    if args.write_results == "yes":
        _add_dq_utils_to_path()
        from dq_utils import DQRun
        dq = DQRun(layer="bronze", domain=DOMAIN, script_name=SCRIPT_NAME, job_run_id=args.job_run_id,
                   source_keys=SOURCE_KEY, fail_on_error=False, code_version=args.code_version, spark=spark)
    else:
        dq = PrintOnly()
    # fail_on_error=False: DQRun writes every result and the run_log row first; the gate is
    # applied below, after the write, so a FAIL never loses its audit rows.
    with dq:
        try:
            run_checks(spark, dq, args, failures)
        except Exception as error:
            traceback.print_exc()
            name, kind, severity = CHECKS["GB00"]
            failures.append("GB00")
            # table_name is needed for the crash row to show in quality.v_open_issues
            try:
                cfg = yaml.safe_load(find_config(args.config_path).read_text(encoding="utf-8"))
                table = (cfg.get("sources", cfg).get(SOURCE_KEY) or {}).get("bronze_table")
            except Exception:
                table = None
            dq.record("GB00", table_name=table, source_key=SOURCE_KEY,
                      batch_id=f"{SOURCE_KEY}:{args.content_checksum}" if args.content_checksum else None,
                      check_name=name, check_type=kind,
                      severity=severity, status="FAIL", fail_count=1, total_count=1,
                      detail=f"{type(error).__name__}: {error}")
    print(f"Validation ID: {dq.validation_id}")
    if failures:
        message = "Geography bronze QC FAILED: " + ", ".join(sorted(set(failures)))
        if args.fail_on_error == "true":
            raise RuntimeError(message)
        print(message + " (--fail_on_error false: not raised)")
    else:
        print("Geography bronze QC passed.")
    return dq.validation_id


if __name__ == "__main__":
    main()