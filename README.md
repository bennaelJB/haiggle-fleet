# haiggle-fleet

Ansible-based fleet management for Haiggle school deployments.
Manages provisioning, zero-downtime deploys, rollbacks, and monitoring across all school VPS instances.

---

## Repository structure

```
haiggle-fleet/
├── inventory/
│   ├── schools.yml            # All school hosts (canary + production groups)
│   ├── staging.yml            # Staging instance
│   └── training-instances.yml # Temporary training instances (auto-decommissioned)
├── playbooks/
│   ├── provision.yml          # Full VPS provisioning (Docker, Nginx, SSL, app)
│   ├── deploy.yml             # Blue-green zero-downtime deploy
│   ├── rollback.yml           # Roll back to a previous version
│   ├── migrate.yml            # Run migrations only (no restart)
│   ├── health-check.yml       # Poll /health and report to Redis
│   ├── sync-ssh-keys.yml      # Sync GitHub team SSH keys to VPSes
│   ├── decommission.yml       # Remove a school instance (destructive)
│   └── provision-training.yml # Provision temporary training instance
├── roles/
│   ├── docker/                # Docker Engine + Compose plugin
│   ├── nginx/                 # Nginx + Let's Encrypt (Certbot)
│   ├── haiggle-app/           # App directory, .env, migrations, storage link
│   └── monitoring/            # node-exporter, Prometheus registration, auto-rollback cron
├── templates/
│   ├── docker-compose.prod.yml.j2
│   ├── .env.j2
│   └── nginx.conf.j2
├── scripts/
│   ├── monitor-canary.py      # Polls Prometheus during canary window
│   ├── auto-rollback.sh       # Reads Redis deploy:failed set, triggers rollback
│   └── decommission-training.sh # Auto-decommissions training instances > 14 days
├── .github/
│   └── workflows/
│       └── fleet-deploy.yml   # 3-stage CI/CD: canary → approval → fleet
└── Makefile                   # Shorthand for all common operations
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| Ansible | `pip install ansible` (≥ 2.15) |
| Ansible Galaxy collections | `ansible-galaxy collection install community.docker community.general` |
| Vault password | `.vault-pass` file in repo root (gitignored) |
| SSH key | `~/.ssh/id_ed25519` with access to all VPS hosts |
| Python 3.10+ | For `scripts/monitor-canary.py` |

---

## Secrets & vault

All sensitive variables (DB passwords, GHCR token, APP_KEY, etc.) are stored in Ansible Vault.

```bash
# Edit vault-encrypted group_vars
ansible-vault edit group_vars/all/vault.yml

# View a single encrypted value
ansible-vault view group_vars/all/vault.yml
```

The vault password file must exist at `.vault-pass` (chmod 600) before running any playbook.
This file is in `.gitignore` and must never be committed.

---

## Common operations (Makefile)

```bash
# Deploy to all production schools
make deploy tag=v1.5.0

# Canary-only deploy (then monitor manually)
make deploy-canary tag=v1.5.0

# Deploy to a single school
make deploy-school school=ccf tag=v1.5.0

# Deploy to staging
make deploy-staging tag=main-abc1234

# Run fleet health check
make health

# Rollback full fleet to a previous version
make rollback version=v1.4.2

# Rollback a single school
make rollback-school school=ccf version=v1.4.2

# Provision a new school VPS
make provision school=ccf tag=v1.5.0

# Provision a temporary training instance
make provision-training school=ccf

# Run migrations only (no container restart)
make migrate tag=v1.5.0

# Sync SSH keys from GitHub team
make sync-keys

# Decommission a school instance (DESTRUCTIVE)
make decommission school=ccf
```

---

## Standard deploy workflow

### 1. Release from the main Haiggle repo

When a `v*.*.*` tag is pushed to the main Haiggle repo, the release workflow:
1. Builds and pushes the Docker image to GHCR as `ghcr.io/org/haiggle-app:vX.Y.Z`
2. Dispatches a `repository_dispatch` event to this fleet repo

### 2. Automated fleet-deploy pipeline (`.github/workflows/fleet-deploy.yml`)

```
Stage 1 — Canary deploy
  └─ Deploy to canary schools (--limit canary)
  └─ Notify Slack
  └─ Monitor Prometheus error rate for 30 minutes
      (exits non-zero → pipeline fails, full fleet not updated)

Stage 2 — Manual approval gate
  └─ GitHub Environment "production" requires reviewer approval

Stage 3 — Full fleet deploy
  └─ ansible-playbook with --limit production, serial=5
  └─ Post-deploy health check
  └─ Slack notification
```

### 3. Skip canary (hotfixes only)

For emergency hotfixes, trigger `workflow_dispatch` with `skip_canary: true`.
This bypasses the 30-minute Prometheus monitoring window.

---

## Zero-downtime deploy (blue-green)

`playbooks/deploy.yml` uses a blue-green strategy on each host:

1. Pull new image (`haiggle-app:{{ image_tag }}`)
2. Start `haiggle-app-next` container (new version) on a temporary port
3. Run migrations inside `haiggle-app-next`
4. Health-check `haiggle-app-next` (`/health` → HTTP 200)
5. Update Nginx upstream to point to `haiggle-app-next`
6. Reload Nginx (zero connection drops)
7. Stop and remove old `haiggle-app` container
8. Rename `haiggle-app-next` → `haiggle-app`
9. Write new version to `/srv/haiggle/.deployed-version`

If any step fails, the `rescue` block restores the Nginx upstream to the old container and removes `haiggle-app-next`.

---

## Rollback

Rollback does **not** run migrations (to avoid destructive down migrations).

```bash
# Roll back the entire fleet to v1.4.2
make rollback version=v1.4.2

# Roll back a single school
make rollback-school school=ccf version=v1.4.2
```

The target image must already exist in GHCR. The playbook:
1. Pulls `haiggle-app:{{ version }}`
2. Starts the rollback container
3. Swaps Nginx upstream
4. Removes the failed container

---

## Automatic rollback

`scripts/auto-rollback.sh` runs as a cron job on the monitoring server every 5 minutes.

It reads the `deploy:failed` Redis set (populated by `playbooks/health-check.yml` when a
school's `/health` endpoint returns non-200 three times in a row) and triggers `rollback.yml`
for each failed school.

After a successful rollback, the school is removed from the `deploy:failed` set.
If rollback also fails, the school remains in the set for manual intervention.

---

## Provisioning a new school

```bash
# 1. Add the school to inventory/schools.yml under the correct group
#    (canary or production) with all required host_vars.

# 2. Add school host_vars file
#    inventory/host_vars/<school>.yml (ansible-vault encrypted)

# 3. Provision the VPS
make provision school=<school_id> tag=v1.5.0

# The provision playbook:
#   - Installs Docker (roles/docker)
#   - Sets up Nginx + SSL (roles/nginx)
#   - Deploys app, runs migrations, storage link (roles/haiggle-app)
#   - Registers with monitoring server (roles/monitoring)
#   - Registers school with HMP licensing server
```

---

## Training instances

Temporary training VPSes are provisioned via:

```bash
make provision-training school=ccf
```

They are automatically decommissioned after 14 days by `scripts/decommission-training.sh`,
which runs as a daily cron on the monitoring server.

To override the TTL: `TTL_DAYS=7 /path/to/decommission-training.sh`

---

## Monitoring

- **Node exporter** runs on port `9100` on every school VPS (inside Docker Compose)
- **Prometheus** on the monitoring server scrapes all hosts via file-based service discovery
- **Grafana** dashboards: fleet overview, per-school error rates, response times, container health
- **Alertmanager** routes alerts to the `#ops-alerts` Slack channel

Key Prometheus metrics:
- `http_requests_total{deploy_group="canary", status=~"5.."}` — canary error rate
- `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes` — host health
- `haiggle_queue_depth` — queue backlog

---

## SSH key management

```bash
# Sync GitHub team keys to all school VPSes
make sync-keys
```

`playbooks/sync-ssh-keys.yml` fetches all public keys from the configured GitHub org team
and writes them exclusively to `~deploy/.ssh/authorized_keys` on every host.
Removing someone from the GitHub team revokes their VPS access on the next `sync-keys` run.

---

## Secrets required (GitHub Actions)

| Secret | Used by |
|---|---|
| `ANSIBLE_VAULT_PASSWORD` | Decrypt group_vars vault |
| `DEPLOY_SSH_KEY` | SSH into school VPSes |
| `SLACK_BOT_TOKEN` | Slack deployment notifications |
| `SLACK_CHANNEL_OPS` | Slack channel ID |
| `PROMETHEUS_URL` | Canary monitoring script |
| `PROMETHEUS_TOKEN` | Prometheus bearer auth |
| `GHCR_TOKEN` | Pull images from GHCR |
