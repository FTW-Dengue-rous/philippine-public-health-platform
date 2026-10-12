# =============================================================================
# facilities_silver_04a_osm_locate.py
#
# Locates OSM / Healthsites facility points by city or municipality using
# point-in-polygon against public_health.silver.facilities_area_boundary.
#
# Grain:
#   One row per Bronze OSM facility row.
#
# Boundaries:
#   facilities_area_boundary is built from admin_boundaries_silver by
#   facilities_silver_00a_area_boundary.sql.
#   Only boundary_rule = 'hdx' rows have usable polygons.
#   Geometry is GeoJSON in WGS84 longitude/latitude.
#
# Output:
#   public_health.silver.facilities_osm_point_silver__located
#
# This is a staging table only.
# facilities_silver_04_osm_point.sql reads it, resolves rows without coordinates
# using addr:city, validates the results, and writes facilities_osm_point_silver.
#
# Run 04a and 04 in the same job, one after the other.
# Step 04 stops if Bronze or the boundary table changed between the two steps.
#
# Why Python:
#   Point-in-polygon uses shapely with an STRtree spatial index.
#   The current data is small enough to process on the driver.
#   If Databricks spatial SQL is available, this step could later be replaced
#   with ST_Contains / spatial SQL without changing the output contract.
#
# Coordinate status:
#   ok           valid numeric coordinates within the Philippines bounds
#   missing      longitude or latitude is blank
#   not_a_number longitude or latitude cannot be parsed
#   outside_ph   outside lon 114-127 or lat 4-21.5
#
# Location rules:
#   Inside exactly 1 polygon
#     -> locate_method = 'point_in_polygon'
#
#   Inside 2+ polygons
#     -> use the smallest polygon
#     -> locate_method = 'point_in_polygon'
#     -> boundary_candidates > 1
#     -> Step 04 reports a warning
#
#   Inside no polygon, nearest boundary <= 1 km
#     -> locate_method = 'nearest_boundary'
#     -> intended for coastline points, piers and small islands
#
#   Inside no polygon, nearest boundary > 1 km
#     -> leave unresolved here
#     -> Step 04 tries addr:city matching
#
# Distance:
#   Distance to the nearest polygon edge is approximated in km using:
#     latitude  = degrees * 111.32
#     longitude = degrees * 111.32 * cos(latitude)
#
# Requirements:
#   - shapely, if not already installed on the runtime
#   - facilities_silver_00a_area_boundary.sql completed successfully
#
# Args:
#   --catalog public_health
#   Use --catalog '' for two-part names in local tests.
# =============================================================================

# =============================================================================
# facilities_silver_04a_osm_locate.py
# Point-in-polygon step for the OSM / Healthsites facility points (plan 4.2 step v2, section 12).
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
# Why Python: point-in-polygon needs a geometry library (shapely). 16,000 points x 1,600 polygons
# take a few seconds on the driver with an STRtree index. On a runtime with Databricks spatial SQL
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
# Status: ran on local Spark 4.0 against the landing file (2026-10-09). Not run on Databricks.
# =============================================================================
# Databricks: install shapely first (cluster library, or run in a separate cell):
#   %pip install shapely
#   %restart_python
