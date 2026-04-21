{% set cpu_cores = var(
    'cpu_cores',
    2
) %}
{% set cpu_load_critical = var(
    'cpu_load_critical',
    3.0
) %}
{% set cpu_load_warning = var(
    'cpu_load_warning',
    1.5
) %}
{% set mem_critical_pct = var(
    'mem_critical_pct',
    4
) %}
{% set mem_warning_pct = var(
    'mem_warning_pct',
    10
) %}
{% set mem_watch_pct = var(
    'mem_watch_pct',
    20
) %}
{% set mem_critical_mb = var(
    'mem_critical_mb',
    150
) %}
{% set mem_warning_mb = var(
    'mem_warning_mb',
    400
) %}
{% set disk_critical_pct = var(
    'disk_critical_pct',
    85
) %}
{% set disk_warning_pct = var(
    'disk_warning_pct',
    70
) %}
{{ config(
    tags = ['intermediate', 'host']
) }}
-- int_host_snapshots_enriched
-- Enriches every host snapshot with derived status fields and human-friendly
-- units. One row per snapshot — grain matches stg_host_snapshots.
-- Marts slice this (e.g. latest row) without repeating business logic.
WITH enriched AS (

    SELECT
        *,
        ROUND(
            mem_available_kb :: DOUBLE / NULLIF(
                mem_total_kb,
                0
            ) * 100.0,
            1
        ) AS mem_available_pct
    FROM
        {{ ref('stg_host_snapshots') }}
)
SELECT
    snapshot_id,
    collected_at,
    -- CPU
    cpu_load_1m,
    cpu_load_5m,
    cpu_load_15m,
    CASE
        WHEN cpu_load_5m / {{ cpu_cores }} > {{ cpu_load_critical }} THEN 'critical'
        WHEN cpu_load_5m / {{ cpu_cores }} > {{ cpu_load_warning }} THEN 'warning'
        ELSE 'healthy'
    END AS cpu_status,
    -- Memory (KB → MB)
    CAST(
        mem_total_kb / 1024 AS INTEGER
    ) AS mem_total_mb,
    CAST(
        mem_used_kb / 1024 AS INTEGER
    ) AS mem_used_mb,
    CAST(
        mem_available_kb / 1024 AS INTEGER
    ) AS mem_available_mb,
    mem_used_pct,
    mem_available_pct,
    CASE
        WHEN mem_available_pct < {{ mem_critical_pct }}
        OR mem_available_kb / 1024 < {{ mem_critical_mb }} THEN 'critical'
        WHEN mem_available_pct < {{ mem_warning_pct }}
        OR mem_available_kb / 1024 < {{ mem_warning_mb }} THEN 'warning'
        WHEN mem_available_pct < {{ mem_watch_pct }} THEN 'watch'
        ELSE 'healthy'
    END AS mem_status,
    -- Uptime (seconds → days)
    ROUND(
        uptime_seconds / 86400.0,
        1
    ) AS uptime_days,
    -- Disk root (KB → GB)
    disk_root_used_pct,
    ROUND(
        disk_root_used_kb / 1048576.0,
        2
    ) AS disk_root_used_gb,
    ROUND(
        disk_root_size_kb / 1048576.0,
        2
    ) AS disk_root_size_gb,
    CASE
        WHEN disk_root_used_pct > {{ disk_critical_pct }} THEN 'critical'
        WHEN disk_root_used_pct > {{ disk_warning_pct }} THEN 'warning'
        ELSE 'healthy'
    END AS disk_root_status,
    -- Disk data (KB → GB)
    disk_data_used_pct,
    ROUND(
        disk_data_used_kb / 1048576.0,
        2
    ) AS disk_data_used_gb,
    ROUND(
        disk_data_size_kb / 1048576.0,
        2
    ) AS disk_data_size_gb,
    CASE
        WHEN disk_data_used_pct > {{ disk_critical_pct }} THEN 'critical'
        WHEN disk_data_used_pct > {{ disk_warning_pct }} THEN 'warning'
        ELSE 'healthy'
    END AS disk_data_status,
    -- Services
    svc_k3s_active,
    svc_sshd_active,
    svc_restic_timer_active,
    CASE
        WHEN NOT svc_k3s_active
        OR NOT svc_sshd_active THEN 'critical'
        WHEN NOT svc_restic_timer_active THEN 'warning'
        ELSE 'healthy'
    END AS services_status
FROM
    enriched
