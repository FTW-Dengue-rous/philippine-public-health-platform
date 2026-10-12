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

# Databricks: install shapely first (cluster library, or run in a separate cell):
#   %pip install shapely
#   %restart_python
