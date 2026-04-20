{{ config(
    materialized = 'incremental',
    unique_key = 'snapshot_id',
    tags = ['staging', 'k8s']
) }}
-- stg_k8s_certs
-- Normalises raw cert-manager CertificateList JSON into typed, flat rows.
-- One row per Certificate object per snapshot file.
--
-- Source shape:
--   kind      "CertificateList"
--   items[]
--     name          string
--     namespace     string
--     dns_names     [string]
--     common_name   string | null
--     issuer_ref    {group, kind, name}
--     not_after     ISO timestamp string
--     not_before    ISO timestamp string
--     renewal_time  ISO timestamp string
--     conditions[]  [{type, status, reason, message, lastTransitionTime, observedGeneration}]
WITH raw AS (

    SELECT
        *
    FROM
        {{ source(
            'source_k8s_certs',
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
        item.name :: VARCHAR AS cert_name,
        item.namespace :: VARCHAR AS namespace,
        item.common_name :: VARCHAR AS common_name,
        -- Primary DNS name is the first in the list; keep full list for reference
        list_extract(
            item.dns_names,
            1
        ) :: VARCHAR AS primary_dns_name,
        len(
            item.dns_names
        ) AS dns_name_count,
        -- Issuer
        item.issuer_ref.kind :: VARCHAR AS issuer_kind,
        item.issuer_ref.name :: VARCHAR AS issuer_name,
        -- Validity window
        item.not_before :: timestamptz AS not_before,
        item.not_after :: timestamptz AS not_after,
        item.renewal_time :: timestamptz AS renewal_time,
        -- Ready condition
        list_filter(
            item.conditions,
            x -> x.type = 'Ready'
        ) [1].status :: VARCHAR AS condition_ready_status,
        list_filter(
            item.conditions,
            x -> x.type = 'Ready'
        ) [1].lastTransitionTime :: timestamptz AS ready_since,
        list_filter(
            item.conditions,
            x -> x.type = 'Ready'
        ) [1].message :: VARCHAR AS ready_message,
    FROM
        unpacked
)
SELECT
    {{ dbt_utils.generate_surrogate_key(['filename', 'namespace', 'cert_name']) }} AS snapshot_id,
    collected_at_filename,
    cert_name,
    namespace,
    common_name,
    primary_dns_name,
    dns_name_count,
    issuer_kind,
    issuer_name,
    not_before,
    not_after,
    renewal_time,
    COALESCE(
        condition_ready_status = 'True',
        FALSE
    ) AS cert_ready,
    ready_since,
    ready_message,
    -- Days remaining until expiry at collection time (NULL if collected_at_filename is NULL)
    DATEDIFF(
        'day',
        collected_at_filename,
        not_after
    ) AS days_until_expiry,
    -- Whether the cert is within its renewal window
    collected_at_filename IS NOT NULL
    AND collected_at_filename >= renewal_time AS renewal_due,
FROM
    temp
