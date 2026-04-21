# Disaster Recovery: Backup & Restore Runbook

## Overview

This document covers backup scope, schedules, verification commands, restore procedures, and a recovery drill for the `vps-prod` k3s cluster.

All backups are stored externally in **Hetzner Object Storage** (`nbg1.your-objectstorage.com`, bucket `k3s-prod-backups`). The VPS holds no source-of-truth data that is not also present in S3 or Git.

---

## Backup Inventory

### 1. k3s etcd Snapshots

**What is backed up:** The embedded etcd database, which contains all Kubernetes object state (Deployments, Services, ConfigMaps, Secrets, PVCs, CRDs, etc.).

| Property    | Value                                                       |
| ----------- | ----------------------------------------------------------- |
| Schedule    | Daily at **02:00 UTC**                                      |
| Retention   | 7 local snapshots on-node; unlimited in S3 (managed by k3s) |
| Compression | Enabled                                                     |
| Local path  | `/var/lib/rancher/k3s/server/db/snapshots/`                 |
| S3 path     | `s3://k3s-prod-backups/etcd/`                               |
| S3 endpoint | `nbg1.your-objectstorage.com`                               |

**What is NOT covered:** PVC data (persistent volume contents). Those are covered by Restic.

---

### 2. Restic PVC Backups

**What is backed up:** The k3s local-path provisioner data directory (`/srv/data/k3s-local-path`), which contains the on-disk content of all `local-path` PVCs — except PostgreSQL PVCs (handled separately by CNPG).

| Property       | Value                                                                  |
| -------------- | ---------------------------------------------------------------------- |
| Schedule       | Daily at **04:00 UTC** (with up to 5-min randomised delay)             |
| Retention      | 7 daily + 4 weekly snapshots; older snapshots are pruned automatically |
| Excluded paths | `*.tmp`, `*.lock`, `*/pvc-*_infra-postgres_*`                          |
| Tag            | `k3s-pvc`                                                              |
| S3 repository  | `s3:https://nbg1.your-objectstorage.com/k3s-prod-backups/restic`       |
| Config file    | `/etc/restic/env`                                                      |
| Backup script  | `/usr/local/bin/restic-backup.sh`                                      |

---

### 3. PostgreSQL (CNPG) Data

**What is backed up:** Continuous WAL archiving plus a daily base backup via the [barman-cloud CNPG plugin](https://cloudnative-pg.io/documentation/current/barman-cloud/). Covers the `infra-postgres/postgres-cluster` CNPG cluster.

| Property      | Value                                                        |
| ------------- | ------------------------------------------------------------ |
| Schedule      | Daily base backup at **03:00 UTC** (`ScheduledBackup`)       |
| WAL archiving | Continuous (every completed WAL segment is shipped to S3)    |
| Retention     | 7 days (`retentionPolicy: 7d` on the `ObjectStore`)          |
| Compression   | gzip (both data and WAL)                                     |
| S3 path       | `s3://k3s-prod-backups/cnpg/`                                |
| S3 endpoint   | `nbg1.your-objectstorage.com`                                |
| Secret        | `infra-postgres/postgres-backup-s3` (from `secrets/prod/postgres-backup.sops.yaml`) |

The `Cluster` references the `ObjectStore` via the barman-cloud plugin (`barmanObjectName: postgres-backup`). WAL archiving is enabled automatically because `isWALArchiver: true` is set on the plugin.

**What is NOT covered:** Restic and etcd backups do not include PostgreSQL data — the Restic job explicitly excludes the `infra-postgres` PVC path.

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

### Restore: PostgreSQL (CNPG) from Barman Cloud

> Use this when PostgreSQL data is corrupted or lost and you need to restore from a base backup + WAL replay.

> CNPG point-in-time recovery (PITR) lets you restore to any timestamp covered by the WAL archive.

1. **Identify the target recovery time** (or use `latest` to get the most recent consistent state).

2. **Edit `apps/postgres/base/postgres-cluster.yaml`** to add a `recovery` bootstrap block, replacing the `initdb` block:

   ```yaml
   bootstrap:
     recovery:
       source: postgres-backup
   externalClusters:
     - name: postgres-backup
       plugin:
         name: barman-cloud.cloudnative-pg.io
         parameters:
           barmanObjectName: postgres-backup
           # Optional: point-in-time recovery
           # recoveryTarget:
           #   targetTime: "2026-01-15 03:00:00"
   ```

3. **Apply the change via Flux** (commit and push, or force-reconcile):

   ```bash
   sudo k3s kubectl -n flux-system annotate kustomization/apps \
     reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
   ```

4. **Monitor recovery progress:**

   ```bash
   sudo k3s kubectl -n infra-postgres get cluster postgres-cluster -w
   sudo k3s kubectl -n infra-postgres logs -l cnpg.io/cluster=postgres-cluster -f
   ```

   CNPG will create a new primary by restoring the base backup and replaying WAL segments.

5. **Verify the cluster is healthy:**

   ```bash
   sudo k3s kubectl -n infra-postgres get cluster postgres-cluster
   # Expected: READY=1, STATUS=Cluster in healthy state
   ```

6. **Revert the `bootstrap` change** back to `initdb` in Git once recovery is confirmed, to prevent re-triggering recovery on the next reconcile.

---

### Restore: PVC Data from Restic

> Use this when a PVC's data is corrupted or accidentally deleted and you need to recover files from a previous snapshot.

> Do not use this procedure for PostgreSQL. The Restic backup job excludes the `infra-postgres` PVC path.

> **Important:** never use `cp` for PVC restores. It can merge old and new files and leave stale data behind. Always use `rsync -a --delete` so the live PVC becomes an exact match of the selected snapshot.

---

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

3. **Browse the snapshot contents (recommended — confirm exact restore path):**

   ```bash
   restic ls <snapshot-id> /srv/data/k3s-local-path
   sudo find /srv/data/k3s-local-path -maxdepth 2 -type d | sort
   ```

4. **Restore to a temporary directory first:**

   ```bash
   restic restore <snapshot-id> \
     --target /tmp/restic-restore \
     --include /srv/data/k3s-local-path/<pvc-directory>
   ```

5. **Stop the workload using the PVC** (required to avoid data races):

   ```bash
   sudo k3s kubectl scale deployment/<name> -n <namespace> --replicas=0
   sudo k3s kubectl get pods -n <namespace>
   ```

   Wait until the pod is fully terminated.

6. **Sync the exact restored PVC subdirectory into place**
   using `rsync` with deletion semantics:

   ```bash
   sudo rsync -a --delete \
     /tmp/restic-restore/srv/data/k3s-local-path/<pvc-directory>/ \
     /srv/data/k3s-local-path/<pvc-directory>/
   ```

   Notes:
   - the **trailing slash matters**
   - sync from the **exact PVC subdirectory inside the snapshot**
   - do **not** sync from `/tmp/restic-restore/` root
   - `--delete` removes stale files that do not exist in the snapshot

7. **If the workload uses SQLite or other file-based databases, fix ownership after restore**
   because restored files may come back as `root:root`:

   ```bash
   sudo chown -R 1000:1000 /srv/data/k3s-local-path/<pvc-directory>
   sudo find /srv/data/k3s-local-path/<pvc-directory> -type d -exec chmod 755 {} \;
   sudo find /srv/data/k3s-local-path/<pvc-directory> -type f -exec chmod 644 {} \;
   ```

   This is especially important for:
   - Actual Budget
   - SQLite-backed applications
   - apps that create WAL/journal files

8. **Restart the workload:**

   ```bash
   sudo k3s kubectl scale deployment/<name> -n <namespace> --replicas=1
   sudo k3s kubectl rollout status deployment/<name> -n <namespace>
   ```

9. **Clean up the temporary restore directory:**

   ```bash
   sudo rm -rf /tmp/restic-restore
   ```

10. **Verify the application is healthy.**

---

### Restore validation checklist

Before assuming the backup is bad, verify all of the following:

- the workload was fully stopped before restore
- the selected snapshot predates the unwanted change
- the **exact PVC subdirectory** was restored (not the snapshot wrapper path)
- `rsync -a --delete` was used instead of `cp`
- file ownership is correct for the container runtime user
- the application is actually reading from that PVC path
- the data is not stored in PostgreSQL, which is outside Restic coverage (restore PostgreSQL via CNPG barman-cloud recovery instead)
- browser-local cache is not masking the server restore result (test in incognito if relevant)

---

### Lessons learned from restore drills

- `cp` is unsafe for stateful PVC restores because it merges data
- restoring from the wrong wrapper level can make applications appear empty
- SQLite-based apps may fail with `readonly database` after restore if ownership is not corrected
- browser-local state can make a successful server restore appear broken
- restore drills must validate both **filesystem correctness** and **application behavior**

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

### Step 6 — Confirm PostgreSQL (CNPG) Backups are Active

Check WAL archiving status and most recent base backup:

```bash
# Check cluster WAL archiving status
sudo k3s kubectl -n infra-postgres get cluster postgres-cluster \
  -o jsonpath='{.status.conditions}' | jq .

# List recent backups
sudo k3s kubectl -n infra-postgres get backup

# Confirm S3 objects exist in the cnpg path
AWS_ACCESS_KEY_ID=<key> AWS_SECRET_ACCESS_KEY=<secret> \
  aws s3 ls s3://k3s-prod-backups/cnpg/ \
  --endpoint-url https://nbg1.your-objectstorage.com \
  --region nbg1 --recursive | tail -10
```

**Pass criteria:** At least one `Backup` object with `STATUS=completed` and S3 objects visible under `cnpg/`.

---

### Drill Result Checklist

| Check                                           | Result         |
| ----------------------------------------------- | -------------- |
| etcd snapshot in S3 within 48h                  | pass / fail    |
| Restic repository check passes                  | pass / fail    |
| Restic snapshot within 48h                      | pass / fail    |
| Restic file restore produces readable files     | pass / fail    |
| etcd snapshot file is valid gzip                | pass / fail    |
| CNPG WAL archiving is active (check cluster status) | pass / fail    |
| CNPG base backup exists in S3 within 48h            | pass / fail    |

Record the date and results. If any check fails, investigate before treating the backup layer as reliable.

---

## Key File Locations

| File                                          | Purpose                                                                                                   |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `/etc/rancher/k3s/config.yaml.d/etcd-s3.yaml` | k3s etcd S3 upload config                                                                                 |
| `/var/lib/rancher/k3s/server/db/snapshots/`   | Local etcd snapshot directory                                                                             |
| `/etc/restic/env`                             | Restic repository URL and credentials                                                                     |
| `/usr/local/bin/restic-backup.sh`             | Restic backup script                                                                                      |
| `/etc/systemd/system/restic-backup.service`   | Restic systemd service                                                                                    |
| `/etc/systemd/system/restic-backup.timer`     | Restic systemd timer                                                                                      |
| `bootstrap/ansible/roles/restic/`             | Ansible role that configures Restic                                                                       |
| `bootstrap/ansible/roles/k3s/`                | Ansible role that configures k3s and etcd snapshots                                                       |
| `secrets/prod/postgres-backup.sops.yaml`      | SOPS-encrypted S3 credentials for CNPG barman-cloud (`postgres-backup-s3` Secret in `infra-postgres`)     |
| `apps/postgres/base/objectstore.yaml`         | CNPG `ObjectStore` CR — S3 destination, credentials ref, retention policy                                  |
| `apps/postgres/base/scheduled-backup.yaml`    | CNPG `ScheduledBackup` CR — daily base backup at 03:00 UTC                                                 |
| `apps/postgres/base/postgres-cluster.yaml`    | CNPG `Cluster` — references `ObjectStore` via barman-cloud plugin for WAL archiving                        |
