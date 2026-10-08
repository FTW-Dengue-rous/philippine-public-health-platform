# Databricks notebook source
# openpyxl is required on Serverless compute for .xlsx parsing
%pip install openpyxl

import pandas as pd

# Source: PSA landing zone Excel file
source_path = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/primary_care_asof20260630.xlsx"

# header=1 skips the title row; row 2 has the actual column names
# (REGION, CHD, GOVERNMENT, PRIVATE, TOTAL, Status)
pdf = pd.read_excel(source_path, header=1)

# Convert pandas DataFrame to Spark DataFrame
# Numeric columns (GOVERNMENT, PRIVATE, TOTAL) are typed as long;
# string columns (REGION, CHD, Status) are typed as string
df = spark.createDataFrame(pdf)

# Write to bronze Delta table (full refresh)
df.write.format("delta") \
  .mode("overwrite") \
  .saveAsTable("ph_public_health.bronze.facilities_primary_care")
