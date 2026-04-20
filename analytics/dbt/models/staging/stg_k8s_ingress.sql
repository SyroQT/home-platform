{{ config(
    materialized = 'incremental',
    unique_key = 'snapshot_id',
    tags = ['staging', 'k8s']
) }}
-- stg_k8s_ingress
-- Normalises raw Kubernetes IngressList JSON into typed, flat rows.
-- One row per Ingress object per snapshot file.
--
-- Source shape:
--   kind      "IngressList"
--   items[]
--     name              string
--     namespace         string
--     ingress_class     string
--     rules[]           [{host: string}]
--     tls[]             [{hosts: [string], secret_name: string}]
--     load_balancer_ips [string]
WITH raw AS (

    SELECT
        *
    FROM
        {{ source(
            'source_k8s_ingress',
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
        item.name :: VARCHAR AS ingress_name,
        item.namespace :: VARCHAR AS namespace,
        item.ingress_class :: VARCHAR AS ingress_class,
        -- Rules and TLS: one host/secret per ingress in practice; take first entry
        list_extract(
            item.rules,
            1
        ).host :: VARCHAR AS rule_host,
        list_extract(
            item.tls,
            1
        ).secret_name :: VARCHAR AS tls_secret_name,
        list_extract(
            item.load_balancer_ips,
            1
        ) :: VARCHAR AS load_balancer_ip,
    FROM
        unpacked
)
SELECT
    {{ dbt_utils.generate_surrogate_key(['filename', 'namespace', 'ingress_name']) }} AS snapshot_id,
    collected_at_filename,
    ingress_name,
    namespace,
    ingress_class,
    rule_host,
    tls_secret_name,
    tls_secret_name IS NOT NULL AS tls_enabled,
    load_balancer_ip,
FROM
    temp
