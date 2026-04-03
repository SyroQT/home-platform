# Collectors

This directory owns raw data collection logic. Each subdirectory maps to one source domain and should contain only source-specific scripts, packaging, and documentation for writing raw snapshots to the canonical paths defined in [`analytics/README.md`](../README.md).

- `host/` owns VPS and operating-system level snapshots.
- `k8s/` owns Kubernetes cluster and workload snapshot collection.
- `billing/` owns infrastructure cost snapshot collection.
