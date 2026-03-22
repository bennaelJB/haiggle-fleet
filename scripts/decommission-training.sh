#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# decommission-training.sh
# Run as a daily cron on the monitoring server.
# Reads inventory/training-instances.yml, calculates age in days, and runs
# the decommission playbook for any temporary training instance older than 14 days.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

FLEET_DIR="$(dirname "$(dirname "$(realpath "$0")")")"
INVENTORY="$FLEET_DIR/inventory/training-instances.yml"
TTL_DAYS="${TTL_DAYS:-14}"

log() { echo "[$(date -Iseconds)] $*"; }

# Parse created_at timestamps using python3 (available on monitoring server)
python3 - <<EOF
import yaml, subprocess, datetime, sys, os

with open("$INVENTORY") as f:
    inv = yaml.safe_load(f) or {}

hosts = inv.get('all', {}).get('hosts', {}) or {}
today = datetime.datetime.now(datetime.timezone.utc)
ttl = int(os.environ.get('TTL_DAYS', $TTL_DAYS))

for host, cfg in hosts.items():
    created_at_str = (cfg or {}).get('created_at', '')
    if not created_at_str:
        print(f"[SKIP] {host}: no created_at — skipping", flush=True)
        continue

    try:
        created_at = datetime.datetime.fromisoformat(created_at_str.replace('Z', '+00:00'))
        age_days = (today - created_at).days
        if age_days >= ttl:
            print(f"[DECOMMISSION] {host}: age={age_days}d >= ttl={ttl}d", flush=True)
            result = subprocess.run([
                'ansible-playbook',
                '-i', "$INVENTORY",
                '--vault-password-file', '$FLEET_DIR/.vault-pass',
                '--limit', host,
                '-e', f"school={host}",
                '$FLEET_DIR/playbooks/decommission.yml',
            ], capture_output=True, text=True)
            if result.returncode == 0:
                print(f"[OK] {host} decommissioned", flush=True)
            else:
                print(f"[ERROR] {host} decommission failed:\n{result.stderr}", flush=True)
        else:
            print(f"[OK] {host}: age={age_days}d — within TTL", flush=True)
    except ValueError as e:
        print(f"[SKIP] {host}: invalid created_at format: {e}", flush=True)
EOF
