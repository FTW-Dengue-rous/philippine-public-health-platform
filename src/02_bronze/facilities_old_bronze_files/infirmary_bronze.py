# Databricks notebook source
# openpyxl is required on Serverless compute for .xlsx parsing
# MAGIC %pip install openpyxl

# COMMAND ----------

import pandas as pd

# Source: infirmary Excel file in the PSA landing zone
infirmary_source_path = (
    "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/"
    "infirmary_asof_20260630.xlsx"
)

# header=3 skips the title, sub-header, and blank rows;
# row 4 has the actual column names (No. of Facilities, ABC, etc.)
infirmary_pdf = pd.read_excel(infirmary_source_path, header=3)
infirmary_pdf = infirmary_pdf.dropna(how="all")

# Handle NaN/Unnamed column names and duplicates for Spark compatibility.
# Columns without headers in the Excel file get named col_0, col_1, etc.
# Duplicate names (e.g., No. of Facilities appears twice) get suffixed _1
_cols = []
_seen = {}
for i, c in enumerate(infirmary_pdf.columns):
    name = f"col_{i}" if (pd.isna(c) or str(c).startswith("Unnamed:")) else str(c).strip()
    if name in _seen:
        _seen[name] += 1
        name = f"{name}_{_seen[name]}"
    else:
        _seen[name] = 0
    _cols.append(name)
infirmary_pdf.columns = _cols

# Convert object columns to nullable string type for Arrow compatibility
# (Spark can't convert mixed object columns to Arrow)
for col in infirmary_pdf.select_dtypes(include=["object"]).columns:
    infirmary_pdf[col] = infirmary_pdf[col].astype("string")

infirmary_df = spark.createDataFrame(infirmary_pdf)

# Write to bronze Delta table (full refresh)
# Column mapping preserves column names with spaces (e.g., "No. of Facilities")
# overwriteSchema allows schema changes between runs
(
    infirmary_df.write.format("delta")
    .mode("overwrite")
    .option("delta.columnMapping.mode", "name")
    .option("delta.minReaderVersion", "2")
    .option("delta.minWriterVersion", "5")
    .option("overwriteSchema", "true")
    .saveAsTable("ph_public_health.bronze.facilities_infirmary")
)

# COMMAND ----------

# DBTITLE 1,Preview infirmary data
# MAGIC %sql
# MAGIC SELECT * FROM ph_public_health.bronze.facilities_infirmary
