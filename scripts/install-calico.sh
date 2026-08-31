#!/usr/bin/env bash
# install-calico.sh — runs on the first control plane only.
# Installs Calico via the Tigera operator (stable path, not the v3-CRD
# tech-preview path). Idempotent via kubectl apply.
set -euo pipefail

CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
export KUBECONFIG=/etc/kubernetes/admin.conf

BASE_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"

echo ">>> installing tigera-operator (${CALICO_VERSION})"
kubectl apply -f "${BASE_URL}/tigera-operator.yaml"

echo ">>> waiting for tigera-operator deployment to be available"
kubectl -n tigera-operator rollout status deployment/tigera-operator --timeout=180s

# tigera-operator.yaml does NOT bundle the operator.tigera.io CRDs — the
# operator installs them itself on startup (-manage-crds=true). Applying
# custom-resources.yaml too early races the operator and fails with
# "no matches for kind Installation ... ensure CRDs are installed first".
echo ">>> waiting for operator to register its CRDs"
for crd in installations.operator.tigera.io apiservers.operator.tigera.io \
           goldmanes.operator.tigera.io whiskers.operator.tigera.io; do
    for i in $(seq 1 30); do
        kubectl get crd "$crd" >/dev/null 2>&1 && break
        sleep 5
    done
    kubectl wait --for=condition=Established "crd/${crd}" --timeout=60s
done

echo ">>> fetching custom-resources.yaml and patching pod CIDR to ${POD_CIDR}"
curl -fsSL "${BASE_URL}/custom-resources.yaml" -o /tmp/custom-resources.yaml
sed -i "s#cidr: 192.168.0.0/16#cidr: ${POD_CIDR}#" /tmp/custom-resources.yaml
kubectl apply -f /tmp/custom-resources.yaml

echo ">>> waiting for tigera status to report Available (this can take a few minutes)"
for i in $(seq 1 30); do
    if kubectl get tigerastatus >/dev/null 2>&1; then
        NOT_READY=$(kubectl get tigerastatus -o jsonpath='{.items[?(@.status.conditions[0].status!="True")].metadata.name}' 2>/dev/null || echo "unknown")
        if [[ -z "$NOT_READY" ]]; then
            echo ">>> all tigerastatus components available"
            kubectl get tigerastatus
            break
        fi
    fi
    sleep 10
done

kubectl get tigerastatus || true
echo ">>> Calico install step complete"
echo ">>> NOTE: on small nodes (2GB or less), the Goldmane/Whisker observability"
echo "    add-ons shipped in custom-resources.yaml can add memory pressure on top"
echo "    of etcd/kube-apiserver/kube-vip on control-plane nodes. If pods stay"
echo "    Pending, remove them (kubectl delete goldmane default / kubectl delete"
echo "    whisker default) — networking + NetworkPolicy don't depend on them."
