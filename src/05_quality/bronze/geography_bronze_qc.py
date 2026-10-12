# Landing -> Bronze quality checks for the geography domain (config-driven).
# Purpose: reconcile an explicit completed PSGC landing snapshot with Bronze.
# Source records, keys, projected attributes and snapshot lineage are checked.
# Does not modify Bronze, Silver, landing files or the check registry.
# Results append to the existing YAML qc_results_table using the team's schema.
# QC batch_id = source_key:checksum; Bronze's batch UUID is preserved in detail.
# Each execution has a new validation_id: audit history intentionally appends.
# Run one writer per snapshot; do not modify landing or Bronze during QC.
# Landing validation helpers are embedded; no sibling-file import is needed.
# Check IDs default to descriptive GEO_LB_* codes, not assumed Bxx registry IDs.
# Set sources.psgc.ingestion_qc.check_ids to approved registry IDs when available.
# CLI: --config_path ... --landing_batch_path ... --bronze_batch_id ...
#      --content_checksum ... --expected_record_count 43762
#      [--run_id <job-run-id>] [--write_results yes|no]
# write_results defaults to yes; no prints results without audit writes.
# A FAIL raises after results are saved. Post-load failure does not undo Bronze.

import argparse
import hashlib
import json
import os
import re
import traceback
import uuid
from datetime import datetime, timezone
from pathlib import Path

import yaml
from pyspark.sql import SparkSession, functions as F

LOADER_VERSION = "2026-10-13.2"
SOURCE_KEY = "psgc"
QC_SCHEMA = """run_id string, validation_id string, batch_id string, source_key string,
table_name string, layer string, executed_at timestamp, check_id string,
check_name string, check_type string, column_name string, admin_level int,
status string, severity string, fail_count long, total_count long, fail_pct double,
threshold double, observed string, expected string, detail string"""

# -----------------------------------------------------------------------------
# Shared source validation helpers (kept self-contained for Job deployment)
# -----------------------------------------------------------------------------

def find_config(explicit=None):
    # Look beside this script and in nearby configuration directories.
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
        raise ValueError("bronze_table must be catalog.schema.table using letters, numbers or underscores.")
    return ".".join(f"`{part}`" for part in parts)

def matching_manifest(path, source, version, endpoint):
    marker = path / "_SUCCESS"
    manifest_path = path / "manifest.json"
    if not marker.is_file() or not manifest_path.is_file():
        return None
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("Manifest must be a JSON object.")
    if manifest.get("status") != "landed":
        return None
    if (manifest.get("source_name"), manifest.get("source_version"), manifest.get("endpoint")) != (source, version, endpoint):
        return None
    if marker.read_text(encoding="utf-8").strip() != manifest.get("run_id"):
        raise ValueError("Success marker does not match manifest run_id.")
    return manifest

def validate_batch(path, manifest):
    for field in ("page_count", "record_count", "landed_record_count", "expected_record_count"):
        value = manifest.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"Invalid manifest count: {field}.")
    if manifest["page_count"] < 1 or manifest["record_count"] < 1:
        raise ValueError("Empty batches cannot be loaded into Bronze.")
    names = manifest.get("files")
    if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
        raise ValueError("Manifest files must be a list of filenames.")
    expected = {
        name for page in range(1, manifest["page_count"] + 1)
        for name in (f"page_{page:04d}.json", f"records_page_{page:04d}.ndjson")
    }
    if len(names) != len(expected) or set(names) != expected:
        raise ValueError("Manifest file list does not match its page count.")
    actual = {p.name for p in path.iterdir() if p.name.startswith(("page_", "records_page_"))}
    if actual != expected:
        raise ValueError("Landing page files do not match manifest.")
    hashes, seen = [], set()
    total = 0
    record_paths = []
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
                    raise ValueError("Missing or non-string geographic code; preserve source codes as strings.")
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
    if any(manifest[field] != total for field in ("record_count", "landed_record_count", "expected_record_count")):
        raise ValueError("Landed counts do not reconcile with manifest.")
    checksum = hashlib.sha256("\n".join(sorted(hashes)).encode("utf-8")).hexdigest()
    if checksum != manifest.get("content_checksum"):
        raise ValueError("Landing content checksum does not match manifest.")
    return record_paths, total

# -----------------------------------------------------------------------------
# QC execution and audit results
# -----------------------------------------------------------------------------


def run_checks(spark, args):
    path = find_config(args.config_path)
    config = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError("YAML must be a mapping.")
    cfg = config.get("sources", config)[SOURCE_KEY]
    table = cfg["bronze_table"]
    qc_table = cfg["qc_results_table"]
    qualified_table(table)
    qc_sql = qualified_table(qc_table)
    if qc_table.lower() == table.lower():
        raise ValueError("QC results table must differ from Bronze.")
    check_ids = (cfg.get("ingestion_qc") or {}).get("check_ids", {})
    if not isinstance(check_ids, dict):
        raise ValueError("ingestion_qc.check_ids must be a mapping.")
    # Fail early rather than altering a shared audit table or creating an assumed schema.
    if args.write_results == "yes":
        if not spark.catalog.tableExists(qc_table):
            raise ValueError("Configured QC results table must already exist.")
        expected_schema = {f.name: f.dataType.simpleString() for f in spark.createDataFrame([], QC_SCHEMA).schema}
        actual_schema = {f.name: f.dataType.simpleString() for f in spark.table(qc_table).schema}
        if expected_schema != actual_schema:
            raise ValueError("QC table schema differs from the supplied team contract.")
        if spark.sql(f"DESCRIBE DETAIL {qc_sql}").first()["format"].lower() != "delta":
            raise ValueError("QC results table must use Delta.")

    run_id = args.run_id or str(uuid.uuid4())
    validation_id = str(uuid.uuid4())
    executed_at = datetime.now(timezone.utc).replace(tzinfo=None)
    results = []
    source_df = target_df = None
    audit_batch = f"{SOURCE_KEY}:{args.content_checksum}"
    context = {"source_version": str(cfg["version"]), "source_endpoint": str(cfg["endpoint"]).strip("/"),
               "bronze_batch_id": args.bronze_batch_id, "landing_batch_path": args.landing_batch_path}

    def add(name, kind, failures=None, total=None, column=None, observed=None, expected=None, detail="", failed=None):
        bad = bool(failures) if failed is None else failed
        pct = float(failures / total) if failures is not None and total else None
        info = detail + "; " + json.dumps(context, separators=(",", ":"))
        check_id = str(check_ids.get(name, "GEO_LB_" + name.upper()))
        results.append((run_id, validation_id, audit_batch, SOURCE_KEY, table, "bronze", executed_at,
                        check_id, name, kind, column, None, "FAIL" if bad else "PASS", "FAIL",
                        failures, total, pct, 0.0, None if observed is None else str(observed),
                        None if expected is None else str(expected), info[:500]))

    try:
        root = Path(cfg["landing_path"]).resolve()
        batch = Path(args.landing_batch_path).resolve()
        if not batch.is_relative_to(root):
            raise ValueError("Selected batch must be inside configured landing_path.")
        manifest = matching_manifest(batch, str(cfg["source_name"]), str(cfg["version"]), str(cfg["endpoint"]).strip("/"))
        if manifest is None:
            raise ValueError("Selected landing batch is incomplete or mismatches configuration.")
        paths, count = validate_batch(batch, manifest)
        if manifest["content_checksum"] != args.content_checksum or count != args.expected_record_count:
            raise ValueError("Landing manifest does not match the supplied successful Bronze handoff.")
        add("landing_integrity", "CONSISTENCY", observed="validated", expected="valid completed batch",
            detail="Validated marker, manifest, files, JSON, counts, uniqueness and content checksum.")
        # Reconstruct the same source projections used by the loader.
        raw = spark.read.text(paths)
        def value(name):
            return F.get_json_object(F.col("value"), f"$.{name}")
        def nonblank(expr):
            return F.when(F.length(F.trim(expr)) > 0, expr)
        fields = ["area_name", "correspondence_code", "geographic_level", "reg", "prv", "mun", "bgy",
                  "old_name", "city_class", "income_classification", "urban_rural", "island_region"]
        source_df = raw.select(
            F.coalesce(nonblank(value("code")), nonblank(value("psgc_code"))).alias("psgc_code"),
            *[value(name).alias(name) for name in fields], value("status").alias("record_status"),
            value("version").alias("record_version"),
            F.coalesce(value("populations"), value("population_data")).alias("populations_json"),
            F.col("value").alias("source_record_json"),
        )
        base = spark.table(table)
        required = set(source_df.columns) | {"source_system", "source_version", "source_endpoint", "content_checksum", "batch_id", "raw_path", "ingested_at"}
        missing = required - set(base.columns)
        add("bronze_columns", "SCHEMA", observed=sorted(missing), expected="no missing columns", failed=bool(missing))
        if missing:
            raise ValueError(f"Bronze columns missing: {sorted(missing)}")
        target_df = base.filter(
            (F.col("source_system") == str(cfg["source_name"]))
            & (F.col("source_version") == str(cfg["version"]))
            & (F.col("source_endpoint") == str(cfg["endpoint"]).strip("/"))
            & (F.col("content_checksum") == args.content_checksum)
        )
        total = target_df.count()
        source_count = source_df.count()
        add("source_parse_count", "RECONCILIATION", observed=source_count, expected=count, failed=source_count != count)
        add("snapshot_nonempty", "COMPLETENESS", observed=total, expected="> 0", failed=total == 0)
        add("snapshot_row_count", "RECONCILIATION", observed=total, expected=count, failed=total != count,
            detail="Value comparison; no row-level fail percentage for count differences.")
        blank = F.col("psgc_code").isNull() | (F.length(F.trim("psgc_code")) == 0)
        add("bronze_key_required", "COMPLETENESS", target_df.filter(blank).count(), total, "psgc_code")
        duplicates = target_df.groupBy("psgc_code").count().filter(F.col("count") > 1).agg(F.sum(F.col("count") - 1).alias("n")).first()["n"] or 0
        add("bronze_key_unique", "UNIQUENESS", int(duplicates), total, "psgc_code", detail="Counts excess records per code.")
        source_keys = source_df.select("psgc_code").distinct()
        target_keys = target_df.select("psgc_code").distinct()
        add("missing_bronze_keys", "RECONCILIATION", source_keys.join(target_keys, "psgc_code", "left_anti").count(), source_count, "psgc_code")
        add("extra_bronze_keys", "RECONCILIATION", target_keys.join(source_keys, "psgc_code", "left_anti").count(), total, "psgc_code")
        joined = target_df.alias("t").join(source_df.alias("s"), "psgc_code")
        payload_bad = ~F.col("t.source_record_json").eqNullSafe(F.col("s.source_record_json"))
        add("source_payload_match", "CONSISTENCY", joined.filter(payload_bad).select("psgc_code").distinct().count(), target_keys.count(), "source_record_json",
            detail="Exact landed JSON text comparison, consistent with ingestion retry checks.")
        bad = F.lit(False)
        for name in source_df.columns:
            if name not in ("psgc_code", "source_record_json"):
                bad = bad | ~F.col(f"t.{name}").eqNullSafe(F.col(f"s.{name}"))
        add("projected_attributes_match", "CONSISTENCY", joined.filter(bad).select("psgc_code").distinct().count(), target_keys.count(),
            detail="Checks every exposed source attribute using the loader's extraction rules.")
        lineage_bad = (~F.col("batch_id").eqNullSafe(F.lit(args.bronze_batch_id))
                       | F.col("raw_path").isNull() | (F.length(F.trim("raw_path")) == 0)
                       | F.col("ingested_at").isNull())
        add("snapshot_lineage", "CONSISTENCY", target_df.filter(lineage_bad).count(), total,
            detail="Existing raw_path/ingested_at may be retained from the original identical snapshot load.")
        add("qc_execution", "EXECUTION", observed="completed", expected="completed")
    except Exception as exc:
        print(f"QC execution error: {type(exc).__name__}: {exc}")
        traceback.print_exc()
        add("qc_execution", "EXECUTION", observed="error", expected="completed",
            detail=f"{type(exc).__name__}: {exc}", failed=True)

    df = spark.createDataFrame(results, QC_SCHEMA)
    df.select("check_id", "check_name", "status", "fail_count", "total_count", "observed", "expected").show(100, truncate=False)
    if args.write_results == "yes":
        # Logging failures propagate: do not report a successful audited execution.
        df.write.format("delta").mode("append").saveAsTable(qc_table)
        print("QC results saved:", qc_table)
    print("Validation ID:", validation_id)
    print("QC batch identity:", audit_batch)
    failures = [row[8] for row in results if row[12] == "FAIL"]
    if failures:
        raise RuntimeError("Landing -> Bronze QC FAILED: " + ", ".join(failures))
    print("Landing -> Bronze QC PASSED.")
    return validation_id


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Geography landing to Bronze QC")
    parser.add_argument("--config_path", default=None)
    parser.add_argument("--landing_batch_path", required=True)
    parser.add_argument("--bronze_batch_id", required=True)
    parser.add_argument("--content_checksum", required=True)
    parser.add_argument("--expected_record_count", required=True, type=int)
    parser.add_argument("--run_id", default=None, help="Optional actual Job run ID; otherwise a QC execution UUID")
    parser.add_argument("--write_results", choices=("yes", "no"), default="yes")
    args = parser.parse_args(argv)
    if args.expected_record_count < 1:
        parser.error("expected_record_count must be positive")
    if not re.fullmatch(r"[0-9a-f]{64}", args.content_checksum):
        parser.error("content_checksum must be a SHA-256 hex string")
    return args


def main(argv=None):
    args = parse_args(argv)
    print(f"Geography landing -> Bronze QC {LOADER_VERSION}")
    return run_checks(SparkSession.builder.getOrCreate(), args)


if __name__ == "__main__":
    main()
