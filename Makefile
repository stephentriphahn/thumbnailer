.PHONY: help emulator-forward emulator-env emulator-ca
.DEFAULT_GOAL := help

NS := platform
PORT := 9297

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-18s %s\n", $$1, $$2}'

emulator-forward:  ## Port-forward the emulator to localhost
	kubectl -n $(NS) port-forward svc/aws-emulator $(PORT):$(PORT)

emulator-ca: ## Save the emulator CA to .emulator/ca.pem
	@mkdir -p .emulator
	@kubectl -n $(NS) get cm aws-emulator-ca -o jsonpath='{.data.ca\.pem}' > .emulator/ca.pem.tmp \
	  || { echo "error: ConfigMap aws-emulator-ca not found in namespace $(NS)" >&2; rm -f .emulator/ca.pem.tmp; exit 1; }
	@test -s .emulator/ca.pem.tmp || { echo "error: ConfigMap has no ca.pem data (is the ca-publisher sidecar running?)" >&2; rm -f .emulator/ca.pem.tmp; exit 1; }
	@mv .emulator/ca.pem.tmp .emulator/ca.pem
	@echo "wrote .emulator/ca.pem"

emulator-env: ## Print shell exports for host AWS tools (use: eval "$(make -s emulator-env)")
	@echo 'unset AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_PROFILE AWS_SESSION_TOKEN'
	@echo 'export AWS_ENDPOINT_URL=https://127.0.0.1:$(PORT)'
	@echo 'export AWS_CA_BUNDLE=$(CURDIR)/.emulator/ca.pem'
	@echo 'export AWS_REGION=us-east-1'
	@echo 'export AWS_DEFAULT_REGION=us-east-1'
	@echo 'export AWS_SECRET_ACCESS_KEY=local'
	@echo 'export AWS_ACCESS_KEY_ID=local'
	@echo 'export AWS_PAGER=""'
	@echo 'export AWS_EC2_METADATA_DISABLED=true'
	@echo 'export AWS_DISABLE_HOST_PREFIX_INJECTION=true'

platform-up: ## Install or upgrade the platform release (local values)
	helm upgrade --install platform charts/platform -n $(NS) --create-namespace -f charts/platform/values-local.yaml