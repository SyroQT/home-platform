# Fixtures

Static offline snapshots used by collector and dbt tests.

## Layout

```
fixtures/
├── host/
│   └── sample.json          # single host collector snapshot
├── k8s/
│   ├── cluster/             # NodeList snapshot
│   ├── workloads/           # WorkloadList (deployments + pods)
│   ├── ingress/             # IngressList
│   ├── certs/               # CertificateList
│   ├── events/              # EventList
│   └── app-health/          # app-health dict keyed by namespace/app
└── meta/
    └── ...                  # pipeline run metadata samples
```

Host fixture is loaded by name (`sample.json`). K8s fixtures are loaded by glob (`*.json`, first match) so timestamped filenames from real captures work directly.

## Updating

Replace the file with a fresh snapshot captured from S3. Keep one file per collector — these are representative structure samples, not a history.
