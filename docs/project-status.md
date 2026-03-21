# Project State

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

Flux is installed and configured to manage cluster state from Git.

---

## Objective

Establish Git as the single source of truth for all Kubernetes resources and eliminate manual `kubectl apply` workflows.

---

## Implementation

### Bootstrap method

Flux was bootstrapped using:

```bash
flux bootstrap git \
  --url=ssh://git@github.com/SyroQT/home-platform.git \
  --branch=main \
  --private-key-file="$HOME/.ssh/flux-vps-prod" \
  --path=clusters/vps-prod
```

### Authentication model

- Git access via **SSH deploy key**
- Key stored locally at:

```
~/.ssh/flux-vps-prod
```

- Public key added to GitHub repository deploy keys
- Access level: **read-only**

**Reason:**

- avoids long-lived personal access tokens
- aligns with pull-based GitOps model
- safer default until image automation is introduced

---

## Repository integration

Flux manages the cluster from:

```
clusters/vps-prod
```

Bootstrap created:

```
clusters/vps-prod/flux-system/
  gotk-components.yaml
  gotk-sync.yaml
```

**Important behavior:**

- bootstrap pushes directly to remote
- local repo must be manually pulled after bootstrap

---

## Reconciliation model

Flux continuously reconciles cluster state from Git.

### Controllers installed

- source-controller
- kustomize-controller
- helm-controller
- notification-controller

### Validation

```bash
flux check
kubectl get pods -n flux-system
```

Expected:

- all controllers running
- `flux check` passes

---

## Kustomization structure

Two top-level Flux Kustomizations define separation of concerns:

### Platform layer

```
clusters/vps-prod/kustomizations/platform.yaml
→ ./platform
```

### Applications layer

```
clusters/vps-prod/kustomizations/apps.yaml
→ ./apps
```

Apps depend on platform:

```yaml
dependsOn:
  - name: platform
```

**Reason:**

- ensures infrastructure (ingress, cert-manager, etc.) is ready before apps
- enforces clean layering

---

## Architecture alignment

This completes the intended layered model:

```
Terraform → infrastructure
Ansible   → host + K3s
Flux      → cluster state
```

**Result:**

- full separation of concerns
- reproducible cluster state
- clear ownership boundaries per layer

---

## Operational model

### Normal workflow

1. Modify manifests locally
2. Commit and push to Git
3. Flux reconciles automatically

### Cluster interaction

`kubectl` is used for:

- inspection
- debugging
- emergency fixes only

Manual changes must be reflected back into Git.

---

## Key decisions

### 1. Pull-based GitOps (Flux)

**Decision:**
Use Flux (pull model) instead of push-based CD.

**Why:**

- cluster pulls desired state
- no external deploy pipeline required
- simpler security model

---

### 2. SSH deploy key (not PAT)

**Decision:**
Use SSH deploy key for Git authentication.

**Why:**

- avoids storing personal credentials
- scoped to single repository
- easily revocable

---

### 3. Read-only Git access

**Decision:**
Deploy key is read-only.

**Why:**

- prevents automated writes to repo
- reduces blast radius
- aligns with PR-based workflow

**Future option:**

- enable write access if Flux image automation is introduced

---

### 4. Layered Kustomizations

**Decision:**
Separate `platform` and `apps`.

**Why:**

- enforces dependency ordering
- isolates failures
- improves maintainability

---

### 5. Git as single source of truth

**Decision:**
No direct `kubectl apply` for normal operations.

**Why:**

- prevents configuration drift
- ensures reproducibility
- aligns with GitOps principles

---

## Known behaviors / gotchas

- `flux bootstrap` does not update local repo -> must `git pull`
- Flux reconciliation is interval-based (not instant)
- misconfigured manifests fail silently unless checked via:

```bash
flux get kustomizations
flux logs
```

---

## Definition of Done (Phase 4)

- Flux controllers installed and healthy
- Git repository connected via SSH deploy key
- `clusters/vps-prod` is active reconciliation root
- `platform` and `apps` Kustomizations exist
- Flux successfully reconciles changes from Git
- No manual `kubectl apply` required for deployments

---

## Next Phase

Phase 5 — Secrets Management (SOPS + age)

Goals:

- store encrypted secrets in Git
- enable Flux decryption at runtime
- eliminate plaintext secrets from repository

---

## Phase 5 Status

### Phase 5 — Secrets Management (SOPS + age)

**Status:** Completed

### Objective

Introduce secure, GitOps-compatible secret management using SOPS with age encryption, enabling encrypted secrets to be stored in Git and decrypted at runtime by Flux.

### Current Progress

- SOPS and age installed and verified locally
- age keypair generated and stored at `~/.config/sops/age/keys.txt`
- public key extracted and configured in `.sops.yaml`
- `.sops.yaml` created at repository root with rules that:
  - target `secrets/*.sops.yaml`
  - encrypt only `data` and `stringData` fields
- initial secret (`demo-secret`) created and successfully:
  - encrypted with SOPS
  - decrypted locally for verification
- workflow issue identified and corrected:
  - file was left in plaintext after decryption testing
  - file was re-encrypted and verified to be back in proper encrypted state (`ENC[...]`)

### Key Decisions

#### 1. Encryption Standard: SOPS + age

- age selected over PGP for simplicity and modern defaults
- aligns with Flux native SOPS integration
- avoids external key servers and complex key management

#### 2. Git as Source of Truth (Encrypted Only)

- all secrets must be stored encrypted in Git
- plaintext secrets are never committed
- Flux performs decryption inside the cluster at reconcile time

#### 3. Repository Structure

Secrets are stored under:

```text
secrets/prod/*.sops.yaml
```

This keeps them clearly separated from:

- platform
- apps
- infrastructure

#### 4. File Naming Convention

- `.sops.yaml` suffix enforced
- ensures `.sops.yaml` rules apply consistently
- reduces risk of accidental plaintext commits

#### 5. Editing Workflow (Critical)

Standard workflow:

```bash
sops <file>
```

- manual decrypt/edit/re-encrypt flows are avoided
- this prevents accidental plaintext persistence

#### 6. Cluster Decryption Model

- Flux will use Kubernetes Secret `flux-system/sops-age`
- this Secret will contain the age private key
- Flux will use it to decrypt manifests during reconciliation

#### 7. Safety Principle

If a secret is ever committed in plaintext:

- it is considered compromised
- it must be rotated immediately

### Deviations / Lessons Learned

#### Issue: Plaintext file left after decryption

- root cause:
  - manual decrypt/test flow without guaranteed re-encryption
- impact:
  - risk of committing plaintext secret
- resolution:
  - re-encrypted file with `sops --encrypt --in-place`
  - standardized on `sops <file>` for editing

#### Improvement Over Guide

The guide did not explicitly enforce that the final on-disk state must be encrypted.

Added project rule:

> Any file readable via `cat` is invalid.

### Validation Status

- local encryption and decryption working correctly
- `.sops.yaml` rules applied as expected
- encrypted file verified to contain:
  - `ENC[...]` values
  - `sops:` metadata block
- end-to-end verification completed:
  - `sops-age` Secret created in `flux-system`
  - Flux `secrets` Kustomization decrypts SOPS manifests during reconciliation
  - encrypted secrets stored in Git are applied successfully in decrypted form in-cluster
  - `flux get kustomizations` reports healthy reconciliation for secrets

### Definition of Done (Phase 5)

- encrypted secrets stored in Git
- no plaintext secrets in repository
- Flux successfully decrypts and applies secrets
- age private key securely backed up outside Git
- secrets fully managed via GitOps workflow

---

# Phase 6 — Platform Configuration — Completed

Platform-level cluster services are now structured to reconcile cleanly under Flux, including correct ordering for CRD-producing controllers and CRD-dependent custom resources.

## Current State

- initial platform structure created under `platform/`
- namespaces are managed through Flux
- cert-manager installation is managed through Flux
- CRD-dependent issuer resources are separated from the initial cert-manager installation path
- app reconciliation is gated on both platform readiness and issuer readiness

## Issue Encountered

Flux failed to reconcile the `platform` Kustomization during dry-run validation because a `ClusterIssuer` was included in the same apply path as the cert-manager install before the cert-manager CRDs existed.

Failure observed:

- `platform` marked not ready
- error:

```text
no matches for kind "ClusterIssuer" in version "cert-manager.io/v1"
```

- `apps` reconciliation blocked because it depended on `platform`

## Key Architectural Decision

Do not place CRD-dependent custom resources in the same initial reconciliation path as the controller that installs their CRDs.

### Reason

- avoids Flux dry-run and validation failures during bootstrap
- prevents CRD race conditions
- creates a clearer dependency graph
- makes reconciliation failures easier to debug
- better matches production GitOps behavior

## Implemented Fix

### 1. Split issuer resources from cert-manager install

- removed `clusterissuer-staging.yaml` from `platform/cert-manager`
- created:

```text
platform/cert-manager-issuers/
```

- moved `ClusterIssuer` resources into that directory

### 2. Added dedicated Flux Kustomization for issuers

Created a separate Flux Kustomization:

- `cert-issuers`

Configured it to depend on:

- `platform`

### 3. Updated app dependency chain

Updated the `apps` Kustomization to depend on:

- `platform`
- `cert-issuers`

## Final Reconciliation Order

1. Install cert-manager and its CRDs
2. Apply `ClusterIssuer` resources
3. Deploy apps

## Validation Outcome

- `platform` can reconcile independently
- `cert-issuers` applies only after cert-manager is available
- `apps` are no longer blocked by missing cert-manager CRDs

## Definition of Done (Phase 6)

- platform namespaces are reconciled through Flux
- cert-manager is installed through Flux
- issuer resources are reconciled only after cert-manager CRDs exist
- Flux dependency ordering prevents CRD validation failures during bootstrap
- app reconciliation is no longer blocked by cert-manager CRD timing

## Phase 7 — HTTPS Validation / Test Workload — Completed

### Objective

Validate end-to-end ingress and TLS setup using a minimal test application before deploying real workloads.

---

### Current Progress

- `platform` Kustomization reconciled successfully
- `cert-issuers` Kustomization reconciled successfully
- `ClusterIssuer` resources available in cluster:
  - `letsencrypt-staging`
  - `letsencrypt-production`

- DNS configured for test domain:
  - `whoami.titas.dev → VPS public IP`

- Removed conflicting wildcard DNS records that were routing traffic externally

---

### Test Workload Deployment

Deployed a minimal `whoami` application under:

```
apps/whoami
```

Resources included:

- Namespace: `apps-test`
- Deployment (1 replica)
- Service (ClusterIP)
- Ingress (Traefik)

Ingress configuration:

- Host: `whoami.titas.dev`
- TLS enabled
- Production issuer validated end-to-end
- Annotation:

  ```
  cert-manager.io/cluster-issuer: letsencrypt-production
  ```

---

### Key Issue Encountered

#### DNS / External Proxy Interference

- Traffic was initially routed through an external proxy (Sucuri)
- Symptoms:
  - Incorrect certificate (DigiCert)
  - Unexpected redirects
  - Requests not reaching cluster

#### Root Cause

- Wildcard DNS record:

  ```
  *.titas.dev → external host (31.x IP)
  ```

- This overrode or intercepted subdomain routing

#### Resolution

- Removed wildcard DNS record
- Ensured explicit A record:

  ```
  whoami.titas.dev → VPS IP
  ```

- Verified direct routing to cluster

---

### Validation Results

#### Ingress Routing

```bash
curl -vk https://whoami.titas.dev
```

- Request reaches Traefik
- Response returned from whoami pod
- Correct headers (`X-Forwarded-*`) present

#### TLS Issuance (Production)

- Certificate successfully issued by cert-manager
- Issuer:

  ```
  Let's Encrypt
  ```

- Production certificate validated successfully for `whoami.titas.dev`

- Certificate status:

  ```
  Ready=True
  ```

#### Cluster Checks

```bash
flux get kustomizations -A
kubectl get clusterissuer
kubectl get certificate -n apps-test
kubectl get pods -n cert-manager
```

All components healthy and reconciled.

---

### Key Decisions

#### 1. Use Staging First, Then Confirm Production

- staging used for initial ACME validation
- production issuance then confirmed successfully on the test workload

#### 2. Introduce Dedicated Test Workload

- `whoami` app used to isolate ingress/TLS from application complexity
- Provides reproducible validation target

#### 3. Separate CRD-Dependent Resources

- `ClusterIssuer` managed in `cert-issuers` Kustomization
- Prevents Flux dry-run failures due to missing CRDs

#### 4. Explicit DNS over Wildcard

- Avoid wildcard DNS in mixed hosting environments
- Prevent unintended traffic interception

---

### Definition of Done

- HTTPS endpoint reachable at `whoami.titas.dev`
- Traffic routed through Traefik
- cert-manager successfully issues a Let's Encrypt production certificate
- ClusterIssuer functional
- Flux reconciliation healthy across:
  - `platform`
  - `cert-issuers`
  - `apps`

---

### Next Steps

1. Use the verified ingress + TLS pattern for real applications
2. Proceed to shared infrastructure (PostgreSQL) before deploying apps
