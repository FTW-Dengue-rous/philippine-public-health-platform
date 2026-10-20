# Glossary

Terms used in this project, in alphabetical order within each group. When a term is also a column or table, the name is in `code`. Detailed column definitions are in the [data dictionary](../04-pipeline/gold/data-dictionary.md).

Owner: LUNASaan Documentation Team
Last updated: 2026-10-20

---

## 1. Philippine health and geography terms

| Term | Meaning |
|---|---|
| **ABC (authorized bed capacity)** | Beds a hospital is licensed for. Not the same as staffed beds. Stored as `authorized_beds` |
| **ADM1 / ADM2 / ADM3** | Administrative levels in the HDX boundaries: region, province, city or municipality |
| **Barangay** | Smallest administrative unit. In silver, not in gold |
| **BARMM** | Bangsamoro Autonomous Region in Muslim Mindanao |
| **BHS** | Barangay health station |
| **BHW** | Barangay health worker |
| **BOR (bed occupancy rate)** | Inpatient bed-days ÷ (beds × days) × 100. Can exceed 100% when patients exceed beds |
| **CC / ICC / HUC** | Component city / independent component city / highly urbanized city. A HUC is not part of any province for statistics |
| **CHC / MHC / RHU** | City health centre / municipal health centre / rural health unit (primary care) |
| **COD-AB** | Common Operational Dataset – Administrative Boundaries, published on HDX |
| **DOH** | Department of Health |
| **DS-TB / MDR-TB** | Drug-susceptible / multidrug-resistant tuberculosis |
| **eFOI / FOI** | (Electronic) Freedom of Information request to a government agency |
| **FHSIS** | Field Health Services Information System (DOH). Source of TB, morbidity, workforce and facility counts |
| **HDX** | Humanitarian Data Exchange. Source of weekly dengue data, boundaries and healthsites |
| **HFSRB** | Health Facilities and Services Regulatory Bureau (DOH). Licenses hospitals, infirmaries, primary care facilities, dialysis clinics and blood service facilities |
| **Hospital level** | Level 1, 2 or 3 (Level 3 = most specialised). `unknown` when the source has none |
| **IHME GBD** | Institute for Health Metrics and Evaluation, Global Burden of Disease. Modelled estimates |
| **LGU** | Local government unit |
| **NCR** | National Capital Region (Metro Manila). Has no provinces |
| **NHFR** | National Health Facility Registry (DOH). The spine of the facility registry: the HFSRB licensed lists are matched to it |
| **OHSRS** | Online Health Facility Statistical Report System (DOH) |
| **OSM / healthsites.io** | OpenStreetMap; healthsites.io publishes its health facility points |
| **PhilHealth** | Philippine Health Insurance Corporation |
| **PSA** | Philippine Statistics Authority |
| **PSGC** | Philippine Standard Geographic Code. 10-digit code for every region, province, city, municipality and barangay. The platform uses the Q2 2024 snapshot for every year |
| **PSMO** | Philippine Society of Medical Oncology |
| **SGA** | Special Geographic Area (BARMM) |
| **TPT** | TB preventive treatment |
| **UP NOAH** | University of the Philippines NOAH Center. Publishes regional dengue counts |

## 2. Project terms

| Term | Meaning |
|---|---|
| **Broad unit** | A province together with its HUCs. Used where a source cannot separate them |
| **Comparison eligible** | `comparison_eligible = true` when a row describes the same place as the unit it is compared with |
| **`facility_key`** | Stable id of one facility establishment. Assigned once, reused from the previous id map on every rebuild, never derived from a name or a code. Join on it, not on names |
| **Focus disease** | A disease used in the burden mart and case studies (`is_focus_disease`) |
| **IATWG-HFD** | The client persona: Inter-Agency Technical Working Group on Health Facility Data |
| **LUNASaan?** | The platform name: *lunas* (cure) + *saan* (where) |
| **Mapping outcome** | How a published area maps to a planning unit: `direct`, `aggregate`, `not_separable`, `not_used`, `out_of_scope` |
| **Named area** | An area with no PSGC code, kept with a named code (for example the 4 NCR districts) |
| **Planning unit** | The unit every comparison uses: each province without its HUCs, each HUC, and NCR |
| **Preferred source** | The source gold displays for a metric. Other roles: `cross_check`, `fallback`. We avoid "source of truth" (D-13) |
| **Recorded** | Listed in the source registry. Not listed does not mean absent: a facility may be unregistered, unlisted or listed under a variant name |
| **Reference year** | The year a value describes (the 2025 poverty estimate, the 2024 census count). Not the file's release date, `_as_of_date` |
| **Registered vs reported** | Registered data comes from a registry (NHFR, HFSRB); reported data comes from periodic reporting (FHSIS, surveillance). They can disagree; each keeps its own rows |
| **Restricted** | `sharing: restricted`. Published as aggregates only; raw files never committed |
| **Selection contract** | The filters that make a total valid for each fact (for example one source, all ages, both sexes) |

## 3. Data engineering terms

| Term | Meaning |
|---|---|
| **ANSI mode** | Spark setting where a failed `CAST` stops the query. Gold relies on it |
| **Asset Bundle** | Databricks deployment of jobs and code from `databricks.yml` |
| **Bronze / silver / gold** | Medallion layers: raw as received / cleaned and standardised / modelled for analysis |
| **`build_id`** | One id per silver or gold build. Silver rows carry `_silver_build_id`, gold rows `_gold_build_id` |
| **`build_log` / `build_inputs`** | Quality tables: one row per build / one row per input a build read |
| **Candidate** | The table a build writes before its gates pass |
| **Content checksum** | sha256 of a source file's bytes. Identifies the exact file version |
| **Cross-domain QC** | `silver_cross_domain_qc.py`: silver checks that read two or more domains (quarantine share, ratios per population, source age, FHSIS vs census population) |
| **Default view** | A gold view (`v_*`) that applies a fact's selection contract |
| **Dimension / fact** | Descriptive table (what, where, when) / measurement table. Names start `dim_` / `fact_`, gold only (D-07) |
| **`DQRun`** | The shared Python helper (`dq_utils.py`) every QC script writes results through |
| **Gate** | A check that stops a build or a job when it fails |
| **Grain** | What one row represents |
| **Idempotent** | Running twice on the same input gives the same result |
| **Incremental load** | Load only new or changed inputs |
| **`ingestion_metadata`** | Bronze load log: one row per file or sheet per run |
| **Landing** | Folder where source files arrive before bronze. Files are never edited there |
| **Lineage** | The record of where a row came from |
| **Mart** | A gold view shaped for one set of questions (`mart_*`) |
| **Preload gate** | `bronze_gate.py`: stops a domain's silver when a bronze source is FAIL, CRASHED, STALE or NOT_CHECKED |
| **QC re-queue** | `run_bronze.py` re-runs QC for unchanged sources that are not cleared |
| **Quarantine** | Rows held back with a reason, not dropped silently |
| **Reconciliation** | Rows read = rows loaded + rows set aside, per input |
| **Reference map** | Reviewed CSV that maps a source label to a PSGC code or disease key. Generated by a builder script |
| **`replaceWhere`** | Delta write that replaces only the rows matching a condition (for example one file) |
| **Review status** | Status of a reviewed decision in a reference map: `proposed` (applied but kept out of analysis), `accepted`, `rejected` |
| **Row disposition** | Why a bronze row was not loaded: `dropped_non_data`, `duplicate_of`, `quarantined`, `merged_into` |
| **Row override** | A reviewed decision for one bronze row (file, sheet, row), bound to the file version it was reviewed in. Used when a printed label or code is wrong |
| **Seed** | A small reviewed table defined in code (for example `source_priority`) |
| **`source_key`** | The YAML entry name of a source. Carried as `_source_key`. Never changed once in use |
| **STALE** | A source loaded again after its latest QC, so QC never saw the new load |
| **Surrogate key** | A generated key. Gold uses `xxhash64` of the natural key |
| **Unity Catalog / Volume** | Databricks catalog with three-part names / file storage inside it |
| **`value_status`** | Per-value status: `ok`, `missing`, `invalid`, `suppressed` and others. A null value is never treated as 0 |
| **Write-audit-publish** | Write a candidate, check it, publish only if every gate passes |

## 4. History of updates

| Date | Change |
|---|---|
| 2026-10-20 | Owner and update-date header added; data-dictionary link; PSGC snapshot and NCR notes; NHFR and HFSRB scope; `facility_key`, reference year and registered-vs-reported entries; `source_key` note; "Recorded" reworded |