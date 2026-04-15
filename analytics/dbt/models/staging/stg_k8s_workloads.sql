{{ config(
    tags = ['staging', 'k8s']
) }}
-- stg_k8s_workloads
-- Normalises raw Kubernetes WorkloadList JSON into typed, flat rows.
-- One row per workload (Deployment / StatefulSet / DaemonSet) per snapshot file.
--
-- Source shape:
--   kind      "WorkloadList"
--   items[]
--     kind              "Deployment" | "StatefulSet" | "DaemonSet"
--     name              string
--     namespace         string
--     labels            struct of label key→value strings
--     replicas          integer  (desired)
--     strategy          string   (RollingUpdate | Recreate)
--     status
--       replicas            integer
--       ready_replicas      integer
--       available_replicas  integer
--       conditions[]        [{type, status, reason, message, lastTransitionTime, lastUpdateTime}]
WITH raw AS (

    SELECT *
    FROM {{ source('source_k8s_workloads', 'snapshots') }}
),

unpacked AS (

    SELECT
        filename,
        try_strptime(
            REGEXP_REPLACE(
                REGEXP_REPLACE(REGEXP_REPLACE(filename, '^.*/', ''), '\.json$', ''),
                '-(\d{2})-(\d{2})$',
                '+\1:\2'
            ),
            '%Y-%m-%dT%H-%M-%S.%f%z'
        ) AS collected_at_filename,
        unnest(items) AS item
    FROM raw
),

temp AS (

    SELECT
        filename,
        collected_at_filename,
        item.kind :: VARCHAR AS workload_kind,
        item.name :: VARCHAR AS workload_name,
        item.namespace :: VARCHAR AS namespace,
        item.replicas :: INTEGER AS desired_replicas,
        item.strategy :: VARCHAR AS update_strategy,
        item.status.replicas :: INTEGER AS current_replicas,
        item.status.ready_replicas :: INTEGER AS ready_replicas,
        item.status.available_replicas :: INTEGER AS available_replicas,
        -- Conditions
        list_filter(item.status.conditions, x -> x.type = 'Available')[1].status :: VARCHAR AS condition_available_status,
        list_filter(item.status.conditions, x -> x.type = 'Progressing')[1].status :: VARCHAR AS condition_progressing_status,
        list_filter(item.status.conditions, x -> x.type = 'Available')[1].lastTransitionTime :: TIMESTAMPTZ AS available_since,
    FROM unpacked
)

SELECT
    {{ dbt_utils.generate_surrogate_key(['filename', 'namespace', 'workload_kind', 'workload_name']) }} AS snapshot_id,
    collected_at_filename,
    workload_kind,
    workload_name,
    namespace,
    update_strategy,
    desired_replicas,
    current_replicas,
    ready_replicas,
    available_replicas,
    COALESCE(condition_available_status = 'True', FALSE) AS available,
    COALESCE(condition_progressing_status = 'True', FALSE) AS progressing,
    available_since,
    -- Derived: fully healthy when all desired replicas are ready and available
    desired_replicas > 0
        AND ready_replicas = desired_replicas
        AND available_replicas = desired_replicas AS fully_available,
FROM temp
