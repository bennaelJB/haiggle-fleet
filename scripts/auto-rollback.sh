#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# auto-rollback.sh
# Run as a cron on the monitoring server every 5 minutes.
# Reads the `deploy:failed` Redis set and triggers rollback playbook for each
# failed school, then removes the school from the set.
#
# Required env vars:
#   MONITORING_REDIS_HOST  — hostname of the central monitoring Redis instance
#   ANSIBLE_INVENTORY      — path to the fleet inventory file
#   ANSIBLE_VAULT_PASS     — path to the Ansible vault password file
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REDIS_HOST="${MONITORING_REDIS_HOST:-127.0.0.1}"
INVENTORY="${ANSIBLE_INVENTORY:-/opt/haiggle-fleet/inventory/schools.yml}"
VAULT_PASS="${ANSIBLE_VAULT_PASS:-/opt/haiggle-fleet/.vault-pass}"
FLEET_DIR="$(dirname "$(dirname "$(realpath "$0")")")"

log() { echo "[$(date -Iseconds)] $*"; }

# Fetch all school names in the failed set
failed_schools=$(redis-cli -h "$REDIS_HOST" SMEMBERS deploy:failed 2>/dev/null || true)

if [ -z "$failed_schools" ]; then
    log "No failed deployments detected."
    exit 0
fi

for school in $failed_schools; do
    log "Auto-rollback triggered for: $school"

    # Determine the last known good version from the deployed-version file on the host.
    # The playbook reads the current .deployed-version on the host to get the rollback tag.
    ansible-playbook \
        -i "$INVENTORY" \
        --vault-password-file "$VAULT_PASS" \
        --limit "$school" \
        -e "version=$(ssh deploy@"$school" cat /srv/haiggle/.deployed-version 2>/dev/null || echo 'latest')" \
        "$FLEET_DIR/playbooks/rollback.yml" \
        && {
            log "Rollback succeeded for $school — removing from failed set"
            redis-cli -h "$REDIS_HOST" SREM deploy:failed "$school"
        } || {
            log "ERROR: Rollback FAILED for $school — leaving in failed set for manual intervention"
        }
done
