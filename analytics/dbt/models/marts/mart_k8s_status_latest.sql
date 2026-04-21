{{ config(
    tags = ['mart', 'k8s']
) }}
-- mart_k8s_status_latest
-- Denormalised current cluster state — one row per node (single node in practice).
-- Joins latest node snapshot with deployment summary, ingress count, and cert expiry summary.
WITH latest_node AS (

    SELECT
        *
    FROM
        {{ ref('stg_k8s_cluster') }}
    WHERE
        collected_at_filename = (
            SELECT
                MAX(collected_at_filename)
            FROM
                {{ ref('stg_k8s_cluster') }}
        )
),
deployment_summary AS (
    SELECT
        COUNT(*) AS total_deployments,
        COUNT(*) FILTER (
            WHERE
                w.ready_replicas = w.desired_replicas
        ) AS ready_deployments
    FROM
        {{ ref('stg_k8s_workloads') }}
        w
    WHERE
        w.workload_kind = 'Deployment'
        AND w.collected_at_filename = (
            SELECT
                MAX(collected_at_filename)
            FROM
                {{ ref('stg_k8s_workloads') }}
        )
),
ingress_summary AS (
    SELECT
        COUNT(*) AS total_ingresses
    FROM
        {{ ref('stg_k8s_ingress') }}
        i
    WHERE
        i.collected_at_filename = (
            SELECT
                MAX(collected_at_filename)
            FROM
                {{ ref('stg_k8s_ingress') }}
        )
),
cert_summary AS (
    SELECT
        COUNT(*) FILTER (
            WHERE
                C.days_until_expiry BETWEEN 0
                AND 30
        ) AS expiring_certs_30d,
        COUNT(*) FILTER (
            WHERE
                C.days_until_expiry < 0
        ) AS expired_certs
    FROM
        {{ ref('stg_k8s_certs') }} C
    WHERE
        C.collected_at_filename = (
            SELECT
                MAX(collected_at_filename)
            FROM
                {{ ref('stg_k8s_certs') }}
        )
)
SELECT
    n.collected_at_filename AS collected_at,
    n.hostname AS node_name,
    n.node_ready,
    CASE
        WHEN n.node_ready THEN 'ok'
        ELSE 'critical'
    END AS node_status,
    n.condition_ready_heartbeat_at AS ready_last_heartbeat,
    DATEDIFF(
        'minute',
        n.condition_ready_heartbeat_at,
        n.collected_at_filename
    ) AS heartbeat_age_minutes,
    n.memory_pressure,
    n.disk_pressure,
    n.pid_pressure,
    n.kubelet_version,
    n.os_image,
    n.allocatable_cpu,
    ROUND(
        n.allocatable_memory_ki / 1024.0 / 1024.0,
        1
    ) AS allocatable_memory_gb,
    COALESCE(
        d.total_deployments,
        0
    ) AS total_deployments,
    COALESCE(
        d.ready_deployments,
        0
    ) AS ready_deployments,
    CASE
        WHEN d.total_deployments IS NULL
        OR d.ready_deployments = d.total_deployments THEN 'ok'
        ELSE 'warning'
    END AS deployments_status,
    COALESCE(
        i.total_ingresses,
        0
    ) AS total_ingresses,
    COALESCE(
        cs.expiring_certs_30d,
        0
    ) AS expiring_certs_30d,
    COALESCE(
        cs.expired_certs,
        0
    ) AS expired_certs,
    CASE
        WHEN cs.expired_certs > 0 THEN 'critical'
        WHEN cs.expiring_certs_30d > 0 THEN 'warning'
        ELSE 'ok'
    END AS certs_status
FROM
    latest_node n
    CROSS JOIN deployment_summary d
    CROSS JOIN ingress_summary i
    CROSS JOIN cert_summary cs
