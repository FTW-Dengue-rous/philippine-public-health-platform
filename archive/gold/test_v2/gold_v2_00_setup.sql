-- ========================================
-- Creates the schema public_health.test_gold2 for data model v2.
--
-- Data model v2 (combined, 14 Oct 2026): 5 dimensions, 4 facts.
--   Dimensions: dim_date, dim_geography, dim_facility, dim_disease, dim_data_source
--   Facts:      fact_disease_metric, fact_facility_capacity, fact_workforce_capacity,
--               fact_area_indicator
--
-- Why a separate schema: v2 reuses some v1 table names (fact_disease_metric) with different
-- columns. Building v2 beside v1 keeps data model v1 in public_health.test_gold for comparison.
--
-- v2 is self-contained (decided 2026-10-14 evening: the team runs v2 only). The three
-- dimensions that did not change in v2 have their own v2 files, gold_v2_11, gold_v2_21 and
-- gold_v2_31, instead of being copied from test_gold. Nothing here reads test_gold.
--
-- Run order: 00 -> 11 -> 21 -> 31 -> 12 -> 13 -> 20 -> 30 -> 35 -> 40.
-- When v2 is promoted to public_health.gold: change the schema name in every file.
-- ========================================

CREATE SCHEMA IF NOT EXISTS public_health.test_gold2
COMMENT 'Data model v2 (combined): 5 dimensions, 4 facts. Test schema beside the v1 tables in test_gold.';