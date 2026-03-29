# Project Status

Last reviewed: 2026-03-29

This document reflects the repository as it exists today. It is a repo-state summary, not a live-cluster health report.

## Current Summary

- The project is a single-node home platform on Hetzner Cloud.
- Infrastructure is defined in Terraform at `bootstrap/terraform-hcloud/`.
- Host bootstrap, hardening, k3s install, and backup tooling are defined in Ansible under `bootstrap/ansible/`.
- Kubernetes state is managed through Flux from `clusters/vps-prod/`.
- Secrets are stored as SOPS-encrypted manifests under `secrets/prod/`.
- cert-manager and CloudNativePG are managed through Flux Helm releases.
- The repo defines three workloads today: `n8n`, `actual`, and `whoami`.

## Canonical Paths

- Terraform: `bootstrap/terraform-hcloud/`
- Ansible: `bootstrap/ansible/`
- Flux root: `clusters/vps-prod/`
- Platform manifests: `platform/`
- App manifests: `apps/`
- Secrets: `secrets/prod/`
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

Current state by component:

- Namespaces are defined for `apps-actual`, `apps-n8n`, `cnpg-system`, and `infra-postgres`
- cert-manager is installed from the Jetstack chart, version track `v1.18.*`
- CloudNativePG operator is installed from the CNPG chart, version track `0.27.*`
- The Barman Cloud CNPG plugin is installed from the CNPG chart repository, version track `0.5.*`
- `platform/ingress/kustomization.yaml` is empty, so Traefik is not managed explicitly in this repo
- In practice, the manifests assume the bundled k3s Traefik ingress controller exists

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

### actual

- Namespace: `apps-actual`
- Ingress host: `beta-budget.titas.dev`
- PVC: `actual-data`
- Image: `actualbudget/actual-server:26.3.0`
- Uses an OpenID secret from `secrets/prod/actual.sops.yaml`

### whoami

- Namespace: `apps-test`
- Ingress host: `whoami.titas.dev`
- Image: `traefik/whoami:v1.10.4`

Important status note:

- `whoami` still creates its namespace from `apps/whoami/base/namespace.yaml`
- That differs from the newer repo convention where namespaces are owned in `platform/namespaces/`
- So `whoami` is still present as a test workload, but it does not follow the same namespace ownership model as `n8n` and `actual`

## Secrets

Current secret management model:

- SOPS config lives in `.sops.yaml`
- Only `data` and `stringData` are encrypted
- Flux decrypts `secrets/prod/` using the `flux-system/sops-age` secret

Secret files currently committed:

- `secrets/prod/demo-secret.sops.yaml`
- `secrets/prod/n8n.sops.yaml`
- `secrets/prod/postgres.sops.yaml`
- `secrets/prod/postgres-backup.sops.yaml`
- `secrets/prod/postgres-n8n-auth.sops.yaml`
- `secrets/prod/actual.sops.yaml`

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
- `docs/todo/backup.md` may still contain older assumptions and should be aligned with the current plugin-based design

## Renovation / Update Automation

This repo has planning notes for automated dependency updates in `docs/todo/renovate.md`, but no Renovate configuration is committed yet.

Current status:

- update automation is planned
- update automation is not yet implemented in this repo

## What Is Stable vs. What Is Still In Flight

Stable repo patterns:

- Terraform for infrastructure
- Ansible for host bootstrap and k3s setup
- Flux for GitOps reconciliation
- SOPS for secret storage
- CNPG for PostgreSQL
- `base` plus `prod` app layout

Still in flight:

- explicit ingress platform management in Git
- PostgreSQL restore drill and recovery documentation polish
- formal update automation
- cleanup or normalization of the legacy `whoami` test workload layout

## Practical Bottom Line

The repository is past initial bootstrap and now defines a working GitOps-shaped platform with:

- infrastructure provisioning
- host hardening
- k3s bootstrap
- Flux reconciliation
- encrypted secrets
- cert-manager
- CloudNativePG
- a PostgreSQL-backed `n8n` app
- an `actual` deployment
- a retained `whoami` test app

The main unfinished areas are restore validation for PostgreSQL, explicit ingress ownership in Git, and update automation.
