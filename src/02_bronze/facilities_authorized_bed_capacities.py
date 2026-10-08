# Databricks notebook source
# DBTITLE 1,Pull raw bed capacity data (exclude Total columns)
import pandas as pd

# --- Read source CSV from landing zone ---
src_path = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/authorized_bed_capacity_2020_2024_asof_20260929.csv"
df = pd.read_csv(src_path, sep=";", header=1)

# Drop all "Total" columns — keep only Government and Private
df = df[[c for c in df.columns if not c.startswith("Total")]]

display(df.head(5))
