SHELL := /bin/bash
COMPOSE ?= docker compose
MIGRATE ?= $(COMPOSE) --profile tools run --rm --user $$(id -u):$$(id -g) migrate

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.env:
	cp .env.example .env

.PHONY: up
up: .env ## Start PostgreSQL, Redis and MinIO
	$(COMPOSE) up -d postgres redis minio minio-init

.PHONY: down
down: ## Stop local infrastructure (keeps volumes)
	$(COMPOSE) down

.PHONY: clean
clean: ## Stop local infrastructure and delete volumes
	$(COMPOSE) down -v

.PHONY: logs
logs: ## Tail logs from local infrastructure
	$(COMPOSE) logs -f --tail=100

.PHONY: ps
ps: ## Show infrastructure container status
	$(COMPOSE) ps

.PHONY: migrate-up
migrate-up: ## Apply all pending migrations
	$(MIGRATE) up

.PHONY: migrate-down
migrate-down: ## Roll back one migration
	$(MIGRATE) down 1

.PHONY: migrate-version
migrate-version: ## Print the current migration version
	$(MIGRATE) version

.PHONY: migrate-create
migrate-create: ## Create a migration: make migrate-create name=add_reactions
	@test -n "$(name)" || (echo "usage: make migrate-create name=<migration_name>" && exit 1)
	$(MIGRATE) create -ext sql -dir /migrations -seq $(name)

.PHONY: psql
psql: ## Open a psql shell on the local database
	$(COMPOSE) exec postgres psql -U $${POSTGRES_USER:-cpchat} -d $${POSTGRES_DB:-cpchat}

.PHONY: redis-cli
redis-cli: ## Open a redis-cli shell on the local cache
	$(COMPOSE) exec redis redis-cli

.PHONY: check
check: ## Validate the compose file and migration numbering
	$(COMPOSE) config -q
	@echo "docker-compose.yml OK"

.PHONY: mobile-get
mobile-get: ## Fetch Flutter dependencies
	cd mobile && flutter pub get

.PHONY: mobile-gen
mobile-gen: ## Run code generation (Drift)
	cd mobile && dart run build_runner build

.PHONY: mobile-analyze
mobile-analyze: ## Analyze the Flutter app
	cd mobile && flutter analyze

.PHONY: mobile-test
mobile-test: ## Run Flutter tests
	cd mobile && flutter test

.PHONY: mobile-run
mobile-run: ## Run the Android app on a connected device/emulator
	cd mobile && flutter run -d android
