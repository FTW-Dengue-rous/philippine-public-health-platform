# Databricks notebook source
# Source: NHFR active facilities CSV in the PSA landing zone
nhfr_source_path = (
    "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/"
    "nhfr_activefacilities_asof_20260929.csv"
)

# Read CSV with header and inferred schema (32 columns)
nhfr_df = spark.read.option("header", True).option("inferSchema", True).csv(nhfr_source_path)

# Write to bronze Delta table (full refresh)
# Column mapping is enabled because the CSV column names contain
# spaces and special characters (e.g., "Street Name and #")
(
    nhfr_df.write.format("delta")
    .mode("overwrite")
    .option("delta.columnMapping.mode", "name")
    .option("delta.minReaderVersion", "2")
    .option("delta.minWriterVersion", "5")
    .saveAsTable("ph_public_health.bronze.active_facilities")
)
