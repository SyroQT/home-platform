{{ config(
    tags = ['mart', 'k8s']
) }}
-- mart_app_health_latest
-- One row per app — pod readiness, ingress host, cert expiry.
--
-- Join conventions (not enforced in source data):
--   ingress: app_health.app_name = ingress.ingress_name, same namespace
--   cert:    app_health.app_name || '-tls' = certs.cert_name, same namespace
-- Both are left joins — apps without ingress/cert produce NULLs.
WITH latest_app_health AS (

    SELECT
        namespace || '/' || app_name AS app_key,
        namespace,
        app_name AS app,
        collected_at_filename AS collected_at,
        COUNT(*) AS total_pods,
        COUNT(*) FILTER (
            WHERE
                pod_ready
        ) AS ready_pods,
        MAX(restart_count) AS max_restart_count
    FROM
        {{ ref('stg_k8s_app_health') }}
    WHERE
        collected_at_filename = (
            SELECT
                MAX(collected_at_filename)
            FROM
                {{ ref('stg_k8s_app_health') }}
        )
    GROUP BY
        namespace,
        app_name,
        collected_at_filename
),
latest_ingress AS (
    SELECT
        ingress_name,
        namespace,
        rule_host,
        load_balancer_ip
    FROM
        {{ ref('stg_k8s_ingress') }}
    WHERE
        collected_at_filename = (
            SELECT
                MAX(collected_at_filename)
            FROM
                {{ ref('stg_k8s_ingress') }}
        )
),
latest_certs AS (
    SELECT
        cert_name,
        namespace,
        not_after,
        cert_ready,
        days_until_expiry
    FROM
        {{ ref('stg_k8s_certs') }}
    WHERE
        collected_at_filename = (
            SELECT
                MAX(collected_at_filename)
            FROM
                {{ ref('stg_k8s_certs') }}
        )
),
joined AS (
    SELECT
        ah.app_key,
        ah.namespace,
        ah.app,
        ah.collected_at,
        ah.total_pods,
        ah.ready_pods,
        ah.ready_pods = ah.total_pods AS all_pods_ready,
        ah.max_restart_count,
        -- Pod status
        CASE
            WHEN ah.ready_pods = ah.total_pods THEN 'ok'
            ELSE 'critical'
        END AS pod_status,
        -- Restart status
        CASE
            WHEN ah.max_restart_count = 0 THEN 'ok'
            WHEN ah.max_restart_count < 5 THEN 'warning'
            ELSE 'critical'
        END AS restart_status,
        -- Ingress (NULL if no match)
        i.rule_host AS ingress_host,
        i.load_balancer_ip AS ingress_load_balancer_ip,
        -- Cert (NULL if no match)
        C.not_after AS cert_not_after,
        C.cert_ready,
        C.days_until_expiry :: INTEGER AS cert_days_remaining,
        CASE
            WHEN C.cert_name IS NULL THEN NULL
            WHEN C.days_until_expiry < 14 THEN 'critical'
            WHEN C.days_until_expiry < 30 THEN 'warning'
            ELSE 'ok'
        END AS cert_status
    FROM
        latest_app_health ah
        LEFT JOIN latest_ingress i
        ON i.ingress_name = ah.app
        AND i.namespace = ah.namespace
        LEFT JOIN latest_certs C
        ON C.cert_name = ah.app || '-tls'
        AND C.namespace = ah.namespace
)
SELECT
    app_key,
    namespace,
    app,
    collected_at,
    total_pods,
    ready_pods,
    all_pods_ready,
    max_restart_count,
    restart_status,
    pod_status,
    ingress_host,
    ingress_load_balancer_ip,
    cert_not_after,
    cert_ready,
    cert_days_remaining,
    cert_status,
    -- overall_status: worst of pod_status, restart_status, cert_status (NULL cert excluded)
    CASE
        WHEN pod_status = 'critical'
        OR restart_status = 'critical'
        OR cert_status = 'critical' THEN 'critical'
        WHEN pod_status = 'warning'
        OR restart_status = 'warning'
        OR cert_status = 'warning' THEN 'warning'
        ELSE 'ok'
    END AS overall_status
FROM
    joined
ORDER BY
    namespace,
    app
