# Collectors

Raw data extraction. Each subdirectory owns one source domain and writes immutable timestamped snapshots to the S3 raw zone defined in [`analytics/README.md`](../README.md).

| Directory | Source | Runtime |
|-----------|--------|---------|
| `host/` | VPS OS signals (`/proc`, `df`, systemd) | systemd timer on VPS |
| `k8s/` | Kubernetes cluster state via `kubectl` | Flux CronJob in cluster |
| `billing/` | Hetzner static pricing | systemd timer on VPS |

All collectors emit a metadata record to `analytics/raw/meta/{collector}/{timestamp}.json` after each run, regardless of success or failure.
