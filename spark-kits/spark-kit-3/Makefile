# Makefile for DGX Spark LLM Stack - Spark Kit 3

.PHONY: help deploy verify rollback clean

# Default inventory file
INVENTORY ?= inventory.yaml

help: ## Show this help message
	@echo "DGX Spark LLM Stack - Spark Kit 3"
	@echo "=================================="
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\t%-15s %s\n", $$1, $$2}'
	@echo ""

deploy: ## Deploy the stack on current node (interactive, secure mode)
	@echo "Deploying DGX Spark LLM Stack (secure mode)..."
	@echo "Run: sudo ./infrastructure/deploy.sh"
	sudo ./infrastructure/deploy.sh

deploy-non-sudo: ## Deploy in non-sudo mode (testing only, degraded security)
	@echo "Deploying DGX Spark LLM Stack (non-sudo mode - testing only)..."
	./infrastructure/deploy.sh --non-sudo

verify: ## Verify deployment on all nodes
	@echo "Verifying deployment..."
	./scripts/verify.sh

verify-hub: ## Verify hub node only
	./scripts/verify.sh --hub

verify-workers: ## Verify all worker nodes
	./scripts/verify.sh --workers

rollback: ## Rollback deployment on current node (sudo mode)
	@echo "Rolling back deployment..."
	@echo "Run: sudo ./scripts/rollback.sh"
	sudo ./scripts/rollback.sh

clean: ## Remove generated files and secrets (local only)
	@echo "Cleaning generated files and secrets..."
	rm -rf generated/ secrets/
	@echo "Cleaned up."

# Individual node operations (legacy - use deploy target instead)
deploy-hub: ## Deploy hub on current node (sudo mode)
	sudo ./infrastructure/deploy.sh

deploy-worker: ## Deploy worker on current node (sudo mode)
	sudo ./infrastructure/deploy.sh

# Shellcheck for all scripts
test: ## Run offline test harness (shellcheck + config-generation tests)
	./tests/run-tests.sh

shellcheck: ## Run shellcheck on all shell scripts
	@echo "Running shellcheck..."
	find . -name "*.sh" -type f | while read -r script; do \
		echo "Checking $$script..."; \
		shellcheck "$$script" || exit 1; \
	done
	@echo "All scripts passed shellcheck."
