# Analytical Layer Design

Date: 2026-03-29
Status: Proposed

## Goal

Add a lightweight analytical stack on top of the existing home-platform so the product side has a simple browser dashboard for inspecting:

- infrastructure cost
- core server status
- Kubernetes operational status
- application health

The technical goal is to make this a real data-engineering exercise rather than a thin monitoring integration. The stack should favor:

- extraction with simple Linux and Kubernetes tools such as `kubectl`, shell commands, and small scripts
- transformation and modeling with DuckDB and `dbt`
- presentation through a lightweight Python app with embedded Plotly charts
- GitOps-managed runtime configuration wherever that is a good fit

This is not intended to become a general-purpose observability platform or a replacement for a full monitoring stack.

## Product Scope

Version 1 is a single browser dashboard with four sections.

### 1. Billing

- show current estimated monthly infrastructure cost
- break cost down by major infrastructure resource where possible
- show a simple history or trend line from snapshots over time
- start with infrastructure cost only, not app-level cost allocation

### 2. Core Server

- CPU load
- memory usage
- disk usage
- uptime
- key host service status

### 3. Kubernetes

- node readiness
- deployment readiness
- failed jobs
- ingress status
- certificate status
- pod restart trends
- recent warning or error events summarized into a compact operational view

### 4. Application Health

One row per app, initially including `n8n`, `actual`, and `whoami`, based on technical checks only:

- pod readiness
- restart counts
- ingress reachability
- TLS validity

The dashboard should stay narrow and opinionated. It should read like an owner dashboard for the platform, not like a generic BI tool or a generic cluster console.

## Architectural Decision

The recommended shape is:

1. GitOps-managed Kubernetes collectors for cluster and app-health snapshots
2. Ansible-managed host collector for VPS snapshots
3. DuckDB as a separate analytics store and lakehouse-style modeling layer
4. `dbt-duckdb` for transformations and marts
5. a lightweight Python web app for HTML plus embedded Plotly charts

This design is preferred over:

- a node-only collector model, because it weakens GitOps alignment
- a heavy dashboard or observability product, because it shifts the work from data engineering to tool integration
- direct dashboarding on raw files, because that creates a brittle UI tightly coupled to collector formats

## Architecture

The system is split into four layers.

### Collectors

Collectors are scheduled snapshot jobs that gather raw operational data.

Cluster collectors:

- run as Flux-managed Kubernetes `CronJob` resources
- use simple commands and scripts, centered around `kubectl`
- collect cluster, workload, ingress, certificate, PVC, and app-health signals

Host collectors:

- are installed and scheduled via Ansible
- run from the VPS using shell commands and lightweight scripts
- collect host signals such as load, memory, disk, uptime, and service state

Billing collectors:

- start as simple infrastructure-cost snapshots based on known Hetzner resources and pricing assumptions
- can later be replaced or enriched with API-based collection if needed

### Raw Lake

Collectors write immutable timestamped files into a dedicated analytics raw zone.

Suggested logical structure:

- `analytics/raw/host/...`
- `analytics/raw/k8s/...`
- `analytics/raw/billing/...`
- `analytics/raw/meta/...`

The raw layer should be append-only. Failed runs should not overwrite the previous successful data.

### Modeling

DuckDB is the analytical storage layer. `dbt-duckdb` builds staged and curated models on top of the raw snapshot files.

Initial target marts:

- `mart_billing_daily`
- `mart_host_status_latest`
- `mart_host_status_history`
- `mart_k8s_status_latest`
- `mart_k8s_status_history`
- `mart_app_health_latest`
- `mart_pipeline_runs`

The marts should be product-oriented rather than source-oriented. The dashboard reads only these curated outputs.

### Presentation

The dashboard is a lightweight Python application that renders server-side HTML and embeds Plotly charts.

Design constraints:

- no heavy frontend framework
- no heavyweight BI or dashboard platform
- no direct reads from raw collector outputs
- read-only and stateless behavior

## Data Flow

The pipeline is snapshot-based rather than real-time.

1. Host collectors run on a schedule via systemd timer installed by Ansible.
2. Cluster collectors run on a schedule via Flux-managed `CronJob` resources.
3. Each run writes raw timestamped files into the analytics raw zone.
4. A separate transform job runs `dbt build` after collection windows.
5. `dbt` publishes updated modeled outputs only when the transform succeeds.
6. The Python dashboard reads the latest modeled state.

This model keeps extraction, modeling, and presentation cleanly separated.

## Ownership Boundaries

- Ansible owns host collector installation and scheduling.
- Flux owns in-cluster collectors and transform jobs.
- DuckDB and `dbt` own analytical modeling.
- The Python dashboard owns presentation only.

These boundaries are important because they prevent the dashboard from becoming a second ETL layer and prevent operational scripts from drifting outside Git-managed workflows.

## Storage And Lakehouse Direction

DuckDB is intentionally chosen as a learning-oriented analytical store separate from the application database.

Why this fits:

- it creates a real analytical modeling problem instead of querying OLTP data directly
- it works well with file-based raw data
- it supports lightweight local development
- it pairs naturally with `dbt` for staged and mart-style modeling

For version 1, the “lakehouse” concept is lightweight:

- raw snapshots are stored as files
- DuckDB reads and models them
- curated analytical tables are persisted for dashboard access

This does not require introducing a large data platform at the start.

## Failure Handling

The stack should degrade predictably.

- collectors write to new timestamped paths on each run
- failed collection does not erase the last good state
- transform jobs publish new modeled state only after success
- stale or missing data is shown as stale or missing in the dashboard, never silently treated as healthy
- each collector run should emit metadata such as source, run time, exit code, and row or file counts
- the dashboard should render partial results when one data source is unavailable

## Dashboard Behavior

The first version should be one page, not a multi-page product.

Expected behavior:

- summary cards at the top for freshness and key status indicators
- separate visual areas for billing, host status, Kubernetes status, and application health
- lightweight charts for trends and recent movement
- small tables for latest entity state

The product should optimize for inspectability and clarity over feature breadth.

## Testing Strategy

Testing is split by layer.

Collector tests:

- golden-file tests for shell or Python parsing
- fixture-based tests for normalization logic

`dbt` tests:

- schema tests
- freshness checks
- uniqueness checks
- accepted values
- semantic invariants, such as one latest row per entity

Dashboard tests:

- render tests against fixture DuckDB data
- verify correct handling of stale or empty sections

Integration testing:

- one local end-to-end flow using fixture collector outputs, `dbt build`, and dashboard startup

Avoid for version 1:

- CI that depends on a live cluster
- synthetic login or user-journey checks
- a large frontend framework
- a full observability suite just to support this dashboard

## Non-Goals

Version 1 does not aim to provide:

- app-level cost allocation
- real-time streaming metrics
- synthetic product transactions
- generic log search
- cluster-wide tracing
- a multi-tenant analytics platform

## Recommended Implementation Order

1. Define the analytics project structure and storage conventions.
2. Implement host and cluster raw collectors with fixture-driven tests.
3. Add DuckDB plus `dbt-duckdb` staging and mart models.
4. Build the lightweight Python dashboard against curated marts.
5. Add pipeline metadata, freshness signals, and polish.

## Open Risks

- Host-level collection and cluster-level collection will have different operational models, so ownership and storage conventions must stay explicit.
- Billing accuracy may start with static pricing assumptions before API-backed enrichment exists.
- Command-output-based collectors can drift when upstream output formats change, so fixture-based tests are important.
- The dashboard can become tightly coupled to raw data if curated marts are not kept strict.

## Recommendation

Proceed with a GitOps-aligned analytical stack that combines:

- Flux-managed Kubernetes snapshot collectors
- Ansible-managed host snapshot collectors
- DuckDB plus `dbt-duckdb` as the analytical lakehouse layer
- a lightweight Python dashboard with embedded Plotly visualizations

This best matches the current home-platform architecture and the stated goal of making the work a meaningful data-engineering exercise instead of a tool-installation exercise.
