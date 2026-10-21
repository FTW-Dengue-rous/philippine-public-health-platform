# Data dictionary

Owner: LUNASaan project team
Last updated: 2026-10-21
Scope: names and purposes evidenced by `main`; this does not claim that tables have been built.

| Object | Layer | Grain / key | Status and evidence |
|---|---|---|---|
| `public_health.bronze.psgc` | Bronze | Not defined on `main` | Intended target in `config/sources.yaml`; columns, schema and load output are absent |
| `public_health.bronze.ingestion_metadata` | Bronze | Not defined on `main` | Intended metadata target in `config/sources.yaml`; columns, schema and load output are absent |

Before any future table is used, add an authoritative contract with purpose, grain, keys, column types, nullable rules, unit, denominator, ranges, source, transformation, geographic/time coverage, refresh, owner, classification, and quality checks.

No rate, per-population, capacity, distance, priority, or disease-burden metric is defined or produced by `main`. A future metric must state formula, numerator, denominator, unit, periods, geography, exclusions, and interpretation warning. A missing denominator produces a missing metric, not zero.
