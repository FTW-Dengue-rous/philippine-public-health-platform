# CD setup — Databricks Asset Bundles + GitHub Actions

## Flow

```
feature/* ──PR──> dev ──push──> CI ✅ ──> CD: bundle deploy -t dev
dev       ──PR──> main ─push──> CI ✅ ──> CD: bundle deploy -t prod  (runs as service principal)
```

CD only fires after the **CI** workflow succeeds on a push. If CI fails, nothing deploys.

## Files

| File | Purpose |
|---|---|
| `databricks.yml` | Bundle root: targets `dev` / `prod`, sync excludes |
| `resources/ph_public_health_job.yml` | The pipeline job (ingestion → bronze → silver), serverless |
| `.github/workflows/cd.yml` | Deploys the bundle after CI passes |

## One-time setup

### 1. Service principal (workspace admin)
1. Workspace **Settings → Identity and access → Service principals → Add** → name it `ph-public-health-cicd`.
2. Open it → **Secrets → Generate secret**. Copy the **Client ID** (= Application ID) and **Secret** (shown once).
3. Give it **Workspace access** (and **Databricks SQL access** if you add SQL tasks later).

### 2. Unity Catalog grants (run in a SQL editor as an admin/owner)
Replace `<app-id>` with the SP's Application ID.

```sql
GRANT USE CATALOG, USE SCHEMA, CREATE SCHEMA, CREATE TABLE, MODIFY, SELECT
  ON CATALOG public_health TO `<app-id>`;
GRANT READ VOLUME, WRITE VOLUME ON VOLUME public_health.bronze.landing TO `<app-id>`;
-- Landing volume in config/sources*.yaml lives in the `workspace` catalog too:
GRANT USE CATALOG ON CATALOG workspace TO `<app-id>`;
GRANT USE SCHEMA, READ VOLUME, WRITE VOLUME ON SCHEMA workspace.default TO `<app-id>`;
```

### 3. GitHub Environments + secrets
Repo **Settings → Environments** → create `dev` and `prod`. Add to **each**:

| Secret | Value |
|---|---|
| `DATABRICKS_HOST` | `https://<your-workspace-host>` |
| `DATABRICKS_CLIENT_ID` | SP Application ID |
| `DATABRICKS_CLIENT_SECRET` | SP secret |

On `prod`: set **Deployment branches → Selected: `main`**. Optional: **Required reviewers** = manual approval before prod deploys.

### 4. Fill the TODOs
- `databricks.yml` → `workspace.host` (both targets), `run_as.service_principal_name`, `permissions` (teammates).
- `resources/ph_public_health_job.yml` → confirm `depends_on` order; pick one population bronze notebook and uncomment.
- Add `.databricks/` to `.gitignore`.

### 5. Test locally before relying on CI
```bash
databricks auth login --host https://<your-workspace-host>
databricks bundle validate -t dev
databricks bundle deploy -t dev
databricks bundle run -t dev ph_public_health_pipeline
```

### 6. Merge `cd.yml` to `main` first
GitHub only fires `workflow_run` triggers from workflow files on the **default branch**. Until `cd.yml` is on `main`, pushes to `dev` won't deploy. Manual run is available anytime: **Actions → CD → Run workflow**.

## Known gap: dev and prod share tables
Both targets deploy separate *jobs*, but the code writes to the same hardcoded tables (`public_health.*` in `config/sources*.yaml`). Running the dev job overwrites prod data. Fix later by passing a `catalog` job parameter per target (e.g. `public_health_dev` vs `public_health`) and reading it in the loaders.
