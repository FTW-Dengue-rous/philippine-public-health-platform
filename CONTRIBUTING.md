# Contributing

## Workflow
1. Pull latest `dev`: `git checkout dev && git pull`
2. Create a branch: `git checkout -b feature/<short-name>`
3. Commit, push, and open a PR into `dev`
4. All CI checks must be green + 1 approval before merging
5. Delete the branch after merge
6. Every end of week/when we finish a milestone (e.g. bronze, silver, gold), merge `dev` into `main`

## Branch names
`feature/…` new work · `fix/…` bug fix · `docs/…` docs only · `chore/…` setup/cleanup

## PR titles (checked automatically)
Format: `type: description`

| Type | Use for |
|---|---|
| `feat` | new ingestion, table, or feature |
| `fix` | bug fix |
| `docs` | documentation only |
| `test` | adding tests |
| `ci` | GitHub Actions / tooling |
| `chore` | setup, cleanup, config |
| `refactor` | restructure without changing behavior |

Example: `feat: add dengue cases ingestion`

## Local checks (required)
Run once after cloning:
```bash
pip install -r requirements-dev.txt
pre-commit install
```
Checks (ruff lint + format, end-of-file newline, trailing whitespace, sqlfluff, nbstripout, gitleaks) then run automatically on every `git commit` and auto-fix what they can. If a commit is blocked, `git add` the fixed files and commit again.

- Check the whole repo anytime: `pre-commit run --all-files`
- Don't skip hooks with `git commit --no-verify`
- Commits made from a Databricks Git folder or the GitHub web editor skip the hooks. Before opening a PR, pull your branch locally, run `pre-commit run --all-files`, and commit any fixes. CI runs the same checks on every PR to `dev`/`main`
- Keep the ruff version in `requirements-dev.txt` and `.pre-commit-config.yaml` the same

## Rules
- Never commit secrets, tokens, or `.env` files
- Never commit full datasets — only small samples in `data/sample/`
- Clear notebook outputs before committing
