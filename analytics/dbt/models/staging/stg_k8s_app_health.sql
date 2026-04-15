{{ config(
    tags = ['staging', 'k8s']
) }}
-- stg_k8s_app_health
-- Normalises raw per-app pod readiness JSON into typed, flat rows.
-- One row per pod per snapshot file.
--
-- Source shape (top-level dict keyed by "namespace/app"):
--   {
--     "namespace/app": [
--       {name, phase, ready, restart_count},
--       ...
--     ],
--     ...
--   }
--
-- Because keys are dynamic (one per deployed app), read_json_auto produces a
-- STRUCT column per app. We serialize the whole row to JSON via struct_pack(*),
-- iterate with json_each, and filter out the filename key to recover app entries.
WITH raw AS (

    SELECT *
    FROM {{ source('source_k8s_app_health', 'snapshots') }}
),

as_json AS (

    SELECT
        r.filename,
        to_json(r) AS row_json
    FROM raw AS r
),

per_app AS (

    SELECT
        a.filename,
        j.key AS app_key,
        j.value :: VARCHAR AS pods_raw
    FROM as_json a, json_each(a.row_json) j
    WHERE j.key != 'filename'
),

per_pod AS (

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
        app_key,
        split_part(app_key, '/', 1) AS namespace,
        split_part(app_key, '/', 2) AS app_name,
        unnest(
            from_json(
                pods_raw,
                '[{"name": "VARCHAR", "phase": "VARCHAR", "ready": "BOOLEAN", "restart_count": "INTEGER"}]'
            )
        ) AS pod
    FROM per_app
)

SELECT
    {{ dbt_utils.generate_surrogate_key(['filename', 'app_key', 'pod.name']) }} AS snapshot_id,
    collected_at_filename,
    namespace,
    app_name,
    pod.name :: VARCHAR AS pod_name,
    pod.phase :: VARCHAR AS pod_phase,
    pod.ready :: BOOLEAN AS pod_ready,
    pod.restart_count :: INTEGER AS restart_count,
FROM per_pod
