# Project Status

Last reviewed: 2026-04-20

This document reflects the repository as it exists today. It is a repo-state summary, not a live-cluster health report. Current working branch: `analytics` (Phase 4 in progress, not yet merged to main).

## Current Summary

- Single-node home platform on Hetzner Cloud, GitOps-managed via Flux from `clusters/vps-prod/`.
- Infrastructure: Terraform at `bootstrap/terraform-hcloud/`; host bootstrap + k3s via Ansible at `bootstrap/ansible/`.
- Secrets: SOPS-encrypted manifests under `secrets/prod/`, decrypted by Flux.
- Workloads: `n8n`, `actual`, `linkding`, `whoami` (test), `postgres`.
- Analytics layer: Phases 1–4 complete and deployed. Collectors running, dbt models committed, `analytics-dbt-runner` Ansible role deployed with two systemd timers (daily main + meta runs). `analytics` branch pending merge to main.

## Canonical Paths

| Area | Path |
|------|------|
| Terraform | `bootstrap/terraform-hcloud/` |
| Ansible | `bootstrap/ansible/` |
| Flux root | `clusters/vps-prod/` |
| Platform manifests | `platform/` |
| App manifests | `apps/` |
| Secrets | `secrets/prod/` |
| Analytics | `analytics/` |

## Infrastructure and Host

- Hetzner Cloud, Debian 12, single-node k3s with embedded etcd
- Data volume at `/srv/data`; k3s local-path storage uses `/srv/data/k3s-local-path`
- Secrets encryption at rest enabled in k3s config
- etcd snapshots scheduled and uploaded to S3 via Ansible
- k3s image GC is configured (added Apr 2026)
- k3s drive/etcd GC settings updated Apr 2026

## GitOps Layout

Four top-level Flux kustomizations in `clusters/vps-prod/kustomizations/`:

1. `platform` — creates namespaces, installs operators
2. `cert-issuers` and `secrets` — depend on platform (need CRDs)
3. `apps` — depends on all of the above

Notable mismatch: `platform/cert-manager-issuers/clusterissuer-staging.yaml` defines a `ClusterIssuer` named `letsencrypt-production`.

## Platform Layer

- Namespaces: `apps-actual`, `apps-n8n`, `apps-linkding`, `cnpg-system`, `infra-postgres`, `analytics`
- cert-manager: Jetstack chart, track `v1.18.*`
- CloudNativePG operator: track `0.27.*`; Barman Cloud plugin: track `0.5.*`
- Traefik: bundled k3s Traefik, not explicitly managed in `platform/ingress/` (empty kustomization)
- Analytics RBAC + CronJob: `platform/analytics/`

## PostgreSQL

- CloudNativePG-managed cluster `postgres-cluster` in namespace `infra-postgres`
- PostgreSQL 16, 1 instance, `local-path` storage, 8Gi
- WAL archiving and base backups via Barman Cloud plugin (not in-tree object store)
- Application endpoint: `postgres-cluster-rw.infra-postgres.svc.cluster.local`
- Key secrets: `postgres.sops.yaml`, `postgres-n8n-auth.sops.yaml`, `postgres-backup.sops.yaml`

Outstanding: restore drill procedure not yet exercised against plugin-based backup flow; `docs/drd/backup-and-recovery.md` predates the plugin-based setup.

## Applications

| App | Namespace | Host | Notes |
|-----|-----------|------|-------|
| n8n | `apps-n8n` | `beta-n8n.titas.dev` | Custom GHCR image `ghcr.io/syroqt/home-platform/n8n:sha-ff70fd8`, `imagePullPolicy: IfNotPresent`; uses PostgreSQL |
| actual | `apps-actual` | `beta-budget.titas.dev` | OpenID secret from `actual.sops.yaml` |
| linkding | `apps-linkding` | `links.titas.dev` | OpenID secret from `linkding.sops.yaml` |
| whoami | `apps-test` | `whoami.titas.dev` | Test workload; creates own namespace (not via `platform/namespaces/`) |

All app pods carry label `home-platform/analytics-collect: "true"` for app-health collection.

## Analytical Layer

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Storage and project scaffolding | ✅ Done |
| 2 | Host collector | ✅ Done |
| 3 | Cluster collector | ✅ Done |
| 3.5 | Billing collector | 🔄 Deferred — billing dir committed (README only), collect.py pending |
| 4 | DuckDB and dbt modeling | ✅ Done and deployed — incremental staging tables, two systemd timers running daily |
| 5 | Python dashboard | ⬜ Not started |
| 6 | Transform job, pipeline wiring, retention | ⬜ Not started |

### Architecture

| Layer | Owner | Runtime | Output |
|-------|-------|---------|--------|
| Host collector | Ansible | systemd timer (every 15 min) | Raw snapshots → S3 |
| Cluster collector | Flux | CronJob (every 15 min, 5-min offset) | Raw snapshots → S3 |
| Billing collector | Ansible | systemd timer (monthly) | Raw snapshots → S3 |
| Meta modeling (dbt-duckdb) | Ansible (`analytics-dbt-runner-meta`) | systemd timer daily 05:00 | Meta models in DuckDB |
| Main modeling (dbt-duckdb) | Ansible (`analytics-dbt-runner`) | systemd timer daily 06:00 | Curated marts in DuckDB |
| Presentation | Python app | Flux Deployment | Dashboard HTML + Plotly |

### Collectors (complete)

- **Host** (`analytics/collectors/host/collect.py`): reads `/proc/loadavg`, `/proc/meminfo`, `df`, systemd status → `analytics/raw/host/`
- **Cluster** (`analytics/collectors/k8s/collect.py`): collectors `cluster`, `workloads`, `ingress`, `certs`, `events`, `app-health` → `analytics/raw/k8s/{collector}/`; container image `ghcr.io/syroqt/home-platform/analytics-collector:sha-a7dbc93`
- **Billing** (`analytics/collectors/billing/`): monthly, static pricing for CX23/Object Storage/block volume/IPv4 — collect.py not yet committed

### dbt / DuckDB (Phase 4)

Committed models (all on `analytics` branch):

- **Staging**: `stg_host_snapshots`, `stg_k8s_cluster`, `stg_k8s_workloads`, `stg_k8s_app_health`, `stg_k8s_certs`, `stg_k8s_events`, `stg_k8s_ingress`, `stg_meta_pipeline_runs`
- **Intermediate**: `int_host_snapshots_enriched`
- **Marts**: `mart_host_status_latest`, `mart_host_status_history`, `mart_k8s_status_latest`, `mart_k8s_status_history`, `mart_app_health_latest`, `mart_pipeline_runs`

Production runner script: `analytics/dbt/run_dbt.sh`. Crash safety via DuckDB WAL — no tmp-file swap needed.

Key decisions:
- DuckDB reads S3 via `httpfs`; requires `SET s3_url_style='path'` for Hetzner Object Storage (nbg1)
- DuckDB file at `/srv/data/analytics/analytics.duckdb` (50 GB block volume)
- Staging tables are **incremental** — each daily run appends only new S3 files; intermediate and marts rebuild from local DuckDB tables (no S3 reads, fast)
- Meta pipeline (`stg_meta_pipeline_runs` + `tag:meta` models) runs separately at 05:00, decoupled from the main daily run at 06:00
- dbt runs as VPS systemd timers (Ansible-managed), not Flux CronJobs
- `mart_billing_daily` stubbed until billing snapshots exist in S3

Phase 4 is complete and deployed. See [docs/setup/08_analytics-dbt-runner.md](docs/setup/08_analytics-dbt-runner.md) for deployment and verification.

### Object Storage

- Bucket: dedicated analytics bucket in Hetzner nbg1
- Raw path layout: `analytics/raw/{host,k8s/{cluster,workloads,ingress,certs,events,app-health},billing,meta}/`
- Secrets: `analytics-s3.sops.yaml` (Ansible), `analytics-s3-k8s.sops.yaml` (Flux, namespace `analytics`)
- Retention: not implemented — planned Phase 6 (90-day target)

## Secrets

- SOPS config in `.sops.yaml`; only `data`/`stringData` encrypted
- Flux decrypts via `flux-system/sops-age`
- Pre-commit enforces SOPS encryption check for `secrets/**/*.sops.yaml`

Current secret files: `demo-secret`, `n8n`, `postgres`, `postgres-backup`, `postgres-n8n-auth`, `actual`, `analytics-s3`, `analytics-s3-k8s`, `linkding`.

## Backup and Recovery

- k3s etcd snapshots: Ansible, uploaded to S3
- Host-level: Restic via `bootstrap/ansible/roles/restic/` (excludes PostgreSQL PVC)
- PostgreSQL: CNPG + Barman Cloud plugin, scheduled backups to Hetzner Object Storage
- Runbook: `docs/drd/backup-and-recovery.md` (predates plugin-based backup — needs revision)

## Renovation / Update Automation

- `renovate.json5`: `config:recommended`, weekend schedule, no automerge
- Managers enabled: Flux, Kubernetes manifest, Terraform, Dockerfile
- Tracks `kubectl` version in `analytics/collectors/k8s/Dockerfile` via inline annotation
- Tracks analytics-collector image tag in `platform/analytics/cronjob.yaml`
- Whether Renovate is actively running depends on repo-host app enablement (outside this repo)

## Repo Guardrails

- Pre-commit: large-file check, merge-conflict detection, `detect-secrets` (`.secrets.baseline`), SOPS encryption validation (`scripts/check-sops-encrypted.sh`)

## What Is Stable vs. What Is Still In Flight

**Stable:**
- Terraform, Ansible, Flux, SOPS, pre-commit guardrails
- CNPG for PostgreSQL with Barman Cloud backup
- Host and cluster analytics collectors writing to S3
- dbt model layer deployed and running (incremental staging + daily mart rebuild, meta pipeline decoupled)

**In flight:**
- Merging `analytics` branch to `main`
- Root disk growth investigation — K3s/containerd storage on `/` growing; see `docs/todo/root-disk-growth-investigation.md`
- Billing collector `collect.py` and Ansible wiring
- Analytics Phases 5–6 (dashboard, pipeline wiring, retention)
- PostgreSQL restore drill + `docs/drd/backup-and-recovery.md` revision (predates Barman Cloud plugin)
- Explicit ingress management in Git (`platform/ingress/` is empty)
- `whoami` namespace convention cleanup
- Confirming Renovate is active at repository host level
