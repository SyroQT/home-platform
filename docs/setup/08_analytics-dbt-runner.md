# Analytics dbt Runner Setup

This document covers the `analytics-dbt-runner` Ansible role: what it does, how it is deployed, and how to verify it is working on the VPS.

It covers:

- what the role installs and where
- how S3 credentials flow from SOPS to dbt
- how to deploy it
- how to verify the timers and the DuckDB output

## 1. Overview

The `analytics-dbt-runner` role deploys two systemd timers on the VPS:

| Timer | Fires | What it runs |
|-------|-------|-------------|
| `analytics-dbt-runner.timer` | Daily at **06:00** | Staging (incremental) + intermediate + marts + tests |
| `analytics-dbt-runner-meta.timer` | Daily at **05:00** | Meta models only (`tag:meta`) |

Both run `analytics/dbt/run_dbt.sh` (the meta timer passes `--meta`). They write to the shared DuckDB file at `/srv/data/analytics/analytics.duckdb`.

Staging tables are **incremental** — each daily run appends only new S3 files. Intermediate and mart tables are rebuilt from the local staging tables on every run (no S3 reads, fast).

The meta run fires first (05:00) because it is heavier and decoupled from the main pipeline. The main run follows at 06:00 when meta data is already fresh.

```
[meta timer]   05:00  →  tag:meta models only
[main timer]   06:00  →  staging (incremental) → intermediate + marts → tests
```

## 2. What the Role Installs

| Path | Purpose |
|------|---------|
| `/opt/analytics/dbt/` | dbt project (synced from `analytics/dbt/`) |
| `/opt/analytics/venv-dbt/` | Python virtualenv with `dbt-duckdb` |
| `/opt/analytics/dbt/profiles.yml` | dbt connection config (Ansible-templated, mode `0600`) |
| `/etc/systemd/system/analytics-dbt-runner.service` | oneshot service — runs `run_dbt.sh` |
| `/etc/systemd/system/analytics-dbt-runner.timer` | daily timer at 06:00 |
| `/etc/systemd/system/analytics-dbt-runner-meta.service` | oneshot service — runs `run_dbt.sh --meta` |
| `/etc/systemd/system/analytics-dbt-runner-meta.timer` | daily timer at 05:00 |

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
2. **Deploy analytics dbt runner** — this role

Both plays load `secrets/prod/analytics-s3.sops.yaml` independently. Ansible play-scoped vars do not carry between plays.

For a dry run:

```bash
ansible-playbook playbooks/analytics.yml --check --diff
```

## 6. Verification

### Verify timers are active

```bash
systemctl list-timers analytics-dbt-runner.timer analytics-dbt-runner-meta.timer
```

Expected: both show `Next` triggers at 05:00 and 06:00 respectively.

### Trigger a manual run

Main pipeline:

```bash
systemctl start analytics-dbt-runner.service
journalctl -u analytics-dbt-runner.service -n 100
```

Meta pipeline:

```bash
systemctl start analytics-dbt-runner-meta.service
journalctl -u analytics-dbt-runner-meta.service -n 100
```

Expected log sequence for main run:

```
[run_dbt] Running staging (incremental)...
[run_dbt] Staging completed in Xs.
[run_dbt] Running intermediate + marts...
[run_dbt] Intermediate + marts completed in Xs.
[run_dbt] Running tests...
[run_dbt] Tests completed in Xs.
[run_dbt] Done. Total duration: Xs.
```

Expected log sequence for meta run:

```
[run_dbt] Meta-only mode — running only tag:meta models
[run_dbt] Running meta models...
[run_dbt] Running meta tests...
[run_dbt] Meta run completed in Xs.
```

On failure the DuckDB WAL ensures the file is not corrupted and the last good state is preserved.

### Verify the DuckDB file

```bash
ls -lh /srv/data/analytics/analytics.duckdb
stat /srv/data/analytics/analytics.duckdb
```

The file's modification time should advance after each successful timer run.

### Verify profiles.yml was templated

```bash
cat /opt/analytics/dbt/profiles.yml
stat /opt/analytics/dbt/profiles.yml
```

The `prod` target should show actual S3 endpoint and key values (not placeholders). Permissions should be `0600`.

### Verify dbt packages are installed

```bash
ls /opt/analytics/dbt/dbt_packages/
```

Expected: `dbt_utils/` directory (installed by `dbt deps` during the Ansible run).

## 7. Full Refresh

If staging tables need to be rebuilt from scratch (after a schema change or if the DuckDB file is lost):

```bash
cd /opt/analytics/dbt
UV_PROJECT_ENVIRONMENT=/opt/analytics/venv-dbt ./run_dbt.sh --full-refresh
```

This drops and rebuilds all staging tables by reading all S3 history. It is slow — do not use on normal runs.

## 8. Updating dbt Version

The dbt version is pinned in two places:

1. `analytics/uv.lock` — controls the local development environment
2. `bootstrap/ansible/roles/analytics-dbt-runner/defaults/main.yml` — `analytics_dbt_version`

When bumping the version, update both. The `uv.lock` version governs what is installed locally via `uv sync`; the Ansible default governs what is installed on the VPS via `uv pip install`.

## 9. Relationship to Other Analytics Components

| Component | Role | Timer |
|-----------|------|-------|
| `analytics-host-collector` | collects VPS host metrics | every 15 min |
| cluster collector | collects k8s metrics | every 15 min |
| `analytics-dbt-runner-meta` | transforms meta pipeline runs | daily 05:00 |
| `analytics-dbt-runner` | transforms raw → DuckDB (staging + marts) | daily 06:00 |

The dbt runners read from S3 (written by the collectors) and write to the shared local DuckDB file. They do not depend on the collectors being healthy to run, but will model whatever data is currently in S3.

`run_dbt.sh` is kept in `analytics/dbt/` alongside the dbt project. The Ansible sync task deploys it to the VPS as part of the dbt project directory. Do not maintain a separate copy.
