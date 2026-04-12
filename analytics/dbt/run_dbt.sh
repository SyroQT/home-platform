#!/usr/bin/env bash
# run_dbt.sh — Production dbt runner with atomic DuckDB swap.
#
# Strategy (Decision 3 from handoff):
#   1. Load S3 credentials from /etc/analytics/host-collector.env
#   2. Run `dbt build` writing to a .tmp DuckDB file
#   3. On success: atomically mv .tmp → .duckdb
#   4. On failure: leave the last good .duckdb in place untouched
#
# Usage: ./run_dbt.sh [extra dbt args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="/srv/data/analytics/analytics.duckdb"
DB_TMP="${DB_PATH}.tmp"
ENV_FILE="/etc/analytics/host-collector.env"
LOG_PREFIX="[run_dbt]"

# ── Load credentials ──────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "${LOG_PREFIX} ERROR: env file not found at ${ENV_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# Export vars dbt_project.yml reads via env_var()
export ANALYTICS_S3_ACCESS_KEY="${S3_ACCESS_KEY_ID:?S3_ACCESS_KEY_ID not set in env file}"
export ANALYTICS_S3_SECRET_KEY="${S3_SECRET_ACCESS_KEY:?S3_SECRET_ACCESS_KEY not set in env file}"
export ANALYTICS_S3_BUCKET="${S3_BUCKET:?S3_BUCKET not set in env file}"
export ANALYTICS_S3_ENDPOINT="${S3_ENDPOINT:-https://nbg1.your-objectstorage.com}"

# ── Point dbt at the tmp file ─────────────────────────────────────────────────
# Override the path via DBT_DUCKDB_PATH env var — profiles.yml reads this
# if you template it, or we pass --vars to override path at runtime.
# Simplest: override via a prod-tmp profile section, or use a wrapper var.
# Here we use a separate profiles.yml setting via environment substitution.
export DBT_DUCKDB_PATH="$DB_TMP"

# Clean up any stale tmp file from a previous failed run
rm -f "$DB_TMP"

echo "${LOG_PREFIX} Starting dbt build (tmp: ${DB_TMP})"

# ── Run dbt ───────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
if dbt build --profiles-dir . --target prod "$@"; then
  echo "${LOG_PREFIX} dbt build succeeded — swapping into place"
  mv "$DB_TMP" "$DB_PATH"
  echo "${LOG_PREFIX} Done. DB updated at ${DB_PATH}"
else
  EXIT_CODE=$?
  echo "${LOG_PREFIX} ERROR: dbt build failed (exit ${EXIT_CODE}) — leaving ${DB_PATH} untouched" >&2
  rm -f "$DB_TMP"
  exit $EXIT_CODE
fi