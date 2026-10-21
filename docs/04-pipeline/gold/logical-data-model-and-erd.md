# Gold logical model and ERD

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

The logical model is a star schema. Facts join to `dim_geography`, `dim_date`, and `dim_data_source`; disease facts also join to `dim_disease`. `dim_facility` describes the registry and joins to geography rather than to a fact.

```text
dim_geography ─┬─ fact_facility_capacity
dim_date ──────┼─ fact_disease_metric ─ dim_disease
dim_data_source┼─ fact_workforce_capacity
               └─ fact_area_indicator

dim_geography ── dim_facility
```

Every table's grain, primary key, source inputs, and consumers are in the [table catalog](table-catalog.md). Column meanings and the natural-key rules are in the [technical data dictionary](gold-data-dictionary.md). Do not join facts or aggregate values until the source, coverage basis, period, and grain are compatible; the [gold usage rules](gold-usage-rules.md) are mandatory for analysis.
