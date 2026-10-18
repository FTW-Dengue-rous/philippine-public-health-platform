# CI/CD and testing

Owner: Jemma Santiago
Last updated: 2026-10-15

## Branching

* `dev` — active development. PRs target this branch.
* `main` — stable release. Merged from `dev` at milestones.
* Branch names: `feature/...`, `fix/...`, `docs/...`, `chore/...`.
* PR titles: `type: description` (feat, fix, docs, test, ci, chore, refactor).

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for the full workflow.

## CI pipeline (`.github/workflows/ci.yml`)

Runs on every push and PR to `dev`/`main`.

| Job | What it does | Tool |
|---|---|---|
| lint | Python lint and format. Auto-fixes on same-repo PRs, pushes fix commit. | ruff (via pre-commit) |
| test | Unit tests with coverage. | pytest --cov=src |
| sql-lint | SQL style and best practices. | sqlfluff 4.3.0 |
| secrets | Scan git history for leaked secrets. | gitleaks (redacted output) |
| repo-hygiene | Block files over 5 MB. Block notebooks with saved outputs. | Custom Python |

### Local checks

```bash
pip install -r requirements-dev.txt
pre-commit install
pre-commit run --all-files  # check the whole repo
```

Hooks: ruff lint + format, end-of-file newline, trailing whitespace, sqlfluff, nbstripout, gitleaks. These run automatically on `git commit`.

Commits from Databricks Git folders or GitHub web editor skip hooks. Before opening a PR, pull locally and run `pre-commit run --all-files`.

## CD pipeline (`.github/workflows/cd.yml`)

Deploys the Databricks bundle after CI passes on a push.

* `push to dev` → CI green → deploy to `dev` target.
* `push to main` → CI green → deploy to `prod` target (with manual approval via GitHub Environment reviewer).
* Manual dispatch: `workflow_dispatch` with `target` input (dev or prod).

CD steps:

1. Checkout the exact commit CI tested.
2. `databricks current-user me` (auth check).
3. `databricks bundle validate -t <target>`.
4. `databricks bundle deploy -t <target>`.
5. Post a deploy summary.

### Required secrets (GitHub Environments)

| Secret | Target | Description |
|---|---|---|
| `DATABRICKS_HOST` | dev, prod | Workspace URL |
| `DATABRICKS_CLIENT_ID` | dev, prod | Service principal application ID |
| `DATABRICKS_CLIENT_SECRET` | dev, prod | Service principal OAuth secret |
| `AUTOFIX_TOKEN` | — | PAT for auto-fix commit push-back on PRs |

## PR hygiene (`.github/workflows/pr-hygiene.yml`)

Auto-labels PRs based on changed paths (e.g. `src/02_bronze/` → `bronze`). Uses `.github/labeler.yml`.

## Tests

### Unit tests

* `tests/test_smoke.py` — checks that expected project folders exist (`src/00_setup` through `src/04_gold`).
* Run: `pytest --cov=src --cov-report=term-missing`.

**Limitation**: The smoke test is a placeholder. It does not test pipeline logic, data quality, or SQL correctness. Local tests do not prove Databricks runtime behavior.

### SQL tests

SQL linting via sqlfluff catches style and syntax issues. There are no SQL unit tests. SQL correctness is validated by:
* Silver build scripts' internal validation gates (null keys, duplicate keys, lineage completeness).
* Bronze QC control totals.
* Row count reconciliation (silver rows + disposition rows = bronze input rows).

### Databricks runtime tests

The pipeline job itself is the integration test. A successful run with expected row counts and no ERROR QC failures is the validation. Build outputs are recorded in `build_log` and `build_inputs` for reproducibility.

## What is NOT tested

* No automated end-to-end test in CI (would require Databricks compute).
* No data quality assertions in CI (they run in the pipeline job).
* No dashboard rendering test.
* The `facilities_osm_point_silver` table is not verified to exist.
