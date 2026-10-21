# Dashboard on public_health.gold (2026-10-21)

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Record of the dashboard definition that reads the gold layer built by the [final runs](../2026-10-21-final-runs/README.md).

| Item | Value |
|---|---|
| Dashboard | Philippine Public Health Platform (`dashboard/Philippine Public Health Platform.lvdash.json`), deployed by the bundle |
| Pages | 8: 0. National Overview · 1. Need · 2. Access to early care · 3. Gaps and equity · 4. Reported care (PhilHealth claims) · 5. Case studies · 6. Preparedness · 7. About the data |
| Datasets | 46, all reading `public_health.gold` (none read `test_gold2`); every dataset is used by a widget |
| Changes on 2026-10-21 | `test_gold2` → `gold` in every dataset. One set of 8 pages kept: the redesigned pages 0–4 and pages 5–7; removed "0. National Overview - Backup", "5. Case studies … - for redesign" and the five earlier copies of pages 0–4. `model` removed from the P7 pipeline-status table (the column left `mart_evidence_readiness` in the gold pass). 18 datasets no widget used were removed (backup, duplicate and test datasets). Page 7 renamed "7. About the data" |
| Check | **Not yet captured.** After deploy, open every page and save one screenshot per page here |

## Screenshots (to capture)

One per page, named `p<n>_<yyyy-mm-dd>.png`: `p0` National Overview, `p1` Need, `p2` Access to early care, `p3` Gaps and equity, `p4` Reported care, `p5` Case studies, `p6` Preparedness, `p7` About the data. Add an image link for each when saved.

## History of updates

| Date | Change |
|---|---|
| 2026-10-21 | Record written: dashboard definition switched to `public_health.gold`; page screenshots still to capture |
