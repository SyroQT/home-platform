{{ config(enabled = target.name != 'dev') }}
-- Fails (returns rows) if mart_host_status_history has fewer than 14 rows.
-- Disabled on dev — fixtures only contain a single snapshot.
SELECT count(*) AS row_count
FROM {{ ref('mart_host_status_history') }}
HAVING count(*) < 14
