# Ghiath - Personal Agentic Ecosystem
#
# Common operations. Run `make` or `make help` for the list.

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help bootstrap up addon deploy down restart ps logs couch-init test secrets sync-env agents pull update clean reinstall hermes-info seed-cron

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

bootstrap: ## First-run local setup: secrets + up + wait + couch-init
	@./scripts/bootstrap.sh local

up: ## Start the local stack (no Caddy, no n8n)
	@docker compose up -d

addon: ## Start the optional n8n add-on alongside the stack
	@docker compose --profile addon up -d

deploy: ## Start the production stack (adds Caddy). Fill .env prod values first.
	@./scripts/bootstrap.sh prod

down: ## Stop and remove containers (keeps data volumes)
	@docker compose --profile prod --profile addon down

restart: ## Restart the local stack
	@docker compose restart

ps: ## Show service status
	@docker compose ps

logs: ## Tail logs for all services (S=servicename to narrow)
	@docker compose logs -f $(S)

couch-init: ## (Re)apply CouchDB config for Obsidian LiveSync
	@./scripts/couch-init.sh

test: ## Smoke-test every running service
	@./scripts/smoke-test.sh

sync-env: ## Project agents.conf into .env + livesync-bridge config
	@./scripts/sync-env.sh --write

agents: ## (Re)provision the two hermes agents - safe, keeps sessions + Telegram (K=keirouter-key)
	@./scripts/hermes.sh $(K)

secrets: ## Print fresh random secrets you can paste into .env
	@echo "KEIROUTER_MASTER_KEY=$$(openssl rand -base64 32)"
	@echo "N8N_ENCRYPTION_KEY=$$(openssl rand -hex 24)"
	@echo "COUCHDB_PASSWORD=$$(openssl rand -hex 16)"
	@echo "# basic_auth hash:"
	@echo "#   docker run --rm caddy:2 caddy hash-password --plaintext 'yourpass'"

pull: ## Pull latest images
	@docker compose pull

update: pull ## Pull latest images and recreate (N8N_ENCRYPTION_KEY must stay stable)
	@docker compose up -d

clean: ## DANGER: stop and delete all containers AND data volumes
	@echo "This deletes caddy cert volumes and stops everything."
	@echo "Bind-mounted data (couchdb/, qdrant/, n8n/, the vaults) is NOT touched."
	@docker compose --profile prod --profile addon down -v

reinstall: ## Force reinstall: pick a reset level, rebuild stack + reprovision agents (K=keirouter-key)
	@./scripts/force-reinstall.sh $(K)

hermes-info: ## Show hermes profiles and their models (host-level)
	@hermes profile list 2>/dev/null || echo "hermes not installed or not on PATH"

seed-cron: ## Copy hermes cron tick scripts to ~/.hermes/scripts/ (safe; not hermes.sh)
	@./scripts/seed-cron.sh
