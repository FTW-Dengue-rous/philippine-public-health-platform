# Bronze ingestion for the geography domain (config-driven).
#
# Purpose
#   Reads config/sources_geography.yaml and loads a completed PSGC landing
#   snapshot into its Bronze Delta table. It does not call the REST API.
#
# Extraction conventions
#   - Source attributes remain STRING; casting/business rules belong in Silver.
#   - Original record JSON and nested population JSON are retained.
#   - Landing files and manifests are never modified.
#
# Lineage columns added to every row
#   source_system, source_version, source_endpoint, batch_id,
#   content_checksum, raw_path, ingested_at
#
# Safety checks
#   1. Completed batch: _SUCCESS and landed manifest match the configured source.
#   2. Files, counts, checksum, JSON records and MERGE keys are validated.
#   3. Target schema and Delta format are checked before writing.
#   4. Missing table is created automatically; no bronze_setup.sql is required.
#   5. Insert-only MERGE preserves existing rows for an identical snapshot.
#   6. Stored records and counts are reconciled after MERGE.
#   Run one writer per snapshot. A post-write failure does not undo the MERGE.
#   Another snapshot for the same version is blocked for downstream compatibility.
#
# Separate quality workflow
#   Source/landing -> Bronze QC should use the printed exact snapshot handoff.
#   The existing Bronze -> Silver gate remains a separate workflow.
#   This loader does not write ingestion_metadata or QC result tables.
#
# How to run (Spark-enabled environment with Delta support, e.g. Databricks)
#   python geography_bronze.py
#       - Validate and preview the newest completed matching batch; no writes.
#   python geography_bronze.py --config_path /Workspace/.../sources_geography.yaml
#       - Use an explicit configuration file.
#   python geography_bronze.py --landing_batch_path /Volumes/.../run_id=... --write_to_bronze yes
#       - Load an explicit completed batch.
#   The target catalog/schema must exist. Requires: pyyaml, pyspark, Delta support.

import argparse
import hashlib
import json
import os
import re
import uuid
from datetime import datetime
from pathlib import Path

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

LOADER_VERSION = "2026-10-13.1"


# -----------------------------------------------------------------------------
# Configuration and landing validation
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
    raise FileNotFoundError(
        "sources_geography.yaml not found. Pass --config_path with its full path."
    )


def qualified_table(name):
    parts = name.split(".")
    if len(parts) != 3 or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", p) for p in parts):
        raise ValueError(
            "bronze_table must be catalog.schema.table using letters, numbers or underscores."
        )
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
    if (manifest.get("source_name"), manifest.get("source_version"), manifest.get("endpoint")) != (
        source,
        version,
        endpoint,
    ):
        return None
    if marker.read_text(encoding="utf-8").strip() != manifest.get("run_id"):
        raise ValueError("Success marker does not match manifest run_id.")
    return manifest


def select_batch(root, source, version, endpoint, explicit=""):
    root = Path(root).resolve()
    if explicit:
        path = Path(explicit).resolve()
        if not path.is_relative_to(root):
            raise ValueError("landing_batch_path must be inside the configured landing_path.")
        manifest = matching_manifest(path, source, version, endpoint)
        if manifest is None:
            raise ValueError(
                "Selected batch is incomplete or does not match YAML source/version/endpoint."
            )
        return path, manifest
    candidates = []
    version_root = root / "raw" / f"version={version}"
    for path in version_root.glob("run_id=*"):
        if not path.is_dir():
            continue
        manifest = matching_manifest(path, source, version, endpoint)
        if manifest is not None:
            completed = datetime.fromisoformat(manifest["finished_at"])
            if completed.tzinfo is None:
                raise ValueError("Manifest finished_at must include a timezone.")
            candidates.append((completed, str(path), manifest))
    if not candidates:
        raise ValueError("No completed matching landing batch found. Run API → landing first.")
    _, path, manifest = max(candidates, key=lambda item: (item[0], item[1]))
    return Path(path), manifest


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
        name
        for page in range(1, manifest["page_count"] + 1)
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
                    raise ValueError(
                        "Missing or non-string geographic code; preserve source codes as strings."
                    )
                if code in seen:
                    raise ValueError("Duplicate geographic code in landing batch.")
                seen.add(code)
                version = record.get("version")
                if version is not None and str(version) != manifest["source_version"]:
                    raise ValueError("Record version does not match landing manifest.")
                canonical = json.dumps(
                    record, sort_keys=True, separators=(",", ":"), ensure_ascii=False
                )
                hashes.append(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
                page_records.append(record)
                total += 1
        if results != page_records:
            raise ValueError("Raw API page and landed records differ.")
    if any(
        manifest[field] != total
        for field in ("record_count", "landed_record_count", "expected_record_count")
    ):
        raise ValueError("Landed counts do not reconcile with manifest.")
    checksum = hashlib.sha256("\n".join(sorted(hashes)).encode("utf-8")).hexdigest()
    if checksum != manifest.get("content_checksum"):
        raise ValueError("Landing content checksum does not match manifest.")
    return record_paths, total


# -----------------------------------------------------------------------------
# Ingest one PSGC snapshot: build, validate, write and reconcile
# -----------------------------------------------------------------------------


def ingest_source(spark, args):
    CONFIG_PATH = find_config(args.config_path or os.environ.get("PSGC_CONFIG_PATH", "").strip())
    with CONFIG_PATH.open(encoding="utf-8") as source:
        config = yaml.safe_load(source)
    if not isinstance(config, dict):
        raise ValueError("YAML must contain a mapping.")
    sources = config.get("sources", config)
    if not isinstance(sources, dict) or not isinstance(sources.get("psgc"), dict):
        raise ValueError("Expected psgc or sources.psgc settings in YAML.")
    psgc_cfg = sources["psgc"]
    SOURCE_NAME = str(psgc_cfg["source_name"])
    SOURCE_VERSION = str(psgc_cfg["version"])
    ENDPOINT = str(psgc_cfg["endpoint"]).strip("/")
    LANDING_PATH = str(psgc_cfg["landing_path"])
    BRONZE_TABLE = str(psgc_cfg["bronze_table"])
    BRONZE_SQL = qualified_table(BRONZE_TABLE)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", SOURCE_VERSION):
        raise ValueError("Invalid source version.")
    BATCH_PATH, MANIFEST = select_batch(
        LANDING_PATH,
        SOURCE_NAME,
        SOURCE_VERSION,
        ENDPOINT,
        args.landing_batch_path,
    )
    RECORD_PATHS, RECORD_COUNT = validate_batch(BATCH_PATH, MANIFEST)
    CONTENT_CHECKSUM = MANIFEST["content_checksum"]
    RUN_ID = MANIFEST["run_id"]
    print("Config:", str(CONFIG_PATH))
    print("Verified landing batch:", str(BATCH_PATH))
    print("Records:", RECORD_COUNT)
    print("Bronze table:", BRONZE_TABLE)

    WRITE_TO_BRONZE = args.write_to_bronze
    if WRITE_TO_BRONZE not in ("yes", "no"):
        raise ValueError("write_to_bronze must be yes or no.")

    # Preserve original record JSON and expose source attributes without cleansing.
    records_df = spark.read.text(RECORD_PATHS)

    def source_value(name):
        return F.get_json_object(F.col("value"), f"$.{name}")

    def nonblank(expr):
        return F.when(F.length(F.trim(expr)) > 0, expr)

    SOURCE_FIELDS = [
        "area_name",
        "correspondence_code",
        "geographic_level",
        "reg",
        "prv",
        "mun",
        "bgy",
        "old_name",
        "city_class",
        "income_classification",
        "urban_rural",
        "island_region",
    ]
    bronze_df = records_df.select(
        F.coalesce(nonblank(source_value("code")), nonblank(source_value("psgc_code"))).alias(
            "psgc_code"
        ),
        *[source_value(name).alias(name) for name in SOURCE_FIELDS],
        source_value("status").alias("record_status"),
        source_value("version").alias("record_version"),
        F.coalesce(source_value("populations"), source_value("population_data")).alias(
            "populations_json"
        ),
        F.col("value").alias("source_record_json"),
    ).withColumns(
        {
            "source_system": F.lit(SOURCE_NAME),
            "source_version": F.lit(SOURCE_VERSION),
            "source_endpoint": F.lit(ENDPOINT),
            "batch_id": F.lit(RUN_ID),
            "content_checksum": F.lit(CONTENT_CHECKSUM),
            "raw_path": F.lit(str(BATCH_PATH)),
            "ingested_at": F.current_timestamp(),
        }
    )
    if bronze_df.count() != RECORD_COUNT:
        raise RuntimeError("Spark input record count does not match validated landing batch.")
    if bronze_df.filter(F.col("psgc_code").isNull()).limit(1).count():
        raise RuntimeError("Bronze parsing produced a missing code.")
    if bronze_df.select("psgc_code").distinct().count() != RECORD_COUNT:
        raise RuntimeError("Bronze parsing produced duplicate geographic codes.")
    print("Bronze input validated.")

    # Prepare an absent table; do not alter an existing table's schema or rows.
    expected_schema = {
        field.name: field.dataType.simpleString() for field in bronze_df.schema.fields
    }
    TABLE_EXISTS = spark.catalog.tableExists(BRONZE_TABLE)
    if TABLE_EXISTS:
        actual_schema = {
            field.name: field.dataType.simpleString()
            for field in spark.table(BRONZE_TABLE).schema.fields
        }
        if actual_schema != expected_schema:
            raise RuntimeError(
                "Existing Bronze table schema differs from this notebook. "
                "Review the table schema before loading; no rows were merged."
            )
        detail = spark.sql(f"DESCRIBE DETAIL {BRONZE_SQL}").select("format").first()
        if detail["format"].lower() != "delta":
            raise RuntimeError("Bronze target must be a Delta table.")

    # Preserve the existing single-snapshot compatibility rule for downstream readers.
    # Preserve an existing batch ID when adding any missing rows for the same snapshot.
    SILVER_COMPATIBILITY_ISSUE = None
    if TABLE_EXISTS:
        version_snapshots = (
            spark.table(BRONZE_TABLE)
            .filter(F.col("source_version") == SOURCE_VERSION)
            .select("source_system", "source_endpoint", "content_checksum", "batch_id")
            .distinct()
            .collect()
        )
        if len(version_snapshots) > 1:
            SILVER_COMPATIBILITY_ISSUE = "Multiple existing Bronze snapshots for this version; review Silver selection before loading."
        elif version_snapshots:
            existing = version_snapshots[0]
            if (
                existing["source_system"],
                existing["source_endpoint"],
                existing["content_checksum"],
            ) != (SOURCE_NAME, ENDPOINT, CONTENT_CHECKSUM):
                SILVER_COMPATIBILITY_ISSUE = "A different Bronze snapshot already exists for this version. Current Silver expects one snapshot; loading another is blocked."
            elif not existing["batch_id"]:
                SILVER_COMPATIBILITY_ISSUE = (
                    "Existing snapshot has no batch ID; review lineage before loading."
                )
            else:
                bronze_df = bronze_df.withColumn("batch_id", F.lit(existing["batch_id"]))
                print("Preserving existing Bronze batch ID:", existing["batch_id"])
    if SILVER_COMPATIBILITY_ISSUE:
        print("Silver compatibility notice:", SILVER_COMPATIBILITY_ISSUE)

    KEYS = ["source_system", "source_version", "source_endpoint", "content_checksum", "psgc_code"]

    def target_snapshot():
        if not TABLE_EXISTS:
            return bronze_df.limit(0)
        return spark.table(BRONZE_TABLE).filter(
            (F.col("source_system") == SOURCE_NAME)
            & (F.col("source_version") == SOURCE_VERSION)
            & (F.col("source_endpoint") == ENDPOINT)
            & (F.col("content_checksum") == CONTENT_CHECKSUM)
        )

    def check_existing_rows(snapshot):
        if snapshot.filter(F.col("psgc_code").isNull()).limit(1).count():
            raise RuntimeError("Target snapshot contains a missing code.")
        if snapshot.groupBy("psgc_code").count().filter(F.col("count") > 1).limit(1).count():
            raise RuntimeError(
                "Target snapshot already contains duplicate codes; review before rerunning."
            )
        # Equality of source JSON is checked before treating a row as an idempotent match.
        if snapshot.join(bronze_df.select("psgc_code"), "psgc_code", "left_anti").limit(1).count():
            raise RuntimeError("Target snapshot contains unexpected codes.")
        conflicts = (
            snapshot.alias("target")
            .join(bronze_df.alias("source"), "psgc_code")
            .filter(
                ~F.col("target.source_record_json").eqNullSafe(F.col("source.source_record_json"))
            )
        )
        if conflicts.limit(1).count():
            raise RuntimeError(
                "Target snapshot has conflicting source JSON; review before merging."
            )

    check_existing_rows(target_snapshot())
    EXISTING_COUNT = target_snapshot().count()
    print("Preview — landing records:", RECORD_COUNT)
    print("Preview — existing matching Bronze records:", EXISTING_COUNT)
    print("Preview — records to insert:", RECORD_COUNT - EXISTING_COUNT)
    print("write_to_bronze:", WRITE_TO_BRONZE)

    if WRITE_TO_BRONZE != "yes":
        print("Preview complete. No Bronze rows were written.")
        print("To load, set write_to_bronze to yes and Run All again.")
    else:
        if SILVER_COMPATIBILITY_ISSUE:
            raise RuntimeError(SILVER_COMPATIBILITY_ISSUE + " No Bronze rows were written.")
        if not TABLE_EXISTS:
            definitions = ", ".join(
                f"`{name}` {dtype.upper()}" for name, dtype in expected_schema.items()
            )
            spark.sql(f"CREATE TABLE IF NOT EXISTS {BRONZE_SQL} ({definitions}) USING DELTA")
            TABLE_EXISTS = True
            actual_schema = {
                field.name: field.dataType.simpleString()
                for field in spark.table(BRONZE_TABLE).schema.fields
            }
            if actual_schema != expected_schema:
                raise RuntimeError(
                    "Concurrent table creation produced a different schema; no rows merged."
                )
        VIEW_NAME = f"psgc_bronze_incoming_{uuid.uuid4().hex}"
        bronze_df.createOrReplaceTempView(VIEW_NAME)
        condition = " AND ".join(f"target.`{name}` = source.`{name}`" for name in KEYS)
        columns = ", ".join(f"`{name}`" for name in bronze_df.columns)
        values = ", ".join(f"source.`{name}`" for name in bronze_df.columns)
        try:
            spark.sql(f"""
                MERGE INTO {BRONZE_SQL} AS target
                USING `{VIEW_NAME}` AS source
                ON {condition}
                WHEN NOT MATCHED THEN INSERT ({columns}) VALUES ({values})
            """)
        finally:
            spark.catalog.dropTempView(VIEW_NAME)

        stored = target_snapshot()
        check_existing_rows(stored)
        STORED_COUNT = stored.count()
        if STORED_COUNT != RECORD_COUNT:
            raise RuntimeError(
                "Bronze count does not reconcile with landing; rerun after investigating."
            )
        print("Landing → Bronze completed.")
        print("Bronze table:", BRONZE_TABLE)
        print("Records in this snapshot:", STORED_COUNT)
        print("Landing batch:", str(BATCH_PATH))
        print("Content checksum:", CONTENT_CHECKSUM)

        handoff = {
            "source_system": SOURCE_NAME,
            "source_version": SOURCE_VERSION,
            "source_endpoint": ENDPOINT,
            "content_checksum": CONTENT_CHECKSUM,
            "batch_id": bronze_df.select("batch_id").first()["batch_id"],
            "expected_record_count": RECORD_COUNT,
            "landing_batch_path": str(BATCH_PATH),
        }
        print("QC handoff:", json.dumps(handoff, sort_keys=True))
        # Optional handoff for notebook runners; Spark Python tasks use the printed JSON.
        if "dbutils" in globals():
            try:
                for key, value in handoff.items():
                    dbutils.jobs.taskValues.set(key=key, value=value)
            except Exception:
                print("Task values unavailable; use printed QC handoff.")
        return handoff


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="PSGC landing to Bronze ingestion")
    parser.add_argument("--config_path", default=None, help="Full path to sources_geography.yaml")
    parser.add_argument(
        "--landing_batch_path",
        default="",
        help="Completed batch folder; blank selects latest matching batch",
    )
    parser.add_argument(
        "--write_to_bronze",
        choices=("yes", "no"),
        default="no",
        help="Default no: preview without writes",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    print(f"Geography Bronze loader {LOADER_VERSION}")
    spark = SparkSession.builder.getOrCreate()
    return ingest_source(spark, args)


if __name__ == "__main__":
    main()
