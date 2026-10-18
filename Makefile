# Developer targets for ghri. Requires: make, shellcheck, shfmt, yq (v4), jq, gh.

SHELL := /bin/bash
SHELL_SOURCES := ghri.sh test/fakes/gh test/run_tests.sh
SHFMT_FLAGS   := -i 2 -ci

.DEFAULT_GOAL := help
.PHONY: help all ci deps test test-integration test-live lint fmt fmt-check check outdated install prune

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

all: lint fmt-check test check ## Everything CI runs (alias: ci)

ci: all

deps: ## Install all required and development packages with apt (needs sudo)
	grep -vE '^(#|$$)' apt-packages.txt | xargs sudo apt-get install -y

test: ## Unit and end-to-end tests (sandboxed, fake gh, no network, no sudo)
	./test/run_tests.sh

test-integration: ## Real `deb` install test (needs sudo, network; changes the system and cleans up)
	GHRI_INTEGRATION=1 bash ./shpec test/shpec/deb_integration_shpec.sh

test-live: ## Smoke test against the real GitHub API and gh (network; uses GH_TOKEN/GITHUB_TOKEN or .env)
	set -a; [ -f .env ] && . ./.env; set +a; GHRI_LIVE=1 bash ./shpec test/shpec/live_shpec.sh

lint: ## ShellCheck the scripts
	shellcheck -x $(SHELL_SOURCES)

fmt: ## Format the scripts with shfmt
	shfmt $(SHFMT_FLAGS) -w $(SHELL_SOURCES)

fmt-check: ## Fail if the scripts are not shfmt-formatted
	shfmt $(SHFMT_FLAGS) -d $(SHELL_SOURCES)

check: ## Validate ghri.yaml and required tools
	./ghri.sh --check

outdated: ## Show installed vs. latest versions (exit 10 is fine: updates available)
	./ghri.sh --outdated || [ $$? -eq 10 ]

prune: ## Remove installs, records and links of packages that left the config (asks first)
	./ghri.sh --prune

install: ## Install/update all packages
	./ghri.sh install
