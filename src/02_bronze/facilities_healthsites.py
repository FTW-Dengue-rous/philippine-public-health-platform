# Databricks notebook source
# DBTITLE 1,Ingest healthsites data as-is
import pandas as pd

# --- Read source CSV from landing zone ---
src_path = (
    "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/philippines_healthsites.csv"
)
df = pd.read_csv(src_path, sep=",", header=0)

# Convert all columns to nullable string for Arrow compatibility
for col in df.columns:
    df[col] = df[col].astype("string")

# --- Write to Delta table ---
table_name = "public_health.bronze.facilities_healthsites"
spark_df = spark.createDataFrame(df)
(
    spark_df.write.format("delta")
    .mode("overwrite")
    .option("columnMapping.mode", "name")
    .option("overwriteSchema", "true")
    .saveAsTable(table_name)
)

print(f"Wrote {df.shape[0]} rows to {table_name}")
display(spark.table(table_name).limit(20))
