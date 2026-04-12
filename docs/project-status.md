# Project Status

Last reviewed: 2026-04-11

This document reflects the repository as it exists today. It is a repo-state summary, not a live-cluster health report.

## Current Summary

- The project is a single-node home platform on Hetzner Cloud.
- Infrastructure is defined in Terraform at `bootstrap/terraform-hcloud/`.
- Host bootstrap, hardening, k3s install, and backup tooling are defined in Ansible under `bootstrap/ansible/`.
- Kubernetes state is managed through Flux from `clusters/vps-prod/`.
- Secrets are stored as SOPS-encrypted manifests under `secrets/prod/`.
- cert-manager and CloudNativePG are managed through Flux Helm releases.
- The repo defines three workloads today: `n8n`, `actual`, and `whoami`.
- Repository guardrails now include pre-commit hooks for merge-conflict detection, large-file checks, secret scanning, and SOPS encryption validation.
- A Renovate configuration is committed at the repo root for Flux, Kubernetes manifest, and Terraform dependency updates.
- An analytical layer is in active development under `analytics/`. Phases 1, 2, and 3 are complete.

## Canonical Paths

- Terraform: `bootstrap/terraform-hcloud/`
- Ansible: `bootstrap/ansible/`
- Flux root: `clusters/vps-prod/`
- Platform manifests: `platform/`
- App manifests: `apps/`
- Secrets: `secrets/prod/`
- Analytics: `analytics/`
- Status doc: `docs/project-status.md`

## Infrastructure and Host

- Target provider: Hetzner Cloud
- Host OS target: Debian 12
- Data volume is mounted at `/srv/data`
- k3s local-path storage is configured to use `/srv/data/k3s-local-path`
- k3s is configured as a single-node cluster with embedded etcd
- k3s config enables secrets encryption at rest
- etcd snapshot scheduling and S3 upload configuration are templated into the k3s role

Relevant files:

- `bootstrap/terraform-hcloud/`
- `bootstrap/ansible/playbooks/harden.yml`
- `bootstrap/ansible/playbooks/k3s.yml`
- `bootstrap/ansible/roles/k3s/templates/k3s-config.yml.j2`
- `bootstrap/ansible/roles/k3s/templates/k3s-etcd-s3.yml.j2`

## GitOps Layout

Flux is structured around four top-level kustomizations in `clusters/vps-prod/kustomizations/`:

- `platform`
- `cert-issuers`
- `secrets`
- `apps`

Current dependency order:

1. `platform`
2. `cert-issuers` and `secrets`
3. `apps`

That ordering is important because:

- namespaces are created in `platform`
- `cert-issuers` depends on cert-manager CRDs being present
- `apps` depends on platform resources, issuers, and secrets

## Platform Layer

The platform layer currently contains:

- `platform/namespaces/`
- `platform/cert-manager/`
- `platform/cloudnative-pg/`
- `platform/ingress/`
- `platform/analytics/`

Current state by component:

- Namespaces are defined for `apps-actual`, `apps-n8n`, `cnpg-system`, `infra-postgres`, and `analytics`
- cert-manager is installed from the Jetstack chart, version track `v1.18.*`
- CloudNativePG operator is installed from the CNPG chart, version track `0.27.*`
- The Barman Cloud CNPG plugin is installed from the CNPG chart repository, version track `0.5.*`
- `platform/ingress/kustomization.yaml` is empty, so Traefik is not managed explicitly in this repo
- In practice, the manifests assume the bundled k3s Traefik ingress controller exists
- Analytics RBAC and CronJob are managed under `platform/analytics/`

Notable mismatch:

- `platform/cert-manager-issuers/clusterissuer-staging.yaml` defines a `ClusterIssuer` named `letsencrypt-production`

## PostgreSQL

PostgreSQL is defined as a CloudNativePG-managed cluster.

Current repo-defined model:

- Operator namespace: `cnpg-system`
- Database namespace: `infra-postgres`
- Operator Helm release: `platform/cloudnative-pg/release.yaml`
- Backup plugin Helm release: `platform/cloudnative-pg/plugin-release.yaml`
- Cluster manifest: `apps/postgres/base/postgres-cluster.yaml`
- Backup object store manifest: `apps/postgres/base/objectstore.yaml`
- Scheduled backup manifest: `apps/postgres/base/scheduled-backup.yaml`
- Additional database resource: `apps/postgres/base/database-n8n.yaml`

Current cluster settings in Git:

- Cluster name: `postgres-cluster`
- PostgreSQL major version: `16`
- Instances: `1`
- Storage class: `local-path`
- Storage size: `8Gi`
- Bootstrap database: `n8n`
- Bootstrap owner: `app_platform`
- Managed application role: `n8n`
- WAL archiving is delegated to the Barman Cloud plugin
- Backup object store name: `postgres-backup`
- Scheduled backup name: `daily-backup`
- Scheduled backup cadence: `0 0 3 * * *`
- `inheritedMetadata.labels` includes `home-platform/analytics-collect: "true"` so CNPG pods are included in app-health collection

Current application-facing endpoint expected by the repo:

- `postgres-cluster-rw.infra-postgres.svc.cluster.local`

Secrets involved:

- `secrets/prod/postgres.sops.yaml`
- `secrets/prod/postgres-n8n-auth.sops.yaml`
- `secrets/prod/postgres-backup.sops.yaml`

Important status note:

- PostgreSQL backup is now wired through the CNPG Barman Cloud plugin rather than the deprecated in-tree object store settings
- The repo keeps PostgreSQL backup credentials in `postgres-backup.sops.yaml` and uses them through the `ObjectStore` resource

## Applications

The repo currently ships these app entries from `apps/kustomization.yaml`:

- `whoami`
- `postgres`
- `n8n`
- `actual`

### n8n

- Namespace: `apps-n8n`
- Ingress host: `beta-n8n.titas.dev`
- PVC: `n8n-data`
- Image: `docker.n8n.io/n8nio/n8n:2.12.3`
- Uses PostgreSQL through CNPG
- Explicitly sets `enableServiceLinks: false`
- Pod template carries label `home-platform/analytics-collect: "true"`

### actual

- Namespace: `apps-actual`
- Ingress host: `beta-budget.titas.dev`
- PVC: `actual-data`
- Image: `actualbudget/actual-server:26.3.0`
- Uses an OpenID secret from `secrets/prod/actual.sops.yaml`
- Pod template carries label `home-platform/analytics-collect: "true"`

### whoami

- Namespace: `apps-test`
- Ingress host: `whoami.titas.dev`
- Image: `traefik/whoami:v1.10.4`
- Pod template carries label `home-platform/analytics-collect: "true"`

Important status note:

- `whoami` still creates its namespace from `apps/whoami/base/namespace.yaml`
- That differs from the newer repo convention where namespaces are owned in `platform/namespaces/`
- So `whoami` is still present as a test workload, but it does not follow the same namespace ownership model as `n8n` and `actual`

## Analytical Layer

The analytical layer is under active development at `analytics/`. It follows a phased implementation plan documented in `docs/todo/analytical-layer.md`.

### Phase completion status

| Phase | Description                       | Status                                |
| ----- | --------------------------------- | ------------------------------------- |
| 1     | Storage and project scaffolding   | ✅ Done                                |
| 2     | Host collector                    | ✅ Done                                |
| 3     | Cluster and billing collectors    | 🔄 In progress — 3.4 and 3.5 remaining |
| 4     | DuckDB and dbt modeling           | ⬜ Not started                         |
| 5     | Python dashboard                  | ⬜ Not started                         |
| 6     | Transform job and pipeline wiring | ⬜ Not started                         |

### Architecture

| Layer                | Owner      | Runtime         | Output                         |
| -------------------- | ---------- | --------------- | ------------------------------ |
| Collectors – Host    | Ansible    | systemd timer   | Raw snapshots → Object Storage |
| Collectors – Cluster | Flux       | CronJob         | Raw snapshots → Object Storage |
| Collectors – Billing | Ansible    | systemd timer   | Raw snapshots → Object Storage |
| Modeling             | dbt-duckdb | CronJob (Flux)  | Curated marts in DuckDB        |
| Presentation         | Python app | Flux Deployment | Dashboard HTML + Plotly charts |

### Host collector (Phase 2 — complete)

- Script: `analytics/collectors/host/collect.py`
- Reads `/proc/loadavg`, `/proc/meminfo`, `/proc/uptime`, `df`, `systemctl is-active`
- Writes snapshots to `analytics/raw/host/{timestamp}.json`
- Writes metadata to `analytics/raw/meta/host/{timestamp}.json`
- Ansible role: `bootstrap/ansible/roles/analytics-host-collector/`
- Playbook: `bootstrap/ansible/playbooks/analytics.yml`
- Timer schedule: every 15 minutes (`OnCalendar=*:0/15`)
- Golden-file tests: `analytics/tests/test_host_collector.py`
- Fixture: `analytics/tests/fixtures/host/sample.json`

### Cluster collector (Phase 3 — partially complete)

- Script: `analytics/collectors/k8s/collect.py`
- Collectors: `cluster`, `workloads`, `ingress`, `certs`, `events`, `app-health`
- App-health uses label-based pod discovery: `home-platform/analytics-collect=true`
- Writes snapshots to `analytics/raw/k8s/{collector}/{timestamp}.json`
- Writes metadata to `analytics/raw/meta/k8s/{collector}/{timestamp}.json`
- Container image: `ghcr.io/syroqt/home-platform/analytics-collector:sha-a7dbc93`
- Image built by: `.github/workflows/analytics-collector-image.yml`
- Dockerfile: `analytics/collectors/k8s/Dockerfile`
- Base image: `python:3.12-slim` with `kubectl v1.34.5` and `boto3`
- CronJob manifest: `platform/analytics/cronjob.yaml`
- Schedule: `5,20,35,50 * * * *` (offset 5 minutes from host collector)
- RBAC: `platform/analytics/clusterrole.yaml`, `clusterrolebinding.yaml`, `serviceaccount.yaml`
- Namespace: `analytics`
- S3 secret: `secrets/prod/analytics-s3-k8s.sops.yaml` (namespace: `analytics`)

### Object Storage conventions

- Bucket: dedicated analytics bucket in Hetzner Object Storage (nbg1)
- Raw zone layout:
  - `analytics/raw/host/`
  - `analytics/raw/k8s/cluster/`
  - `analytics/raw/k8s/workloads/`
  - `analytics/raw/k8s/ingress/`
  - `analytics/raw/k8s/certs/`
  - `analytics/raw/k8s/events/`
  - `analytics/raw/k8s/app-health/`
  - `analytics/raw/billing/`
  - `analytics/raw/meta/`
- Retention policy: not yet implemented — planned for Phase 6 (90-day target)
- Estimated storage growth: ~200 KB per cluster collector run, ~1 KB per host run

### Remaining analytical layer tasks

- 3.4 — fixture tests for k8s collector output
- 3.5 — billing collector (Ansible-managed, monthly timer)
- Phase 4 — DuckDB and dbt modeling
- Phase 5 — Python dashboard
- Phase 6 — transform job, pipeline wiring, retention policy

### Secrets

- `secrets/prod/analytics-s3.sops.yaml` — used by Ansible host collector
- `secrets/prod/analytics-s3-k8s.sops.yaml` — used by Flux CronJob in `analytics` namespace

## Secrets

Current secret management model:

- SOPS config lives in `.sops.yaml`
- Only `data` and `stringData` are encrypted
- Flux decrypts `secrets/prod/` using the `flux-system/sops-age` secret
- Pre-commit enforces a local SOPS encryption check for files under `secrets/**/*.sops.yaml`
- Secret scanning baseline and pre-commit integration are committed in `.secrets.baseline` and `.pre-commit-config.yaml`

Secret files currently committed:

- `secrets/prod/demo-secret.sops.yaml`
- `secrets/prod/n8n.sops.yaml`
- `secrets/prod/postgres.sops.yaml`
- `secrets/prod/postgres-backup.sops.yaml`
- `secrets/prod/postgres-n8n-auth.sops.yaml`
- `secrets/prod/actual.sops.yaml`
- `secrets/prod/analytics-s3.sops.yaml`
- `secrets/prod/analytics-s3-k8s.sops.yaml`

Relevant repo guardrail files:

- `.pre-commit-config.yaml`
- `.secrets.baseline`
- `scripts/check-sops-encrypted.sh`

## Backup and Recovery

The backup story is implemented in two layers.

Implemented in the repo:

- k3s etcd snapshot scheduling and S3 upload configuration via Ansible
- Restic install and systemd timer via `bootstrap/ansible/roles/restic/`
- Restic excludes the PostgreSQL PVC path, so PostgreSQL is not backed up through host-level file snapshots
- PostgreSQL base backups and WAL archiving are configured through CloudNativePG plus the Barman Cloud plugin
- PostgreSQL scheduled backups target Hetzner Object Storage via `apps/postgres/base/objectstore.yaml`
- backup playbook at `bootstrap/ansible/playbooks/backup.yml`
- disaster recovery runbook at `docs/drd/backup-and-recovery.md`

Still incomplete or not fully wired:

- PostgreSQL restore drill procedure should be exercised and documented against the plugin-based backup flow
- `docs/drd/backup-and-recovery.md` still contains older assumptions that predate the current CNPG plugin-based backup wiring and should be revised

## Renovation / Update Automation

Automated dependency update configuration is now committed in `renovate.json`.

Current status:

- Renovate is configured with `config:recommended`
- Updates are scheduled for weekends
- Flux, Kubernetes manifest, and Terraform managers are enabled in config
- Major updates are labeled for manual review
- The repo config does not enable automerge
- Renovate tracks `kubectl` version in `analytics/collectors/k8s/Dockerfile` via inline comment datasource annotation
- Renovate tracks the analytics-collector image tag in `platform/analytics/cronjob.yaml`

Important scope note:

- This document reflects committed repo config only; whether Renovate is actively running still depends on repository-side app/install enablement outside this repo

## Repo Guardrails

Current repo hygiene controls committed in Git:

- Pre-commit hooks check for large added files and merge conflicts
- `detect-secrets` is configured with `.secrets.baseline`
- SOPS-encrypted secret files are validated by `scripts/check-sops-encrypted.sh`
- The secret-scanning config explicitly excludes encrypted SOPS payload files from false positives

## What Is Stable vs. What Is Still In Flight

Stable repo patterns:

- Terraform for infrastructure
- Ansible for host bootstrap and k3s setup
- Flux for GitOps reconciliation
- SOPS for secret storage
- pre-commit secret and encryption guardrails
- CNPG for PostgreSQL
- `base` plus `prod` app layout
- Host and cluster analytics collectors running and writing to Object Storage

Still in flight:

- explicit ingress platform management in Git
- PostgreSQL restore drill and recovery documentation polish
- cleanup or normalization of the legacy `whoami` test workload layout
- validation that Renovate is enabled and operating against the repository host
- analytics Phase 3 completion (fixture tests, billing collector)
- analytics Phases 4–6 (dbt modeling, dashboard, pipeline wiring)

## Practical Bottom Line

The repository is past initial bootstrap and now defines a working GitOps-shaped platform with:

- infrastructure provisioning
- host hardening
- k3s bootstrap
- Flux reconciliation
- encrypted secrets
- pre-commit repo guardrails
- cert-manager
- CloudNativePG
- a PostgreSQL-backed `n8n` app
- an `actual` deployment
- a retained `whoami` test app
- a host analytics collector running every 15 minutes via systemd
- a cluster analytics collector running every 15 minutes via Flux CronJob

The main unfinished areas are restore validation for PostgreSQL, explicit ingress ownership in Git, documentation drift cleanup, confirming Renovate is active at the repository host level, and completing the analytical layer through Phases 3–6.
