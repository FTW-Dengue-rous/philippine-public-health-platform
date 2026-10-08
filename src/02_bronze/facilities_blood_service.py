# Databricks notebook source
# DBTITLE 1,Install openpyxl
# MAGIC %pip install openpyxl

# COMMAND ----------

# DBTITLE 1,Read both sheets
import pandas as pd

file_path = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/blood_service_asof_20260630.xlsx"

# Read both sheets
gov_df = pd.read_excel(file_path, sheet_name="Government", header=0)
priv_df = pd.read_excel(file_path, sheet_name="Private", header=0)

print(f"Government sheet: {gov_df.shape[0]} rows, {gov_df.shape[1]} columns")
print(f"Private sheet:   {priv_df.shape[0]} rows, {priv_df.shape[1]} columns")

# COMMAND ----------

# DBTITLE 1,Merge and clean
# Drop trailing 'Unnamed' artifact columns and '#' column
gov_df = gov_df.loc[:, ~gov_df.columns.str.contains("^Unnamed")]
priv_df = priv_df.loc[:, ~priv_df.columns.str.contains("^Unnamed")]

# Merge into one DataFrame
merged_df = pd.concat([gov_df, priv_df], ignore_index=True)

# Drop '#' (row number) column
merged_df = merged_df.drop(columns=["#"], errors="ignore")
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

# Rename columns to snake_case for Delta compatibility
col_map = {
    "NHFR CODE": "nhfr_code",
    "REGION": "region",
    "PROVINCE": "province",
    "CITY/MUNICIPALITY": "city_municipality",
    "BLDG OR HOUSE NO., STREET, BRGY (as applicable)": "bldg_house_no_street_brgy",
    "NAME OF FACILITY": "name_of_facility",
    "OWNERSHIP": "ownership",
    "SERVCE  CAPABILITY": "service_capability",
    "INSTITUTIONAL CHARACTER": "institutional_character",
    "HEAD OF LABORATORY": "head_of_laboratory",
    "CONTACT NOS.": "contact_nos",
    "EMAIL ADDRESS": "email_address",
    "VALIDITY FROM": "validity_from",
    "VALIDITY UNTIL": "validity_until",
    "LICENSE NO.": "license_no",
    "APPLICATION STATUS": "application_status",
    "APPLICATION STATUS\n(IF WITH CHANGES)": "application_status_if_with_changes",
    "REMARKS": "remarks",
    "Reference used by DMU": "reference_used_by_dmu",
}
merged_df = merged_df.rename(columns=col_map)

# Drop unnecessary columns
merged_df = merged_df.drop(
    columns=["bldg_house_no_street_brgy", "contact_nos", "email_address"], errors="ignore"
)

print(f"\nFinal columns: {list(merged_df.columns)}")
print(f"Final dtypes:\n{merged_df.dtypes}")

# COMMAND ----------

# DBTITLE 1,Write to Delta table
# Write merged DataFrame to Delta table
spark_df = spark.createDataFrame(merged_df)
spark_df.write.mode("overwrite").option("columnMapping.mode", "name").option(
    "overwriteSchema", "true"
).saveAsTable("public_health.bronze.facilities_blood_services")

print(f"Wrote {merged_df.shape[0]} rows to public_health.bronze.facilities_blood_services")

# COMMAND ----------

# DBTITLE 1,Verify
# Verify the written table
print("Table schema:")
spark.sql("DESCRIBE TABLE public_health.bronze.facilities_blood_services").show(truncate=False)

print("\nRow count and OWNERSHIP breakdown:")
spark.sql("""
    SELECT ownership, COUNT(*) as cnt
    FROM public_health.bronze.facilities_blood_services
    GROUP BY ownership
""").show()

print("Sample rows:")
display(spark.sql("SELECT * FROM public_health.bronze.facilities_blood_services LIMIT 5"))
