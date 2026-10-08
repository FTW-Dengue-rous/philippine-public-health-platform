# Databricks notebook source
# MAGIC %pip install openpyxl

# COMMAND ----------

import pandas as pd

file_path = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/dialysis_clinics_asof_20260630.xlsx"

# Read both sheets (note: ' Private' has a leading space in the sheet name)
gov_df = pd.read_excel(file_path, sheet_name="Government", header=0)
priv_df = pd.read_excel(file_path, sheet_name=" Private", header=0)

print(f"Government sheet: {gov_df.shape[0]} rows, {gov_df.shape[1]} columns")
print(f"Private sheet:   {priv_df.shape[0]} rows, {priv_df.shape[1]} columns")

# COMMAND ----------

# Drop trailing 'Unnamed' artifact columns from both sheets
gov_df = gov_df.loc[:, ~gov_df.columns.str.contains("^Unnamed")]
priv_df = priv_df.loc[:, ~priv_df.columns.str.contains("^Unnamed")]

# Merge into one DataFrame
merged_df = pd.concat([gov_df, priv_df], ignore_index=True)
print(f"Merged shape: {merged_df.shape}")
print(f"OWNERSHIP value counts:\n{merged_df['OWNERSHIP'].value_counts()}")

# Convert date columns to consistent string format
date_cols = ["VALIDITY FROM", "VALIDITY UNTIL"]
for col in date_cols:
    merged_df[col] = pd.to_datetime(merged_df[col], errors="coerce").dt.strftime("%Y-%m-%d")

# Convert all object columns to nullable string for Arrow compatibility
for col in merged_df.columns:
    if merged_df[col].dtype == "object":
        merged_df[col] = merged_df[col].astype("string")

# Convert '#' to string (row number — not meaningful for analysis)
merged_df["#"] = merged_df["#"].astype("string")

# Rename columns: '#' -> 'row_num', and snake_case all others for Delta compatibility
col_map = {
    "#": "row_num",
    "NHFR CODE": "nhfr_code",
    "REGION": "region",
    "CHD": "chd",
    "PROVINCE": "province",
    "CITY/ MUNICIPALITY": "city_municipality",
    "BLDG OR HOUSE NO., STREET, BRGY (as applicable)": "bldg_house_no_street_brgy",
    "NAME OF CLINIC": "name_of_clinic",
    "OWNERSHIP": "ownership",
    "INSTITUTIONAL CHARACTER": "institutional_character",
    "NO. OF STATION": "no_of_station",
    "HEAD OF THE FACILITY": "head_of_facility",
    "CONTACT NUMBER": "contact_number",
    "EMAIL ADDRESS": "email_address",
    "VALIDITY FROM": "validity_from",
    "VALIDITY UNTIL": "validity_until",
    "LICENSED NO.": "licensed_no",
    "REMARKS": "remarks",
}
merged_df = merged_df.rename(columns=col_map)

# Convert no_of_station to string (currently int64)
merged_df["no_of_station"] = merged_df["no_of_station"].astype("string")

print(f"\nFinal columns: {list(merged_df.columns)}")
print(f"Final dtypes:\n{merged_df.dtypes}")

# COMMAND ----------

# Write merged DataFrame to Delta table
spark_df = spark.createDataFrame(merged_df)
spark_df.write.mode("overwrite").option("columnMapping.mode", "name").option(
    "overwriteSchema", "true"
).saveAsTable("public_health.bronze.facilities_dialysis_clinics")

print(f"Wrote {merged_df.shape[0]} rows to public_health.bronze.facilities_dialysis_clinics")

# COMMAND ----------

# Verify the written table
print("Table schema:")
spark.sql("DESCRIBE TABLE public_health.bronze.facilities_dialysis_clinics").show(truncate=False)

print("\nRow count and OWNERSHIP breakdown:")
spark.sql("""
    SELECT OWNERSHIP, COUNT(*) as cnt
    FROM public_health.bronze.facilities_dialysis_clinics
    GROUP BY OWNERSHIP
""").show()

print("Sample rows:")
display(spark.sql("SELECT * FROM public_health.bronze.facilities_dialysis_clinics LIMIT 5"))
