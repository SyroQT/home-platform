# Tests

Offline tests for collectors and dbt models. No live cluster, VPS, or S3 access needed — all tests run against fixtures.

## Running

```bash
# All tests
cd analytics && uv run pytest

# Collector tests only
uv run pytest tests/test_host_collectors.py
uv run pytest tests/test_k8s_collectors.py
```

## Test Approach

**Collector tests** (`test_host_collectors.py`, `test_k8s_collectors.py`) are golden-file tests: they load a static fixture and assert structural and type invariants. They do not call the collector or touch S3.

**dbt tests** live in `dbt/tests/` as SQL assertions (e.g. `assert_mart_host_status_latest_is_single_row.sql`) and run via `uv run dbt test`.

## Updating Fixtures

Fixtures should be updated when the collector output schema changes. Capture a fresh snapshot from S3 and replace the relevant file under `tests/fixtures/`.

The k8s collector tests load the first `*.json` file found in each fixture subdirectory, so you can drop a new timestamped file and remove the old one.
