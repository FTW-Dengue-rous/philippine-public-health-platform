# Headline figures: evidence run

Owner: Jemma
Last updated: 2026-10-21

Recorded results of `docs/06-evidence/headline_figures.sql` (H1–H5) against `public_health.gold`, run on 2026-10-21 after final run 3. These are the values the root README section "What the data shows" must quote. One screenshot per query, numbered in query order.

---

## 1. Results

| Query | Screenshot | Columns returned | Value | Matches README (main @ 3d1d65a) |
|---|---|---|---|---|
| H1 | `1_h1.png` | `localities_without_hospital`, `localities`, `pct`, `population_without_hospital` | 1,114 of 1,642 (67.8%); 38,133,083 people | Yes |
| H2 | `2_h2.png` | `localities_without_licensed_primary_care`, `localities_with_neither` | 924; 678 | Yes |
| H3 | `3_h3.png` | `provinces_without_level3`, `provinces`, `median_km_to_level3` | 58 of 82; 66 km | No: README says 45 km |
| H4 | `4_h4.png` | `beds_per_10k_national` | 11.1 | No: README says 8.0 |
| H5 | `5_h5.png` | `poverty_group`, `provinces`, `beds_per_10k` | under 10%: 35 provinces, 9.3; 20-30%: 13 provinces, 6.8 | No: README says 10.3 vs 6.2 |

Restricted data: counts, rates and distances only (D-47).

## 2. Why three values differ

The README stated on 2026-10-19 that H3, H4 and H5 were "the team's presented dashboard values", taken from the 2026-10-17 dashboard on `test_gold2`. H1 and H2 were verified against gold on 2026-10-19 and still match. The other three were never run against `public_health.gold` until now. Per the revision checklist (E1), the README now quotes the query values.

| Query | Presented value | Query value | Reading |
|---|---|---|---|
| H3 | 45 km | 66 km | 45 km is the median over all 1,634 localities with a distance (`fact_area_access`, as built 2026-10-14). The H3 query returns the median in the same row as the 58 provinces, so it reads as the median for localities in provinces with no Level 3 hospital. Both are correct for their own set; the README wording follows the query |
| H4 | 8.0 | 11.1 | 11.1 = 124,667 registry beds × 10,000 ÷ national population (124,667 ÷ 112.1 M). The presented 8.0 used a narrower bed set (about 90,000 beds); the dashboard definition was not recorded. The README quotes the all-registry-beds value and names it as such |
| H5 | 10.3 vs 6.2 | 9.3 vs 6.8 | Same direction, different values. The query groups 35 + 13 provinces by poverty band from `mart_area_service_profile`; the presented pair came from the 2026-10-17 dashboard on `test_gold2`, before the gold pass of 2026-10-18 changed the planning-unit population and the band boundaries. The README quotes the query |

What stays true in every case: the direction of each finding (two-thirds of localities without a hospital, most provinces without a Level 3, fewer beds per resident in poorer provinces) is unchanged.

To do if time allows (not tonight): record the dashboard widget definitions behind the presented 8.0 and 10.3/6.2 so the two sets can be reconciled, or point the widgets at the same marts the queries read.

## 3. Files

```
2026-10-21-headline-figures/
├── README.md     this record
├── 1_h1.png      H1: localities without a hospital
├── 2_h2.png      H2: localities without licensed primary care, and with neither
├── 3_h3.png      H3: provinces without a Level 3 hospital, median distance
├── 4_h4.png      H4: registry beds per 10,000 residents, national
└── 5_h5.png      H5: beds per 10,000 by poverty band
```

## 4. History of updates

| Date | Change |
|---|---|
| 2026-10-21 | H1–H5 run against `public_health.gold` after final run 3; five screenshots recorded; three README values corrected to the query values (E1 of the revision checklist) |
