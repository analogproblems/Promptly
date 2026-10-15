# Promptly developer shortcuts. Run `make` for the list.
#
# Prerequisites: see docs/DEVELOPMENT.md, or run `tools/setup.sh` on Ubuntu.

FLUTTER ?= flutter
CARGO   ?= cargo
ENGINE  := engine
APP     := app

.DEFAULT_GOAL := help

help: ## Show this list
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

setup: ## Install toolchains and dependencies (Ubuntu); safe to re-run
	tools/setup.sh

gen: ## Regenerate the Dart/Rust bridge after changing engine/crates/promptly-api/src/api
	cd $(APP) && flutter_rust_bridge_codegen generate

engine-build: ## Build the Rust engine and CLI
	cd $(ENGINE) && $(CARGO) build

engine-test: ## Run the Rust tests
	cd $(ENGINE) && $(CARGO) test

engine-lint: ## Format check and clippy, as CI runs them
	cd $(ENGINE) && $(CARGO) fmt --all --check && $(CARGO) clippy --all-targets -- -D warnings

engine-fmt: ## Format the Rust code
	cd $(ENGINE) && $(CARGO) fmt --all

engine-audit: ## Check Rust dependencies against the RustSec advisory database
	@command -v cargo-audit >/dev/null || $(CARGO) install cargo-audit --locked
	cd $(ENGINE) && $(CARGO) audit

cli: ## Build and run the CLI, e.g. make cli ARGS="parse deploy@10.0.0.11"
	cd $(ENGINE) && $(CARGO) run -q -p promptly-cli -- $(ARGS)

app-get: ## Fetch Dart packages
	cd $(APP) && $(FLUTTER) pub get

analyze: ## Run the Dart analyzer
	cd $(APP) && $(FLUTTER) analyze

app-test: ## Run the widget tests (no native library needed)
	cd $(APP) && $(FLUTTER) test

run: ## Run the app on Linux desktop in debug mode with hot reload
	cd $(APP) && $(FLUTTER) run -d linux

icons: ## Re-render the app icon for every platform from tools/icons (needs Node + playwright, ImageMagick)
	node tools/icons/render.cjs

build-linux: ## Release bundle at app/build/linux/x64/release/bundle
	cd $(APP) && $(FLUTTER) build linux --release

package-linux: ## Tarball and .deb in dist/ from the release bundle
	tools/package-linux.sh

version: ## Set the version everywhere, e.g. make version V=1.0.1
	@test -n "$(V)" || (echo "usage: make version V=X.Y.Z" && exit 1)
	tools/version.sh $(V)

check: engine-lint engine-test engine-audit analyze app-test ## Everything CI checks, locally

clean: ## Remove build output
	cd $(ENGINE) && $(CARGO) clean
	cd $(APP) && $(FLUTTER) clean

.PHONY: help setup gen engine-build engine-test engine-lint engine-fmt engine-audit cli app-get analyze app-test run icons build-linux package-linux version check clean
