#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# reset-training.sh
# Installed by provision-training.yml as a daily cron at 03:00 AM.
# Restores the training DB from the seed snapshot and flushes Redis.
# Logs to /var/log/haiggle-training-reset.log
#
# This script runs INSIDE the training VPS (not from the Ansible ops machine).
# It calls docker directly to avoid needing Ansible locally.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_DIR="/srv/haiggle"
SNAPSHOT="${APP_DIR}/snapshots/training-seed.sql"
DB_NAME="haiggle_training"
TIMESTAMP=$(date -Iseconds)

log() { echo "[${TIMESTAMP}] $*"; }

log "=== Training reset started ==="

# ── Verify snapshot exists ────────────────────────────────────────────────────
if [[ ! -f "$SNAPSHOT" ]]; then
  log "ERROR: Snapshot ${SNAPSHOT} not found. Aborting reset."
  exit 1
fi

# ── Load .env to get DB/Redis credentials ─────────────────────────────────────
# shellcheck disable=SC1091
set -a
source "${APP_DIR}/.env"
set +a

log "Terminating active DB connections..."
docker exec haiggle-db psql -U haiggle -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" \
  > /dev/null

log "Dropping and recreating database..."
docker exec haiggle-db psql -U haiggle -d postgres -c \
  "DROP DATABASE IF EXISTS ${DB_NAME};" > /dev/null
docker exec haiggle-db psql -U haiggle -d postgres -c \
  "CREATE DATABASE ${DB_NAME};" > /dev/null

log "Restoring from snapshot..."
docker exec -i haiggle-db psql -U haiggle -d "${DB_NAME}" < "$SNAPSHOT"

log "Flushing Redis..."
docker exec haiggle-redis redis-cli -a "${REDIS_PASSWORD}" FLUSHALL > /dev/null

log "Restarting app containers..."
docker restart haiggle-app haiggle-queue haiggle-scheduler

log "Waiting for health check..."
for i in $(seq 1 12); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "https://${APP_URL#https://}/api/health" || true)
  if [[ "$HTTP" == "200" ]]; then
    log "Health check OK (attempt ${i})"
    break
  fi
  if [[ $i -eq 12 ]]; then
    log "ERROR: Health check failed after ${i} attempts (last status: ${HTTP})"
    exit 1
  fi
  sleep 5
done

# Write last-reset timestamp (readable by /api/health or monitoring)
echo "$TIMESTAMP" > "${APP_DIR}/snapshots/last-reset.txt"

log "=== Training reset complete ==="
