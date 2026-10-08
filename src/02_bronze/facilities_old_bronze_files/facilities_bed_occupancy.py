# Databricks notebook source
# MAGIC %pip install openpyxl

# COMMAND ----------

# DBTITLE 1,Read Excel sheets
import pandas as pd

file_path = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/bed_occupancy_rate_2025.xlsx"
sheet_names = ["2020", "2021", "2022", "2023", "2024", "2025"]
all_dfs = []

for sheet in sheet_names:
    df = pd.read_excel(file_path, sheet_name=sheet, header=0)
    df["year"] = sheet
    all_dfs.append(df)
    print(f"Sheet '{sheet}': {df.shape[0]} rows, {df.shape[1]} columns")


# COMMAND ----------

# DBTITLE 1,Merge all sheets
# Merge all sheets into one DataFrame
# pd.concat aligns columns by name and fills missing with NaN
merged_df = pd.concat(all_dfs, ignore_index=True)

# Rename to snake_case
col_map = {
    "Region": "region",
    "Province/District": "province_district",
    "City/Municipality": "city_municipality",
    "General": "general",
    "Nature of Ownership": "nature_of_ownership",
    "Authorized Bed Capacity": "authorized_bed_capacity",
    "Implementing Beds": "implementing_beds",
    "Bed Occupancy Rate (BOR) Based on Authorized Beds": "bed_occupancy_rate",
}
merged_df = merged_df.rename(columns=col_map)

# Ensure year is the last column
cols = [c for c in merged_df.columns if c != "year"] + ["year"]
merged_df = merged_df[cols]

# Convert all columns to string for Arrow compatibility
merged_df = merged_df.astype("string")

print(f"Merged shape: {merged_df.shape}")
print(f"Columns: {list(merged_df.columns)}")
print("\nYear breakdown:")
print(merged_df["year"].value_counts().sort_index())


# COMMAND ----------

# Write merged DataFrame to Delta table
spark_df = spark.createDataFrame(merged_df)
spark_df.write.mode("overwrite").option("columnMapping.mode", "name").option(
    "overwriteSchema", "true"
).saveAsTable("public_health.bronze.facilities_bed_occupancy_rate")

print(f"Wrote {merged_df.shape[0]} rows to public_health.bronze.facilities_bed_occupancy_rate")


# COMMAND ----------

# Verify the written table
print("Table schema:")
spark.sql("DESCRIBE TABLE public_health.bronze.facilities_bed_occupancy_rate").show(truncate=False)

print("\nRow count and year breakdown:")
spark.sql("""
    SELECT year, COUNT(*) as cnt
    FROM public_health.bronze.facilities_bed_occupancy_rate
    GROUP BY year
    ORDER BY year
""").show()

print("Sample rows:")
display(spark.sql("SELECT * FROM public_health.bronze.facilities_bed_occupancy_rate LIMIT 5"))
