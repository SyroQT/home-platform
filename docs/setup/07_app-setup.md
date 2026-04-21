# Application Setup Pattern

This guide documents how to add a new application to this repository.

It uses the n8n deployment as the primary example, but the process is intentionally generic so it can be repeated for other apps.

It covers:

- how app manifests are structured
- how namespaces, secrets, storage, services, and ingress should be handled
- how to wire an app into Flux
- how to connect an app to PostgreSQL when needed
- how to reconcile and verify the rollout

## 1. Scope

This repo currently follows these conventions for applications:

- reusable manifests live under `apps/<app>/base/`
- environment composition lives under `apps/<app>/prod/`
- secrets live under `secrets/prod/`
- shared namespaces live under `platform/namespaces/`
- Flux reconciles apps from `apps/`
- Flux reconciles secrets from `secrets/prod/`

Relevant repo paths:

- `apps/`
- `platform/namespaces/`
- `secrets/prod/`
- `clusters/vps-prod/kustomizations/apps.yaml`
- `clusters/vps-prod/kustomizations/secrets.yaml`

Examples in this repo:

- `apps/n8n/`
- `apps/actual/`
- `apps/whoami/`

## 2. Core Design Rules

### Rule 1. Keep namespace ownership out of app overlays

Namespaces should be created in the platform layer:

- `platform/namespaces/<namespace>.yaml`

Do not rely on the app overlay to create the namespace if secrets will be applied separately by Flux.

Why:

- Flux applies `secrets` and `apps` as separate Kustomizations
- namespaced secrets fail if the namespace does not already exist

### Rule 2. Use `base` and `prod`

Each app should follow this pattern:

```text
apps/<app>/
  base/
    deployment.yaml
    service.yaml
    pvc.yaml           # if needed
    ingress.yaml       # if needed
    kustomization.yaml
  prod/
    kustomization.yaml
```

Why:

- `base` holds reusable manifests
- `prod` composes the deployable environment entrypoint
- the repo stays consistent across applications

### Rule 3. Keep app secrets separate from infrastructure secrets

App secrets should live in:

- `secrets/prod/<app>.sops.yaml`

Database or operator-owned secrets should remain separate if they belong to a different namespace or controller.

This is important even if the same password value appears in more than one secret.

### Rule 4. Prefer explicit configuration over cluster defaults

Use explicit values where cluster defaults can cause hidden breakage.

Example from n8n:

- `enableServiceLinks: false`

Without it, Kubernetes injected `N8N_PORT=tcp://...` and broke startup.

## 3. Step-By-Step App Onboarding

## Step 1. Create the namespace in the platform layer

Create:

- `platform/namespaces/<namespace>.yaml`

Example:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: apps-n8n
```

Add it to:

- `platform/namespaces/kustomization.yaml`

Why:

- secrets must be able to reconcile before the app starts

## Step 2. Create the app directory layout

Create:

```text
apps/<app>/base/
apps/<app>/prod/
```

Add:

- `apps/<app>/base/kustomization.yaml`
- `apps/<app>/prod/kustomization.yaml`

Generic `prod` example:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
```

## Step 3. Add the deployment

Create:

- `apps/<app>/base/deployment.yaml`

Minimum checklist:

- correct namespace
- stable labels and selector
- pinned image tag
- resource requests and limits
- port definition if exposed
- volume mounts if persistent storage is needed
- env vars from secret references where appropriate

Generic example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: apps-my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: example/app:1.2.3
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 768Mi
```

### n8n-specific example

The current n8n deployment adds:

- `enableServiceLinks: false`
- an immutable custom image tag such as `ghcr.io/syroqt/home-platform/n8n:sha-ff70fd8`
- `imagePullPolicy: IfNotPresent`
- PostgreSQL env vars
- app secret references
- mounted PVC at `/home/node/.n8n`
- `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true`

For custom app images such as n8n, use manual promotion in Git:

1. update the image source, for example via Renovate in the Dockerfile
2. build and push a new immutable image tag such as `sha-ff70fd8`
3. update the deployment manifest to that exact tag

Do not deploy `:latest` for long-lived workloads reconciled by Flux.

## Step 4. Add the service

Create:

- `apps/<app>/base/service.yaml`

Expose the container port through a stable ClusterIP service.

Generic example:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: apps-my-app
spec:
  selector:
    app: my-app
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

## Step 5. Add persistent storage if needed

Create:

- `apps/<app>/base/pvc.yaml`

Generic example:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
  namespace: apps-my-app
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: local-path
```

Only add a PVC when the app really needs persisted state.

Examples:

- n8n stores config and working state under `/home/node/.n8n`
- Actual stores app data under `/data`

## Step 6. Add ingress if the app needs external access

Create:

- `apps/<app>/base/ingress.yaml`

Generic example:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: apps-my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - app.example.com
      secretName: my-app-tls
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

Important:

- use valid DNS names
- do not use underscores in hostnames

## Step 7. Add the app secret

Create:

- `secrets/prod/<app>.sops.yaml`

Store only the values owned by the application there.

Generic example:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secret
  namespace: apps-my-app
type: Opaque
stringData:
  APP_KEY: change-me
```

Encrypt with:

```bash
sops --encrypt --in-place secrets/prod/<app>.sops.yaml
```

Add the secret file to:

- `secrets/prod/kustomization.yaml`

## Step 8. If the app needs PostgreSQL, provision it separately

Do not assume the application secret alone is enough.

For database-backed apps:

- create a dedicated database role if needed
- create a dedicated database if needed
- keep the DB role secret separate from the application secret
- make sure the app secret and DB role secret carry the same password value if both are used

Example from n8n:

- app secret: `secrets/prod/n8n.sops.yaml`
- DB role secret: `secrets/prod/postgres-n8n-auth.sops.yaml`
- dedicated DB: `apps/postgres/base/database-n8n.yaml`

For the PostgreSQL side, follow:

- `docs/setup/06_postgresql-setup.md`

## Step 9. Register the app in the aggregate kustomization

Add the app to:

- `apps/kustomization.yaml`

Example:

```yaml
resources:
  - whoami/prod
  - postgres/prod
  - n8n/prod
  - actual/prod
```

This is what makes the app part of the Flux `apps` reconciliation path.

## 4. Reconcile Sequence

Recommended order after commit and push:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization platform -n flux-system --with-source
flux reconcile kustomization secrets -n flux-system --with-source
flux reconcile kustomization apps -n flux-system --with-source
# optional to inspect it live
flux get kustomizations -A --watch
```

Why:

- `platform` ensures namespaces exist
- `secrets` ensures namespaced secrets exist
- `apps` deploys workloads that depend on those secrets and namespaces

## 5. Verification Checklist

### Verify namespace

```bash
kubectl get ns
```

### Verify secrets

```bash
kubectl get secret -n <namespace>
```

### Verify workload

```bash
kubectl get deploy -n <namespace>
kubectl get pods -n <namespace>
kubectl describe pod -n <namespace>
kubectl logs -n <namespace> deploy/<app> --tail=200
kubectl logs -n <namespace> deploy/<app> --previous --tail=200
```

### Verify service and ingress

```bash
kubectl get svc -n <namespace>
kubectl get ingress -n <namespace>
```

### Verify storage if used

```bash
kubectl get pvc -n <namespace>
kubectl get pv
```

## 6. n8n As The Example

n8n demonstrates several patterns that are reusable for other apps.

### Reusable patterns

- namespace owned by `platform/namespaces/`
- `base` and `prod` layout
- app secret in `secrets/prod/`
- PVC-backed state
- Ingress + TLS
- PostgreSQL integration through a dedicated app user and database
- app-level verification through logs and pod inspection

### n8n-specific lessons

- use `enableServiceLinks: false` when cluster-injected env vars can conflict with app config
- verify the real service name exposed by the database controller instead of assuming a hostname
- keep DB operator secrets separate from app secrets
- verify database login directly, not just secret values
- warnings about Python task runners may appear on newer n8n images even when they are not fatal for normal operation

## 7. Common Failure Modes

- namespace missing when secrets reconcile
- secret file exists in Git but is missing from `secrets/prod/kustomization.yaml`
- app exists under `apps/<app>/prod` but is missing from `apps/kustomization.yaml`
- ingress host is invalid
- service target port does not match container port
- PVC is missing or not bound
- app config expects a database host name that does not actually exist
- secrets match in Kubernetes but the external system behind them has stale state

## 8. Definition Of Done

An app setup is complete when:

- namespace exists in the platform layer
- app manifests exist under `apps/<app>/base` and `apps/<app>/prod`
- app is registered in `apps/kustomization.yaml`
- required secrets exist under `secrets/prod/` and are included in `secrets/prod/kustomization.yaml`
- Flux reconciles without errors
- pods become `Running`
- ingress and service are present if expected
- PVC is `Bound` if storage is required
- the app is reachable and healthy
