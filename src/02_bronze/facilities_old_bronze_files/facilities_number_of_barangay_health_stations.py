# Databricks notebook source
# DBTITLE 1,Ingest and reshape barangay health station data
import pandas as pd

# --- Read source CSV from landing zone ---
src_path = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/number_barangay_health_station_2026_to_2023.csv"
df = pd.read_csv(src_path, sep=",", header=None)

# Region names from row 3 (columns 2–18), cleaning "MIMA-\nROPA" -> "MIMAROPA"
regions = ['NCR', 'CAR', 'I', 'II', 'III', 'IV-A', 'MIMAROPA', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII', 'Caraga', 'BARMM']

# Assign column names: col 0 = Year, col 1 = Philippines (national total), cols 2–18 = regions
df.columns = ['Year', 'Philippines'] + regions + [f'col_{i}' for i in range(19, df.shape[1])]

# Keep only data rows (where Year is a 4-digit year string)
df = df[df['Year'].astype(str).str.match(r'^\d{4}$', na=False)].copy()

# Select relevant columns
cols_to_keep = ['Year', 'Philippines'] + regions
df = df[cols_to_keep]

# --- Unpivot wide format to long format ---
melted = df.melt(
    id_vars=['Year'],
    var_name='region',
    value_name='number_of_barangay_health_stations',
)
melted = melted.rename(columns={'Year': 'year'})

# Clean values: strip whitespace, remove commas, handle "-" as null
melted['number_of_barangay_health_stations'] = (
    melted['number_of_barangay_health_stations']
    .astype(str)
    .str.strip()
    .str.replace(',', '', regex=False)
    .str.replace('-', '', regex=False)
    .str.strip()
)
melted['number_of_barangay_health_stations'] = melted['number_of_barangay_health_stations'].replace('', None)
melted['region'] = melted['region'].astype(str).str.strip()

# Select and sort final columns
melted = melted[['region', 'year', 'number_of_barangay_health_stations']]
melted = melted.sort_values(['region', 'year']).reset_index(drop=True)

# Convert all columns to nullable string for Arrow compatibility
for col in melted.columns:
    melted[col] = melted[col].astype('string')

# --- Write to Delta table ---
table_name = "public_health.bronze.facilities_number_of_barangay_health_stations"
spark_df = spark.createDataFrame(melted)
(
    spark_df.write.format('delta')
    .mode('overwrite')
    .option('columnMapping.mode', 'name')
    .option('overwriteSchema', 'true')
    .saveAsTable(table_name)
)

print(f"Wrote {melted.shape[0]} rows to {table_name}")
display(spark.table(table_name).limit(20))
