# Runbook and verification

Owner: LUNASaan project team
Last updated: 2026-10-21

## Supported verification on `main`

Prerequisites: Python 3.11 and the dependencies in `requirements.txt` and `requirements-dev.txt`.

```powershell
pip install -r requirements.txt -r requirements-dev.txt
pytest
pre-commit run --all-files
```

Expected outcome: the structural test confirms intended layer folders exist; lint and hygiene checks report repository issues. This does **not** validate data, source access, transformation logic, quality results, or a dashboard.

## Databricks setup boundary

`setup/01_create_schemas.sql` can create the bronze, silver, and gold schemas after replacing `ph_public_health` with an approved catalog. Confirm catalog permission first. Do not run empty layer setup scripts as if they create a pipeline.

## Not yet executable

There is no official end-to-end execution order, parameter set, expected table output, reconciliation result, recovery procedure, or idempotency evidence in `main`. Do not claim these properties until the corresponding implementation and recorded evidence exist.

## Failure response

If repository checks fail, fix the reported source/configuration issue and rerun the same check. If a future data build fails, preserve logs and inputs; do not hand-edit published tables. Record the incident, evidence, correction, rerun order, and prevention control.
