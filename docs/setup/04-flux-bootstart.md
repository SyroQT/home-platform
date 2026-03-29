# Flux Bootstrap

Manual steps for bootstrapping Flux against this repository and cluster.

## Prerequisites

- `kubectl` is installed and configured to talk to the target K3s cluster
- access to the GitHub repository `SyroQT/home-platform`
- permission to add a deploy key in the GitHub repository settings

## 1. Install Flux CLI

On macOS, install Flux with Homebrew:

```bash
brew install fluxcd/tap/flux
```

Verify the CLI:

```bash
flux --version
```

## 2. Verify Kubernetes access

Check the current context:

```bash
kubectl config current-context
```

Check the cluster is reachable:

```bash
kubectl get nodes
```

Run Flux prerequisite checks:

```bash
flux check --pre
```

## 3. Generate the Flux SSH key

Create a dedicated deploy key for Flux:

```bash
ssh-keygen -t ed25519 -C "flux-vps-prod" -f ~/.ssh/flux-vps-prod
```

This creates:

- `~/.ssh/flux-vps-prod`
- `~/.ssh/flux-vps-prod.pub`

Recommended permissions:

```bash
chmod 600 ~/.ssh/flux-vps-prod
chmod 644 ~/.ssh/flux-vps-prod.pub
```

## 4. Add the public key to GitHub

Copy the public key:

```bash
cat ~/.ssh/flux-vps-prod.pub
```

In GitHub:

1. Open `SyroQT/home-platform`
2. Go to `Settings`
3. Go to `Deploy keys`
4. Click `Add deploy key`
5. Title it `flux-vps-prod`
6. Paste the contents of `~/.ssh/flux-vps-prod.pub`
7. Leave write access disabled unless Flux image automation will need to push back to the repo
8. Save

## 5. Bootstrap Flux

Run bootstrap from the repository root:

```bash
flux bootstrap git \
  --url=ssh://git@github.com/SyroQT/home-platform.git \
  --branch=main \
  --private-key-file="$HOME/.ssh/flux-vps-prod" \
  --path=clusters/vps-prod
```

Notes:

- use `"$HOME/.ssh/flux-vps-prod"` instead of `~/.ssh/flux-vps-prod`
- the `--path` value is the path inside the Git repository that Flux manages
- bootstrap is idempotent and can be re-run

## 6. Pull the generated files locally

`flux bootstrap git` writes and pushes manifests through a temporary clone. It does not update your current local checkout automatically.

Fetch and pull the new commit:

```bash
git fetch origin
git pull origin main
```

Then verify the generated manifests exist locally:

```bash
find clusters/vps-prod -maxdepth 3 -type f | sort
```

## 7. Verify Flux in the cluster

Check Flux controllers:

```bash
flux check
```

Check the created objects:

```bash
kubectl get pods -n flux-system
kubectl get gitrepositories,kustomizations -A
```

## Troubleshooting

If bootstrap fails with `open ~/.ssh/flux-vps-prod: no such file or directory`, use:

```bash
--private-key-file="$HOME/.ssh/flux-vps-prod"
```

If `clusters/vps-prod` stays empty after bootstrap, pull the new commit:

```bash
git pull origin main
```
