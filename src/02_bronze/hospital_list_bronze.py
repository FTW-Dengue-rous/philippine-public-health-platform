# Databricks notebook source
# MAGIC %pip install openpyxl

# COMMAND ----------

# openpyxl is required on Serverless compute for .xlsx parsing
import pandas as pd

# Source: hospital list Excel file in the PSA landing zone
hospital_source_path = (
    "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/"
    "hospital_list_asof_20260630.xlsx"
)

# header=3 skips the title, sub-header, and blank rows;
# row 4 has the actual column names (LEVEL 1, LEVEL 2, LEVEL 3, etc.)
hospital_pdf = pd.read_excel(hospital_source_path, header=3)
hospital_pdf = hospital_pdf.dropna(how="all")

# Handle NaN/Unnamed column names and duplicates for Spark compatibility.
# Columns without headers in the Excel file get named col_0, col_1, etc.
# Duplicate names (e.g., LEVEL 1 appears 3 times) get suffixed _1, _2
_cols = []
_seen = {}
for i, c in enumerate(hospital_pdf.columns):
    name = f"col_{i}" if (pd.isna(c) or str(c).startswith("Unnamed:")) else str(c).strip()
    if name in _seen:
        _seen[name] += 1
        name = f"{name}_{_seen[name]}"
    else:
        _seen[name] = 0
    _cols.append(name)
hospital_pdf.columns = _cols

# Convert object columns to nullable string type for Arrow compatibility
# (Spark can't convert mixed object columns to Arrow)
for col in hospital_pdf.select_dtypes(include=["object"]).columns:
    hospital_pdf[col] = hospital_pdf[col].astype("string")

hospital_df = spark.createDataFrame(hospital_pdf)

# Write to bronze Delta table (full refresh)
# Column mapping preserves column names with spaces (e.g., "LEVEL 1")
# overwriteSchema allows schema changes between runs
(
    hospital_df.write.format("delta")
    .mode("overwrite")
    .option("delta.columnMapping.mode", "name")
    .option("delta.minReaderVersion", "2")
    .option("delta.minWriterVersion", "5")
    .option("overwriteSchema", "true")
    .saveAsTable("public_health.bronze.facilities_hospital_list")
)

# COMMAND ----------

# DBTITLE 1,Preview hospital list data
# MAGIC %sql
# MAGIC SELECT * FROM public_health.bronze.facilities_hospital_list
