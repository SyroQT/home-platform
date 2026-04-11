# Analytics

This directory is the top-level home for the analytics project scaffold. It defines the canonical raw-zone folder conventions, the ownership boundaries for each sub-area, and the initial repository layout for collectors, modeling, dashboard work, and test fixtures.

## Canonical Raw-Zone Layout

The raw zone is append-only. Every collector run writes a new timestamped object and must not overwrite prior snapshots.

Canonical paths:

- `analytics/raw/host/{timestamp}.json`
- `analytics/raw/k8s/cluster/{timestamp}.json`
- `analytics/raw/k8s/workloads/{timestamp}.json`
- `analytics/raw/k8s/events/{timestamp}.txt`
- `analytics/raw/billing/{timestamp}.json`
- `analytics/raw/meta/{collector}/{timestamp}.json`

### Path Semantics

- `{timestamp}` is a sortable UTC collection timestamp chosen by the collector implementation.
- `host` stores raw VPS host snapshots.
- `k8s/cluster` stores cluster-level Kubernetes state snapshots.
- `k8s/workloads` stores raw workload snapshots such as pods and deployments.
- `k8s/events` stores raw event output as text.
- `billing` stores raw cost snapshot JSON documents.
- `meta/{collector}` stores pipeline run metadata for a named collector, such as runtime, exit status, and record counts.

## Initial Repository Layout

```text
analytics/
├── collectors/
│   ├── billing/
│   ├── host/
│   └── k8s/
├── dashboard/
├── dbt/
└── tests/
    └── fixtures/
```

## Ownership

- `collectors/` contains raw data extraction code and collector-specific documentation.
- `dbt/` contains transformation and modeling assets built on top of the raw zone.
- `dashboard/` contains presentation-layer code and dashboard assets.
- `tests/fixtures/` contains stable offline fixtures used to test collectors, models, and dashboard behavior.

Subdirectory READMEs define local ownership in more detail.
