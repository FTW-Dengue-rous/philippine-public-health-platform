# =============================================================================
# Shared helper for every QC script (bronze, silver, gold). Writes to the
# public_health.quality schema created by quality_setup.sql.
#
# What it writes (append-only, so domains can run QC at the same time)
#   quality.qc_results    one row per check result          -> record()
#   quality.run_log       one row per QC execution          -> written on exit
#   quality.profile       one row per column of a table     -> profile_table()
#   quality.table_stats   row count / Delta version / size  -> capture_table_stats()
#   quality.quarantine    rejected rows as JSON             -> quarantine()
#
# Usage
#   from dq_utils import DQRun
#
#   with DQRun(layer="silver", domain="diseases",
#              script_name="diseases_silver_qc.py", job_run_id=args.job_run_id) as dq:
#       t = "public_health.silver.diseases_metric_silver"
#       total = dq.capture_table_stats(t)
#       dq.profile_table(t)
#       dq.record("S01", table_name=t, status="PASS" if total > 0 else "FAIL",
#                 observed=total, expected="> 0")
#       dq.record("S03", table_name=t, fail_count=dup_rows, total_count=total)  # status computed
#   # On exit: results and the run_log row are written; raises if any check is FAIL.
#   # If the script crashes, a B00/S00/G00 FAIL row and an ERROR run_log row are written.
#
# Rules
#   * Registry is OPTIONAL for now (strict_registry=False, the default):
#       - code in quality.check_registry -> name, type, severity, threshold come from it
#       - code not in the registry       -> pass check_name and check_type yourself;
#         the code is listed as "unregistered" at the end of the run
#     Build the registry at the end (quality_registry_seed.sql), then switch to
#     strict_registry=True so unknown codes are rejected.
#   * Pass status yourself, or pass fail_count (+ total_count) and it is computed:
#     PASS if fail_pct <= threshold, otherwise the check's severity (WARN or FAIL).
#   * job_run_id: in a Databricks job, pass {{job.run_id}} as a task parameter.
#
# Requires: pyspark (Databricks runtime).
# =============================================================================

import uuid
from datetime import datetime, timezone

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

DQ_SCHEMA = "public_health.quality"
LAYER_PREFIX = {"bronze": "B", "silver": "S", "gold": "G"}
STATUSES = ("PASS", "WARN", "FAIL")

RESULTS_SCHEMA = (
    "run_id string, validation_id string, batch_id string, source_key string, table_name string, "
    "layer string, executed_at timestamp, check_id string, check_name string, check_type string, "
    "column_name string, admin_level int, status string, severity string, fail_count bigint, "
    "total_count bigint, fail_pct double, threshold double, observed string, expected string, "
    "detail string")
RUN_LOG_SCHEMA = (
    "validation_id string, run_id string, layer string, domain string, script_name string, "
    "source_keys string, started_at timestamp, ended_at timestamp, status string, checks_total int, "
    "checks_pass int, checks_warn int, checks_fail int, tables_checked int, code_version string, "
    "error_message string")
PROFILE_SCHEMA = (
    "run_id string, validation_id string, layer string, table_name string, row_filter string, "
    "column_name string, data_type string, row_count bigint, null_count bigint, null_pct double, "
    "blank_count bigint, distinct_count bigint, min_value string, max_value string, "
    "profiled_at timestamp")
STATS_SCHEMA = (
    "run_id string, validation_id string, layer string, table_name string, delta_version bigint, "
    "row_count bigint, column_count int, num_files bigint, size_bytes bigint, captured_at timestamp")


def _now():
    # UTC without tzinfo, matching how the other loaders store timestamps.
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _text(value, limit):
    return None if value is None else str(value)[:limit]


def _q(col):
    return "`" + col.replace("`", "``") + "`"


class DQRun:
    """One QC execution (validation session). Use it as a context manager."""

    def __init__(self, layer, domain, script_name, job_run_id=None, source_keys="ALL",
                 fail_on_error=True, code_version=None, dq_schema=DQ_SCHEMA, spark=None,
                 strict_registry=False):
        if layer not in LAYER_PREFIX:
            raise ValueError(f"layer must be one of {list(LAYER_PREFIX)}, got {layer!r}")
        self.spark = spark or SparkSession.builder.getOrCreate()
        self.layer = layer
        self.domain = domain
        self.script_name = script_name
        self.source_keys = source_keys if isinstance(source_keys, str) else ",".join(source_keys)
        self.fail_on_error = fail_on_error
        self.code_version = code_version
        self.schema = dq_schema
        self.validation_id = str(uuid.uuid4())
        self.run_id = str(job_run_id) if job_run_id else self.validation_id
        self.started_at = _now()
        self.results, self.profiles, self.stats = [], [], []
        self._finished = False
        self.strict_registry = strict_registry
        self.unregistered = set()                               # codes used but not in the registry
        try:
            self.registry = {
                r["check_id"]: r.asDict()
                for r in self.spark.table(f"{dq_schema}.check_registry").where("is_active").collect()
            }
        except Exception:                                       # registry table not created yet
            if strict_registry:
                raise
            self.registry = {}
        print(f"DQ {layer}/{domain}: validation_id={self.validation_id} run_id={self.run_id}")

    # -------------------------------------------------------------------------
    # Check results
    # -------------------------------------------------------------------------

    def record(self, check_id, table_name=None, status=None, source_key=None, batch_id=None,
               column_name=None, admin_level=None, fail_count=None, total_count=None,
               threshold=None, observed=None, expected=None, detail=None,
               check_name=None, check_type=None, severity=None, skip=()):
        """Store one check result. Returns the status written (None if skipped)."""
        if check_id in (skip or ()):
            return None
        reg = self.registry.get(check_id)
        if reg is None:
            if self.strict_registry:
                raise KeyError(f"{check_id} is not an active code in {self.schema}.check_registry. "
                               "Add it there first so check codes stay consistent.")
            self.unregistered.add(check_id)
            reg = {"layer": self.layer, "check_name": check_id, "check_type": None,
                   "default_severity": "WARN" if status == "WARN" else "FAIL",
                   "default_threshold": 0}
        elif reg["layer"] != self.layer:
            raise ValueError(f"{check_id} is a {reg['layer']} check; this run is {self.layer}")

        check_type = check_type or reg["check_type"]
        severity = severity or reg["default_severity"]
        threshold = float(reg["default_threshold"] or 0) if threshold is None else float(threshold)
        fail_pct = None
        if fail_count is not None and total_count:
            fail_pct = float(fail_count) / float(total_count)

        if status is None:
            if fail_count is None:
                raise ValueError(f"{check_id}: pass status, or fail_count to compute it")
            pct = fail_pct if fail_pct is not None else (0.0 if fail_count == 0 else 1.0)
            status = "PASS" if pct <= threshold else severity
        if status not in STATUSES:
            raise ValueError(f"{check_id}: status must be one of {STATUSES}, got {status!r}")

        self.results.append((
            self.run_id, self.validation_id, batch_id, source_key, table_name, self.layer, _now(),
            check_id, check_name or reg["check_name"], check_type, column_name,
            None if admin_level is None else int(admin_level), status, severity,
            None if fail_count is None else int(fail_count),
            None if total_count is None else int(total_count),
            fail_pct, threshold, _text(observed, 500), _text(expected, 500), _text(detail, 500),
        ))
        print(f"  {status:4} {check_id} {check_name or reg['check_name']}"
              + (f" [{column_name}]" if column_name else "")
              + (f" | fail={fail_count}/{total_count}" if fail_count is not None else "")
              + (f" | observed={observed} expected={expected}" if observed is not None else "")
              + (f" | {_text(detail, 200)}" if detail else ""))
        return status

    # -------------------------------------------------------------------------
    # Profiling and table stats
    # -------------------------------------------------------------------------

    def profile_table(self, table_name, columns=None, exclude=(), where=None):
        """Null / blank / distinct / min / max per column, in one pass over the table."""
        df = self.spark.table(table_name)
        if where:
            df = df.where(where)
        fields = [f for f in df.schema.fields
                  if (columns is None or f.name in columns) and f.name not in exclude
                  and f.dataType.typeName() not in ("struct", "array", "map", "binary")]
        if not fields:
            return 0

        aggs = [F.count(F.lit(1)).alias("__rows")]
        for i, f in enumerate(fields):
            c = F.col(_q(f.name))
            aggs += [
                F.sum(F.when(c.isNull(), 1).otherwise(0)).alias(f"n{i}"),
                F.sum(F.when(c.isNotNull() & (F.trim(c.cast("string")) == ""), 1).otherwise(0)).alias(f"b{i}"),
                F.approx_count_distinct(c).alias(f"d{i}"),
                F.min(c).cast("string").alias(f"lo{i}"),
                F.max(c).cast("string").alias(f"hi{i}"),
            ]
        row = df.agg(*aggs).collect()[0]
        rows = row["__rows"]
        at = _now()
        for i, f in enumerate(fields):
            nulls = row[f"n{i}"] or 0
            self.profiles.append((
                self.run_id, self.validation_id, self.layer, table_name, where, f.name,
                f.dataType.simpleString(), rows, nulls, (nulls / rows) if rows else None,
                row[f"b{i}"] or 0, row[f"d{i}"], _text(row[f"lo{i}"], 200), _text(row[f"hi{i}"], 200), at,
            ))
        print(f"  profiled {table_name}: {len(fields)} columns, {rows} rows")
        return rows

    def capture_table_stats(self, table_name):
        """Row count, Delta version and size of a table. Returns the row count."""
        df = self.spark.table(table_name)
        rows = df.count()
        version = num_files = size = None
        try:
            detail = self.spark.sql(f"DESCRIBE DETAIL {table_name}").collect()[0]
            num_files, size = detail["numFiles"], detail["sizeInBytes"]
            version = self.spark.sql(f"DESCRIBE HISTORY {table_name} LIMIT 1").collect()[0]["version"]
        except Exception as e:                                   # views have no Delta detail
            print(f"  table stats for {table_name}: no Delta detail ({str(e)[:100]})")
        self.stats.append((self.run_id, self.validation_id, self.layer, table_name, version, rows,
                           len(df.columns), num_files, size, _now()))
        return rows

    # -------------------------------------------------------------------------
    # Quarantine
    # -------------------------------------------------------------------------

    def quarantine(self, df, table_name, check_id, reason, key_cols=(), source_table=None):
        """Append rejected rows (a DataFrame) as JSON. Returns the number of rows quarantined."""
        if check_id not in self.registry:
            if self.strict_registry:
                raise KeyError(f"{check_id} is not an active code in {self.schema}.check_registry")
            self.unregistered.add(check_id)
        n = df.count()
        if n == 0:
            return 0
        key_json = (F.to_json(F.struct(*[F.col(_q(k)) for k in key_cols])) if key_cols
                    else F.lit(None).cast("string"))
        out = df.select(
            F.lit(self.run_id).alias("run_id"),
            F.lit(self.validation_id).alias("validation_id"),
            F.lit(self.layer).alias("layer"),
            F.lit(table_name).alias("table_name"),
            F.lit(source_table).cast("string").alias("source_table"),
            F.lit(check_id).alias("check_id"),
            F.lit(reason).alias("reason"),
            key_json.alias("record_key"),
            F.to_json(F.struct(*[F.col(_q(c)) for c in df.columns])).alias("record"),
            F.lit(_now()).cast("timestamp").alias("quarantined_at"),
        )
        out.write.format("delta").mode("append").saveAsTable(f"{self.schema}.quarantine")
        print(f"  quarantined {n} rows from {source_table or '?'} -> {table_name} ({check_id}: {reason})")
        return n

    # -------------------------------------------------------------------------
    # Finish
    # -------------------------------------------------------------------------

    def _append(self, rows, schema, table):
        if rows:
            (self.spark.createDataFrame(rows, schema)
             .write.format("delta").mode("append").saveAsTable(f"{self.schema}.{table}"))

    def finish(self, error=None):
        """Write everything, log the run, and raise if a check FAILed (when fail_on_error)."""
        if self._finished:
            return
        self._finished = True

        self._append(self.results, RESULTS_SCHEMA, "qc_results")
        self._append(self.profiles, PROFILE_SCHEMA, "profile")
        self._append(self.stats, STATS_SCHEMA, "table_stats")

        statuses = [r[12] for r in self.results]
        n_pass, n_warn, n_fail = (statuses.count(s) for s in STATUSES)
        if error is not None:
            status = "ERROR"
        elif not statuses:
            status = "NO_CHECKS"
        else:
            status = "FAIL" if n_fail else "WARN" if n_warn else "PASS"
        tables = len({r[4] for r in self.results if r[4]})
        self._append([(self.validation_id, self.run_id, self.layer, self.domain, self.script_name,
                       self.source_keys, self.started_at, _now(), status, len(statuses), n_pass,
                       n_warn, n_fail, tables, self.code_version, _text(error, 500))],
                     RUN_LOG_SCHEMA, "run_log")

        print(f"DQ {self.layer}/{self.domain} {self.validation_id}: {status} | {len(statuses)} checks, "
              f"{n_fail} FAIL, {n_warn} WARN | results in {self.schema}.qc_results")
        if self.unregistered:
            print(f"  not in check_registry yet: {sorted(self.unregistered)}")
        if error is None and n_fail and self.fail_on_error:
            failed = [f"{r[3] or ''} {r[7]} {r[8]}".strip() for r in self.results if r[12] == "FAIL"]
            raise RuntimeError(f"{self.layer} QC failed: " + "; ".join(failed[:20]))

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc is not None:
            # Record the crash as an execution check, write what was collected, then re-raise.
            self.record(f"{LAYER_PREFIX[self.layer]}00", status="FAIL", check_name="QC ran without error",
                        check_type="EXECUTION", detail=f"{exc_type.__name__}: {exc}")
            self.finish(error=f"{exc_type.__name__}: {exc}")
            return False
        self.finish()
        return False