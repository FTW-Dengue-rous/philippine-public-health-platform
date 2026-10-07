# Setup

One-time scripts that prepare the Databricks environment. Run in order before the pipeline.

1. `01_create_schemas.sql` — catalog schemas for each medallion layer

Replace `public_health` with your team's catalog name if different.
