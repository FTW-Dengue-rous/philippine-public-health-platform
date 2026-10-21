# Quality checks

Owner: LUNASaan Documentation Team
Last updated: 2026-10-21

Quality-check scripts for bronze, silver and gold, the preload gate, and the quality registry.

Files and folders:
1. `dq_utils.py` — shared library for QC runs (DQRun, check registry helpers).
2. `bronze/` — bronze QC scripts per domain and `bronze_gate.py` (preload gate).
3. `silver/` — silver QC scripts per domain.
4. `gold/` — gold QC (`gold_qc.py`, checks G00-G13).
5. `sql/` — `quality_registry_seed.sql` (registry seed) and `quality_registry_check.sql` (registry check).

Job tasks: `gate_<domain>` (bronze gate), `<domain>_silver_qc` (silver QC), `gold_qc` (gold QC), `qc_registry` (registry check, last task).

Docs: [quality check catalog](../../docs/04-pipeline/quality/quality-check-catalog.md).
