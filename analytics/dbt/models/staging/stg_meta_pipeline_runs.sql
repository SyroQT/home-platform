{{ config(
    materialized = 'incremental',
    unique_key = 'snapshot_id',
    tags = ['staging', 'meta']
) }}
-- stg_meta_pipeline_runs
-- Normalises collector pipeline run metadata into typed, flat rows.
-- One row per collector run (one JSON file per run).
--
-- Source shape:
--   collected_at   ISO timestamp string
--   collector      string  (e.g. "host", "k8s/workloads")
--   exit_code      integer (0 = success)
--   field_count    integer (ignored here)
WITH raw AS (

    SELECT
        *
    FROM
        {{ source(
            'source_meta',
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
)
SELECT
    {{ dbt_utils.generate_surrogate_key(['filename']) }} AS snapshot_id,
    collected_at :: timestamptz AS collected_at,
    collector :: VARCHAR AS collector,
    exit_code :: INTEGER AS exit_code,
    exit_code = 0 AS success,
FROM
    raw
