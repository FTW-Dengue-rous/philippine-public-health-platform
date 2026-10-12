# Bronze ingestion for the admin_boundaries domain.
#
# Purpose
#   Read an explicit ingestion handoff.json, verify its landing receipt and
#   staging manifest, and preserve raw features in the Bronze Delta table.
#   This is a regular Python script for a Databricks Serverless Python task.
#
# Loading conventions
#   Source feature, properties and geometry JSON are retained with lineage.
#   A new source version is appended atomically; an absent table is created.
#   A complete existing version is a no-op; partial versions stop the run.
#   Existing duplicate fingerprints prevent an unsafe no-op rerun.
#   No schema evolution, cleansing or Bronze -> Silver approval occurs here.
#   Idempotency requires maximum concurrent Job runs = 1; this is not a MERGE.
#   Post-write reconciliation failure does not roll back committed Bronze rows.
#
# Output
#   Writes bronze_handoff.json beside the input handoff for the separate QC task.
#   Use the printed Bronze handoff path as QC's --bronze_handoff_path.
#   Python task execution does not depend on dbutils/widgets or notebook state.
#
# How to run
#   --handoff_path /Volumes/.../_runs/<run-id>/handoff.json
#   This is the INGESTION handoff, not bronze_handoff.json (QC's input).
#   Target catalog/schema must exist. Requires Spark with Delta support.
#
# Source notebook migration
#   Removed the widget cell that referenced HANDOFF_DEFAULT before definition.
#   Raw projections, write/no-op decisions and reconciliation logic are retained.

import argparse


from pathlib import Path, PurePosixPath
from datetime import datetime, timezone
import json
import re
from pyspark.sql import functions as F

from pyspark.sql import SparkSession

LOADER_VERSION = "2026-10-13.1"

def utc_now():
    return datetime.now(timezone.utc)

def safe_volume_file(value, expected_name=None):
    path = Path(value)
    parts = PurePosixPath(value).parts
    if len(parts) < 5 or parts[:2] != ('/', 'Volumes') or '..' in parts:
        raise ValueError(f'Expected a safe /Volumes path: {value}')
    if expected_name and path.name != expected_name:
        raise ValueError(f'Expected {expected_name}: {value}')
    if not path.is_file():
        raise FileNotFoundError(f'File not found: {value}')
    return path

def validate_table_name(value):
    parts = value.split('.')
    if len(parts) != 3 or any((not re.fullmatch('[A-Za-z_][A-Za-z0-9_]*', part) for part in parts)):
        raise ValueError(f'Invalid table name: {value}')

# -----------------------------------------------------------------------------
# Validate input, build Bronze, write/no-op, reconcile and publish QC handoff
# -----------------------------------------------------------------------------

def ingest_source(spark, handoff_path):
    HANDOFF_PATH = handoff_path
    HANDOFF_FILE = safe_volume_file(HANDOFF_PATH, 'handoff.json')
    HANDOFF = json.loads(HANDOFF_FILE.read_text(encoding='utf-8'))
    REQUIRED_HANDOFF_FIELDS = {'source_key', 'dataset_id', 'source_version', 'landing_receipt_path', 'staging_manifest_path', 'batch_id', 'bronze_table', 'dq_results_table'}
    missing = REQUIRED_HANDOFF_FIELDS - set(HANDOFF)
    if missing:
        raise ValueError(f'Handoff is missing required fields: {sorted(missing)}')
    SOURCE_KEY = HANDOFF['source_key']
    DATASET_ID = HANDOFF['dataset_id']
    SOURCE_VERSION = HANDOFF['source_version']
    BATCH_ID = HANDOFF['batch_id']
    BRONZE_TABLE = 'public_health.bronze.admin_boundaries_bronze'
    DQ_RESULTS_TABLE = HANDOFF['dq_results_table']
    VALIDATION_ID = HANDOFF.get('validation_id')
    if not re.fullmatch('[a-f0-9]{64}', SOURCE_VERSION):
        raise ValueError('source_version must be a SHA-256 hash.')
    expected_batch_id = f'{DATASET_ID}:{SOURCE_VERSION}'
    if BATCH_ID != expected_batch_id:
        raise ValueError('batch_id does not match dataset_id + source_version.')
    validate_table_name(BRONZE_TABLE)
    validate_table_name(DQ_RESULTS_TABLE)
    print('Source key:', SOURCE_KEY)
    print('Dataset:', DATASET_ID)
    print('Source version:', SOURCE_VERSION)
    print('Batch ID:', BATCH_ID)
    print('Validation ID:', VALIDATION_ID)
    print('Bronze table:', BRONZE_TABLE)
    LANDING_RECEIPT_PATH = safe_volume_file(HANDOFF['landing_receipt_path'], 'receipt.json')
    STAGING_MANIFEST_PATH = safe_volume_file(HANDOFF['staging_manifest_path'], 'manifest.json')
    RECEIPT = json.loads(LANDING_RECEIPT_PATH.read_text(encoding='utf-8'))
    MANIFEST = json.loads(STAGING_MANIFEST_PATH.read_text(encoding='utf-8'))
    if RECEIPT.get('status') != 'ready':
        raise ValueError('Landing receipt is not ready.')
    if RECEIPT.get('dataset_id') != DATASET_ID:
        raise ValueError('Receipt dataset_id does not match the handoff.')
    if RECEIPT.get('source_version') != SOURCE_VERSION:
        raise ValueError('Receipt source_version does not match the handoff.')
    if RECEIPT.get('batch_id') != BATCH_ID:
        raise ValueError('Receipt batch_id does not match the handoff.')
    if MANIFEST.get('status') != 'ready':
        raise ValueError('Staging manifest is not ready.')
    if MANIFEST.get('dataset_id') != DATASET_ID:
        raise ValueError('Manifest dataset_id does not match the handoff.')
    if MANIFEST.get('source_version') != SOURCE_VERSION:
        raise ValueError('Manifest source_version does not match the handoff.')
    if MANIFEST.get('batch_id') != BATCH_ID:
        raise ValueError('Manifest batch_id does not match the handoff.')
    if MANIFEST.get('landing_version') != str(LANDING_RECEIPT_PATH.parent):
        raise ValueError('Manifest landing_version does not match the receipt location.')
    EXPECTED_BY_LEVEL = {int(layer['admin_level']): int(layer['rows']) for layer in MANIFEST['layers']}
    EXPECTED_TOTAL = sum(EXPECTED_BY_LEVEL.values())
    print('Receipt verified.')
    print('Manifest verified.')
    print('Expected rows by level:', EXPECTED_BY_LEVEL)
    print('Expected total:', EXPECTED_TOTAL)
    bronze_frames = []
    manifest_directory = STAGING_MANIFEST_PATH.parent
    layer_metadata = {int(layer['admin_level']): layer for layer in MANIFEST['layers']}
    for level in sorted(EXPECTED_BY_LEVEL):
        layer = layer_metadata[level]
        prepared_files = [item for item in MANIFEST['files'] if int(item['admin_level']) == level]
        if not prepared_files:
            raise ValueError(f'No prepared files found for ADM{level}.')
        paths = []
        for item in prepared_files:
            relative = PurePosixPath(item['path'])
            if relative.is_absolute() or '..' in relative.parts or '\\' in item['path']:
                raise ValueError(f"Unsafe staging file path: {item['path']}")
            full_path = manifest_directory.joinpath(*relative.parts)
            if not full_path.is_file():
                raise FileNotFoundError(f'Prepared file missing: {full_path}')
            if full_path.stat().st_size != int(item['bytes']):
                raise ValueError(f'Prepared file size changed: {full_path}')
            paths.append(str(full_path))
        frame = spark.read.text(paths).select(F.col('value').alias('source_feature_json'), F.expr('_metadata.file_path').alias('_staging_file_path')).withColumn('feature_type', F.get_json_object('source_feature_json', '$.type')).withColumn('source_feature_id', F.get_json_object('source_feature_json', '$.id')).withColumn('properties_json', F.get_json_object('source_feature_json', '$.properties')).withColumn('geometry_json', F.get_json_object('source_feature_json', '$.geometry')).withColumn('geometry_type', F.get_json_object('source_feature_json', '$.geometry.type')).withColumn('_source_key', F.lit(SOURCE_KEY)).withColumn('_dataset_id', F.lit(DATASET_ID)).withColumn('_source_version', F.lit(SOURCE_VERSION)).withColumn('_batch_id', F.lit(BATCH_ID)).withColumn('_admin_level', F.lit(level).cast('int')).withColumn('_source_file', F.lit(layer['source_file'])).withColumn('_source_file_sha256', F.lit(layer['source_sha256'])).withColumn('_source_crs', F.lit(layer['source_crs'])).withColumn('_source_url', F.lit(RECEIPT.get('source_url')).cast('string')).withColumn('_landing_receipt_path', F.lit(str(LANDING_RECEIPT_PATH))).withColumn('_staging_manifest_path', F.lit(str(STAGING_MANIFEST_PATH))).withColumn('_validation_id', F.lit(VALIDATION_ID).cast('string')).withColumn('_landing_ingested_at', F.to_timestamp(F.lit(RECEIPT.get('ingestion_timestamp')))).withColumn('_bronze_ingested_at', F.current_timestamp()).withColumn('_record_sha256', F.sha2(F.col('source_feature_json'), 256))
        bronze_frames.append(frame)
    BRONZE_DF = bronze_frames[0]
    for frame in bronze_frames[1:]:
        BRONZE_DF = BRONZE_DF.unionByName(frame)
    print('Bronze candidate built.')
    BRONZE_DF.printSchema()
    candidate_counts = {int(row['_admin_level']): int(row['count']) for row in BRONZE_DF.groupBy('_admin_level').count().collect()}
    candidate_total = sum(candidate_counts.values())
    if candidate_counts != EXPECTED_BY_LEVEL:
        raise ValueError(f'Candidate row counts do not match the validated manifest. expected={EXPECTED_BY_LEVEL}; actual={candidate_counts}')
    if candidate_total != EXPECTED_TOTAL:
        raise ValueError('Candidate total does not match the validated manifest.')
    TARGET_EXISTS = spark.catalog.tableExists(BRONZE_TABLE)
    if not TARGET_EXISTS:
        existing_counts = {}
        existing_total = 0
    else:
        existing_version = spark.table(BRONZE_TABLE).filter(F.col('_source_version') == SOURCE_VERSION)
        existing_counts = {int(row['_admin_level']): int(row['count']) for row in existing_version.groupBy('_admin_level').count().collect()}
        existing_total = sum(existing_counts.values())
    if existing_total == 0:
        LOAD_ACTION = 'LOAD'
    elif existing_total == EXPECTED_TOTAL and existing_counts == EXPECTED_BY_LEVEL:
        existing_duplicates = existing_version.groupBy('_admin_level', '_record_sha256').count().filter(F.col('count') > 1).count()
        if existing_duplicates:
            raise ValueError('Existing source version has duplicate Bronze records.')
        LOAD_ACTION = 'ALREADY_COMPLETE'
    else:
        raise ValueError(f'A partial or inconsistent version already exists in Bronze. The script will not append to it. expected={EXPECTED_BY_LEVEL}; existing={existing_counts}')
    print('Candidate counts:', candidate_counts)
    print('Expected total:', EXPECTED_TOTAL)
    print('Existing counts:', existing_counts)
    print('Load action:', LOAD_ACTION)
    if LOAD_ACTION == 'LOAD':
        print('Writing new source version to Bronze...')
        if TARGET_EXISTS:
            target_schema = {field.name: field.dataType.simpleString() for field in spark.table(BRONZE_TABLE).schema}
            candidate_schema = {field.name: field.dataType.simpleString() for field in BRONZE_DF.schema}
            if target_schema != candidate_schema:
                raise ValueError('Bronze table schema differs from the candidate schema. Review the schema change explicitly before loading.')
        BRONZE_DF.write.format('delta').mode('append').saveAsTable(BRONZE_TABLE)
        WRITE_OUTCOME = 'loaded'
    else:
        WRITE_OUTCOME = 'already_complete'
        print('Source version is already complete in Bronze. No rows were written.')
    print('Write outcome:', WRITE_OUTCOME)
    loaded_version = spark.table(BRONZE_TABLE).filter(F.col('_source_version') == SOURCE_VERSION)
    loaded_counts = {int(row['_admin_level']): int(row['count']) for row in loaded_version.groupBy('_admin_level').count().collect()}
    loaded_total = sum(loaded_counts.values())
    if loaded_counts != EXPECTED_BY_LEVEL:
        raise ValueError(f'Post-write reconciliation failed. expected={EXPECTED_BY_LEVEL}; actual={loaded_counts}')
    if loaded_total != EXPECTED_TOTAL:
        raise ValueError('Post-write total does not match the validated manifest.')
    batch_ids = loaded_version.select('_batch_id').distinct().collect()
    if len(batch_ids) != 1 or batch_ids[0]['_batch_id'] != BATCH_ID:
        raise ValueError('Bronze source version contains an unexpected batch_id.')
    print('Bronze reconciliation passed.')
    print('Bronze table:', BRONZE_TABLE)
    print('Source version:', SOURCE_VERSION)
    print('Rows by level:', loaded_counts)
    print('Total rows:', loaded_total)
    print('Outcome:', WRITE_OUTCOME)
    BRONZE_QC_TABLE = HANDOFF.get('bronze_qc_results_table', DQ_RESULTS_TABLE + '_bronze')
    validate_table_name(BRONZE_QC_TABLE)
    BRONZE_HANDOFF = {'source_key': SOURCE_KEY, 'dataset_id': DATASET_ID, 'source_version': SOURCE_VERSION, 'batch_id': BATCH_ID, 'bronze_table': BRONZE_TABLE, 'bronze_qc_results_table': BRONZE_QC_TABLE, 'expected_by_level': {str(k): v for k, v in EXPECTED_BY_LEVEL.items()}, 'bronze_row_count': loaded_total, 'upstream_validation_id': VALIDATION_ID, 'write_outcome': WRITE_OUTCOME, 'staging_manifest_path': str(STAGING_MANIFEST_PATH), 'status': 'bronze_loaded_pending_qc'}
    BRONZE_HANDOFF_PATH = HANDOFF_FILE.parent / 'bronze_handoff.json'
    tmp = BRONZE_HANDOFF_PATH.with_suffix('.json.tmp')
    tmp.write_text(json.dumps(BRONZE_HANDOFF, indent=2), encoding='utf-8')
    tmp.replace(BRONZE_HANDOFF_PATH)
    print('Bronze handoff:', BRONZE_HANDOFF_PATH)
    print('Next stage: Bronze QC. This batch is not yet approved for Silver.')
    return BRONZE_HANDOFF_PATH

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Admin boundaries landing to Bronze")
    parser.add_argument("--handoff_path", required=True,
                        help="Full /Volumes path to the ingestion handoff.json")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    print(f"Admin boundaries Bronze loader {LOADER_VERSION}")
    spark = SparkSession.builder.getOrCreate()
    return ingest_source(spark, args.handoff_path)


if __name__ == "__main__":
    main()
