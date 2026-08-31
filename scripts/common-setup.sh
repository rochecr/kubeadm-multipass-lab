#!/usr/bin/env bash
# common-setup.sh — runs on every node (control planes + workers).
# Prepares the OS, installs containerd, and installs kubeadm/kubelet/kubectl.
# Idempotent: safe to re-run, guarded by a marker file.
set -euo pipefail

K8S_STREAM="${K8S_STREAM:-v1.34}"
MARKER=/etc/kubeadm-multipass-lab-provisioned

if [[ -f "$MARKER" ]]; then
    echo ">>> $(hostname): already provisioned (K8s stream $(cat "$MARKER")), skipping"
    exit 0
fi

echo ">>> $(hostname): disabling swap"
swapoff -a
sed -ri 's/^([^#].*\sswap\s)/#\1/' /etc/fstab

echo ">>> $(hostname): loading kernel modules"
cat <<'EOF' >/etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo ">>> $(hostname): configuring sysctl for Kubernetes networking"
cat <<'EOF' >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo ">>> $(hostname): installing containerd"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -yqq containerd apt-transport-https ca-certificates curl gpg >/dev/null

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd >/dev/null 2>&1

echo ">>> $(hostname): adding pkgs.k8s.io repo ($K8S_STREAM) and installing kubeadm/kubelet/kubectl"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_STREAM}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -yqq kubelet kubeadm kubectl >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null

systemctl enable --now kubelet >/dev/null 2>&1 || true
# kubelet will crashloop here until kubeadm init/join runs against it — expected.

echo "$K8S_STREAM" >"$MARKER"
echo ">>> $(hostname): provisioning complete"
