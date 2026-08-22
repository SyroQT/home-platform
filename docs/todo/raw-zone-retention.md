# Raw Zone Retention

Date: 2026-08-16
Status: Resolved (2026-08-22)

## Resolution

The bucket configuration was verified against the live bucket on 2026-08-22 via
`get-bucket-lifecycle-configuration`: both rules (`expire-noncurrent-90d`,
`expire-raw-analytics-90d`) are present, matching state. Decisions:

- **Retention window:** keep 90 days. The DR horizon stays at 90 days; cost is negligible either
  way.
- **P1 (meta glob):** done — `source_meta` in `_sources.yml` is now bounded to the rolling
  16-day window with explicit per-collector, per-day globs.
- **P2 (noncurrent window):** declined. Effective retention stays ~180 days (delete marker at
  day 90, reclaim at ~day 180). Storage is ~2.5 GB against a 1 TB plan, and skipping P2 avoids
  the rule-overlap uncertainty on Ceph RGW. Docs state ~180 days as the real figure.
- **P3 (Terraform):** minimal option — the deployed `expire-raw-analytics-90d` rule was added to
  `bucket.tf` with comments marking the lifecycle resources as documentation only; changes go
  through `aws s3api`.
- **P4 (stale docs):** done — `docs/project-status.md` and `docs/todo/analytical-layer-plan.md`
  updated.

The original investigation follows unchanged.

---

## Summary

Raw zone retention on the analytics bucket **is already configured and active** — a 90-day
expiration rule on `analytics/raw/`. It is not in the repository. It exists only in Terraform
state, having been applied out-of-band directly against the bucket.

Two consequences follow:

1. The repo and the docs both claim retention is unimplemented. They are wrong.
2. Because bucket versioning is enabled, the effective retention is roughly **180 days**, not 90.

Separately, the investigation surfaced a larger issue that no lifecycle rule can fix: one dbt
source reads the full history of the raw zone on every run.

---

## Evidence

### What the repository says

`bootstrap/terraform-hcloud/bucket.tf` defines exactly one lifecycle rule for the analytics
bucket:

```hcl
rule {
  id     = "expire-noncurrent-90d"
  status = "Enabled"
  filter {}
  noncurrent_version_expiration { noncurrent_days = 90 }
}
```

There is no `expiration` block. Collectors only ever write new keys and never overwrite, so
noncurrent versions are essentially never produced by normal operation — this rule is close to a
no-op for the raw zone on its own. Reading only the repo, the conclusion is "raw objects are kept
forever."

### What Terraform state says

`bootstrap/terraform-hcloud/terraform.tfstate` contains a **second rule** on the same bucket:

```json
{
  "id": "expire-raw-analytics-90d",
  "prefix": "analytics/raw/",
  "expiration": [{ "days": 90 }],
  "status": "Enabled"
}
```

This rule appears in no git revision. Verified by:

```bash
git log --all -S "expire-raw-analytics" --oneline        # zero hits
# plus a grep of every historical revision of bucket.tf  # zero hits
```

`bucket.tf` has only three commits, the most recent being `d34d63d` ("Add lifecycle
placeholders", 2026-04-12) — the commit that introduced the placeholder rules. State was last
written 2026-04-23, eleven days later.

### Why the drift was invisible

The lifecycle resource carries `lifecycle { ignore_changes = all }` (`bucket.tf:75`, and
`bucket.tf:51` for the backups bucket). Terraform
refreshes the resource from the remote but never plans to reconcile it. The out-of-band rule was
therefore absorbed into state silently and never reported as drift.

### Confidence

State reflects the bucket as of **2026-04-23**, four months ago. That is good evidence for April,
not proof for today. Verify before acting — see [Verification](#verification).

---

## Findings

### 1. Versioning doubles the retention window

Hetzner's documentation is explicit that when versioning is enabled, an `Expiration.Days` rule
**adds a delete marker instead of deleting the object**. Versioning is Enabled on this bucket
(`aws_s3_bucket_versioning.analytics`). The lifecycle therefore is:

| Day | Event | Billed? |
| --- | ----- | ------- |
| 0   | Collector writes object | yes |
| 90  | `expire-raw-analytics-90d` adds a delete marker; object becomes noncurrent | yes |
| 180 | `expire-noncurrent-90d` (`Prefix: ""`, so it also covers `analytics/raw/`) reclaims it | no |

A stated 90-day retention is really ~180 days of stored data. The noncurrent window, not the
expiration window, is the lever for a hard cap.

### 2. Terraform cannot apply lifecycle changes to this backend

The AWS provider's lifecycle read/write cycle does not survive Hetzner's S3 implementation. The
`ignore_changes = all` and 10-minute `timeouts` blocks in `bucket.tf` are scar tissue from this.
The supported path is `aws s3api`, using Hetzner's documented JSON shape — rule-level `Prefix`
rather than `Filter`, which matches what is already in state.

A Terraform resource that errors on apply *and* ignores drift is worse than no resource: it reads
as authoritative while being neither enforced nor accurate.

### 3. This is not a cost problem

Measured from the test fixtures in `analytics/tests/fixtures/`, one full collection cycle is
~143 KB:

| Object | Size |
| ------ | ---- |
| `k8s/workloads` | 72.8 KB |
| `k8s/events` | 59.6 KB |
| `k8s/certs` | 4.4 KB |
| `k8s/cluster` | 2.7 KB |
| `k8s/ingress` | 1.6 KB |
| `k8s/app-health` | 0.6 KB |
| `host` | 0.6 KB |
| `meta` (7 files) | ~0.8 KB |

At 96 cycles/day that is **~14 MB/day, ~5 GB/year**. Ninety days is ~1.2 GB; ~2.5 GB with the
versioning doubling — against the 1 TB included in the €7.85/month Object Storage plan.

Retention tuning saves effectively nothing. The meaningful pressure is object *count*
(~1,344/day, ~490k/year) and its effect on LIST-heavy read paths.

### 4. The real cost is an unbounded dbt glob

Seven of the eight sources in `analytics/dbt/models/staging/_sources.yml` are bounded to a rolling
window via `analytics_history_days: 16` (`analytics/dbt/dbt_project.yml:14`), expanded into
explicit per-day globs.

`source_meta` is the exception:

```yaml
external_location: "read_json_auto('{{ env_var('ANALYTICS_RAW_BASE_PATH') }}/meta/**/*.json', filename=true)"
```

This reads **full history on every meta run** (05:00 daily). Meta is roughly half of all objects
in the raw zone. This degrades continuously; a lifecycle rule caps the damage but never fixes it.
It is a code change, not an infrastructure change, and it is the highest-value item here.

### 5. Documentation is stale

- `docs/project-status.md:129` — "Retention: not implemented — planned Phase 6 (90-day target)"
- `docs/todo/analytical-layer-plan.md:333` — lists "Raw zone grows unbounded" as an open risk

Both describe a state that has not been true since roughly April.

---

## Constraint: retention is the disaster-recovery horizon

`analytics/dbt/run_dbt.sh --full-refresh` rebuilds all staging tables from S3. Normal incremental
runs only need the 16-day window, because history accumulates in
`/srv/data/analytics/analytics.duckdb`. But if that DuckDB file is ever lost, raw retention is the
hard limit on what can be reconstructed.

At 90 days the DR horizon is 90 days. Cutting raw retention to 30 days cuts the DR horizon to 30
days. This — not storage cost — should drive the choice of window.

---

## Verification

Run before changing anything. Requires the S3 credentials; `sops -d` needs the age key, which is
not present on all workstations.

```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket k3s-prod-analytics \
  --endpoint-url https://nbg1.your-objectstorage.com
```

Expected, if state is still accurate: two rules, `expire-noncurrent-90d` and
`expire-raw-analytics-90d`.

---

## Proposed Solutions

Ranked by value.

### P1 — Bound the `meta` glob to the rolling window

Bring `source_meta` in line with the other seven sources in `_sources.yml`. Removes a full-history
scan from the daily 05:00 meta run and makes read cost independent of retention.

`stg_meta_pipeline_runs` is `materialized = 'incremental'`, so bounding the source window does not
lose already-ingested history — it only limits what a `--full-refresh` can rebuild, which raw
retention already limits anyway.

Note the macro caveat at `analytics/dbt/macros/rolling_window_glob.sql`: dbt does not expose
project macros during `schema.yml` rendering, so the inline Jinja pattern used by the other
sources must be copied rather than the macro called.

### P2 — Cut the noncurrent window for the raw prefix

Halves raw storage and, more importantly, makes the stated retention the real retention. No effect
on the DR horizon.

`put-bucket-lifecycle-configuration` **replaces the entire configuration**, so both rules must be
submitted together:

```json
{
  "Rules": [
    {
      "ID": "expire-raw-analytics-90d",
      "Status": "Enabled",
      "Prefix": "analytics/raw/",
      "Expiration": { "Days": 90 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 1 }
    },
    {
      "ID": "expire-noncurrent-90d",
      "Status": "Enabled",
      "Prefix": "",
      "NoncurrentVersionExpiration": { "NoncurrentDays": 90 }
    }
  ]
}
```

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket k3s-prod-analytics \
  --lifecycle-configuration file://lifecycle.json \
  --endpoint-url https://nbg1.your-objectstorage.com
```

**Open question.** These two rules overlap on the `analytics/raw/` prefix, and Ceph RGW's
overlap-resolution is not guaranteed to match AWS semantics. Do not assume the intended result —
apply, then observe actual object counts over two to three weeks before treating it as settled.
If overlap proves unreliable, make the rules non-overlapping by scoping the bucket-wide rule to
the prefixes it actually needs.

### P3 — Stop pretending Terraform manages this

Two options:

- **Preferred:** remove `aws_s3_bucket_lifecycle_configuration.analytics` and `.backups` from
  Terraform entirely (`terraform state rm` to avoid a destroy), and document lifecycle management
  in a runbook alongside `docs/setup/object-storage-key-rotation.md`, which already establishes
  the `aws s3api`-against-Hetzner pattern.
- **Minimal:** keep the resources but add the deployed `expire-raw-analytics-90d` rule to
  `bucket.tf` with a comment explaining that the block is documentation only, is not applied by
  Terraform, and that changes must go through `aws s3api`.

Either way the repo should stop implying Terraform is the source of truth for lifecycle rules.

### P4 — Fix the stale documentation

Update `docs/project-status.md:129` and `docs/todo/analytical-layer-plan.md:333` to describe the
retention that actually exists, and link here.

---

## Decisions Needed

1. **Retention window.** Keep 90 days, or shorten? The binding constraint is the DR horizon
   (90 days today), not cost. dbt's normal operation needs only 16 days.
2. **P3 shape.** Remove the Terraform lifecycle resources, or keep them as annotated
   documentation?

---

## References

- [Applying lifecycle policies — Hetzner Docs](https://docs.hetzner.com/storage/object-storage/howto-protect-objects/manage-lifecycle/)
- [Buckets & objects — Hetzner Docs](https://docs.hetzner.com/storage/object-storage/faq/buckets-objects/)
- `bootstrap/terraform-hcloud/bucket.tf` — lifecycle placeholders
- `analytics/dbt/models/staging/_sources.yml` — rolling-window globs and the unbounded `source_meta`
- `analytics/dbt/run_dbt.sh` — `--full-refresh` semantics
- `docs/setup/object-storage-key-rotation.md` — existing `aws s3api` + Hetzner runbook pattern
