# Analytics dbt Runner Setup

This document covers the `analytics-dbt-runner` Ansible role: what it does, how it is deployed, and how to verify it is working on the VPS.

It covers:

- what the role installs and where
- how S3 credentials flow from SOPS to dbt
- how to deploy it
- how to verify the timer and the DuckDB output

## 1. Overview

The `analytics-dbt-runner` role deploys a systemd timer on the VPS that runs `analytics/dbt/run_dbt.sh` every 15 minutes (offset 10 minutes from the host and cluster collectors). It produces the curated DuckDB file at `/srv/data/analytics/analytics.duckdb`.

It is the last piece of Phase 4 of the analytics layer.

```
[host collector]   :00/:15/:30/:45  →  raw S3 snapshots
[cluster collector] :05/:20/:35/:50  →  raw S3 snapshots
[dbt runner]       :10/:25/:40/:55  →  analytics.duckdb (reads from S3)
```

## 2. What the Role Installs

| Path | Purpose |
|------|---------|
| `/opt/analytics/dbt/` | dbt project (synced from `analytics/dbt/`) |
| `/opt/analytics/venv-dbt/` | Python virtualenv with `dbt-duckdb` |
| `/opt/analytics/dbt/profiles.yml` | dbt connection config (Ansible-templated, mode `0600`) |
| `/etc/systemd/system/analytics-dbt-runner.service` | oneshot service that runs `run_dbt.sh` |
| `/etc/systemd/system/analytics-dbt-runner.timer` | timer that fires at `:10/:25/:40/:55` |

`dbt_packages/` and `target/` are excluded from the sync and generated on the VPS by `dbt deps` and `dbt build` respectively.

## 3. How Credentials Flow

S3 credentials are decrypted from SOPS at playbook run time and written into `/opt/analytics/dbt/profiles.yml` by Ansible. The file is mode `0600` and owned by root.

```
secrets/prod/analytics-s3.sops.yaml
  │
  ├─ community.sops.load_vars         (play pre_task)
  ├─ ansible.builtin.set_fact          (maps to clean var names)
  └─ ansible.builtin.template          → /opt/analytics/dbt/profiles.yml (0600)
```

At runtime, `run_dbt.sh` also loads `/etc/analytics/host-collector.env` to export `ANALYTICS_S3_ACCESS_KEY` and `ANALYTICS_S3_SECRET_KEY` for its own S3 operations. The `profiles.yml` deployed by this role uses hardcoded values (written at deploy time), not env_var() lookups, for S3 credentials.

Why:

- credentials in `profiles.yml` avoid the need for the systemd service to carry them as environment variables
- `0600` prevents other processes from reading the file
- SOPS keys stay encrypted at rest in Git

## 4. Defaults

These variables are set in `bootstrap/ansible/roles/analytics-dbt-runner/defaults/main.yml`:

| Variable | Default | Notes |
|----------|---------|-------|
| `analytics_dbt_install_dir` | `/opt/analytics/dbt` | dbt project root on VPS |
| `analytics_dbt_venv_dir` | `/opt/analytics/venv-dbt` | virtualenv path |
| `analytics_dbt_version` | `1.10.1` | must match `analytics/uv.lock` |
| `analytics_s3_endpoint` | `nbg1.your-objectstorage.com` | Hetzner Object Storage |
| `analytics_s3_bucket` | `k3s-prod-analytics` | bucket name |

Two variables have no defaults and must be supplied by the playbook via `set_fact` from SOPS:

- `analytics_s3_access_key`
- `analytics_s3_secret_key`

## 5. Deploying

Run the analytics playbook from `bootstrap/ansible/`:

```bash
cd bootstrap/ansible
ansible-playbook playbooks/analytics.yml
```

The playbook has two plays:

1. **Deploy analytics collectors** — host collector (unchanged)
2. **Deploy analytics dbt runner** — new role

Both plays load `secrets/prod/analytics-s3.sops.yaml` independently. Ansible play-scoped vars do not carry between plays.

To deploy only the dbt runner play:

```bash
ansible-playbook playbooks/analytics.yml --tags '' --limit vps -e "ansible_play_name='Deploy analytics dbt runner'"
```

Or use `--start-at-task` to skip the collectors play during iteration:

```bash
ansible-playbook playbooks/analytics.yml --start-at-task "Load analytics S3 credentials" --skip-tags host-collector
```

For a dry run:

```bash
ansible-playbook playbooks/analytics.yml --check --diff
```

## 6. Verification

### Verify the timer is active

```bash
systemctl list-timers analytics-dbt-runner.timer
```

Expected: shows `Next` trigger at the next `:10`, `:25`, `:40`, or `:55` boundary.

### Verify the service runs without errors

Trigger a manual run:

```bash
systemctl start analytics-dbt-runner.service
```

Then inspect the journal:

```bash
journalctl -u analytics-dbt-runner.service -n 100
```

Expected log sequence:

```
[run_dbt] Starting dbt build (tmp: /srv/data/analytics/analytics.duckdb.tmp)
...dbt build output...
[run_dbt] dbt build succeeded — swapping into place
[run_dbt] Done. DB updated at /srv/data/analytics/analytics.duckdb
```

On failure the last good `.duckdb` is left untouched. The `.tmp` file is removed.

### Verify the DuckDB file

```bash
ls -lh /srv/data/analytics/analytics.duckdb
stat /srv/data/analytics/analytics.duckdb
```

The file's modification time should advance every 15 minutes after the timer fires.

### Verify profiles.yml was templated

```bash
cat /opt/analytics/dbt/profiles.yml
```

The `prod` target should show the actual S3 endpoint and key values (not placeholders). The file permissions should be `0600`:

```bash
stat /opt/analytics/dbt/profiles.yml
```

### Verify dbt packages are installed

```bash
ls /opt/analytics/dbt/dbt_packages/
```

Expected: `dbt_utils/` directory (installed by `dbt deps` during the Ansible run).

## 7. Updating dbt Version

The dbt version is pinned in two places:

1. `analytics/uv.lock` — controls the local development environment
2. `bootstrap/ansible/roles/analytics-dbt-runner/defaults/main.yml` — `analytics_dbt_version`

When bumping the version, update both. The `uv.lock` version governs what is installed locally via `uv sync`; the Ansible default governs what is installed on the VPS via `uv pip install`.

## 8. Relationship to Other Analytics Components

| Component | Role | Timer |
|-----------|------|-------|
| `analytics-host-collector` | collects VPS host metrics | `:0/15` (every 15 min, on the hour) |
| cluster collector | collects k8s metrics | `:5/15` (5-min offset) |
| `analytics-dbt-runner` | transforms raw → DuckDB | `:10,25,40,55` (10-min offset) |

The dbt runner reads from S3 (written by the collectors) and writes to the local DuckDB file. It does not depend on the collectors being healthy to run, but it will model whatever data is currently in S3.

`run_dbt.sh` is kept in `analytics/dbt/` alongside the dbt project. The Ansible sync task deploys it to the VPS as part of the dbt project directory. Do not maintain a separate copy.
