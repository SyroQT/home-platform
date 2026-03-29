# SOPS And Ingress Setup

Command reference for secret encryption, Flux decryption, cert-manager, issuers, and ingress/TLS verification in this repository.

## Scope

This repo currently uses:

- SOPS + age for encrypted secrets
- Flux for runtime decryption and reconciliation
- cert-manager for certificate issuance
- K3s bundled Traefik as the ingress controller

Relevant repo paths:

- `.sops.yaml`
- `secrets/prod/`
- `clusters/vps-prod/kustomizations/secrets.yaml`
- `platform/cert-manager/`
- `platform/cert-manager-issuers/`
- `platform/ingress/`

## 1. Install Local Tooling

```bash
brew install sops age
brew install fluxcd/tap/flux
```

Verify:

```bash
sops --version
age --version
flux --version
kubectl version --client
```

## 2. Generate And Inspect The age Key

Create the age keypair used for SOPS:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Show the public key:

```bash
age-keygen -y ~/.config/sops/age/keys.txt
```

Inspect the local key file:

```bash
cat ~/.config/sops/age/keys.txt
```

## 3. Create Or Edit Encrypted Secrets

Create a plain Kubernetes Secret manifest for encryption:

```bash
kubectl create secret generic demo-secret \
  --namespace default \
  --from-literal=username=demo \
  --from-literal=password=change-me \
  --dry-run=client -o yaml > secrets/prod/demo-secret.sops.yaml
```

Encrypt it in place:

```bash
sops --encrypt --in-place secrets/prod/demo-secret.sops.yaml
```

Decrypt for inspection only:

```bash
sops --decrypt secrets/prod/demo-secret.sops.yaml
```

Edit safely:

```bash
sops secrets/prod/demo-secret.sops.yaml
```

Re-encrypt in place if needed:

```bash
sops --encrypt --in-place secrets/prod/demo-secret.sops.yaml
```

Verify the file is encrypted on disk:

```bash
cat secrets/prod/demo-secret.sops.yaml
```

Expected result:

- secret values are `ENC[...]`
- a `sops:` metadata block exists

## 4. Wire SOPS Decryption Into Flux

Create the decryption Secret in `flux-system`:

```bash
kubectl create secret generic sops-age \
  -n flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

Verify it exists:

```bash
kubectl get secret sops-age -n flux-system
```

Confirm the Flux Kustomization contains the decryption block:

```bash
kubectl get kustomization secrets -n flux-system -o yaml
```

Reconcile the Git source and secret manifests:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization secrets -n flux-system
```

Check status:

```bash
flux get kustomizations -A
kubectl get secrets -A
```

## 5. cert-manager Installation Commands

The repo installs cert-manager through Flux from `platform/cert-manager/`.

Check the Helm release:

```bash
kubectl get helmrelease -n flux-system
kubectl get helmrelease cert-manager -n flux-system
```

Check cert-manager pods:

```bash
kubectl get pods -n cert-manager
```

Check that the CRDs exist:

```bash
kubectl get crd | grep cert-manager.io
```

Force reconciliation if needed:

```bash
flux reconcile kustomization platform -n flux-system
```

## 6. Issuer Reconciliation Commands

Issuer manifests are split into `platform/cert-manager-issuers/` and reconciled by the separate `cert-issuers` Flux Kustomization.

Check Flux ordering and readiness:

```bash
flux get kustomizations -A
kubectl get kustomization cert-issuers -n flux-system -o yaml
```

Reconcile issuers after `platform` is ready:

```bash
flux reconcile kustomization cert-issuers -n flux-system
```

Verify the `ClusterIssuer` exists:

```bash
kubectl get clusterissuer
kubectl get clusterissuer letsencrypt-staging -o yaml
```

## 7. Ingress / Traefik Verification Commands

This cluster currently relies on the K3s bundled Traefik ingress controller. The repo path `platform/ingress/` exists, but is currently an empty placeholder.

Verify Traefik is running:

```bash
kubectl get pods -n kube-system | grep traefik
kubectl get svc -n kube-system | grep traefik
```

Verify ingress classes:

```bash
kubectl get ingressclass
```

List ingress resources:

```bash
kubectl get ingress -A
```

Describe a specific ingress during debugging:

```bash
kubectl describe ingress <name> -n <namespace>
```

## 8. Certificate And ACME Debugging Commands

Check cert-manager resources:

```bash
kubectl get certificates,certificaterequests,orders,challenges -A
```

Describe a failed object:

```bash
kubectl describe certificate <name> -n <namespace>
kubectl describe certificaterequest <name> -n <namespace>
kubectl describe order <name> -n <namespace>
kubectl describe challenge <name> -n <namespace>
```

Check cert-manager logs:

```bash
kubectl logs -n cert-manager deploy/cert-manager
kubectl logs -n cert-manager deploy/cert-manager-webhook
kubectl logs -n cert-manager deploy/cert-manager-cainjector
```

## 9. Flux Debugging Commands

Check overall Flux health:

```bash
flux check
flux get all -A
flux get kustomizations -A
```

Inspect reconciliation errors:

```bash
flux logs --all-namespaces --follow=false
kubectl describe kustomization platform -n flux-system
kubectl describe kustomization cert-issuers -n flux-system
kubectl describe kustomization secrets -n flux-system
```

## 10. Minimal HTTPS Test Workflow

Use this flow before onboarding real apps.

1. Confirm prerequisites:

```bash
flux get kustomizations -A
kubectl get clusterissuer
kubectl get ingressclass
```

2. Apply the test workload manifests through Git and reconcile:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization platform -n flux-system
flux reconcile kustomization cert-issuers -n flux-system
flux reconcile kustomization apps -n flux-system
```

3. Verify ingress and certificate resources:

```bash
kubectl get ingress -A
kubectl get certificates,certificaterequests,orders,challenges -A
```

4. Validate HTTP to HTTPS behavior externally:

```bash
curl -I http://<host>
curl -Ik https://<host>
```

## Notes

- Do not keep decrypted secrets on disk.
- `sops <file>` is the standard editing workflow.
- `ClusterIssuer` resources must stay separate from the initial cert-manager install path.
- `apps` should depend on both `platform` and `cert-issuers` when TLS resources require cert-manager.
