# analytics-dbt-runner Ansible Role — Design

**Date:** 2026-04-19
**Branch:** analytics

---

## Overview

A new Ansible role `analytics-dbt-runner` that installs uv, creates a Python virtualenv, deploys the dbt project, templates `profiles.yml` with SOPS-decrypted S3 credentials, and wires up a systemd service+timer to run `run_dbt.sh` on a 25-minute cadence offset from the host collectors.

---

## Role Structure

```
bootstrap/ansible/roles/analytics-dbt-runner/
  defaults/main.yml
  handlers/main.yml
  tasks/main.yml
  templates/
    profiles.yml.j2
    dbt-runner.service.j2
    dbt-runner.timer.j2
```

No `files/` directory. `run_dbt.sh` is copied from source using a `playbook_dir`-relative path (same pattern as `collect.py` in `analytics-host-collector`).

---

## `defaults/main.yml`

```yaml
analytics_dbt_install_dir: /opt/analytics/dbt
analytics_dbt_venv_dir: /opt/analytics/venv-dbt
analytics_dbt_version: "1.10.1"          # pinned — matches analytics/uv.lock
analytics_s3_endpoint: "nbg1.your-objectstorage.com"
analytics_s3_bucket: "k3s-prod-analytics"
# analytics_s3_access_key and analytics_s3_secret_key must be provided
# by the playbook via set_fact from SOPS — no defaults defined here
```

---

## `handlers/main.yml`

Identical to `analytics-host-collector`:

```yaml
- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true
```

---

## Tasks (`tasks/main.yml`)

Tasks execute in this order:

1. **Check uv** — `command: uv --version`, `failed_when: false`, `changed_when: false`, register `uv_check`
2. **Install uv** — `shell: curl -LsSf https://astral.sh/uv/install.sh | sh`, env `UV_INSTALL_DIR: /usr/local/bin`, `when: uv_check.rc != 0`
3. **Create dbt install dir** — `file` task, path `{{ analytics_dbt_install_dir }}`, mode `0755`, owner/group `root`
4. **Create virtualenv** — `command: uv venv {{ analytics_dbt_venv_dir }}`, `args.creates: {{ analytics_dbt_venv_dir }}` for idempotency
5. **Install dbt-duckdb** — `command: uv pip install --python {{ analytics_dbt_venv_dir }} dbt-duckdb=={{ analytics_dbt_version }}`
6. **Sync dbt project files** — `ansible.posix.synchronize` from `{{ playbook_dir }}/../../../analytics/dbt/` to `{{ analytics_dbt_install_dir }}/`; rsync excludes: `profiles.yml`, `.user.yml`, `target/`, `dbt_packages/`; `delete: true`
7. **Set run_dbt.sh permissions** — `file` task on `{{ analytics_dbt_install_dir }}/run_dbt.sh`, mode `0755`, owner/group `root`
8. **Template profiles.yml** — `template` task, dest `{{ analytics_dbt_install_dir }}/profiles.yml`, mode `0600`, owner/group `root`
9. **Run dbt deps** — `command: uv run dbt deps --profiles-dir {{ analytics_dbt_install_dir }}`, chdir `{{ analytics_dbt_install_dir }}`, env `UV_PROJECT_ENVIRONMENT: {{ analytics_dbt_venv_dir }}`; `changed_when: false`
10. **Install systemd service** — `template` → `/etc/systemd/system/analytics-dbt-runner.service`, mode `0644`, notify `Reload systemd`
11. **Install systemd timer** — `template` → `/etc/systemd/system/analytics-dbt-runner.timer`, mode `0644`, notify `Reload systemd`
12. **Enable and start timer** — `systemd` task, `name: analytics-dbt-runner.timer`, `enabled: true`, `state: started`

---

## Templates

### `profiles.yml.j2`

Mirrors `profiles.yml.example` exactly — `dev` and `prod` targets only. Ansible vars injected into the prod target's four S3 fields. The `DBT_DUCKDB_PATH` `env_var()` call is wrapped in `{% raw %}...{% endraw %}` so Ansible passes it through unescaped for dbt to evaluate at runtime.

```yaml
home_platform:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /tmp/analytics_dev.duckdb
      extensions:
        - httpfs
        - json
      settings:
      threads: 2

    prod:
      type: duckdb
      path: "{% raw %}{{ env_var('DBT_DUCKDB_PATH', '/srv/data/analytics/analytics.duckdb') }}{% endraw %}"
      extensions:
        - httpfs
        - json
      settings:
        s3_endpoint: "{{ analytics_s3_endpoint }}"
        s3_url_style: path
        s3_access_key_id: "{{ analytics_s3_access_key }}"
        s3_secret_access_key: "{{ analytics_s3_secret_key }}"
        s3_region: "us-east-1"
      threads: 2
```

### `dbt-runner.service.j2`

```ini
[Unit]
Description=Analytics dbt runner
After=network.target

[Service]
Type=oneshot
ExecStart={{ analytics_dbt_install_dir }}/run_dbt.sh
Environment=UV_PROJECT_ENVIRONMENT={{ analytics_dbt_venv_dir }}
StandardOutput=journal
StandardError=journal
```

`UV_PROJECT_ENVIRONMENT` tells `uv run dbt` (called inside `run_dbt.sh`) which virtualenv to use, since there is no `pyproject.toml` in the dbt project directory.

### `dbt-runner.timer.j2`

```ini
[Unit]
Description=Analytics dbt runner timer
Requires=analytics-dbt-runner.service

[Timer]
OnCalendar=*:10/25/40/55
Persistent=true

[Install]
WantedBy=timers.target
```

Schedule offset from host collectors (`*:0/15`) to avoid resource contention: fires at :10, :35 past each hour (25-minute cadence).

---

## Playbook Change (`bootstrap/ansible/playbooks/analytics.yml`)

A second play is appended after the existing host-collector play:

```yaml
# This play must run after analytics-host-collector: run_dbt.sh sources
# /etc/analytics/host-collector.env for S3 credentials at runtime.
- name: Deploy analytics dbt runner
  hosts: vps
  become: true
  pre_tasks:
    - name: Load analytics S3 credentials
      community.sops.load_vars:
        file: "{{ playbook_dir }}/../../../secrets/prod/analytics-s3.sops.yaml"
        name: analytics_s3_creds

    - name: Set S3 credential vars
      ansible.builtin.set_fact:
        analytics_s3_access_key: "{{ analytics_s3_creds.stringData.analytics_s3_access_key_id }}"
        analytics_s3_secret_key: "{{ analytics_s3_creds.stringData.analytics_s3_secret_access_key }}"

  roles:
    - analytics-dbt-runner
```

SOPS is re-loaded in this play (play-scoped vars don't carry between plays). The `set_fact` maps from SOPS key names to the clean var names used in role templates and defaults.

---

## Key Decisions

- **Run as root** — matches `analytics-host-collector` pattern; no separate analytics system user
- **Venv at `/opt/analytics/venv-dbt`** — separate from install dir to keep dbt project files clean; `UV_PROJECT_ENVIRONMENT` wires `uv run` to it
- **Credentials in `profiles.yml`** — hardcoded by Ansible at deploy time (file mode `0600`); avoids needing dbt `env_var()` for S3 fields while `DBT_DUCKDB_PATH` stays as a runtime env_var
- **`dbt_packages/` excluded from sync** — regenerated by `dbt deps` on VPS from `packages.yml` + `package-lock.yml`; avoids shipping vendored packages in the deploy
- **`dbt-duckdb==1.10.1`** — pinned to match `analytics/uv.lock`
