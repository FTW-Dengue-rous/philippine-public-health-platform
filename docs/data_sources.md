# Source register

Owner: LUNASaan project team
Last updated: 2026-10-21
Scope: sources evidenced by the `main` repository only.

| Source key | Provider | Version / coverage | Intended use | Repository evidence |
|---|---|---|---|---|
| `psgc` | Philippine Statistics Authority, Philippine Standard Geographic Code | `Q2_2024`; endpoint `all` | Geographic reference and code standardisation | URL, Databricks landing path, bronze target, and metadata target in `config/sources.yaml`; no retrieval/load evidence is committed |

Facility, population, disease-burden, and socioeconomic sources needed for BQ1 are not registered on `main`. Before use, record provider, access/licence, retrieval date, version, coverage, geographic grain, unit, denominator, limitations, owner, and downstream object.

No source is decision-ready until its definition and restrictions are recorded, the landing asset is versioned or checksummed, and a published result can be traced back to it.
