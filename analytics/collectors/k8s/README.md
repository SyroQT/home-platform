# Kubernetes Collector

Runs six `kubectl` collectors every 15 minutes (offset +5 from host collector) and writes one JSON snapshot per collector to S3.

## What It Collects

| Collector | kubectl command | Output path |
|-----------|----------------|-------------|
| `cluster` | `get nodes` | `analytics/raw/k8s/cluster/` |
| `workloads` | `get deployments,pods -A` | `analytics/raw/k8s/workloads/` |
| `ingress` | `get ingress -A` | `analytics/raw/k8s/ingress/` |
| `certs` | `get certificates -A` | `analytics/raw/k8s/certs/` |
| `events` | `get events -A --sort-by=.lastTimestamp` | `analytics/raw/k8s/events/` |
| `app-health` | `get pods -A -l home-platform/analytics-collect=true` | `analytics/raw/k8s/app-health/` |

All collectors project only analytically useful fields — full Kubernetes object specs are not stored.

`app-health` uses label-based pod discovery: pods must carry `home-platform/analytics-collect: "true"` to be included.

Metadata per collector: `analytics/raw/meta/k8s/{collector}/{timestamp}.json`

## Testing

```bash
cd analytics && uv run pytest tests/test_k8s_collectors.py
```

38 golden-file tests, fully offline. Fixtures at `tests/fixtures/k8s/{cluster,workloads,ingress,certs,events,app-health}/`.

## Deployment

Runs as a Kubernetes CronJob in the `analytics` namespace, managed by Flux.

- CronJob manifest: `platform/analytics/cronjob.yaml`
- Schedule: `5,20,35,50 * * * *`
- RBAC: `platform/analytics/clusterrole.yaml`, `clusterrolebinding.yaml`, `serviceaccount.yaml`
- Container image: `ghcr.io/syroqt/home-platform/analytics-collector` (built by `.github/workflows/analytics-collector-image.yml`)
- Credentials: Kubernetes Secret from `secrets/prod/analytics-s3-k8s.sops.yaml` (namespace: `analytics`)

The image bundles `kubectl` and `boto3`. The `KUBECTL_VERSION` build arg is tracked by Renovate via the inline datasource annotation in `Dockerfile`.

## Environment Variables

Injected via Kubernetes Secret:

| Variable | Description |
|----------|-------------|
| `S3_ENDPOINT_URL` | Hetzner Object Storage endpoint (nbg1) |
| `S3_BUCKET` | Analytics bucket name |
| `AWS_ACCESS_KEY_ID` | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key |
