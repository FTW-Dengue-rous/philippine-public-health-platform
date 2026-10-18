# Bronze quality checks

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

Bronze QC runs inside `run_bronze.py` after each source loads. It is implemented in `src/05_quality/bronze/` using `dq_utils.DQRun`. A QC failure with ERROR severity raises an exception that fails the task and stops downstream execution.

## Check IDs

| Check | Rule | Severity | Expected result | Failure action |
|---|---|---|---|---|
| B02 | Row count matches `expected_rows` in YAML | ERROR | Actual = expected | Fail task, stop downstream |
| B03 | No nulls in key columns | ERROR | 0 nulls | Fail task, stop downstream |
| B06 | Numeric columns are numeric | ERROR | 0 non-numeric values | Fail task, stop downstream |
| B08 | No rescued data (`_rescued_data` is null) | WARN | 0 rescued values | Record warning, continue |
| B09 | Control totals match (e.g. sum of cases per year) | ERROR | Actual = expected | Fail task, stop downstream |
| B11 | Required columns exist | ERROR | All present | Fail task, stop downstream |
| B12 | Header check passes | ERROR | Headers match YAML | Fail task, stop write |
| B14 | Each file gives at least one data row | ERROR | 1 or more rows | Fail task, stop write |

## Per-source configuration

Checks are configured per source in the YAML `qc:` section. Not all checks apply to all sources. For example:

* `skip_checks: [B08]` skips the rescued-data check for sources with known multi-line fields.
* `severity: {B03: WARN}` downgrades null-key failures to warnings for sources with known nulls.
* `expected_rows` is set in the YAML for sources where the row count is known. Sources with variable row counts omit this check.
* `control_totals` verify aggregate values (e.g. sum of dengue cases by year) against values confirmed from the source file at config time.

## Results storage

QC results are stored in `public_health.quality.qc_results`. Key columns: `validation_id`, `source_key`, `table_name`, `layer`, `check_id`, `check_name`, `check_type`, `status` (PASS/WARN/FAIL), `severity` (WARN/FAIL), `fail_count`, `total_count`, `fail_pct`, `threshold`, `observed`, `expected`, `executed_at`, `detail`.

## Verified results

Bronze QC ran for all domains during the 2026-10 builds. Most checks show status PASS. A small number of early runs recorded FAIL for the "QC ran without error" check (the QC script itself errored); these were corrected. See [quality results](../quality/quality-results.md) for verified outcomes.

Notable control total verifications:

* `doh_foi_dengue`: Sum of cases by year matches (2021: 80,919, 2022: 264,390, 2023: 214,638, 2024: 413,960, 2025: 240,540).
* `psa_poverty`: 2025 Philippines poverty incidence (9.7), threshold (35,120.89), poor population (11,083.03) all match.

## How to add a new check

1. Add the check logic to the `DQRun` class in `dq_utils.py`.
2. Configure it in the source YAML `qc:` section.
3. Run `run_bronze.py --domains <domain> --force_keys <source_key>` to test.
4. Check `qc_results` for the outcome.

See [quality control framework](../quality/quality-control-framework.md) for the framework overview and [quality check catalog](../quality/quality-check-catalog.md) for the complete check list across all layers.