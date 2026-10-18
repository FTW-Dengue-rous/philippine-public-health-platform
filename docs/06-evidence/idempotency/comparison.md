# Idempotency comparison

Owner: LUNASaan Documentation Team
Last updated: 2026-10-18

The platform is designed for idempotent rebuilds: running the same silver or gold build with the same inputs should produce the same output.

## How idempotency works

* **Bronze**: Incremental loader. Unchanged files are skipped, so bronze rows and load IDs stay the same.
* **Silver**: `CREATE OR REPLACE` with the complete new state. Validation gates check null keys, duplicate keys, and lineage completeness. If validation fails, the target is left unchanged.
* **Gold**: `CREATE OR REPLACE` from silver inputs. Deterministic given the same silver tables.
* **Build IDs**: Each build gets a new UUID, but the data content should match if inputs are the same.

## Verified behavior

* Facilities silver v1.7 SQL builds were run on Databricks (2026-10-10 to 2026-10-12) and produced consistent row counts: id_map 5,254, registry 3,954, metric 2,988, BOR 1,977.
* The registry build was run twice (10:02 and 10:04 on 2026-10-10) and both produced the same counts.
* Delta time travel preserves previous versions: `DESCRIBE HISTORY` shows target_table_version 1, 2 for rebuilds.

*(Source: Databricks build_log, 2026-10-10. Two registry builds with identical row counts.)*

## What to check after a rebuild

```sql
-- Compare row counts
SELECT 'before' as run, count(*) FROM public_health.silver.<table> VERSION AS OF <old_version>
UNION ALL
SELECT 'after' as run, count(*) FROM public_health.silver.<table>;

-- Compare key distributions
SELECT ownership, count(*) FROM public_health.silver.<table> GROUP BY ownership;
```

If row counts or key distributions differ, check for changed source files or YAML config changes.
