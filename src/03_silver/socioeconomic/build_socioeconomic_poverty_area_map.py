# =============================================================================
# Drafts socioeconomic_poverty_area_map.csv from the PSA poverty workbook, the
# PSGC datafile and the geography_silver snapshot.
#
# What it does
#   Lists the areas published in the poverty workbook (sheet tab2), gives each one a
#   level, a parent region (as published), a PSGC code, a stable area_key and a
#   proposed geographic coverage basis.
#
# This is a DRAFTING tool, not a pipeline step
#   The CSV it writes is a reviewed contract kept in the repo. Run this script when PSA
#   publishes a new release or geography_silver gets a new snapshot, compare the output
#   with the CSV in the repo, and review every difference before committing. The silver
#   job reads the CSV, never this script.
#
# How to run
#   Databricks notebook cell (reads geography_silver itself):
#     %run or python build_socioeconomic_poverty_area_map.py \
#         --poverty  <landing_root>/socioeconomic/psa_poverty/psa_poverty_province_biennial_2021_2025.xlsx \
#         --psgc     <landing_root>/geography/psa_psgc/psa_psgc_barangay_asof_20260713.xlsx \
#         --out      <landing_root>/reference/socioeconomic/socioeconomic_poverty_area_map.csv
#   Laptop (no Spark): export the snapshot first and pass it with --geography
#     SELECT psgc_code, area_name, geographic_level FROM public_health.silver.geography_silver
#     WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at)
#                               FROM public_health.silver.geography_silver)
#       AND geographic_level IN ('Reg', 'Prov', 'City')
#   The CSV must end up in <landing_root>/reference/socioeconomic/, the folder
#   socioeconomic_silver_00_reference.sql reads. Keep the same copy in the repo.
#
# Where the codes come from
#   Names and population notes come from the PSGC datafile. The CODE written to the CSV is
#   always the one public_health.silver.geography_silver holds (decision D-30: geography_silver
#   is the only source of PSGC codes). The two can differ: the PSGC datafile may be a newer
#   release than the snapshot in silver. align_to_snapshot() replaces a code the snapshot does
#   not have with the snapshot's code for the same name and level, and prints every change.
#   The codes are checked again by socioeconomic_silver_00_reference.sql,
#   socioeconomic_silver_05_poverty_geography_check.sql and socioeconomic_silver_qc.py.
#
# 2026-10-11: Isabela City now maps to 0990101000 (the PSGC city row), the same code the diseases
#   area map uses. Every code written must now sit at the expected PSGC level.
# 2026-10-13: codes are aligned to the geography_silver snapshot. Found by the gold build:
#   Sulu was written as 0906600000 (PSGC file of 13 Jul 2026, Region IX) while geography_silver
#   (Q2 2024) has 1906600000, so fact_poverty could not find its area. See docs/runbook.md.
#
# Requires: openpyxl. Spark only when --geography is not given.
# =============================================================================

import argparse
import collections
import csv
import re

import openpyxl

DATA_START_ROW = 7  # 0-based, same as data_start_row in sources_socioeconomic.yaml
YEARS = (2021, 2023, 2025)
INCIDENCE_COL = {2021: 4, 2023: 5, 2025: 6}  # positions in tab2 (poverty_tab2 layout in the YAML)
GEOGRAPHY_TABLE = "public_health.silver.geography_silver"
SNAPSHOT_LEVEL = {"region": "Reg", "province": "Prov", "city": "City"}  # map level -> PSGC level

# Manual decisions. Every entry here is a judgement that a person reviewed.
PROVINCE_NAME_FIXES = {"mt. province": "mountain province"}  # poverty name -> PSGC name
LISTED_CITIES = {
    "Isabela City": "0990101000",  # PSGC city row "City of Isabela". Not 0990100000
    # "City of Isabela (Not a Province)", a placeholder
    # with no level and no population
    "Cotabato City": "1908703000",
}  # PSGC "City of Cotabato"
SUPERSEDED = {"Maguindanao": "hist:maguindanao"}  # split into del Norte / del Sur; no current code

FIELDS = [
    "area_key",
    "geo_name_source",
    "geo_level",
    "psgc_code",
    "parent_geo_name_source",
    "geo_coverage_basis",
    "coverage_confirmed",
    "first_estimate_year",
    "is_superseded_area",
    "comparison_eligible",
    "exclusion_reason",
    "source_order",
]


def norm(text):
    # Lower case, single spaces: used to compare names.
    return re.sub(r"\s+", " ", str(text)).strip().lower()


def read_poverty_areas(path):
    # Area rows of tab2, selected by STRUCTURE: every row from the first data row up to the
    # "Notes:" line that has an area name. No row is chosen by whether a value is a number.
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    rows = list(wb["tab2"].iter_rows(values_only=True))
    wb.close()
    areas = []
    for i in range(DATA_START_ROW, len(rows)):
        name = rows[i][0]
        if isinstance(name, str) and name.strip().lower().startswith("notes"):
            break
        if isinstance(name, str) and name.strip():
            areas.append((name.strip(), rows[i]))
    return areas


def read_psgc(path):
    # Region and province names with their codes, plus the population note of each province
    # (the unnamed column after "2024 Population", e.g. "(excluding CITY OF BAGUIO)").
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    rows = list(wb["PSGC"].iter_rows(values_only=True))[1:]
    wb.close()
    regions = {norm(r[1]): str(r[0]) for r in rows if r[3] == "Reg"}
    provinces = {norm(r[1]): (str(r[0]), r[9]) for r in rows if r[3] == "Prov"}
    levels = {str(r[0]): r[3] for r in rows}  # code -> PSGC level (Reg, Prov, City, ...)
    return regions, provinces, levels


def read_snapshot(path=None):
    # The latest geography_silver snapshot, region, province and city rows:
    # code -> level, and (level, name) -> code. From a CSV export when a path is given,
    # otherwise from the table through Spark.
    if path:
        with open(path, newline="", encoding="utf-8-sig") as f:
            rows = [
                (r["psgc_code"], r["area_name"], r["geographic_level"]) for r in csv.DictReader(f)
            ]
    else:
        from pyspark.sql import SparkSession

        spark = SparkSession.builder.getOrCreate()
        rows = [
            tuple(r)
            for r in spark.sql(f"""
            SELECT psgc_code, area_name, geographic_level FROM {GEOGRAPHY_TABLE}
            WHERE content_checksum = (SELECT max_by(content_checksum, silver_processed_at) FROM {GEOGRAPHY_TABLE})
              AND geographic_level IN ('Reg', 'Prov', 'City')""").collect()
        ]
    if not rows:
        raise ValueError("the geography snapshot has no region, province or city rows")
    by_code = {str(c).strip().zfill(10): lvl for c, _, lvl in rows}
    by_name = {(lvl, norm(name)): str(c).strip().zfill(10) for c, name, lvl in rows}
    return by_code, by_name


def build(areas, regions, provinces, levels):
    out, parent = [], ""
    for order, (name, row) in enumerate(areas, 1):
        n = norm(name)
        code, basis, eligible, reason, superseded = "", "", "true", "", "false"

        if name == "PHILIPPINES":
            level, key, basis = "country", "ph", "country"
        elif n in regions:
            level, code, basis = "region", regions[n], "region"
            key, parent = "psgc:" + code, name  # areas below belong to this region
        elif re.match(r"^\d(st|nd|rd|th) District$", name):
            level, key, basis = "ncr_district", "ncr-district:" + name[0], "ncr_district"
            eligible, reason = "false", "no_psgc_equivalent"
        elif name in LISTED_CITIES:
            level, code, basis = "city", LISTED_CITIES[name], "city_listed_separately"
            key = "psgc:" + code
            if levels.get(code) != "City":  # a typed code must be a PSGC city row
                raise ValueError(
                    f"{name}: code {code} is not a City row in the PSGC file "
                    f"(found level: {levels.get(code)!r})"
                )
        elif name in SUPERSEDED:
            level, key, basis = "province", SUPERSEDED[name], "superseded_province"
            eligible, reason, superseded = "false", "superseded_area", "true"
        else:
            level = "province"
            match = provinces.get(PROVINCE_NAME_FIXES.get(n, n))
            if match is None:  # a new or renamed area: stop, do not guess
                raise ValueError(
                    f"'{name}' is not a PSGC region or province and has no manual rule. "
                    "Add it to PROVINCE_NAME_FIXES, LISTED_CITIES or SUPERSEDED."
                )
            code, note = match
            key = "psgc:" + code
            if note and "ISABELA" in note.upper():
                basis, eligible, reason = (
                    "province_excl_listed_city",
                    "false",
                    "coverage_unconfirmed",
                )
            elif note:  # PSGC population excludes a highly urbanized city
                basis, eligible = "province_incl_huc", "false"
                reason = "poverty_includes_huc_psgc_population_excludes"
            else:
                basis = "province"

        # First year with a published incidence estimate.
        first_year = next(
            (y for y in YEARS if isinstance(row[INCIDENCE_COL[y]], (int, float))), None
        )
        if first_year is None:
            raise ValueError(f"'{name}' has no incidence estimate in any year")

        out.append(
            {
                "area_key": key,
                "geo_name_source": name,
                "geo_level": level,
                "psgc_code": code,
                "parent_geo_name_source": "" if level in ("country", "region") else parent,
                "geo_coverage_basis": basis,
                "coverage_confirmed": "false" if level == "province" else "true",
                "first_estimate_year": first_year,
                "is_superseded_area": superseded,
                "comparison_eligible": eligible,
                "exclusion_reason": reason,
                "source_order": order,
            }
        )
    return out


def align_to_snapshot(rows, by_code, by_name):
    # Every PSGC code written must be the one geography_silver holds, at the expected level.
    # A code the snapshot does not have (an area PSA has since moved or recoded, e.g. Sulu) is
    # replaced by the snapshot's code for the same name and level. No match: stop, do not guess.
    # parent_geo_name_source is NOT changed: it stays the region as PSA published it.
    changed = []
    for r in rows:
        code, want = r["psgc_code"], SNAPSHOT_LEVEL.get(r["geo_level"])
        if not code or by_code.get(code) == want:
            continue
        name = norm(r["geo_name_source"])
        new = by_name.get((want, PROVINCE_NAME_FIXES.get(name, name)))
        if new is None:
            raise ValueError(
                f"{r['geo_name_source']}: code {code} is not a {want} row in geography_silver, "
                "and no area of that name and level exists there. Review it by hand."
            )
        changed.append((r["geo_name_source"], code, new))
        r["psgc_code"], r["area_key"] = new, "psgc:" + new
    print(f"codes aligned to the geography_silver snapshot: {len(changed)}")
    for name, old, new in changed:
        print(f"  {name}: {old} -> {new}")
    return rows


def check(rows):
    # Stop on duplicate keys or codes; print a summary to review.
    for field in ("area_key", "geo_name_source"):
        dup = [k for k, v in collections.Counter(r[field] for r in rows).items() if v > 1]
        if dup:
            raise ValueError(f"duplicate {field}: {dup}")
    dup = [
        k
        for k, v in collections.Counter(r["psgc_code"] for r in rows if r["psgc_code"]).items()
        if v > 1
    ]
    if dup:
        raise ValueError(f"duplicate psgc_code: {dup}")
    area_years = sum(len([y for y in YEARS if y >= r["first_estimate_year"]]) for r in rows)
    print(f"areas: {len(rows)}  expected area-years: {area_years}")
    print("by level:   ", dict(collections.Counter(r["geo_level"] for r in rows)))
    print("by coverage:", dict(collections.Counter(r["geo_coverage_basis"] for r in rows)))
    print(
        "not comparison-eligible:",
        dict(
            collections.Counter(
                r["exclusion_reason"] for r in rows if r["comparison_eligible"] == "false"
            )
        ),
    )


def main():
    p = argparse.ArgumentParser(
        description="Draft the poverty area map from the PSA poverty and PSGC files"
    )
    p.add_argument("--poverty", required=True, help="Path to the PSA poverty workbook")
    p.add_argument("--psgc", required=True, help="Path to the PSGC datafile")
    p.add_argument(
        "--geography",
        default=None,
        help="CSV export of the geography_silver snapshot (psgc_code, area_name, "
        "geographic_level). Leave out on Databricks: the table is read through Spark",
    )
    p.add_argument("--out", default="socioeconomic_poverty_area_map.csv", help="CSV to write")
    args = p.parse_args()

    areas = read_poverty_areas(args.poverty)
    regions, provinces, levels = read_psgc(args.psgc)
    rows = build(areas, regions, provinces, levels)
    rows = align_to_snapshot(rows, *read_snapshot(args.geography))
    check(rows)
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
