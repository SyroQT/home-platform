# dbt

Transformations and curated models. Reads from the S3 raw zone via DuckDB `httpfs` and writes marts to `analytics.duckdb` on the VPS.

## Model Layers

**Staging** — one model per raw source, reads S3 JSON directly:

| Model | Source |
|-------|--------|
| `stg_host_snapshots` | `analytics/raw/host/` |
| `stg_k8s_cluster` | `analytics/raw/k8s/cluster/` |
| `stg_k8s_workloads` | `analytics/raw/k8s/workloads/` |
| `stg_k8s_app_health` | `analytics/raw/k8s/app-health/` |
| `stg_k8s_certs` | `analytics/raw/k8s/certs/` |
| `stg_k8s_events` | `analytics/raw/k8s/events/` |
| `stg_k8s_ingress` | `analytics/raw/k8s/ingress/` |
| `stg_meta_pipeline_runs` | `analytics/raw/meta/` |

**Intermediate** — enrichments not needed in marts directly:

| Model | Purpose |
|-------|---------|
| `int_host_snapshots_enriched` | Adds derived health status fields to host snapshots |

**Marts** — final curated tables for dashboard use:

| Model | Purpose |
|-------|---------|
| `mart_host_status_latest` | Most recent host snapshot (single row) |
| `mart_host_status_history` | Rolling host metric history |
| `mart_k8s_status_latest` | Most recent cluster state (single row) |
| `mart_k8s_status_history` | Rolling cluster metric history |
| `mart_app_health_latest` | Current readiness and restart counts per app |
| `mart_pipeline_runs` | Collector run history and success rates |

## Production Runner

`run_dbt.sh` is the VPS production entrypoint. It:
1. Loads S3 credentials from `/etc/analytics/host-collector.env`
2. Runs `dbt build` writing to `analytics.duckdb.tmp`
3. On success: atomically `mv` tmp → `analytics.duckdb`
4. On failure: leaves the last good `analytics.duckdb` untouched

DuckDB file lives at `/srv/data/analytics/analytics.duckdb` (50 GB block volume).

**Note:** `SET s3_url_style='path'` is required for Hetzner Object Storage — path-style URLs only.

## Environment variables

| Variable | Required for | Description |
|---|---|---|
| `ANALYTICS_RAW_BASE_PATH` | all targets | Base path to the raw zone. Use a local path (e.g. `analytics/tests/fixtures`) for `dev`, or an S3 URL (e.g. `s3://your-bucket/analytics/raw`) for `dev-s3` / `prod`. |
| `ANALYTICS_S3_ACCESS_KEY` | `dev-s3`, `prod` | S3 / Hetzner Object Storage access key ID. |
| `ANALYTICS_S3_SECRET_KEY` | `dev-s3`, `prod` | S3 / Hetzner Object Storage secret access key. |
| `DBT_DUCKDB_PATH` | `prod` | Override the DuckDB file path (defaults to `/srv/data/analytics/analytics.duckdb`). |

## Running locally

### Against local fixtures (no credentials needed)

```bash
export ANALYTICS_RAW_BASE_PATH=/path/to/repo/analytics/tests/fixtures
uv run dbt run --target dev --select tag:staging
```

### Against S3 (Hetzner Object Storage)

```bash
export ANALYTICS_RAW_BASE_PATH="s3://your-bucket/analytics/raw"
export ANALYTICS_S3_ACCESS_KEY="your-access-key"
export ANALYTICS_S3_SECRET_KEY="your-secret-key"
uv run dbt run --target dev-s3 --select tag:staging
```

### Inspect results

```bash
uv run python -c "
import duckdb
con = duckdb.connect('/tmp/analytics_dev.duckdb')
print(con.execute('SELECT * FROM stg_host_snapshots').fetchdf().T)
"
```
