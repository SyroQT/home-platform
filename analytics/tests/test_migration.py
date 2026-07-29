import sys
from pathlib import Path
from unittest.mock import MagicMock

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
