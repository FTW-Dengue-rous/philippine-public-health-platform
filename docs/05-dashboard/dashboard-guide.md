# Dashboard on public_health.gold (2026-10-21)

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Record of the dashboard definition that reads the gold layer built by the [final runs](../06-evidence/2026-10-21-final-runs/README.md). For pages, filters, freshness and interpretation, see the full [dashboard guide](../../dashboard/dashboard-guide.md); this page only records the switch to `public_health.gold`.

| Item | Value |
|---|---|
| Dashboard | Philippine Public Health Platform (`dashboard/Philippine Public Health Platform.lvdash.json`), deployed by the bundle |
| Pages | 8 in the definition; 6 published (0–4 and 7); 5 (Case studies) and 6 (Preparedness) are drafts excluded from the published view (`excludeFromPublished`) |
| Datasets | 46, all reading `public_health.gold` (none read `test_gold2`); every dataset is used by a widget |
| Changes on 2026-10-21 | `test_gold2` → `gold` in every dataset. One set of 8 pages kept: the redesigned pages 0–4 and pages 5–7; removed "0. National Overview - Backup", "5. Case studies … - for redesign" and the five earlier copies of pages 0–4. `model` removed from the P7 pipeline-status table (the column left `mart_evidence_readiness` in the gold pass). 18 datasets no widget used were removed (backup, duplicate and test datasets). Page 7 renamed "7. About the data" |
| Check | Pages 0, 2, 3 and 4 captured: [dashboard evidence](../06-evidence/2026-10-21-dashboard/README.md). Pages 1 and 7 still to capture. |

## History of updates

| Date | Change |
|---|---|
| 2026-10-21 | Record written: dashboard definition switched to `public_health.gold`; page screenshots still to capture |
| 2026-10-21 | Final-runs link fixed (`../06-evidence/...`); pointer added to the full guide in `dashboard/dashboard-guide.md` |
| 2026-10-21 | Pages row corrected: 6 published, 5 and 6 are drafts. Check row links to evidence (pages 0, 2, 3, 4 captured). Screenshots section removed (duplicates evidence page) |
