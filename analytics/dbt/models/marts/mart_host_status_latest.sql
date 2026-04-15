{{ config(
    tags = ['mart', 'host']
) }}
{% set cpu_cores = var('cpu_cores', 2) %}
-- mart_host_status_latest
-- Single-row snapshot of the most recent host collector run with derived
-- status fields. Smoke-test that the full pipeline (source → staging → mart)
-- is working end to end.

WITH latest AS (
    SELECT *
    FROM {{ ref('stg_host_snapshots') }}
    ORDER BY collected_at DESC
    LIMIT 1
)

SELECT
    snapshot_id,
    collected_at,

    -- CPU
    cpu_load_1m,
    cpu_load_5m,
    cpu_load_15m,
    CASE
        WHEN cpu_load_5m / {{ cpu_cores }} > 3.0 THEN 'critical'
        WHEN cpu_load_5m / {{ cpu_cores }} > 1.5 THEN 'warning'
        ELSE 'ok'
    END AS cpu_status,

    -- Memory (KB → MB)
    CAST(mem_total_kb / 1024 AS INTEGER)     AS mem_total_mb,
    CAST(mem_used_kb / 1024 AS INTEGER)      AS mem_used_mb,
    CAST(mem_available_kb / 1024 AS INTEGER) AS mem_available_mb,
    mem_used_pct,
    CASE
        WHEN mem_used_pct > 90 THEN 'critical'
        WHEN mem_used_pct > 75 THEN 'warning'
        ELSE 'ok'
    END AS mem_status,

    -- Uptime (seconds → days)
    ROUND(uptime_seconds / 86400.0, 1) AS uptime_days,

    -- Disk root (KB → GB)
    disk_root_used_pct,
    ROUND(disk_root_used_kb / 1048576.0, 2) AS disk_root_used_gb,
    ROUND(disk_root_size_kb / 1048576.0, 2) AS disk_root_size_gb,
    CASE
        WHEN disk_root_used_pct > 85 THEN 'critical'
        WHEN disk_root_used_pct > 70 THEN 'warning'
        ELSE 'ok'
    END AS disk_root_status,

    -- Disk data (KB → GB)
    disk_data_used_pct,
    ROUND(disk_data_used_kb / 1048576.0, 2) AS disk_data_used_gb,
    ROUND(disk_data_size_kb / 1048576.0, 2) AS disk_data_size_gb,
    CASE
        WHEN disk_data_used_pct > 85 THEN 'critical'
        WHEN disk_data_used_pct > 70 THEN 'warning'
        ELSE 'ok'
    END AS disk_data_status,

    -- Services
    svc_k3s_active,
    svc_sshd_active,
    svc_restic_timer_active,
    CASE
        WHEN NOT svc_k3s_active OR NOT svc_sshd_active THEN 'critical'
        WHEN NOT svc_restic_timer_active               THEN 'warning'
        ELSE 'ok'
    END AS services_status

FROM latest
