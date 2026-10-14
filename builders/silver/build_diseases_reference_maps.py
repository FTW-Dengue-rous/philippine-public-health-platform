# =============================================================================
# build_diseases_reference_maps.py
#
# Drafting tool for the diseases Silver reference files.
# This is NOT a pipeline step.
#
# Reads the diseases Bronze tables and generates four CSVs for manual review:
#
#   diseases_area_map.csv
#     Published area label / id -> area_key, PSGC code and geography level
#
#   diseases_cause_map.csv
#     Published cause label / code -> disease_key and row class
#
#   diseases_directory.csv
#     One row per disease_key.
#     Used later to build dim_disease in Gold.
#
#   diseases_cause_aggregation.csv
#     Approved cause aggregation sets.
#     Current set: psa_death_composition_v1
#
# Output:
#   Writes the CSVs to config/reference/ in the Volume used by
#   diseases_silver_00_reference.sql.
#
# Review the generated files before committing them to the repo.
# diseases_silver.py reads only the reviewed CSVs.
# It never runs this script.
#
# Run:
#   %run ./build_diseases_reference_maps
#
#   or
#
#   python build_diseases_reference_maps.py
#
# Existing CSVs are protected by default.
# Use --overwrite true only when you intend to regenerate them.
#
# Rules:
#   - If a label matches no rule, stop the script.
#     Add a manual rule only after confirming what the area or cause represents.
#
#   - Get PSGC codes for regions, provinces, cities and municipalities from
#     geography Silver using one PSGC snapshot.
#
#   - Validate every PSGC code before writing the area map.
#     Stop if the code is missing from geography Silver or has the wrong level.
#
#   - Rerun this tool when a new source file introduces new labels.
#     Review the CSV diff and commit the reviewed changes in the same PR.
# =============================================================================

import argparse
import csv
import os
import re
import sys

from pyspark.sql import SparkSession

# ----------------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", default="public_health",
                   help="Catalog name. Use '' for a two-part name (local tests)")
    p.add_argument("--out_dir",
                   default="/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/diseases",
                   help="Folder for the four CSVs. Default is the folder diseases_silver_00_reference.sql reads")
    p.add_argument("--overwrite", default="false",
                   help="'true' replaces existing CSVs. Default 'false' stops if a CSV already exists, "
                        "so reviewed files are not replaced by accident")
    p.add_argument("--geography_table", default="silver.geography_silver",
                   help="Geography silver table (schema.table). Source of the PSGC names and codes")
    a, _ = p.parse_known_args()
    return a


ARGS = parse_args()
PREFIX = f"{ARGS.catalog}." if ARGS.catalog else ""
BRONZE = f"{PREFIX}bronze"
spark = SparkSession.builder.getOrCreate()


def tbl(name):
    return spark.table(f"{BRONZE}.{name}")


# ----------------------------------------------------------------------------------
# Normalisation. The silver SQL uses the same rule (see norm_sql in diseases_silver.py):
# upper case, N for N-tilde, everything that is not A-Z, 0-9 becomes a space, single spaces.
# ----------------------------------------------------------------------------------
def norm(s):
    s = (s or "").upper().replace("Ñ", "N")
    s = re.sub(r"[^A-Z0-9]", " ", s)
    return re.sub(r" +", " ", s).strip()


def stop(msg):
    print("STOPPED: " + msg)
    sys.exit(1)


# ----------------------------------------------------------------------------------
# 1. PSGC lookup: names and codes from geography silver (regions, provinces, cities, municipalities)
# ----------------------------------------------------------------------------------
REGION_CODES = {
    "01": "Region I (Ilocos Region)", "02": "Region II (Cagayan Valley)",
    "03": "Region III (Central Luzon)", "04": "Region IV-A (CALABARZON)",
    "05": "Region V (Bicol Region)", "06": "Region VI (Western Visayas)",
    "07": "Region VII (Central Visayas)", "08": "Region VIII (Eastern Visayas)",
    "09": "Region IX (Zamboanga Peninsula)", "10": "Region X (Northern Mindanao)",
    "11": "Region XI (Davao Region)", "12": "Region XII (SOCCSKSARGEN)",
    "13": "National Capital Region (NCR)", "14": "Cordillera Administrative Region (CAR)",
    "16": "Region XIII (Caraga)", "17": "MIMAROPA Region",
    "18": "Negros Island Region (NIR)", "19": "Bangsamoro Autonomous Region in Muslim Mindanao (BARMM)",
}

GEO_TABLE = f"{PREFIX}{ARGS.geography_table}"
if not ARGS.geography_table or not spark.catalog.tableExists(GEO_TABLE):
    stop(f"geography table not found: {GEO_TABLE!r}. Build geography silver first")
geo_df = spark.table(GEO_TABLE)
# geography_silver keeps one row per psgc_code and content_checksum, so one snapshot is required.
GEO_SNAPSHOTS = [r[0] for r in geo_df.select("content_checksum").distinct().collect()]
if len(GEO_SNAPSHOTS) != 1:
    stop(f"{GEO_TABLE} holds {len(GEO_SNAPSHOTS)} PSGC snapshots; this script needs exactly one")

# Rows with no level are left out: 0990100000 'City of Isabela (Not a Province)' is a placeholder
# (the city is 0990101000) and 1999900000 is the Special Geographic Area. Barangays are not needed.
geo_rows = (geo_df
            .filter("geographic_level IN ('Reg', 'Prov', 'City', 'Mun')")
            .selectExpr("lpad(trim(psgc_code), 10, '0') AS code", "trim(area_name) AS name",
                        "geographic_level AS level")
            .collect())
GEO_LEVEL_OF = {r.code: r.level for r in geo_rows}     # used again by the check in section 10


def city_swap(n):
    """CITY OF X and X CITY are the same place."""
    m = re.match(r"^CITY OF (.+)$", n)
    return f"{m.group(1)} CITY" if m else n


def geo_name_key(name):
    """Lookup key for a geography name. The n-tilde is repaired first, in case geography silver
    still holds the damaged form (two characters, written here as escapes)."""
    return city_swap(norm((name or "").replace("\u00c3\u00b1", "\u00f1")))


PROV = {}   # normalised name -> code, for codes ending in 00000 (provinces, HUCs, NCR cities)
MUNI = {}   # (province prefix, normalised name) -> code
MUNI_BY_NAME = {}
for r in geo_rows:
    if r.level == "Reg":
        continue
    key = geo_name_key(r.name)
    if r.code.endswith("00000"):
        if key in PROV and PROV[key] != r.code:
            stop(f"two province-level geography rows share the name {key!r}: {PROV[key]}, {r.code}")
        PROV[key] = r.code
    else:
        MUNI[(r.code[:5], key)] = r.code
        MUNI_BY_NAME.setdefault(key, []).append(r.code)

region_found = {r.code[:2] for r in geo_rows if r.level == "Reg"}
if region_found != set(REGION_CODES):
    stop(f"region codes in geography differ from the expected 18: {sorted(region_found ^ set(REGION_CODES))}")


def region_code(label):
    """Region label in any of the sources -> two-digit PSGC region code."""
    n = norm(label)
    if "BARMM" in n or "BANGSAMORO" in n:
        return "19"
    if "CORDILLERA" in n or n == "CAR":
        return "14"
    if "NATIONAL CAPITAL" in n or n == "NCR":
        return "13"
    if "MIMAROPA" in n:
        return "17"
    if "NEGROS ISLAND" in n or n == "NIR":
        return "18"
    if "CARAGA" in n or re.search(r"\bXIII\b", n):
        return "16"
    m = re.match(r"^REGION (XII|XI|X|IX|VIII|VII|VI|V|IV A|III|II|I)\b", n)
    roman = {"I": "01", "II": "02", "III": "03", "IV A": "04", "V": "05", "VI": "06", "VII": "07",
             "VIII": "08", "IX": "09", "X": "10", "XI": "11", "XII": "12"}
    return roman[m.group(1)] if m else None


def parent_of(code):
    """Parent in current PSGC, from the code. Region for provinces and HUCs, province for municipalities.
    A municipality whose 5-digit prefix has no province row in geography (Pateros, City of Isabela)
    hangs on its region."""
    if code is None:
        return ""
    if code.endswith("00000000"):
        return "ph"
    if code.endswith("00000") or GEO_LEVEL_OF.get(f"{code[:5]}00000") != "Prov":
        return f"psgc:{code[:2]}00000000"
    return f"psgc:{code[:5]}00000"


AREA_COLS = ["_source_key", "match_type", "match_value", "parent_label_norm", "year_from", "year_to",
             "area_label_source", "area_key", "psgc_code", "geo_level", "parent_area_key",
             "geo_coverage_basis", "is_superseded_area",
             "override_source_file", "override_source_sheet", "override_source_row_num",
             "override_content_checksum", "review_note"]
area_rows = []


def add_area(source_key, match_type, match_value, label, area_key, psgc, level, coverage,
             parent_label="", year_from="", year_to="", superseded="false", parent_key=None,
             note="", override=None):
    o = override or {}
    area_rows.append({
        "_source_key": source_key, "match_type": match_type, "match_value": match_value,
        "parent_label_norm": parent_label, "year_from": year_from, "year_to": year_to,
        "area_label_source": label, "area_key": area_key, "psgc_code": psgc or "",
        "geo_level": level,
        "parent_area_key": parent_key if parent_key is not None else parent_of(psgc),
        "geo_coverage_basis": coverage, "is_superseded_area": superseded,
        "override_source_file": o.get("file", ""), "override_source_sheet": o.get("sheet", ""),
        "override_source_row_num": o.get("row", ""), "override_content_checksum": "",
        "review_note": note,
    })


# ----------------------------------------------------------------------------------
# 2. Area map: region-level sources
# ----------------------------------------------------------------------------------
def add_regions(source_key, labels, coverage_by_code=None, **kw):
    for lab in sorted(labels):
        rc = region_code(lab)
        if rc is None:
            stop(f"{source_key}: region label not recognised: {lab!r}")
        code = f"{rc}00000000"
        cov = (coverage_by_code or {}).get(rc, "region")
        add_area(source_key, "label", norm(lab), lab.strip(), f"psgc:{code}", code, "region", cov, **kw)


# DOH FOI dengue: 18 regions, NIR listed for every month of 2021-2025.
labels = [r[0] for r in tbl("diseases_doh_foi_dengue_bronze").select("Region").distinct().collect()]
add_regions("doh_foi_dengue", labels)

# UP NOAH: 17 regions, no Negros Island Region. Regions VI and VII are the older, larger areas.
labels = [r[0] for r in tbl("diseases_upnoah_dengue_regional_bronze").select("REGION").distinct().collect()]
PRE_NIR = {"06": "region_pre_nir_definition", "07": "region_pre_nir_definition"}
add_regions("upnoah", labels, coverage_by_code=PRE_NIR)

# PSA deaths by region: 2023 has 17 regions (no NIR), 2024 has 18. Philippines and Foreign Country are rows too.
psa_reg = spark.sql(f"""
    SELECT DISTINCT trim(geolocation) AS lab, regexp_extract(_source_file, '_([0-9]{{4}})\\\\.', 1) AS yr
    FROM {BRONZE}.diseases_psa_deaths_region_annual_bronze
""").collect()
years_by_label = {}
for r in psa_reg:
    years_by_label.setdefault(norm(r.lab), {"lab": r.lab, "years": set()})["years"].add(r.yr)
has_nir_year = {r.yr for r in psa_reg if region_code(r.lab) == "18"}
for n_lab, info in sorted(years_by_label.items()):
    lab = re.sub(r"^[.\s]+", "", info["lab"])
    if n_lab == "PHILIPPINES":
        add_area("psa_deaths_region_annual", "label", n_lab, lab, "ph", "", "country", "country", parent_key="")
    elif n_lab == "FOREIGN COUNTRY":
        add_area("psa_deaths_region_annual", "label", n_lab, lab, "foreign", "", "foreign",
                 "usual_residence_abroad", parent_key="")
    else:
        rc = region_code(lab)
        if rc is None:
            stop(f"psa_deaths_region_annual: label not recognised: {lab!r}")
        code = f"{rc}00000000"
        if rc in ("06", "07"):
            # one row per definition: before and after the Negros Island Region
            for yr in sorted(info["years"]):
                cov = "region" if yr in has_nir_year else "region_pre_nir_definition"
                add_area("psa_deaths_region_annual", "label", n_lab, lab, f"psgc:{code}", code, "region", cov,
                         year_from=yr, year_to=yr)
        else:
            add_area("psa_deaths_region_annual", "label", n_lab, lab, f"psgc:{code}", code, "region", "region")

# ----------------------------------------------------------------------------------
# 3. Area map: HDX dengue (province and city labels)
# ----------------------------------------------------------------------------------
# Manual decisions. Each was checked by hand; do not add one without checking the area.
HDX_MANUAL = {
    "MAGUINDANAO":    ("hist:maguindanao", "", "province", "superseded_province", "true",
                       "Split into Maguindanao del Norte and del Sur; no current PSGC code"),
    "BASILIG CITY":   (None, "BISLIG CITY", "city", None, "false", "Typo in the file for Bislig City"),
    "SISQUIJOR":      (None, "SIQUIJOR", "province", None, "false", "Typo in the file for Siquijor"),
    "TACLOBAN":       (None, "TACLOBAN CITY", "city", None, "false", "Printed without 'City'"),
    "NORTH COTABATO": (None, "COTABATO", "province", None, "false", "Old name of Cotabato province"),
    "NUEVA VISCAYA":  (None, "NUEVA VIZCAYA", "province", None, "false", "Typo in the file"),
    "NAGA CITY":      (None, "0501724000", "city", None, "false",
                       "Listed under Region V: Naga City, Camarines Sur (not Naga, Cebu)"),
    "ISABELA CITY":   (None, "0990101000", "city", None, "false",
                       "PSGC city row 'City of Isabela'. Not 0990100000 'City of Isabela (Not a Province)', "
                       "which is a placeholder with no level and no population"),
}
hdx = spark.sql(f"""
    SELECT DISTINCT trim(loc) AS loc
    FROM {BRONZE}.diseases_hdx_dengue_bronze
    WHERE loc NOT LIKE '#%'
""").collect()
for r in sorted(hdx, key=lambda x: x.loc):
    n = norm(r.loc)
    note = ""
    superseded = "false"
    if n in HDX_MANUAL:
        key, target, level, cov, superseded, note = HDX_MANUAL[n]
        if key:                                  # named key, no PSGC code
            add_area("hdx_dengue", "label", n, r.loc, key, "", level, cov, superseded=superseded,
                     parent_key="psgc:1900000000", note=note)
            continue
        code = target if target.isdigit() else (PROV.get(target) or (MUNI_BY_NAME.get(target) or [None])[0])
    else:
        code = PROV.get(n)
        level = "city" if (code and n.endswith(" CITY")) else "province"
        if code is None:
            hits = MUNI_BY_NAME.get(n, [])
            if len(hits) != 1:
                stop(f"hdx_dengue: area not resolved (matches: {hits}): {r.loc!r}")
            code, level = hits[0], ("city" if n.endswith(" CITY") else "municipality")
    if code is None:
        stop(f"hdx_dengue: manual rule did not resolve: {r.loc!r}")
    cov = "city_listed_separately" if level in ("city", "municipality") else "province_listed_cities_separate_unconfirmed"
    add_area("hdx_dengue", "label", n, r.loc, f"psgc:{code}", code, level, cov, note=note)

# ----------------------------------------------------------------------------------
# 4. Area map: IHME GBD (matched on location_id)
# ----------------------------------------------------------------------------------
IHME_MANUAL = {
    "COTABATO NORTH COTABATO": "COTABATO",
    "SAMAR WESTERN SAMAR": "SAMAR",
}
ihme = tbl("diseases_ihme_gbd_bronze").select("location_id", "location_name").distinct().collect()
for r in sorted(ihme, key=lambda x: x.location_name):
    n = norm(r.location_name)
    if n == "NATIONAL CAPITAL REGION":
        add_area("ihme_gbd", "source_id", r.location_id, r.location_name, "psgc:1300000000", "1300000000",
                 "region", "modelled_region", note="IHME lists NCR as one location")
    elif n == "MAGUINDANAO":
        add_area("ihme_gbd", "source_id", r.location_id, r.location_name, "hist:maguindanao", "", "province",
                 "superseded_province", superseded="true", parent_key="psgc:1900000000",
                 note="IHME keeps the undivided province; no current PSGC code")
    else:
        code = PROV.get(IHME_MANUAL.get(n, n))
        if code is None:
            stop(f"ihme_gbd: location not resolved: {r.location_id} {r.location_name!r}")
        add_area("ihme_gbd", "source_id", r.location_id, r.location_name, f"psgc:{code}", code, "province",
                 "modelled_province_coverage_unconfirmed")

# ----------------------------------------------------------------------------------
# 5. Area map: FHSIS TB. Rows resolve by their own PSGC code; the map holds only the
#    Philippines row and the row-level override (finding F7).
# ----------------------------------------------------------------------------------
add_area("doh_fhsis", "label", "PHILIPPINES", "PHILIPPINES", "ph", "", "country", "country", parent_key="",
         note="Used when the row has no PSGC code (2025 sheet)")
f7 = spark.sql(f"""
    SELECT _source_file, _source_sheet, _source_row_num, trim(area_name) AS name, lpad(psgc_code, 10, '0') AS code
    FROM {BRONZE}.diseases_fhsis_tb_bronze
    WHERE upper(trim(area_name)) = 'PHILIPPINES' AND psgc_code IS NOT NULL
""").collect()
for r in f7:
    add_area("doh_fhsis", "row_override", norm(r.name), r.name, "ph", "", "country", "country", parent_key="",
             parent_label=r.code,
             override={"file": r._source_file, "sheet": r._source_sheet, "row": r._source_row_num},
             note=f"F7: the Philippines row carries code {r.code} (NCR). Matched on file, sheet, row, label "
                  f"and printed code (parent_label_norm). Fill override_content_checksum after the first build")

# ----------------------------------------------------------------------------------
# 6. Area map: hospital encounters (patient province and city labels; names only, no counts)
# ----------------------------------------------------------------------------------
ENC = "davao_hospital_pneumonia"
ENC_PROV_MANUAL = {
    "COMPOSTELA VALLEY": ("DAVAO DE ORO", "Old name of Davao de Oro"),
    "COTABATO NORTH COTABATO": ("COTABATO", ""),
    "NORTH COTABATO": ("COTABATO", "Old name of Cotabato province"),
}
enc = tbl("diseases_davao_hospital_pneumonia_bronze").select("Province", "City").distinct().collect()
prov_code = {}
for p in sorted({r.Province for r in enc if r.Province and r.Province.strip()}):
    n = norm(p)
    note = ""
    if n == "MAGUINDANAO":
        add_area(ENC, "label", n, p.strip(), "hist:maguindanao", "", "province", "patient_origin",
                 superseded="true", parent_key="psgc:1900000000", note="No current PSGC code")
        continue
    if n == "COTABATO CITY":
        add_area(ENC, "label", n, p.strip(), "psgc:1908703000", "1908703000", "city", "patient_origin",
                 note="A city entered in the province field")
        continue
    target, note = ENC_PROV_MANUAL.get(n, (n, ""))
    code = PROV.get(target)
    if code is None:
        stop(f"{ENC}: province label not resolved: {p!r}")
    prov_code[n] = code
    add_area(ENC, "label", n, p.strip(), f"psgc:{code}", code, "province", "patient_origin", note=note)


def city_clean(n):
    n = re.sub(r"^MUNICIPALITY OF ", "", n)
    n = re.sub(r" CAPITAL$", "", n)
    return city_swap(n)


unresolved_cities = 0
seen_pairs = set()
for r in sorted(enc, key=lambda x: (x.Province or "", x.City or "")):
    if not (r.Province and r.City and r.City.strip()):
        continue
    pn, cn = norm(r.Province), norm(r.City)
    if (pn, cn) in seen_pairs:          # same label printed with different case or spacing
        continue
    seen_pairs.add((pn, cn))
    pcode = prov_code.get(pn)
    # strip a bracketed old name: "ASUNCION (SAUG)" -> "ASUNCION"
    base = city_clean(norm(re.sub(r"\(.*?\)", " ", r.City)))
    code = None
    if pcode:
        for cand in (base, base + " CITY", re.sub(r" CITY$", "", base)):
            code = MUNI.get((pcode[:5], cand))
            if code:
                break
    # An HUC has its own province-level code. Only a label that says it is a city may use it,
    # so a province name typed in the city field (DAVAO DE ORO) stays unresolved.
    if code is None and base.endswith(" CITY") and PROV.get(base):
        code = PROV[base]
    if code is None:
        unresolved_cities += 1
        add_area(ENC, "label", cn, r.City.strip(), "", "", "city_municipality", "patient_origin",
                 parent_label=pn, parent_key="", note="unresolved: review the label")
    else:
        add_area(ENC, "label", cn, r.City.strip(), f"psgc:{code}", code, "city_municipality", "patient_origin",
                 parent_label=pn)

# ----------------------------------------------------------------------------------
# 6b. Area map: PhilHealth claims by hospital (the HOSPITAL's province + municipality labels)
#     PhilHealth prints no PSGC code. Each (province, municipality) label pair is resolved by
#     the rules below, in this order; the first rule that gives exactly one place wins.
#     A pair that matches no rule, or more than one place, STOPS the script.
#       1 manila_district     NCR label "<district>, MANILA" -> City of Manila
#       2 in_province:<form>  a city / municipality of the province whose name equals one form of
#                             the label: as printed, STA/STO/GEN/PRES expanded, the part outside or
#                             inside brackets (old names), the word CITY added or removed, spaces removed
#       3 city_in_region      the same forms, against the HUCs / ICCs of the province's region
#                             (CEBU / CEBU CITY: an HUC has its own code, outside the province)
#       4 in_province:initials   GEN M ALVAREZ = General Mariano Alvarez
#       5 in_province:spelling   one name in the province within edit distance 2, closer than any other
#                                (labels of 5+ letters): OZAMIS CITY -> City of Ozamiz
#       6 city_outside_listed_province   exactly one CITY of that name in the country
#                                (COTABATO / COTABATO CITY -> City of Cotabato, BARMM)
#       7 CLAIMS_AREA_MANUAL     reviewed decisions, by target NAME (not code) so a new PSGC snapshot
#                                still resolves them; the geography check in section 10 applies
#     Rows from rules 4 to 7 carry the rule and evidence in review_note: review them in the diff.
# ----------------------------------------------------------------------------------
CLAIMS = "philhealth_foi_claims_hospital"
CLAIMS_TABLE = "diseases_philhealth_claims_hospital_bronze"
CLAIMS_PROV_ALIAS = {"NORTH COTABATO": "COTABATO", "WESTERN SAMAR": "SAMAR", "COMPOSTELA VALLEY": "DAVAO DE ORO"}
ABBREV = {"STA": "SANTA", "STO": "SANTO", "GEN": "GENERAL", "PRES": "PRESIDENT"}
# (province label, municipality label), normalised -> (PSGC names to look for in the province, note)
CLAIMS_AREA_MANUAL = {
    ("BUKIDNON", "MUSUAN"): (["MARAMAG"],
        "Musuan is the Central Mindanao University area of Maramag; not a PSGC name. "
        "Facility: Central Mindanao University Hospital"),
    ("CAVITE", "MENDEZ NUNEZ"): (["MENDEZ"], "Mendez (Mendez-Nunez), Cavite; PSGC prints 'Mendez'"),
    ("DAVAO DEL NORTE", "SAN ISIDRO"): (["SAWATA", "SAN ISIDRO"],
        "San Isidro, Davao del Norte, renamed Sawata; the snapshot may hold either name"),
    ("PALAWAN", "RIZAL MARCOS"): (["DR JOSE P RIZAL", "RIZAL"],
        "Rizal (formerly Marcos), Palawan, renamed Dr. Jose P. Rizal; the snapshot may hold either name"),
}


def expand_abbrev(n):
    return " ".join(ABBREV.get(t, t) for t in n.split(" "))


def lgu_forms(name):
    """Lookup forms of a geography city / municipality name."""
    n = expand_abbrev(norm((name or "").replace("Ã±", "ñ")))
    forms = {n}
    m = re.match(r"^(?:ISLAND GARDEN |SCIENCE )?CITY OF (.+)$", n)
    if m:
        forms |= {f"{m.group(1)} CITY", m.group(1)}
    m = re.match(r"^(.+) CITY$", n)
    if m:
        forms.add(m.group(1))
    return forms | {f.replace(" ", "") for f in forms}


def label_forms(label):
    """(rule, form) pairs of a published municipality label, strictest first."""
    n = norm(label)
    out = [("name", n)]
    raw = (label or "").upper()
    if "(" in raw:
        out.append(("bracket_outside", norm(re.sub(r"\(.*?\)", " ", raw))))
        out += [("bracket_inside", norm(x)) for x in re.findall(r"\((.*?)\)", raw) if norm(x)]
    for rule, f in list(out):
        if expand_abbrev(f) != f:
            out.append(("abbreviation_expanded" if rule == "name" else rule + "+abbreviation_expanded", expand_abbrev(f)))
    base = [f for _, f in out]
    for f in base:
        for g in (f + " CITY", re.sub(r" CITY$", "", f), re.sub(r"^CITY OF ", "", f)):
            if g != f:
                out.append(("city_word", g))
    out += [("spaces_removed", f.replace(" ", "")) for f in base if " " in f]
    return out


def edit_distance(a, b, cap=3):
    if abs(len(a) - len(b)) > cap:
        return cap + 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def initials_match(label, name):
    a, b = label.split(" "), name.split(" ")
    if len(a) != len(b) or a == b or not any(len(t) == 1 for t in a):
        return False
    return all(x == y or (len(x) == 1 and y.startswith(x)) for x, y in zip(a, b))


LGU = [(r.code, lgu_forms(r.name)) for r in geo_rows if r.level in ("City", "Mun")]
GEO_NAME_OF = {r.code: r.name.strip() for r in geo_rows}


def claims_province_prefix(label):
    n = CLAIMS_PROV_ALIAS.get(norm(label), norm(label))
    if n == "METRO MANILA":
        return "13", True
    code = PROV.get(n)
    if code is None or GEO_LEVEL_OF.get(code) != "Prov":
        stop(f"{CLAIMS}: province label not resolved: {label!r}")
    return code[:5], False


def claims_resolve(prov_label, muni_label):
    """-> (code, rule, evidence)"""
    prefix, is_ncr = claims_province_prefix(prov_label)
    n = norm(muni_label)
    forms = label_forms(muni_label)
    in_prov = [(c, fs) for c, fs in LGU if c.startswith(prefix)]
    in_region = [(c, fs) for c, fs in LGU if c.startswith(prefix[:2]) and not c.startswith(prefix)
                 and GEO_LEVEL_OF[c] == "City"]
    if is_ncr and n.endswith(" MANILA"):
        manila = [c for c, fs in in_prov if "MANILA" in fs]
        if len(manila) == 1:
            return manila[0], "manila_district", f"district {n[:-7]} of the City of Manila"
    for scope, pool in (("in_province", in_prov), ("city_in_region", in_region)):
        for rule, f in forms:
            hits = sorted({c for c, fs in pool if f in fs})
            if len(hits) > 1:
                stop(f"{CLAIMS}: {prov_label!r} / {muni_label!r}: form {f!r} matches {hits}")
            if hits:
                return hits[0], f"{scope}:{rule}", "" if rule == "name" else f"{f} = {GEO_NAME_OF[hits[0]]}"
    hits = sorted({c for c, fs in in_prov for _, f in forms for g in fs if initials_match(f, g)})
    if len(hits) == 1:
        return hits[0], "in_province:initials", f"initials of {GEO_NAME_OF[hits[0]]}"
    if len(n) >= 5:
        ranked = sorted((min(edit_distance(f, g) for _, f in forms[:2] for g in fs), c) for c, fs in in_prov)
        if ranked and ranked[0][0] <= 2 and (len(ranked) == 1 or ranked[1][0] > ranked[0][0]):
            return ranked[0][1], "in_province:spelling", f"edit distance {ranked[0][0]} to {GEO_NAME_OF[ranked[0][1]]}"
    for rule, f in forms:
        if f.endswith(" CITY") or rule == "city_word":
            hits = sorted({c for c, fs in LGU if f in fs and GEO_LEVEL_OF[c] == "City"})
            if len(hits) == 1:
                return hits[0], "city_outside_listed_province", f"{f} = {GEO_NAME_OF[hits[0]]} (region {hits[0][:2]})"
    manual = CLAIMS_AREA_MANUAL.get((norm(prov_label), n))
    if manual:
        names, note = manual
        hits = sorted({c for c, fs in in_prov for t in names if t in fs})
        if len(hits) == 1:
            return hits[0], "manual", f"{note}; resolved to {GEO_NAME_OF[hits[0]]}"
        stop(f"{CLAIMS}: manual rule for {prov_label!r} / {muni_label!r} found {hits} for {names}")
    stop(f"{CLAIMS}: municipality not resolved: {prov_label!r} / {muni_label!r}. "
         "Check the place, then add a rule or a CLAIMS_AREA_MANUAL row")


claims_rule_count = {}
if spark.catalog.tableExists(f"{BRONZE}.{CLAIMS_TABLE}"):
    claims_pairs = (tbl(CLAIMS_TABLE).where(f"_source_key = '{CLAIMS}'")
                    .select("HF_Province", "HF_Municipality").distinct().collect())
    seen_pairs = set()
    for r in sorted(claims_pairs, key=lambda x: (x.HF_Province or "", x.HF_Municipality or "")):
        pn, mn = norm(r.HF_Province), norm(r.HF_Municipality)
        if not pn or not mn:
            stop(f"{CLAIMS}: blank province or municipality label: {r.HF_Province!r} / {r.HF_Municipality!r}")
        if (pn, mn) in seen_pairs:              # same label printed with other spacing or punctuation
            continue
        seen_pairs.add((pn, mn))
        code, rule, evidence = claims_resolve(r.HF_Province, r.HF_Municipality)
        claims_rule_count[rule.split(":")[0]] = claims_rule_count.get(rule.split(":")[0], 0) + 1
        level = "city" if GEO_LEVEL_OF[code] == "City" else "municipality"
        flagged = rule.split(":")[-1] in ("initials", "spelling") or rule in ("city_outside_listed_province", "manual")
        note = f"{rule}" + (f": {evidence}" if evidence else "") + ("; REVIEW" if flagged else "")
        add_area(CLAIMS, "label", mn, re.sub(r"\s+", " ", r.HF_Municipality.strip()), f"psgc:{code}", code, level,
                 "facility_location", parent_label=pn, note=note if rule != "in_province:name" else "")
else:
    print(f"NOTE: {BRONZE}.{CLAIMS_TABLE} not found; no claims area rows written")

# ----------------------------------------------------------------------------------
# 7. Cause map
# ----------------------------------------------------------------------------------
# A digit, one to three separator characters (any dash, spaces), three digits, optional letter.
# Same pattern as PSA_CODE_PATTERN in diseases_silver.py.
CODE_RE = re.compile(r"^[^0-9A-Za-z]*([0-9])[^0-9A-Za-z]{1,3}([0-9]{3}[a-d]?)")
CAUSE_COLS = ["_source_key", "match_type", "match_value", "row_class", "reason",
              "disease_key", "source_cause_code", "review_note"]
cause_rows = []


def add_cause(source_key, match_type, match_value, row_class, disease_key="", code="", reason="", note=""):
    cause_rows.append({"_source_key": source_key, "match_type": match_type, "match_value": match_value,
                       "row_class": row_class, "reason": reason, "disease_key": disease_key,
                       "source_cause_code": code, "review_note": note})


def uncoded_key(n):
    """Normalised PSA label without a tabulation code -> (row_class, disease_key or reason).
    Notes are tested first: a note can quote a cause name ("... COVID-19 virus not identified refers to ...")."""
    if n.startswith("SOURCE"):
        return "non_data", "source_line"
    for p in ("NOTES", "CAUSES OF DEATH ARE CODED", "CAUSE OF DEATH IS CODED", "MORTALITY GROUPING",
              "FIGURES ARE RESULTS", "REGARDING COVID 19 DEATHS"):
        if n.startswith(p):
            return "non_data", "note"
    if n == "TRANSPORT ACCIDENTS":
        return "non_data", "sub_header"
    if n == "TOTAL":
        return "data", "all_causes"
    if "VAPING" in n:
        return "data", "psa_vaping_related_disorder"
    if "VIRUS NOT IDENTIFIED" in n:
        return "data", "psa_covid19_virus_not_identified"
    if "VIRUS IDENTIFIED" in n:
        return "data", "psa_covid19_virus_identified"
    if n.startswith("POST COVID"):
        return "data", "psa_post_covid19_condition"
    if n.startswith("MULTISYSTEM INFLAMMATORY"):
        return "data", "psa_mis_covid19"
    if "VACCINES CAUSING ADVERSE" in n:
        return "data", "psa_covid19_vaccine_adverse_effects"
    if n.startswith("COVID 19") or n.startswith("CORONAVIRUS DISEASE 2019"):
        return "data", "psa_covid19"
    return None, None


PSA = [("psa_deaths_national_monthly", "diseases_psa_deaths_national_monthly_bronze"),
       ("psa_deaths_region_annual", "diseases_psa_deaths_region_annual_bronze"),
       ("psa_deaths_national_annual", "diseases_psa_deaths_national_annual_bronze")]
psa_names = {}      # code -> a printed label (latest file wins), for the directory
psa_icd = {}        # code -> ICD-10 range where a file prints it
for source_key, table in PSA:
    labels = [r[0] for r in tbl(table).select("cause_of_death").distinct().collect()]
    codes, uncoded = set(), {}
    for lab in labels:
        m = CODE_RE.match(lab or "")
        if m:
            code = f"{m.group(1)}-{m.group(2)}"
            codes.add(code)
            rest = (lab or "")[m.end():].strip()
            icd = re.search(r"\s([A-Z]\d{2}(?:\.\d)?(?:\s*[-–,]\s*[A-Z]?\d{2}(?:\.\d)?)*)$", rest)
            if icd:
                psa_icd.setdefault(code, icd.group(1).replace("–", "-"))
                rest = rest[:icd.start()].strip()
            if code not in psa_names or len(rest) < len(psa_names[code]):
                psa_names[code] = re.sub(r"\s+", " ", rest)
        else:
            uncoded[norm(lab)] = lab
    for code in sorted(codes):
        add_cause(source_key, "psa_code", code, "data", "psa_" + code.replace("-", "_"), code)
    for n, lab in sorted(uncoded.items()):
        row_class, val = uncoded_key(n)
        if row_class is None:
            stop(f"{source_key}: cause label matches no rule: {lab!r}")
        if row_class == "data":
            add_cause(source_key, "label", n, "data", val)
        else:
            # notes are long sentences: match on the first 40 characters of the normalised label
            add_cause(source_key, "label_prefix", n[:40].strip(), "non_data", reason=val)

ihme_causes = tbl("diseases_ihme_gbd_bronze").select("cause_id", "cause_name", "_source_file").distinct().collect()
for cid, name in sorted({(r.cause_id, r.cause_name) for r in ihme_causes}, key=lambda x: int(x[0])):
    add_cause("ihme_gbd", "ihme_cause_id", cid, "data", f"ihme_{cid}", cid)

for sk in ("doh_foi_dengue", "upnoah", "hdx_dengue"):
    add_cause(sk, "fixed", "*", "data", "dengue", note="Every data row of this source is dengue")
add_cause("doh_fhsis", "fixed", "cases_total", "data", "tb_all_forms", note="FHSIS TB: all forms, column cases_total")
add_cause("doh_fhsis", "fixed", "dr_cases_total", "data", "tb_drug_resistant",
          note="FHSIS TB: drug-resistant, column dr_cases_total")

# PhilHealth claims: illness = case-rate package name. One disease_key per package (the
# directory groups them with the other sources through related_condition_group).
# A blank illness is not in the map: silver quarantines those rows (illness_missing).
CLAIMS_PACKAGES = {
    "DENGUE FEVER": ("phic_dengue_fever", "Dengue fever (PhilHealth case-rate package)", "dengue"),
    "DENGUE SEVERE": ("phic_dengue_severe", "Severe dengue (PhilHealth case-rate package)", "dengue"),
    "PNEUMONIA MODERATE RISK": ("phic_pneumonia_moderate_risk", "Pneumonia, moderate risk (PhilHealth case-rate package)", "pneumonia_lri"),
    "PNEUMONIA HIGH RISK": ("phic_pneumonia_high_risk", "Pneumonia, high risk (PhilHealth case-rate package)", "pneumonia_lri"),
    "HYPERTENSIVE EMERGENCYURGENCY": ("phic_hypertensive_emergency_urgency",
                                      "Hypertensive emergency / urgency (PhilHealth case-rate package)", "hypertensive_disease"),
    "STROKE INFARCTION": ("phic_stroke_infarction", "Stroke, infarction (PhilHealth case-rate package)", "stroke"),
    "STROKE HEMORRHAGIC": ("phic_stroke_hemorrhagic", "Stroke, haemorrhagic (PhilHealth case-rate package)", "stroke"),
    "OTHER CEREBROVASCULAR DISEASES": ("phic_other_cerebrovascular", "Other cerebrovascular diseases (PhilHealth case-rate package)", "stroke"),
    "SEQUELAE OF CEREBROVASCULAR DISEASES": ("phic_sequelae_cerebrovascular",
                                             "Sequelae of cerebrovascular diseases (PhilHealth case-rate package)", "stroke"),
    "ISCHEMIC HEART DISEASE WITH MYOCARDIAL INFARCTION": ("phic_ihd_with_mi",
        "Ischaemic heart disease with myocardial infarction (PhilHealth case-rate package)", "ischaemic_heart_disease"),
    "ISCHEMIC HEART DISEASE WITHOUT MYOCARDIAL INFARCTION": ("phic_ihd_without_mi",
        "Ischaemic heart disease without myocardial infarction (PhilHealth case-rate package)", "ischaemic_heart_disease"),
    "CHRONIC HEART DISEASES WITHOUT COMPLICATIONS": ("phic_chronic_heart_disease_uncomplicated",
        "Chronic heart diseases without complications (PhilHealth case-rate package)", ""),
    "ENCEPHALOPATHY": ("phic_encephalopathy", "Encephalopathy (PhilHealth case-rate package)", ""),
    "PRIMARY CARE": ("phic_primary_care", "Primary care (PhilHealth benefit package, not a disease)", ""),
}
if spark.catalog.tableExists(f"{BRONZE}.{CLAIMS_TABLE}"):
    labels = [r[0] for r in tbl(CLAIMS_TABLE).where(f"_source_key = '{CLAIMS}'")
              .select("Illness_Description").distinct().collect()]
    for lab in sorted({norm(x) for x in labels if x and x.strip()}):
        if lab not in CLAIMS_PACKAGES:
            stop(f"{CLAIMS}: illness package matches no rule: {lab!r}. Add it to CLAIMS_PACKAGES")
        add_cause(CLAIMS, "label", lab, "data", CLAIMS_PACKAGES[lab][0],
                  note="HYPERTENSIVE EMERGENCYURGENCY is spelled that way in the source" if "EMERGENCYURGENCY" in lab else "")

# ----------------------------------------------------------------------------------
# 8. Directory
# ----------------------------------------------------------------------------------
# WHO Mortality Tabulation List 1 chapters as PSA prints them: chapter code -> last child code.
PSA_CHAPTERS = {"1-001": "1-025", "1-026": "1-047", "1-048": "1-050", "1-051": "1-054", "1-055": "1-057",
                "1-058": "1-061", "1-062": None, "1-063": None, "1-064": "1-071", "1-072": "1-077",
                "1-078": "1-081", "1-082": None, "1-083": None, "1-084": "1-086", "1-087": "1-091",
                "1-092": None, "1-093": None, "1-094": None, "1-095": "1-103"}
RELATED = {
    "dengue": ["dengue", "ihme_357", "psa_1_017"],
    "tuberculosis": ["tb_all_forms", "tb_drug_resistant", "psa_1_005", "psa_1_006", "ihme_297"],
    "pneumonia_lri": ["psa_1_074", "psa_1_075", "ihme_322"],
    "neoplasms": ["psa_1_026", "ihme_410"],
    "diabetes": ["psa_1_052", "ihme_587"],
    "ischaemic_heart_disease": ["psa_1_067", "ihme_493"],
    "stroke": ["psa_1_069", "ihme_494"],
    "hypertensive_disease": ["psa_1_066", "ihme_498"],
    "chronic_respiratory": ["psa_1_076", "ihme_508"],
    "rheumatic_heart_disease": ["psa_1_065", "ihme_492"],
    "covid19": ["psa_covid19", "ihme_1048"],
    # Kidney case study (K1). No PSA code is mapped: chronic kidney disease (N18) sits inside
    # the remainder row 1-086, which also holds other genitourinary causes.
    "chronic_kidney_disease": ["ihme_589"],
}
for _pkg_key, _pkg_name, _pkg_group in CLAIMS_PACKAGES.values():     # PhilHealth packages (section 7)
    if _pkg_group:
        RELATED[_pkg_group].append(_pkg_key)
FOCUS_GROUPS = {"dengue", "tuberculosis", "pneumonia_lri", "neoplasms", "diabetes",
                "ischaemic_heart_disease", "stroke", "hypertensive_disease", "chronic_kidney_disease"}
group_of = {k: g for g, keys in RELATED.items() for k in keys}

DIR_COLS = ["disease_key", "disease_name", "classification", "psa_cause_code", "icd10_range", "ihme_cause_id",
            "cause_level", "parent_disease_key", "has_children_in_source", "related_condition_group",
            "is_focus_disease", "review_note"]
dir_rows = {}


def add_dir(key, name, classification, psa_code="", icd="", ihme_id="", level="", parent="", note=""):
    g = group_of.get(key, "")
    dir_rows[key] = {"disease_key": key, "disease_name": name, "classification": classification,
                     "psa_cause_code": psa_code, "icd10_range": icd, "ihme_cause_id": ihme_id,
                     "cause_level": level, "parent_disease_key": parent, "has_children_in_source": "false",
                     "related_condition_group": g,
                     "is_focus_disease": "true" if (g in FOCUS_GROUPS or key == "all_causes") else "false",
                     "review_note": note}


add_dir("all_causes", "All causes", "psa_tabulation_list", level="0")
chapter_of = {}
for ch, last in PSA_CHAPTERS.items():
    if last:
        for i in range(int(ch[2:]) + 1, int(last[2:]) + 1):
            chapter_of[f"1-{i:03d}"] = ch
for code in sorted(psa_names):
    key = "psa_" + code.replace("-", "_")
    if code in PSA_CHAPTERS or code == "1-901":
        level, parent = "1", "all_causes"
    elif re.match(r"^1-096[a-d]$", code):
        level, parent = "3", "psa_1_096"
    elif code in chapter_of:
        level, parent = "2", "psa_" + chapter_of[code].replace("-", "_")
    else:
        stop(f"PSA code outside the known chapter ranges: {code}")
    add_dir(key, psa_names[code], "psa_tabulation_list", psa_code=code, icd=psa_icd.get(code, ""),
            level=level, parent=parent)
SPECIAL = [("psa_vaping_related_disorder", "Vaping-related disorder", "U07.0", "1", "all_causes"),
           ("psa_covid19", "COVID-19", "U07.1-U07.2", "1", "all_causes"),
           ("psa_covid19_virus_identified", "COVID-19, virus identified", "U07.1", "2", "psa_covid19"),
           ("psa_covid19_virus_not_identified", "COVID-19, virus not identified", "U07.2", "2", "psa_covid19"),
           ("psa_post_covid19_condition", "Post COVID-19 condition", "U09.9", "1", "all_causes"),
           ("psa_mis_covid19", "Multisystem inflammatory syndrome associated with COVID-19", "U10.9", "1", "all_causes"),
           ("psa_covid19_vaccine_adverse_effects", "COVID-19 vaccines causing adverse effects in therapeutic use",
            "U12.9", "1", "all_causes")]
for key, name, icd, level, parent in SPECIAL:
    add_dir(key, name, "psa_tabulation_list", icd=icd, level=level, parent=parent,
            note="No tabulation code in the PSA tables")

neoplasm_file_ids = {r.cause_id for r in ihme_causes if "neoplasms" in r._source_file}
for cid, name in sorted({(r.cause_id, r.cause_name) for r in ihme_causes}, key=lambda x: int(x[0])):
    parent = "ihme_410" if (cid in neoplasm_file_ids and cid != "410") else ""
    add_dir(f"ihme_{cid}", name, "ihme_gbd", ihme_id=cid, parent=parent,
            note="" if parent or cid == "410" else "GBD level and parent are not in the export")
add_dir("dengue", "Dengue (reported surveillance cases and deaths)", "programme")
add_dir("tb_all_forms", "Tuberculosis, all forms (programme notifications)", "programme")
add_dir("tb_drug_resistant", "Tuberculosis, drug-resistant (programme notifications)", "programme",
        parent="tb_all_forms", level="2")
for _pkg_label, (_pkg_key, _pkg_name, _pkg_group) in sorted(CLAIMS_PACKAGES.items()):
    add_dir(_pkg_key, _pkg_name, "phic_case_rate_package",
            note=f"PhilHealth package '{_pkg_label}'. No ICD-10 codes in the claims file"
                 + ("" if _pkg_group else "; no related_condition_group"))
for row in dir_rows.values():
    p = row["parent_disease_key"]
    if p and p in dir_rows:
        dir_rows[p]["has_children_in_source"] = "true"

# every disease_key in the cause map must be in the directory
missing = {c["disease_key"] for c in cause_rows if c["disease_key"]} - set(dir_rows)
if missing:
    stop(f"cause map keys missing from the directory: {sorted(missing)}")

# ----------------------------------------------------------------------------------
# 9. Aggregation set: psa_death_composition_v1 (decision D10 still open)
# ----------------------------------------------------------------------------------
AGG_COLS = ["aggregation_set", "disease_key", "category", "year_from", "year_to", "reconciles_to", "review_note"]
CATEGORY = {"1-001": "communicable", "1-087": "maternal_and_perinatal", "1-092": "maternal_and_perinatal",
            "1-095": "injury", "1-094": "ill_defined", "1-072": "respiratory_acute_and_chronic"}
agg_rows = []
for ch in PSA_CHAPTERS:
    cat = CATEGORY.get(ch, "noncommunicable")
    note = "D10: the chapter holds pneumonia and influenza as well as chronic respiratory disease" if ch == "1-072" else ""
    agg_rows.append({"aggregation_set": "psa_death_composition_v1", "disease_key": "psa_" + ch.replace("-", "_"),
                     "category": cat, "year_from": "2015", "year_to": "", "reconciles_to": "all_causes",
                     "review_note": note})
for key, yf in [("psa_1_901", "2015"), ("psa_vaping_related_disorder", "2015"), ("psa_covid19", "2015"),
                ("psa_post_covid19_condition", "2021"), ("psa_mis_covid19", "2021"),
                ("psa_covid19_vaccine_adverse_effects", "2021")]:
    agg_rows.append({"aggregation_set": "psa_death_composition_v1", "disease_key": key,
                     "category": "covid_and_special_codes", "year_from": yf, "year_to": "",
                     "reconciles_to": "all_causes",
                     "review_note": "D10: COVID shown as its own category" if key == "psa_covid19" else ""})

# ----------------------------------------------------------------------------------
# 10. Checks, then write
# ----------------------------------------------------------------------------------
seen = set()
for a in area_rows:
    k = (a["_source_key"], a["match_type"], a["match_value"], a["parent_label_norm"], a["year_from"])
    if k in seen:
        stop(f"duplicate area map key: {k}")
    seen.add(k)
seen = set()
for c in cause_rows:
    k = (c["_source_key"], c["match_type"], c["match_value"])
    if k in seen:
        stop(f"duplicate cause map key: {k}")
    seen.add(k)

# Every PSGC code in the area map must exist in geography silver at the level the map states.
# This also covers codes typed in the manual rules above.
GEO_LEVELS = {"region": {"Reg"}, "province": {"Prov"}, "city": {"City"}, "municipality": {"Mun"},
              "city_municipality": {"City", "Mun"}}
problems = []
for a in area_rows:
    code = a["psgc_code"]
    if not code:
        continue
    if code not in GEO_LEVEL_OF:
        problems.append((a["_source_key"], a["area_label_source"], code, a["geo_level"], "not in geography"))
    elif GEO_LEVEL_OF[code] not in GEO_LEVELS.get(a["geo_level"], set()):
        problems.append((a["_source_key"], a["area_label_source"], code, a["geo_level"],
                         f"geography level is {GEO_LEVEL_OF[code]}"))
if problems:
    for p in problems:
        print("  geography check:", p)
    stop(f"{len(problems)} area map row(s) failed the geography check. Fix the rule that produced them")
print(f"geography check passed against {GEO_TABLE} ({GEO_SNAPSHOTS[0][:12]}...)")

OUT_FILES = ["diseases_area_map.csv", "diseases_cause_map.csv", "diseases_directory.csv",
             "diseases_cause_aggregation.csv"]
existing = [n for n in OUT_FILES if os.path.exists(os.path.join(ARGS.out_dir, n))]
if existing and str(ARGS.overwrite).lower() != "true":
    stop(f"these files already exist in {ARGS.out_dir}: {existing}. "
         "Manual edits would be lost. Pass --overwrite true to replace them.")
os.makedirs(ARGS.out_dir, exist_ok=True)


def write(name, cols, rows):
    path = os.path.join(ARGS.out_dir, name)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, quoting=csv.QUOTE_MINIMAL)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"wrote {len(rows):>5} rows  {path}")


write("diseases_area_map.csv", AREA_COLS, area_rows)
write("diseases_cause_map.csv", CAUSE_COLS, cause_rows)
write("diseases_directory.csv", DIR_COLS, list(dir_rows.values()))
write("diseases_cause_aggregation.csv", AGG_COLS, agg_rows)

by_src = {}
for a in area_rows:
    by_src[a["_source_key"]] = by_src.get(a["_source_key"], 0) + 1
print("area map rows by source:", by_src)
print("hospital encounter city labels left unresolved (blank area_key):", unresolved_cities)
print("PhilHealth claims label pairs by rule:", claims_rule_count,
      "(rows from initials, spelling, city_outside_listed_province and manual say REVIEW in review_note)")
print("Review the CSVs, then commit them. Rows with a review_note need a person to confirm.")