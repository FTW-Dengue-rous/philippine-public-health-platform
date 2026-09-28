-- Creates one schema per medallion layer.
-- Replace ph_public_health with your catalog name.

CREATE SCHEMA IF NOT EXISTS ph_public_health.bronze
COMMENT 'Raw data ingested as-is';

CREATE SCHEMA IF NOT EXISTS ph_public_health.silver
COMMENT 'Cleaned, validated, standardized data';

CREATE SCHEMA IF NOT EXISTS ph_public_health.gold
COMMENT 'Business-ready tables for the dashboard';
