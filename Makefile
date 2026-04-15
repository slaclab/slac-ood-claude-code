# Container runtime (default: sudo podman)
RUNTIME ?= sudo podman

# Image configuration
REGISTRY  ?= docker.io
NAMESPACE ?= slaclab
IMAGE     ?= claude-code
TAG       ?= latest

FULL_IMAGE = $(REGISTRY)/$(NAMESPACE)/$(IMAGE):$(TAG)

.PHONY: all build build-no-cache push login clean help

## all: build and push the image
all: build push

## build: build the container image
build:
	$(RUNTIME) build -t $(FULL_IMAGE) .

## build-no-cache: build the container image without cache
build-no-cache:
	$(RUNTIME) build --no-cache -t $(FULL_IMAGE) .

## push: push the image to DockerHub
push:
	$(RUNTIME) push $(FULL_IMAGE)

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
	@echo "  FULL_IMAGE= $(FULL_IMAGE)"
	@echo ""