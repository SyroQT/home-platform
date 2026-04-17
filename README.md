# Home Platform

A self-hosted platform running on a single Hetzner VPS. Infrastructure is provisioned with Terraform and Ansible, the cluster runs k3s, and all workloads are managed through GitOps with Flux.

## Architecture overview

| Layer | Technology |
|---|---|
| Infrastructure | Hetzner Cloud, Terraform |
| Server configuration | Ansible |
| Kubernetes | k3s (single node, embedded etcd) |
| GitOps | Flux v2 |
| Ingress / TLS | Traefik (k3s built-in) + cert-manager + Let's Encrypt |
| Secrets | SOPS + age |
| Database | CloudNativePG (PostgreSQL 16) |
| Backups | Restic (PVC data) + k3s etcd snapshots → Hetzner Object Storage |
| Analytics | DuckDB + dbt + Plotly (`analytics/`) |

## Repository layout

```
bootstrap/          Terraform and Ansible for infrastructure provisioning
  terraform-hcloud/ Hetzner Cloud resources
  ansible/          Server hardening and k3s installation
clusters/           Flux entrypoint per environment
  vps-prod/         Production cluster Kustomizations
platform/           Cluster-level infrastructure (namespaces, cert-manager, etc.)
apps/               Application workloads
secrets/            SOPS-encrypted Kubernetes secrets
analytics/          Analytical layer (dbt, DuckDB, dashboard)
docs/               Runbooks and setup guides
```

## Environment setup

Export the age key before running any SOPS or Flux commands:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

## Setup guides

Follow these in order for a fresh deployment:

1. [Terraform — provision infrastructure](docs/setup/01_terraform-setup.md)
2. [Ansible — harden and configure the server](docs/setup/02_ansible-setup.md)
3. [k3s — verify cluster and kubectl access](docs/setup/03_k3s-setup-and-verification.md)
4. [Flux — bootstrap GitOps](docs/setup/04-flux-bootstart.md)
5. [SOPS + ingress — secrets, cert-manager, TLS](docs/setup/05_sops-and-ingress-setup.md)
6. [PostgreSQL — CloudNativePG cluster setup](docs/setup/06_postgresql-setup.md)
7. [Apps — onboarding pattern for new applications](docs/setup/07_app-setup.md)

## Day-to-day operations

### Check cluster and Flux health

```bash
kubectl get nodes
flux check
flux get kustomizations -A
```

### Force reconciliation

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization platform -n flux-system --with-source
flux reconcile kustomization secrets -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source
```

### Edit an encrypted secret

```bash
sops secrets/prod/<name>.sops.yaml
```

### Check application logs

```bash
kubectl logs -n <namespace> deploy/<app> --tail=200
```

### Destroy infrastructure

```bash
terraform -chdir=bootstrap/terraform-hcloud destroy
```

## Runbooks

- [Backup and recovery](docs/drd/backup-and-recovery.md) — etcd restore, Restic PVC restore, recovery drill
- [Object storage key rotation](docs/setup/object-storage-key-rotation.md) — rotating Hetzner S3 credentials across all consumers

## Analytics

See [`analytics/README.md`](analytics/README.md) for the analytical layer: data extraction, dbt models, and the dashboard.
