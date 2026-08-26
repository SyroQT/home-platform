#!/usr/bin/env bash
# run_dbt.sh — Production dbt runner for incremental staging + mart rebuild.
#
# Strategy:
#   1. Load S3 credentials
#   2. Run staging models incrementally (only new S3 files)
#   3. Run intermediate + marts (full rebuild from staging tables — fast, no S3 reads)
#   4. On failure: DuckDB WAL ensures the file is not corrupted
#
# Usage: ./run_dbt.sh [--full-refresh] [--meta]
#
# --full-refresh: rebuilds all staging tables from scratch. Use after a schema
#                 change or if the DuckDB file is lost. Do NOT use on normal runs.
# --meta:         runs only meta models and their tests; skips staging/intermediate/marts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="/srv/data/analytics/analytics.duckdb"
ENV_FILE="/etc/analytics/host-collector.env"
LOG_PREFIX="[run_dbt]"

# ── Load credentials ──────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "${LOG_PREFIX} ERROR: env file not found at ${ENV_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

export ANALYTICS_S3_ACCESS_KEY="${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID not set in env file}"
export ANALYTICS_S3_SECRET_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY not set in env file}"
export ANALYTICS_S3_BUCKET="${S3_BUCKET:?S3_BUCKET not set in env file}"
export ANALYTICS_S3_ENDPOINT="${S3_ENDPOINT_URL:-https://nbg1.your-objectstorage.com}"
export ANALYTICS_RAW_BASE_PATH="${ANALYTICS_RAW_BASE_PATH:-s3://${ANALYTICS_S3_BUCKET}/analytics/raw}"

# Point dbt at the persistent DuckDB file (no tmp — incremental models require
# a long-lived file; crash safety is provided by DuckDB's WAL)
export DBT_DUCKDB_PATH="$DB_PATH"

# Partial parsing MUST stay off. The rolling-window globs in _sources.yml render
# modules.datetime.date.today() at parse time, and dbt's partial-parse cache does not
# know the result changes daily — a cached manifest freezes the window at the date it
# was parsed. This silently stopped all staging ingestion on 2026-07-30 (stale
# partial_parse.msgpack served a Jul 15–30 window for weeks while runs reported OK).
export DBT_PARTIAL_PARSE=false

# Use the deployed venv and the deployed uv.lock exactly as-is. UV_FROZEN stops uv run
# from re-resolving dependencies (a deploy-time re-resolve is how dbt-core silently
# drifted to 1.12.0); the env default makes manual invocations match the systemd units,
# which set UV_PROJECT_ENVIRONMENT in their unit files.
export UV_PROJECT_ENVIRONMENT="${UV_PROJECT_ENVIRONMENT:-/opt/analytics/venv-dbt}"
export UV_FROZEN=1

cd "$SCRIPT_DIR"

# ── Parse flags ───────────────────────────────────────────────────────────────
FULL_REFRESH=""
META_ONLY=false

for arg in "$@"; do
  case "$arg" in
  --full-refresh)
    FULL_REFRESH="--full-refresh"
    echo "${LOG_PREFIX} WARNING: full-refresh requested — all staging history will be rebuilt from S3"
    ;;
  --meta)
    META_ONLY=true
    echo "${LOG_PREFIX} Meta-only mode — running only tag:meta models"
    ;;
  esac
done

# ── Timing helpers ────────────────────────────────────────────────────────────
# $SECONDS is a bash built-in that counts seconds since the shell started.
# Capture a checkpoint, run a phase, then subtract to get elapsed seconds.
fmt_duration() {
  local secs=$1
  if ((secs < 60)); then
    echo "${secs}s"
  else
    echo "$((secs / 60))m $((secs % 60))s"
  fi
}

TOTAL_START=$SECONDS

# ── Meta-only path ────────────────────────────────────────────────────────────
if [[ "$META_ONLY" == true ]]; then
  PHASE_START=$SECONDS
  echo "${LOG_PREFIX} Running meta models..."
  uv run dbt run \
    --profiles-dir . \
    --target prod \
    --select tag:meta

  echo "${LOG_PREFIX} Running meta tests..."
  uv run dbt test \
    --profiles-dir . \
    --target prod \
    --select tag:meta

  echo "${LOG_PREFIX} Meta run completed in $(fmt_duration $((SECONDS - PHASE_START)))."
  echo "${LOG_PREFIX} Total duration: $(fmt_duration $((SECONDS - TOTAL_START)))."
  exit 0
fi

# ── Step 1: incremental staging ───────────────────────────────────────────────
# Reads only S3 files not yet present in the staging tables.
# With --full-refresh: drops and rebuilds all staging tables from scratch.
PHASE_START=$SECONDS
echo "${LOG_PREFIX} Running staging (incremental)..."
uv run dbt run \
  --profiles-dir . \
  --target prod \
  --select tag:staging \
  --exclude tag:meta \
  $FULL_REFRESH
echo "${LOG_PREFIX} Staging completed in $(fmt_duration $((SECONDS - PHASE_START)))."

# ── Step 2: rebuild intermediate + marts from staging tables ──────────────────
# No S3 reads here — intermediate and marts read from local DuckDB staging tables.
# Always a full rebuild so marts reflect the latest state.
PHASE_START=$SECONDS
echo "${LOG_PREFIX} Running intermediate + marts..."
uv run dbt run \
  --profiles-dir . \
  --target prod \
  --select tag:intermediate tag:mart \
  --exclude tag:meta
echo "${LOG_PREFIX} Intermediate + marts completed in $(fmt_duration $((SECONDS - PHASE_START)))."

# ── Step 3: tests ─────────────────────────────────────────────────────────────
PHASE_START=$SECONDS
echo "${LOG_PREFIX} Running tests..."
uv run dbt test \
  --profiles-dir . \
  --target prod \
  --exclude tag:meta
echo "${LOG_PREFIX} Tests completed in $(fmt_duration $((SECONDS - PHASE_START)))."

echo "${LOG_PREFIX} Done. Total duration: $(fmt_duration $((SECONDS - TOTAL_START)))."
