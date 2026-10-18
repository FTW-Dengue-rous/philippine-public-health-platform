# CI/CD setup

Owner: Jemma Santiago
Last updated: 2026-10-15

CI/CD is implemented with GitHub Actions and Databricks Asset Bundles. The full reference is in [CI/CD and testing](../07-operations/ci-cd-and-testing.md).

## Summary

* **CI** (`.github/workflows/ci.yml`): runs on every push and PR to `dev`/`main`. Lint (ruff), test (pytest), SQL lint (sqlfluff), secret scan (gitleaks), repo hygiene (large files, notebook outputs).
* **CD** (`.github/workflows/cd.yml`): deploys the DABs bundle after CI passes. `dev` push → dev target, `main` push → prod target (with manual approval gate).
* **PR hygiene** (`.github/workflows/pr-hygiene.yml`): auto-labels PRs based on changed paths.
* **Bundle** (`databricks.yml`): deploys `src/` and `config/` to the workspace. Excludes `archive/`, `docs/`, `data/`, `tests/`, `dashboard/`, `presentation/`, and ingestion notebooks.
