# Day-to-day operations on the BOOST Togo stack. Run from the directory that
# holds compose.yaml and .env: the installation directory on the server, or
# the repository for development. `make` alone lists the targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE := docker compose
# An installation package has no source to build from: its images are loaded.
IN_REPO := $(wildcard upstream.lock)
NO_BUILD := $(if $(IN_REPO),,--no-build)
# Image tag: in the repository, the release of the checked-out commit
# (scripts/release-name.sh); in an installation package, RELEASE from .env.
ifneq ($(IN_REPO),)
RELEASE ?= $(shell scripts/release-name.sh)
export RELEASE
endif

BACKUP_DIR ?= /var/backups/boost-togo
KEEP_DAYS ?= 30
SINCE ?= 1h
SERVICE ?=
STEPS ?=
FILE ?=
CONFIRM ?=
BACKUP_NAME ?=
REF ?=
VERSION ?=

.PHONY: help install up down restart status logs follow pipeline refresh-boundaries steps \
        backup restore cache-clear psql deploy-check fetch build package deploy rollback releases release \
        metabase-up metabase-down metabase-status \
        dev-setup dev-db-up dev-db-down dev-db-status dev-db-reset dev-dashboard dev-pipeline \
        dev-steps dev-test dev-psql dev-status dev-lock

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z][a-z-]*:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  Variables: SERVICE=db|dashboard  SINCE=24h  STEPS='mega-indicators/gdp.py ...'"
	@echo "             FILE=<dump>  BACKUP_DIR=$(BACKUP_DIR)  KEEP_DAYS=$(KEEP_DAYS)"
	@echo "             REPOS='dashboard indicators boost' (dev-lock)  DEV_DB=docker|native"
	@echo "             REF=v2026.10.1 (deploy)  VERSION=2026.10.1 (release)  BACKUP_NAME=<name> (backup)"

install: ## Check, load and start an extracted package (./install.sh)
	@test -x ./install.sh || { echo "install.sh is only in an extracted package"; exit 2; }
	./install.sh

up: ## Start the database and the dashboard, applying .env changes
	$(COMPOSE) up -d --wait $(NO_BUILD)
	@bind=$${DASHBOARD_BIND:-$$(awk -F= '/^DASHBOARD_BIND=/ {print $$2}' .env 2>/dev/null)}; bind=$${bind:-127.0.0.1:8080}; \
	 for i in $$(seq 1 30); do \
	   [ "$$(curl -s -o /dev/null -w '%{http_code}' "http://$$bind/")" = 200 ] && { echo "dashboard ready: http://$$bind/"; exit 0; }; \
	   sleep 2; \
	 done; echo "dashboard not answering on http://$$bind/ after 60 s: make logs SERVICE=dashboard"; exit 1

down: ## Stop the stack (Metabase included); the database volume is kept
	$(COMPOSE) --profile metabase down

restart: ## Restart the dashboard process
	$(COMPOSE) restart dashboard

status: ## Containers and the dashboard's HTTP status
	@$(COMPOSE) ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
	@bind=$${DASHBOARD_BIND:-$$(awk -F= '/^DASHBOARD_BIND=/ {print $$2}' .env 2>/dev/null)}; bind=$${bind:-127.0.0.1:8080}; \
	 code=$$(curl -s -o /dev/null -w '%{http_code}' "http://$$bind/"); \
	 echo "dashboard http://$$bind/ -> HTTP $$code"; [ "$$code" = 200 ]

logs: ## Logs since SINCE (default 1h), of SERVICE or all services
	$(COMPOSE) logs --since $(SINCE) $(SERVICE)

follow: ## Follow the logs live (Ctrl+C to stop)
	$(COMPOSE) logs -f --tail 50 $(SERVICE)

pipeline: ## Load the data: every step, or STEPS='step1 step2'
	$(COMPOSE) run --rm pipeline $(if $(STEPS),--only $(STEPS))

refresh-boundaries: ## Download the World Bank boundary files again at the next pipeline run
	$(COMPOSE) run --rm --entrypoint sh pipeline -c 'rm -fv "$$DDH_BOUNDARIES_DIR"/*.geojson'

steps: ## List the pipeline steps
	@$(COMPOSE) run --rm -T pipeline --list

backup: ## Dump prd_mega (and Metabase's database when present) to BACKUP_DIR; dumps older than KEEP_DAYS are deleted
	@mkdir -p "$(BACKUP_DIR)"
	@f="$(BACKUP_DIR)/$(if $(BACKUP_NAME),$(BACKUP_NAME),prd_mega-$$(date +%Y%m%d)).dump"; \
	 $(COMPOSE) exec -T db pg_dump -U pipeline -d prd_mega -Fc > "$$f.part" \
	   || { rm -f "$$f.part"; echo "backup failed"; exit 1; }; \
	 mv "$$f.part" "$$f" && ls -lh "$$f"; \
	 if [ "$$($(COMPOSE) exec -T db psql -U pipeline -d prd_mega -Atc "SELECT 1 FROM pg_database WHERE datname = 'metabase'")" = 1 ]; then \
	   m="$$(dirname "$$f")/metabase-$$(basename "$$f" | sed 's/^prd_mega-//')"; \
	   $(COMPOSE) exec -T db pg_dump -U pipeline -d metabase -Fc > "$$m.part" \
	     || { rm -f "$$m.part"; echo "backup of the metabase database failed"; exit 1; }; \
	   mv "$$m.part" "$$m" && ls -lh "$$m"; \
	 fi
	@find "$(BACKUP_DIR)" \( -name 'prd_mega-*.dump' -o -name 'metabase-*.dump' \) -mtime +$(KEEP_DAYS) -print -delete

restore: ## Replace the database with FILE=<dump> (asks for confirmation)
	@test -n "$(FILE)" || { echo "usage: make restore FILE=$(BACKUP_DIR)/prd_mega-YYYYMMDD.dump"; exit 2; }
	@test -s "$(FILE)" || { echo "$(FILE): missing or empty"; exit 1; }
	@ls -lh "$(FILE)"
	$(COMPOSE) up -d --wait $(NO_BUILD) db
	@echo "server: PostgreSQL $$($(COMPOSE) exec -T db psql -U pipeline -d prd_mega -Atc 'show server_version')"
	@$(COMPOSE) exec -T db pg_restore --list < "$(FILE)" | head -6
	@if [ "$(CONFIRM)" != yes ]; then \
	   read -r -p "Replace the content of prd_mega with $(FILE)? Type yes: " answer; \
	   [ "$$answer" = yes ] || { echo "cancelled"; exit 1; }; \
	 fi
	$(COMPOSE) stop dashboard
	$(COMPOSE) exec -T db pg_restore -U pipeline -d prd_mega --clean --if-exists < "$(FILE)"
	$(COMPOSE) up -d --wait $(NO_BUILD)
	@$(MAKE) --no-print-directory cache-clear

cache-clear: ## Empty the dashboard's query cache (after changing the database by hand)
	@$(COMPOSE) exec -T dashboard python -c "import os, urllib.request; \
	r = urllib.request.Request('http://localhost:8080/api/cache/clear', method='POST', \
	headers={'X-Refresh-Token': os.environ['CACHE_REFRESH_TOKEN']}); \
	print(urllib.request.urlopen(r).read().decode())"

metabase-up: ## Optional Metabase on 127.0.0.1:3000 (METABASE_BIND): .env keys, its database and read-only role, start
	deploy/metabase.sh up

metabase-down: ## Stop Metabase; its database and roles are kept
	deploy/metabase.sh down

metabase-status: ## Metabase's container and health
	@deploy/metabase.sh status

psql: ## Open a SQL session on prd_mega
	$(COMPOSE) exec db psql -U pipeline -d prd_mega

deploy-check: ## The dashboard answers HTTP 200 and its own code reads the database
	@$(MAKE) --no-print-directory status
	@$(COMPOSE) exec -T dashboard python -c "from queries import QueryService; \
	df = QueryService().execute_query(\"SELECT count(*) AS n FROM information_schema.tables \
	WHERE table_schema IN ('boost', 'indicator')\", persistent=False); \
	print(f'database read by the dashboard: {int(df.iloc[0, 0])} tables in boost and indicator')"

fetch: ## Check out the upstream code pinned in upstream.lock (repository only)
	@test -n "$(IN_REPO)" || { echo "fetch needs the repository (upstream.lock)"; exit 2; }
	scripts/fetch-upstream.sh

build: ## Build the images from the upstream checkouts (repository only)
	@test -n "$(IN_REPO)" || { echo "build needs the repository (upstream.lock)"; exit 2; }
	@test -f upstream/SOURCES || { echo "no upstream checkout: make fetch"; exit 2; }
	$(COMPOSE) --profile pipeline build

package: ## Build the offline installation package (repository only)
	@test -n "$(IN_REPO)" || { echo "package needs the repository (upstream.lock)"; exit 2; }
	scripts/package-release.sh --indicator-snapshot

deploy: ## Deploy REF (a vAAAA.MM.N tag or a branch): backup, build, start, check; back on failure (repository only)
	@test -n "$(IN_REPO)" || { echo "deploy needs the repository (upstream.lock)"; exit 2; }
	scripts/deploy.sh $(REF)

rollback: ## Back to the release deployed before the current one, from its images (repository only)
	@test -n "$(IN_REPO)" || { echo "rollback needs the repository (upstream.lock)"; exit 2; }
	scripts/deploy.sh --rollback

releases: ## Releases deployed from this clone, newest last (repository only)
	@test -n "$(IN_REPO)" || { echo "releases needs the repository (upstream.lock)"; exit 2; }
	@scripts/deploy.sh --history

release: ## Tag VERSION=AAAA.MM.N: fork tags at the pinned commits, upstream.lock on them, deploy tag (repository only)
	@test -n "$(IN_REPO)" || { echo "release needs the repository (upstream.lock)"; exit 2; }
	scripts/release.sh $(VERSION)

# Development outside Docker (repository only): the code of the sibling checkouts
# runs on the machine, against a development database (scripts/dev-*.sh).
REPO_ONLY = @test -n "$(IN_REPO)" || { echo "$@ needs the repository (upstream.lock)"; exit 2; }

dev-setup: ## Dev: sibling clones, Python environments, .env, database (DEV_DB=native: no Docker)
	$(REPO_ONLY)
	scripts/dev-setup.sh $(if $(filter native,$(DEV_DB)),--native-db)

dev-db-up: ## Dev: start the development database
	$(REPO_ONLY)
	scripts/dev-db.sh up

dev-db-down: ## Dev: stop the development database; its data are kept
	$(REPO_ONLY)
	scripts/dev-db.sh down

dev-db-status: ## Dev: the development database's address and tables
	$(REPO_ONLY)
	@scripts/dev-db.sh status

dev-db-reset: ## Dev: empty the development database (asks for confirmation)
	$(REPO_ONLY)
	scripts/dev-db.sh reset

dev-dashboard: ## Dev: the dashboard on 127.0.0.1:8050, reloaded on every change
	$(REPO_ONLY)
	scripts/dev-run.sh dashboard

dev-pipeline: ## Dev: load the data with the sibling code: every step, or STEPS='...'
	$(REPO_ONLY)
	scripts/dev-run.sh pipeline $(STEPS)

dev-steps: ## Dev: list the pipeline steps of the sibling code
	$(REPO_ONLY)
	@scripts/dev-run.sh steps

dev-test: ## Dev: the tests of rpf-country-dash and of this repository
	$(REPO_ONLY)
	scripts/dev-run.sh test

dev-psql: ## Dev: a SQL session on the development database
	$(REPO_ONLY)
	scripts/dev-run.sh psql

dev-status: ## Dev: branch and commit of each sibling checkout, against upstream.lock
	$(REPO_ONLY)
	@scripts/dev-lock.sh --status

dev-lock: ## Dev: pin the sibling checkouts' pushed branches in upstream.lock, then fetch
	$(REPO_ONLY)
	scripts/dev-lock.sh $(REPOS)
