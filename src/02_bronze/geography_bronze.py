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
#   7. Audit: one ingestion_metadata row per run, same 15-column schema and
#      statuses as the other bronze loaders (<domain>_bronze.py). If the audit
#      row cannot be written, the data stays committed and the run fails.
#   Run one writer per snapshot. A post-write failure does not undo the MERGE.
#   Another snapshot for the same version is blocked for downstream compatibility.
#
# What each run does (same idea as the incremental file loaders)
#   load            Snapshot not in Bronze      -> MERGE, log 'processed'
#   unchanged       Snapshot in Bronze, logged  -> no write, log 'skipped_duplicate'
#   backfill_audit  Snapshot in Bronze, no log  -> no write, log 'processed' for the
#                                                  existing batch (rows re-verified)
#   repair          Snapshot partly in Bronze, no log -> insert missing rows, log 'processed'
#   A snapshot that is logged but incomplete is blocked: delete its rows and reload.
#   The 'processed' row's batch_id always equals the Bronze rows' batch_id, which is
#   what bronze QC B13 and the silver lineage lookup match on.
#
# Separate quality workflow
#   Source/landing -> Bronze QC should use the printed exact snapshot handoff.
#   The existing Bronze -> Silver gate remains a separate workflow.
#   This loader writes ingestion_metadata (audit) but not QC result tables.
#
# How to run (Spark-enabled environment with Delta support, e.g. Databricks)
#   python geography_bronze.py
#       - Load the newest completed matching batch (default write_to_bronze yes).
#         Safe to rerun: an unchanged snapshot writes no Bronze rows, only a
#         'skipped_duplicate' audit row.
#   python geography_bronze.py --write_to_bronze no
#       - Validate and preview only; no Bronze or metadata writes. main() returns the
#         planned action ({"preview": True, "action": ...}); run_bronze.py --plan reads it.
#   python geography_bronze.py --config_path /Workspace/.../sources_geography.yaml
#       - Use an explicit configuration file.
#   python geography_bronze.py --landing_batch_path /Volumes/.../run_id=...
#       - Load an explicit completed batch.
#   Notebook (Run All): IPython launcher arguments are ignored. No options are
#   needed for a normal load. To change one, set it in a cell above this script,
#   either as environment variables:
#       import os
#       os.environ["PSGC_WRITE_TO_BRONZE"] = "no"   # preview only
#       # optional: os.environ["PSGC_LANDING_BATCH_PATH"] = "/Volumes/.../run_id=..."
#   or as arguments:
#       import sys
#       sys.argv = ["geography_bronze.py", "--write_to_bronze", "no"]
#   Command-line arguments override environment variables.
#   The target catalog/schema and ingestion_metadata must exist.
#   Requires: pyyaml, pyspark, Delta support.
#   Optional YAML key psgc.metadata_table (default public_health.bronze.ingestion_metadata).

import argparse
import hashlib
import json
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path

import yaml
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

LOADER_VERSION = "2026-10-19.1"
DEFAULT_METADATA_TABLE = "public_health.bronze.ingestion_metadata"

LINEAGE_COLUMNS = [
    "source_system",
    "source_version",
    "source_endpoint",
    "batch_id",
    "content_checksum",
    "raw_path",
    "ingested_at",
]

# Ingestion metadata: same 15 columns, order and meaning as the other bronze loaders
# (<domain>_bronze.py) and the API ingestion job. One row per run for this API snapshot.
METADATA_SCHEMA = [
    ("batch_id", "string"),          # equals the Bronze rows' batch_id for 'processed'
    ("source_name", "string"),       # source_name from YAML / manifest
    ("source_version", "string"),    # PSGC version from YAML / manifest
    ("endpoint", "string"),          # API endpoint
    ("content_checksum", "string"),  # manifest content checksum
    ("raw_file_path", "string"),     # landing batch folder
    ("record_count", "bigint"),      # rows of this snapshot in Bronze (reconciled after the write)
    ("page_count", "int"),           # API pages in the landing batch
    ("retrieved_at", "timestamp"),   # load time (UTC); equals the rows' ingested_at for 'processed'
    ("status", "string"),            # processed | skipped_duplicate
    ("bronze_table", "string"),
    ("source_sheet", "string"),      # null for API loads
    ("column_count", "int"),         # data columns written (lineage columns excluded)
    ("file_size_bytes", "bigint"),   # landing page + record files
    ("error_message", "string"),     # note on a backfilled / repaired / skipped row
]


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
            "Table names must be catalog.schema.table using letters, numbers or underscores."
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
# Ingestion metadata (audit), same pattern as the other bronze loaders
# -----------------------------------------------------------------------------


def metadata_row(**values):
    # One metadata row as a tuple in METADATA_SCHEMA order; missing values are null.
    unknown = set(values) - {name for name, _ in METADATA_SCHEMA}
    if unknown:
        raise KeyError(f"not in METADATA_SCHEMA: {sorted(unknown)}")
    return tuple(values.get(name) for name, _ in METADATA_SCHEMA)


def has_processed_metadata(spark, metadata_table, batch_id):
    # True if ingestion_metadata has a processed row for this batch ID.
    # Bronze QC (B13) reconciles Bronze rows to that row by batch_id.
    if not spark.catalog.tableExists(metadata_table):
        return False
    row = spark.sql(
        f"SELECT COUNT(*) AS n FROM {qualified_table(metadata_table)} "
        "WHERE batch_id = :batch_id AND status = 'processed'",
        args={"batch_id": batch_id},
    ).first()
    return row["n"] > 0


def log_metadata(spark, metadata_table, rows):
    # Append audit rows. Columns the existing table does not have are left out (with a
    # warning), as in the other loaders. The table itself must exist (ingestion_metadata.sql).
    if not spark.catalog.tableExists(metadata_table):
        raise RuntimeError(
            f"{metadata_table} does not exist; create it with ingestion_metadata.sql first."
        )
    schema = ", ".join(f"`{name}` {dtype}" for name, dtype in METADATA_SCHEMA)
    frame = spark.createDataFrame(rows, schema=schema)
    existing = {field.name for field in spark.table(metadata_table).schema.fields}
    missing = [name for name, _ in METADATA_SCHEMA if name not in existing]
    if missing:
        print("Warning: ingestion_metadata has no column(s)", missing, "- not logged.")
    keep = [name for name, _ in METADATA_SCHEMA if name in existing]
    frame.select(*keep).write.mode("append").saveAsTable(metadata_table)


# -----------------------------------------------------------------------------
# Ingest one PSGC snapshot: build, validate, write, reconcile and audit
# -----------------------------------------------------------------------------


def ingest_source(spark, args):
    CONFIG_PATH = find_config(args.config_path)
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
    METADATA_TABLE = str(psgc_cfg.get("metadata_table") or DEFAULT_METADATA_TABLE)
    qualified_table(METADATA_TABLE)
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
    PAGE_COUNT = MANIFEST["page_count"]
    FILE_SIZE_BYTES = sum((BATCH_PATH / name).stat().st_size for name in MANIFEST["files"])
    # One timestamp per run: used for the rows' ingested_at and the audit row's retrieved_at,
    # so the two match exactly (the lineage lookup joins on them).
    LOAD_TS = datetime.now(timezone.utc)
    print("Config:", str(CONFIG_PATH))
    print("Verified landing batch:", str(BATCH_PATH))
    print("Records:", RECORD_COUNT)
    print("Bronze table:", BRONZE_TABLE)
    print("Metadata table:", METADATA_TABLE)

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
            "ingested_at": F.lit(LOAD_TS),
        }
    )
    DATA_COLUMN_COUNT = len([c for c in bronze_df.columns if c not in LINEAGE_COLUMNS])
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
    # Preserve an existing batch ID when the same snapshot is already in Bronze.
    LOAD_ISSUE = None
    BATCH_ID = RUN_ID
    if TABLE_EXISTS:
        version_snapshots = (
            spark.table(BRONZE_TABLE)
            .filter(F.col("source_version") == SOURCE_VERSION)
            .select("source_system", "source_endpoint", "content_checksum", "batch_id")
            .distinct()
            .collect()
        )
        if len(version_snapshots) > 1:
            LOAD_ISSUE = "Multiple existing Bronze snapshots for this version; review Silver selection before loading."
        elif version_snapshots:
            existing = version_snapshots[0]
            if (
                existing["source_system"],
                existing["source_endpoint"],
                existing["content_checksum"],
            ) != (SOURCE_NAME, ENDPOINT, CONTENT_CHECKSUM):
                LOAD_ISSUE = "A different Bronze snapshot already exists for this version. Current Silver expects one snapshot; loading another is blocked."
            elif not existing["batch_id"]:
                LOAD_ISSUE = "Existing snapshot has no batch ID; review lineage before loading."
            else:
                BATCH_ID = existing["batch_id"]
                bronze_df = bronze_df.withColumn("batch_id", F.lit(BATCH_ID))
                print("Preserving existing Bronze batch ID:", BATCH_ID)

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

    # Decide what this run does, like the incremental file loaders.
    ALREADY_LOGGED = EXISTING_COUNT > 0 and has_processed_metadata(
        spark, METADATA_TABLE, BATCH_ID
    )
    if EXISTING_COUNT == 0:
        ACTION = "load"
    elif EXISTING_COUNT == RECORD_COUNT:
        ACTION = "unchanged" if ALREADY_LOGGED else "backfill_audit"
    elif not ALREADY_LOGGED:
        ACTION = "repair"
    else:
        ACTION = "blocked"
        LOAD_ISSUE = LOAD_ISSUE or (
            f"Bronze batch {BATCH_ID} is logged as processed but has only {EXISTING_COUNT} of "
            f"{RECORD_COUNT} rows. Delete its rows (batch_id = '{BATCH_ID}') and reload."
        )
    if LOAD_ISSUE:
        ACTION = "blocked"
        print("Load blocked:", LOAD_ISSUE)

    print("Preview — landing records:", RECORD_COUNT)
    print("Preview — existing matching Bronze records:", EXISTING_COUNT)
    print("Preview — records to insert:", RECORD_COUNT - EXISTING_COUNT)
    print("Preview — Bronze batch ID:", BATCH_ID)
    print("Preview — processed audit row already logged:", ALREADY_LOGGED)
    print("Preview — planned action:", ACTION)
    print("write_to_bronze:", WRITE_TO_BRONZE)

    if WRITE_TO_BRONZE != "yes":
        print("Preview complete. No Bronze or metadata rows were written.")
        print("To load, set write_to_bronze to yes (the default) and Run All again.")
        # Planned action for run_bronze.py --plan (load | unchanged | backfill_audit | repair | blocked).
        return {"preview": True, "action": ACTION, "load_issue": LOAD_ISSUE, "batch_id": BATCH_ID,
                "expected_record_count": RECORD_COUNT}

    if ACTION == "blocked":
        raise RuntimeError(LOAD_ISSUE + " No Bronze or metadata rows were written.")
    if not spark.catalog.tableExists(METADATA_TABLE):
        raise RuntimeError(
            f"{METADATA_TABLE} does not exist; create it with ingestion_metadata.sql first. "
            "No Bronze rows were written."
        )

    if ACTION in ("load", "repair"):
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
    else:
        print("Snapshot already in Bronze; no rows written.")

    # Reconcile what is stored, whatever the action.
    stored = target_snapshot()
    check_existing_rows(stored)
    STORED_COUNT = stored.count()
    if STORED_COUNT != RECORD_COUNT:
        raise RuntimeError(
            "Bronze count does not reconcile with landing; rerun after investigating."
        )
    stored_batches = [row["batch_id"] for row in stored.select("batch_id").distinct().collect()]
    if stored_batches != [BATCH_ID]:
        raise RuntimeError(
            f"Stored snapshot batch IDs {stored_batches} do not equal {BATCH_ID}; review before logging."
        )
    SNAPSHOT_LOADED_AT = stored.agg(F.min("ingested_at")).first()[0]

    # Audit row (step 7), same statuses and message style as the file loaders.
    common = dict(
        source_name=SOURCE_NAME,
        source_version=SOURCE_VERSION,
        endpoint=ENDPOINT,
        content_checksum=CONTENT_CHECKSUM,
        raw_file_path=str(BATCH_PATH),
        page_count=PAGE_COUNT,
        bronze_table=BRONZE_TABLE,
        source_sheet=None,
        column_count=DATA_COLUMN_COUNT,
        file_size_bytes=FILE_SIZE_BYTES,
    )
    if ACTION == "load":
        audit = metadata_row(
            batch_id=BATCH_ID, record_count=STORED_COUNT, retrieved_at=LOAD_TS,
            status="processed", error_message=None, **common,
        )
    elif ACTION == "repair":
        audit = metadata_row(
            batch_id=BATCH_ID, record_count=STORED_COUNT, retrieved_at=LOAD_TS,
            status="processed",
            error_message=(
                f"repaired: {RECORD_COUNT - EXISTING_COUNT} missing rows inserted into load "
                f"{BATCH_ID}; earlier rows keep their ingested_at"
            ),
            **common,
        )
    elif ACTION == "backfill_audit":
        audit = metadata_row(
            batch_id=BATCH_ID, record_count=STORED_COUNT, retrieved_at=SNAPSHOT_LOADED_AT,
            status="processed",
            error_message=(
                "audit row backfilled: bronze rows were loaded earlier without a log row; "
                f"re-verified against landing batch {RUN_ID}"
            ),
            **common,
        )
    else:  # unchanged
        audit = metadata_row(
            batch_id=str(uuid.uuid4()), record_count=STORED_COUNT, retrieved_at=LOAD_TS,
            status="skipped_duplicate",
            error_message=(
                f"unchanged: bronze rows are from load {BATCH_ID} "
                f"({SNAPSHOT_LOADED_AT:%Y-%m-%d %H:%M:%S} UTC)"
            ),
            **common,
        )
    try:
        log_metadata(spark, METADATA_TABLE, [audit])
    except Exception as exc:
        raise RuntimeError(
            f"Bronze rows are committed, but the ingestion_metadata audit row was not written "
            f"({type(exc).__name__}: {str(exc)[:300]}). Rerun this loader: it will backfill "
            "the audit row without rewriting Bronze."
        ) from exc
    print(f"Audit logged: {audit[METADATA_SCHEMA.index(('status', 'string'))]} "
          f"for batch {BATCH_ID} in {METADATA_TABLE}")

    print("Landing → Bronze completed." if ACTION in ("load", "repair")
          else "Bronze unchanged; audit up to date.")
    print("Bronze table:", BRONZE_TABLE)
    print("Records in this snapshot:", STORED_COUNT)
    print("Landing batch:", str(BATCH_PATH))
    print("Content checksum:", CONTENT_CHECKSUM)

    handoff = {
        "source_system": SOURCE_NAME,
        "source_version": SOURCE_VERSION,
        "source_endpoint": ENDPOINT,
        "content_checksum": CONTENT_CHECKSUM,
        "batch_id": BATCH_ID,
        "expected_record_count": RECORD_COUNT,
        "landing_batch_path": str(BATCH_PATH),
        "action": ACTION,
    }
    print("QC handoff:", json.dumps(handoff, sort_keys=True))
    # Job runs: qc_bronze_geography reads these via {{tasks.bronze_geography.values.<key>}}.
    # Manual runs: use the printed QC handoff.
    publish_task_values(spark, handoff)
    return handoff


def publish_task_values(spark, values):
    # Set Databricks Job task values. Plain Spark Python tasks have no global dbutils,
    # so resolve it explicitly; outside a Job run this only prints a notice.
    task_dbutils = globals().get("dbutils")
    if task_dbutils is None:
        try:
            from databricks.sdk.runtime import dbutils as task_dbutils
        except Exception:
            try:
                from pyspark.dbutils import DBUtils

                task_dbutils = DBUtils(spark)
            except Exception:
                task_dbutils = None
    if task_dbutils is None:
        print("Task values unavailable; use printed QC handoff.")
        return
    try:
        for key, value in values.items():
            task_dbutils.jobs.taskValues.set(key=key, value=value)
        print("QC handoff published as task values.")
    except Exception as exc:
        print(f"Task values unavailable ({exc}); use printed QC handoff.")


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------


def parse_args(argv=None):
    # Defaults come from environment variables so notebook runs can set them in a
    # cell above. parse_known_args ignores IPython launcher arguments such as
    # "-f .../connection.json" that Databricks notebooks pass to every script.
    parser = argparse.ArgumentParser(description="PSGC landing to Bronze ingestion")
    parser.add_argument(
        "--config_path",
        default=os.environ.get("PSGC_CONFIG_PATH", "").strip() or None,
        help="Full path to sources_geography.yaml (env PSGC_CONFIG_PATH)",
    )
    parser.add_argument(
        "--landing_batch_path",
        default=os.environ.get("PSGC_LANDING_BATCH_PATH", "").strip(),
        help="Completed batch folder; blank selects latest matching batch "
        "(env PSGC_LANDING_BATCH_PATH)",
    )
    parser.add_argument(
        "--write_to_bronze",
        choices=("yes", "no"),
        default=os.environ.get("PSGC_WRITE_TO_BRONZE", "yes").strip().lower(),
        help="Default yes: writes Bronze and the audit row; use no to preview "
        "(env PSGC_WRITE_TO_BRONZE)",
    )
    args, ignored = parser.parse_known_args(argv)
    if ignored:
        print("Ignoring launcher arguments:", " ".join(ignored))
    return args


def main(argv=None):
    args = parse_args(argv)
    print(f"Geography Bronze loader {LOADER_VERSION}")
    spark = SparkSession.builder.getOrCreate()
    return ingest_source(spark, args)


if __name__ == "__main__":
    main()