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

.PHONY: up-scale
up-scale: .env ## Start infrastructure plus Kafka and ScyllaDB (Phase 4)
	$(COMPOSE) --profile kafka --profile scylla up -d postgres redis minio minio-init kafka scylla scylla-init

.PHONY: backfill-scylla
backfill-scylla: ## Mirror existing messages from PostgreSQL into ScyllaDB
	cd backend && DATABASE_URL=$${DATABASE_URL:-postgres://cpchat:cpchat@localhost:5432/cpchat?sslmode=disable} \
		SCYLLA_CONTACT_POINTS=$${SCYLLA_CONTACT_POINTS:-localhost:9042} \
		node scripts/backfill-scylla.mjs $(args)

.PHONY: kafka-cli
kafka-cli: ## List topics on the local Kafka broker
	$(COMPOSE) --profile kafka exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

.PHONY: scylla-cqlsh
scylla-cqlsh: ## Open a cqlsh shell on the local ScyllaDB node
	$(COMPOSE) --profile scylla exec scylla cqlsh

.PHONY: up-all
up-all: .env migrate-up ## Start the full stack: infrastructure + API + chat gateway
	$(COMPOSE) up -d --build postgres redis minio minio-init api gateway

.PHONY: backend-rebuild
backend-rebuild: ## Rebuild the api + gateway images from the current source
	$(COMPOSE) build api gateway

.PHONY: backend-restart
backend-restart: ## Rebuild and restart the api + gateway containers
	$(COMPOSE) build api gateway
	$(COMPOSE) up -d api gateway

.PHONY: api-logs
api-logs: ## Tail only the api container logs
	$(COMPOSE) logs -f --tail=100 api

.PHONY: gateway-logs
gateway-logs: ## Tail only the gateway container logs
	$(COMPOSE) logs -f --tail=100 gateway

.PHONY: backend-install
backend-install: ## Install backend dependencies
	cd backend && npm ci --include=dev

.PHONY: backend-typecheck
backend-typecheck: ## Typecheck the backend
	cd backend && npm run typecheck

.PHONY: backend-test
backend-test: ## Run backend unit and integration tests
	cd backend && npm test

.PHONY: backend-build
backend-build: ## Compile the backend to backend/dist
	cd backend && npm run build

.PHONY: smoke
smoke: ## Run the live end-to-end REST + WebSocket smoke test
	cd backend && node scripts/smoke.mjs $${REST_BASE_URL:-http://localhost:8080} $${WS_BASE_URL:-ws://localhost:8081}

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
migrate-up: ## Apply all pending migrations (000001 through 000007)
	$(MIGRATE) up

.PHONY: migrations-check
migrations-check: ## Verify every migration has a matching up/down pair
	@cd backend/migrations && set -e; \
	fail=0; \
	for up in [0-9]*.up.sql; do \
		base=$${up%.up.sql}; \
		if [ ! -f "$$base.down.sql" ]; then echo "missing $$base.down.sql"; fail=1; fi; \
	done; \
	for down in [0-9]*.down.sql; do \
		base=$${down%.down.sql}; \
		if [ ! -f "$$base.up.sql" ]; then echo "missing $$base.up.sql"; fail=1; fi; \
	done; \
	if [ "$$fail" -ne 0 ]; then exit 1; fi; \
	echo "migration pairs OK: $$(ls [0-9]*.up.sql | wc -l) versions"

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

.PHONY: mobile-apk
mobile-apk: ## Build an installable APK for a LAN device (MODE=debug|release, default debug)
	@test -n "$(API_BASE_URL)" || (echo "usage: make mobile-apk API_BASE_URL=http://<host-ip>:8080 WS_BASE_URL=ws://<host-ip>:8081 [MODE=release]" && exit 1)
	@test -n "$(WS_BASE_URL)" || (echo "usage: make mobile-apk API_BASE_URL=http://<host-ip>:8080 WS_BASE_URL=ws://<host-ip>:8081 [MODE=release]" && exit 1)
	cd mobile && flutter build apk --$(or $(MODE),debug) \
		--dart-define=API_BASE_URL=$(API_BASE_URL) \
		--dart-define=WS_BASE_URL=$(WS_BASE_URL)

.PHONY: verify
verify: migrations-check backend-typecheck backend-build backend-test mobile-analyze mobile-test ## Run the full Phase 6 verification suite
	@echo "verification suite passed"
