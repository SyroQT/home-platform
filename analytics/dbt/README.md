# dbt

This directory owns analytics transformations and curated models. Assets here should read from the canonical raw-zone paths documented in [`analytics/README.md`](../README.md) and publish modeled outputs for downstream dashboard use.

## tests

uv run dbt run --target dev --select stg_host_snapshots

uv run python -c "
import duckdb
con = duckdb.connect('/tmp/analytics_dev.duckdb')
print(con.execute('SELECT \* FROM stg_host_snapshots').fetchdf().T)
"
