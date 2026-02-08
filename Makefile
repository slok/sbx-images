SHELL := /bin/bash
.DEFAULT_GOAL := help

# Build configuration (extracted from config.yaml).
KERNEL_VERSION := $(shell grep 'version:' config.yaml | head -1 | awk '{print $$2}' | tr -d '"')
CI_VERSION := $(shell grep 'ci_version:' config.yaml | awk '{print $$2}' | tr -d '"')
FC_VERSION := $(shell grep -A1 'firecracker:' config.yaml | grep 'version:' | awk '{print $$2}' | tr -d '"')
DISTRO_VERSION := $(shell grep 'distro_version:' config.yaml | awk '{print $$2}' | tr -d '"')
PROFILE := $(shell grep 'profile:' config.yaml | awk '{print $$2}' | tr -d '"')
ARCHITECTURES := $(shell grep -A10 'architectures:' config.yaml | grep '^\s*-' | awk '{print $$2}')

# Paths.
BUILD_DIR := build
SCRIPTS_DIR := scripts
PROFILES_DIR := alpine/profiles
FILES_DIR := alpine/files

# Version (set via CLI: make manifest VERSION=v0.1.0).
VERSION ?= dev
COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

.PHONY: build
build: build-kernel build-rootfs ## Build all artifacts (kernel + rootfs).

.PHONY: build-kernel
build-kernel: ## Download kernel for all architectures.
	@for arch in $(ARCHITECTURES); do \
		$(SCRIPTS_DIR)/download-kernel.sh \
			--arch "$${arch}" \
			--kernel-version "$(KERNEL_VERSION)" \
			--ci-version "$(CI_VERSION)" \
			--output-dir "$(BUILD_DIR)"; \
	done

.PHONY: build-rootfs
build-rootfs: ## Build rootfs for all architectures (requires root).
	@for arch in $(ARCHITECTURES); do \
		$(SCRIPTS_DIR)/build-rootfs.sh \
			--arch "$${arch}" \
			--profile "$(PROFILE)" \
			--branch "v$(DISTRO_VERSION)" \
			--profiles-dir "$(PROFILES_DIR)" \
			--files-dir "$(FILES_DIR)" \
			--output-dir "$(BUILD_DIR)"; \
	done

.PHONY: manifest
manifest: ## Generate manifest.json from built artifacts.
	go run ./cmd/manifest \
		-version "$(VERSION)" \
		-config config.yaml \
		-build-dir "$(BUILD_DIR)" \
		-commit "$(COMMIT)"

.PHONY: all
all: build manifest ## Build all artifacts and generate manifest.

.PHONY: clean
clean: ## Remove build artifacts.
	rm -rf $(BUILD_DIR)

.PHONY: validate
validate: ## Validate config.yaml and check Go tool compiles.
	@echo "Validating Go tool..."
	@go build ./cmd/manifest/
	@rm -f manifest
	@echo "Validating config.yaml..."
	@test -n "$(KERNEL_VERSION)" || (echo "ERROR: kernel.version not found in config.yaml" && exit 1)
	@test -n "$(CI_VERSION)" || (echo "ERROR: kernel.ci_version not found in config.yaml" && exit 1)
	@test -n "$(FC_VERSION)" || (echo "ERROR: firecracker.version not found in config.yaml" && exit 1)
	@test -n "$(PROFILE)" || (echo "ERROR: rootfs.profile not found in config.yaml" && exit 1)
	@test -n "$(ARCHITECTURES)" || (echo "ERROR: no architectures found in config.yaml" && exit 1)
	@echo "Config OK: kernel=$(KERNEL_VERSION) ci=$(CI_VERSION) fc=$(FC_VERSION) profile=$(PROFILE) arch=$(ARCHITECTURES)"

.PHONY: print-config
print-config: ## Print extracted configuration values.
	@echo "KERNEL_VERSION=$(KERNEL_VERSION)"
	@echo "CI_VERSION=$(CI_VERSION)"
	@echo "FC_VERSION=$(FC_VERSION)"
	@echo "DISTRO_VERSION=$(DISTRO_VERSION)"
	@echo "PROFILE=$(PROFILE)"
	@echo "ARCHITECTURES=$(ARCHITECTURES)"

.PHONY: help
help: ## Show this help message.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
