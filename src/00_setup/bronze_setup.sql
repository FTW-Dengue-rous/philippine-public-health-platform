-- Bronze layer setup statements


--PSGC - geography_bronze table
--Grain: One PSGC geographic record per logical source snapshot
CREATE TABLE IF NOT EXISTS public_health.bronze.geography_bronze (
    psgc_code STRING,
    area_name STRING,
    correspondence_code STRING,
    geographic_level STRING,
    reg STRING,
    prv STRING,
    mun STRING,
    bgy STRING,
    old_name STRING,
    city_class STRING,
    income_classification STRING,
    urban_rural STRING,
    island_region STRING,
    record_status STRING,
    record_version STRING,
    populations_json STRING,
    source_record_json STRING,

    source_system STRING,
    source_version STRING,
    source_endpoint STRING,
    batch_id STRING,
    content_checksum STRING,
    raw_path STRING,
    ingested_at TIMESTAMP
)
USING DELTA;-- Bronze layer setup statements.
