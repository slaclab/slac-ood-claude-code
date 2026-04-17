# Container runtime (default: sudo podman)
RUNTIME ?= sudo podman

# Image configuration
REGISTRY  ?= docker.io
NAMESPACE ?= slaclab
IMAGE     ?= claude-code
TAG       ?= latest

FULL_IMAGE         = $(REGISTRY)/$(NAMESPACE)/$(IMAGE):$(TAG)
VERSIONED_IMAGE    = $(REGISTRY)/$(NAMESPACE)/$(IMAGE):$(CLAUDE_VERSION)

# Resolve the latest Claude Code version once; used for both --build-arg and
# the Apptainer .sif filename so they always stay in sync.
CLAUDE_VERSION := $(shell curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest \
                      | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")

UV_VERSION := $(shell curl -fsSL https://pypi.org/pypi/uv/json \
                  | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])")

MEMPALACE_VERSION := $(shell curl -fsSL https://pypi.org/pypi/mempalace/json \
                         | python3 -c "import sys,json; print(json.load(sys.stdin)['info']['version'])")

SIF_FILE = $(IMAGE)_$(CLAUDE_VERSION).sif

.PHONY: all build build-no-cache push login apptainer clean help

## all: build and push the image
all: build push

## build: build the container image (auto-detects latest Claude Code version for cache-busting)
build:
	$(RUNTIME) build \
	  --build-arg CLAUDE_VERSION=$(CLAUDE_VERSION) \
	  --build-arg UV_VERSION=$(UV_VERSION) \
	  --build-arg MEMPALACE_VERSION=$(MEMPALACE_VERSION) \
	  -t $(FULL_IMAGE) \
	  -t $(VERSIONED_IMAGE) .

## build-no-cache: build the container image without cache
build-no-cache:
	$(RUNTIME) build --no-cache \
	  --build-arg CLAUDE_VERSION=$(CLAUDE_VERSION) \
	  --build-arg UV_VERSION=$(UV_VERSION) \
	  --build-arg MEMPALACE_VERSION=$(MEMPALACE_VERSION) \
	  -t $(FULL_IMAGE) \
	  -t $(VERSIONED_IMAGE) .

## apptainer: convert the Docker image to an Apptainer .sif file (e.g. claude-code_2.1.101.sif)
apptainer:
	apptainer build $(SIF_FILE) docker://$(VERSIONED_IMAGE)

## push: push the image to DockerHub (both :latest and :<claude-version> tags)
push:
	$(RUNTIME) push $(FULL_IMAGE)
	$(RUNTIME) push $(VERSIONED_IMAGE)

## login: log in to DockerHub
login:
	$(RUNTIME) login $(REGISTRY)

## tag: tag the image with a custom TAG (e.g. make tag TAG=1.2.3)
tag:
	$(RUNTIME) tag $(FULL_IMAGE) $(REGISTRY)/$(NAMESPACE)/$(IMAGE):$(TAG)

## clean: remove the local image
clean:
	$(RUNTIME) rmi $(FULL_IMAGE) || true

## help: show this help message
help:
	@echo ""
	@echo "Usage: make [target] [VARIABLE=value ...]"
	@echo ""
	@echo "Targets:"
	@grep -E '^## ' Makefile | sed 's/^## /  /'
	@echo ""
	@echo "Variables (current values):"
	@echo "  RUNTIME   = $(RUNTIME)"
	@echo "  REGISTRY  = $(REGISTRY)"
	@echo "  NAMESPACE = $(NAMESPACE)"
	@echo "  IMAGE     = $(IMAGE)"
	@echo "  TAG       = $(TAG)"
	@echo "  FULL_IMAGE         = $(FULL_IMAGE)"
	@echo "  VERSIONED_IMAGE    = $(VERSIONED_IMAGE)"
	@echo "  CLAUDE_VERSION = $(CLAUDE_VERSION)"
	@echo "  UV_VERSION     = $(UV_VERSION)"
	@echo "  MEMPALACE_VERSION = $(MEMPALACE_VERSION)"
	@echo "  SIF_FILE       = $(SIF_FILE)"
	@echo ""