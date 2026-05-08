-- Fails if staging has fewer than 80 rows from the last 24 hours.
-- Collector runs every 15 min = 96 possible rows/day. 80 allows for minor gaps.
SELECT count(*) AS recent_rows
FROM {{ ref('stg_host_snapshots') }}
WHERE collected_at >= now() - INTERVAL '24 hours'
HAVING count(*) < 80
