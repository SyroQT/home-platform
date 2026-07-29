# S3 Daily Partitioning Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers-extended-cc:subagent-driven-development (if subagents available) or superpowers-extended-cc:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Partition all raw S3 collector output by `YYYY/MM/DD` and update dbt sources to scan only the rolling window of recent partitions.

**Architecture:** Collectors insert a date path segment into every S3 key they write. A one-off migration script moves existing flat files to the new layout. dbt staging sources switch from flat globs to a `rolling_window_glob` macro that generates per-day paths for the last `analytics_history_days` (16) days. Staging model SQL is unchanged — incremental dedup via `snapshot_id` handles overlap.

**Tech Stack:** Python 3.13, boto3 (runtime only, mocked in tests), dbt-duckdb 1.10.1, pytest, uv

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `collectors/host/collect.py` | Modify | Insert `YYYY/MM/DD` into snapshot and meta S3 keys |
| `collectors/k8s/collect.py` | Modify | Insert `YYYY/MM/DD` into all collector and meta S3 keys |
| `collectors/migrate_to_partitioned.py` | Create | One-off script: copy flat files to partitioned paths, delete originals |
| `dbt/macros/rolling_window_glob.sql` | Create | Jinja macro that generates a JSON list of daily partition globs |
| `dbt/models/staging/_sources.yml` | Modify | Point the 7 data sources at `rolling_window_glob(prefix)` |
| `tests/test_collector_keys.py` | Create | Unit tests for key construction formulas |
| `tests/test_migration.py` | Create | Unit tests for migration script pure functions + mocked S3 flow |
| `tests/fixtures/k8s/*/2026/04/17/` | Move | Relocate 6 k8s fixture files into date subdirs |
| `tests/fixtures/meta/host/2026/04/17/` | Move | Relocate meta/host fixture |
| `tests/fixtures/meta/k8s/workloads/2026/04/17/` | Move | Relocate meta/k8s/workloads fixture |
| `tests/test_k8s_collectors.py` | Modify | Update `load()` glob from `*.json` to `**/*.json` |

---

### Task 1: Update collectors for date-partitioned S3 keys

**Goal:** Both collectors write files under `YYYY/MM/DD/` date subdirectories and tests verify the key formulas.

**Files:**
- Modify: `collectors/host/collect.py`
- Modify: `collectors/k8s/collect.py`
- Create: `tests/test_collector_keys.py`

**Acceptance Criteria:**
- [ ] Host collector snapshot key matches `analytics/raw/host/YYYY/MM/DD/{timestamp}.json`
- [ ] Host collector meta key matches `analytics/raw/meta/host/YYYY/MM/DD/{timestamp}.json`
- [ ] K8s collector data key matches `{prefix}/YYYY/MM/DD/{timestamp}.json`
- [ ] K8s collector meta key matches `analytics/raw/meta/k8s/{name}/YYYY/MM/DD/{timestamp}.json`
- [ ] `uv run pytest tests/test_collector_keys.py -v` passes

**Verify:** `uv run pytest tests/test_collector_keys.py -v` → all tests PASS

**Steps:**

- [ ] **Step 1: Write tests for the key construction formulas**

Create `tests/test_collector_keys.py`:

```python
from datetime import datetime, timezone


def test_host_date_path_from_collected_at():
    collected_at = "2026-05-22T10:30:45.123456+00:00"
    date_path = collected_at[:10].replace("-", "/")
    assert date_path == "2026/05/22"


def test_host_snapshot_key_has_date_partition():
    collected_at = "2026-05-22T10:30:45.123456+00:00"
    timestamp = collected_at.replace(":", "-").replace("+", "-")
    date_path = collected_at[:10].replace("-", "/")
    key = f"analytics/raw/host/{date_path}/{timestamp}.json"
    assert key == "analytics/raw/host/2026/05/22/2026-05-22T10-30-45.123456-00-00.json"


def test_host_meta_key_has_date_partition():
    now = datetime(2026, 5, 22, 10, 30, 45, tzinfo=timezone.utc)
    meta_ts = now.isoformat().replace(":", "-").replace("+", "-")
    meta_date_path = now.strftime("%Y/%m/%d")
    key = f"analytics/raw/meta/host/{meta_date_path}/{meta_ts}.json"
    assert key == "analytics/raw/meta/host/2026/05/22/2026-05-22T10-30-45-00-00.json"


def test_k8s_data_key_has_date_partition():
    now = datetime(2026, 5, 22, 10, 30, 45, tzinfo=timezone.utc)
    timestamp = now.isoformat().replace(":", "-").replace("+", "-")
    date_path = now.strftime("%Y/%m/%d")
    s3_key_prefix = "analytics/raw/k8s/cluster"
    key = f"{s3_key_prefix}/{date_path}/{timestamp}.json"
    assert key == "analytics/raw/k8s/cluster/2026/05/22/2026-05-22T10-30-45-00-00.json"


def test_k8s_meta_key_has_date_partition():
    now = datetime(2026, 5, 22, 10, 30, 45, tzinfo=timezone.utc)
    meta_ts = now.isoformat().replace(":", "-").replace("+", "-")
    meta_date_path = now.strftime("%Y/%m/%d")
    name = "workloads"
    key = f"analytics/raw/meta/k8s/{name}/{meta_date_path}/{meta_ts}.json"
    assert key == "analytics/raw/meta/k8s/workloads/2026/05/22/2026-05-22T10-30-45-00-00.json"
```

Run: `uv run pytest tests/test_collector_keys.py -v`
Expected: **5 failures** (tests written before implementation — TDD red phase).

- [ ] **Step 2: Update `collectors/host/collect.py` snapshot key**

In `main()`, find these lines (around line 193–194):

```python
timestamp = snapshot["collected_at"].replace(":", "-").replace("+", "-")
snapshot_key = f"analytics/raw/host/{timestamp}.json"
```

Replace with:

```python
timestamp = snapshot["collected_at"].replace(":", "-").replace("+", "-")
date_path = snapshot["collected_at"][:10].replace("-", "/")
snapshot_key = f"analytics/raw/host/{date_path}/{timestamp}.json"
```

- [ ] **Step 3: Update `collectors/host/collect.py` meta key**

In `main()`'s `finally` block, find these lines (around line 210–215):

```python
meta_ts = (
    datetime.now(timezone.utc)
    .isoformat()
    .replace(":", "-")
    .replace("+", "-")
)
meta_key = f"analytics/raw/meta/host/{meta_ts}.json"
```

Replace with:

```python
meta_now = datetime.now(timezone.utc)
meta_ts = meta_now.isoformat().replace(":", "-").replace("+", "-")
meta_date_path = meta_now.strftime("%Y/%m/%d")
meta_key = f"analytics/raw/meta/host/{meta_date_path}/{meta_ts}.json"
```

- [ ] **Step 4: Update `collectors/k8s/collect.py` data key**

In `run_collector()`, find these lines (around line 315–327):

```python
result = fn()
timestamp = (
    datetime.now(timezone.utc).isoformat().replace(":", "-").replace("+", "-")
)
...
key = f"{s3_key_prefix}/{timestamp}.json"
```

Replace with:

```python
result = fn()
now = datetime.now(timezone.utc)
timestamp = now.isoformat().replace(":", "-").replace("+", "-")
date_path = now.strftime("%Y/%m/%d")
...
key = f"{s3_key_prefix}/{date_path}/{timestamp}.json"
```

- [ ] **Step 5: Update `collectors/k8s/collect.py` meta key**

In `run_collector()`'s `finally` block, find these lines (around line 337–349):

```python
meta_ts = (
    datetime.now(timezone.utc)
    .isoformat()
    .replace(":", "-")
    .replace("+", "-")
)
meta = {...}
meta_key = f"analytics/raw/meta/k8s/{name}/{meta_ts}.json"
```

Replace with:

```python
meta_now = datetime.now(timezone.utc)
meta_ts = meta_now.isoformat().replace(":", "-").replace("+", "-")
meta_date_path = meta_now.strftime("%Y/%m/%d")
meta = {...}
meta_key = f"analytics/raw/meta/k8s/{name}/{meta_date_path}/{meta_ts}.json"
```

- [ ] **Step 6: Run verification and commit**

```bash
uv run pytest tests/test_collector_keys.py -v
```

Expected: **5 passed**

```bash
git add collectors/host/collect.py collectors/k8s/collect.py tests/test_collector_keys.py
git commit -m "feat: write collector output to date-partitioned S3 keys"
```

---

### Task 2: Write migration script

**Goal:** A script that detects flat S3 files and copies them to the partitioned layout, with dry-run mode and full unit test coverage of its pure functions.

**Files:**
- Create: `collectors/migrate_to_partitioned.py`
- Create: `tests/test_migration.py`

**Acceptance Criteria:**
- [ ] `is_migratable()` correctly identifies flat vs partitioned keys
- [ ] `make_partitioned_key()` produces correct new keys for all source prefixes
- [ ] Dry-run mode lists moves without touching S3
- [ ] Apply mode calls `copy_object` then `delete_object` for each file
- [ ] `uv run pytest tests/test_migration.py -v` passes

**Verify:** `uv run pytest tests/test_migration.py -v` → all tests PASS

**Steps:**

- [ ] **Step 1: Write tests**

Create `tests/test_migration.py`:

```python
import sys
from pathlib import Path
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, str(Path(__file__).parent.parent / "collectors"))
import migrate_to_partitioned as mig


# --- Pure function tests ---

def test_is_partitioned_returns_true_for_date_path():
    key = "analytics/raw/host/2026/05/22/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.is_partitioned(key) is True


def test_is_partitioned_returns_false_for_flat_key():
    key = "analytics/raw/host/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.is_partitioned(key) is False


def test_is_migratable_true_for_flat_timestamped_file():
    key = "analytics/raw/host/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.is_migratable(key) is True


def test_is_migratable_false_for_already_partitioned():
    key = "analytics/raw/host/2026/05/22/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.is_migratable(key) is False


def test_is_migratable_false_for_non_json():
    key = "analytics/raw/host/somefile.txt"
    assert mig.is_migratable(key) is False


def test_make_partitioned_key_host():
    old = "analytics/raw/host/2026-05-22T10-30-45.000000-00-00.json"
    expected = "analytics/raw/host/2026/05/22/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.make_partitioned_key(old) == expected


def test_make_partitioned_key_k8s_cluster():
    old = "analytics/raw/k8s/cluster/2026-05-22T10-30-45.000000-00-00.json"
    expected = "analytics/raw/k8s/cluster/2026/05/22/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.make_partitioned_key(old) == expected


def test_make_partitioned_key_meta_host():
    old = "analytics/raw/meta/host/2026-05-22T10-30-45.000000-00-00.json"
    expected = "analytics/raw/meta/host/2026/05/22/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.make_partitioned_key(old) == expected


def test_make_partitioned_key_meta_k8s():
    old = "analytics/raw/meta/k8s/workloads/2026-05-22T10-30-45.000000-00-00.json"
    expected = "analytics/raw/meta/k8s/workloads/2026/05/22/2026-05-22T10-30-45.000000-00-00.json"
    assert mig.make_partitioned_key(old) == expected


# --- Dry-run test (no S3 calls) ---

def test_migrate_dry_run_does_not_call_s3(capsys):
    client = MagicMock()
    mig.migrate(client, "my-bucket", "analytics/raw/host/2026-05-22T10-00-00.000000-00-00.json", dry_run=True)
    client.copy_object.assert_not_called()
    client.delete_object.assert_not_called()
    out = capsys.readouterr().out
    assert "[dry-run]" in out


# --- Apply test (calls copy then delete) ---

def test_migrate_apply_copies_then_deletes():
    client = MagicMock()
    old_key = "analytics/raw/host/2026-05-22T10-00-00.000000-00-00.json"
    new_key = "analytics/raw/host/2026/05/22/2026-05-22T10-00-00.000000-00-00.json"
    mig.migrate(client, "my-bucket", old_key, dry_run=False)
    client.copy_object.assert_called_once_with(
        Bucket="my-bucket",
        CopySource={"Bucket": "my-bucket", "Key": old_key},
        Key=new_key,
    )
    client.delete_object.assert_called_once_with(Bucket="my-bucket", Key=old_key)


# --- list_flat_keys test ---

def test_list_flat_keys_returns_only_flat_files():
    client = MagicMock()
    client.get_paginator.return_value.paginate.return_value = [
        {
            "Contents": [
                {"Key": "analytics/raw/host/2026-05-22T10-00-00.000000-00-00.json"},
                {"Key": "analytics/raw/host/2026/05/22/2026-05-22T10-00-00.000000-00-00.json"},
                {"Key": "analytics/raw/k8s/cluster/2026-05-21T10-00-00.000000-00-00.json"},
            ]
        }
    ]
    result = mig.list_flat_keys(client, "my-bucket")
    assert len(result) == 2
    assert all(not mig.is_partitioned(k) for k in result)
```

Run: `uv run pytest tests/test_migration.py -v`
Expected: **ImportError or AttributeError** (module not yet created — TDD red phase).

- [ ] **Step 2: Create `collectors/migrate_to_partitioned.py`**

```python
#!/usr/bin/env python3
"""
Migrate flat S3 files to date-partitioned layout.

Before: analytics/raw/host/2026-05-22T10-30-45.000000-00-00.json
After:  analytics/raw/host/2026/05/22/2026-05-22T10-30-45.000000-00-00.json

Usage:
    python migrate_to_partitioned.py          # dry run (default)
    python migrate_to_partitioned.py --apply  # execute changes
"""
import argparse
import os
import re
import sys

FLAT_KEY_PATTERN = re.compile(r"/\d{4}-\d{2}-\d{2}T[^/]+\.json$")
PARTITIONED_PATTERN = re.compile(r"/\d{4}/\d{2}/\d{2}/[^/]+\.json$")
RAW_PREFIX = "analytics/raw/"


def is_partitioned(key: str) -> bool:
    return bool(PARTITIONED_PATTERN.search(key))


def is_migratable(key: str) -> bool:
    return bool(FLAT_KEY_PATTERN.search(key)) and not is_partitioned(key)


def make_partitioned_key(key: str) -> str:
    filename = key.split("/")[-1]
    prefix = "/".join(key.split("/")[:-1])
    date_path = filename[:10].replace("-", "/")  # "2026-05-22" -> "2026/05/22"
    return f"{prefix}/{date_path}/{filename}"


def list_flat_keys(client, bucket: str) -> list[str]:
    paginator = client.get_paginator("list_objects_v2")
    flat_keys = []
    for page in paginator.paginate(Bucket=bucket, Prefix=RAW_PREFIX):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if is_migratable(key):
                flat_keys.append(key)
    return flat_keys


def migrate(client, bucket: str, old_key: str, dry_run: bool) -> None:
    new_key = make_partitioned_key(old_key)
    if dry_run:
        print(f"[dry-run] {old_key}\n      --> {new_key}")
        return
    client.copy_object(
        Bucket=bucket,
        CopySource={"Bucket": bucket, "Key": old_key},
        Key=new_key,
    )
    client.delete_object(Bucket=bucket, Key=old_key)
    print(f"Migrated: {old_key} -> {new_key}")


def get_s3_client():
    import boto3

    endpoint = os.environ.get("S3_ENDPOINT_URL")
    if not endpoint:
        print("ERROR: S3_ENDPOINT_URL is not set", file=sys.stderr)
        sys.exit(1)
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY"),
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Migrate flat S3 files to date-partitioned layout"
    )
    parser.add_argument(
        "--apply", action="store_true", help="Execute migration (default: dry run)"
    )
    args = parser.parse_args()
    dry_run = not args.apply

    bucket = os.environ.get("S3_BUCKET")
    if not bucket:
        print("ERROR: S3_BUCKET is not set", file=sys.stderr)
        sys.exit(1)

    if dry_run:
        print("DRY RUN — pass --apply to execute\n")

    client = get_s3_client()
    flat_keys = list_flat_keys(client, bucket)

    if not flat_keys:
        print("No flat files found — nothing to migrate")
        sys.exit(0)

    print(f"Found {len(flat_keys)} file(s) to migrate")
    for key in flat_keys:
        migrate(client, bucket, key, dry_run=dry_run)

    if dry_run:
        print(f"\nRun with --apply to migrate {len(flat_keys)} file(s)")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Run verification and commit**

```bash
uv run pytest tests/test_migration.py -v
```

Expected: **12 passed**

```bash
git add collectors/migrate_to_partitioned.py tests/test_migration.py
git commit -m "feat: add migration script for flat-to-partitioned S3 layout"
```

---

### Task 3: Add dbt macro and update sources

**Goal:** A `rolling_window_glob` macro generates per-day partition paths, and all 7 data sources in `_sources.yml` use it instead of flat globs.

**Files:**
- Create: `dbt/macros/rolling_window_glob.sql`
- Modify: `dbt/models/staging/_sources.yml`

**Acceptance Criteria:**
- [ ] `uv run dbt compile` completes with no errors from the `dbt/` directory
- [ ] Compiled output for any staging source model references at least 1 date-path glob
- [ ] `source_meta` still uses the flat `meta/**/*.json` glob (no macro)

**Verify:** `cd dbt && uv run dbt compile 2>&1 | tail -5` → `Completed successfully`

**Steps:**

- [ ] **Step 1: Create `dbt/macros/rolling_window_glob.sql`**

```sql
{% macro rolling_window_glob(prefix) %}
  {%- set days = var('analytics_history_days', 16) -%}
  {%- set paths = [] -%}
  {%- for i in range(days) -%}
    {%- set d = modules.datetime.date.today() - modules.datetime.timedelta(days=i) -%}
    {%- do paths.append(
      env_var('ANALYTICS_RAW_BASE_PATH') ~ '/' ~ prefix ~ '/'
      ~ d.strftime('%Y') ~ '/' ~ d.strftime('%m') ~ '/' ~ d.strftime('%d')
      ~ '/*.json'
    ) -%}
  {%- endfor -%}
  {{ paths | tojson }}
{% endmacro %}
```

- [ ] **Step 2: Update `dbt/models/staging/_sources.yml`**

Replace every `external_location` for the 7 data sources. The `source_meta` entry keeps its existing flat glob unchanged.

The full updated file:

```yaml
version: 2

sources:

  - name: source_host
    description: "VPS host snapshots — CPU, memory, disk, uptime, service status"
    tables:
      - name: snapshots
        description: "One JSON file per 15-minute collection run"
        config:
          external_location: "read_json_auto({{ rolling_window_glob('host') }}, filename=true)"

  - name: source_k8s_cluster
    description: "Kubernetes node state snapshots"
    tables:
      - name: snapshots
        config:
          external_location: "read_json_auto({{ rolling_window_glob('k8s/cluster') }}, filename=true)"

  - name: source_k8s_workloads
    description: "Kubernetes Deployment and Pod snapshots"
    tables:
      - name: snapshots
        config:
          external_location: "read_json_auto({{ rolling_window_glob('k8s/workloads') }}, filename=true)"

  - name: source_k8s_ingress
    description: "Kubernetes Ingress snapshots"
    tables:
      - name: snapshots
        config:
          external_location: "read_json_auto({{ rolling_window_glob('k8s/ingress') }}, filename=true)"

  - name: source_k8s_certs
    description: "cert-manager Certificate snapshots"
    tables:
      - name: snapshots
        config:
          external_location: "read_json_auto({{ rolling_window_glob('k8s/certs') }}, filename=true)"

  - name: source_k8s_events
    description: "Kubernetes Event snapshots"
    tables:
      - name: snapshots
        config:
          external_location: "read_json_auto({{ rolling_window_glob('k8s/events') }}, filename=true)"

  - name: source_k8s_app_health
    description: "Per-app pod readiness snapshots (dict-of-lists keyed by namespace/app)"
    tables:
      - name: snapshots
        config:
          external_location: "read_json_auto({{ rolling_window_glob('k8s/app-health') }}, filename=true)"

  - name: source_meta
    description: "Collector pipeline run metadata — one record per collector per run"
    tables:
      - name: snapshots
        config:
          external_location: "read_json_auto('{{ env_var('ANALYTICS_RAW_BASE_PATH') }}/meta/**/*.json', filename=true)"
```

- [ ] **Step 3: Run verification and commit**

```bash
cd dbt && uv run dbt compile 2>&1 | tail -5
```

Expected output ends with: `Completed successfully`

Check that the compiled output references date paths:

```bash
grep -o "2026/[0-9][0-9]/[0-9][0-9]" dbt/target/compiled/home_platform/models/staging/stg_host_snapshots.sql | head -3
```

Expected: 3 lines of dates (one per glob path in the window).

```bash
git add dbt/macros/rolling_window_glob.sql dbt/models/staging/_sources.yml
git commit -m "feat: add rolling_window_glob macro and update staging sources for partitioned S3"
```

---

### Task 4: Update test fixtures and k8s test loader

**Goal:** All timestamped fixture files live under `YYYY/MM/DD/` subdirectories, and the k8s test `load()` function discovers them with a recursive glob.

**Files:**
- Move: `tests/fixtures/k8s/*/2026-04-17T10-00-00.000000-00-00.json` → `tests/fixtures/k8s/*/2026/04/17/`
- Move: `tests/fixtures/meta/host/2026-04-17T10-00-00.000000-00-00.json` → `tests/fixtures/meta/host/2026/04/17/`
- Move: `tests/fixtures/meta/k8s/workloads/2026-04-17T10-00-00.000000-00-00.json` → `tests/fixtures/meta/k8s/workloads/2026/04/17/`
- Modify: `tests/test_k8s_collectors.py` (update `load()`)

**Acceptance Criteria:**
- [ ] No `*.json` files remain directly under `tests/fixtures/k8s/{name}/` (only under date subdirs)
- [ ] `uv run pytest tests/test_k8s_collectors.py -v` still passes (all existing tests green)

**Verify:** `uv run pytest tests/test_k8s_collectors.py -v` → all tests PASS

**Steps:**

- [ ] **Step 1: Move fixture files into date subdirectories**

```bash
DATE_DIR="2026/04/17"
FNAME="2026-04-17T10-00-00.000000-00-00.json"

for name in app-health certs cluster events ingress workloads; do
  mkdir -p "tests/fixtures/k8s/${name}/${DATE_DIR}"
  mv "tests/fixtures/k8s/${name}/${FNAME}" "tests/fixtures/k8s/${name}/${DATE_DIR}/${FNAME}"
done

mkdir -p "tests/fixtures/meta/host/${DATE_DIR}"
mv "tests/fixtures/meta/host/${FNAME}" "tests/fixtures/meta/host/${DATE_DIR}/${FNAME}"

mkdir -p "tests/fixtures/meta/k8s/workloads/${DATE_DIR}"
mv "tests/fixtures/meta/k8s/workloads/${FNAME}" "tests/fixtures/meta/k8s/workloads/${DATE_DIR}/${FNAME}"
```

- [ ] **Step 2: Update `load()` in `tests/test_k8s_collectors.py`**

Find this function (lines 17–23):

```python
def load(name: str) -> object:
    fixture_dir = FIXTURE_DIR / name
    # Support both timestamp-named files (dbt dev fixtures) and legacy sample.json
    candidates = sorted(fixture_dir.glob("*.json"))
    if not candidates:
        raise FileNotFoundError(f"No fixture files found in {fixture_dir}")
    return json.loads(candidates[0].read_text())
```

Replace with:

```python
def load(name: str) -> object:
    fixture_dir = FIXTURE_DIR / name
    candidates = sorted(fixture_dir.glob("**/*.json"))
    if not candidates:
        raise FileNotFoundError(f"No fixture files found in {fixture_dir}")
    return json.loads(candidates[0].read_text())
```

The only change is `"*.json"` → `"**/*.json"`. The comment about `legacy sample.json` is removed since that pattern no longer applies.

- [ ] **Step 3: Run verification and commit**

```bash
uv run pytest tests/test_k8s_collectors.py -v
```

Expected: all tests PASS (same count as before)

```bash
# Confirm no flat fixture files remain under k8s/
find tests/fixtures/k8s -maxdepth 2 -name "*.json" | wc -l
```

Expected: `0`

```bash
git add tests/fixtures/ tests/test_k8s_collectors.py
git commit -m "feat: move test fixtures to date-partitioned layout"
```

---

## Cutover (Post-Merge)

Run these in order after the branch is deployed:

```bash
# 1. Dry-run migration to review what will be moved
S3_ENDPOINT_URL=... S3_BUCKET=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  python collectors/migrate_to_partitioned.py

# 2. Execute migration
S3_ENDPOINT_URL=... S3_BUCKET=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  python collectors/migrate_to_partitioned.py --apply

# 3. Rebuild all incremental dbt models from migrated files
cd dbt && uv run dbt run --full-refresh

# 4. Verify
uv run dbt test
```
