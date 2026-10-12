-- =============================================================================
-- Shared ingestion log for all bronze loads (API and file loaders).
-- Safe to rerun (CREATE TABLE IF NOT EXISTS). Loaders only append.
-- =============================================================================
-- 1. Create the shared table with the agreed schema.
CREATE TABLE IF NOT EXISTS public_health.bronze.ingestion_metadata (
    batch_id STRING COMMENT 'Unique identifier for the ingestion attempt (one per loader run, shared by its files)',
    source_name STRING COMMENT 'Name of the source being ingested (YAML source key for file loads)',
    source_version STRING COMMENT 'Source version requested by the run (as_of_date for file loads)',
    endpoint STRING COMMENT 'API endpoint used by the run, null for file loads',
    content_checksum STRING COMMENT 'Deterministic checksum of the source content (sha256 of the file for file loads)',
    raw_file_path STRING COMMENT 'Landing path associated with the run',
    record_count BIGINT COMMENT 'Number of source records retrieved / rows written to bronze',
    page_count INT COMMENT 'Number of API pages retrieved, null for file loads',
    retrieved_at TIMESTAMP COMMENT 'When the ingestion attempt ran (UTC)',
    status STRING COMMENT 'in_progress | processed | failed | skipped_duplicate',
    bronze_table STRING COMMENT 'File loads: target bronze table',
    source_sheet STRING COMMENT 'File loads: Excel sheet name, null for CSV',
    column_count INT COMMENT 'File loads: data columns written (lineage columns excluded)',
    file_size_bytes BIGINT COMMENT 'File loads: file size at load time',
    error_message STRING COMMENT 'Error text (first 500 chars) when status = failed'
)
USING DELTA
COMMENT 'One row per ingested file/sheet (file loads) or per API ingestion attempt';

-- Note: the one-time migration from ingestion_metadata_v0 (rename + copy rows)
-- was already applied on the workspace and removed so this script is idempotent.
-- See git history for the original migration SQL.
