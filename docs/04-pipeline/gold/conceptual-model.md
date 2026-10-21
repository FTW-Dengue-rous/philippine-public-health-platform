# Gold conceptual model

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Gold turns cleaned silver data into analysis for BQ1: gaps in health-service availability relative to population, selected disease burden, and socioeconomic conditions. BQ2 remains previous scope.

The model keeps five shared dimensions—geography, date, data source, facility, and disease—and four facts: facility capacity, disease metrics, workforce capacity, and area indicators. Marts combine only comparable records for a specific question. They do not make sources with different coverage or periods equivalent.

| Data concern | Gold object family | Important rule |
|---|---|---|
| Where | `dim_geography` | A planning unit is a province excluding its HUCs, an HUC, or NCR. |
| When | `dim_date` | The source reporting period is retained; annual, weekly, and snapshot values are not silently converted. |
| Source and meaning | `dim_data_source`, facts | Source is part of a fact's grain. |
| Supply, burden, workforce, equity | Four facts and marts | Rates use a named denominator and remain null when comparison is not valid. |

Gold reads silver only. Each table build writes a candidate, checks it, publishes it only if its gates pass, and records its input lineage. Views and marts read the published tables at query time. See the [gold overview](README.md), [logical model and ERD](logical-data-model-and-erd.md), and the source-of-truth [engineering README](../../../src/04_gold/README.md).
