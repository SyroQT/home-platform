{{ config(
    tags = ['mart', 'k8s']
) }}
-- mart_k8s_status_history
-- Time-series of pod restarts and warning event counts. One row per pod per snapshot.
-- Used for trend charts.
--
-- Warning events are matched to pods by namespace + object_name where object_kind = 'Pod'.
-- Snapshots from stg_k8s_app_health and stg_k8s_events are joined on collected_at_filename;
-- pods with no matching event snapshot get warning_events = 0.
WITH pods AS (

    SELECT
        collected_at_filename AS collected_at,
        namespace,
        pod_name,
        pod_phase AS phase,
        restart_count
    FROM
        {{ ref('stg_k8s_app_health') }}
),
warning_events AS (
    SELECT
        collected_at_filename,
        namespace,
        object_name AS pod_name,
        COUNT(*) AS warning_count
    FROM
        {{ ref('stg_k8s_events') }}
    WHERE
        is_warning
        AND object_kind = 'Pod'
    GROUP BY
        collected_at_filename,
        namespace,
        object_name
)
SELECT
    p.collected_at,
    p.namespace,
    p.pod_name,
    p.phase,
    p.restart_count,
    COALESCE(
        e.warning_count,
        0
    ) AS warning_events
FROM
    pods p
    LEFT JOIN warning_events e
    ON e.collected_at_filename = p.collected_at
    AND e.namespace = p.namespace
    AND e.pod_name = p.pod_name
ORDER BY
    p.collected_at ASC,
    p.namespace,
    p.pod_name
