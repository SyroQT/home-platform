# Billing Collector

Captures a monthly Hetzner cost snapshot using static pricing and writes it to S3.

**Status: not yet implemented.** `collect.py` and the Ansible role are pending. Deferred until after Phase 4 (dbt modeling) is deployed.

## Planned Design

- Timer: monthly, first of month at 06:00 (`OnCalendar=*-*-01 06:00:00`)
- Output: `analytics/raw/billing/{timestamp}.json`
- Metadata: `analytics/raw/meta/billing/{timestamp}.json`

Static pricing at time of writing:

| Resource | Price |
|----------|-------|
| CX23 server | €4.83/month |
| Object Storage | €7.85/month |
| 50 GB block volume | €0.0572/GB/month |
| IPv4 address | €0.50/month |

## Planned Deployment

- Ansible role: `bootstrap/ansible/roles/analytics-billing-collector/` (pending)
- Playbook: `bootstrap/ansible/playbooks/analytics.yml` (to be extended)
- Credentials: same `/etc/analytics/host-collector.env` used by the host collector

## dbt Note

`mart_billing_daily` in dbt should remain stubbed until billing snapshots exist in S3.
