#!/usr/bin/env python3
"""
Cluster collector for the analytics pipeline.

Runs kubectl commands against the in-cluster API and writes timestamped
JSON snapshots to Object Storage. Emits a metadata record per collector
on success or failure.

Environment variables (injected by Kubernetes Secret):
    S3_ENDPOINT_URL        Hetzner Object Storage endpoint
    S3_BUCKET              Target bucket name
    AWS_ACCESS_KEY_ID      S3 access key
    AWS_SECRET_ACCESS_KEY  S3 secret key
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# kubectl helpers
# ---------------------------------------------------------------------------


def kubectl_json(*args) -> dict:
    """Run a kubectl command with -o json and return parsed output."""
    proc = subprocess.run(
        ["kubectl", *args, "-o", "json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(proc.stdout)


def kubectl_text(*args) -> str:
    """Run a kubectl command and return raw text output."""
    proc = subprocess.run(
        ["kubectl", *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return proc.stdout


# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------


def collect_cluster() -> dict:
    return kubectl_json("get", "nodes")


def collect_workloads() -> dict:
    return kubectl_json("get", "deployments,pods", "-A")


def collect_ingress() -> dict:
    return kubectl_json("get", "ingress", "-A")


def collect_certs() -> dict:
    return kubectl_json("get", "certificates", "-A")


def collect_events() -> dict:
    """Collect cluster events as structured JSON, sorted by lastTimestamp."""
    return kubectl_json("get", "events", "-A", "--sort-by=.lastTimestamp")


def collect_app_health() -> dict:
    """
    Discover pods opted in via label home-platform/analytics-collect=true
    and collect readiness and restart counts per pod, grouped by namespace/app.
    """
    data = kubectl_json(
        "get", "pods", "-A", "-l", "home-platform/analytics-collect=true"
    )

    result = {}
    for pod in data.get("items", []):
        namespace = pod["metadata"]["namespace"]
        app = pod["metadata"]["labels"].get("app", pod["metadata"]["name"])
        key = f"{namespace}/{app}"

        container_statuses = pod["status"].get("containerStatuses", [])
        entry = {
            "name": pod["metadata"]["name"],
            "phase": pod["status"].get("phase"),
            "ready": all(cs["ready"] for cs in container_statuses),
            "restart_count": sum(cs["restartCount"] for cs in container_statuses),
        }

        result.setdefault(key, []).append(entry)

    return result


# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------


def get_s3_client():
    try:
        import boto3
    except ImportError:
        print("ERROR: boto3 is not installed", file=sys.stderr)
        sys.exit(1)

    endpoint = os.environ.get("S3_ENDPOINT_URL")
    if not endpoint:
        print("ERROR: S3_ENDPOINT_URL is not set", file=sys.stderr)
        sys.exit(1)

    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    if not access_key:
        print("ERROR: AWS_ACCESS_KEY_ID is not set", file=sys.stderr)
        sys.exit(1)
    if not secret_key:
        print("ERROR: AWS_SECRET_ACCESS_KEY is not set", file=sys.stderr)
        sys.exit(1)

    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )


def upload(client, bucket: str, key: str, body: str) -> None:
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )


# ---------------------------------------------------------------------------
# Run a single collector with metadata emission
# ---------------------------------------------------------------------------


def run_collector(
    name: str, fn, bucket: str, client, s3_key_prefix: str, is_text: bool = False
) -> int:
    """
    Run a single collector function, upload its output, emit metadata.
    Returns 0 on success, 1 on failure.
    """
    exit_code = 0
    field_count = 0

    try:
        result = fn()
        timestamp = (
            datetime.now(timezone.utc).isoformat().replace(":", "-").replace("+", "-")
        )

        if is_text:
            body = result
            field_count = len(result.splitlines())
            ext = "txt"
        else:
            body = json.dumps(result, indent=2)
            if isinstance(result, list):
                field_count = len(result)
            elif "items" in result:
                field_count = len(result["items"])
            else:
                field_count = len(result)
            ext = "json"

        key = f"{s3_key_prefix}/{timestamp}.{ext}"
        upload(client, bucket, key, body)
        print(f"OK: {name} uploaded to {key}")

    except Exception as exc:
        print(f"ERROR: {name} failed: {exc}", file=sys.stderr)
        exit_code = 1

    finally:
        try:
            meta_ts = (
                datetime.now(timezone.utc)
                .isoformat()
                .replace(":", "-")
                .replace("+", "-")
            )
            meta = {
                "collected_at": datetime.now(timezone.utc).isoformat(),
                "collector": f"k8s/{name}",
                "exit_code": exit_code,
                "field_count": field_count,
            }
            meta_key = f"analytics/raw/meta/k8s/{name}/{meta_ts}.json"
            upload(client, bucket, meta_key, json.dumps(meta, indent=2))
        except Exception as meta_exc:
            print(
                f"WARNING: {name} metadata upload failed: {meta_exc}", file=sys.stderr
            )

    return exit_code


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

COLLECTORS = [
    ("cluster", collect_cluster, "analytics/raw/k8s/cluster", False),
    ("workloads", collect_workloads, "analytics/raw/k8s/workloads", False),
    ("ingress", collect_ingress, "analytics/raw/k8s/ingress", False),
    ("certs", collect_certs, "analytics/raw/k8s/certs", False),
    ("events", collect_events, "analytics/raw/k8s/events", False),
    ("app-health", collect_app_health, "analytics/raw/k8s/app-health", False),
]


def main() -> None:
    bucket = os.environ.get("S3_BUCKET")
    if not bucket:
        print("ERROR: S3_BUCKET is not set", file=sys.stderr)
        sys.exit(1)

    client = get_s3_client()

    results = []
    for name, fn, prefix, is_text in COLLECTORS:
        code = run_collector(name, fn, bucket, client, prefix, is_text)
        results.append((name, code))

    failed = [name for name, code in results if code != 0]
    if failed:
        print(f"FAILED collectors: {', '.join(failed)}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
