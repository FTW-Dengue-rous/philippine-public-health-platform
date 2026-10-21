# CI/CD and testing

Owner: Jemma Santiago
Last updated: 2026-10-21

This page describes the checks that protect the repository and the deployment path for the Databricks Asset Bundle. Pipeline data-quality checks run in Databricks; they are not CI tests.

## Branching and pull requests

- `dev` is the active integration branch. Pull requests target `dev`.
- `main` is the stable release branch.
- Use the branch and pull-request conventions in [CONTRIBUTING.md](../../CONTRIBUTING.md).
- Run the local checks before opening a pull request. Commits made from a Databricks Git folder or the GitHub editor do not run local hooks.

## Continuous integration

[`ci.yml`](../../.github/workflows/ci.yml) runs on pushes and pull requests for `dev` and `main`.

| Job | What it checks |
|---|---|
| `lint` | Ruff linting and formatting, end-of-file newlines, and trailing whitespace. Same-repository PRs may receive an auto-fix commit. |
| `test` | `pytest --cov=src --cov-report=term-missing`. |
| `sql-lint` | SQLFluff 4.3.0 over tracked SQL files outside `archive/`. |
| `secrets` | Redacted Gitleaks scan of Git history. |
| `repo-hygiene` | Tracked files over 5 MB and notebooks with saved outputs. |

Run the equivalent local checks:

```bash
pip install -r requirements.txt -r requirements-dev.txt
pre-commit install
pre-commit run --all-files
pytest --cov=src --cov-report=term-missing
```

## Continuous deployment

[`cd.yml`](../../.github/workflows/cd.yml) deploys only after a successful CI run triggered by a push. A push to `dev` deploys the `dev` bundle target; a push to `main` deploys `prod`. Manual dispatch can select either target. The workflow checks out the commit CI tested, authenticates with the Databricks CLI, validates the bundle, deploys it, and writes a summary.

The GitHub Environment for each target must supply `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, and `DATABRICKS_CLIENT_SECRET`. `AUTOFIX_TOKEN` is optional for CI auto-fix commits. Protect the production environment with the required reviewers configured in GitHub.

## What CI does not prove

CI does not execute the Databricks pipeline, inspect restricted source data, prove dashboard rendering, or validate data-quality outcomes. A deploy is also not a successful pipeline run. Use the [runbook](runbook.md), [quality results](../04-pipeline/quality/quality-results.md), and saved run evidence for those claims.

## Current automated-test coverage

The current repository test is a smoke test for the expected project folders. It confirms that pytest is configured, but it does **not** validate loader parsing, geography matching, metric formulas, or quality-gate failure behavior. Treat the Databricks run evidence as execution evidence, not as a replacement for automated tests.

Before a production handover, add deterministic fixture-based tests for at least: a valid and an invalid Bronze header, duplicate and missing-value disposition, one geography-map exception, a published Gold metric calculation, and a FAIL-level gate that stops its downstream build. Add a CI coverage threshold after those tests exist.
