#!/usr/bin/env bash
# write-kube-vip.sh — runs on the first control plane / any additional
# control plane BEFORE kubeadm init/join. Places the kube-vip static Pod
# manifest so kubelet starts it as part of control-plane bootstrap
# (kube-vip must exist in /etc/kubernetes/manifests before kubeadm brings
# up the API server — that's why this is a separate step).
#
# ARP mode, --controlplane only (no --services): kube-vip here is scoped
# to control-plane VIP failover, not Service type=LoadBalancer.
#
# Idempotent: overwrites in place with identical content given the same VIP.
set -euo pipefail

VIP="${VIP:?VIP env var required}"
KUBE_VIP_VERSION="${KUBE_VIP_VERSION:-v1.2.1}"
# The kubeadm >=1.29 admin.conf-permissions race (kube-vip#684) only exists
# on the node that runs `kubeadm init` — that's the only place admin.conf's
# RBAC is temporarily restricted while the cluster bootstraps. Nodes that
# join via `kubeadm join --control-plane` inherit an already-fully-reconciled
# RBAC state, admin.conf is fully privileged immediately, and kubeadm doesn't
# even generate super-admin.conf for a join (kube-vip crashloops reading it,
# "no configuration has been provided", if you mount it there by mistake).
# So: the init node mounts super-admin.conf; join nodes mount admin.conf.
KUBECONFIG_SRC="${KUBECONFIG_SRC:-/etc/kubernetes/super-admin.conf}"
IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')

if [[ -z "$IFACE" ]]; then
    echo "!! $(hostname): could not detect default network interface" >&2
    exit 1
fi

mkdir -p /etc/kubernetes/manifests

cat >/etc/kubernetes/manifests/kube-vip.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  name: kube-vip
  namespace: kube-system
  labels:
    component: kube-vip
spec:
  containers:
  - args:
    - manager
    env:
    - name: vip_arp
      value: "true"
    - name: port
      value: "6443"
    - name: vip_interface
      value: ${IFACE}
    - name: vip_subnet
      value: "32"
    - name: cp_enable
      value: "true"
    - name: cp_namespace
      value: kube-system
    - name: vip_ddns
      value: "false"
    - name: svc_enable
      value: "false"
    - name: vip_leaderelection
      value: "true"
    - name: vip_leaseduration
      value: "5"
    - name: vip_renewdeadline
      value: "3"
    - name: vip_retryperiod
      value: "1"
    - name: address
      value: ${VIP}
    image: ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}
    imagePullPolicy: IfNotPresent
    name: kube-vip
    resources: {}
    securityContext:
      capabilities:
        add:
        - NET_ADMIN
        - NET_RAW
        - SYS_TIME
    volumeMounts:
    - mountPath: /etc/kubernetes/admin.conf
      name: kubeconfig
  hostAliases:
  - hostnames:
    - kubernetes
    ip: 127.0.0.1
  hostNetwork: true
  volumes:
  - hostPath:
      # see KUBECONFIG_SRC comment above — super-admin.conf for the init
      # node, admin.conf directly for join nodes.
      path: ${KUBECONFIG_SRC}
      type: FileOrCreate
    name: kubeconfig
status: {}
EOF

echo ">>> $(hostname): kube-vip static pod manifest written (VIP=${VIP}, iface=${IFACE})"
