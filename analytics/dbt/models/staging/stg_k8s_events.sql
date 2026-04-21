{{ config(
    materialized = 'incremental',
    unique_key = 'snapshot_id',
    tags = ['staging', 'k8s']
) }}
-- stg_k8s_events
-- Normalises raw Kubernetes EventList JSON into typed, flat rows.
-- One row per Event object per snapshot file.
--
-- Source shape:
--   kind      "EventList"
--   items[]
--     namespace             string
--     name                  string
--     reason                string
--     type                  "Normal" | "Warning"
--     message               string
--     involved_object       {kind, name, namespace}
--     first_timestamp       ISO timestamp string | null  (legacy events)
--     last_timestamp        ISO timestamp string | null  (legacy events)
--     event_time            ISO timestamp string | null  (new-style events)
--     count                 integer | null
--     reporting_component   string
WITH raw AS (

    SELECT
        *
    FROM
        {{ source(
            'source_k8s_events',
            'snapshots'
        ) }}

{% if is_incremental() %}
WHERE
    filename NOT IN (
        SELECT
            DISTINCT filename
        FROM
            {{ this }}
    )
{% endif %}
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
    FROM
        raw
),
temp AS (
    SELECT
        filename,
        collected_at_filename,
        item.name :: VARCHAR AS event_name,
        item.namespace :: VARCHAR AS namespace,
        item.reason :: VARCHAR AS reason,
        item.type :: VARCHAR AS event_type,
        item.message :: VARCHAR AS message,
        item.involved_object.kind :: VARCHAR AS object_kind,
        item.involved_object.name :: VARCHAR AS object_name,
        item.involved_object.namespace :: VARCHAR AS object_namespace,
        -- Timestamps: new-style events use event_time; legacy events use first/last_timestamp
        item.event_time :: timestamptz AS event_time,
        item.first_timestamp :: timestamptz AS first_timestamp,
        item.last_timestamp :: timestamptz AS last_timestamp,
        item.count :: INTEGER AS event_count,
        item.reporting_component :: VARCHAR AS reporting_component,
    FROM
        unpacked
)
SELECT
    {{ dbt_utils.generate_surrogate_key(['filename', 'namespace', 'event_name']) }} AS snapshot_id,
    collected_at_filename,
    event_name,
    namespace,
    reason,
    event_type,
    event_type = 'Warning' AS is_warning,
    message,
    object_kind,
    object_name,
    object_namespace,
    -- Unified timestamp: prefer event_time (new-style), fall back to last_timestamp (legacy)
    COALESCE(
        event_time,
        last_timestamp,
        first_timestamp
    ) AS occurred_at,
    event_time,
    first_timestamp,
    last_timestamp,
    -- For legacy events, count tracks how many times the event fired; new-style is always 1
    COALESCE(
        event_count,
        1
    ) AS event_count,
    reporting_component,
FROM
    temp
