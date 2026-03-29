# Disaster Recovery: Backup & Restore Runbook

## Overview

This document covers backup scope, schedules, verification commands, restore procedures, and a recovery drill for the `vps-prod` k3s cluster.

All backups are stored externally in **Hetzner Object Storage** (`nbg1.your-objectstorage.com`, bucket `k3s-prod-backups`). The VPS holds no source-of-truth data that is not also present in S3 or Git.

---

## Backup Inventory

### 1. k3s etcd Snapshots

**What is backed up:** The embedded etcd database, which contains all Kubernetes object state (Deployments, Services, ConfigMaps, Secrets, PVCs, CRDs, etc.).

| Property | Value |
|---|---|
| Schedule | Daily at **02:00 UTC** |
| Retention | 7 local snapshots on-node; unlimited in S3 (managed by k3s) |
| Compression | Enabled |
| Local path | `/var/lib/rancher/k3s/server/db/snapshots/` |
| S3 path | `s3://k3s-prod-backups/etcd/` |
| S3 endpoint | `nbg1.your-objectstorage.com` |

**What is NOT covered:** PVC data (persistent volume contents). Those are covered by Restic.

---

### 2. Restic PVC Backups

**What is backed up:** The k3s local-path provisioner data directory (`/srv/data/k3s-local-path`), which contains the on-disk content of all `local-path` PVCs — except PostgreSQL PVCs (handled separately by CNPG).

| Property | Value |
|---|---|
| Schedule | Daily at **04:00 UTC** (with up to 5-min randomised delay) |
| Retention | 7 daily + 4 weekly snapshots; older snapshots are pruned automatically |
| Excluded paths | `*.tmp`, `*.lock`, `*/pvc-*_infra-postgres_*` |
| Tag | `k3s-pvc` |
| S3 repository | `s3:https://nbg1.your-objectstorage.com/k3s-prod-backups/restic` |
| Config file | `/etc/restic/env` |
| Backup script | `/usr/local/bin/restic-backup.sh` |

---

### 3. PostgreSQL (CNPG) Data

**Current state in this repository:** PostgreSQL is **not currently covered by a working backup path**.

The `infra-postgres/postgres` CNPG cluster PVC is excluded from Restic, but the CNPG `HelmRelease` does not currently define S3 backups, WAL archiving, or recovery configuration. The encrypted secret `secrets/prod/postgres-backup.sops.yaml` exists, but it is not wired into the PostgreSQL `HelmRelease` yet.

This means:

- Restic restores do not recover PostgreSQL data
- etcd restores do not recover PostgreSQL data
- there is no repo-defined CNPG restore procedure to run today

Until CNPG backup configuration is added and verified, treat PostgreSQL recovery as a documented gap.

---

## Checking Backup Status

### etcd Snapshots

SSH to the node and run:

```bash
# List local snapshots
sudo k3s etcd-snapshot ls

# Confirm the most recent snapshot timestamp
sudo ls -lh /var/lib/rancher/k3s/server/db/snapshots/

# Check k3s service logs for snapshot activity
sudo journalctl -u k3s -n 100 --no-pager | grep -i snapshot
```

Confirm S3 upload with the AWS CLI (credentials from Ansible secrets):

```bash
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws s3 ls s3://k3s-prod-backups/etcd/ \
  --endpoint-url https://nbg1.your-objectstorage.com \
  --region nbg1
```

---

### Restic PVC Backups

```bash
# Load restic environment (run as root on the VPS)
sudo bash -c 'set -a; source /etc/restic/env; set +a; restic snapshots --tag k3s-pvc'

# Check last backup log via systemd
sudo journalctl -u restic-backup.service -n 50 --no-pager

# Check the timer status and next scheduled run
sudo systemctl status restic-backup.timer

# Verify repository integrity
sudo bash -c 'set -a; source /etc/restic/env; set +a; restic check'
```

---

## Restore Procedures

### Restore: k3s Cluster from etcd Snapshot

> Use this when the cluster is unresponsive, etcd is corrupted, or you are rebuilding on a new node.

> This restores Kubernetes object state only. It does not restore PVC contents such as application files or PostgreSQL data.

1. **Stop k3s on the node:**
   ```bash
   sudo systemctl stop k3s
   ```

2. **Download the desired snapshot from S3** (if local copy is unavailable):
   ```bash
   AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
     aws s3 cp s3://k3s-prod-backups/etcd/<snapshot-file> /tmp/snapshot.db.gz \
     --endpoint-url https://nbg1.your-objectstorage.com
   ```

3. **Restore the snapshot:**
   ```bash
   sudo k3s server \
     --cluster-reset \
     --cluster-reset-restore-path=/tmp/snapshot.db.gz
   ```
   k3s will reset the etcd data directory and restore from the snapshot, then exit.

4. **Restart k3s normally:**
   ```bash
   sudo systemctl start k3s
   ```

5. **Verify cluster health:**
   ```bash
   sudo k3s kubectl get nodes
   sudo k3s kubectl get pods -A
   ```

6. **Re-reconcile Flux** if GitOps state has drifted:
   ```bash
   sudo k3s kubectl -n flux-system annotate kustomization/flux-system \
     reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
   ```

If the cluster appears to return to the same state after an etcd restore, that can be expected for two reasons:

- Flux will reconcile the current Git state back onto the cluster after it comes up
- application data stored in PVCs is outside etcd and remains unchanged unless restored separately

---

### Restore: PVC Data from Restic

> Use this when a PVC's data is corrupted or accidentally deleted and you need to recover files from a previous snapshot.

> Do not use this procedure for PostgreSQL. The Restic backup job excludes the `infra-postgres` PVC path.

1. **Load the restic environment (on the VPS node, as root):**
   ```bash
   sudo bash
   set -a; source /etc/restic/env; set +a
   ```

2. **List available snapshots:**
   ```bash
   restic snapshots --tag k3s-pvc
   ```
   Note the snapshot ID you want to restore from.

3. **Browse the snapshot contents (optional — confirm paths before restoring):**
   ```bash
   restic ls <snapshot-id> /srv/data/k3s-local-path
   ```

4. **Restore to a temporary directory first:**
   ```bash
   restic restore <snapshot-id> \
     --target /tmp/restic-restore \
     --include /srv/data/k3s-local-path/<pvc-directory>
   ```

5. **Stop the workload using the PVC** (to avoid data races):
   ```bash
   sudo k3s kubectl scale deployment/<name> -n <namespace> --replicas=0
   ```

6. **Copy restored files into place:**
   ```bash
   sudo cp -r /tmp/restic-restore/srv/data/k3s-local-path/<pvc-directory>/. \
     /srv/data/k3s-local-path/<pvc-directory>/
   ```

7. **Restart the workload:**
   ```bash
   sudo k3s kubectl scale deployment/<name> -n <namespace> --replicas=1
   ```

8. **Verify the application is healthy.**

If the application still shows the same data after this procedure, verify all of the following before assuming the backup is bad:

- the workload was fully stopped before files were copied back
- the restored snapshot timestamp predates the unwanted change
- the correct PVC directory was restored
- the application is actually reading from that PVC path
- the data is not stored in PostgreSQL, which is outside Restic coverage in the current repo state

---

## Recovery Drill

Run this drill periodically (recommended: quarterly) to confirm backups are valid and restore procedures work.

### Prerequisites

- SSH access to the VPS node
- Restic environment credentials (`/etc/restic/env` or Ansible vault)
- A test namespace or expendable workload available

---

### Step 1 — Confirm etcd Snapshots Exist in S3

```bash
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws s3 ls s3://k3s-prod-backups/etcd/ \
  --endpoint-url https://nbg1.your-objectstorage.com \
  --region nbg1
```

**Pass criteria:** At least one snapshot from the last 48 hours is listed.

---

### Step 2 — Confirm Restic Repository is Healthy

```bash
sudo bash -c 'set -a; source /etc/restic/env; set +a; restic check'
```

**Pass criteria:** `no errors were found` in output.

---

### Step 3 — Confirm Recent Restic Snapshot Exists

```bash
sudo bash -c 'set -a; source /etc/restic/env; set +a; restic snapshots --tag k3s-pvc --last'
```

**Pass criteria:** A snapshot from the last 48 hours is listed.

---

### Step 4 — Test a Restic File Restore

Pick a known PVC directory and restore a single file to `/tmp`:

```bash
# List a known PVC to find a test file
sudo bash -c 'set -a; source /etc/restic/env; set +a; \
  restic ls latest /srv/data/k3s-local-path' | head -30

# Restore a single directory/file from the latest snapshot
sudo bash -c 'set -a; source /etc/restic/env; set +a; \
  restic restore latest \
    --target /tmp/drill-restore \
    --include /srv/data/k3s-local-path/<chosen-pvc-dir>'

ls -lh /tmp/drill-restore/srv/data/k3s-local-path/<chosen-pvc-dir>/
```

**Pass criteria:** Files are present and readable in `/tmp/drill-restore`.

Clean up:
```bash
sudo rm -rf /tmp/drill-restore
```

---

### Step 5 — Simulate etcd Restore (Non-Destructive Dry Run)

Download the most recent snapshot and verify it is not corrupted:

```bash
# Download latest snapshot
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws s3 cp $(AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
    aws s3 ls s3://k3s-prod-backups/etcd/ \
    --endpoint-url https://nbg1.your-objectstorage.com \
    --region nbg1 \
    | sort | tail -1 | awk '{print "s3://k3s-prod-backups/etcd/"$4}') \
  /tmp/etcd-drill.db.gz \
  --endpoint-url https://nbg1.your-objectstorage.com

# Verify the file is a valid gzip
file /tmp/etcd-drill.db.gz
gunzip -t /tmp/etcd-drill.db.gz && echo "Snapshot file is valid"
```

**Pass criteria:** `gunzip -t` exits 0 with no errors.

Clean up:
```bash
rm /tmp/etcd-drill.db.gz
```

---

### Drill Result Checklist

| Check | Result |
|---|---|
| etcd snapshot in S3 within 48h | pass / fail |
| Restic repository check passes | pass / fail |
| Restic snapshot within 48h | pass / fail |
| Restic file restore produces readable files | pass / fail |
| etcd snapshot file is valid gzip | pass / fail |
| PostgreSQL backup path is configured and tested | currently fail |

Record the date and results. If any check fails, investigate before treating the backup layer as reliable.

---

## Key File Locations

| File | Purpose |
|---|---|
| `/etc/rancher/k3s/config.yaml.d/etcd-s3.yaml` | k3s etcd S3 upload config |
| `/var/lib/rancher/k3s/server/db/snapshots/` | Local etcd snapshot directory |
| `/etc/restic/env` | Restic repository URL and credentials |
| `/usr/local/bin/restic-backup.sh` | Restic backup script |
| `/etc/systemd/system/restic-backup.service` | Restic systemd service |
| `/etc/systemd/system/restic-backup.timer` | Restic systemd timer |
| `bootstrap/ansible/roles/restic/` | Ansible role that configures Restic |
| `bootstrap/ansible/roles/k3s/` | Ansible role that configures k3s and etcd snapshots |
| `secrets/prod/postgres-backup.sops.yaml` | SOPS-encrypted S3 credentials staged for CNPG, but not currently consumed by the PostgreSQL `HelmRelease` |
