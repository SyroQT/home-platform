import json
from datetime import datetime, timezone
from pathlib import Path

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "host" / "sample.json"

REQUIRED_TOP_LEVEL_FIELDS = {
    "collected_at",
    "cpu_load_1m",
    "cpu_load_5m",
    "cpu_load_15m",
    "mem_total_kb",
    "mem_available_kb",
    "mem_used_kb",
    "uptime_seconds",
    "disk",
    "services",
}

REQUIRED_DISK_MOUNTS = {"/", "/srv/data"}
REQUIRED_DISK_FIELDS = {"size_kb", "used_kb", "avail_kb", "used_pct"}
REQUIRED_SERVICES = {"k3s", "sshd", "restic-backup.timer"}


def load_fixture():
    return json.loads(FIXTURE_PATH.read_text())


def test_required_top_level_fields_present():
    data = load_fixture()
    missing = REQUIRED_TOP_LEVEL_FIELDS - data.keys()
    assert not missing, f"Missing top-level fields: {missing}"


def test_collected_at_is_valid_iso8601():
    data = load_fixture()
    raw = data["collected_at"]
    # datetime.fromisoformat handles the +00:00 offset on Python 3.7+
    parsed = datetime.fromisoformat(raw)
    assert parsed.tzinfo is not None, "collected_at must include timezone info"


def test_disk_contains_required_mounts():
    data = load_fixture()
    disk = data["disk"]
    missing_mounts = REQUIRED_DISK_MOUNTS - disk.keys()
    assert not missing_mounts, f"Missing disk mounts: {missing_mounts}"


def test_disk_entries_have_required_fields():
    data = load_fixture()
    for mount in REQUIRED_DISK_MOUNTS:
        entry = data["disk"][mount]
        missing = REQUIRED_DISK_FIELDS - entry.keys()
        assert not missing, f"Mount '{mount}' missing fields: {missing}"


def test_disk_used_pct_is_float_in_range():
    data = load_fixture()
    for mount, entry in data["disk"].items():
        pct = entry["used_pct"]
        assert isinstance(pct, (int, float)), f"{mount}: used_pct is not numeric"
        assert 0.0 <= pct <= 100.0, f"{mount}: used_pct={pct} out of range"


def test_services_contains_exactly_required_keys():
    data = load_fixture()
    services = data["services"]
    assert (
        set(services.keys()) == REQUIRED_SERVICES
    ), f"Expected services {REQUIRED_SERVICES}, got {set(services.keys())}"


def test_services_values_are_strings():
    data = load_fixture()
    for name, status in data["services"].items():
        assert isinstance(status, str), f"Service '{name}' status is not a string"


def test_numeric_fields_are_non_negative():
    data = load_fixture()
    numeric_fields = [
        "cpu_load_1m",
        "cpu_load_5m",
        "cpu_load_15m",
        "mem_total_kb",
        "mem_available_kb",
        "mem_used_kb",
        "uptime_seconds",
    ]
    for field in numeric_fields:
        assert data[field] >= 0, f"Field '{field}' is negative: {data[field]}"
