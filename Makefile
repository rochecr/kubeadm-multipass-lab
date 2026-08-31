SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- config -----------------------------------------------------------------
# CP_COUNT=1  -> plain single control-plane kubeadm cluster, no VIP/kube-vip.
# CP_COUNT>1  -> HA control plane, kube-vip fronting a floating VIP.
NAME_PREFIX  ?= k8s
CP_COUNT     ?= 1
WORKER_COUNT ?= 2

IMAGE   := 24.04
CPUS    ?= 2
MEM     ?= 2G
DISK    ?= 20G

K8S_STREAM       ?= v1.34
POD_CIDR         ?= 10.244.0.0/16
CALICO_VERSION   ?= v3.32.1
KUBE_VIP_VERSION ?= v1.2.1

# Defaults for `make add-worker` — separate names so overriding one
# doesn't touch the fixed fleet sizing above. e.g.:
#   make add-worker NAME=k8s-w3 ADD_MEM=4G
ADD_CPUS ?= $(CPUS)
ADD_MEM  ?= $(MEM)
ADD_DISK ?= $(DISK)

# VIP is auto-detected from the first control plane's subnet on first run
# (HA mode only) and cached in .state/vip. Override with: make up VIP=x.x.x.x
VIP ?=

STATE_DIR         := $(CURDIR)/.state
VIP_FILE          := $(STATE_DIR)/vip
JOIN_WORKER_FILE  := $(STATE_DIR)/kubeadm-join-worker.sh
JOIN_CP_FILE      := $(STATE_DIR)/kubeadm-join-cp.sh
EXTRA_NODES_FILE  := $(STATE_DIR)/extra-nodes
KUBECONFIG_OUT    := $(CURDIR)/kubeconfig

# node names, generated from CP_COUNT/WORKER_COUNT — not fixed variables,
# so any CP_COUNT/WORKER_COUNT works, not just specific hardcoded counts.
CP_NAMES     := $(shell seq 1 $(CP_COUNT) | sed 's/^/$(NAME_PREFIX)-cp/')
WORKER_NAMES := $(shell seq 1 $(WORKER_COUNT) | sed 's/^/$(NAME_PREFIX)-w/')
NODES        := $(CP_NAMES) $(WORKER_NAMES)
CP1_NAME     := $(word 1,$(CP_NAMES))

.PHONY: help up destroy kubeconfig verify status add-worker ssh \
        launch-nodes detect-vip bootstrap-nodes init-first-cp join-control-planes join-workers install-cni

help:
	@echo "targets:"
	@echo "  make up               - provision the cluster (idempotent)"
	@echo "  make add-worker       - add one more worker, custom size, e.g.:"
	@echo "                          make add-worker NAME=$(NAME_PREFIX)-w3 ADD_MEM=4G"
	@echo "  make kubeconfig       - copy admin kubeconfig to ./kubeconfig"
	@echo "  make verify           - run verify.sh against the cluster"
	@echo "  make ssh NAME=<node>  - shell into any node"
	@echo "  make status           - multipass list"
	@echo "  make destroy          - tear everything down (incl. any add-worker nodes)"
	@echo ""
	@echo "current config: CP_COUNT=$(CP_COUNT) WORKER_COUNT=$(WORKER_COUNT) NAME_PREFIX=$(NAME_PREFIX)"
	@echo "  nodes: $(NODES)"
	@echo ""
	@echo "examples:"
	@echo "  make up                              # 1 control-plane + 2 workers, no VIP"
	@echo "  make up CP_COUNT=3 WORKER_COUNT=2     # HA, 3 control planes + 2 workers"
	@echo "  make up VIP=192.168.64.200            # HA with an explicit VIP instead of auto-pick"

# --- up -----------------------------------------------------------------------

up: launch-nodes detect-vip bootstrap-nodes init-first-cp join-control-planes join-workers install-cni
	@echo ""
	@if [ "$(CP_COUNT)" -gt 1 ]; then \
		echo ">>> Cluster up (HA, $(CP_COUNT) control planes). VIP=$$(cat $(VIP_FILE)). Next: make kubeconfig && make verify"; \
	else \
		echo ">>> Cluster up (single control-plane). Next: make kubeconfig && make verify"; \
	fi

launch-nodes:
	@mkdir -p $(STATE_DIR)
	@for n in $(NODES); do \
		if multipass info $$n >/dev/null 2>&1; then \
			echo ">>> $$n already exists, skipping launch"; \
		else \
			echo ">>> launching $$n ($(IMAGE), $(CPUS) vCPU, $(MEM), $(DISK))"; \
			multipass launch $(IMAGE) --name $$n --cpus $(CPUS) --memory $(MEM) --disk $(DISK); \
		fi; \
	done
	@echo ">>> waiting for cloud-init on all nodes..."
	@for n in $(NODES); do \
		multipass exec $$n -- cloud-init status --wait >/dev/null 2>&1 || true; \
	done

detect-vip:
	@mkdir -p $(STATE_DIR)
	@if [ "$(CP_COUNT)" -le 1 ]; then \
		echo ">>> CP_COUNT=1 - single control-plane, no VIP/kube-vip needed, skipping"; \
		exit 0; \
	fi; \
	if [ -n "$(VIP)" ]; then \
		echo "$(VIP)" >$(VIP_FILE); \
		echo ">>> using explicit VIP $(VIP)"; \
		ping -c1 -W1 "$(VIP)" >/dev/null 2>&1 && echo "!! warning: $(VIP) already answers ping - make sure nothing else owns it" || true; \
	elif [ -f $(VIP_FILE) ]; then \
		echo ">>> reusing cached VIP $$(cat $(VIP_FILE))"; \
	else \
		EXISTING=$$(multipass exec $(CP1_NAME) -- sudo sed -n '/name: address/{n;s/.*value: //p}' /etc/kubernetes/manifests/kube-vip.yaml 2>/dev/null || true); \
		if [ -n "$$EXISTING" ]; then \
			echo "$$EXISTING" >$(VIP_FILE); \
			echo ">>> .state/vip was missing but $(CP1_NAME) already has a live kube-vip manifest using $$EXISTING - reusing it instead of picking a new one"; \
			exit 0; \
		fi; \
		CP1_IP=$$(multipass info $(CP1_NAME) | awk '/IPv4/{print $$2; exit}'); \
		if [ -z "$$CP1_IP" ]; then echo "!! could not read $(CP1_NAME)'s IP - is it launched?"; exit 1; fi; \
		SUBNET=$$(echo "$$CP1_IP" | cut -d. -f1-3); \
		FOUND=""; \
		for h in 200 201 202 203 204 205 206 207 208 209 210; do \
			CAND="$$SUBNET.$$h"; \
			if ! ping -c1 -W1 "$$CAND" >/dev/null 2>&1; then FOUND="$$CAND"; break; fi; \
		done; \
		if [ -z "$$FOUND" ]; then \
			echo "!! could not auto-pick a free VIP in $$SUBNET.0/24 - set one explicitly: make up VIP=x.x.x.x"; \
			exit 1; \
		fi; \
		echo "$$FOUND" >$(VIP_FILE); \
		echo ">>> auto-picked VIP $$FOUND in $$SUBNET.0/24 (override with 'make up VIP=x.x.x.x' if this collides with something on your LAN)"; \
	fi

bootstrap-nodes:
	@for n in $(NODES); do \
		echo ">>> bootstrapping $$n"; \
		multipass transfer scripts/common-setup.sh $$n:/tmp/common-setup.sh; \
		multipass exec $$n -- sudo K8S_STREAM=$(K8S_STREAM) bash /tmp/common-setup.sh; \
	done

init-first-cp:
	@if [ "$(CP_COUNT)" -gt 1 ]; then \
		test -f $(VIP_FILE) || (echo "!! $(VIP_FILE) missing - run 'make detect-vip' first"; exit 1); \
		VIP=$$(cat $(VIP_FILE)); \
		echo ">>> writing kube-vip manifest on $(CP1_NAME) (VIP=$$VIP)"; \
		multipass transfer scripts/write-kube-vip.sh $(CP1_NAME):/tmp/write-kube-vip.sh; \
		multipass exec $(CP1_NAME) -- sudo VIP=$$VIP KUBE_VIP_VERSION=$(KUBE_VIP_VERSION) bash /tmp/write-kube-vip.sh; \
	fi
	@echo ">>> initializing $(CP1_NAME)"
	@multipass transfer scripts/init-first-cp.sh $(CP1_NAME):/tmp/init-first-cp.sh
	@if [ "$(CP_COUNT)" -gt 1 ]; then \
		VIP=$$(cat $(VIP_FILE)); \
		multipass exec $(CP1_NAME) -- sudo VIP=$$VIP CP_COUNT=$(CP_COUNT) POD_CIDR=$(POD_CIDR) NODE_NAME=$(CP1_NAME) bash /tmp/init-first-cp.sh; \
	else \
		multipass exec $(CP1_NAME) -- sudo CP_COUNT=1 POD_CIDR=$(POD_CIDR) NODE_NAME=$(CP1_NAME) bash /tmp/init-first-cp.sh; \
	fi
	@multipass transfer $(CP1_NAME):/tmp/kubeadm-join-worker.sh $(JOIN_WORKER_FILE)
	@if [ "$(CP_COUNT)" -gt 1 ]; then \
		multipass transfer $(CP1_NAME):/tmp/kubeadm-join-cp.sh $(JOIN_CP_FILE); \
	fi

join-control-planes:
	@if [ "$(CP_COUNT)" -le 1 ]; then \
		echo ">>> CP_COUNT=1 - nothing to join, skipping"; \
		exit 0; \
	fi
	@test -f $(VIP_FILE) || (echo "!! $(VIP_FILE) missing - run 'make detect-vip' first"; exit 1)
	@VIP=$$(cat $(VIP_FILE)); \
		for n in $(wordlist 2,$(CP_COUNT),$(CP_NAMES)); do \
			echo ">>> ensuring kube-vip manifest on $$n"; \
			multipass transfer scripts/write-kube-vip.sh $$n:/tmp/write-kube-vip.sh; \
			multipass exec $$n -- sudo VIP=$$VIP KUBE_VIP_VERSION=$(KUBE_VIP_VERSION) KUBECONFIG_SRC=/etc/kubernetes/admin.conf bash /tmp/write-kube-vip.sh; \
			if multipass exec $$n -- test -f /etc/kubernetes/kubelet.conf >/dev/null 2>&1; then \
				echo ">>> $$n already joined, skipping kubeadm join"; \
			else \
				echo ">>> joining $$n as control-plane"; \
				test -f $(JOIN_CP_FILE) || (echo "!! $(JOIN_CP_FILE) missing - run 'make init-first-cp' first"; exit 1); \
				multipass transfer $(JOIN_CP_FILE) $$n:/tmp/kubeadm-join-cp.sh; \
				multipass exec $$n -- sudo bash /tmp/kubeadm-join-cp.sh; \
			fi; \
		done

join-workers:
	@test -f $(JOIN_WORKER_FILE) || (echo "!! $(JOIN_WORKER_FILE) missing - run 'make init-first-cp' first"; exit 1)
	@for n in $(WORKER_NAMES); do \
		echo ">>> joining $$n as worker"; \
		if multipass exec $$n -- test -f /etc/kubernetes/kubelet.conf >/dev/null 2>&1; then \
			echo ">>> $$n already joined, skipping"; \
		else \
			multipass transfer $(JOIN_WORKER_FILE) $$n:/tmp/kubeadm-join-worker.sh; \
			multipass exec $$n -- sudo bash /tmp/kubeadm-join-worker.sh; \
		fi; \
		multipass exec $(CP1_NAME) -- sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf \
			label node $$n node-role.kubernetes.io/worker= --overwrite >/dev/null; \
	done

install-cni:
	@echo ">>> installing Calico $(CALICO_VERSION)"
	@multipass transfer scripts/install-calico.sh $(CP1_NAME):/tmp/install-calico.sh
	@multipass exec $(CP1_NAME) -- sudo CALICO_VERSION=$(CALICO_VERSION) POD_CIDR=$(POD_CIDR) bash /tmp/install-calico.sh

# --- add a node after the cluster is already up ------------------------------

add-worker:
	@test -n "$(NAME)" || (echo "!! usage: make add-worker NAME=$(NAME_PREFIX)-w3 [ADD_MEM=4G] [ADD_CPUS=2] [ADD_DISK=20G]"; exit 1)
	@mkdir -p $(STATE_DIR)
	@if multipass info $(NAME) >/dev/null 2>&1; then \
		echo ">>> $(NAME) already exists, skipping launch"; \
	else \
		echo ">>> launching $(NAME) ($(IMAGE), $(ADD_CPUS) vCPU, $(ADD_MEM), $(ADD_DISK))"; \
		multipass launch $(IMAGE) --name $(NAME) --cpus $(ADD_CPUS) --memory $(ADD_MEM) --disk $(ADD_DISK); \
		multipass exec $(NAME) -- cloud-init status --wait >/dev/null 2>&1 || true; \
	fi
	@echo ">>> bootstrapping $(NAME)"
	@multipass transfer scripts/common-setup.sh $(NAME):/tmp/common-setup.sh
	@multipass exec $(NAME) -- sudo K8S_STREAM=$(K8S_STREAM) bash /tmp/common-setup.sh
	@if multipass exec $(NAME) -- test -f /etc/kubernetes/kubelet.conf >/dev/null 2>&1; then \
		echo ">>> $(NAME) already joined, skipping kubeadm join"; \
	else \
		echo ">>> minting a fresh worker join command from $(CP1_NAME) (old tokens expire after 24h)"; \
		multipass exec $(CP1_NAME) -- sudo sh -c 'kubeadm token create --print-join-command > /tmp/kubeadm-join-worker-fresh.sh'; \
		multipass transfer $(CP1_NAME):/tmp/kubeadm-join-worker-fresh.sh /tmp/kubeadm-join-worker-fresh.sh; \
		multipass transfer /tmp/kubeadm-join-worker-fresh.sh $(NAME):/tmp/kubeadm-join-worker.sh; \
		rm -f /tmp/kubeadm-join-worker-fresh.sh; \
		multipass exec $(CP1_NAME) -- sudo rm -f /tmp/kubeadm-join-worker-fresh.sh; \
		echo ">>> joining $(NAME) as worker"; \
		multipass exec $(NAME) -- sudo bash /tmp/kubeadm-join-worker.sh; \
	fi
	@multipass exec $(CP1_NAME) -- sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf \
		label node $(NAME) node-role.kubernetes.io/worker= --overwrite >/dev/null
	@touch $(EXTRA_NODES_FILE)
	@grep -qx "$(NAME)" $(EXTRA_NODES_FILE) || echo "$(NAME)" >>$(EXTRA_NODES_FILE)
	@echo ">>> $(NAME) joined. Verify: kubectl get nodes -o wide"

# --- day 2 --------------------------------------------------------------------

kubeconfig:
	@multipass exec $(CP1_NAME) -- sudo cat /etc/kubernetes/admin.conf > $(KUBECONFIG_OUT)
	@if [ "$(CP_COUNT)" -gt 1 ]; then \
		test -f $(VIP_FILE) || (echo "!! $(VIP_FILE) missing - run 'make up' first"; exit 1); \
		VIP=$$(cat $(VIP_FILE)); \
		sed -i "s#server: .*#server: https://$$VIP:6443#" $(KUBECONFIG_OUT); \
	fi
	@chmod 600 $(KUBECONFIG_OUT)
	@echo ">>> wrote $(KUBECONFIG_OUT)"
	@echo ">>> run: export KUBECONFIG=$(KUBECONFIG_OUT)"

verify:
	@KUBECONFIG=$(KUBECONFIG_OUT) bash verify.sh

status:
	@multipass list

ssh:
	@test -n "$(NAME)" || (echo "!! usage: make ssh NAME=$(CP1_NAME)"; exit 1)
	@multipass shell $(NAME)

destroy:
	@for n in $(NODES) $$(cat $(EXTRA_NODES_FILE) 2>/dev/null); do \
		multipass delete --purge $$n >/dev/null 2>&1 || true; \
	done
	@rm -rf $(STATE_DIR) $(KUBECONFIG_OUT)
	@echo ">>> cluster destroyed"
