# dbt

This directory owns analytics transformations and curated models. Assets here should read from the canonical raw-zone paths documented in [`analytics/README.md`](../README.md) and publish modeled outputs for downstream dashboard use.

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
