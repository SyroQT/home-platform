{{ config(
    tags = ['mart', 'host']
) }}
--   Time-series, one row per snapshot, last 14 days.
--   Used for trend charts.

SELECT
    snapshot_id,
    collected_at,
    cpu_load_1m,
    cpu_load_5m,
    cpu_load_15m,
    mem_used_pct,
    mem_used_mb,
    disk_root_used_pct,
    disk_root_used_gb,
    disk_data_used_pct,
    disk_data_used_gb,
    uptime_days
FROM
    {{ ref('int_host_snapshots_enriched') }}
WHERE
    collected_at >= now() - INTERVAL '14 days'
ORDER BY
    collected_at ASC
