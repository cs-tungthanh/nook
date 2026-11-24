# Entry points for building Nook and running the repo's tools.
# Run `make` (or `make help`) to list the targets.

.DEFAULT_GOAL := help
.PHONY: help build install uninstall run clean icon hooks scan clean-zsh bookmarks tools-check

# Extra arguments for the tool targets, e.g. make bookmarks ARGS="-apply -wait 5"
ARGS ?=

help: ## List the targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z_-]+:.*## / { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

## App

build: ## Compile, bundle and sign Nook.app
	scripts/build.sh

install: ## Build, replace /Applications/Nook.app and launch it
	scripts/install.sh

uninstall: ## Quit Nook and remove it from /Applications
	scripts/install.sh --uninstall

run: build ## Build and open the repo copy of Nook.app
	open Nook.app

clean: ## Remove the built Nook.app
	rm -rf Nook.app

icon: ## Redraw icon/AppIcon.icns from icon/make-icon.swift
	swift icon/make-icon.swift icon/AppIcon.iconset
	iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns
	rm -rf icon/AppIcon.iconset

## Repo

hooks: ## Enable the pre-commit hook for this clone
	git config core.hooksPath .githooks
	@command -v gitleaks >/dev/null 2>&1 || echo "Install gitleaks to make the hook scan: brew install gitleaks"

scan: ## Scan every commit for secrets and home paths
	gitleaks git . --config .gitleaks.toml --redact --no-banner

## Tools (standalone Go programs in tools/)

clean-zsh: ## Remove duplicate commands from ~/.zsh_history (ARGS="path")
	cd tools && go run ./clean-zsh $(ARGS)

bookmarks: ## Preview moved Edge bookmarks (ARGS="-apply" to save)
	cd tools && go run ./edge-bookmarks $(ARGS)

tools-check: ## Vet and build the Go tools
	cd tools && go vet ./... && go build -o /dev/null ./...
