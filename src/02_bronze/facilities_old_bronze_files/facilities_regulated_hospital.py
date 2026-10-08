# Databricks notebook source
# DBTITLE 1,Ingest regulated hospital data (raw wide format, drop Total columns)
import pandas as pd

# --- Read source CSV from landing zone ---
src_path = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/TABLE 9.18 Number of Regulated Hospitals by Type and by Region- 2020 to 2024 (1).csv"
df = pd.read_csv(src_path, sep=",", header=1)

# --- Drop Total columns, keep raw wide format (Region + Government/Private 2020-2024) ---
drop_cols = [c for c in df.columns if c.startswith("Total")]
df = df.drop(columns=drop_cols)

# Convert column names to snake_case for Delta compatibility (e.g. "Government 2020" -> "government_2020")
df.columns = (
    df.columns
    .str.strip()
    .str.lower()
    .str.replace(r"\s+", "_", regex=True)
)

# Convert all columns to nullable string for Arrow compatibility
for col in df.columns:
    df[col] = df[col].astype("string")

# --- Write to Delta table ---
table_name = "ph_public_health.bronze.facilities_regulated_hospital"
spark_df = spark.createDataFrame(df)
(
    spark_df.write.format("delta")
    .mode("overwrite")
    .option("columnMapping.mode", "name")
    .option("overwriteSchema", "true")
    .saveAsTable(table_name)
)

print(f"Wrote {df.shape[0]} rows × {df.shape[1]} columns to {table_name}")
display(spark.table(table_name).limit(5))
