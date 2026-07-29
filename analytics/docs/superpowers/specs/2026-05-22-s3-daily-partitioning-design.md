# S3 Daily Partitioning Refactor

**Date:** 2026-05-22  
**Status:** Approved

## Problem

All collector output currently lands in flat S3 prefixes, e.g. `analytics/raw/host/{timestamp}.json`. dbt sources glob the entire prefix on every run, which will become expensive as history grows. There is no partition pruning — every run re-scans all files.

## Goal

Partition raw files by calendar date (`YYYY/MM/DD`) in S3 and update dbt to scan only the rolling window of recent partitions needed for the incremental load.

## S3 Layout

### Before
```
analytics/raw/host/{timestamp}.json
analytics/raw/k8s/{name}/{timestamp}.json
analytics/raw/meta/host/{timestamp}.json
analytics/raw/meta/k8s/{name}/{timestamp}.json
```

### After
```
analytics/raw/host/YYYY/MM/DD/{timestamp}.json
analytics/raw/k8s/{name}/YYYY/MM/DD/{timestamp}.json
analytics/raw/meta/host/YYYY/MM/DD/{timestamp}.json
analytics/raw/meta/k8s/{name}/YYYY/MM/DD/{timestamp}.json
```

## Components

### 1. Collectors

Both `collectors/host/collect.py` and `collectors/k8s/collect.py` derive a `date_path` from the collection timestamp and insert it into the S3 key.

**host collector** (`main()`):
```python
date_path = now.strftime("%Y/%m/%d")  # now is already in scope from collect()
snapshot_key = f"analytics/raw/host/{date_path}/{timestamp}.json"
```

**k8s collector** (`run_collector()`):
```python
date_path = datetime.now(timezone.utc).strftime("%Y/%m/%d")
key = f"{s3_key_prefix}/{date_path}/{timestamp}.json"
```

Meta keys follow the same pattern.

### 2. Migration Script

`collectors/migrate_to_partitioned.py` — one-off script to move existing flat files to the partitioned layout.

- Lists all objects under `analytics/raw/` in S3
- Identifies flat files: any key without a `YYYY/MM/DD` path segment
- Parses the date from the filename timestamp (same format collectors already produce)
- Copies each object to its new partitioned key via S3 `copy_object`
- Deletes the source object after a successful copy
- Dry-run by default; requires `--apply` flag to execute changes

### 3. dbt Macro

New macro `dbt/macros/rolling_window_glob.sql`:

```sql
{% macro rolling_window_glob(prefix) %}
  {%- set days = var('analytics_history_days', 16) -%}
  {%- set paths = [] -%}
  {%- for i in range(days) -%}
    {%- set d = modules.datetime.date.today() - modules.datetime.timedelta(days=i) -%}
    {%- do paths.append(
      env_var('ANALYTICS_RAW_BASE_PATH') ~ '/' ~ prefix ~ '/' ~
      d.strftime('%Y') ~ '/' ~ d.strftime('%m') ~ '/' ~ d.strftime('%d') ~ '/*.json'
    ) -%}
  {%- endfor -%}
  {{ paths | tojson }}
{% endmacro %}
```

Generates a JSON list of partition paths covering today and the previous `analytics_history_days - 1` days. The existing `analytics_history_days` var (currently 16) controls the window.

### 4. dbt Sources

`dbt/models/staging/_sources.yml` — each `external_location` is updated to use the macro:

```yaml
external_location: "read_json_auto({{ rolling_window_glob('host') }}, filename=true)"
```

All seven data sources (`host`, `k8s/cluster`, `k8s/workloads`, `k8s/ingress`, `k8s/certs`, `k8s/events`, `k8s/app-health`) get this treatment with their respective prefix arguments.

The `source_meta` source is **excluded from partition pruning** — its files live under two nested sub-paths (`meta/host/` and `meta/k8s/{name}/`) which don't map cleanly to a single prefix. Meta files are small and infrequent; it continues to use the existing full glob `meta/**/*.json`. After migration the migrated meta files will be at `meta/host/YYYY/MM/DD/` and `meta/k8s/{name}/YYYY/MM/DD/`, and the `**` wildcard covers them correctly.

### 5. Staging Models

No SQL changes required. The incremental dedup logic (`unique_key = 'snapshot_id'` based on `filename`) continues to work correctly:

- The source glob now only scans recent partitions (partition pruning)
- The `WHERE snapshot_id NOT IN (SELECT snapshot_id FROM {{ this }})` filter handles any overlap between the rolling window and already-loaded data

### 6. Test Fixtures

Fixture files under `tests/fixtures/` gain the date folder to match the new layout:

```
tests/fixtures/k8s/cluster/2026-04-17T10-00-00.000000-00-00.json
→ tests/fixtures/k8s/cluster/2026/04/17/2026-04-17T10-00-00.000000-00-00.json
```

All fixture paths across `tests/test_host_collectors.py` and `tests/test_k8s_collectors.py` are updated accordingly.

## Cutover Procedure

1. Run `collectors/migrate_to_partitioned.py --apply` to move existing flat files
2. Deploy updated collectors (host service + k8s CronJob)
3. Run `dbt run --full-refresh` to rebuild all incremental tables from the migrated files
4. Verify mart row counts match pre-migration baseline

## What Does Not Change

- Collector logic (what data is collected)
- Staging model SQL
- Intermediate and mart models
- dbt `unique_key` and surrogate key strategy
- `analytics_history_days` var semantics
