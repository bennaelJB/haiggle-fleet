# Haiggle Fleet — Makefile
# Shorthand for common Ansible and operational tasks.

ANSIBLE_FLAGS ?= --vault-password-file .vault-pass

# ── Deployment ────────────────────────────────────────────────────────────────
deploy: ## Deploy a specific image tag to the full fleet
	@test -n "$(tag)" || (echo "Usage: make deploy tag=v1.5.0"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		-e "image_tag=$(tag)" \
		playbooks/deploy.yml

deploy-canary: ## Deploy to canary group only
	@test -n "$(tag)" || (echo "Usage: make deploy-canary tag=v1.5.0"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		--limit canary \
		-e "image_tag=$(tag)" \
		playbooks/deploy.yml

deploy-school: ## Deploy to a single school (make deploy-school school=ccf tag=v1.5.0)
	@test -n "$(school)" || (echo "Usage: make deploy-school school=ccf tag=v1.5.0"; exit 1)
	@test -n "$(tag)" || (echo "Usage: make deploy-school school=ccf tag=v1.5.0"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		--limit $(school) \
		-e "image_tag=$(tag)" \
		playbooks/deploy.yml

deploy-staging: ## Deploy to staging only
	@test -n "$(tag)" || (echo "Usage: make deploy-staging tag=main-abc1234"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/staging.yml \
		-e "image_tag=$(tag)" \
		playbooks/deploy.yml

# ── Rollback ──────────────────────────────────────────────────────────────────
rollback: ## Rollback the full fleet to a previous version (make rollback version=v1.4.2)
	@test -n "$(version)" || (echo "Usage: make rollback version=v1.4.2"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		-e "version=$(version)" \
		playbooks/rollback.yml

rollback-school: ## Rollback a single school (make rollback-school school=ccf version=v1.4.2)
	@test -n "$(school)" || (echo "Usage: make rollback-school school=ccf version=v1.4.2"; exit 1)
	@test -n "$(version)" || (echo "Usage: make rollback-school school=ccf version=v1.4.2"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		--limit $(school) \
		-e "version=$(version)" \
		playbooks/rollback.yml

# ── Provisioning ──────────────────────────────────────────────────────────────
provision: ## Provision a new school VPS (make provision school=ccf tag=v1.5.0)
	@test -n "$(school)" || (echo "Usage: make provision school=ccf tag=v1.5.0"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		--limit $(school) \
		-e "image_tag=$(tag)" \
		playbooks/provision.yml

provision-training: ## Provision the permanent training instance (training.haiggle.com)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/training.yml \
		playbooks/provision-training.yml

deploy-training: ## Deploy a new image to the training instance (make deploy-training tag=v1.5.0)
	@test -n "$(tag)" || (echo "Usage: make deploy-training tag=v1.5.0"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/training.yml \
		-e "image_tag=$(tag)" \
		playbooks/deploy.yml

reset-training: ## Restore training DB to seeded baseline and flush Redis
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/training.yml \
		playbooks/reset-training.yml

decommission: ## Decommission a school instance (DESTRUCTIVE — confirm required)
	@test -n "$(school)" || (echo "Usage: make decommission school=ccf"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		--limit $(school) \
		-e "school=$(school)" \
		playbooks/decommission.yml

# ── Maintenance ───────────────────────────────────────────────────────────────
health: ## Run health check across all production schools
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		playbooks/health-check.yml

migrate: ## Run migrations only without restarting the app (make migrate tag=v1.5.0)
	@test -n "$(tag)" || (echo "Usage: make migrate tag=v1.5.0"; exit 1)
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		-e "image_tag=$(tag)" \
		playbooks/migrate.yml

sync-keys: ## Sync GitHub team SSH keys to all school VPSes
	ansible-playbook $(ANSIBLE_FLAGS) -i inventory/schools.yml \
		playbooks/sync-ssh-keys.yml

# ── Testing (Molecule / Docker) ───────────────────────────────────────────────
test: ## Run full Molecule test cycle (create → converge → verify → destroy)
	molecule test

test-converge: ## Run roles against test containers without destroying them
	molecule converge

test-verify: ## Run verify assertions against running test containers
	molecule verify

test-login: ## Open a shell inside the running test container
	molecule login

test-destroy: ## Tear down Molecule test containers
	molecule destroy

lint: ## Lint all playbooks and roles with ansible-lint
	ansible-lint

# ── Help ──────────────────────────────────────────────────────────────────────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.PHONY: deploy deploy-canary deploy-school deploy-staging rollback rollback-school \
        provision provision-training deploy-training reset-training decommission \
        health migrate sync-keys \
        test test-converge test-verify test-login test-destroy lint help
.DEFAULT_GOAL := help
