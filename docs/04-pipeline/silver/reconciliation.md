# Silver — reconciliation

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Reconciliation proves that silver lost nothing, doubled nothing and changed no value on the way from bronze. Every bronze row a build reads is either in a silver row or recorded with the reason it was set aside, and the numbers that come out match the numbers that went in and the numbers the agencies published.

This page is the method. The evidence index states where a recorded run's reconciliation outputs belong; see [evidence](../../06-evidence/README.md). Back to the [silver overview](README.md).

## 1. Row accounting

For every silver build, per source:

```
rows read from bronze  =  rows loaded into silver  +  rows set aside (with a reason)
```

| Term | Where it is recorded |
|---|---|
| Rows read | `quality.build_inputs.input_rows`, one row per bronze file and sheet the build read |
| Rows loaded | Not stored row by row: the silver rows carry their bronze row reference (`_source_file`, `_source_sheet`, `_source_row_num`) |
| Rows set aside | `quality.row_disposition`, one row per bronze row not loaded, with its disposition and reason |

| Disposition | Meaning | Counts as |
|---|---|---|
| `dropped_non_data` | Titles, notes, legends, blank rows, footnotes | Set aside |
| `duplicate_of` | A known repeat of another row (for example the 252 HDX rows repeated across two files) | Set aside |
| `quarantined` | A data row that cannot be placed safely (for example a blank area label with numbers in it) | Set aside |
| `merged_into` | Folded into another silver row (claims repeats summed; FHSIS households joined to the population row of the same area and year) | Loaded |

Nothing is dropped without one of these rows. An unclassified bronze row stops the build.

## 2. Where it is checked

| When | Check | Effect |
|---|---|---|
| Before publishing | Build gates "classified rows <> bronze rows read" and "bronze rows referenced by silver <> rows read − rows not loaded" | Any difference stops the build; the published table is not touched |
| After publishing | Domain QC **S09** "bronze to silver rows reconcile", per table and source | FAIL stops the job before gold |
| After publishing | Domain QC **S63 / S33 / S83 / S16** freshness: the bronze loads read are the ones in bronze now | FAIL: rebuild silver |
| After all domains | Cross-domain QC **S29**: quarantined share per table and source | WARN above 0; FAIL above 5% **and** above 10 rows |

Geography and population are built in Python and check the same thing their own way:

| Table | Check | Rule |
|---|---|---|
| `geography_silver` | SG05 before writing, GS05 after | Bronze snapshot rows = silver snapshot rows |
| `population_silver` | S09 | Population entries unpacked from bronze = silver rows, matched on area, year and version |
| `admin_boundaries_silver` | AB04 before writing, ASB05 after | Bronze features = silver boundaries |

## 3. Value reconciliation

Row counts can match while values change. Three more checks cover values:

| Kind | Checks | What must hold |
|---|---|---|
| Totals preserved | S10 (diseases, socioeconomic) | The sum of a measure in silver = the sum of the same cells read from bronze |
| Published controls | S21 facilities, S34 diseases, S64 / S65 / S78 workforce, S84 socioeconomic, S56 population | Selected values equal the figures the agency published. They are the same numbers bronze QC B11 checks, read from the `qc.control_values` of `config/sources_<domain>.yaml` |
| Internal consistency | S55 population, S68 / S69 workforce, S91 socioeconomic | Totals equal their parts (province = its cities and municipalities; total = its components; financing shares add up). WARN, because a source can disagree with itself |

## 4. Rows set aside by design

Known at the last builds. The live counts are in `row_disposition` and in the S09 detail.

| Table | Rows set aside | Why |
|---|---|---|
| `diseases_metric_silver` | 252 HDX rows, 820 IHME rows (`duplicate_of`); 18 FHSIS TB rows (`quarantined`) | Repeats across files; TB rows of the Special Geographic Area that cannot be placed (review item) |
| `diseases_hospital_claims_silver` | 1,404 rows (`quarantined`); 120 repeats (`merged_into`) | Blank illness; repeated source rows, summed |
| `workforce_headcount_silver` | 8 rows (`quarantined`) | Blank area label with numbers in the row |
| `workforce_area_denominator_silver` | Households rows (`merged_into`) | Joined to the population row of the same area and year |
| `facilities_osm_point_silver` | 2 points (`quarantined`) | Outside every boundary |
| Every table | `dropped_non_data` | Titles, notes, legends |

## 5. Producing the evidence

Run these after a full run and save the outputs in the reconciliation folder named by the evidence index, with the run date.

**A. Row accounting per table and source** (latest succeeded build of each silver table):

```sql
WITH latest AS (
  SELECT target_table, max_by(build_id, finished_at) AS build_id
  FROM public_health.quality.build_log
  WHERE layer = 'silver' AND status = 'succeeded'
  GROUP BY target_table),
read_rows AS (
  SELECT i.target_table, i.source_key, sum(i.input_rows) AS rows_read
  FROM public_health.quality.build_inputs i
  JOIN latest l ON l.target_table = i.target_table AND l.build_id = i.build_id
  WHERE i.input_kind = 'bronze_source'
  GROUP BY i.target_table, i.source_key),
set_aside AS (
  SELECT d.target_table, d.source_key,
         count_if(d.disposition = 'dropped_non_data') AS dropped_non_data,
         count_if(d.disposition = 'duplicate_of')     AS duplicate_of,
         count_if(d.disposition = 'quarantined')      AS quarantined,
         count_if(d.disposition = 'merged_into')      AS merged_into
  FROM public_health.quality.row_disposition d
  JOIN latest l ON l.target_table = d.target_table AND l.build_id = d.build_id
  GROUP BY d.target_table, d.source_key)
SELECT r.target_table, r.source_key, r.rows_read,
       coalesce(s.dropped_non_data, 0) AS dropped_non_data,
       coalesce(s.duplicate_of, 0)     AS duplicate_of,
       coalesce(s.quarantined, 0)      AS quarantined,
       coalesce(s.merged_into, 0)      AS merged_into,
       r.rows_read - coalesce(s.dropped_non_data, 0) - coalesce(s.duplicate_of, 0)
                   - coalesce(s.quarantined, 0)      AS rows_loaded
FROM read_rows r
LEFT JOIN set_aside s ON s.target_table = r.target_table AND s.source_key <=> r.source_key
ORDER BY r.target_table, r.source_key;
```

**B. The reconciliation checks of the latest QC runs** (each must be PASS; S29 may be WARN with its rows listed):

```sql
SELECT table_name, source_key, check_id, check_name, status, observed, expected, detail, executed_at
FROM public_health.quality.qc_results
WHERE layer = 'silver'
  AND check_id IN ('S09', 'S10', 'S29', 'GS05', 'ASB05')
QUALIFY row_number() OVER (PARTITION BY table_name, source_key, check_id ORDER BY executed_at DESC) = 1
ORDER BY check_id, table_name, source_key;
```

**C. Controls at both layers** (the same published figure, checked in bronze and in silver):

```sql
SELECT layer, table_name, source_key, check_id, status, observed, expected, detail
FROM public_health.quality.qc_results
WHERE (layer = 'bronze' AND check_id = 'B11')
   OR (layer = 'silver' AND check_id IN ('S21', 'S34', 'S56', 'S64', 'S65', 'S78', 'S84'))
QUALIFY row_number() OVER (PARTITION BY layer, table_name, source_key, check_id, detail ORDER BY executed_at DESC) = 1
ORDER BY source_key, layer, check_id;
```

**D. Geography and boundaries:** the build output lines "Bronze snapshot rows / Silver snapshot rows" (geography) and "MERGE inserted / updated" (0 / 0 on a rerun), or GS05 and ASB05 in query B.

**What the evidence should show:** every `rows_loaded` in A equals the rows silver references (S09 PASS in B); every S10 and control PASS; S29 PASS, or WARN with the rows of section 4. Anything else is a finding to explain in [quality results and evidence](../quality/quality-results.md).
