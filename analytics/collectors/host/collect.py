#!/usr/bin/env python3
"""
Host collector for the analytics pipeline.

Collects VPS signals and writes a timestamped JSON snapshot to Object Storage.
Also emits a metadata record with exit status and field count.

Environment variables (loaded from env file by systemd):
    S3_ENDPOINT_URL      Hetzner Object Storage endpoint
    S3_BUCKET            Target bucket name
    AWS_ACCESS_KEY_ID    S3 access key
    AWS_SECRET_ACCESS_KEY  S3 secret key
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------


def read_cpu_load() -> dict:
    """Parse /proc/loadavg into 1m, 5m, 15m load averages."""
    with open("/proc/loadavg") as f:
        parts = f.read().split()
    return {
        "cpu_load_1m": float(parts[0]),
        "cpu_load_5m": float(parts[1]),
        "cpu_load_15m": float(parts[2]),
    }


def read_memory() -> dict:
    """Parse /proc/meminfo into total, available, and used KB."""
    meminfo = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            meminfo[key.strip()] = int(value.strip().split()[0])

    total = meminfo["MemTotal"]
    available = meminfo["MemAvailable"]
    return {
        "mem_total_kb": total,
        "mem_available_kb": available,
        "mem_used_kb": total - available,
    }


def read_uptime() -> dict:
    """Parse /proc/uptime into total uptime in seconds."""
    with open("/proc/uptime") as f:
        uptime_seconds = float(f.read().split()[0])
    return {"uptime_seconds": uptime_seconds}


def read_disk_usage(mountpoints: list[str]) -> dict:
    """
    Run df on the given mountpoints and return used_pct per path.

    Returns a dict keyed by mountpoint, e.g.:
        {"disk": {"/": {"used_pct": 42.1, ...}, "/srv/data": {...}}}
    """
    result = {}
    for mp in mountpoints:
        proc = subprocess.run(
            ["df", "--output=size,used,avail,pcent", mp],
            capture_output=True,
            text=True,
            check=True,
        )
        # df output: header line + data line
        lines = proc.stdout.strip().splitlines()
        if len(lines) < 2:
            raise RuntimeError(f"Unexpected df output for {mp!r}: {proc.stdout!r}")
        size_kb, used_kb, avail_kb, pcent = lines[1].split()
        result[mp] = {
            "size_kb": int(size_kb),
            "used_kb": int(used_kb),
            "avail_kb": int(avail_kb),
            "used_pct": float(pcent.rstrip("%")),
        }
    return {"disk": result}


def read_service_status(services: list[str]) -> dict:
    """
    Check systemctl is-active for each service.
    Returns a dict of service -> "active" | "inactive" | "failed" | ...
    """
    result = {}
    for svc in services:
        proc = subprocess.run(
            ["systemctl", "is-active", svc],
            capture_output=True,
            text=True,
        )
        result[svc] = proc.stdout.strip()
    return {"services": result}


# ---------------------------------------------------------------------------
# Snapshot assembly
# ---------------------------------------------------------------------------

DISK_MOUNTPOINTS = ["/", "/srv/data"]
SERVICES = ["k3s", "sshd", "restic-backup.timer"]


def collect() -> dict:
    """Collect all host signals and return a single snapshot dict."""
    now = datetime.now(timezone.utc)
    snapshot = {"collected_at": now.isoformat()}

    snapshot.update(read_cpu_load())
    snapshot.update(read_memory())
    snapshot.update(read_uptime())
    snapshot.update(read_disk_usage(DISK_MOUNTPOINTS))
    snapshot.update(read_service_status(SERVICES))

    return snapshot


# ---------------------------------------------------------------------------
# S3 upload
# ---------------------------------------------------------------------------


def get_s3_client():
    """Build a boto3 S3 client from environment variables."""
    try:
        import boto3
    except ImportError:
        print("ERROR: boto3 is not installed", file=sys.stderr)
        sys.exit(1)

    endpoint = os.environ.get("S3_ENDPOINT_URL")
    if not endpoint:
        print("ERROR: S3_ENDPOINT_URL is not set", file=sys.stderr)
        sys.exit(1)

    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    )


def upload(client, bucket: str, key: str, body: str) -> None:
    """Upload a string body to S3 at the given key."""
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    bucket = os.environ.get("S3_BUCKET")
    if not bucket:
        print("ERROR: S3_BUCKET is not set", file=sys.stderr)
        sys.exit(1)

    exit_code = 0
    snapshot = {}

    try:
        snapshot = collect()
        field_count = len(snapshot)

        timestamp = snapshot["collected_at"].replace(":", "-").replace("+", "-")
        snapshot_key = f"analytics/raw/host/{timestamp}.json"
        snapshot_body = json.dumps(snapshot, indent=2)

        client = get_s3_client()
        upload(client, bucket, snapshot_key, snapshot_body)
        print(f"OK: snapshot uploaded to {snapshot_key}")

    except Exception as exc:
        print(f"ERROR: collection failed: {exc}", file=sys.stderr)
        exit_code = 1
        field_count = len(snapshot)

    finally:
        # Always attempt to write the metadata record
        try:
            meta_ts = (
                datetime.now(timezone.utc)
                .isoformat()
                .replace(":", "-")
                .replace("+", "-")
            )
            meta_key = f"analytics/raw/meta/host/{meta_ts}.json"
            meta = {
                "collected_at": datetime.now(timezone.utc).isoformat(),
                "collector": "host",
                "exit_code": exit_code,
                "field_count": field_count,
            }
            client = get_s3_client()
            upload(client, bucket, meta_key, json.dumps(meta, indent=2))
        except Exception as meta_exc:
            print(f"WARNING: metadata upload failed: {meta_exc}", file=sys.stderr)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
