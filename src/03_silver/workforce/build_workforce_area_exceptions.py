# =============================================================================
# Writes the three workforce reference CSVs (workforce-silver-plan.md, sections 4.2 and 7.2):
#
#   workforce_area_exceptions.csv       FHSIS and PSA T9.14 labels the geography join cannot resolve
#   workforce_psmo_area_exceptions.csv  PSMO region labels, NCR districts, composite and odd labels
#   workforce_area_override.csv         row-level corrections (G6, G10), from the OVERRIDES table below
#
# Every decision lives in the tables of this script (REGIONS, MANUAL_CODES, NAMED_KEYS,
# NAME_VARIANTS_2025, OVERRIDES, PSMO_REGIONS, PSMO_AREAS). The CSVs are generated from them; do not
# edit the CSVs by hand. Changing a decision (e.g. accepting an override) = edit the table, rerun.
#
# What it does
#   Not a pipeline step. workforce_silver_00_reference.sql loads the CSVs; the build never runs this.
#   1. Reads geography from public_health.silver.geography_silver: one PSGC snapshot, the latest
#      content_checksum (the same rule and the same level mapping as the wf_geo view in
#      workforce_silver_01_fhsis_areas.sql).
#   2. Reads the area labels of the FHSIS (2018-2025), PSA T9.14 and PSMO bronze tables.
#   3. Applies the region labels and manual decisions listed below.
#   4. Tries the same automatic join the silver build uses (name core + level + parent region).
#   5. Writes every label the join cannot resolve, with its decision, to the exceptions files.
#   6. Overrides: each OVERRIDES row must still be in bronze with its original label, and its workbook
#      must still have the checksum it was reviewed against (same lookup as 01).
#   7. 2025: lists rows whose printed PSGC code is another area in geography (the build stops on them,
#      workforce_silver_01 gate). Each needs an OVERRIDES row (a wrong code, e.g. the swapped Surigao
#      del Norte / Alegria codes) or an entry in NAME_VARIANTS_2025 (same place, another name).
#      Region rows are skipped: their labels never match the geography names.
#   8. Checks every PSGC code it writes: it must exist in geography at the level the decision says.
#   If any label still has no decision, or any check fails, NOTHING is written to --out_dir: the
#   script writes workforce_area_unresolved.csv to --review_dir and stops, so nothing unreviewed
#   reaches the folder the build reads.
#
# Matching rules (same as workforce_silver_01_fhsis_areas.sql [1], [5], [6]; keep them identical)
#   - norm: a damaged n-tilde ('Ã±') read as 'ñ'; upper case, accents folded, punctuation removed,
#     single spaces.
#   - core: bracketed text removed, then a leading 'CITY OF ' (or 'ISLAND GARDEN CITY OF ',
#     'SCIENCE CITY OF ') or a trailing ' CITY' removed. Whether the LABEL had a city token is kept.
#   - a label with a city token matches geography cities only; a label without one matches a
#     province first, and a city or municipality only when the region has no province of that name.
#   - candidates are limited to the parent region's code, or the codes in child_region_codes.
#   - exactly one candidate is accepted; zero or several need a row in the exceptions file.
#
# How to run (Databricks job or notebook, after geography_silver and the workforce bronze tables)
#   python build_workforce_area_exceptions.py
#   python build_workforce_area_exceptions.py --overwrite true
#   It stops if the CSVs already exist in --out_dir; pass --overwrite true to replace them.
#   Review the diff of the three CSVs against the committed files, in the same PR as any
#   sources_workforce.yaml change, then run workforce_silver_00_reference.sql.
# =============================================================================

import argparse
import csv
import os
import re
import sys
import unicodedata

import pandas as pd
from pyspark.sql import SparkSession

AREA_COLS = [
    "_source_key",
    "year_from",
    "year_to",
    "match_role",
    "area_label_norm",
    "parent_label_norm",
    "psgc_code",
    "area_key",
    "named_key_level",
    "named_key_parent_psgc",
    "child_region_codes",
    "is_superseded_area",
    "reason",
    "note",
]
PSMO_COLS = [
    "_source_key",
    "match_role",
    "area_label_norm",
    "parent_label_norm",
    "psgc_code",
    "area_key",
    "named_key_level",
    "named_key_parent_psgc",
    "child_region_codes",
    "is_composite_area",
    "component_psgc_codes",
    "reason",
    "note",
]
OVERRIDE_COLS = [
    "_source_key",
    "_source_file",
    "_source_sheet",
    "_source_row_num",
    "_content_checksum",
    "original_label",
    "proposed_area_key",
    "evidence",
    "review_status",
    "reviewed_by",
    "reviewed_on",
]
FHSIS, PSA, PSMO = "doh_fhsis_demographic", "psa_gov_practitioners", "psmo_oncologists"

# ---------------------------------------------------------------------------------------------
# Row overrides (plan 4.2, G6 and G10): one bronze row whose printed label or code is wrong.
# Written to workforce_area_override.csv. Each entry is a reviewed decision with evidence:
#   bound_checksum  the content_checksum of the workbook the row was reviewed in. If the workbook is
#                   re-downloaded with other content, rows can move: the script stops until a person
#                   re-checks the row and updates this value (01 stops on the same mismatch).
#   review_status   proposed (row takes the key but stays ineligible) / accepted / rejected.
# ---------------------------------------------------------------------------------------------
_F2022 = "workforce/doh_fhsis_demographic/doh_fhsis_demographic_province_annual_2022.xlsx"
_F2025 = "workforce/doh_fhsis_demographic/doh_fhsis_demographic_municipality_annual_2025.xlsx"
_C2022 = "ad15429cebc9a4d67a6d4c723699ff597296bc6fa06fd44313086d24cc55221e"
_C2025 = "4ad975b4cb27af11a5338e7f65b8cb401ac79e9db43fd8fa139cf7b43ec79d2d"
OVERRIDES = [  # (file, sheet, row, bound_checksum, original_label, proposed_area_key, evidence, status, by, on)
    (
        _F2022,
        "HEALTH WORKERS PART1",
        17,
        _C2022,
        "Taguig City",
        "psgc:1381200000",
        "Row 17 of Part 2 in the same workbook is labelled Pasig City with the same population (828114); "
        "Pasig sits at this position in 2021 and 2023; Taguig is also listed at row 19",
        "proposed",
        "",
        "",
    ),
    (
        _F2022,
        "HEALTH WORKERS PART1",
        22,
        _C2022,
        "San Juan City",
        "psgc:1380300000",
        "Row 22 of Part 2 in the same workbook is labelled Makati City with the same population (638764); "
        "Makati sits at this position in 2021 and 2023; San Juan is also listed at row 24",
        "proposed",
        "",
        "",
    ),
    (
        _F2025,
        "Health Workers",
        1498,
        _C2025,
        "Surigao del Norte",
        "psgc:1606700000",
        "Printed code 1606701000 is Alegria's PSGC code; this row is the province row (listed before its "
        "municipalities, label Surigao del Norte). Row 1499 (Alegria) carries 1606700000. The two codes appear swapped",
        "proposed",
        "",
        "",
    ),
    (
        _F2025,
        "Health Workers",
        1499,
        _C2025,
        "Alegria",
        "psgc:1606701000",
        "Printed code 1606700000 is the Surigao del Norte province code; row 1498 (Surigao del Norte) carries "
        "Alegria's code 1606701000. The two codes appear swapped",
        "proposed",
        "",
        "",
    ),
]

# ---------------------------------------------------------------------------------------------
# FHSIS and PSA region labels (match_role = region). Region labels never match PSGC region names,
# so every variant is listed. child_region_codes: regions whose areas may be listed under the label
# (current PSGC moved Negros Occidental, Bacolod, Negros Oriental and Siquijor to NIR, 18).
# ---------------------------------------------------------------------------------------------
REGIONS = {  # region code -> (labels as printed in any year, child_region_codes)
    "13": (["N C R", "NCR", "METRO MANILA", "..NCR"], "13"),
    "14": (["C A R", "CAR", "..CAR"], "14"),
    "01": (["Region 1", "ILOCOS", "..I"], "01"),
    "02": (["Region 2", "CAGAYAN VALLEY", "..II"], "02"),
    "03": (["Region 3", "CENTRAL LUZON", "..III"], "03"),
    "04": (["Region 4A", "CALABARZON", "..IV-A"], "04"),
    "17": (["Region 4B", "MIMAROPA", "..MIMAROPA"], "17"),
    "05": (["Region 5", "BICOL", "..V"], "05"),
    "06": (["Region 6", "WESTERN VISAYAS", "..VI"], "06;18"),
    "07": (["Region 7", "CENTRAL VISAYAS", "..VII"], "07;18"),
    "08": (["Region 8", "EASTERN VISAYAS", "..VIII"], "08"),
    "09": (["Region 9", "ZAMBOANGA PENINSULA", "..IX"], "09"),
    "10": (["Region 10", "NORTHERN MINDANAO", "..X"], "10"),
    "11": (["Region 11", "DAVAO", "..XI"], "11"),
    "12": (["Region 12", "SOCCSKSARGEN", "..XII"], "12;19"),  # Cotabato City moved to BARMM
    "16": (["CARAGA", "Caraga", "..CARAGA"], "16"),
    "19": (["A.R.M.M.", "ARMM", "BARMM", "..BARMM"], "19"),
}
RENAMED_REGION_LABELS = {"A.R.M.M.", "ARMM"}  # ARMM (to 2018) -> BARMM in the comparison geography

# ---------------------------------------------------------------------------------------------
# Manual decisions for FHSIS / PSA area labels the join cannot resolve, keyed by the label as
# printed. Codes, not names: PSGC names change spelling, codes do not. Step 7 checks each code
# exists in geography at the stated level. Reviewed 2026-10-09 against the 2025 FHSIS PSGC codes.
# ---------------------------------------------------------------------------------------------
MANUAL_CODES = {  # label as printed -> (PSGC code, geography level, reason, note)
    "Compostela Valley": ("1108200000", "province", "old_name", "renamed Davao de Oro in 2019"),
    "Gen. Santos City": ("1230800000", "city", "name_variant", "City of General Santos"),
    "Gen.  Santos City": ("1230800000", "city", "name_variant", "double space in the 2018 file"),
    "Ilocos Note": ("0102800000", "province", "name_variant", "typo in the 2018 file"),
    "Legaspi City": ("0500506000", "city", "name_variant", "City of Legazpi"),
    "Mindoro Occidental": ("1705100000", "province", "name_variant", "Occidental Mindoro"),
    "Mindoro Oriental": ("1705200000", "province", "name_variant", "Oriental Mindoro"),
    "Mindoro Oriental *": ("1705200000", "province", "name_variant", "asterisk in the 2018 label"),
    "Mt. Province": ("1404400000", "province", "name_variant", "Mountain Province"),
    "North Cotabato": ("1204700000", "province", "old_name", "the province, not City of Cotabato"),
    "Northern Leyte": (
        "0803700000",
        "province",
        "old_name",
        "the province, not the municipality of Leyte",
    ),
    "Western Samar": ("0806000000", "province", "old_name", "Samar"),
    "Province of Dinagat": ("1608500000", "province", "name_variant", "Dinagat Islands"),
    "Ozamis City": ("1004210000", "city", "name_variant", "City of Ozamiz"),
    "SGA": (
        "1999900000",
        "special_geographic_area",
        "name_variant",
        "BARMM Special Geographic Area; a child of BARMM, not a region. Same code as the 2025 file",
    ),
}
NAMED_KEYS = {  # label -> (area_key, level, parent psgc, superseded, reason, note)
    "PHILIPPINES": ("ph", "country", "", "false", "no_psgc_code", ""),
    "Philippines": ("ph", "country", "", "false", "no_psgc_code", ""),
    "Maguindanao": (
        "hist:maguindanao",
        "province",
        "1900000000",
        "true",
        "no_psgc_code",
        "split into Maguindanao del Norte and del Sur in 2022; no current code",
    ),
}
# 2025 rows whose printed code is right but whose label differs from the geography name (the loose
# key still differs). label as printed -> (printed code, reason, note). Reviewed 2026-10-11 from the
# first run against public_health.silver.geography_silver.
_SGA = (
    "SGA cluster name used before the 2024 plebiscite that created the 8 SGA municipalities; "
    "printed code accepted"
)
NAME_VARIANTS_2025 = {
    "San Andress": ("1705912000", "name_variant", "Misspelling of San Andres (Romblon)"),
    "Pio V. Corpuz": ("0504116000", "name_variant", "Geography spells it Pio V. Corpus (Masbate)"),
    "Bacungan": ("0907226000", "old_name", "Former name of Leon T. Postigo (Zamboanga del Norte)"),
    "Carmen Cluster": ("1999901000", "old_name", f"Kapalawan. {_SGA}"),
    "Kabacan Cluster": (
        "1999902000",
        "old_name",
        f"Old Kaabakan (proposed as Northern Kabacan). {_SGA}",
    ),
    "Midsayap Cluster I": ("1999903000", "old_name", f"Kadayangan. {_SGA}"),
    "Midsayap Cluster II": ("1999904000", "old_name", f"Nabalawag (proposed as Kabalukan). {_SGA}"),
    "Pigcawayan Cluster": ("1999905000", "old_name", f"Pahamuddin. {_SGA}"),
    "Pikit Cluster I": ("1999906000", "old_name", f"Malidegao (proposed as Malmar). {_SGA}"),
    "Pikit Cluster II": ("1999907000", "old_name", f"Ligawasan. {_SGA}"),
    "Pikit Cluster III": (
        "1999908000",
        "old_name",
        f"Tugunan; the 2022 bill lists Aleosan barangays, DOH labels it a Pikit cluster. {_SGA}",
    ),
}

# ---------------------------------------------------------------------------------------------
# PSMO (plan 7.2). Region labels, then the area labels the join cannot resolve.
# ---------------------------------------------------------------------------------------------
PSMO_REGIONS = {  # label as printed -> (region code, child_region_codes, note)
    "NCR": ("13", "13", ""),
    "CAR": ("14", "14", ""),
    "Region 1": ("01", "01", ""),
    "Region 2": ("02", "02", ""),
    "Region 3": ("03", "03", ""),
    "Region 4-A": ("04", "04", ""),
    "MIMAROPA": ("17", "17", ""),
    "Region 5": ("05", "05", ""),
    "Region 6": ("06", "06;18", ""),
    "Region 7": ("07", "07;18", ""),
    "Region 8": ("08", "08", ""),
    "Region 9": ("09", "09", ""),
    "Region 10": ("10", "10;16", "PSMO lists Agusan del Sur under Region 10"),
    "Region 11": ("11", "11", ""),
    "Region 12": ("12", "12;19", ""),
    "Region 13": ("16", "16", "Region 13 = Caraga"),
    "Bangsamoro Region": ("19", "19", ""),
}
PSMO_AREAS = {  # (label as printed, region label) -> decision
    ("Metro Manila", "NCR"): dict(
        area_key="ncr:unassigned",
        named_key_level="region_area",
        named_key_parent_psgc="1300000000",
        reason="no_psgc_code",
        note="Listed beside the four NCR districts; may overlap them (D3). Never added to district counts",
    ),
    ("1st District City of Manila", "NCR"): dict(
        psgc_code="1380600000",
        level="city",
        reason="name_variant",
        note="NCR 1st district is the City of Manila",
    ),
    ("2nd District: Mandaluyong, Marikina, Pasig, Quezon City, San Juan", "NCR"): dict(
        area_key="ncr-district:2",
        named_key_level="ncr_district",
        named_key_parent_psgc="1300000000",
        components="1380500000;1380700000;1381200000;1381300000;1381400000",
        reason="composite_area",
    ),
    ("3rd District: Caloocan, Malabon, Navotas, Valenzuela", "NCR"): dict(
        area_key="ncr-district:3",
        named_key_level="ncr_district",
        named_key_parent_psgc="1300000000",
        components="1380100000;1380400000;1380900000;1381600000",
        reason="composite_area",
    ),
    ("4th District: Las Pinas, Makati, Muntinlupa, Paranaque, Pasay, Pateros, Taguig", "NCR"): dict(
        area_key="ncr-district:4",
        named_key_level="ncr_district",
        named_key_parent_psgc="1300000000",
        components="1380200000;1380300000;1380800000;1381000000;1381100000;1381701000;1381500000",
        reason="composite_area",
    ),
    ("Cagayan Valley", "Region 2"): dict(
        psgc_code="0200000000",
        level="region",
        reason="region_as_area",
        note="A region name used as an area of practice; stays at region level",
    ),
    ("Negros Oriental / Dumaguete City", "Region 7"): dict(
        area_key="composite:negros-oriental+dumaguete",
        named_key_level="composite_area",
        named_key_parent_psgc="1800000000",
        components="1804600000;1804610000",
        reason="composite_area",
    ),
    ("Zamboanga del Sur / Pagadian City", "Region 9"): dict(
        area_key="composite:zamboanga-del-sur+pagadian",
        named_key_level="composite_area",
        named_key_parent_psgc="0900000000",
        components="0907300000;0907322000",
        reason="composite_area",
    ),
    ("Agusan del Sur / San Francisco", "Region 10"): dict(
        area_key="composite:agusan-del-sur+san-francisco",
        named_key_level="composite_area",
        named_key_parent_psgc="1600000000",
        components="1600300000;1600308000",
        reason="composite_area",
    ),
    ("Misamis Occidental / Ozamiz", "Region 10"): dict(
        area_key="composite:misamis-occidental+ozamiz",
        named_key_level="composite_area",
        named_key_parent_psgc="1000000000",
        components="1004200000;1004210000",
        reason="composite_area",
    ),
    ("Cotabato City / Kidapawan, North Cotabato", "Region 12"): dict(
        area_key="composite:cotabato-city+kidapawan",
        named_key_level="composite_area",
        named_key_parent_psgc="",
        components="1908703000;1204704000",
        reason="composite_area",
        note="Components in two regions (BARMM, XII); no single parent",
    ),
}
COMPOSITE_NOTE = "Count is never copied to or split between the components"


# ---------------------------------------------------------------------------------------------
# Name rules (keep identical to wf_norm, wf_core, wf_has_city, wf_loose in workforce_silver_01)
# ---------------------------------------------------------------------------------------------
def norm(s):
    s = str(s or "").replace("Ã±", "ñ").replace("Ã‘", "Ñ")  # damaged n-tilde
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().upper()
    s = re.sub(r"[^A-Z0-9 ]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def core(s):
    n = norm(re.sub(r"\([^)]*\)", " ", str(s or "")))
    n = re.sub(r"^(ISLAND GARDEN CITY OF|SCIENCE CITY OF|CITY OF) ", "", n)
    return re.sub(r" CITY$", "", n)


def has_city(s):
    n = norm(s)
    return n.startswith("CITY OF ") or n.endswith(" CITY")


def loose(s):
    words = core(s).split(" ")
    words = [
        {
            "STA": "SANTA",
            "STO": "SANTO",
            "GEN": "GENERAL",
            "PRES": "PRESIDENT",
            "SEN": "SENATOR",
        }.get(w, w)
        for w in words
    ]
    return "".join(words)


def is_non_data(label):
    return label == "" or re.match(r"^(Legend|\*|0\s*[-=])", label, re.I) is not None


def code10(x):
    """Printed PSGC code left-padded to 10 digits; None when it is not 9 or 10 digits."""
    t = str(x).strip() if x is not None and not (isinstance(x, float) and x != x) else ""
    t = re.sub(r"\.0$", "", t)
    return t.zfill(10) if re.fullmatch(r"\d{9,10}", t) else None


def stop(msg):
    print("STOPPED: " + msg)
    sys.exit(1)


# ---------------------------------------------------------------------------------------------
# 1. Geography (same rules as the wf_geo view)
# ---------------------------------------------------------------------------------------------
LEVELS = {"Reg": "region", "Prov": "province", "City": "city", "Mun": "municipality"}


def load_geography(spark, table):
    if not spark.catalog.tableExists(table):
        stop(f"geography table not found: {table!r}. Build geography silver first")
    g = (
        spark.table(table)
        .select(
            "psgc_code",
            "area_name",
            "geographic_level",
            "city_class",
            "content_checksum",
            "silver_processed_at",
        )
        .toPandas()
    )
    latest = g.sort_values("silver_processed_at").content_checksum.dropna().iloc[-1]
    g = g[g.content_checksum == latest].copy()
    g["psgc_code"] = g.psgc_code.astype(str).str.strip().str.zfill(10)
    g["geo_level"] = g.geographic_level.map(LEVELS)
    g.loc[g.geographic_level.isna() & (g.psgc_code == "1999900000"), "geo_level"] = (
        "special_geographic_area"
    )
    g = g[g.geo_level.notna()].copy()  # drops SubMun, Bgy and the Isabela placeholder
    g["geo_name"] = g.area_name.astype(str).str.strip()
    g["city_class"] = g.city_class.where(g.geo_level == "city")
    g["name_core"] = g.geo_name.map(core)
    g["name_loose"] = g.geo_name.map(loose)
    regions = int((g.geo_level == "region").sum())
    if regions != 18:
        stop(f"{table} snapshot {latest[:12]}... has {regions} regions, expected 18")
    print(
        f"geography: {table}, snapshot {latest[:12]}..., {len(g)} areas "
        f"({g.geo_level.value_counts().to_dict()})"
    )
    return g


def candidates(geo, label, region_codes):
    """The automatic join: name core + level + parent region. Returns the candidate rows."""
    c, city = core(label), has_city(label)
    cand = geo[(geo.name_core == c) & geo.psgc_code.str[:2].isin(region_codes)]
    if city:
        return cand[cand.geo_level == "city"]
    prov = cand[cand.geo_level == "province"]
    return prov if len(prov) else cand[cand.geo_level.isin(["city", "municipality"])]


# ---------------------------------------------------------------------------------------------
# 2. Labels
# ---------------------------------------------------------------------------------------------
def fhsis_psa_labels(spark, bronze):
    """(source_key, year, label, parent region label, role, parent region codes) for every row that
    needs a label match, in file order. 2025 rows with a usable code are matched on the code instead
    (see codes_2025); their region rows still set the parent for 2025 rows without one."""
    out = []
    f = (
        spark.table(f"{bronze}.workforce_fhsis_health_workers_bronze")
        .select(
            "_source_key",
            "_source_file",
            "_source_sheet",
            "_source_row_num",
            "area_name",
            "psgc_code",
        )
        .toPandas()
    )
    f["year"] = f._source_file.str.extract(r"_(\d{4})\.xlsx$")[0].astype(int)
    f.columns = [c.lstrip("_") for c in f.columns]  # itertuples drops names starting with "_"
    f["code10"] = f.psgc_code.map(code10)
    region_labels = {lab for labs, _ in REGIONS.values() for lab in labs}
    region_kids = {lab: kids for labs, kids in REGIONS.values() for lab in labs}
    for (_, _), g in f.sort_values("source_row_num").groupby(["source_file", "source_sheet"]):
        parent, kids = "", ""
        for r in g.itertuples():
            lab = r.area_name.strip() if isinstance(r.area_name, str) else ""
            if is_non_data(lab):
                continue
            if r.year == 2025 and isinstance(r.code10, str):
                if r.code10.endswith("00000000"):  # 2025 region row: sets the parent by code
                    parent, kids = lab, r.code10[:2]
                continue
            if lab in region_labels:
                parent, kids = lab, region_kids[lab]
                out.append((r.source_key, r.year, lab, "", "region", ""))
            else:
                out.append((r.source_key, r.year, lab, parent, "area", kids))
    p = (
        spark.table(f"{bronze}.workforce_psa_gov_practitioners_bronze")
        .select("_source_key", "Region")
        .toPandas()
    )
    p.columns = ["source_key", "Region"]
    for r in p.drop_duplicates().itertuples():
        lab = r.Region.strip()
        out.append(
            (r.source_key, 0, lab, "", "region" if lab in region_labels else "area", "")
        )  # year 0: 2012-2023
    return pd.DataFrame(
        out, columns=["source_key", "year", "label", "parent_label", "role", "parent_codes"]
    )


def codes_2025(spark, bronze, geo, override_rows):
    """2025 rows whose printed code is another area in geography (loose keys differ)."""
    f = (
        spark.table(f"{bronze}.workforce_fhsis_health_workers_bronze")
        .select("_source_file", "_source_sheet", "_source_row_num", "area_name", "psgc_code")
        .toPandas()
    )
    f = f[f._source_file.str.contains(r"_2025\.xlsx$")]
    f["code10"] = f.psgc_code.map(code10)
    names = dict(zip(geo.psgc_code, geo.name_loose, strict=False))
    shown = dict(zip(geo.psgc_code, geo.geo_name, strict=False))
    level = dict(zip(geo.psgc_code, geo.geo_level, strict=False))
    out = []
    for r in f.itertuples(index=False):
        if (
            not isinstance(r.code10, str)
            or r.code10 not in names
            or (r[0], r[1], int(r[2])) in override_rows
        ):
            continue
        if level[r.code10] == "region":  # region rows are taken by code and level; their
            continue  # labels ('Region 1', 'NCR') never match the names
        if NAME_VARIANTS_2025.get((r.area_name or "").strip(), ("",))[0] == r.code10:
            continue
        if loose(r.area_name) != names[r.code10]:
            out.append((r[2], r.area_name, r.code10, shown[r.code10]))
    return out


def file_checksums(spark, bronze):
    """Current content_checksum per FHSIS file and sheet: the same lookup as wf_fhsis_file_versions in
    workforce_silver_01 (bronze load time -> ingestion_metadata, status processed)."""
    return {
        (r._source_file, r._source_sheet): (r.n, r.checksum)
        for r in spark.sql(f"""
        SELECT i._source_file, i._source_sheet, count(m.batch_id) AS n, max(m.content_checksum) AS checksum
        FROM (SELECT DISTINCT _source_key, _source_file, _source_sheet, _ingested_at
              FROM {bronze}.workforce_fhsis_health_workers_bronze WHERE _source_key = '{FHSIS}') i
        LEFT JOIN {bronze}.ingestion_metadata m
          ON m.source_name = i._source_key AND lower(m.status) = 'processed'
         AND endswith(m.raw_file_path, concat('/', i._source_file))
         AND m.source_sheet <=> i._source_sheet AND m.retrieved_at = i._ingested_at
        GROUP BY i._source_file, i._source_sheet""").collect()
    }


def check_overrides(spark, bronze):
    """Every OVERRIDES entry: valid status, the workbook still has the reviewed checksum, and the bronze
    row still carries the original label. Returns (rows for the CSV, problems)."""
    sums = file_checksums(spark, bronze)
    f = (
        spark.table(f"{bronze}.workforce_fhsis_health_workers_bronze")
        .select("_source_file", "_source_sheet", "_source_row_num", "area_name")
        .toPandas()
    )
    label_at = {
        (a, b, int(c)): d
        for a, b, c, d in zip(
            f._source_file, f._source_sheet, f._source_row_num, f.area_name, strict=False
        )
    }
    rows, problems = [], []
    for file, sheet, row, bound, label, key, evidence, status, by, on in OVERRIDES:
        where = f"override {file.rsplit('/', 1)[-1]} {sheet} row {row} {label!r}"
        n, current = sums.get((file, sheet), (0, None))
        if status not in ("proposed", "accepted", "rejected"):
            problems.append(
                (where, f"review_status {status!r} is not proposed / accepted / rejected")
            )
        if n != 1:
            problems.append(
                (where, f"{n} ingestion_metadata matches for this file and sheet (need 1)")
            )
        elif current != bound:
            problems.append(
                (
                    where,
                    f"workbook checksum is now {current}, reviewed against {bound}: "
                    "re-check the row, then update bound_checksum in OVERRIDES",
                )
            )
        printed = label_at.get((file, sheet, row))
        if printed is None or norm(printed) != norm(label):
            problems.append((where, f"bronze row label is {printed!r}, expected {label!r}"))
        if not key.startswith("psgc:"):
            problems.append((where, f"proposed_area_key {key!r} must be psgc:<code>"))
        rows.append(
            dict(
                _source_key=FHSIS,
                _source_file=file,
                _source_sheet=sheet,
                _source_row_num=row,
                _content_checksum=bound,
                original_label=label,
                proposed_area_key=key,
                evidence=evidence,
                review_status=status,
                reviewed_by=by,
                reviewed_on=on,
            )
        )
    return pd.DataFrame(rows, columns=OVERRIDE_COLS), problems


# ---------------------------------------------------------------------------------------------
# 3. Main
# ---------------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--catalog", default="public_health", help="'' gives two-part names (local tests)"
    )
    ap.add_argument("--geography_table", default="silver.geography_silver")
    ap.add_argument(
        "--out_dir",
        default="/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/workforce",
        help="Folder workforce_silver_00_reference.sql reads",
    )
    ap.add_argument(
        "--review_dir",
        default="",
        help="Where workforce_area_unresolved.csv goes when labels need a decision (default: --out_dir)",
    )
    ap.add_argument(
        "--overwrite", default="false", help="'true' replaces existing CSVs in --out_dir"
    )
    args, _ = ap.parse_known_args()
    prefix = f"{args.catalog}." if args.catalog else ""
    bronze = f"{prefix}bronze"
    spark = SparkSession.builder.getOrCreate()

    geo = load_geography(spark, f"{prefix}{args.geography_table}")
    level_of = dict(zip(geo.psgc_code, geo.geo_level, strict=False))
    unresolved, code_problems = [], []

    def check_code(code, level, where):
        if code not in level_of:
            code_problems.append((where, code, level, "not in geography"))
        elif level and level_of[code] != level:
            code_problems.append((where, code, level, f"geography level is {level_of[code]}"))

    # ---- FHSIS and PSA ---------------------------------------------------------------------
    region_of = {
        lab: (code + "00000000", kids) for code, (labs, kids) in REGIONS.items() for lab in labs
    }
    lab = fhsis_psa_labels(spark, bronze)
    lab["label_norm"] = lab.label.map(norm)
    lab["parent_norm"] = lab.parent_label.map(norm)
    rows = []
    for (src, _), g in lab[lab.role == "region"].groupby(["source_key", "label_norm"]):
        label = g.label.iloc[0]
        code, kids = region_of[label]
        check_code(code, "region", f"{src} region {label!r}")
        yrs = sorted(set(g.year))
        rows.append(
            dict(
                _source_key=src,
                year_from=2012 if yrs == [0] else min(yrs),
                year_to=2023 if yrs == [0] else max(yrs),
                match_role="region",
                area_label_norm=norm(label),
                parent_label_norm="",
                psgc_code=code,
                area_key="",
                named_key_level="",
                named_key_parent_psgc="",
                child_region_codes=kids,
                is_superseded_area="false",
                reason="region_renamed" if label in RENAMED_REGION_LABELS else "region_label",
                note="ARMM until 2018; BARMM in the comparison geography"
                if label in RENAMED_REGION_LABELS
                else "",
            )
        )

    for (src, _, _, _), g in lab[lab.role == "area"].groupby(
        ["source_key", "label_norm", "parent_norm", "parent_codes"]
    ):
        label, parent = g.label.iloc[0], g.parent_label.iloc[0]
        yrs = sorted(set(g.year))
        base = dict(
            _source_key=src,
            year_from=2012 if yrs == [0] else min(yrs),
            year_to=2023 if yrs == [0] else max(yrs),
            match_role="area",
            area_label_norm=norm(label),
            parent_label_norm=norm(parent),
            psgc_code="",
            area_key="",
            named_key_level="",
            named_key_parent_psgc="",
            child_region_codes="",
            is_superseded_area="false",
            reason="",
            note="",
        )
        if label in NAMED_KEYS:
            k, lvl, par, sup, reason, note = NAMED_KEYS[label]
            rows.append(
                {
                    **base,
                    "parent_label_norm": "",
                    "area_key": k,
                    "named_key_level": lvl,
                    "named_key_parent_psgc": par,
                    "is_superseded_area": sup,
                    "reason": reason,
                    "note": note,
                }
            )
            continue
        if label == "SGA":  # a child of BARMM in any year; parent left blank
            code, level, reason, note = MANUAL_CODES[label]
            check_code(code, level, f"{src} {label!r}")
            rows.append(
                {**base, "parent_label_norm": "", "psgc_code": code, "reason": reason, "note": note}
            )
            continue
        regions = (
            g.parent_codes.iloc[0] or (region_of[parent][1] if parent in region_of else "")
        ).split(";")
        cand = candidates(geo, label, regions)
        if len(cand) == 1 and label not in MANUAL_CODES:
            continue  # resolved by the join: no exception needed
        if label in MANUAL_CODES:
            code, level, reason, note = MANUAL_CODES[label]
            check_code(code, level, f"{src} {label!r}")
            rows.append({**base, "psgc_code": code, "reason": reason, "note": note})
            continue
        cands = (
            "; ".join(f"{r.geo_name} {r.psgc_code} ({r.geo_level})" for r in cand.itertuples())
            or "none"
        )
        unresolved.append(
            dict(
                _source_key=src,
                years=f"{yrs[0]}-{yrs[-1]}",
                parent_label=parent,
                label=label,
                problem=f"{len(cand)} geography candidates",
                candidates=cands,
            )
        )

    # 2025: printed code that is another area in geography (override file rows are skipped)
    ov, ov_problems = check_overrides(spark, bronze)
    for where, problem in ov_problems:
        unresolved.append(
            dict(
                _source_key=FHSIS,
                years="",
                parent_label="",
                label=where,
                problem=problem,
                candidates="",
            )
        )
    override_rows = {
        (a, b, int(c))
        for a, b, c in zip(ov._source_file, ov._source_sheet, ov._source_row_num, strict=False)
    }
    for row_num, key, label in zip(
        ov._source_row_num, ov.proposed_area_key, ov.original_label, strict=False
    ):
        check_code(str(key).replace("psgc:", ""), "", f"override row {row_num} {label!r}")
    for row_num, label, code, geo_name in codes_2025(spark, bronze, geo, override_rows):
        unresolved.append(
            dict(
                _source_key=FHSIS,
                years="2025-2025",
                parent_label="",
                label=label,
                problem=f"row {row_num}: printed code {code} is {geo_name!r} in geography",
                candidates="OVERRIDES (wrong code) or NAME_VARIANTS_2025 (other spelling)",
            )
        )
    for label, (code, reason, note) in NAME_VARIANTS_2025.items():
        check_code(code, "", f"2025 name variant {label!r}")
        rows.append(
            dict(
                _source_key=FHSIS,
                year_from=2025,
                year_to=2025,
                match_role="area",
                area_label_norm=norm(label),
                parent_label_norm="",
                psgc_code=code,
                area_key="",
                named_key_level="",
                named_key_parent_psgc="",
                child_region_codes="",
                is_superseded_area="false",
                reason=reason,
                note=note,
            )
        )

    area = pd.DataFrame(rows, columns=AREA_COLS)
    keys = [c for c in AREA_COLS if c not in ("year_from", "year_to")]
    area = (
        area.groupby(keys, dropna=False, as_index=False).agg(
            year_from=("year_from", "min"), year_to=("year_to", "max")
        )
    )[AREA_COLS]
    area = area.sort_values(
        ["_source_key", "match_role", "year_from", "parent_label_norm", "area_label_norm"]
    )

    # ---- PSMO ---------------------------------------------------------------------------------
    psmo = (
        spark.table(f"{bronze}.workforce_psmo_oncologists_bronze")
        .select("region", "province_area")
        .toPandas()
    )
    prow = []
    for lab_, (code, kids, note) in PSMO_REGIONS.items():
        code10_ = code + "00000000"
        check_code(code10_, "region", f"PSMO region {lab_!r}")
        prow.append(
            dict(
                _source_key=PSMO,
                match_role="region",
                area_label_norm=norm(lab_),
                parent_label_norm="",
                psgc_code=code10_,
                area_key="",
                named_key_level="",
                named_key_parent_psgc="",
                child_region_codes=kids,
                is_composite_area="false",
                component_psgc_codes="",
                reason="region_label",
                note=note,
            )
        )
    for r in psmo.drop_duplicates().itertuples(index=False):
        region, label = str(r.region).strip(), str(r.province_area).strip()
        if region not in PSMO_REGIONS:
            unresolved.append(
                dict(
                    _source_key=PSMO,
                    years="",
                    parent_label="",
                    label=region,
                    problem="region label not in PSMO_REGIONS",
                    candidates="",
                )
            )
            continue
        d = PSMO_AREAS.get((label, region))
        if d is None:
            cand = candidates(geo, label, PSMO_REGIONS[region][1].split(";"))
            if len(cand) != 1:
                cands = (
                    "; ".join(
                        f"{c.geo_name} {c.psgc_code} ({c.geo_level})" for c in cand.itertuples()
                    )
                    or "none"
                )
                unresolved.append(
                    dict(
                        _source_key=PSMO,
                        years="",
                        parent_label=region,
                        label=label,
                        problem=f"{len(cand)} geography candidates",
                        candidates=cands,
                    )
                )
            continue  # resolved by the join
        components = d.get("components", "")
        for c in filter(None, components.split(";")):
            check_code(c, "", f"PSMO component of {label!r}")
        if d.get("psgc_code"):
            check_code(d["psgc_code"], d.get("level", ""), f"PSMO {label!r}")
        prow.append(
            dict(
                _source_key=PSMO,
                match_role="area",
                area_label_norm=norm(label),
                parent_label_norm=norm(region),
                psgc_code=d.get("psgc_code", ""),
                area_key=d.get("area_key", ""),
                named_key_level=d.get("named_key_level", ""),
                named_key_parent_psgc=d.get("named_key_parent_psgc", ""),
                child_region_codes="",
                is_composite_area="true" if components else "false",
                component_psgc_codes=components,
                reason=d["reason"],
                note=d.get("note")
                or (
                    COMPOSITE_NOTE
                    if d["reason"] == "composite_area" and "district" not in d.get("area_key", "")
                    else ""
                ),
            )
        )
    psmo_out = pd.DataFrame(prow, columns=PSMO_COLS)

    # ---- stop, or write -------------------------------------------------------------------------
    review_dir = args.review_dir or args.out_dir
    if unresolved or code_problems:
        for p in code_problems:
            unresolved.append(
                dict(
                    _source_key="",
                    years="",
                    parent_label="",
                    label=p[0],
                    problem=f"code {p[1]} (level {p[2] or 'any'}): {p[3]}",
                    candidates="",
                )
            )
        os.makedirs(review_dir, exist_ok=True)
        path = os.path.join(review_dir, "workforce_area_unresolved.csv")
        pd.DataFrame(unresolved).to_csv(path, index=False, quoting=csv.QUOTE_MINIMAL)
        for u in unresolved:
            print(
                f"  {u['_source_key']} {u['years']} [{u['parent_label']}] {u['label']!r}: {u['problem']} | {u['candidates']}"
            )
        stop(
            f"{len(unresolved)} label(s) or code(s) need a decision; listed in {path}. "
            "Add them to MANUAL_CODES / NAMED_KEYS / PSMO_AREAS / NAME_VARIANTS_2025 / OVERRIDES and rerun. "
            "Nothing was written to the reference folder"
        )
    files = [
        "workforce_area_exceptions.csv",
        "workforce_psmo_area_exceptions.csv",
        "workforce_area_override.csv",
    ]
    existing = [f for f in files if os.path.exists(os.path.join(args.out_dir, f))]
    if existing and str(args.overwrite).lower() != "true":
        stop(
            f"these files already exist in {args.out_dir}: {existing}. Pass --overwrite true to replace them"
        )
    os.makedirs(args.out_dir, exist_ok=True)
    area.to_csv(os.path.join(args.out_dir, files[0]), index=False)
    psmo_out.to_csv(os.path.join(args.out_dir, files[1]), index=False)
    ov.to_csv(os.path.join(args.out_dir, files[2]), index=False)
    print(
        f"wrote {files[0]}: {len(area)} rows ({(area.match_role == 'region').sum()} region labels, "
        f"{(area.match_role == 'area').sum()} area labels)"
    )
    print(
        f"wrote {files[1]}: {len(psmo_out)} rows ({(psmo_out.match_role == 'region').sum()} region labels, "
        f"{(psmo_out.match_role == 'area').sum()} area labels)"
    )
    print(f"wrote {files[2]}: {len(ov)} rows ({ov.review_status.value_counts().to_dict()})")
    print(
        "geography check passed for every code written. Review the diff, commit, then run workforce_silver_00_reference.sql"
    )


if __name__ == "__main__":
    main()
