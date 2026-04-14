{{ config(materialized='view', tags=['staging', 'host']) }}

-- stg_host_snapshots
-- Normalises raw host collector JSON into typed, flat rows.
--
-- Source shape (one file per 15-min run):
--   collected_at        ISO timestamp string
--   cpu_load_1m/5m/15m  floats
--   mem_*_kb            integers
--   uptime_seconds      float
--   disk                struct keyed by mount point
--   services            struct keyed by service name

WITH raw AS (
    SELECT
        filename,
        collected_at::TIMESTAMPTZ                   AS collected_at_field,
        -- Derive timestamp from filename as a cross-check; use field value as
        -- authoritative (it has sub-second precision and proper tz offset).
        TRY_STRPTIME(
            regexp_replace(
                regexp_replace(regexp_replace(filename, '^.*/', ''), '\.json$', ''),
                '-(\d{2})-(\d{2})$', '+\1:\2'
            ),
            '%Y-%m-%dT%H-%M-%S.%f%z'
        )                                           AS collected_at_filename,
        cpu_load_1m::DOUBLE                         AS cpu_load_1m,
        cpu_load_5m::DOUBLE                         AS cpu_load_5m,
        cpu_load_15m::DOUBLE                        AS cpu_load_15m,
        mem_total_kb::BIGINT                        AS mem_total_kb,
        mem_available_kb::BIGINT                    AS mem_available_kb,
        mem_used_kb::BIGINT                         AS mem_used_kb,
        uptime_seconds::DOUBLE                      AS uptime_seconds,
        -- Disk: extract both mounts explicitly
        disk."/".used_pct::DOUBLE                   AS disk_root_used_pct,
        disk."/".size_kb::BIGINT                    AS disk_root_size_kb,
        disk."/".used_kb::BIGINT                    AS disk_root_used_kb,
        disk."/srv/data".used_pct::DOUBLE           AS disk_data_used_pct,
        disk."/srv/data".size_kb::BIGINT            AS disk_data_size_kb,
        disk."/srv/data".used_kb::BIGINT            AS disk_data_used_kb,
        -- Services: dot-notation for simple keys, struct_extract for hyphenated
        services.k3s::VARCHAR                       AS svc_k3s,
        services.sshd::VARCHAR                      AS svc_sshd,
        struct_extract(services, 'restic-backup.timer')::VARCHAR AS svc_restic_timer
    FROM {{ source('source_host', 'snapshots') }}
)

SELECT
    {{ dbt_utils.generate_surrogate_key(['filename']) }} AS snapshot_id,
    -- Use the in-file timestamp as authoritative
    collected_at_field                              AS collected_at,
    collected_at_filename                           AS collected_at_from_filename,
    cpu_load_1m,
    cpu_load_5m,
    cpu_load_15m,
    mem_total_kb,
    mem_available_kb,
    mem_used_kb,
    -- Derived: memory used percentage
    ROUND(mem_used_kb::DOUBLE / NULLIF(mem_total_kb, 0) * 100.0, 1) AS mem_used_pct,
    uptime_seconds,
    disk_root_used_pct,
    disk_root_size_kb,
    disk_root_used_kb,
    disk_data_used_pct,
    disk_data_size_kb,
    disk_data_used_kb,
    -- Services: map to booleans for easier mart logic (COALESCE so missing service = FALSE, not NULL)
    COALESCE(svc_k3s = 'active', FALSE)             AS svc_k3s_active,
    COALESCE(svc_sshd = 'active', FALSE)            AS svc_sshd_active,
    COALESCE(svc_restic_timer = 'active', FALSE)    AS svc_restic_timer_active
FROM raw
