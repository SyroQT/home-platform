# PostgreSQL Setup With CloudNativePG

This guide documents the PostgreSQL setup used in this repository and the steps required to reproduce it.

It covers:

- why CloudNativePG was chosen
- how the repo is structured
- which secrets exist and why
- how the shared cluster and the `n8n` database are configured
- how to reconcile and verify the setup
- what to do when password reconciliation drifts

## 1. Scope

This repo currently uses:

- CloudNativePG as the PostgreSQL operator
- a shared PostgreSQL cluster in `infra-postgres`
- Flux for reconciliation
- SOPS + age for encrypted secrets
- a dedicated `n8n` database and `n8n` role inside the shared cluster

Relevant repo paths:

- `platform/cloudnative-pg/`
- `apps/postgres/base/`
- `apps/postgres/prod/`
- `secrets/prod/postgres.sops.yaml`
- `secrets/prod/postgres-n8n-auth.sops.yaml`
- `clusters/vps-prod/kustomizations/apps.yaml`
- `clusters/vps-prod/kustomizations/secrets.yaml`

## 2. Key Decisions

### Why CloudNativePG

CloudNativePG was chosen over the earlier Bitnami-based approach because:

- it fits the GitOps/operator model better
- it manages PostgreSQL as a native Kubernetes workload
- it provides first-class role and database management
- it avoids depending on image conventions that changed under the Bitnami chart path

### Why a Shared Cluster

The repository is structured around one shared PostgreSQL cluster rather than one cluster per app.

That means:

- infrastructure concerns stay in `infra-postgres`
- apps get their own database and role
- app credentials are separated from cluster bootstrap credentials

### Why Bootstrap Owner And App User Are Different

The cluster bootstraps with:

- bootstrap owner: `app_platform`
- bootstrap database: `n8n`

Then the app layer creates:

- database: `n8n`
- role: `n8n`

This keeps the initial cluster bootstrap identity separate from the application identity.

## 3. Repo Structure

The app manifests follow the same `base` / `prod` overlay pattern used elsewhere in the repo.

### PostgreSQL manifests

- `apps/postgres/base/helmrelease.yaml`
  - defines the CloudNativePG cluster HelmRelease
- `apps/postgres/base/database-n8n.yaml`
  - creates the dedicated `n8n` database
- `apps/postgres/base/kustomization.yaml`
  - composes the PostgreSQL base resources
- `apps/postgres/prod/kustomization.yaml`
  - references `../base`

### Namespace ownership

Namespaces are owned by the platform layer, not by the app overlays.

- `platform/namespaces/infra-postgres.yaml`
- `platform/namespaces/apps-n8n.yaml`

This is important because Flux applies `secrets` separately from `apps`, and namespaced secrets fail if the namespace does not already exist.

## 4. PostgreSQL Secrets Model

This setup uses two different PostgreSQL-related secrets.

### Bootstrap secret

File:

- `secrets/prod/postgres.sops.yaml`

Purpose:

- bootstraps the shared cluster owner account

Shape:

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

### n8n database role secret

File:

- `secrets/prod/postgres-n8n-auth.sops.yaml`

Purpose:

- desired password for the `n8n` PostgreSQL role managed by CloudNativePG

Shape:

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

Important:

- the `cnpg.io/reload: "true"` label is used so CNPG can react to secret changes
- this secret is separate from the n8n application secret

## 5. n8n Application Secret Relationship

The n8n app also has its own secret:

- `secrets/prod/n8n.sops.yaml`

This secret contains app-specific values such as:

- `DB_POSTGRESDB_PASSWORD`
- `N8N_ENCRYPTION_KEY`
- `N8N_BASIC_AUTH_USER`
- `N8N_BASIC_AUTH_PASSWORD`

Important rule:

- `secrets/prod/n8n.sops.yaml` -> `DB_POSTGRESDB_PASSWORD`
- `secrets/prod/postgres-n8n-auth.sops.yaml` -> `password`

These two values must match.

The secrets stay separate because:

- they belong to different namespaces
- they are owned by different systems
- one is an app secret and one is an operator-managed DB role secret

## 6. Cluster Configuration

The PostgreSQL cluster is defined in:

- `apps/postgres/base/helmrelease.yaml`

Canonical settings:

- namespace: `infra-postgres`
- chart: `cluster`
- PostgreSQL version: `16`
- instances: `1`
- storage class: `local-path`
- storage size: `8Gi`
- bootstrap owner: `app_platform`
- bootstrap database: `n8n`
- managed role: `n8n`
- managed role password secret: `postgres-n8n-auth`

The dedicated database is defined in:

- `apps/postgres/base/database-n8n.yaml`

Canonical database settings:

- database name: `n8n`
- owner: `n8n`
- cluster reference: `postgres`

## 7. Expected Service Names

CloudNativePG creates these services for this cluster:

- `postgres-cluster-rw`
- `postgres-cluster-ro`
- `postgres-cluster-r`

Use the write service for applications:

```text
postgres-cluster-rw.infra-postgres.svc.cluster.local:5432
```

Do not use `postgres-rw`. That name is not what this cluster currently exposes.

## 8. Create Or Update The Encrypted Secrets

Edit secrets safely with `sops`:

```bash
sops secrets/prod/postgres.sops.yaml
sops secrets/prod/postgres-n8n-auth.sops.yaml
```

If creating the files from scratch, create plaintext manifests first and then encrypt them:

```bash
kubectl create secret generic postgres-auth \
  --namespace infra-postgres \
  --type kubernetes.io/basic-auth \
  --from-literal=username=app_platform \
  --from-literal=password=change-me \
  --dry-run=client -o yaml > secrets/prod/postgres.sops.yaml

kubectl create secret generic postgres-n8n-auth \
  --namespace infra-postgres \
  --type kubernetes.io/basic-auth \
  --from-literal=username=n8n \
  --from-literal=password=change-me \
  --dry-run=client -o yaml > secrets/prod/postgres-n8n-auth.sops.yaml
```

Add the CNPG reload label to `postgres-n8n-auth` before encryption if creating manually:

```yaml
metadata:
  labels:
    cnpg.io/reload: "true"
```

Encrypt:

```bash
sops --encrypt --in-place secrets/prod/postgres.sops.yaml
sops --encrypt --in-place secrets/prod/postgres-n8n-auth.sops.yaml
```

## 9. Reconcile Order

The correct reconcile order matters.

Namespaces must exist before namespaced secrets reconcile, and secrets should reconcile before app deployments depend on them.

Recommended sequence:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization platform -n flux-system --with-source
flux reconcile kustomization secrets -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source
```

Why:

- `platform` creates namespaces such as `infra-postgres` and `apps-n8n`
- `secrets` decrypts and applies namespaced secrets under `secrets/prod`
- `apps` applies app workloads and PostgreSQL resources

The repo already encodes part of this dependency:

- `clusters/vps-prod/kustomizations/secrets.yaml` depends on `platform`

## 10. Verification

### Verify the cluster resources

```bash
kubectl get helmrelease -n infra-postgres postgres
kubectl get pods -n infra-postgres
kubectl get svc -n infra-postgres
kubectl get database -n infra-postgres
```

Expected:

- HelmRelease is `Ready`
- PostgreSQL pod is `Running`
- services include `postgres-cluster-rw`, `postgres-cluster-ro`, `postgres-cluster-r`
- database resource `postgres-n8n` exists

### Verify the secrets

```bash
kubectl get secret -n infra-postgres postgres-auth postgres-n8n-auth
kubectl get secret -n apps-n8n n8n-secret
```

### Verify storage

```bash
kubectl get pvc -n infra-postgres
kubectl get pv
```

Expected:

- PVC is `Bound`

## 11. Verify Database Connectivity

Check that the role exists:

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- psql -U postgres -d postgres -c "\du"
```

Check that the database exists:

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- psql -U postgres -d postgres -c "\l"
```

Check that the `n8n` login actually works:

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- \
  env PGPASSWORD='<password>' \
  psql -h 127.0.0.1 -U n8n -d n8n -c 'select current_user, current_database();'
```

This is the most important password verification step.

## 12. Password Reconciliation Caveat

This setup exposed an important operational detail:

- updating the Kubernetes secret does not by itself prove that the PostgreSQL role password has already changed in the database

During setup, these states diverged:

- the secrets in Kubernetes matched
- the PostgreSQL role `n8n` still had a stale password
- application login failed until the DB role password was manually corrected

That means password rotation must always be verified with a real DB login test.

## 13. Manual Recovery If Passwords Drift

If the in-cluster secrets match but the direct `psql` login test fails, manually update the PostgreSQL role password:

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- \
  psql -U postgres -d postgres -c "ALTER ROLE n8n WITH PASSWORD '<password>';"
```

Verify again:

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- \
  env PGPASSWORD='<password>' \
  psql -h 127.0.0.1 -U n8n -d n8n -c 'select current_user, current_database();'
```

If this succeeds, restart the application that consumes the secret:

```bash
kubectl rollout restart deployment/n8n -n apps-n8n
kubectl rollout status deployment/n8n -n apps-n8n
```

## 14. Password Rotation Procedure

Do not delete the secrets first. Rotate them in place through Git and Flux.

### Step 1. Update both encrypted files

Update:

- `secrets/prod/postgres-n8n-auth.sops.yaml` -> `stringData.password`
- `secrets/prod/n8n.sops.yaml` -> `stringData.DB_POSTGRESDB_PASSWORD`

These values must stay identical.

### Step 2. Commit and push

```bash
git add secrets/prod/postgres-n8n-auth.sops.yaml secrets/prod/n8n.sops.yaml
git commit -m "Rotate n8n database password"
git push
```

### Step 3. Reconcile

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization secrets -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source
```

### Step 4. Verify secret values

```bash
kubectl get secret -n infra-postgres postgres-n8n-auth -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret -n apps-n8n n8n-secret -o jsonpath='{.data.DB_POSTGRESDB_PASSWORD}' | base64 -d; echo
```

### Step 5. Verify DB login

```bash
kubectl exec -n infra-postgres -it postgres-cluster-1 -- \
  env PGPASSWORD='<password>' \
  psql -h 127.0.0.1 -U n8n -d n8n -c 'select current_user, current_database();'
```

If that still fails, use the manual recovery step above.

## 15. Common Failure Modes

- wrong secret type for CNPG bootstrap or managed role secret
- editing encrypted SOPS files outside `sops`, causing MAC mismatches
- secrets reconciling before namespaces exist
- using the wrong service host name
- matching Kubernetes secrets but stale PostgreSQL role password
- assuming secret rotation alone guarantees DB-side password rotation

## 16. Definition Of Done

The PostgreSQL setup is considered complete when:

- CNPG operator is healthy
- the PostgreSQL cluster is `Ready`
- `postgres-cluster-rw` exists
- the `n8n` role exists
- the `n8n` database exists
- the `postgres-auth` and `postgres-n8n-auth` secrets exist
- the `n8n` role can log in successfully with the expected password
- dependent applications can connect through `postgres-cluster-rw.infra-postgres.svc.cluster.local`
