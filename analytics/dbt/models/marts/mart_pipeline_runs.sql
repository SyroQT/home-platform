{{ config(
    tags = ['mart', 'meta']
) }}
-- mart_pipeline_runs
-- Last N runs per collector with exit code, age, and freshness status.
-- Observability mart — one row per collector run.
--
-- run_age_hours is relative to the most recent run across all collectors,
-- so all rows age together as new runs arrive.
WITH base AS (

    SELECT
        collector,
        collected_at,
        exit_code,
        success,
        CASE
            WHEN success THEN 'ok'
            ELSE 'critical'
        END AS run_status,
        DATEDIFF('minute', collected_at, MAX(collected_at) over ()) / 60.0 AS run_age_hours
    FROM
        {{ ref('stg_meta_pipeline_runs') }}
)
SELECT
    collector,
    collected_at,
    exit_code,
    success,
    run_status,
    run_age_hours,
    CASE
        WHEN run_age_hours < 2 THEN 'ok'
        WHEN run_age_hours < 6 THEN 'warning'
        ELSE 'critical'
    END AS freshness_status
FROM
    base
ORDER BY
    collector,
    collected_at DESC
