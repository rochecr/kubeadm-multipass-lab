SHELL := /bin/bash
.DEFAULT_GOAL := help

CONFIG ?= clusters.yaml
CLUSTER ?=
PRUNE ?=

PRUNE_FLAG := $(if $(PRUNE),--prune,)

.PHONY: help up destroy status audit

help:
	@echo "Thin wrapper over provision.py — clusters.yaml is the source of truth."
	@echo ""
	@echo "  make up      CLUSTER=<name>            - converge to the declared state"
	@echo "  make audit   CLUSTER=<name>            - read-only drift/orphan report, no side effects"
	@echo "  make status  CLUSTER=<name>            - quick per-node state listing"
	@echo "  make destroy CLUSTER=<name> [PRUNE=1]  - remove exactly the declared nodes"
	@echo ""
	@echo "PRUNE=1 on 'up'/'destroy' also removes nodes that exist in Multipass but"
	@echo "aren't declared for that cluster in $(CONFIG)."
	@echo ""
	@echo "known clusters:"
	@python3 -c "import yaml; print('  ' + ', '.join(yaml.safe_load(open('$(CONFIG)'))['clusters'].keys()))" 2>/dev/null || true

up:
	@test -n "$(CLUSTER)" || (echo "!! usage: make up CLUSTER=<name>"; exit 1)
	python3 provision.py up --config $(CONFIG) --cluster $(CLUSTER) $(PRUNE_FLAG)

destroy:
	@test -n "$(CLUSTER)" || (echo "!! usage: make destroy CLUSTER=<name>"; exit 1)
	python3 provision.py destroy --config $(CONFIG) --cluster $(CLUSTER) $(PRUNE_FLAG)

status:
	@test -n "$(CLUSTER)" || (echo "!! usage: make status CLUSTER=<name>"; exit 1)
	python3 provision.py status --config $(CONFIG) --cluster $(CLUSTER)

audit:
	@test -n "$(CLUSTER)" || (echo "!! usage: make audit CLUSTER=<name>"; exit 1)
	python3 provision.py audit --config $(CONFIG) --cluster $(CLUSTER)
