# =============================================================================
# Silver PSGC Population
#
# Turns the nested PSGC population payload in Bronze (populations_json on each PSGC
# geography record) into clean, typed population observations. Script version of the
# psgc_population_silver notebook (same SQL, same order).
#
#   Source     public_health.bronze.geography_bronze (populations_json)
#   Target     public_health.silver.population_silver (full rebuild: CREATE OR REPLACE TABLE)
#   Reference  public_health.silver.geography_silver (only for the closing reconciliation)
#   Grain      one row per psgc_code x population_year x source_version
#
# Parse status
#   VALID            digits only after removing commas and spaces
#   VALID_WITH_NOTE  as VALID, with a leading bracketed note kept in population_note
#                    e.g. "(excluding CITY OF ANGELES) 1,234" -> 1234
#   MISSING          null, empty or "-"
#   INVALID          anything else (kept, population null, original in population_raw)
#
# How to run (Databricks, Serverless or classic)
#   Python script task:  psgc_population_silver.py  [--bronze_table ...] [--silver_table ...]
#                        [--geography_table ...]
#   Notebook cell:       import runpy; runpy.run_path("<repo>/src/03_silver/psgc_population_silver.py",
#                                                     run_name="__main__")
#   All parameters are optional (defaults below); job/widget parameters of the same names work too.
#   Run after geography_silver.py; then run psgc_population_silver_qc.py.
#
# Changes from the notebook
#   - Table names are parameters (defaults are the notebook's names).
#   - The grain check stops the run before the table is replaced if a key is duplicated,
#     and an unexpected parse status stops it too (the notebook only displayed both).
#   - Expected reconciliation exceptions are listed in the output (see the last section).
# =============================================================================

import argparse

from pyspark.sql import SparkSession

spark = SparkSession.builder.getOrCreate()

DEFAULT_BRONZE_TABLE = "public_health.bronze.geography_bronze"
DEFAULT_SILVER_TABLE = "public_health.silver.population_silver"
DEFAULT_GEOGRAPHY_TABLE = "public_health.silver.geography_silver"
APPROVED_PARSE_STATUS = ("VALID", "VALID_WITH_NOTE", "MISSING", "INVALID")


# -----------------------------------------------------------------------------
# Run parameters: command-line arguments (Python script task), then job/widget
# parameters (notebook task), then defaults.
# -----------------------------------------------------------------------------


def parse_args():
    parser = argparse.ArgumentParser(description="PSGC population Bronze to Silver")
    parser.add_argument("--bronze_table", default=None, help=f"Default {DEFAULT_BRONZE_TABLE}")
    parser.add_argument("--silver_table", default=None, help=f"Default {DEFAULT_SILVER_TABLE}")
    parser.add_argument(
        "--geography_table", default=None, help=f"Default {DEFAULT_GEOGRAPHY_TABLE}"
    )
    args, _ = parser.parse_known_args()  # notebook kernels pass their own arguments
    return args


def _dbutils():
    handle = globals().get("dbutils")
    if handle is not None:
        return handle
    try:
        from databricks.sdk.runtime import dbutils as handle

        return handle
    except Exception:
        return None


def param(value, name, default):
    if value is not None and str(value).strip():
        return str(value).strip()
    handle = _dbutils()
    if handle is not None:
        try:
            widget_value = handle.widgets.get(name).strip()
            if widget_value:
                return widget_value
        except Exception:
            pass
    return default


def show(df, n=20):
    # Replaces the notebook display function; also works in a Python script task.
    df.show(n, truncate=False)


ARGS = parse_args()
BRONZE_TABLE = param(ARGS.bronze_table, "bronze_table", DEFAULT_BRONZE_TABLE)
SILVER_TABLE = param(ARGS.silver_table, "silver_table", DEFAULT_SILVER_TABLE)
GEOGRAPHY_TABLE = param(ARGS.geography_table, "geography_table", DEFAULT_GEOGRAPHY_TABLE)

print(f"Bronze table   : {BRONZE_TABLE}")
print(f"Silver table   : {SILVER_TABLE}")
print(f"Geography table: {GEOGRAPHY_TABLE}")

for label, table in (("Bronze", BRONZE_TABLE), ("Geography Silver", GEOGRAPHY_TABLE)):
    if not spark.catalog.tableExists(table):
        raise ValueError(f"{label} table not found: {table}")


# -----------------------------------------------------------------------------
# 1. Parse the nested population JSON
#    The parent PSGC code of the Bronze geography record is the Silver psgc_code.
# -----------------------------------------------------------------------------
spark.sql(f"""
CREATE OR REPLACE TEMP VIEW psgc_population_observations AS

SELECT
    g.psgc_code AS psgc_code,
    g.source_version,
    g.content_checksum,
    g.batch_id,
    population_item.year AS population_year,
    population_item.population AS population_raw,

    -- text inside a leading bracket, e.g. 'excluding CITY OF ANGELES'
    NULLIF(
        REGEXP_EXTRACT(TRIM(population_item.population), '^[(]([^)]*)[)]', 1),
        ''
    ) AS population_note,

    -- the value with the bracketed note, commas and spaces removed
    REPLACE(
        REPLACE(
            REGEXP_REPLACE(TRIM(population_item.population), '^[(][^)]*[)]', ''),
            ',', ''
        ),
        ' ', ''
    ) AS population_number_text

FROM {BRONZE_TABLE} g

LATERAL VIEW EXPLODE(
    FROM_JSON(
        g.populations_json,
        'array<struct<id:bigint,population:string,psgc:string,year:int>>'
    )
) exploded AS population_item

WHERE g.populations_json IS NOT NULL
""")


# -----------------------------------------------------------------------------
# 2. Classify population parsing results
# -----------------------------------------------------------------------------
spark.sql("""
CREATE OR REPLACE TEMP VIEW psgc_population_parsed AS

SELECT
    psgc_code,
    population_year,
    CASE WHEN population_number_text RLIKE '^[0-9]+$'
         THEN CAST(population_number_text AS BIGINT) END AS population,
    population_raw,
    population_note,
    CASE
        WHEN population_number_text RLIKE '^[0-9]+$' AND population_note IS NOT NULL THEN 'VALID_WITH_NOTE'
        WHEN population_number_text RLIKE '^[0-9]+$' THEN 'VALID'
        WHEN population_raw IS NULL OR TRIM(population_raw) IN ('', '-') THEN 'MISSING'
        ELSE 'INVALID'
    END AS population_parse_status,
    source_version,
    content_checksum,
    batch_id

FROM psgc_population_observations
""")


# -----------------------------------------------------------------------------
# 3. Profile the population observations (inspection only)
# -----------------------------------------------------------------------------
print("\nPopulation observations per source version")
show(
    spark.sql("""
SELECT
    source_version,
    COUNT(*) AS total_observations,
    COUNT_IF(population_parse_status = 'VALID') AS valid_population,
    COUNT_IF(population_parse_status = 'MISSING') AS missing_population,
    COUNT_IF(population_parse_status = 'INVALID') AS invalid_population,
    COUNT_IF(population_parse_status = 'VALID_WITH_NOTE') AS valid_with_note,
    COUNT(DISTINCT psgc_code) AS distinct_psgc_codes
FROM psgc_population_parsed
GROUP BY source_version
ORDER BY source_version
""")
)


# -----------------------------------------------------------------------------
# 4. Check the Silver grain: psgc_code x population_year x source_version
#    Stops the run before the table is replaced if any key is duplicated.
# -----------------------------------------------------------------------------
duplicate_keys = spark.sql("""
SELECT
    psgc_code,
    population_year,
    source_version,
    COUNT(*) AS row_count
FROM psgc_population_parsed
GROUP BY
    psgc_code,
    population_year,
    source_version
HAVING COUNT(*) > 1
ORDER BY
    row_count DESC,
    psgc_code,
    population_year
""")
duplicate_key_count = duplicate_keys.count()
print(f"\nDuplicate grain keys: {duplicate_key_count}")
if duplicate_key_count > 0:
    show(duplicate_keys, n=50)
    raise RuntimeError(
        f"{duplicate_key_count} duplicate psgc_code x population_year x source_version keys. "
        f"{SILVER_TABLE} was not replaced. Check that {BRONZE_TABLE} holds one snapshot per version."
    )


# -----------------------------------------------------------------------------
# 5. Validate population values
#    Missing numeric values are expected when the parse status is MISSING or INVALID.
# -----------------------------------------------------------------------------
print("\nPopulation value checks")
show(
    spark.sql("""
SELECT
    COUNT(*) AS total_observations,
    COUNT_IF(population_parse_status = 'VALID') AS valid_population,
    COUNT_IF(population_parse_status = 'MISSING') AS missing_population,
    COUNT_IF(population_parse_status = 'INVALID') AS invalid_population,
    COUNT_IF(population < 0) AS negative_population,
    COUNT_IF(population_parse_status = 'VALID_WITH_NOTE') AS valid_with_note,
    MIN(population) AS min_population,
    MAX(population) AS max_population
FROM psgc_population_parsed
""")
)


# -----------------------------------------------------------------------------
# 6. Validate accepted parse statuses (stops the run on an unexpected status)
# -----------------------------------------------------------------------------
statuses = [
    row["population_parse_status"]
    for row in spark.sql("""
        SELECT DISTINCT population_parse_status
        FROM psgc_population_parsed
        ORDER BY population_parse_status
    """).collect()
]
print(f"\nParse statuses: {statuses}")
unexpected = [s for s in statuses if s not in APPROVED_PARSE_STATUS]
if unexpected:
    raise RuntimeError(
        f"Unexpected parse status(es) {unexpected}. {SILVER_TABLE} was not replaced."
    )


# -----------------------------------------------------------------------------
# 7. Create the PSGC population Silver table (full rebuild)
#    Keeps every observation, including MISSING and INVALID; population_raw keeps the
#    original value and population_parse_status makes the quality state visible.
# -----------------------------------------------------------------------------
spark.sql(f"""
CREATE OR REPLACE TABLE {SILVER_TABLE}
USING DELTA
COMMENT 'PSGC population Silver layer'
AS

SELECT
    psgc_code,
    population_year,
    population,
    population_raw,
    population_note,
    population_parse_status,
    source_version,
    content_checksum,
    batch_id,
    CURRENT_TIMESTAMP() AS silver_processed_at
FROM psgc_population_parsed
""")
print(f"\nReplaced {SILVER_TABLE}")


# -----------------------------------------------------------------------------
# 8. Validate the created Silver table
# -----------------------------------------------------------------------------
summary = spark.sql(f"""
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT psgc_code) AS distinct_psgc_codes,
    COUNT(DISTINCT population_year) AS distinct_population_years,
    COUNT(DISTINCT source_version) AS distinct_source_versions,
    COUNT_IF(population_parse_status = 'VALID_WITH_NOTE') AS valid_with_note,
    COUNT_IF(population_parse_status = 'VALID') AS valid_population,
    COUNT_IF(population_parse_status = 'MISSING') AS missing_population,
    COUNT_IF(population_parse_status = 'INVALID') AS invalid_population
FROM {SILVER_TABLE}
""")
print("\nSilver table summary")
show(summary)

parsed_count = spark.table("psgc_population_parsed").count()
silver_count = summary.first()["total_rows"]
if silver_count != parsed_count:
    raise RuntimeError(f"Row-count mismatch: parsed {parsed_count}, Silver {silver_count}.")


# -----------------------------------------------------------------------------
# 9. Check the final Silver schema
# -----------------------------------------------------------------------------
EXPECTED_COLUMNS = [
    "psgc_code",
    "population_year",
    "population",
    "population_raw",
    "population_note",
    "population_parse_status",
    "source_version",
    "content_checksum",
    "batch_id",
    "silver_processed_at",
]
actual_columns = spark.table(SILVER_TABLE).columns
print(f"\nSilver columns: {actual_columns}")
if actual_columns != EXPECTED_COLUMNS:
    raise RuntimeError(
        f"Silver schema differs. Expected {EXPECTED_COLUMNS}, found {actual_columns}."
    )
spark.table(SILVER_TABLE).printSchema()


# -----------------------------------------------------------------------------
# 10. Sample the final Silver data
# -----------------------------------------------------------------------------
print("Sample rows")
show(
    spark.sql(f"""
SELECT
    psgc_code,
    population_year,
    population,
    population_raw,
    population_parse_status,
    source_version,
    batch_id,
    silver_processed_at
FROM {SILVER_TABLE}
ORDER BY
    psgc_code,
    population_year
LIMIT 20
""")
)


# -----------------------------------------------------------------------------
# 11. Reconciliation: province total vs sum of its cities and municipalities
#     Inspection only. The recorded check is S55 in psgc_population_silver_qc.py; its
#     qc_results detail is the live list. Exceptions seen 2026-10-11 (PSGC Q2_2024 payload):
#     Maguindanao del Norte 2015 and 2020 (province total excludes Cotabato City) and
#     Benguet 2015 (444,224 vs 446,224 in source).
# -----------------------------------------------------------------------------
reconciliation = spark.sql(f"""
WITH p AS (
  SELECT s.psgc_code, s.population_year, s.population, s.population_note, g.geographic_level
  FROM {SILVER_TABLE} s
  JOIN {GEOGRAPHY_TABLE} g USING (psgc_code)
)
SELECT pr.psgc_code, pr.population_year, pr.population AS province_total,
       l.lgu_sum, pr.population_note
FROM (SELECT * FROM p WHERE geographic_level = 'Prov') pr
JOIN (SELECT substr(psgc_code, 1, 5) AS prov, population_year, sum(population) AS lgu_sum
      FROM p WHERE geographic_level IN ('City', 'Mun') GROUP BY 1, 2) l
  ON l.prov = substr(pr.psgc_code, 1, 5) AND l.population_year = pr.population_year
WHERE NOT (pr.population <=> l.lgu_sum)
ORDER BY pr.psgc_code, pr.population_year
""")
print(
    f"Province totals that differ from the sum of their cities/municipalities: {reconciliation.count()}"
)
show(reconciliation, n=50)

print("PSGC population Bronze -> Silver completed.")
