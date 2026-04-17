# Host Collector

Collects VPS OS signals every 15 minutes and writes a timestamped JSON snapshot to S3.

## What It Collects

| Field(s) | Source |
|----------|--------|
| `cpu_load_1m/5m/15m` | `/proc/loadavg` |
| `mem_total_kb`, `mem_available_kb`, `mem_used_kb` | `/proc/meminfo` |
| `uptime_seconds` | `/proc/uptime` |
| `disk["/"]`, `disk["/srv/data"]` → `size_kb`, `used_kb`, `avail_kb`, `used_pct` | `df` |
| `services["k3s"]`, `services["sshd"]`, `services["restic-backup.timer"]` | `systemctl is-active` |

Output: `analytics/raw/host/{timestamp}.json`
Metadata: `analytics/raw/meta/host/{timestamp}.json`

## Testing

```bash
cd analytics && uv run pytest tests/test_host_collectors.py
```

Tests are golden-file only — no live VPS or S3 access needed. Fixture at `tests/fixtures/host/sample.json`.

## Deployment

- Ansible role: `bootstrap/ansible/roles/analytics-host-collector/`
- Playbook: `bootstrap/ansible/playbooks/analytics.yml`
- Installs to: `/opt/analytics/host/collect.py`
- Timer: `analytics-host-collector.timer`, every 15 minutes (`OnCalendar=*:0/15`)
- Credentials: `/etc/analytics/host-collector.env` (rendered from `secrets/prod/analytics-s3.sops.yaml`)

```bash
# Deploy or update
ansible-playbook bootstrap/ansible/playbooks/analytics.yml
```

## Environment Variables

Loaded from `/etc/analytics/host-collector.env` by systemd:

| Variable | Description |
|----------|-------------|
| `S3_ENDPOINT_URL` | Hetzner Object Storage endpoint (nbg1) |
| `S3_BUCKET` | Analytics bucket name |
| `AWS_ACCESS_KEY_ID` | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key |
