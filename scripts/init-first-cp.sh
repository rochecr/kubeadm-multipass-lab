#!/usr/bin/env bash
# init-first-cp.sh — runs on the first control-plane node only.
#
# Branches on CP_COUNT:
#   CP_COUNT=1  -> plain `kubeadm init`, no --control-plane-endpoint, no
#                  --upload-certs (nothing else will ever join as a CP).
#   CP_COUNT>1  -> HA init against the VIP (kube-vip's static pod manifest
#                  must already be in place — see write-kube-vip.sh — since
#                  kubeadm init needs the VIP reachable as
#                  --control-plane-endpoint).
#
# Idempotent: if already initialized, skips kubeadm init but still
# regenerates fresh join commands (tokens expire in 24h, certificate
# keys in 2h — safe, cheap to redo on every run).
set -euo pipefail

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CP_COUNT="${CP_COUNT:-1}"
NODE_NAME="${NODE_NAME:?NODE_NAME env var required}"
export KUBECONFIG=/etc/kubernetes/admin.conf

if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo ">>> control plane already initialized, skipping kubeadm init"
else
    if [[ "$CP_COUNT" -gt 1 ]]; then
        VIP="${VIP:?VIP env var required when CP_COUNT>1}"
        echo ">>> running kubeadm init (HA, control-plane-endpoint=${VIP}:6443, pod-network-cidr=${POD_CIDR})"
        kubeadm init \
            --control-plane-endpoint="${VIP}:6443" \
            --upload-certs \
            --pod-network-cidr="${POD_CIDR}" \
            --cri-socket=unix:///var/run/containerd/containerd.sock \
            --node-name="${NODE_NAME}"
    else
        echo ">>> running kubeadm init (single control-plane, pod-network-cidr=${POD_CIDR})"
        kubeadm init \
            --pod-network-cidr="${POD_CIDR}" \
            --cri-socket=unix:///var/run/containerd/containerd.sock \
            --node-name="${NODE_NAME}"
    fi

    mkdir -p "$HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
fi

echo ">>> generating worker join command"
kubeadm token create --print-join-command >/tmp/kubeadm-join-worker.sh
chmod +x /tmp/kubeadm-join-worker.sh

if [[ "$CP_COUNT" -gt 1 ]]; then
    echo ">>> generating control-plane join command (fresh certificate-key, valid 2h)"
    CERT_KEY=$(kubeadm init phase upload-certs --upload-certs | tail -1)
    printf '%s --control-plane --certificate-key %s\n' \
        "$(cat /tmp/kubeadm-join-worker.sh)" "$CERT_KEY" >/tmp/kubeadm-join-cp.sh
    chmod +x /tmp/kubeadm-join-cp.sh
fi

echo ">>> ${NODE_NAME} ready"
echo ">>> worker join:        $(cat /tmp/kubeadm-join-worker.sh)"
if [[ "$CP_COUNT" -gt 1 ]]; then
    echo ">>> control-plane join: $(cat /tmp/kubeadm-join-cp.sh)"
fi
