# Project State

---

## LLM Quick Reference

Use this section as the canonical current state. The phase sections below are the implementation history.

### Current Stack

- Provider: Hetzner Cloud
- Host OS: Debian 12
- Kubernetes: K3s
- GitOps: Flux
- Secrets: SOPS + age
- TLS / certificates: cert-manager
- Ingress: Traefik
- PostgreSQL: CloudNativePG

### Canonical Paths

- Terraform: `bootstrap/terraform`
- Ansible: `bootstrap/ansible`
- Cluster root: `clusters/vps-prod`
- Platform manifests: `platform/`
- App manifests: `apps/`
- Encrypted secrets: `secrets/prod/`
- Status/history document: `docs/project-status.md`

### Current Operational Model

- Infrastructure is provisioned by Terraform
- Host bootstrap and hardening are managed by Ansible
- Cluster resources are reconciled by Flux from Git
- Secrets are committed only in encrypted SOPS form
- Platform resources reconcile before apps
- PostgreSQL is operator-managed via CloudNativePG

### Current PostgreSQL State

- Namespace: `infra-postgres`
- Operator namespace: `cnpg-system`
- Write endpoint: `postgres-rw`
- Read-only endpoint: `postgres-ro`
- Replica/internal endpoint: `postgres-r`
- PostgreSQL version: 16
- Instances: 1
- Storage class: `local-path`
- Storage size: `8Gi`
- Bootstrap database: `n8n`
- Bootstrap user: `n8n`
- Secret name: `postgres-auth`
- Secret type: `kubernetes.io/basic-auth`

### Current Flux / Platform Components

- `cert-manager`
- `cloudnative-pg`
- `postgres`

### Rules That Must Stay True

- Do not commit plaintext secrets
- Do not manage cluster resources manually outside Git unless recovering from failure
- Do not expose PostgreSQL via Ingress
- Use `postgres-rw` for application writes
- Validate PVC binding and storage placement after storage-related changes
- Treat this section as canonical when historical sections differ in wording

---

# Phase 1 — Infrastructure Provisioning (Terraform) — Completed

Terraform manages the base infrastructure on Hetzner Cloud.

## Provisioned resources

- 1 × VPS running Debian 12
- Hetzner Cloud Firewall
- Attached persistent volume
- Public IPv4 connectivity
- SSH access restricted to my IP

## Source of truth

Terraform is the source of truth for infrastructure resources.

### Managed resources

- hcloud_server
- hcloud_volume
- hcloud_firewall
- firewall rules
- server location/type

## Terraform → Ansible bridge

Terraform outputs are used as inputs for Ansible.

### Key outputs

- `server_ipv4`
- `volume_id`
- derived device path:

```

/dev/disk/by-id/scsi-0HC_Volume_<id>

```

---

# Phase 2 — Host Bootstrap & Hardening (Ansible) — Completed

The VPS OS is configured using Ansible after Terraform provisioning.

## Base system

- System packages installed
- Timezone: Europe/Amsterdam
- QEMU guest agent installed
- Base utilities installed (git, curl, vim, etc.)

## Access model

Root is used only for initial bootstrap.

### Permanent access chain

```

SSH → deployer → sudo → root

```

### Admin user

- username: `deployer`
- auth: SSH key
- sudo: passwordless

## SSH configuration

- password authentication disabled
- root login disabled
- public key authentication enforced

## Firewall

- Host firewall: UFW

### Allowed ports

- 22
- 80
- 443

- Hetzner firewall remains the outer perimeter

## Persistent storage

Mounted at:

```

/srv/data

```

### Characteristics

- filesystem: ext4
- device: `/dev/disk/by-id/scsi-0HC_Volume_<id>`
- mount: `/srv/data`

Using `/dev/disk/by-id` ensures stable device naming.

---

## Ansible inventory

```

bootstrap/ansible/inventories/prod/hosts.ini

```

### Steady-state

```ini
[vps]
vps-prod

[vps:vars]
ansible_user=deployer
ansible_port=22
```

### Bootstrap override

```
-u root
```

---

## Generated variables (Terraform → Ansible)

```
bootstrap/ansible/inventories/prod/group_vars/vps/generated.yml
```

Example:

```yaml
ansible_host: <server-ip>
data_device: /dev/disk/by-id/scsi-0HC_Volume_<id>
data_mount_point: /srv/data
```

Rules:

- generated automatically
- ignored by git
- overwritten on every Terraform apply
- never manually edited

---

## Operational workflow

### Normal run

```bash
ansible-playbook -i bootstrap/ansible/inventories/prod/hosts.ini \
  bootstrap/ansible/playbooks/harden.yml
```

### Full rebuild

```bash
terraform apply
render-ansible-vars.sh
ssh-keygen -R <server-ip>
ssh-keyscan -H <server-ip> >> ~/.ssh/known_hosts

ansible-playbook -u root harden.yml
ansible-playbook harden.yml
```

---

## Important implementation notes

### 1. Group vars placement

Must be:

```
group_vars/vps/generated.yml
```

Otherwise ignored.

---

### 2. Stable disk identifiers

Use:

```
/dev/disk/by-id/
```

Do not use `/dev/sdX`.

---

### 3. SSH host key refresh

```bash
ssh-keygen -R <server-ip>
ssh-keyscan -H <server-ip> >> ~/.ssh/known_hosts
```

---

### 4. Passwordless sudo

Required for full Ansible automation.

---

### 5. Responsibility separation

Terraform controls:

- server IP
- volume ID
- device path

Ansible controls:

- filesystem
- mount point
- firewall
- OS configuration

---

# Phase 3 — Kubernetes Bootstrap (K3s) — Completed

K3s is installed via Ansible and the cluster is operational.

---

## State

- K3s installed via dedicated Ansible role
- Single-node cluster running
- Node status: `Ready`
- System pods healthy:
  - coredns
  - traefik
  - local-path-provisioner
  - metrics-server

- Embedded etcd active
- etcd snapshots working
- Secrets encryption enabled
- Local-path storage configured

---

## Cluster architecture

- Distribution: K3s
- Topology: single-node
- Datastore: embedded etcd

**Reason:** improved backup/restore and production alignment

---

## Storage model

Persistent data root:

```
/srv/data
```

K3s local storage:

```
/srv/data/k3s-local-path
```

**Behavior:**

- PVC uses `WaitForFirstConsumer`
- PV created only when Pod mounts it

---

## Security model

- Secrets encryption at rest: enabled
- Encryption config:

  ```
  /var/lib/rancher/k3s/server/cred/encryption-config.json
  ```

### kubeconfig

- source:

  ```
  /etc/rancher/k3s/k3s.yaml
  ```

- copied manually to:

  ```
  ~/.kube/config
  ```

- permissions: `600`

**Not automated** (user-specific credential)

---

## Network exposure

### Public

- 80 (HTTP)
- 443 (HTTPS)

### Restricted

- 22 (SSH)

### Not exposed

- 6443 (Kubernetes API)

---

## Tooling

- Standalone `kubectl` installed via Ansible
- Avoid using `k3s kubectl` wrapper

---

## Validation commands

```bash
sudo systemctl is-active k3s
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
sudo k3s etcd-snapshot save
```

---

## Storage validation

PVC alone is not sufficient.

Requires Pod:

```bash
# create PVC
kubectl apply -f pvc.yaml

# create Pod using PVC
kubectl apply -f pod.yaml

# verify
kubectl get pod,pvc,pv
```

Expected:

- Pod: Running
- PVC: Bound
- PV created
- Data under:

  ```
  /srv/data/k3s-local-path
  ```

---

## Known behaviors / gotchas

- PVC remains `Pending` until consumed
- K3s config must exist before install or requires restart
- `k3s kubectl` may show permission warnings
- `etcd-snapshot` may warn about unrelated config keys
- kubeconfig is cluster-admin credential (handle carefully)

---

## Operational model

### Layered architecture

- Terraform → infrastructure
- Ansible → host + K3s
- Kubernetes → workloads (next phase)

---

## Reproducibility

Full rebuild:

1. Terraform apply
2. Ansible (including K3s role)

Cluster is recreated deterministically.

---

## What is intentionally manual

- kubeconfig placement
- local machine access setup

---

## Definition of Done (Phase 3)

- K3s service active
- Node `Ready`
- System pods healthy
- etcd snapshots working
- Secrets encryption enabled
- Persistent volumes use `/srv/data`
- `kubectl` works without sudo

---

# Phase 4 — GitOps (Flux) — Completed

### Outcome

Flux is the active GitOps controller for the cluster. Git is the source of truth for Kubernetes state, and normal deployment flow is Git commit/push followed by Flux reconciliation.

### Canonical State

- Reconciliation root: `clusters/vps-prod`
- Flux bootstrap path: `clusters/vps-prod`
- Bootstrap-generated manifests:
  - `clusters/vps-prod/flux-system/gotk-components.yaml`
  - `clusters/vps-prod/flux-system/gotk-sync.yaml`
- Authentication: SSH deploy key
- Local private key: `~/.ssh/flux-vps-prod`
- Access level: read-only
- Main controllers:
  - `source-controller`
  - `kustomize-controller`
  - `helm-controller`
  - `notification-controller`
- Top-level Flux Kustomizations:
  - `platform`
  - `apps`

### Canonical Workflow

1. Modify manifests locally
2. Commit and push to Git
3. Flux reconciles from Git

`kubectl` is for inspection, debugging, and break-glass recovery. Manual cluster changes must be reflected back into Git.

### Validation

```bash
flux check
kubectl get pods -n flux-system
```

Expected:

- Flux controllers are running
- `flux check` passes

### Gotchas

- `flux bootstrap` writes to the remote repo; the local repo must be pulled afterward
- Flux reconciliation is interval-based, not instant
- If manifests are wrong, inspect with:

```bash
flux get kustomizations
flux logs
```

### Definition of Done (Phase 4)

- Flux controllers healthy
- Git repository connected through SSH deploy key
- `clusters/vps-prod` active as reconciliation root
- `platform` and `apps` Kustomizations present
- Normal deployments no longer rely on `kubectl apply`

---

# Phase 5 — Secrets Management (SOPS + age) — Completed

### Outcome

Secrets are stored in Git only in encrypted SOPS form and decrypted by Flux inside the cluster.

### Canonical State

- Secret files live under: `secrets/prod/*.sops.yaml`
- Encryption tool: SOPS
- Key type: age
- Local age private key path: `~/.config/sops/age/keys.txt`
- Repo config file: `.sops.yaml`
- Cluster decryption secret: `flux-system/sops-age`
- Encryption scope: `data` and `stringData` fields only

### Canonical Workflow

Edit encrypted files with:

```bash
sops <file>
```

Rules:

- never commit plaintext secrets
- never leave a secret decrypted on disk
- if plaintext is committed, treat it as compromised and rotate it

### Validation

- encrypted files contain `ENC[...]`
- encrypted files contain a `sops:` metadata block
- Flux `secrets` Kustomization reconciles successfully
- decrypted Secret resources appear correctly in-cluster

### Gotchas

- Manual decrypt/edit/re-encrypt flows are error-prone
- Any secret readable directly via `cat` is in an invalid on-disk state
- SOPS MAC mismatches happen if encrypted files are edited outside `sops`
- Secret namespaces must exist before the Flux `secrets` Kustomization applies namespaced secrets
- App secrets and operator-managed database secrets should stay separate even if they carry the same password value

### Definition of Done (Phase 5)

- Encrypted secrets stored in Git
- No plaintext secrets in repository
- Flux decrypts and applies secrets successfully
- age private key backed up outside Git

---

# Phase 6 — Platform Configuration — Completed

### Outcome

Platform services reconcile cleanly under Flux, including correct dependency ordering for CRD-producing controllers and CRD-dependent resources.

### Canonical State

- Platform manifests live under: `platform/`
- Namespaces are managed by Flux
- cert-manager is installed via Flux
- CRD-dependent issuer resources are separated from the cert-manager install path
- App reconciliation depends on platform readiness

### Key Design Rule

Do not place CRD-dependent custom resources in the same initial reconciliation path as the controller that installs their CRDs.

### Implemented Structure

- cert-manager install path remains under `platform/cert-manager`
- issuer resources moved to `platform/cert-manager-issuers`
- dedicated Flux Kustomization: `cert-issuers`
- app dependency chain updated so `apps` depends on:
  - `platform`
  - `cert-issuers`

### Reconciliation Order

1. Install cert-manager and its CRDs
2. Reconcile issuer resources
3. Reconcile apps

### Validation

- `platform` reconciles independently
- `cert-issuers` waits until cert-manager CRDs exist
- `apps` no longer fail due to missing `ClusterIssuer` CRDs

### Gotchas

- If a `ClusterIssuer` is included before cert-manager CRDs exist, Flux dry-run fails with:

```text
no matches for kind "ClusterIssuer" in version "cert-manager.io/v1"
```

### Definition of Done (Phase 6)

- Platform namespaces reconciled by Flux
- cert-manager installed by Flux
- issuer resources reconciled only after CRDs exist
- dependency ordering prevents CRD timing failures

---

# Phase 7 — HTTPS Validation / Test Workload — Completed

### Outcome

Ingress and TLS were validated end-to-end using a minimal `whoami` workload before deploying real applications.

### Canonical State

- Test workload path: `apps/whoami`
- Namespace: `apps-test`
- Host: `whoami.titas.dev`
- Ingress controller: Traefik
- Certificate issuer: `letsencrypt-production`
- Supporting Flux Kustomizations healthy:
  - `platform`
  - `cert-issuers`
  - `apps`

### Validation

```bash
curl -vk https://whoami.titas.dev
flux get kustomizations -A
kubectl get clusterissuer
kubectl get certificate -n apps-test
kubectl get pods -n cert-manager
```

Expected:

- Traffic reaches Traefik
- `whoami` responds successfully
- cert-manager issues a valid production certificate
- certificate reports `Ready=True`

### Incident / Fix

- Problem: wildcard DNS routed traffic through an external proxy instead of the cluster
- Symptom: wrong certificate, redirects, requests not reaching Traefik
- Root cause: `*.titas.dev` pointed at an external host
- Fix: remove wildcard record and create explicit record:

```text
whoami.titas.dev → VPS IP
```

### Operational Rule

Validate ingress and TLS with a minimal workload before introducing application complexity.

### Definition of Done (Phase 7)

- HTTPS endpoint reachable at `whoami.titas.dev`
- Traffic routed through Traefik
- Let's Encrypt production certificate issued successfully
- Flux reconciliation healthy across platform and apps

### Next Step

Proceed to shared infrastructure: PostgreSQL.

---

## Phase 8 — PostgreSQL (CloudNativePG Migration)

### Outcome

PostgreSQL now runs on **CloudNativePG (CNPG)** instead of the Bitnami PostgreSQL Helm chart.

This changed the deployment model from a single Helm-managed database release to an operator-managed PostgreSQL cluster.

### Why This Changed

- The Bitnami chart tried to pull `docker.io/bitnami/postgresql:16.4.0-debian-12-r14`
- That image tag was no longer available after Bitnami changed image distribution on August 28, 2025
- `bitnamilegacy/postgresql` was considered only as a short-term workaround and rejected for production use
- CloudNativePG was selected because it is actively maintained and fits the GitOps/operator model better

### Canonical Architecture

```text
HelmRelease (cloudnative-pg operator)   [platform layer]
↓
HelmRelease (postgres / CNPG cluster)   [apps layer]
↓
Managed PostgreSQL cluster in infra-postgres
```

### Canonical Current State

- Operator namespace: `cnpg-system`
- Database namespace: `infra-postgres`
- Helm releases:
  - `cert-manager`
  - `cloudnative-pg`
  - `postgres`
- Cluster name: `postgres-cluster`
- Write service: `postgres-cluster-rw`
- Read-only service: `postgres-cluster-ro`
- Replica/internal service: `postgres-cluster-r`
- PostgreSQL version: 16
- Instances: 1
- Storage class: `local-path`
- Storage size: `8Gi`
- Bootstrap database: `n8n`
- Bootstrap owner: `app_platform`
- Bootstrap secret: `postgres-auth`
- Bootstrap secret type: `kubernetes.io/basic-auth`
- Application database: `n8n`
- Application role: `n8n`
- Application role password secret: `postgres-n8n-auth`

### Canonical Secret Shape

CloudNativePG does not use the old Bitnami `auth.*` values model. The bootstrap secret and the managed role secret are separate resources.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-auth
  namespace: infra-postgres
type: kubernetes.io/basic-auth
stringData:
  username: app_platform
  password: <secure-password>
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-n8n-auth
  namespace: infra-postgres
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: n8n
  password: <secure-password>
```

### Canonical Connectivity

- In-cluster write endpoint: `postgres-cluster-rw.infra-postgres.svc.cluster.local:5432`
- n8n should use:

```text
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres-cluster-rw.infra-postgres.svc.cluster.local
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=<from secret>
```

### Required Validation

Storage path must resolve under:

```text
/srv/data/k3s-local-path
```

Validation commands:

```bash
kubectl get pvc -n infra-postgres
kubectl get pv

ssh deployer@<server-ip>
sudo find /srv/data/k3s-local-path -maxdepth 3 -type d | sort
```

Expected:

- PVC is `Bound`
- Data directory exists under `/srv/data/k3s-local-path`

### Operational Rules

- Do not expose PostgreSQL via Ingress
- Use `postgres-cluster-rw` for writes
- Keep credentials only in SOPS-encrypted secrets
- Do not manually edit the running cluster unless recovering from failure
- Manage changes through Git and Flux reconciliation
- Keep CNPG-owned secrets in `infra-postgres` and app-owned secrets in app namespaces
- Manage `apps-n8n` in the platform namespace layer so secrets can reconcile before apps

### Common Failure Modes

- Secret missing before reconcile → bootstrap fails
- Secret type or shape wrong → authentication/bootstrap issues
- Manual edits to encrypted files → SOPS MAC mismatch
- Wrong namespace ownership/order → `Secret/apps-n8n/n8n-secret not found: namespaces "apps-n8n" not found`
- PVC not bound → pod remains Pending
- Wrong service name (`postgres-rw` vs `postgres-cluster-rw`) → DNS resolution failures
- Kubernetes service links enabled → `N8N_PORT` injected as `tcp://...` and n8n fails to start
- Matching Kubernetes secrets but stale PostgreSQL role password → `password authentication failed for user "n8n"`
- Storage path not validated → risk of data landing on the wrong disk

### Status

- PostgreSQL deployment: **Completed**
- CNPG operator installed and healthy
- Cluster running
- Dedicated `n8n` database created
- Dedicated `n8n` role created
- Ready for application onboarding

### Reconcile And Verify

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization platform -n flux-system --with-source
flux reconcile kustomization secrets -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source
```

```bash
kubectl get svc -n infra-postgres
kubectl get pods -n infra-postgres
kubectl get database -n infra-postgres
kubectl get secret -n infra-postgres postgres-auth postgres-n8n-auth
kubectl get secret -n apps-n8n n8n-secret
```

### Password Reconciliation Notes

- `postgres-n8n-auth` is the CNPG-owned desired password for the `n8n` database role
- `n8n-secret` is the n8n application secret and includes `DB_POSTGRESDB_PASSWORD`
- These two password values must match
- Updating Kubernetes secrets does not guarantee the PostgreSQL role password has already changed
- Verify the live database password with a direct login test before assuming rotation succeeded

Verification:

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- \
  env PGPASSWORD='<password>' \
  psql -h 127.0.0.1 -U n8n -d n8n -c 'select current_user, current_database();'
```

If the direct login test fails even though the in-cluster secrets match, manually reconcile the role password:

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- \
  psql -U postgres -d postgres -c "ALTER ROLE n8n WITH PASSWORD '<password>';"
```

After password updates:

```bash
kubectl rollout restart deployment/n8n -n apps-n8n
kubectl rollout status deployment/n8n -n apps-n8n
kubectl logs -n apps-n8n deploy/n8n --tail=200
```

---

# Phase 9 — n8n Deployment (PostgreSQL-backed) — Completed

### Outcome

n8n is deployed in `apps-n8n`, exposed through Traefik with TLS, and configured to use the shared PostgreSQL cluster through a dedicated `n8n` role and database.

### Canonical State

- Namespace: `apps-n8n`
- Deployment: `n8n`
- Service: `n8n`
- Ingress host: `beta-n8n.titas.dev`
- PVC: `n8n-data`
- Application secret: `n8n-secret`
- Database host: `postgres-cluster-rw.infra-postgres.svc.cluster.local`
- Database: `n8n`
- Database user: `n8n`
- `enableServiceLinks: false` is required in the pod spec

### Canonical Secrets

- `secrets/prod/n8n.sops.yaml`
  - `DB_POSTGRESDB_PASSWORD`
  - `N8N_ENCRYPTION_KEY`
  - `N8N_BASIC_AUTH_USER`
  - `N8N_BASIC_AUTH_PASSWORD`
- `secrets/prod/postgres-n8n-auth.sops.yaml`
  - `username: n8n`
  - `password: <same value as DB_POSTGRESDB_PASSWORD>`
  - `metadata.labels.cnpg.io/reload: "true"`

### Validation

```bash
kubectl get pods -n apps-n8n
kubectl get ingress -n apps-n8n
kubectl logs -n apps-n8n deploy/n8n --tail=200
kubectl logs -n apps-n8n deploy/n8n --previous --tail=200
kubectl describe pod -n apps-n8n
```

Expected:

- Deployment becomes `Ready`
- Ingress host is `beta-n8n.titas.dev`
- n8n starts without `N8N_PORT` parsing errors
- n8n connects successfully to PostgreSQL as user `n8n`

### Status

- n8n deployment: **Completed**
- Dedicated application database and role configured
- Flux ordering adjusted so namespaces exist before secrets reconcile
- Password rotation requires verification against the live PostgreSQL role state
