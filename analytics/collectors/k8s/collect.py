#!/usr/bin/env python3
"""
Cluster collector for the analytics pipeline.

Runs kubectl commands against the in-cluster API and writes timestamped
JSON snapshots to Object Storage. Projects only analytically useful fields
before upload to avoid capturing full Kubernetes object specs.

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


# ---------------------------------------------------------------------------
# Field projections
# ---------------------------------------------------------------------------


def _project_node(node: dict) -> dict:
    meta = node.get("metadata", {})
    status = node.get("status", {})
    info = status.get("nodeInfo", {})
    return {
        "name": meta.get("name"),
        "labels": meta.get("labels", {}),
        "conditions": status.get("conditions", []),
        "allocatable": status.get("allocatable", {}),
        "capacity": status.get("capacity", {}),
        "node_info": {
            "architecture": info.get("architecture"),
            "kernel_version": info.get("kernelVersion"),
            "kubelet_version": info.get("kubeletVersion"),
            "os_image": info.get("osImage"),
            "container_runtime_version": info.get("containerRuntimeVersion"),
        },
    }


def _project_deployment(item: dict) -> dict:
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    return {
        "kind": "Deployment",
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "labels": meta.get("labels", {}),
        "replicas": spec.get("replicas"),
        "strategy": spec.get("strategy", {}).get("type"),
        "status": {
            "replicas": status.get("replicas", 0),
            "ready_replicas": status.get("readyReplicas", 0),
            "available_replicas": status.get("availableReplicas", 0),
            "conditions": status.get("conditions", []),
        },
    }


def _project_pod(item: dict) -> dict:
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    containers = spec.get("containers", [])
    container_statuses = status.get("containerStatuses", [])
    return {
        "kind": "Pod",
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "labels": {
            k: v
            for k, v in meta.get("labels", {}).items()
            if not k.startswith("pod-template-hash")
            and not k.startswith("controller-uid")
            and not k.startswith("batch.kubernetes.io")
        },
        "phase": status.get("phase"),
        "conditions": status.get("conditions", []),
        "containers": [
            {
                "name": c.get("name"),
                "image": c.get("image"),
                "resources": c.get("resources", {}),
            }
            for c in containers
        ],
        "container_statuses": [
            {
                "name": cs.get("name"),
                "ready": cs.get("ready"),
                "restart_count": cs.get("restartCount"),
                "state": cs.get("state"),
            }
            for cs in container_statuses
        ],
    }


def _project_ingress(item: dict) -> dict:
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    return {
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "ingress_class": spec.get("ingressClassName"),
        "rules": [{"host": r.get("host")} for r in spec.get("rules", [])],
        "tls": [
            {"hosts": t.get("hosts", []), "secret_name": t.get("secretName")}
            for t in spec.get("tls", [])
        ],
        "load_balancer_ips": [
            i.get("ip") for i in status.get("loadBalancer", {}).get("ingress", [])
        ],
    }


def _project_cert(item: dict) -> dict:
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})
    return {
        "name": meta.get("name"),
        "namespace": meta.get("namespace"),
        "dns_names": spec.get("dnsNames", []),
        "common_name": spec.get("commonName"),
        "issuer_ref": spec.get("issuerRef", {}),
        "not_after": status.get("notAfter"),
        "not_before": status.get("notBefore"),
        "renewal_time": status.get("renewalTime"),
        "conditions": status.get("conditions", []),
    }


def _project_event(item: dict) -> dict:
    return {
        "namespace": item.get("metadata", {}).get("namespace"),
        "name": item.get("metadata", {}).get("name"),
        "reason": item.get("reason"),
        "type": item.get("type"),
        "message": item.get("message"),
        "involved_object": {
            "kind": item.get("involvedObject", {}).get("kind"),
            "name": item.get("involvedObject", {}).get("name"),
            "namespace": item.get("involvedObject", {}).get("namespace"),
        },
        "first_timestamp": item.get("firstTimestamp"),
        "last_timestamp": item.get("lastTimestamp"),
        "event_time": item.get("eventTime"),
        "count": item.get("count"),
        "reporting_component": item.get("reportingComponent"),
    }


# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------


def collect_cluster() -> dict:
    raw = kubectl_json("get", "nodes")
    return {
        "kind": "NodeList",
        "items": [_project_node(n) for n in raw.get("items", [])],
    }


def collect_workloads() -> dict:
    raw = kubectl_json("get", "deployments,pods", "-A")
    items = []
    for item in raw.get("items", []):
        kind = item.get("kind")
        if kind == "Deployment":
            items.append(_project_deployment(item))
        elif kind == "Pod":
            items.append(_project_pod(item))
    return {"kind": "WorkloadList", "items": items}


def collect_ingress() -> dict:
    raw = kubectl_json("get", "ingress", "-A")
    return {
        "kind": "IngressList",
        "items": [_project_ingress(i) for i in raw.get("items", [])],
    }


def collect_certs() -> dict:
    raw = kubectl_json("get", "certificates", "-A")
    return {
        "kind": "CertificateList",
        "items": [_project_cert(i) for i in raw.get("items", [])],
    }


def collect_events() -> dict:
    raw = kubectl_json("get", "events", "-A", "--sort-by=.lastTimestamp")
    return {
        "kind": "EventList",
        "items": [_project_event(i) for i in raw.get("items", [])],
    }


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


def run_collector(name: str, fn, bucket: str, client, s3_key_prefix: str) -> int:
    """
    Run a single collector function, upload its output, emit metadata.
    Returns 0 on success, 1 on failure.
    """
    exit_code = 0
    field_count = 0

    try:
        result = fn()
        now = datetime.now(timezone.utc)
        timestamp = now.isoformat().replace(":", "-").replace("+", "-")
        date_path = now.strftime("%Y/%m/%d")

        body = json.dumps(result, indent=2)
        if isinstance(result, list):
            field_count = len(result)
        elif "items" in result:
            field_count = len(result["items"])
        else:
            field_count = len(result)

        key = f"{s3_key_prefix}/{date_path}/{timestamp}.json"
        upload(client, bucket, key, body)
        print(f"OK: {name} uploaded to {key}")

    except Exception as exc:
        print(f"ERROR: {name} failed: {exc}", file=sys.stderr)
        exit_code = 1

    finally:
        try:
            meta_now = datetime.now(timezone.utc)
            meta_ts = meta_now.isoformat().replace(":", "-").replace("+", "-")
            meta_date_path = meta_now.strftime("%Y/%m/%d")
            meta = {
                "collected_at": datetime.now(timezone.utc).isoformat(),
                "collector": f"k8s/{name}",
                "exit_code": exit_code,
                "field_count": field_count,
            }
            meta_key = f"analytics/raw/meta/k8s/{name}/{meta_date_path}/{meta_ts}.json"
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
    ("cluster", collect_cluster, "analytics/raw/k8s/cluster"),
    ("workloads", collect_workloads, "analytics/raw/k8s/workloads"),
    ("ingress", collect_ingress, "analytics/raw/k8s/ingress"),
    ("certs", collect_certs, "analytics/raw/k8s/certs"),
    ("events", collect_events, "analytics/raw/k8s/events"),
    ("app-health", collect_app_health, "analytics/raw/k8s/app-health"),
]


def main() -> None:
    bucket = os.environ.get("S3_BUCKET")
    if not bucket:
        print("ERROR: S3_BUCKET is not set", file=sys.stderr)
        sys.exit(1)

    client = get_s3_client()

    results = []
    for name, fn, prefix in COLLECTORS:
        code = run_collector(name, fn, bucket, client, prefix)
        results.append((name, code))

    failed = [name for name, code in results if code != 0]
    if failed:
        print(f"FAILED collectors: {', '.join(failed)}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
