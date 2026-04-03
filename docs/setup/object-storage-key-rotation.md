# Hetzner Object Storage Key Rotation

This runbook covers the current backup-related Hetzner Object Storage credential rotation flow for this repository.

It applies to these consumers:

- Terraform access to the backup bucket
- Restic backup on the VPS
- K3s etcd snapshot upload on the VPS
- PostgreSQL backup credentials in Kubernetes via SOPS and Flux

## Credential Map

One Hetzner Object Storage access key pair is currently used in four places.

| Consumer | Source file | Delivery path | Verification |
| --- | --- | --- | --- |
| Terraform bucket access | [`bootstrap/terraform-hcloud/terraform.tfvars`](/Users/syro/Documents/Work/personal/home-platform/bootstrap/terraform-hcloud/terraform.tfvars) | Local Terraform CLI | `aws s3api get-bucket-versioning ...` |
| Restic on VPS | [`bootstrap/ansible/inventories/prod/group_vars/vps/secrets.yml`](/Users/syro/Documents/Work/personal/home-platform/bootstrap/ansible/inventories/prod/group_vars/vps/secrets.yml) | Ansible renders `/etc/restic/env` | `restic snapshots` on VPS |
| K3s etcd snapshots on VPS | [`bootstrap/ansible/inventories/prod/group_vars/vps/secrets.yml`](/Users/syro/Documents/Work/personal/home-platform/bootstrap/ansible/inventories/prod/group_vars/vps/secrets.yml) | Ansible renders `/etc/rancher/k3s/config.yaml.d/etcd-s3.yaml` | inspect rendered file and K3s logs |
| PostgreSQL backup in cluster | [`secrets/prod/postgres-backup.sops.yaml`](/Users/syro/Documents/Work/personal/home-platform/secrets/prod/postgres-backup.sops.yaml) | Flux decrypts and applies Kubernetes Secret | `kubectl get secret ...` |

## Preconditions

Before rotating:

1. Create a new Hetzner Object Storage access key and secret.
2. Do not delete the old key until all verification steps pass.
3. Make sure these tools are available where you run commands:
   - `ansible`
   - `kubectl`
   - `flux`
   - `sops`
   - `aws`

The examples below use:

- bucket: `k3s-prod-backups`
- endpoint: `https://nbg1.your-objectstorage.com`
- inventory: `bootstrap/ansible/inventories/prod/hosts.ini`

## Step 1: Update Terraform Credentials

Edit [`bootstrap/terraform-hcloud/terraform.tfvars`](/Users/syro/Documents/Work/personal/home-platform/bootstrap/terraform-hcloud/terraform.tfvars) and replace:

- `object_storage_access_key`
- `object_storage_secret_key`

Optional verification against the bucket:

```bash
AWS_ACCESS_KEY_ID='<new-access-key>' \
AWS_SECRET_ACCESS_KEY='<new-secret-key>' \
aws s3api get-bucket-versioning \
  --bucket k3s-prod-backups \
  --endpoint-url https://nbg1.your-objectstorage.com
```

Expected output:

```json
{
  "Status": "Enabled",
  "MFADelete": "Disabled"
}
```

## Step 2: Update VPS Backup Credentials for Restic and K3s

Edit [`bootstrap/ansible/inventories/prod/group_vars/vps/secrets.yml`](/Users/syro/Documents/Work/personal/home-platform/bootstrap/ansible/inventories/prod/group_vars/vps/secrets.yml) and replace:

- `backup_s3_access_key`
- `backup_s3_secret_key`

Do not change `restic_password` during this process unless you are rotating the Restic repository password separately.

## Step 3: Push the Restic Update to the VPS

Run the backup playbook:

```bash
ansible-playbook \
  -i bootstrap/ansible/inventories/prod/hosts.ini \
  bootstrap/ansible/playbooks/backup.yml
```

This rewrites `/etc/restic/env` from [`restic-env.j2`](/Users/syro/Documents/Work/personal/home-platform/bootstrap/ansible/roles/restic/templates/restic-env.j2).

Verify the rendered environment file:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "sed -n '1,120p' /etc/restic/env"
```

Verify the variables export correctly:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "set -a; . /etc/restic/env; set +a; env | grep -E '^RESTIC_|^AWS_'"
```

Verify Restic can access the repository:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "set -a; . /etc/restic/env; set +a; restic snapshots"
```

Check the latest Restic job logs:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "journalctl -u restic-backup.service -n 50 --no-pager"
```

## Step 4: Push the K3s etcd S3 Update to the VPS

Run the K3s playbook:

```bash
ansible-playbook \
  -i bootstrap/ansible/inventories/prod/hosts.ini \
  bootstrap/ansible/playbooks/k3s.yml
```

This rewrites `/etc/rancher/k3s/config.yaml.d/etcd-s3.yaml` from [`k3s-etcd-s3.yml.j2`](/Users/syro/Documents/Work/personal/home-platform/bootstrap/ansible/roles/k3s/templates/k3s-etcd-s3.yml.j2) and notifies a K3s restart.

Verify the rendered K3s S3 config:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "sed -n '1,120p' /etc/rancher/k3s/config.yaml.d/etcd-s3.yaml"
```

Verify K3s is healthy after the update:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "systemctl status k3s --no-pager"
```

Check recent etcd snapshot-related logs:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "journalctl -u k3s -n 100 --no-pager | grep -i etcd"
```

Optional direct object storage check:

```bash
AWS_ACCESS_KEY_ID='<new-access-key>' \
AWS_SECRET_ACCESS_KEY='<new-secret-key>' \
aws s3 ls s3://k3s-prod-backups/etcd/ \
  --endpoint-url https://nbg1.your-objectstorage.com
```

## Step 5: Update PostgreSQL Backup Secret

Edit the SOPS-encrypted secret:

```bash
sops secrets/prod/postgres-backup.sops.yaml
```

Replace:

- `stringData.ACCESS_KEY_ID`
- `stringData.ACCESS_SECRET_KEY`

This secret is consumed by [`apps/postgres/base/objectstore.yaml`](/Users/syro/Documents/Work/personal/home-platform/apps/postgres/base/objectstore.yaml) through the `postgres-backup-s3` Secret in namespace `infra-postgres`.

## Step 6: Reconcile Flux Secrets

Apply the updated SOPS secret through Flux:

```bash
flux reconcile kustomization secrets -n flux-system
```

This uses the Flux `Kustomization` named `secrets` from [`clusters/vps-prod/kustomizations/secrets.yaml`](/Users/syro/Documents/Work/personal/home-platform/clusters/vps-prod/kustomizations/secrets.yaml).

Verify the Secret exists:

```bash
kubectl -n infra-postgres get secret postgres-backup-s3 -o yaml
```

Verify the secret data was updated:

```bash
kubectl -n infra-postgres get secret postgres-backup-s3 -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 --decode && echo
kubectl -n infra-postgres get secret postgres-backup-s3 -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 --decode && echo
```

Verify the ObjectStore still points at that Secret:

```bash
kubectl -n infra-postgres get objectstore postgres-backup -o yaml
```

Optional direct object storage check for PostgreSQL backup objects:

```bash
AWS_ACCESS_KEY_ID='<new-access-key>' \
AWS_SECRET_ACCESS_KEY='<new-secret-key>' \
aws s3 ls s3://k3s-prod-backups/cnpg/ \
  --recursive \
  --endpoint-url https://nbg1.your-objectstorage.com
```

## Step 7: Remove the Old Key

Only after all of the following succeed:

- Terraform access check works
- Restic can list snapshots
- K3s config is updated and K3s is healthy
- PostgreSQL Secret is updated in-cluster

Then delete the old Hetzner Object Storage key in the Hetzner console.

## Common Pitfalls

### Restic check fails with `source: not found`

Ansible `shell` uses `/bin/sh` by default. Use `.` instead of `source`.

Correct:

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "set -a; . /etc/restic/env; set +a; restic snapshots"
```

### Restic check fails with `Please specify repository location`

This usually means `/etc/restic/env` was loaded without exporting variables. Use:

```bash
set -a; . /etc/restic/env; set +a
```

before running `restic`.

### PostgreSQL Secret did not update in the cluster

Check:

1. The SOPS file was saved with the new values.
2. `flux reconcile kustomization secrets -n flux-system` completed successfully.
3. The decoded `kubectl get secret` values match the new key pair.

## Quick Verification Checklist

Run these after rotating:

```bash
AWS_ACCESS_KEY_ID='<new-access-key>' \
AWS_SECRET_ACCESS_KEY='<new-secret-key>' \
aws s3api get-bucket-versioning \
  --bucket k3s-prod-backups \
  --endpoint-url https://nbg1.your-objectstorage.com
```

```bash
ansible-playbook \
  -i bootstrap/ansible/inventories/prod/hosts.ini \
  bootstrap/ansible/playbooks/backup.yml
```

```bash
ansible -i bootstrap/ansible/inventories/prod/hosts.ini vps -b \
  -m shell -a "set -a; . /etc/restic/env; set +a; restic snapshots"
```

```bash
ansible-playbook \
  -i bootstrap/ansible/inventories/prod/hosts.ini \
  bootstrap/ansible/playbooks/k3s.yml
```

```bash
flux reconcile kustomization secrets -n flux-system
```

```bash
kubectl -n infra-postgres get secret postgres-backup-s3 -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 --decode && echo
kubectl -n infra-postgres get secret postgres-backup-s3 -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 --decode && echo
```
