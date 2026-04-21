-- Fails (returns rows) if mart_k8s_status_latest has more or fewer than 1 row.
SELECT count(*) AS row_count
FROM {{ ref('mart_k8s_status_latest') }}
HAVING count(*) != 1
