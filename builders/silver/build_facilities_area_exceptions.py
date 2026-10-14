# =============================================================================
# Drafting tool for the facilities Silver reference files.
# This is NOT a Silver pipeline step.
#
# Generates reproducible and auditable facilities area reference CSVs from
# Bronze data, geography Silver and reviewed rules.
# No PSGC code is typed directly into the generated exceptions output.
# Each row records:
#   - the matching rule
#   - supporting evidence, when available
#   - the proposed PSGC code
#   - geography validation
#   - review_status
#   - the geography snapshot used
#
# The Silver job does not run this script.
# facilities_silver_00_reference.sql loads the generated CSVs.
# Silver build steps 01-04 record them in quality.build_inputs.
#
# Outputs:
#   facilities_area_exceptions.csv
#     Generated area exceptions with reviewer decisions applied.
#   facilities_area_decisions.csv
#     Snapshot of the DECISIONS table defined in this file.
#   facilities_id_map_override.csv
#     Snapshot of ID_MAP_OVERRIDES defined in this file.
#     Writes only the header while no overrides exist.
# Decisions and ID overrides are code changes.
# Review them in the PR like any other matching rule.
#
# Run order:
#   Bronze
#   -> geography_silver
#   -> admin_boundaries_silver
#   -> facilities_silver_00a_area_boundary.sql
#   -> this script
#   -> facilities_silver_00_reference.sql
#   -> facilities_silver_01 ... 04
# Databricks:
#   %pip install shapely
#   %restart_python
# Then run this file in the next cell.
# CLI:
#   python build_facilities_area_exceptions.py \
#       --catalog public_health \
#       --geography_table silver.geography_silver \
#       --out_dir <folder>
# To override a path in a notebook:
#   import sys
#   sys.argv = ["x", "--out_dir", "/Volumes/.../reference/facilities"]
# Review the printed report and CSV diff before committing.
#
#
# Geography:
#   silver.geography_silver is the only source of PSGC codes and area names.
#   It follows the same geography rules as build_diseases_reference_maps.py.
#   Exactly one geography snapshot (content_checksum) is required.
#   Every generated row stores geography_checksum.
#   facilities_silver_00_reference.sql stops if geography has changed since
#   the reference files were generated.
#   The script also repairs the known damaged n-tilde in area_name before matching.
#
# OSM boundary evidence:
#   OSM evidence uses public_health.silver.facilities_area_boundary.
#   The boundary table must come from the same geography snapshot.
#   Stop if the boundary table is missing or uses another snapshot.
#   Use --skip_osm_evidence true only when you intentionally want to continue
#   without OSM spatial evidence.
#
#
# Reviewer decisions:
#   DECISIONS is defined in this file.
#   accept
#     Keep the generated proposal only while the generator still proposes
#     the same PSGC code.
#
#     If the proposal changes, mark the decision STALE and return the row
#     to needs_review.
#   set
#     Replace the generated proposal with the reviewer-provided PSGC code.
#   reject
#     Keep the label unresolved and quarantined.
#   Reviewed codes still pass the same geography checks as generated codes.
#   Stop the script if a reviewed code fails validation.
#   Report decisions for labels that no longer appear in the source data.
#   These decisions can be removed after review.
#
#
# 1. Build the unresolved-label inventory.
#   Mirror the same place-matching rules used by Facilities Silver:
#     fac_place_key = name + level + parent
#   If Silver already resolves a label normally, do not create an exception row.
#
#   Sources:
#     nhfr
#       City/Municipality PSGC codes missing from geography Silver.
#     hfsrb
#       Province labels and city/municipality labels under their province.
#       Used by 01_registry.
#     fhsis
#       Area labels under their region row, by file year.
#       Used by 02_metric.
#     bor
#       Province/District labels and city labels under their province.
#       Used by 03_bed_occupancy.
#       Current source key: doh_foi_hospital_beds.
#     osm
#       addr:city labels from points without coordinates.
#       Used by 04_osm_point.
#       Only the latest Healthsites snapshot is inventoried.
#
#
# 2. Generate one candidate.
#   Apply rules in order.
#   The first rule that returns exactly one area becomes the candidate.
#   Store the rule name in rule.
#
#   Structural rules:
#     code_prefix_same_name
#       Replace an invalid NHFR code prefix only when the municipality name matches.
#     label_part
#       Match one part of labels such as "A (B)" or "A, B".
#       Example: SAMAR (WESTERN SAMAR)
#     not_a_province
#       Handle "<city> (Not a Province)" in a province field.
#     ncr_district
#       Map NCR district labels to named district keys.
#       Example: "NCR, Second District" -> ncr-district:2
#     word_order
#       Match the same words in another order.
#       Example: Mindoro Occidental
#     directional_prefix
#       Drop a leading direction such as North, Northern or Western.
#       Example: North Cotabato
#     province_prefix
#       Drop a leading "Province of".
#       Example: Province of Dinagat
#     abbreviation
#       Expand known abbreviations such as Mt. and Pres.
#       Example: Mt. Province
#     acronym
#       Match initials to one area name within the parent region.
#       Example: SGA
#     split_province
#       If a historical label is the shared prefix of multiple current provinces,
#       assign a named historical key instead of a current PSGC code.
#       Example: Maguindanao -> hist:<name>
#
#   Fuzzy/evidence-based rules:
#     contained_name
#       One name contains the other and the match is unique within the parent.
#       Example: Ala Esperanza
#     spelling
#       Similarity is at least 0.85 with one clear match in the parent.
#       Example: Ilocos Note
#     duplicate_in_file
#       FHSIS only.
#       If two rows in one file resolve to the same area, try to assign the
#       duplicate to an area missing from that region in the same file.
#     evidence_only
#       No text rule produced a candidate, but independent evidence identifies one area.
#     address_other_province
#       HFSRB only.
#       Use when the label does not exist in the stated province, but the address
#       names the same place in another province within the same region.
#       The geography check then uses the province named in the address.
#       The region must still match.
#
#
# 3. Collect independent evidence.
#   Evidence must come from information other than the unresolved label itself.
#   Store the result in evidence.
#   hfsrb
#     Use NHFR facilities with similar names when their NHFR codes identify one
#     municipality.
#     Also inspect ADDRESS.
#     It can support a municipality when the address names:
#       - that municipality, or
#       - a barangay belonging to exactly one municipality in the province.
#   fhsis
#     Compare the row's barangay count with geography Silver.
#     Accept the evidence when it is within 7% of exactly one area in the region.
#     Province totals may include or exclude separately listed cities.
#   osm
#     Use points with the same addr:city and valid coordinates.
#     Locate them by point-in-polygon against facilities_area_boundary.
#   nhfr
#     Use the municipality name printed in NHFR when it matches geography Silver.
#   bor
#     No independent evidence is available because the records are anonymous.
#
#
# 4. Validate the candidate against geography.
#   geography_check confirms that the proposed code:
#     - exists in geography Silver
#     - has an allowed geography level
#     - belongs to the expected parent province or region
#   Region checks may also allow valid successor areas.
#   If a usable row fails geography_check, change it to needs_review.
#
#
# 5. Assign review_status.
#   Silver uses only auto, corroborated and reviewed rows.
#   corroborated
#     Candidate and evidence agree, or evidence_only identifies one area.
#   auto
#     A structural rule returns one candidate and no evidence contradicts it.
#   needs_review
#     A fuzzy rule has no supporting evidence, evidence disagrees with the candidate,
#     or no candidate can be generated.
#   reviewed
#     A reviewer accepted or replaced the proposed code in DECISIONS.
#   rejected
#     A reviewer decided that the label should remain unresolved.
#   Rows that are not usable are loaded with match_type = 'unresolvable'.
#   Their source records stay quarantined.
#   Keep proposed_psgc_code visible even when the row is unresolved.
#
#
# Requires: pyspark, pandas, shapely for OSM evidence
# If shapely is unavailable, OSM evidence is skipped with a note.
# =============================================================================

import argparse
import os, csv, difflib, re, sys, unicodedata
from collections import Counter, defaultdict

import pandas as pd
from pyspark.sql import SparkSession

OUT_COLUMNS = ["source_group", "match_type", "match_value", "parent_label_norm", "year_from", "year_to",
               "area_label_source", "psgc_code", "area_key", "named_key_level", "reason", "review_note",
               "rule", "evidence", "evidence_n", "evidence_share", "review_status", "proposed_psgc_code",
               "proposed_area_name", "geography_check", "records", "geography_checksum"]
USABLE = {"auto", "corroborated", "reviewed"}
REF_DIR = "/Volumes/workspace/default/ftw-b12-de/groups/g5_landing/reference/facilities"

# ---------------------------------------------------------------------------------------------
# Reviewer decisions on generated rows. Key = (source_group, match_type, match_value,
# parent_label_norm, year_from) of the generated row. decision: accept (keep the proposal, only while
# the generator still proposes it), set (use this code / key), reject (keep it quarantined).
# Every code is checked against geography silver like a generated row. Written to
# facilities_area_decisions.csv as a record.
# ---------------------------------------------------------------------------------------------
DECISION_COLS = ["source_group", "match_type", "match_value", "parent_label_norm", "year_from",
                 "decision", "psgc_code", "area_key", "reviewed_by", "reviewed_on", "note"]
DECISIONS = [
    # source_group, match_type, match_value, parent_label_norm, year_from, decision, psgc_code, area_key, reviewed_by, reviewed_on, note
    ("hfsrb", "area_label", "GOV GEN", "DAVAO ORIENTAL", None, "accept", "1102506000", None, "Jemma", "2026-10-09",
     "address names Governor Generoso; geography_check ok"),
    ("hfsrb", "area_label", "MONTALBAN", "RIZAL", None, "accept", "0405808000", None, "Jemma", "2026-10-09",
     "address names Rodriguez (Montalban is its former name); geography_check ok"),
    ("hfsrb", "area_label", "SEMIRARA", "ANTIQUE", None, "accept", "0600605000", None, "Jemma", "2026-10-09",
     "Brgy. Semirara is in Caluya; geography_check ok"),
    ("hfsrb", "area_label", "QUIRINO", "METRO MANILA", None, "accept", "1381300000", None, "Jemma", "2026-10-09",
     "address: Quirino 2-B, Quezon City; geography_check ok"),
    ("hfsrb", "area_label", "LIBERTAD", "SOUTH COTABATO", None, "accept", "1206313000", None, "Jemma", "2026-10-09",
     "address: Libertad, Surallah; geography_check ok"),
    ("hfsrb", "area_label", "PIGCAWAYAN", "NORTH COTABATO", None, "accept", "1204711000", None, "Jemma", "2026-10-09",
     "spelling of Pigkawayan; geography_check ok"),
    ("hfsrb", "area_label", "SAN REMEGIO", "CEBU", None, "accept", "0702243000", None, "Jemma", "2026-10-09",
     "spelling of San Remigio; geography_check ok"),
    ("hfsrb", "area_label", "SENATOR NINO AQUINO", "SULTAN KUDARAT", None, "accept", "1206512000", None, "Jemma", "2026-10-09",
     "spelling of Sen. Ninoy Aquino; geography_check ok"),
    ("hfsrb", "area_label", "SILVINO LUBOS", "NORTHERN SAMAR", None, "accept", "0804822000", None, "Jemma", "2026-10-09",
     "spelling of Silvino Lobos; geography_check ok"),
    ("hfsrb", "area_label", "PANAMAO", "SULU", None, "accept", "1906607000", None, "Jemma", "2026-10-09",
     "PSGC name is Old Panamao; geography_check ok"),
    ("fhsis", "area_label", "SAN JUAN CITY", "1300000000", "2022", "accept", "1380300000", None, "Jemma", "2026-10-09",
     "2022 row is Makati: 33 barangays, population matches Makati 2021 and 2023; geography_check ok"),
    # bed occupancy, doh_foi_hospital_beds (2026-10-14): spelling variants the generator proposes or cannot place
    ("bor", "area_label", "BALIUAG", "BULACAN", None, "accept", "0301403000", None, "Jemma", "2026-10-14",
     "spelling of Baliwag (City of Baliwag), 50 records; geography_check ok"),
    ("bor", "area_label", "OZAMIS CITY", "MISAMIS OCCIDENTAL", None, "set", "1004210000", None, "Jemma", "2026-10-14",
     "spelling of City of Ozamiz (one letter), 39 records; geography_check ok"),
    # HFSRB label that cannot be placed (open item D9)
    ("hfsrb", "area_label", "SAN JOSE", "ORIENTAL MINDORO", None, "reject", None, None, "Jemma", "2026-10-14",
     "address names no province; San Jose exists in several provinces; left unplaced"),
]

# Manual facility identity (loaded by facilities_silver_00_reference.sql as facilities_id_map_override).
# action: link_to_nhfr (nhfr_id required) or own_facility. Empty: the file is written with its header only.
ID_MAP_OVERRIDE_COLS = ["_source_key", "source_record_id", "action", "nhfr_id", "reason", "review_status",
                        "reviewed_by", "reviewed_on"]
ID_MAP_OVERRIDES = [
    # ("doh_hfsrb_hospitals", "name:hospital|<NAME>|<psgc>", "link_to_nhfr", "1234", "why", "accepted", "Jemma", "2026-10-14"),
]
STRUCTURAL = {"code_prefix_same_name", "label_part", "not_a_province", "ncr_district", "word_order",
              "directional_prefix", "province_prefix", "acronym", "split_province", "abbreviation"}
ABBREVIATIONS = {"MT": ["MOUNTAIN", "MOUNT"], "PRES": ["PRESIDENT"], "STO": ["SANTO"], "STA": ["SANTA"]}
SPELLING_MIN, SPELLING_MARGIN = 0.85, 0.05
BGY_TOLERANCE = 0.07      # FHSIS barangay counts drift a few % between years and geography


# ---------------------------------------------------------------------------------------------
# Normalisation: the same as the SQL helper functions (facilities_silver_01_registry.sql [0])
# ---------------------------------------------------------------------------------------------
def fac_norm(s):
    if s is None or (isinstance(s, float) and s != s):
        return None
    s = str(s)
    for a in ("Ã±", "Ã‘", "ñ", "?"):
        s = s.replace(a, "N")
    s = s.upper().translate(str.maketrans("ÑÁÉÍÓÚ", "NAEIOU"))
    s = re.sub(r"[^A-Z0-9]", " ", s)
    return re.sub(r" +", " ", s).strip()


def fac_place(s):
    if s is None or (isinstance(s, float) and s != s):
        return None
    t = " " + (fac_norm(re.sub(r"['’`-]", "", str(s))) or "") + " "
    t = re.sub(r" (HUC|ICC|CC|CAPITAL|NOT A PROVINCE) ", " ", t)
    for a, b in ((" STA ", " SANTA "), (" STO ", " SANTO "), (" GEN ", " GENERAL "), (" GOV ", " GOVERNOR "),
                 (" SEN ", " SENATOR ")):
        t = t.replace(a, b)
    t = re.sub(r"^ (MUNICIPALITY OF|ISLAND GARDEN CITY OF|SCIENCE CITY OF|CITY OF) ", " ", t)
    t = re.sub(r" CITY $", " ", t)
    return re.sub(r" +", " ", t).strip()


def place_key(s):
    p = fac_place(s)
    return p.replace(" ", "") if p is not None else None


def city_hint(s):
    n = fac_norm(s) or ""
    return re.search(r"(^CITY OF )|( CITY$)|( CITY )", n) is not None


def fac_lgu(code):
    return "1380600000" if code and re.fullmatch(r"13806\d{2}000", code) else code


def fac_region_psgc(s):
    n = fac_norm(s) or ""
    def has(p):
        return re.search(r"(^| )(" + p + r")( |$)", n) is not None
    if has("NCR|N C R|NATIONAL CAPITAL|METRO MANILA"): return "1300000000"
    if has("CAR|C A R|CORDILLERA"): return "1400000000"
    if has("BARMM|ARMM|BANGSAMORO|AUTONOMOUS REGION IN MUSLIM MINDANAO"): return "1900000000"
    if has("NIR|NEGROS ISLAND"): return "1800000000"
    if has("MIMAROPA|IV B|4 B|4B|IVB"): return "1700000000"
    if has("CARAGA|XIII|13"): return "1600000000"
    if has("CALABARZON|IV A|4 A|4A|IVA"): return "0400000000"
    named = {"ILOCOS": "01", "CAGAYAN VALLEY": "02", "CENTRAL LUZON": "03", "BICOL": "05", "WESTERN VISAYAS": "06",
             "CENTRAL VISAYAS": "07", "EASTERN VISAYAS": "08", "ZAMBOANGA PENINSULA": "09",
             "NORTHERN MINDANAO": "10", "DAVAO": "11", "SOCCSKSARGEN": "12"}
    for k, v in named.items():
        if re.fullmatch(k + r"( REGION)?", n):
            return v + "00000000"
    m = re.match(r"^REGION ([IVX]+|[0-9]+)( |$)", n)
    roman = {"I": "01", "1": "01", "II": "02", "2": "02", "III": "03", "3": "03", "V": "05", "5": "05",
             "VI": "06", "6": "06", "VII": "07", "7": "07", "VIII": "08", "8": "08", "IX": "09", "9": "09",
             "X": "10", "10": "10", "XI": "11", "11": "11", "XII": "12", "12": "12"}
    if m and m.group(1) in roman:
        return roman[m.group(1)] + "00000000"
    return None


GENERIC = {"HOSPITAL", "MEDICAL", "CENTER", "GENERAL", "DISTRICT", "PROVINCIAL", "MEMORIAL", "REGIONAL", "CITY",
           "OF", "THE", "AND", "DE", "DEL", "NG", "SA", "MATERNITY", "CLINIC", "INFIRMARY", "HEALTH", "CARE",
           "DOCTORS", "DR", "ST", "SANTO", "SAN", "OPC", "COMMUNITY", "MUNICIPAL", "HOSPITALS", "SPECIALTY",
           "FOUNDATION", "INC", "CORP", "CORPORATION", "CO"}


def name_similarity(a, b):
    ta = {t for t in (fac_norm(a) or "").split() if len(t) > 1 and t not in GENERIC}
    tb = {t for t in (fac_norm(b) or "").split() if len(t) > 1 and t not in GENERIC}
    if not ta or not tb:
        return None
    return len(ta & tb) / min(len(ta), len(tb))


def nhfr_id(s):
    t = str(s).strip() if s is not None and s == s else ""
    m = re.fullmatch(r"(?:DOH|doh)?(\d{1,15})(?:\.0)?", t)
    return int(m.group(1)) if m else None


DIRECTIONS = r"^(NORTH|NORTHERN|SOUTH|SOUTHERN|EAST|EASTERN|WEST|WESTERN) "


# ---------------------------------------------------------------------------------------------
# Geography
# ---------------------------------------------------------------------------------------------
class Geo:
    LEVEL = {"Reg": "region", "Prov": "province", "City": "city", "Mun": "municipality",
             "SubMun": "submunicipality", "Bgy": "barangay"}

    def __init__(self, df, source="geography"):
        # One PSGC snapshot, as in build_diseases_reference_maps.py: stop rather than pick one.
        snapshots = df.content_checksum.dropna().unique()
        if len(snapshots) != 1:
            sys.exit(f"STOPPED: {source} holds {len(snapshots)} PSGC snapshots; this script needs exactly one")
        self.checksum = snapshots[0]
        g = df.copy()
        g["psgc_code"] = g.psgc_code.astype(str).str.strip().str.zfill(10)
        # damaged n-tilde (UTF-8 read as Latin-1): a no-op once geography_silver is repaired
        self.repaired = int(g.area_name.fillna("").str.contains("\u00c3").sum())
        g["area_name"] = g.area_name.str.replace("\u00c3\u00b1", "\u00f1", regex=False) \
                                    .str.replace("\u00c3\u2018", "\u00d1", regex=False)
        g["level"] = g.geographic_level.map(self.LEVEL)
        g["region"] = g.psgc_code.str[:2] + "00000000"
        g["province"] = None
        mask = g.level.isin(["city", "municipality"]) & (g.city_class.fillna("") != "HUC")
        g.loc[mask, "province"] = g.psgc_code.str[:5] + "00000"
        g["place"] = g.area_name.map(place_key)
        self.all = g
        self.areas = g[g.level.isin(["province", "city", "municipality", "submunicipality"])].copy()
        self.name = dict(zip(g.psgc_code, g.area_name))
        self.level = dict(zip(g.psgc_code, g.level))
        self.city_class = dict(zip(g.psgc_code, g.city_class))
        self.other = g[g.level.isna() & g.area_name.notna()]
        b = g[g.level == "barangay"]
        self.bgy_names = defaultdict(set)            # lgu code -> barangay place names
        for c, nm in zip(b.psgc_code, b.area_name):
            self.bgy_names[fac_lgu(c[:7] + "000")].add(fac_place(nm))
        self.bgy_prov = Counter(b.psgc_code.str[:5])
        self.bgy_lgu = Counter(fac_lgu(c[:7] + "000") for c in b.psgc_code)

    def find(self, place, levels, region=None, province=None):
        a = self.areas[(self.areas.place == place) & self.areas.level.isin(levels)]
        if region:
            a = a[a.region.isin(region if isinstance(region, (list, set, tuple)) else [region])]
        if province:
            a = a[(a.province == province) | (a.psgc_code == province)]
        return a

    def scope(self, levels, region=None, province=None):
        a = self.areas[self.areas.level.isin(levels)]
        if region:
            a = a[a.region.isin(region if isinstance(region, (list, set, tuple)) else [region])]
        if province:
            a = a[(a.province == province) | (a.psgc_code == province)]
        return a

    def barangays(self, code):
        if self.level.get(code) == "province":
            return self.bgy_prov.get(code[:5], 0)
        return self.bgy_lgu.get(code, 0)


# ---------------------------------------------------------------------------------------------
# Rules: candidate for a label that the silver rules do not resolve
# ---------------------------------------------------------------------------------------------
def candidate(geo, label, levels, region=None, province=None, allow_fuzzy=True):
    """(rule, psgc_code or None, named_key or None). Tries the structural rules, then the fuzzy ones,
    first in the parent scope, then nationwide (a nationwide answer must be unique)."""
    n = fac_norm(label) or ""
    hint = city_hint(label)
    lv = ["city"] if hint and "city" in levels else levels
    if province:
        region = None                       # the province is the narrower, already resolved parent
    scopes = [dict(region=region, province=province)] if (region or province) else []
    scopes.append({})

    def unique(place, scope_levels=lv):
        for sc in scopes:
            a = geo.find(place, scope_levels, **sc)
            if len(a) == 1:
                return a.psgc_code.iloc[0]
            if len(a) > 1:
                return None
        return None

    # ncr_district / not_a_province / label_part
    m = re.search(r"(SECOND|THIRD|FOURTH) DISTRICT", n)
    if "NCR" in n.split() and m:
        return "ncr_district", None, "ncr-district:" + {"SECOND": "2", "THIRD": "3", "FOURTH": "4"}[m.group(1)]
    if "NCR" in n.split() and ("FIRST DISTRICT" in n or "CITY OF MANILA" in n):
        return "ncr_district", "1380600000", None
    if "NOT A PROVINCE" in n:
        base = re.sub(r"\(.*?\)", " ", str(label))
        c = unique(place_key(base), ["city"])
        if c:
            return "not_a_province", c, None
    parts = [p for p in re.split(r"[(),]", str(label)) if p and p.strip()]
    if len(parts) > 1:
        provs = {p: geo.find(place_key(p), ["province"]) for p in parts}
        for p, pr in provs.items():          # 'Balayan, Batangas': the province part scopes the other parts
            if len(pr) == 1:
                rest = {geo.find(place_key(q), lv, province=pr.psgc_code.iloc[0]).psgc_code.iloc[0]
                        for q in parts if q != p and len(geo.find(place_key(q), lv, province=pr.psgc_code.iloc[0])) == 1}
                if len(rest) == 1:
                    return "label_part", rest.pop(), None
        hits = {unique(place_key(p)) for p in parts} - {None}
        if len(hits) == 1:
            return "label_part", hits.pop(), None
        # added 2026-10-14: an old name in brackets can be a place elsewhere ('MARAGUSAN (SAN MARIANO)':
        # San Mariano is a town in Isabela). Inside the parent scope only one part may resolve; a part
        # may carry a standard abbreviation ('PRES. CARLOS P. GARCIA (PITOGO)').
        if scopes[0]:
            def variants(q):
                toks = (fac_norm(q) or "").split()
                out = [q]
                for i, t in enumerate(toks):
                    out += [" ".join(toks[:i] + [full] + toks[i + 1:]) for full in ABBREVIATIONS.get(t, [])]
                return out
            inside = set()
            for q in parts:
                for v in variants(q):
                    a = geo.find(place_key(v), lv, **scopes[0])
                    if len(a) == 1:
                        inside.add(a.psgc_code.iloc[0])
                        break
            if len(inside) == 1:
                return "label_part", inside.pop(), None
    # word_order
    words = sorted((fac_place(label) or "").split())
    for sc in scopes:
        a = geo.scope(lv, **sc)
        hit = a[a.area_name.map(lambda x: sorted((fac_place(x) or "").split()) == words)]
        if len(hit) == 1:
            return "word_order", hit.psgc_code.iloc[0], None
        if len(hit) > 1:
            break
    # directional_prefix / province_prefix
    if re.match(DIRECTIONS, n):
        c = unique(place_key(re.sub(DIRECTIONS, "", n)))
        if c:
            return "directional_prefix", c, None
    if n.startswith("PROVINCE OF "):
        c = unique(place_key(n[12:]), ["province"])
        if c:
            return "province_prefix", c, None
    # abbreviation: expand one standard abbreviation and match exactly
    toks = n.split()
    for i, t in enumerate(toks):
        for full in ABBREVIATIONS.get(t, []):
            c = unique(place_key(" ".join(toks[:i] + [full] + toks[i + 1:])))
            if c:
                return "abbreviation", c, None
    # acronym (SGA = Special Geographic Area), among areas of the parent region of any level
    if re.fullmatch(r"[A-Z]{2,5}", n) and region:
        pool = pd.concat([geo.scope(levels, region=region), geo.other[geo.other.region == region]])
        hit = pool[pool.area_name.map(lambda x: "".join(w[0] for w in (fac_norm(x) or "").split()) == n)]
        if len(hit) == 1:
            return "acronym", hit.psgc_code.iloc[0], None
    # split_province: MAGUINDANAO = start of MAGUINDANAO DEL NORTE and MAGUINDANAO DEL SUR
    if "province" in levels and not hint:
        provs = geo.scope(["province"], region=region) if region else geo.scope(["province"])
        starts = provs[provs.area_name.map(lambda x: (fac_place(x) or "").startswith((fac_place(label) or "#") + " "))]
        if len(starts) >= 2:
            return "split_province", None, "hist:" + re.sub(r"[^a-z0-9]+", "_", (fac_place(label) or "").lower())
    if not allow_fuzzy:
        return None, None, None
    # contained_name (whole words, in the parent scope only; 'Province of' dropped; a province wins
    # over cities and municipalities when the label does not say city)
    base = re.sub(r"^PROVINCE OF ", "", n)
    lw = set((fac_place(base) or "").split())
    if (region or province) and lw:
        a = geo.scope(lv, region=region, province=province)
        def contains(x):
            xw = set((fac_place(x) or "").split())
            return bool(xw) and xw != lw and (xw <= lw or lw <= xw)
        hit = a[a.area_name.map(contains)]
        if len(hit) > 1 and not hint and (hit.level == "province").sum() == 1:
            hit = hit[hit.level == "province"]
        if len(hit) == 1:
            return "contained_name", hit.psgc_code.iloc[0], None
    # spelling (in the parent scope; a city is also compared with 'CITY' appended)
    pk = place_key(label) or ""
    for sc in scopes[:-1] or scopes:
        a = geo.scope(lv, **sc)
        if a.empty or not pk:
            continue
        def score(r):
            keys = [r.place] + ([r.place + "CITY"] if r.level == "city" else [])
            return max(difflib.SequenceMatcher(None, pk, k).ratio() for k in keys)
        s = a.assign(score=a.apply(score, axis=1)).sort_values("score", ascending=False)
        top = s.score.iloc[0]
        second = s.score.iloc[1] if len(s) > 1 else 0
        if top >= SPELLING_MIN and top - second >= SPELLING_MARGIN:
            return "spelling", s.psgc_code.iloc[0], None
    return None, None, None


def address_lgu(geo, address, lgus, exclude=()):
    """The one city / municipality of `lgus` that an address names, by its own name or by the
    name of one of its barangays (6+ letters, unique to it among `lgus`). None if 0 or 2+."""
    if not isinstance(address, str) or not address.strip():
        return None
    text = " " + (fac_place(address) or "") + " "
    hits = set()
    for code, name in zip(lgus.psgc_code, lgus.area_name):
        nm = fac_place(name) or ""
        if nm and nm.replace(" ", "") not in exclude and f" {nm} " in text:
            hits.add(fac_lgu(code))
    if len(hits) == 1:
        return hits.pop()
    if hits:
        return None
    owners = defaultdict(set)
    for code in lgus.psgc_code:
        for b in geo.bgy_names.get(fac_lgu(code), ()):
            if b and len(b.replace(" ", "")) >= 6 and f" {b} " in text:
                owners[b].add(fac_lgu(code))
    found = {next(iter(v)) for v in owners.values() if len(v) == 1}
    return found.pop() if len(found) == 1 else None


def address_other_province(geo, label, rows, region, prov):
    """HFSRB label whose city / municipality does not exist in the labelled province: the records'
    addresses name the label AND another province of the same region that has a city /
    municipality of that name ('Hubang, San Francisco, Agusan Del Sur' under 'Agusan del Norte').
    Returns a Counter {psgc_code: records whose address names exactly one such province}."""
    ev = Counter()
    lab = fac_place(label) or ""
    cands = geo.find(place_key(label), ["city", "municipality"], region=region)
    cands = cands[cands.province.notna() & (cands.province != prov)]
    if not lab or cands.empty:
        return ev
    for r in rows.itertuples():
        text = " " + (fac_place(r.address) or "") + " "
        if f" {lab} " not in text:
            continue
        hits = {c for c, pc in zip(cands.psgc_code, cands.province)
                if fac_place(geo.name.get(pc)) and f" {fac_place(geo.name.get(pc))} " in text}
        if len(hits) == 1:
            ev[hits.pop()] += 1
    return ev


# ---------------------------------------------------------------------------------------------
# Inventory per source (mirrors the silver rules: what they resolve needs no row)
# ---------------------------------------------------------------------------------------------
def province_of(geo, label, region):
    if "NOT A PROVINCE" in (fac_norm(label) or ""):
        return None                          # '<city> (Not a Province)': the province of that name is wrong
    p = place_key(label)
    a = geo.find(p, ["province"], region=region)
    if len(a) == 1:
        return a.psgc_code.iloc[0]
    if len(a) == 0:
        a = geo.find(p, ["province"])
        if len(a) == 1:
            return a.psgc_code.iloc[0]
    return None


def silver_city(geo, label, region, prov, levels=("city", "municipality", "submunicipality"), prov_label=None):
    """Mirror of the registry / BOR city step: candidates in the region (else the country), scored
    by province and level; resolved when the best score is unique. With prov_label (registry only):
    when the city label matches nothing anywhere, a province column that names one city resolves it."""
    pk, hint = place_key(label), city_hint(label)
    if prov_label is not None and prov is None and geo.find(pk, list(levels)).empty:
        c = geo.find(place_key(prov_label), ["city"], region=region)
        if len(c) == 1:
            return c.psgc_code.iloc[0]
    for sc in ([dict(region=region)] if region else []) + [{}]:
        a = geo.find(pk, list(levels), **sc)
        if len(a):
            lvl_ok = (a.level == "city") if hint else a.level.isin(["municipality", "submunicipality"])
            sc_ = ((a.province == prov) | (a.psgc_code == prov)).astype(int) * 2 + lvl_ok.astype(int)
            best = sc_.max()
            return a.psgc_code[sc_ == best].iloc[0] if (sc_ == best).sum() == 1 else None
    return None


# Bed occupancy source read by facilities_silver_03 (sources_facilities.yaml entry 12a). The older
# file (entry 12, bed_occupancy) stays in bronze for lineage but is superseded and not read.
BOR_SOURCE = "doh_foi_hospital_beds"


def bor_exceptions(bo, geo, add):
    """Province/District labels, then city / municipality labels under their province, of the bed
    occupancy source. Calls add() for each label the silver rules cannot place."""
    bo = bo[(bo._source_key == BOR_SOURCE) & bo.Region.notna()].copy()
    if bo.empty:
        sys.exit(f"STOPPED: no {BOR_SOURCE} rows in facilities_bed_occupancy_bronze. Load the source first")
    bo["region_psgc"] = bo.Region.map(fac_region_psgc)
    bo["prov_norm"] = bo["Province/District"].map(fac_norm)
    bprov = {}
    for (reg, pn), g in bo.groupby(["region_psgc", "prov_norm"], dropna=False):
        label = g["Province/District"].iloc[0]
        p = province_of(geo, label, reg) if isinstance(label, str) else None
        bprov[(reg, pn)] = p
    done = set()
    for (reg, pn), p in bprov.items():
        if p is not None or pn is None or pn in done:
            continue
        done.add(pn)
        label = bo[bo.prov_norm == pn]["Province/District"].iloc[0]
        rule, code, key = candidate(geo, label, ["province", "city"], region=reg)
        add("bor", "province_label", pn, None, label, rule, code, key, None, int((bo.prov_norm == pn).sum()),
            named_level="ncr_district" if key and key.startswith("ncr-district") else None)
        bprov[(reg, pn)] = code
    bc = bo[bo["City/Municipality"].notna()]
    for (reg, pn, cl), g in bc.groupby(["region_psgc", "prov_norm", "City/Municipality"], dropna=False):
        prov = bprov.get((reg, pn))
        if silver_city(geo, cl, reg, prov) is not None:
            continue
        rule, code, key = candidate(geo, cl, ["city", "municipality", "submunicipality"], region=reg, province=prov)
        add("bor", "area_label", fac_norm(cl), pn, cl, rule, code, key, None, len(g), parent_code=prov)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default="public_health", help="'' for two-part names (local tests)")
    ap.add_argument("--out_dir", default=REF_DIR, help="folder for the three CSVs (default: the Volume folder 00 reads)")
    ap.add_argument("--out", default=None, help="exceptions CSV path (default: <out_dir>/facilities_area_exceptions.csv)")
    ap.add_argument("--compare", default=None, help="an older exceptions CSV to compare with (report only)")
    ap.add_argument("--geography_table", default="silver.geography_silver",
                    help="geography silver table (schema.table): source of PSGC codes and names")
    ap.add_argument("--skip_osm_evidence", type=lambda v: str(v).lower() == "true", default=False)
    args, _ = ap.parse_known_args()      # parse_known_args: notebook kernels pass their own arguments
    pre = f"{args.catalog}." if args.catalog else ""
    args.out = args.out or os.path.join(args.out_dir, "facilities_area_exceptions.csv")
    decisions_out = os.path.join(os.path.dirname(args.out), "facilities_area_decisions.csv")
    overrides_out = os.path.join(os.path.dirname(args.out), "facilities_id_map_override.csv")
    spark = SparkSession.builder.getOrCreate()
    T = lambda t: spark.table(f"{pre}{t}").toPandas()

    geo_table = f"{pre}{args.geography_table}"
    if not spark.catalog.tableExists(geo_table):
        sys.exit(f"STOPPED: geography table not found: {geo_table}. Build geography silver first")
    geo = Geo(spark.table(geo_table).select("psgc_code", "area_name", "geographic_level", "city_class",
                                            "content_checksum").toPandas(), geo_table)
    print(f"geography: {geo_table}, snapshot {geo.checksum[:12]}..., damaged names repaired here: {geo.repaired}")
    rows = []

    succ = {"06": {"18"}, "07": {"18"}, "12": {"19"}, "09": {"19"}}

    def geo_check(mtype, code, parent_code):
        """The proposed code against geography silver: it exists at a level the match type allows, and
        it lies in the label's parent (province for city labels, region for FHSIS labels; a region's
        successor counts: 06/07 -> 18, 09/12 -> 19). 'ok' or the problem."""
        if mtype == "code_prefix" or not code:
            return "ok" if mtype == "code_prefix" else None
        if code not in geo.level:
            return "code_not_in_geography"
        lvl = geo.level.get(code)
        if mtype == "province_label" and lvl not in ("province", "city"):
            return f"level_{lvl}"
        if not parent_code:
            return "ok"
        if parent_code.endswith("00000000"):                    # parent is a region
            ok = code[:2] == parent_code[:2] or code[:2] in succ.get(parent_code[:2], set())
            return "ok" if ok else f"region_{code[:2]}_not_{parent_code[:2]}"
        ok = code[:5] == parent_code[:5] or fac_lgu(code)[:5] == parent_code[:5] or code == parent_code
        if not ok and geo.city_class.get(code) == "HUC" and code[:2] == parent_code[:2]:
            ok = True                                   # an HUC has its own code but lies in the province
        return "ok" if ok else f"province_{code[:5]}_not_{parent_code[:5]}"

    def add(group, mtype, value, parent, label, rule, code, key, evidence, records, year_from=None, year_to=None,
            named_level=None, parent_code=None):
        ev = Counter(evidence or {})
        n = sum(ev.values())
        top, top_n = (ev.most_common(1)[0] if ev else (None, 0))
        share = round(top_n / n, 3) if n else None
        target = key or code
        if rule is None and n >= 1 and (share or 0) >= (0.8 if group == "osm" else 1.0) and n >= (3 if group == "osm" else 2):
            rule, code, target = "evidence_only", top, top
        elif rule is None and target is None and n >= 1 and share == 1.0:
            code = top                                 # shown as the proposal; too little evidence to use it
        if target is None or rule is None:
            status = "needs_review"
        elif n and top == target and share >= 2 / 3:
            status = "corroborated"
        elif n and top != target:
            status = "needs_review"
        elif rule in STRUCTURAL:
            status = "auto"
        else:
            status = "needs_review"
        check = geo_check(mtype, code, parent_code)
        if status in USABLE and check not in (None, "ok"):
            status = "needs_review"                     # geography disagrees with the label's parent
        rows.append(dict(source_group=group, match_type=mtype, match_value=value, parent_label_norm=parent,
                         year_from=year_from, year_to=year_to, area_label_source=label,
                         psgc_code=code, area_key=key, named_key_level=named_level, reason=rule,
                         review_note=None, rule=rule,
                         evidence="; ".join(f"{k}:{v}" for k, v in ev.most_common(3)) or None,
                         evidence_n=n or None, evidence_share=share, review_status=status,
                         proposed_psgc_code=code, proposed_area_name=geo.name.get(code) if code else key,
                         geography_check=check, records=records, _parent_code=parent_code))

    # ---- NHFR: municipality codes not in geography ----------------------------------------------
    nh = T("bronze.facilities_nhfr_bronze")
    nh = nh[nh._source_key == "doh_nhfr"]
    city_col, name_col = "City/Municipality_PSGC", "City/Municipality_Name"
    nh["city_code"] = nh[city_col].astype(str).str.strip().str.zfill(10)
    missing = nh[~nh.city_code.isin(geo.level)]
    by_prefix = defaultdict(list)
    for d in missing.to_dict("records"):
        by_prefix[d["city_code"][:5]].append((d["city_code"], d.get(name_col)))
    for prefix, items in sorted(by_prefix.items()):
        targets, ev = Counter(), Counter()
        for code, nm in items:
            same = geo.areas[(geo.areas.psgc_code.str[5:] == code[5:]) & geo.areas.level.isin(["city", "municipality"])]
            same = same[same.place == place_key(nm)]
            if len(same) == 1:
                targets[same.psgc_code.iloc[0][:5]] += 1
                ev[same.psgc_code.iloc[0][:5]] += 1
        if len(targets) == 1:
            new = next(iter(targets))
            add("nhfr", "code_prefix", prefix, None, f"NHFR codes {prefix}...", "code_prefix_same_name", new, None,
                ev, len(items))
        else:
            add("nhfr", "code_prefix", prefix, None, f"NHFR codes {prefix}...", None, None, None, None, len(items))

    nh_by_id = {}
    remap = {r["match_value"]: r["psgc_code"] for r in rows if r["source_group"] == "nhfr" and r["psgc_code"]}
    for d in nh.to_dict("records"):
        code = d["city_code"]
        if code[:5] in remap:
            code = remap[code[:5]] + code[5:]
        nh_by_id[nhfr_id(d["Health_Facility_Code"])] = (fac_lgu(code), d["Facility_Name"])

    # ---- HFSRB: province labels, then city labels under their province -------------------------
    hf = []
    for t in ("hospitals", "infirmaries", "primary_care", "dialysis_clinics"):
        d = T(f"bronze.facilities_hfsrb_{t}_bronze")
        d = d[d.region.notna() & d.city_municipality.notna()]
        hf.append(d[["region", "province", "city_municipality", "nhfr_code", "facility_name", "address"]])
    hf = pd.concat(hf)
    hf["region_psgc"] = hf.region.map(fac_region_psgc)
    hf["prov_norm"] = hf.province.map(fac_norm)
    hf["city_norm"] = hf.city_municipality.map(fac_norm)
    prov_res = {}
    for (reg, pn), g in hf.groupby(["region_psgc", "prov_norm"], dropna=False):
        label = g.province.iloc[0]
        p = province_of(geo, label, reg) if isinstance(label, str) else None
        prov_res[(reg, pn)] = p
    done_prov = set()
    for (reg, pn), p in prov_res.items():
        if p is not None or pn is None or pn in done_prov:
            continue
        done_prov.add(pn)
        label = hf[hf.prov_norm == pn].province.iloc[0]
        rule, code, key = candidate(geo, label, ["province"], region=reg)
        if code is None and rule is None:
            continue                       # e.g. 'Davao City' in the province column: silver handles it
        ev = Counter()
        for r in hf[hf.prov_norm == pn].itertuples():
            m = nh_by_id.get(nhfr_id(r.nhfr_code))
            if m and (name_similarity(m[1], r.facility_name) or 0) >= 0.5 and m[0][:5] != "13806":
                pc = m[0][:5] + "00000"
                if geo.level.get(pc) == "province":
                    ev[pc] += 1
        add("hfsrb", "province_label", pn, None, label, rule, code, key, ev, int((hf.prov_norm == pn).sum()))
        prov_res[(reg, pn)] = code
    for (reg, pn, cn), g in hf.groupby(["region_psgc", "prov_norm", "city_norm"], dropna=False):
        prov = prov_res.get((reg, pn))
        label = g.city_municipality.iloc[0]
        if silver_city(geo, label, reg, prov, prov_label=g.province.iloc[0] if isinstance(g.province.iloc[0], str) else "") is not None:
            continue
        rule, code, key = candidate(geo, label, ["city", "municipality", "submunicipality"], region=reg, province=prov)
        ev = Counter()
        lgus = geo.scope(["city", "municipality", "submunicipality"], province=prov) if prov else \
               geo.scope(["city", "municipality", "submunicipality"], region=reg)
        for r in g.itertuples():
            m = nh_by_id.get(nhfr_id(r.nhfr_code))
            if m and (name_similarity(m[1], r.facility_name) or 0) >= 0.5:
                ev[m[0]] += 1
                continue
            hit = address_lgu(geo, r.address, lgus, exclude={place_key(label), place_key(r.province)})
            if hit:
                ev[hit] += 1
        if code:
            code = fac_lgu(code) if ev and fac_lgu(code) in ev else code
        parent_code = prov
        if rule is None and code is None and key is None and not ev and prov:
            # the name does not exist in the labelled province: does the address name another one?
            other = address_other_province(geo, label, g, reg, prov)
            if len(other) == 1:
                code = next(iter(other))
                rule, ev, parent_code = "address_other_province", other, code[:5] + "00000"
        add("hfsrb", "area_label", cn, pn, label, rule, code, key, ev, len(g), parent_code=parent_code)

    # ---- FHSIS: area labels under their region row, per file year -------------------------------
    fh = T("bronze.facilities_fhsis_primary_care_bronze")
    fh = fh[(fh._source_key == "doh_fhsis_demographic") & fh.area_name.notna()].copy()
    fh["year"] = fh._source_file.str.extract(r"_(\d{4})\.xlsx$")[0].astype(int)
    fh["bgy"] = pd.to_numeric(fh.barangays_no.astype(str).str.replace(",", "").str.strip(), errors="coerce")
    fh = fh.sort_values(["_source_file", "_source_row_num"])
    prov_places = set(geo.areas.place[geo.areas.level == "province"])
    units = []                                    # (year, file, row, label, label_norm, parent region, barangays)
    for f, g in fh.groupby("_source_file"):
        parent = None
        for d in g.to_dict("records"):
            lab = str(d["area_name"]).strip()
            n = fac_norm(lab)
            if not n or n == "PHILIPPINES" or re.match(r"^(SOURCE|NOTE|LEGEND)", n):
                continue
            reg = fac_region_psgc(lab)
            if reg and not city_hint(lab) and place_key(lab) not in prov_places:
                parent = reg
                continue
            if not re.search(r"\d", str(d["population"] or "")):
                continue
            units.append((d["year"], f, d["_source_row_num"], lab, n, parent, d["bgy"]))
    succ = {"0600000000": "1800000000", "0700000000": "1800000000", "1200000000": "1900000000",
            "0900000000": "1900000000"}
    resolved = {}                                 # mirror of the metric [3] name + level + parent step
    for (yr, f, rn, lab, n, parent, bgy) in units:
        pk, hint = place_key(lab), city_hint(lab)
        lv = ["city"] if hint else ["province", "city", "municipality"]
        code = None
        for sc in ([dict(region=parent)] if parent else []) + ([dict(region=succ[parent])] if parent in succ else []) + [{}]:
            a = geo.find(pk, lv, **sc)
            if len(a):
                s = a.level.map(lambda l: 2 if (hint and l == "city") or (not hint and l == "province") else 1)
                code = a.psgc_code[s == s.max()].iloc[0] if (s == s.max()).sum() == 1 else None
                break
        resolved[(f, rn)] = code
    listed = defaultdict(set)                     # file, region -> areas listed in it
    for (yr, f, rn, lab, n, parent, bgy) in units:
        if resolved[(f, rn)]:
            listed[(f, parent)].add(resolved[(f, rn)])

    def bgy_close(code, bgy, f, parent):  # noqa: E306
        """The printed barangay count is within the tolerance of the area's count in geography
        (a province with or without the cities listed separately in the same file)."""
        if not code or bgy is None or bgy != bgy:
            return False
        exp = {geo.barangays(code)}
        if geo.level.get(code) == "province":
            sub = [c for c in listed.get((f, parent), ()) if geo.level.get(c) == "city" and c[:5] == code[:5]]
            exp.add(geo.barangays(code) - sum(geo.barangays(c) for c in sub))
        return any(e > 0 and abs(int(bgy) - e) / e <= BGY_TOLERANCE for e in exp)

    def bgy_fit(bgy, f, parent, pool):
        fits = [c for c in pool if bgy_close(c, bgy, f, parent)]
        return fits[0] if len(fits) == 1 else None

    # duplicates: two rows of one file resolve to the same area. Each area of the region missing from
    # the file goes to the ONE row whose printed barangay count is closest to it (within the
    # tolerance); one remaining row keeps its name (the closest to the named area); any other copy is
    # proposed for the last missing area, for review.
    by_file_code = defaultdict(list)
    for u in units:
        if resolved[(u[1], u[2])]:
            by_file_code[(u[1], resolved[(u[1], u[2])])].append(u)

    def gap(code, bgy, f, parent):
        if not code or bgy is None or bgy != bgy:
            return None
        exp = {geo.barangays(code)}
        if geo.level.get(code) == "province":
            sub = [c for c in listed.get((f, parent), ()) if geo.level.get(c) == "city" and c[:5] == code[:5]]
            exp.add(geo.barangays(code) - sum(geo.barangays(c) for c in sub))
        return min(abs(int(bgy) - e) / e for e in exp if e > 0) if any(e > 0 for e in exp) else None

    groups = [(f, code, us) for (f, code), us in sorted(by_file_code.items()) if len(us) >= 2]
    moved, used = {}, defaultdict(set)            # (file, row) -> area; file -> areas given out
    for f in sorted({g[0] for g in groups}):      # pass 1: closest row per missing area, whole file
        pairs = []
        for (_, code, us) in [g for g in groups if g[0] == f]:
            parent = us[0][5]
            missing_here = [c for c in geo.scope(["province", "city", "municipality"], region=parent).psgc_code
                            if c not in listed[(f, parent)]]
            pairs += [(g_, u[2], c) for u in us for c in missing_here
                      for g_ in [gap(c, u[6], f, parent)] if g_ is not None and g_ <= BGY_TOLERANCE]
        for g_, rn, c in sorted(pairs):
            if (f, rn) not in moved and c not in used[f]:
                moved[(f, rn)] = c
                used[f].add(c)
    for (f, code, us) in groups:                  # pass 2: rows
        parent = us[0][5]
        stay = [u for u in us if (f, u[2]) not in moved]
        keep = min(stay, key=lambda u: gap(code, u[6], f, parent) if gap(code, u[6], f, parent) is not None else 9) if stay else None
        left = [c for c in geo.scope(["province", "city", "municipality"], region=parent).psgc_code
                if c not in listed[(f, parent)] and c not in used[f]]
        for u in us:
            yr, _, rn, lab, n, _, bgy = u
            if (f, rn) in moved:
                add("fhsis", "area_label", n, parent, lab, "duplicate_in_file", moved[(f, rn)], None,
                    Counter({moved[(f, rn)]: 1}), 1, yr, yr, parent_code=parent)
            elif keep is not None and rn != keep[2]:
                add("fhsis", "area_label", n, parent, lab, "duplicate_in_file", left[0] if len(left) == 1 else None,
                    None, None, 1, yr, yr, parent_code=parent)

    pending = defaultdict(list)                   # labels the name step does not resolve
    for u in units:
        if resolved[(u[1], u[2])] is None:
            pending[(u[4], u[5])].append(u)
    for (n, parent), us in sorted(pending.items(), key=lambda x: (x[0][0], x[0][1] or "")):
        lab = us[0][3]
        rule, code, key = candidate(geo, lab, ["province", "city", "municipality"], region=parent)
        pool = list(geo.scope(["province", "city"], region=parent).psgc_code) if parent else []
        ev = Counter(c for c in (bgy_fit(u[6], u[1], parent, pool) for u in us) if c)
        if code and ev and code not in ev and rule not in STRUCTURAL:
            rule, code = None, None                   # the text guess is contradicted: let the evidence decide
        add("fhsis", "area_label", n, parent, lab, rule, code, key, ev, len(us), parent_code=parent)

    # ---- BOR: Province/District labels, then city labels under their province -------------------
    bor_exceptions(T("bronze.facilities_bed_occupancy_bronze"), geo, add)

    # ---- OSM: addr:city of points without coordinates -------------------------------------------
    hs = T("bronze.facilities_hdx_healthsites_bronze")
    hs = hs[hs._source_key == "hdx_healthsites"].copy()
    # Only the newest file (latest _as_of_date), the same rule as facilities_silver_04: bronze keeps
    # every Healthsites snapshot (load_mode latest_file). Two files on that date would be ambiguous.
    hs = hs[hs._as_of_date == hs._as_of_date.max()].copy()
    if hs._source_file.nunique() != 1:
        sys.exit(f"STOPPED: {hs._source_file.nunique()} Healthsites files share the latest _as_of_date "
                 f"{hs._as_of_date.max()}: give the newer one a later as_of_date in sources_facilities.yaml")
    hs["has_xy"] = pd.to_numeric(hs.X, errors="coerce").notna() & pd.to_numeric(hs.Y, errors="coerce").notna()
    pip = {}
    try:
        import json
        from shapely import STRtree, points
        from shapely.geometry import shape
        bnd = spark.table(f"{pre}silver.facilities_area_boundary") \
                   .select("psgc_code", "boundary_rule", "geometry_json", "geography_checksum").toPandas()
        bsum = bnd.geography_checksum.dropna().unique()
        if len(bsum) != 1 or bsum[0] != geo.checksum:
            raise ValueError("silver.facilities_area_boundary was not built from this geography snapshot "
                             "(geography_checksum differs): run facilities_silver_00a_area_boundary.sql first")
        bnd = bnd[(bnd.boundary_rule == "hdx") & bnd.geometry_json.notna()][["psgc_code", "geometry_json"]] \
            .reset_index(drop=True)
        tree = STRtree([shape(json.loads(w)) for w in bnd.geometry_json])
        xy = hs[hs.has_xy]
        pi, gi = tree.query(points(pd.to_numeric(xy.X).values, pd.to_numeric(xy.Y).values), predicate="intersects")
        for i, g in zip(pi, gi):
            pip[xy.index[i]] = bnd.psgc_code.iloc[g]
    except Exception as e:
        # Without the OSM evidence the OSM rows would come out needs_review: a different file, silently.
        if not args.skip_osm_evidence:
            sys.exit(f"STOPPED: OSM point-in-polygon evidence unavailable ({type(e).__name__}: {e}). "
                     "Install shapely and run facilities_silver_00a_area_boundary.sql, or pass --skip_osm_evidence true")
        print(f"note: OSM point-in-polygon evidence skipped ({type(e).__name__}: {e})")
    hs["pip"] = hs.index.map(pip)
    hs["label_key"] = hs.addr_city.map(place_key)
    labelled = hs[hs.label_key.notna()]
    for lk, g in labelled.groupby("label_key"):
        nocoord = g[~g.has_xy]
        if nocoord.empty:
            continue
        label = nocoord.addr_city.iloc[0]
        hint = city_hint(label)
        a = geo.find(lk, ["city"] if hint else ["city", "municipality"])
        if len(a) == 1:
            continue                              # silver resolves it by name
        ev = Counter(fac_lgu(c) for c in g.pip.dropna())
        rule, code, key = candidate(geo, label, ["city", "municipality"], allow_fuzzy=False)
        if code is None and len(a) > 1 and ev:
            inside = [c for c in a.psgc_code if c in ev]
            if len(inside) == 1:
                rule, code = "ambiguous_name_located", inside[0]
        add("osm", "area_label", label, None, label, rule, code, key, ev, len(nocoord))

    # ---- decisions by a person, then write -------------------------------------------------------
    out = pd.DataFrame(rows, columns=OUT_COLUMNS[:-1] + ["_parent_code"])
    dec = pd.DataFrame(DECISIONS, columns=DECISION_COLS)
    if dec.duplicated(["source_group", "match_type", "match_value", "parent_label_norm", "year_from"]).any():
        sys.exit("STOPPED: two DECISIONS rows share a key")
    for o in ID_MAP_OVERRIDES:
        if len(o) != len(ID_MAP_OVERRIDE_COLS) or o[2] not in ("link_to_nhfr", "own_facility") \
                or (o[2] == "link_to_nhfr" and not str(o[3] or "").isdigit()):
            sys.exit(f"STOPPED: ID_MAP_OVERRIDES row is not valid: {o}")
    keycols = ["source_group", "match_type", "match_value", "parent_label_norm", "year_from"]
    out[keycols] = out[keycols].astype(object).where(out[keycols].notna(), None)
    def keyval(x):
        """Comparable text for a key cell: None for blanks, 2022 for 2022 / 2022.0 / '2022'."""
        if x is None or (isinstance(x, float) and x != x) or (isinstance(x, str) and x.strip() == ""):
            return None
        if isinstance(x, float) and x.is_integer():
            return str(int(x))
        return str(x).strip()

    # A decision is tied to what the reviewer saw. 'accept' applies only while the generator still
    # proposes the same code / key; if geography or the data changed the proposal, the decision is
    # stale: the row stays needs_review (records quarantined) until it is reviewed again.
    stale, unmatched = [], []
    for d in dec.to_dict("records"):
        decision = keyval(d.get("decision"))
        dcode, dkey = keyval(d.get("psgc_code")), keyval(d.get("area_key"))
        if decision not in ("accept", "set", "reject"):
            sys.exit(f"STOPPED: decision must be accept / set / reject: {d}")
        if decision in ("accept", "set") and not (dcode or dkey):
            sys.exit(f"STOPPED: an accept / set decision must carry the psgc_code or area_key it approves: {d}")
        m = pd.Series(True, index=out.index)
        for k in keycols:
            v = keyval(d.get(k))
            m &= out[k].map(keyval) == v if v is not None else out[k].map(keyval).isna()
        if not m.any():
            unmatched.append(d)
            continue
        note = f"{decision} by {d.get('reviewed_by')} on {d.get('reviewed_on')}: {d.get('note') or ''}"
        if decision == "reject":
            out.loc[m, ["review_status", "review_note"]] = ["rejected", note]
            continue
        if decision == "accept":
            gen = out.loc[m, "proposed_psgc_code"].map(keyval) if dcode else out.loc[m, "area_key"].map(keyval)
            if not (gen == (dcode or dkey)).all():
                now = ", ".join(sorted({str(x) for x in gen}))
                out.loc[m, ["review_status", "review_note"]] = [
                    "needs_review", f"stale decision: {d.get('reviewed_by')} accepted {dcode or dkey} on "
                                    f"{d.get('reviewed_on')}; the generator now proposes {now}"]
                stale.append((d, now))
                continue
        out.loc[m, "psgc_code"] = dcode
        out.loc[m, "area_key"] = dkey
        out.loc[m, ["review_status", "review_note"]] = ["reviewed", note]

    # A person's decision is checked against geography like any generated row.
    bad = []
    for i in out.index[out.review_status == "reviewed"]:
        r = out.loc[i]
        chk = geo_check(r.match_type, keyval(r.psgc_code), keyval(r._parent_code)) if keyval(r.psgc_code) else "ok"
        out.loc[i, "geography_check"] = chk
        if chk not in (None, "ok"):
            bad.append((r.source_group, r.area_label_source, r.psgc_code, chk))
    # Final gate: every code silver will use exists in geography_silver.
    usable = out[out.review_status.isin(USABLE) & (out.match_type != "code_prefix") & out.psgc_code.notna()]
    missing = usable[~usable.psgc_code.isin(geo.level.keys())]
    for r in missing.itertuples():
        bad.append((r.source_group, r.area_label_source, r.psgc_code, "code_not_in_geography"))
    if bad:
        for b in bad:
            print("  geography check failed:", b)
        sys.exit(f"STOPPED: {len(bad)} usable row(s) fail the geography check. Fix the decision or the rule; "
                 "nothing written")
    out = out.drop(columns="_parent_code")
    out["geography_checksum"] = geo.checksum

    for c in ("year_from", "year_to", "evidence_n", "records"):
        out[c] = pd.to_numeric(out[c], errors="coerce").astype("Int64")
    out = out.sort_values(["source_group", "match_type", "match_value", "parent_label_norm"], na_position="first")
    out.to_csv(args.out, index=False, quoting=csv.QUOTE_MINIMAL)
    dec.to_csv(decisions_out, index=False, quoting=csv.QUOTE_MINIMAL)
    pd.DataFrame(ID_MAP_OVERRIDES, columns=ID_MAP_OVERRIDE_COLS).to_csv(overrides_out, index=False, quoting=csv.QUOTE_MINIMAL)

    # ---- report ----------------------------------------------------------------------------------
    print(f"wrote {args.out}: {len(out)} rows")
    print(f"wrote {decisions_out}: {len(dec)} decisions (record of DECISIONS)")
    print(f"wrote {overrides_out}: {len(ID_MAP_OVERRIDES)} identity overrides")
    print(out.groupby(["source_group", "review_status"]).size().unstack(fill_value=0).to_string())
    print("\nby rule:", out.groupby("rule", dropna=False).size().to_dict())
    for d, now in stale:
        print(f"STALE decision (row back to needs_review): {d.get('source_group')} {d.get('match_value')!r} "
              f"accepted {d.get('psgc_code') or d.get('area_key')}, now proposed {now}")
    for d in unmatched:
        print(f"decision matches no generated row (label gone from the data; can be removed): "
              f"{d.get('source_group')} {d.get('match_value')!r} parent={d.get('parent_label_norm')}")
    nr = out[~out.review_status.isin(USABLE)]
    if len(nr):
        print(f"\n{len(nr)} rows are not used by silver (records quarantined) until decided in DECISIONS:")
        for r in nr.itertuples():
            print(f"  {r.source_group} {r.match_type} {r.area_label_source!r} parent={r.parent_label_norm} "
                  f"year={r.year_from} rule={r.rule} proposed={r.proposed_psgc_code} {r.proposed_area_name or ''} "
                  f"evidence={r.evidence} records={r.records}")
    if args.compare:
        old = pd.read_csv(args.compare, dtype=str)
        print("\ncomparison with", args.compare)
        for r in old.itertuples():
            m = out[(out.source_group == r.source_group) & (out.match_type == r.match_type)
                    & (out.match_value.map(lambda x: place_key(x)) == place_key(r.match_value))]
            if r.parent_label_norm == r.parent_label_norm and r.parent_label_norm:
                m = m[m.parent_label_norm.map(lambda x: str(x)) == str(r.parent_label_norm)] if len(m) > 1 else m
            new = m.iloc[0] if len(m) else None
            same = new is not None and ((new.proposed_psgc_code == r.psgc_code) or (new.area_key == r.area_key))
            print(f"  {'SAME' if same else 'DIFF':4s} {r.source_group:5s} {r.match_type:14s} {r.area_label_source!r}: "
                  f"old {r.psgc_code if r.psgc_code == r.psgc_code else r.area_key} | new "
                  f"{(new.proposed_psgc_code if new is not None else 'no row')} "
                  f"{(new.review_status if new is not None else '')} {(new.rule if new is not None else '')}")


if __name__ == "__main__":
    main()