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
