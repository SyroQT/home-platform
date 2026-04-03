# Analytical Layer — Implementation Plan

_home-platform · 2026-04-02_

---

## Overview

Phased implementation plan for adding an analytical layer to the home-platform. Phases are in dependency order. Each phase produces a concrete, testable output before the next begins.

**Stack summary:**

- Flux-managed Kubernetes CronJob collectors for cluster and app-health snapshots
- Ansible-managed host collector for VPS snapshots
- Static billing snapshots based on known Hetzner pricing
- Raw snapshot files written to Hetzner Object Storage (nbg1)
- DuckDB as the analytical store, modeled with dbt-duckdb
- Lightweight Python dashboard reading curated dbt marts

## Layer and Ownership Map

| Layer | Owner | Runtime | Output |
|---|---|---|---|
| Collectors – Host | Ansible | systemd timer | Raw snapshots → Object Storage |
| Collectors – Cluster | Flux | CronJob | Raw snapshots → Object Storage |
| Collectors – Billing | Ansible or manual | systemd timer or script | Raw snapshots → Object Storage |
| Modeling | dbt-duckdb | CronJob (Flux) | Curated marts in DuckDB |
| Presentation | Python app | Flux Deployment | Dashboard HTML + Plotly charts |

---

## Phase 1 — Storage and Project Scaffolding

_Establish the raw zone, credentials, and folder conventions before any collector is written._

No collector code in this phase. The output is a defined, accessible raw zone in Object Storage with correct credentials and a committed project skeleton in Git. Every subsequent phase depends on these conventions being fixed.

### Tasks

**1.1 Create analytics bucket**
- Create a dedicated Hetzner Object Storage bucket for the analytics raw zone
- Region: nbg1, consistent with existing backup buckets
- Keep it separate from the backup and etcd snapshot buckets
- _Note: manual bucket creation is acceptable here — consistent with existing platform precedent of not adding a Terraform provider for a single resource_

**1.2 Create S3 credentials**
- Create a dedicated S3 access key pair for the analytics bucket
- Do not reuse backup or etcd snapshot credentials
- Store in a new SOPS-encrypted credentials file: `secrets/prod/analytics-s3.sops.yaml`
- Follow the existing schema used by `postgres-backup.sops.yaml`

**1.3 Define raw zone folder conventions**
- Commit the canonical folder layout as a documented convention (ADR or README)
- Canonical paths:
  - `analytics/raw/host/{timestamp}.json`
  - `analytics/raw/k8s/cluster/{timestamp}.json`
  - `analytics/raw/k8s/workloads/{timestamp}.json`
  - `analytics/raw/k8s/events/{timestamp}.txt`
  - `analytics/raw/billing/{timestamp}.json`
  - `analytics/raw/meta/{collector}/{timestamp}.json` — pipeline run metadata

**1.4 Scaffold analytics project directory**
- Add `analytics/` top-level directory to the repo with initial structure:
  - `analytics/collectors/host/`
  - `analytics/collectors/k8s/`
  - `analytics/collectors/billing/`
  - `analytics/dbt/`
  - `analytics/dashboard/`
  - `analytics/tests/fixtures/`
- Add a short README at each level describing ownership

**1.5 Verify S3 write access**
- Before writing any collector, confirm credentials work end-to-end
- Use the AWS CLI or a small boto3 script to put and get a test object
- Confirm path prefix conventions work as expected

---

## Phase 2 — Host Collector

_Ansible-managed systemd timer writing VPS snapshots to Object Storage._

Simplest collector to build and a good place to validate the full write path before adding Kubernetes complexity. Follows the same pattern as the existing restic systemd timer.

### Tasks

**2.1 Write host collector script**
- Shell or Python script collecting host signals and writing a timestamped JSON snapshot
- Signals to collect:
  - CPU load: `/proc/loadavg`
  - Memory: `/proc/meminfo`
  - Disk usage: `df` on `/srv/data` and `/`
  - Uptime: `/proc/uptime`
  - Key service status: `systemctl is-active` for k3s, sshd, and the restic timer
- Output: single JSON object with a `collected_at` ISO timestamp field
- Upload to `analytics/raw/host/{timestamp}.json` on Object Storage
- Emit a metadata record to `analytics/raw/meta/host/{timestamp}.json` with exit code and field count

**2.2 Add Ansible role for host collector**
- New role: `bootstrap/ansible/roles/analytics-host-collector/`
- Follow the restic role as the pattern
- Install the collector script to a fixed path on the VPS
- Template S3 credentials from the SOPS secret into an env file
- Create systemd service and timer units
- Default schedule: every 15 minutes
- Wire the role into a new playbook: `bootstrap/ansible/playbooks/analytics.yml`

**2.3 Write golden-file tests**
- Capture a real collector output as a fixture: `analytics/tests/fixtures/host/sample.json`
- Assert required fields are present: `collected_at`, `cpu_load_1m`, `mem_total_kb`, `disk_used_pct`, `uptime_seconds`, `services`
- Assert `collected_at` is a valid ISO timestamp
- Tests run offline against the fixture — no VPS connection needed

**2.4 Verify first live snapshot**
- Run the collector manually on the VPS and confirm the output appears in Object Storage
- Check path prefix matches the Phase 1 convention
- Confirm JSON is valid and all expected fields are present
- Confirm the metadata record was also written

---

## Phase 3 — Cluster and Billing Collectors

_Flux-managed CronJobs for Kubernetes signals, plus static billing snapshots._

Cluster collectors run inside the cluster as CronJobs and call `kubectl` against the cluster API. The billing collector starts as a static pricing script; it can be enriched with API calls later.

### Tasks

**3.1 Define RBAC for collector CronJobs**
- Create a ClusterRole granting read access to: pods, deployments, nodes, events, ingresses, certificates (cert-manager CRD), persistentvolumeclaims
- Verbs: `get`, `list`
- Namespace: `analytics` — add to `platform/namespaces/`
- ServiceAccount: `analytics-collector` in the `analytics` namespace
- Add a ClusterRoleBinding scoped to this ServiceAccount

**3.2 Write cluster collector scripts**
- Scripts run inside a CronJob pod and upload snapshots to Object Storage:
  - `cluster.sh`: `kubectl get nodes -o json` → `analytics/raw/k8s/cluster/{timestamp}.json`
  - `workloads.sh`: `kubectl get deployments,pods -A -o json` → `analytics/raw/k8s/workloads/{timestamp}.json`
  - `events.sh`: `kubectl get events -A --sort-by=.lastTimestamp` → `analytics/raw/k8s/events/{timestamp}.txt`
  - `ingress.sh`: `kubectl get ingress -A -o json` → `analytics/raw/k8s/ingress/{timestamp}.json`
  - `certs.sh`: `kubectl get certificates -A -o json` → `analytics/raw/k8s/certs/{timestamp}.json`
  - `app-health.sh`: per-app pod readiness and restart counts for n8n, actual, whoami
- Each script emits a metadata record to `analytics/raw/meta/k8s/{collector}/{timestamp}.json`

**3.3 Add Flux CronJob manifests for cluster collectors**
- One CronJob per collector script, or a single CronJob running all scripts sequentially
- Manifests in `apps/analytics/` or `platform/analytics/` — decision: platform layer since these are infrastructure collectors, not application workloads
- CronJob spec uses the `analytics-collector` ServiceAccount
- S3 credentials injected from `analytics-s3` Secret (sourced from `secrets/prod/analytics-s3.sops.yaml`)
- Schedule: every 15 minutes, offset from host collector to spread writes

**3.4 Write fixture tests for cluster collector output**
- Save sample `kubectl` outputs as fixtures in `analytics/tests/fixtures/k8s/`
- Assert required fields are present in each collector's output
- Tests run entirely offline against fixtures

**3.5 Write billing collector**
- Script that produces a JSON snapshot of estimated monthly infrastructure cost
- Start with static assumptions: known Hetzner server type, known pricing, known storage volumes
- Fields: `collected_at`, `period_month`, line items with `resource`, `unit_cost`, `quantity`, `estimated_total`
- Upload to `analytics/raw/billing/{timestamp}.json`
- Installed via Ansible alongside the host collector; runs monthly on the first of the month

---

## Phase 4 — DuckDB and dbt Modeling

_DuckDB as the analytical store; dbt-duckdb staging and mart models reading from raw Object Storage files._

This phase is largely offline work. You do not need the cluster running to develop dbt models — fixture snapshots from Phase 2 and 3 tests are enough to build and validate the full model layer.

### Tasks

**4.1 Set up the dbt project**
- Initialise a dbt project at `analytics/dbt/`
- Install `dbt-duckdb`
- Configure the DuckDB connection to read from Object Storage using the S3 credentials
- Configure DuckDB to persist the modeled database to a file on the VPS at `/srv/data/analytics/analytics.duckdb`

**4.2 Define dbt sources**
- One source per raw zone prefix:
  - `source_host` → `analytics/raw/host/*.json`
  - `source_k8s_cluster` → `analytics/raw/k8s/cluster/*.json`
  - `source_k8s_workloads` → `analytics/raw/k8s/workloads/*.json`
  - `source_k8s_events` → `analytics/raw/k8s/events/*.txt`
  - `source_billing` → `analytics/raw/billing/*.json`
  - `source_meta` → `analytics/raw/meta/**/*.json`
- Add dbt freshness checks on each source

**4.3 Write staging models**
- One staging model per source; staging normalises raw data into typed, structured rows
- `stg_host_snapshots`: parse host JSON into typed columns
- `stg_k8s_nodes`, `stg_k8s_pods`, `stg_k8s_deployments`: extract from workloads JSON
- `stg_k8s_events`: parse free-text event lines using `regexp_extract` / `string_split` into severity, age, object, message
- `stg_billing_snapshots`: parse billing JSON into line-item rows
- `stg_pipeline_runs`: parse metadata records

**4.4 Write mart models**
- Product-oriented marts that the dashboard reads directly:
  - `mart_host_status_latest`: latest single row of host signals
  - `mart_host_status_history`: time-series of host snapshots for trend charts
  - `mart_k8s_status_latest`: current node and workload readiness, restart counts, ingress and cert status
  - `mart_k8s_status_history`: time-series for pod restart trends and event counts
  - `mart_app_health_latest`: one row per app (n8n, actual, whoami) with pod readiness, restart count, ingress reachability, TLS validity
  - `mart_billing_daily`: daily estimated cost snapshots for the trend chart
  - `mart_pipeline_runs`: collector run history with exit codes and freshness signals

**4.5 Add dbt tests**
- Schema tests on all mart models: not-null on key columns, unique on entity + timestamp keys
- Accepted values tests on status fields
- Freshness checks: alert if latest snapshot is older than 1 hour for host and k8s sources
- Semantic invariants: exactly one latest row per entity in `_latest` marts

**4.6 Validate models against fixture data**
- Run `dbt build` locally using fixture snapshots from Phase 2 and 3
- Confirm all models build cleanly and all tests pass before wiring to live collectors

---

## Phase 5 — Python Dashboard

_Lightweight Python web app reading curated dbt marts and rendering server-side HTML with embedded Plotly charts._

Built last because it reads from curated marts, not raw files. This keeps it decoupled from collector output format changes.

### Tasks

**5.1 Scaffold the Python app**
- Framework: Flask or FastAPI with Jinja2 templates
- Single page, no multi-page routing for v1
- Reads from the DuckDB file at `/srv/data/analytics/analytics.duckdb`
- Read-only and stateless — no writes, no session state

**5.2 Build the four dashboard sections**
- **Billing**: estimated monthly cost summary card, cost breakdown table, trend line chart from `mart_billing_daily`
- **Core Server**: CPU, memory, disk, uptime, and service status cards from `mart_host_status_latest`; sparklines from `mart_host_status_history`
- **Kubernetes**: node readiness, deployment readiness, failed jobs, ingress and cert status table from `mart_k8s_status_latest`; pod restart trend chart from `mart_k8s_status_history`
- **Application Health**: one row per app with pod readiness, restart count, ingress reachability, TLS validity from `mart_app_health_latest`

**5.3 Add freshness and staleness indicators**
- Summary cards at the top: data freshness per source from `mart_pipeline_runs`
- Stale sections rendered visibly as stale, never silently treated as healthy
- Missing data sections show a "no data" state rather than failing to render

**5.4 Add Flux Deployment manifest**
- Manifest in `apps/analytics/`
- Mounts the DuckDB file from `/srv/data/analytics/` via a hostPath volume
- Ingress under a subdomain e.g. `analytics.titas.dev`
- TLS via cert-manager, consistent with other apps

**5.5 Write render tests**
- Tests render the dashboard against a fixture DuckDB file pre-populated with sample mart data
- Assert each section renders without error
- Assert stale and empty states are handled correctly and labelled clearly

---

## Phase 6 — Transform Job and Pipeline Wiring

_Flux-managed CronJob that runs `dbt build` after collection windows close, publishes updated marts, and emits pipeline metadata._

### Tasks

**6.1 Write the transform CronJob manifest**
- Flux-managed CronJob in `apps/analytics/` or `platform/analytics/`
- Runs `dbt build` against the live DuckDB file
- Schedule: runs after each collection window, e.g. 5 minutes past each 15-minute mark
- On failure: does not overwrite the last good modeled state
- On success: DuckDB file is updated with fresh marts

**6.2 Add pipeline run metadata emission**
- The transform job writes a record to `mart_pipeline_runs` on each run
- Fields: `run_at`, `exit_code`, `models_built`, `tests_passed`, `tests_failed`, `duration_seconds`
- Dashboard freshness cards read from this mart

**6.3 End-to-end local integration test**
- Using fixture collector outputs, run `dbt build` and start the dashboard
- Confirm the full flow works: fixtures → dbt models → dashboard renders correctly
- Document the local dev setup in `analytics/README.md`

---

## Open Decisions

| Decision | Options | Notes |
|---|---|---|
| Cluster collector image | Bitnami kubectl, custom image, or distroless + kubectl binary | Custom image gives most control; bitnami/kubectl is simplest to start |
| DuckDB file location | `/srv/data/analytics/analytics.duckdb` | Consistent with data volume convention; survives pod restarts |
| Dashboard deployment | Flux Deployment vs local-only for v1 | Flux Deployment preferred for consistency with platform conventions |
| Billing enrichment | Static pricing vs Hetzner API | Start static; API enrichment is a v2 concern |
| Transform job trigger | Time-based CronJob vs event-driven | Time-based CronJob is simpler and sufficient for v1 |

---

## Risk Register

| Risk | Mitigation |
|---|---|
| kubectl output format changes break staging models | Fixture-based tests fail loudly before the mart is affected |
| Collector CronJob fails silently | Metadata records + freshness checks surface failures in the dashboard |
| DuckDB file corruption if transform job is killed mid-write | DuckDB WAL provides crash safety; consider a copy-on-success pattern for extra safety |
| Billing estimates drift from actual costs | Mark billing section clearly as estimated; revisit with API enrichment in v2 |
| Raw zone grows unbounded | Add a retention policy (e.g. delete raw files older than 90 days) in Phase 6 or as a follow-up |
