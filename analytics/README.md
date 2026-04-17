# Analytics

Analytics pipeline for the home platform. Collects VPS and cluster signals, models them with dbt + DuckDB, and exposes a dashboard.

## Pipeline

```
[host collector]     systemd timer, every 15 min  ─┐
[k8s collector]      Flux CronJob, every 15 min   ──┼─→  S3 raw zone  →  dbt/DuckDB  →  dashboard
[billing collector]  systemd timer, monthly        ─┘
```

- Collectors write append-only timestamped JSON snapshots to the S3 raw zone.
- dbt reads S3 directly via DuckDB `httpfs` and writes curated marts to `analytics.duckdb`.
- Dashboard reads from DuckDB. (Phase 5 — not yet built.)

## Raw Zone Layout

Every collector run appends a new object. Nothing is overwritten.

```
analytics/raw/
├── host/{timestamp}.json
├── k8s/
│   ├── cluster/{timestamp}.json
│   ├── workloads/{timestamp}.json
│   ├── ingress/{timestamp}.json
│   ├── certs/{timestamp}.json
│   ├── events/{timestamp}.json
│   └── app-health/{timestamp}.json
├── billing/{timestamp}.json
└── meta/{collector}/{timestamp}.json
```

`{timestamp}` is a sortable UTC ISO-8601 string with `:` replaced by `-` (e.g. `2026-04-17T12-00-00-000000+00-00`).

`meta/` records pipeline run metadata (exit code, field count, collector name) emitted after every run, even on failure.

## Directory Ownership

| Directory | Purpose |
|-----------|---------|
| `collectors/` | Raw extraction — one subdirectory per source domain |
| `dbt/` | Transformations and curated models |
| `dashboard/` | Presentation layer (Phase 5) |
| `tests/` | Offline tests; `tests/fixtures/` holds golden-file snapshots |

## Quick Commands

```bash
# Run all collector tests
cd analytics && uv run pytest

# Run dbt against local fixtures (no credentials needed)
export ANALYTICS_RAW_BASE_PATH=/path/to/repo/analytics/tests/fixtures
cd analytics/dbt && uv run dbt build --target dev

# Run dbt against S3
export ANALYTICS_RAW_BASE_PATH="s3://your-bucket/analytics/raw"
export ANALYTICS_S3_ACCESS_KEY="..."
export ANALYTICS_S3_SECRET_KEY="..."
cd analytics/dbt && uv run dbt build --target dev-s3
```
