# Kubernetes Collectors

This directory owns Kubernetes collector code and documentation. Files here should gather raw cluster, workload, and event data and write immutable snapshots to the canonical `analytics/raw/k8s/*` prefixes, with collector metadata written under `analytics/raw/meta/{collector}/{timestamp}.json`.
