-- =============================================================================
-- Shared ingestion log for all bronze loads (API and file loaders).
-- Run once. Then every loader only appends.
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

-- 3. Copy the rows already logged by the old schema.
-- raw_file_path keeps the old relative path; checksum was not recorded then.
INSERT INTO public_health.bronze.ingestion_metadata
SELECT
    run_id AS batch_id,
    source_key AS source_name,
    CAST(as_of_date AS STRING) AS source_version,
    CAST(NULL AS STRING) AS endpoint,
    CAST(NULL AS STRING) AS content_checksum,
    source_file AS raw_file_path,
    row_count AS record_count,
    CAST(NULL AS INT) AS page_count,
    ingested_at AS retrieved_at,
    CASE WHEN status = 'SUCCESS' THEN 'processed' ELSE 'failed' END AS status,
    bronze_table,
    source_sheet,
    column_count,
    file_size_bytes,
    error_message
FROM public_health.bronze.ingestion_metadata_v0;

-- 4. Check, then drop the old table when satisfied.
SELECT
    status,
    COUNT(*) AS n_rows
FROM public_health.bronze.ingestion_metadata
GROUP BY status;

-- DROP TABLE public_health.bronze.ingestion_metadata_v0;
