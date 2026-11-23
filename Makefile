# Local equivalents of the CI/CD pipeline stages. Run `make help` for targets.
SHELL := bash
.SHELLFLAGS := -eo pipefail -c

VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
IMAGE   ?= orders-api:$(VERSION)
STAGES  := 01-platform 02-addons 03-app
export TF_VAR_image := $(IMAGE)

.PHONY: help lint test build up smoke load drift evidence down all dev

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

lint: ## Ruff, ShellCheck, Terraform fmt/validate
	cd app && uv run ruff check . && uv run ruff format --check .
	shellcheck --external-sources scripts/*.sh
	terraform fmt -check -recursive infra
	for s in $(STAGES); do terraform -chdir=infra/$$s init -backend=false -input=false >/dev/null && terraform -chdir=infra/$$s validate; done

test: ## Unit tests with coverage
	cd app && uv run pytest tests/unit --cov

build: ## Build the application image
	docker build --provenance=false --build-arg APP_VERSION=$(VERSION) -t $(IMAGE) app

up: build ## Build, then terraform apply all three stages
	for s in $(STAGES); do \
	  terraform -chdir=infra/$$s init -input=false && \
	  terraform -chdir=infra/$$s apply -auto-approve -input=false; \
	done

smoke: ## Post-deploy smoke tests
	EXPECTED_VERSION=$(VERSION) scripts/smoke-test.sh

load: ## k6 load test; asserts HPA + KEDA scale out
	scripts/autoscale-test.sh

drift: ## Second terraform plan must report no changes
	scripts/drift-check.sh

evidence: ## Snapshot cluster/Docker state into evidence/
	scripts/collect-evidence.sh

down: ## terraform destroy all stages (reverse order)
	for s in 03-app 02-addons 01-platform; do \
	  [ -f infra/$$s/terraform.tfstate ] && terraform -chdir=infra/$$s destroy -auto-approve -input=false || true; \
	done

all: up smoke load drift evidence ## Full pipeline locally (leaves the stack running)

dev: ## Run the app with docker compose (no Kubernetes)
	docker compose up --build
