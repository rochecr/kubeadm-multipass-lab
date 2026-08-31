#!/usr/bin/env bash
# verify.sh — run from the host with KUBECONFIG pointed at ./kubeconfig
# (make verify does this for you). Works for any CP_COUNT/WORKER_COUNT —
# discovers the first control-plane node and expected node count from
# the live cluster rather than assuming fixed names.
set -euo pipefail

echo "=== 1/4 Nodes ==="
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get nodes -o wide
CP_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
CP_TOTAL=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
echo ">>> using $CP_NODE as the etcd/API check target ($CP_TOTAL control-plane node(s) total)"

echo ""
echo "=== 2/4 CoreDNS ==="
kubectl -n kube-system rollout status deploy/coredns --timeout=180s
kubectl get pods -n kube-system -l k8s-app=kube-dns

echo ""
echo "=== 3/4 etcd ==="
kubectl -n kube-system exec "etcd-${CP_NODE}" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    member list -w table
# Expected: $CP_TOTAL member(s), all "started"

echo ""
echo "=== 4/4 Test workload (nginx) ==="
kubectl run verify-nginx --image=nginx:stable --restart=Never
kubectl wait --for=condition=Ready pod/verify-nginx --timeout=120s
kubectl get pod verify-nginx -o wide

echo ">>> cleaning up test pod"
kubectl delete pod verify-nginx --wait=true

echo ""
echo ">>> ALL CHECKS PASSED"
