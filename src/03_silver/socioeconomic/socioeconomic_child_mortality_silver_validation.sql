-- DRAFT | Socioeconomic Silver: Child Mortality (PSA Table 9.9)
-- Standalone, one-statement, READ-ONLY validation. No Delta or QC writes.
-- Grain of candidate records: (characteristic_group, characteristic, survey_year, mortality_metric)
WITH source_rows AS (
  SELECT b.*,
    CASE WHEN _source_row_num IN (5,23,26,33) THEN 'group_header'
         WHEN _source_row_num BETWEEN 6 AND 22 OR _source_row_num BETWEEN 24 AND 25
              OR _source_row_num BETWEEN 27 AND 32 OR _source_row_num BETWEEN 34 AND 38 THEN 'data'
         WHEN _source_row_num IN (41,42,43,44,46) THEN 'source_note'
         ELSE 'unexpected' END AS row_class
  FROM public_health.bronze.socioeconomic_psa_child_mortality_bronze b
  WHERE _source_key = 'psa_child_mortality'
),
with_groups AS (
  SELECT *,
    last_value(CASE WHEN row_class = 'group_header' THEN trim(characteristic_group) END, true)
      OVER (PARTITION BY _source_key, _source_file, _ingested_at
            ORDER BY _source_row_num ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
      AS group_name
  FROM source_rows
),
metric_cells AS (
  SELECT _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _ingested_at,
         group_name AS characteristic_group, trim(characteristic) AS characteristic,
         survey_year, mortality_metric, raw_value,
         CASE WHEN trim(raw_value) = '*' THEN 'suppressed'
              WHEN trim(raw_value) RLIKE '^[(][0-9]+([.][0-9]+)?[)]$' THEN 'low_precision'
              WHEN trim(raw_value) RLIKE '^[0-9]+([.][0-9]+)?$' THEN 'ok'
              WHEN raw_value IS NULL OR trim(raw_value) = '' THEN 'missing'
              ELSE 'unexpected' END AS value_status,
         try_cast(regexp_replace(trim(raw_value), '[()]', '') AS DOUBLE) AS mortality_rate_per_1000
  FROM (
    SELECT _source_key, _source_file, _source_sheet, _source_row_num, _as_of_date, _ingested_at,
           group_name, characteristic,
           stack(6,
             2022, 'infant', imr_2022,
             2017, 'infant', imr_2017,
             2022, 'child', cmr_2022,
             2017, 'child', cmr_2017,
             2022, 'under_five', u5mr_2022,
             2017, 'under_five', u5mr_2017
           ) AS (survey_year, mortality_metric, raw_value)
    FROM with_groups WHERE row_class = 'data'
  ) x
),
validation_gates AS (
  SELECT '01 | Bronze has exactly 39 physical rows' AS gate, abs(count(*)-39) AS failures FROM source_rows
  UNION ALL SELECT '02 | Physical positions exactly match source',
    (SELECT count(*) FROM source_rows WHERE _source_row_num IS NULL OR NOT (
       _source_row_num BETWEEN 5 AND 38 OR _source_row_num IN (41,42,43,44,46)))
    + abs(count(DISTINCT _source_row_num)-39) FROM source_rows
  UNION ALL SELECT '03 | Exactly four group headers', abs(count(*)-4) FROM source_rows WHERE row_class='group_header'
  UNION ALL SELECT '04 | Exactly thirty data rows', abs(count(*)-30) FROM source_rows WHERE row_class='data'
  UNION ALL SELECT '05 | Exactly five notes/source rows', abs(count(*)-5) FROM source_rows WHERE row_class='source_note'
  UNION ALL SELECT '06 | No unexpected source rows', count(*) FROM source_rows WHERE row_class='unexpected'
  UNION ALL SELECT '07 | One source file and ingestion version',
    CASE WHEN count(DISTINCT _source_file)=1 AND count(DISTINCT _ingested_at)=1 THEN 0 ELSE 1 END FROM source_rows
  UNION ALL SELECT '08 | Group header labels recognized', count(*) FROM source_rows
    WHERE row_class='group_header' AND (trim(characteristic_group) NOT IN
      ('Region','Residence',"Mother's Education",'Wealth quintile') OR characteristic IS NOT NULL)
  UNION ALL SELECT '09 | Data rows have characteristic', count(*) FROM with_groups
    WHERE row_class='data' AND (characteristic IS NULL OR trim(characteristic)='')
  UNION ALL SELECT '10 | Data rows carry correct group', count(*) FROM with_groups
    WHERE row_class='data' AND (group_name IS NULL OR
      CASE WHEN _source_row_num BETWEEN 6 AND 22 THEN group_name <> 'Region'
           WHEN _source_row_num BETWEEN 24 AND 25 THEN group_name <> 'Residence'
           WHEN _source_row_num BETWEEN 27 AND 32 THEN group_name <> "Mother's Education"
           ELSE group_name <> 'Wealth quintile' END)
  UNION ALL SELECT '11 | Exactly 180 metric cells', abs(count(*)-180) FROM metric_cells
  UNION ALL SELECT '12 | All metric formats recognized', count(*) FROM metric_cells WHERE value_status IN ('missing','unexpected')
  UNION ALL SELECT '13 | Precisely 165 ordinary numeric cells', abs(count(*)-165) FROM metric_cells WHERE value_status='ok'
  UNION ALL SELECT '14 | Precisely 10 low-precision cells', abs(count(*)-10) FROM metric_cells WHERE value_status='low_precision'
  UNION ALL SELECT '15 | Precisely 5 suppressed cells', abs(count(*)-5) FROM metric_cells WHERE value_status='suppressed'
  UNION ALL SELECT '16 | Numeric/null handling is faithful', count(*) FROM metric_cells
    WHERE (value_status='suppressed' AND mortality_rate_per_1000 IS NOT NULL)
       OR (value_status IN ('ok','low_precision') AND mortality_rate_per_1000 IS NULL)
  UNION ALL SELECT '17 | Unique complete grain and valid survey years/metrics',
    (SELECT count(*) FROM (
       SELECT characteristic_group, characteristic, survey_year, mortality_metric, count(*) n
       FROM metric_cells GROUP BY characteristic_group, characteristic, survey_year, mortality_metric
       HAVING count(*) <> 1 OR characteristic_group IS NULL OR characteristic IS NULL
          OR survey_year NOT IN (2017,2022) OR mortality_metric NOT IN ('infant','child','under_five')
     ) duplicate_keys)
    + abs(count(*)-180) FROM metric_cells
  UNION ALL SELECT '18 | PSA control values: NCR 2022 IMR=8, BARMM 2017 U5MR=55',
    CASE WHEN (SELECT count(*) FROM metric_cells WHERE characteristic_group='Region' AND characteristic='NCR'
                    AND survey_year=2022 AND mortality_metric='infant' AND mortality_rate_per_1000=8)=1
            AND (SELECT count(*) FROM metric_cells WHERE characteristic_group='Region' AND characteristic='BARMM'
                    AND survey_year=2017 AND mortality_metric='under_five' AND mortality_rate_per_1000=55)=1
         THEN 0 ELSE 1 END
)
SELECT gate, failures,
       CASE WHEN failures=0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM validation_gates ORDER BY gate;
