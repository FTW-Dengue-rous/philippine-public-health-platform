# =============================================================================
# Point-in-polygon step for the OSM / Healthsites facility points (facilities-silver-plan.md v2.1,
# section 4.2 step v2 and section 12).
# Lineage contract v1.3: this is step 1 of the 04 build, not a build of its own. It writes only a
# staging table and no build_log row; facilities_silver_04_osm_point.sql checks the staging table
# against bronze and the boundaries, and records the build.
# Run order: 00a -> build_facilities_area_exceptions.py (when inputs change) -> 00 -> 01 -> 02 -> 03 -> [04a] -> 04
# Notebook: %pip install shapely, then %restart_python, then this file.
# Places every bronze point with coordinates in a city / municipality of geography silver, using
# the HDX boundaries in public_health.silver.facilities_area_boundary (built from the team's
# admin_boundaries_silver by facilities_silver_00a_area_boundary.sql; only boundary_rule = 'hdx'
# rows have a polygon). Geometry is GeoJSON in WGS84 lon/lat. Writes one STAGING table and nothing else:
#
#   public_health.silver.facilities_osm_point_silver__located   one row per bronze row
#
# facilities_silver_04_osm_point.sql reads it, resolves the rows without coordinates by their
# addr:city tag, validates, writes facilities_osm_point_silver and records the build. Run 04a and 04
# in the same job, right after each other; 04 stops if bronze or the boundaries changed in between.
#
# Why Python: point-in-polygon needs a geometry library (shapely). About 16,000 points x 1,600 polygons
# (2026-10-14 file) take a few seconds on the driver with an STRtree index. On a runtime with Databricks spatial SQL
# (ST_Contains, ST_GeomFromWKT) this step could be SQL instead; the output columns would not change.
#
# Rules
#   coordinate_status   ok | missing (X or Y blank: OSM ways in this export) | not_a_number |
#                       outside_ph (outside lon 114-127, lat 4-21.5)
#   point inside 1 polygon            -> locate_method point_in_polygon
#   point inside 2+ polygons          -> point_in_polygon, the smallest area wins, boundary_candidates > 1
#                                        (simplified borders touch; 04 reports it as a warning)
#   point inside none, nearest <= 1 km -> nearest_boundary (coastline points, piers, small islands)
#   point inside none, nearest > 1 km  -> not located here (04 tries the addr:city tag)
#   Distances are great-circle km between the point and the nearest polygon edge, approximated by
#   degrees x 111.32 x cos(latitude) for longitude; good to a few metres at these distances.
#
# Needs: pip install shapely (if the runtime does not have it), facilities_silver_00a_area_boundary.sql.
# Args : --catalog public_health (use '' for two-part names in local tests)
# 2026-10-14: reads only the newest Healthsites file (latest _as_of_date).
# =============================================================================
%pip install shapely
%restart_python

import argparse
import json
import math

from pyspark.sql import SparkSession
from pyspark.sql.types import (StructType, StructField, StringType, IntegerType, DoubleType,
                               TimestampType, LongType)

try:
    from shapely import STRtree, points
    from shapely.geometry import shape
    from shapely.validation import make_valid
except ImportError as e:   # make the cause obvious in the job log
    raise ImportError("shapely is required for the point-in-polygon step: %pip install shapely") from e

# Settings. Written to the staging table, so 04 records them in build_log.parameters (rule 2a, 2026-10-19).
# PH_BBOX is the same box as ph_bbox in facilities_silver_04_osm_point.sql and the 00a centroid gate.
NEAREST_MAX_KM = 1.0
PH_BBOX = (114.0, 4.0, 127.0, 21.5)     # lon_min, lat_min, lon_max, lat_max

p = argparse.ArgumentParser()
p.add_argument("--catalog", default="public_health")
args, _ = p.parse_known_args()
pre = f"{args.catalog}." if args.catalog else ""
BRONZE = f"{pre}bronze.facilities_hdx_healthsites_bronze"
BOUNDARY = f"{pre}silver.facilities_area_boundary"
TARGET = f"{pre}silver.facilities_osm_point_silver__located"

spark = SparkSession.builder.getOrCreate()


def table_version(name):
    try:
        return spark.sql(f"DESCRIBE HISTORY {name} LIMIT 1").collect()[0]["version"]
    except Exception:
        return None


def to_float(s):
    try:
        v = float(str(s).strip())
        return v if math.isfinite(v) else None
    except (TypeError, ValueError):
        return None


def km(lat, deg_dist):
    # degrees -> km; the nearest-edge distance mixes lon and lat, so use the mean of the two scales
    return deg_dist * 111.32 * (1 + math.cos(math.radians(lat))) / 2


# ---- boundaries -------------------------------------------------------------------------------
b = spark.sql(f"""SELECT psgc_code, CAST(area_km2 AS DOUBLE) AS area_km2, geometry_json
                  FROM {BOUNDARY} WHERE boundary_rule = 'hdx' AND geometry_json IS NOT NULL""").collect()
if not b:
    raise RuntimeError(f"{BOUNDARY} has no geometries: run facilities_silver_00a_area_boundary.sql first")
geoms, codes, areas = [], [], []
for r in b:
    try:
        g = shape(json.loads(r["geometry_json"]))
        geoms.append(g if g.is_valid else make_valid(g))
    except Exception as e:
        raise ValueError(f"Boundary GeoJSON does not parse for {r['psgc_code']}: {e}")
    codes.append(r["psgc_code"])
    areas.append(r["area_km2"] or geoms[-1].area)
tree = STRtree(geoms)

# ---- points -----------------------------------------------------------------------------------
# Only the newest file (latest _as_of_date): hdx_healthsites is load_mode latest_file and bronze keeps
# every snapshot. Same rule as fac_osm_latest_file in facilities_silver_04_osm_point.sql.
rows = spark.sql(f"""SELECT _source_key, _source_file, _source_sheet, _source_row_num, _ingested_at,
                            osm_type, osm_id, X, Y
                     FROM {BRONZE}
                     WHERE _source_key = 'hdx_healthsites'
                       AND _as_of_date = (SELECT max(_as_of_date) FROM {BRONZE}
                                          WHERE _source_key = 'hdx_healthsites')""").collect()

out, idx, pts = [], [], []
for r in rows:
    x, y = to_float(r["X"]), to_float(r["Y"])
    if r["X"] is None or r["Y"] is None or str(r["X"]).strip() == "" or str(r["Y"]).strip() == "":
        status = "missing"
    elif x is None or y is None:
        status = "not_a_number"
    elif not (PH_BBOX[0] <= x <= PH_BBOX[2] and PH_BBOX[1] <= y <= PH_BBOX[3]):
        status = "outside_ph"
    else:
        status = "ok"
    out.append({"_source_key": r["_source_key"], "_source_file": r["_source_file"],
                "_source_sheet": r["_source_sheet"], "_source_row_num": r["_source_row_num"],
                "_ingested_at": r["_ingested_at"], "osm_type": r["osm_type"], "osm_id": r["osm_id"],
                "longitude": x if status == "ok" else None, "latitude": y if status == "ok" else None,
                "coordinate_status": status, "located_psgc": None, "locate_method": None,
                "boundary_candidates": 0, "distance_to_boundary_km": None})
    if status == "ok":
        idx.append(len(out) - 1)
        pts.append((x, y))

if pts:
    geo_pts = points([p[0] for p in pts], [p[1] for p in pts])
    pi, gi = tree.query(geo_pts, predicate="intersects")
    hits = {}
    for i, g in zip(pi.tolist(), gi.tolist()):
        hits.setdefault(i, []).append(g)
    misses = [i for i in range(len(pts)) if i not in hits]
    for i, gl in hits.items():
        best = min(gl, key=lambda g: (areas[g], codes[g]))
        o = out[idx[i]]
        o.update(located_psgc=codes[best], locate_method="point_in_polygon",
                 boundary_candidates=len(gl), distance_to_boundary_km=0.0)
    if misses:
        ni, dist = tree.query_nearest(geo_pts[misses], return_distance=True, all_matches=False)
        for q, g, d in zip(ni[0].tolist(), ni[1].tolist(), dist.tolist()):
            o = out[idx[misses[q]]]
            d_km = round(km(o["latitude"], d), 3)
            o["distance_to_boundary_km"] = d_km
            if d_km <= NEAREST_MAX_KM:
                o.update(located_psgc=codes[g], locate_method="nearest_boundary", boundary_candidates=0)

bver = table_version(BOUNDARY)
schema = StructType([
    StructField("_source_key", StringType()), StructField("_source_file", StringType()),
    StructField("_source_sheet", StringType()), StructField("_source_row_num", IntegerType()),
    StructField("_ingested_at", TimestampType()), StructField("osm_type", StringType()),
    StructField("osm_id", StringType()), StructField("longitude", DoubleType()),
    StructField("latitude", DoubleType()), StructField("coordinate_status", StringType()),
    StructField("located_psgc", StringType()), StructField("locate_method", StringType()),
    StructField("boundary_candidates", IntegerType()), StructField("distance_to_boundary_km", DoubleType()),
    StructField("boundary_table_version", LongType()), StructField("boundary_rows", LongType()),
    StructField("nearest_max_km", DoubleType())])
data = [(o["_source_key"], o["_source_file"], o["_source_sheet"], o["_source_row_num"], o["_ingested_at"],
         o["osm_type"], o["osm_id"], o["longitude"], o["latitude"], o["coordinate_status"],
         o["located_psgc"], o["locate_method"], o["boundary_candidates"], o["distance_to_boundary_km"],
         bver, len(codes), float(NEAREST_MAX_KM)) for o in out]
(spark.createDataFrame(data, schema).write.mode("overwrite").option("overwriteSchema", "true")
      .saveAsTable(TARGET))

n_pip = sum(1 for o in out if o["locate_method"] == "point_in_polygon")
n_near = sum(1 for o in out if o["locate_method"] == "nearest_boundary")
n_multi = sum(1 for o in out if o["boundary_candidates"] > 1)
by_status = {}
for o in out:
    by_status[o["coordinate_status"]] = by_status.get(o["coordinate_status"], 0) + 1
print(f"{TARGET}: {len(out)} rows; coordinates {by_status}; point_in_polygon {n_pip} "
      f"(on a shared border {n_multi}); nearest_boundary {n_near}; not located by coordinates "
      f"{len(out) - n_pip - n_near}")