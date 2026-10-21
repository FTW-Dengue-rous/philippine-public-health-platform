# =============================================================================
# Converts the HDX Healthsites GeoJSON into a CSV with the same columns as the
# Healthsites CSV the pipeline already loads, with coordinates for every row.
#
# Why
#   The HDX CSV export has blank X / Y for OSM "way" rows (building outlines, 3,870 of
#   16,032 rows, including most hospitals). The GeoJSON export carries the outline, so the
#   centre of each building can be computed (facilities decision D12).
#
# What it does
#   Point            X / Y = the point
#   Polygon          X / Y = centroid of the outer ring (area-weighted)
#   MultiPolygon     X / Y = centroid of all outer rings together (area-weighted)
#   Column names and order are copied from the header of the old CSV, so bronze and
#   silver run unchanged. Values are written as published, with one exception:
#   changeset_timestamp is rewritten from the GeoJSON form (2021-06-26T00:51:51Z) to the
#   CSV form (2021/06/26 00:51:51+00) that silver parses.
# =============================================================================
import argparse
import csv
import json
import re
from collections import Counter

FOLDER = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/facilities/hdx_healthsites"
GEOJSON = f"{FOLDER}/raw_geojson/hdx_healthsites_facility_asof_20261014.geojson"
OLD_CSV = f"{FOLDER}/hdx_healthsites_facility_asof_20260929.csv"
OUT_CSV = f"{FOLDER}/hdx_healthsites_facility_asof_20261014.csv"

PH_BOX = (116.0, 127.5, 4.0, 21.5)  # lon min, lon max, lat min, lat max
NODE_TOLERANCE_DEG = 0.00001  # about 1 metre: node moved since the old file
DECIMALS = 7  # OSM precision


def ring_centroid(ring):
    """Area-weighted centroid of one closed ring. Returns (lon, lat, area).
    Coordinates are shifted to the first corner before the sums. With raw lon/lat
    (about 120, 14) the cross products of a building-sized ring cancel out and lose
    the precision needed: centroids moved up to 3 km and 1,762 of 3,869 fell outside
    their own outline. Shifted, the error is gone."""
    x0, y0 = ring[0]
    pts = [(x - x0, y - y0) for x, y in ring]
    a = cx = cy = 0.0
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        cross = x1 * y2 - x2 * y1
        a += cross
        cx += (x1 + x2) * cross
        cy += (y1 + y2) * cross
    if abs(a) < 1e-20:  # a line or a single spot: plain average of the corners
        corners = ring[:-1] or ring
        return (
            sum(p[0] for p in corners) / len(corners),
            sum(p[1] for p in corners) / len(corners),
            0.0,
        )
    return x0 + cx / (3 * a), y0 + cy / (3 * a), abs(a) / 2


def inside(lon, lat, ring):
    """True if the point is inside the closed ring (ray casting). Used as a check only."""
    hit = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > lat) != (y2 > lat) and lon < (x2 - x1) * (lat - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def centroid(geometry):
    """(lon, lat) of a GeoJSON geometry, or (None, None)."""
    if not geometry:
        return None, None
    kind, coords = geometry.get("type"), geometry.get("coordinates")
    if kind == "Point":
        return coords[0], coords[1]
    if kind == "Polygon":
        outers = [coords[0]]
    elif kind == "MultiPolygon":
        outers = [poly[0] for poly in coords]
    else:
        return None, None
    parts = [ring_centroid([(p[0], p[1]) for p in ring]) for ring in outers if len(ring) >= 2]
    if not parts:
        return None, None
    total = sum(p[2] for p in parts)
    if total == 0:
        return sum(p[0] for p in parts) / len(parts), sum(p[1] for p in parts) / len(parts)
    return sum(p[0] * p[2] for p in parts) / total, sum(p[1] * p[2] for p in parts) / total


ISO_TS = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2}:\d{2})Z$")


def csv_timestamp(value):
    """GeoJSON writes changeset_timestamp as 2021-06-26T00:51:51Z; the CSV export (and silver's
    to_timestamp(..., 'yyyy/MM/dd HH:mm:ssx')) uses 2021/06/26 00:51:51+00. Return the CSV form,
    or None if the value has neither form."""
    if value in ("", None):
        return ""
    m = ISO_TS.match(value)
    if m:
        return f"{m.group(1)}/{m.group(2)}/{m.group(3)} {m.group(4)}+00"
    return value if re.match(r"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}\+00$", value) else None


def text(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--geojson", default=GEOJSON)
    p.add_argument("--old_csv", default=OLD_CSV)
    p.add_argument("--out", default=OUT_CSV)
    a, _ = p.parse_known_args()

    with open(a.old_csv, encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        header = reader.fieldnames
        old = {(r["osm_type"], r["osm_id"]): r for r in reader}
    features = json.load(open(a.geojson, encoding="utf-8"))["features"]

    props = set().union(*(f["properties"].keys() for f in features))
    missing = [c for c in header if c not in props and c not in ("X", "Y")]
    extra = sorted(props - set(header))
    if missing:
        raise SystemExit(
            f"STOPPED. Columns of the old CSV that the GeoJSON does not have: {missing}"
        )

    rows, problems, kinds = [], [], Counter()
    for f in features:
        pr = f["properties"]
        lon, lat = centroid(f.get("geometry"))
        key = (text(pr.get("osm_type")), text(pr.get("osm_id")))
        if lon is None:
            problems.append(f"{key}: no usable geometry")
        elif not (PH_BOX[0] <= lon <= PH_BOX[1] and PH_BOX[2] <= lat <= PH_BOX[3]):
            kinds["outside the Philippines box (kept; silver decides)"] += 1
        geom = f.get("geometry") or {}
        kinds[geom.get("type")] += 1
        if lon is not None and geom.get("type") in ("Polygon", "MultiPolygon"):
            rings = (
                [geom["coordinates"][0]]
                if geom["type"] == "Polygon"
                else [p[0] for p in geom["coordinates"]]
            )
            if not any(inside(lon, lat, [(q[0], q[1]) for q in r]) for r in rings):
                kinds["centroid outside its own outline (L/U-shaped building; kept)"] += 1
        row = {c: text(pr.get(c)) for c in header if c not in ("X", "Y")}
        if "changeset_timestamp" in row:
            ts = csv_timestamp(row["changeset_timestamp"])
            if ts is None:
                problems.append(
                    f"{key}: changeset_timestamp in an unknown format: {row['changeset_timestamp']!r}"
                )
            else:
                row["changeset_timestamp"] = ts
        row["X"] = "" if lon is None else f"{lon:.{DECIMALS}f}"
        row["Y"] = "" if lat is None else f"{lat:.{DECIMALS}f}"
        rows.append((key, row))

    keys = [k for k, _ in rows]
    dup = [k for k, n in Counter(keys).items() if n > 1]
    if dup:
        problems.append(f"duplicate (osm_type, osm_id): {dup[:10]}")

    # Compare with the old CSV
    new_keys, old_keys = set(keys), set(old)
    moved = filled = 0
    for key, row in rows:
        o = old.get(key)
        if not o:
            continue
        if o["X"].strip() and o["Y"].strip():
            if row["X"] and (
                abs(float(o["X"]) - float(row["X"])) > NODE_TOLERANCE_DEG
                or abs(float(o["Y"]) - float(row["Y"])) > NODE_TOLERANCE_DEG
            ):
                moved += 1
        elif row["X"]:
            filled += 1

    print(f"features read:            {len(features)}")
    print(f"geometry types:           {dict(kinds)}")
    print(f"rows in the old CSV:      {len(old)}")
    print(f"only in the old CSV:      {len(old_keys - new_keys)}")
    print(f"only in the GeoJSON:      {len(new_keys - old_keys)}")
    print(f"coordinates newly filled: {filled}")
    print(f"old coordinates changed:  {moved}   (more than {NODE_TOLERANCE_DEG} degrees)")
    print(f"rows without coordinates: {sum(1 for _, r in rows if not r['X'])}")
    print(f"GeoJSON fields not in the CSV layout (not written): {extra}")
    if problems:
        raise SystemExit("STOPPED, nothing written:\n  " + "\n  ".join(problems[:20]))

    with open(a.out, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=header, lineterminator="\n")  # LF, like the HDX CSV
        w.writeheader()
        w.writerows(r for _, r in rows)
    print(f"wrote {a.out}  ({len(rows)} rows, {len(header)} columns)")


if __name__ == "__main__":
    main()
