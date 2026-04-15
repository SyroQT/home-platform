{{ config(
    tags = ['mart', 'host']
) }}
-- mart_host_status_history
-- Most recent host snapshot. Business logic lives in int_host_snapshots_enriched.

SELECT
    *
FROM
    {{ ref('int_host_snapshots_enriched') }}
ORDER BY
    collected_at DESC
LIMIT
    1
