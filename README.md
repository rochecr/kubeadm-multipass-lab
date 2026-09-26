# kubeadm-multipass-lab

Real `kubeadm` Kubernetes clusters on [Multipass](https://multipass.run/)
VMs. No k3s, no kind, no pre-baked images — plain `kubeadm init` /
`kubeadm join` / certs on real VMs, the same path a production on-prem
or bare-metal cluster would take.

**`clusters.yaml` is the single source of truth.** Every cluster you want
declares, by name, exactly which nodes should exist and how they're
sized — not a node *count* that gets recomputed from Makefile variables
each run (that recomputation is exactly what causes silent drift: run
`make destroy` with different variables than what created the cluster,
and it computes a different — wrong — node list). `provision.py` reads
that file, compares it against what Multipass actually has running, and
converges one towards the other — the same desired-state-vs-actual-state
model Kubernetes controllers use.

A cluster with one control plane and no `vip:` block is a plain single-CP
cluster. A cluster with `vip.enabled: true` and more than one entry under
`control_planes` gets a highly-available control plane, stacked etcd,
fronted by [kube-vip](https://kube-vip.io/) (ARP mode). Both shapes run
through the exact same code path — nothing is duplicated.

## Prerequisites

- [Multipass](https://multipass.run/) installed and working
  (`multipass launch ...` should already work before you touch this repo)
- Python 3.9+ with PyYAML: `pip install pyyaml`
- `kubectl` (for cluster interaction once it's up)
- Enough host resources for however many VMs your cluster declares

## Quick start

```bash
make up CLUSTER=quick-test      # single control-plane, per the example clusters.yaml
make status CLUSTER=quick-test
make audit CLUSTER=quick-test   # read-only — drift and orphan report, no side effects
make destroy CLUSTER=quick-test
```

```bash
make up CLUSTER=cka-lab         # HA, 3 control planes, per the example clusters.yaml
```

`make up` is idempotent — re-run it after a partial failure and it skips
VMs that already exist, starts any that are `Stopped`, skips bootstrap
steps already done, and regenerates join tokens either way (cheap, avoids
24h/2h expiry surprises). `make audit CLUSTER=<name>` never modifies
anything — it just reports where reality has drifted from `clusters.yaml`
(missing nodes, stopped nodes, CPU/memory/disk that doesn't match, and
orphaned VMs that exist but aren't declared). `--prune` (as
`PRUNE=1` on `make up`/`make destroy`) is the only thing that removes an
orphan, and it's never automatic.

See `clusters.yaml` for the full schema — `vip`, `cni`, `addons`,
per-node `cpus`/`memory`/`disk` overrides on top of a cluster-wide
`defaults` block.

## Layout

```
kubeadm-multipass-lab/
├── clusters.yaml           # declared state for every cluster
├── provision.py             # idempotent reconciler — reads clusters.yaml, drives multipass
├── Makefile                  # thin wrapper: make {up,destroy,status,audit} CLUSTER=<name>
├── scripts/
│   ├── common-setup.sh      # runs on every node
│   ├── write-kube-vip.sh    # runs on control-plane nodes, before init/join (HA only)
│   ├── init-first-cp.sh     # runs on the first control-plane node only
│   └── install-calico.sh    # runs on the first control-plane node only
└── .state/<cluster-name>/    # gitignored: per-cluster VIP + join command staging
```

## Adding a node later

Add an entry under `workers:` (or `control_planes:`) in `clusters.yaml`
— any size you want, independent of that cluster's `defaults` — then:

```bash
make up CLUSTER=cka-lab
```

`provision.py` diffs the file against what's actually running and only
creates/bootstraps/joins the new node; everything already converged is
left alone. It also labels new workers with
`node-role.kubernetes.io/worker=` automatically — `kubeadm` never does
this itself (only control-plane nodes get an automatic role label), so
without it `kubectl get nodes` would show `ROLES=<none>` for every
worker.

## Other commands

```bash
make status CLUSTER=<name>
multipass shell <node-name>     # shell into any node directly
make destroy            # tear everything down, including add-worker nodes
```

## Why kube-vip instead of HAProxy+keepalived (HA mode)

Both are legitimate ways to give an HA `kubeadm` cluster a stable
`--control-plane-endpoint`:

- **HAProxy + keepalived** — the traditional approach from the
  [kubeadm HA topology guide](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/).
  Two daemons: keepalived owns the floating IP (VRRP), haproxy
  load-balances TCP/6443 across the control-plane nodes. Well
  understood, but it's two separate configs that can drift out of sync
  with each other and with your node list.
- **kube-vip** — one static pod per control-plane node that does VIP
  failover *and* API-server load-balancing in a single binary. No extra
  VM, one manifest. This is the option kubernetes.io's own HA topology
  page lists as the modern alternative, and it's what this repo uses.

kube-vip here is scoped to `--controlplane` only (`svc_enable=false`) —
it does not also handle `Service type=LoadBalancer` traffic.

## Testing control-plane failover (HA mode)

```bash
# find who currently holds the VIP
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'; echo

multipass stop k8s-cp1   # or whichever node currently holds the VIP

# from your host
ping <VIP>                              # keeps answering, reassigned to a survivor
kubectl get nodes                       # the stopped node -> NotReady after ~40s

kubectl -n kube-system exec etcd-k8s-cp2 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster
# run this against a SURVIVING node — kubectl exec proxies through that
# node's kubelet, so exec'ing into the stopped node's etcd pod will fail

multipass start k8s-cp1
```

etcd tolerates 1 of N members down without losing quorum (needs a
majority); losing more than that makes the API server read-only or
fully unavailable.

## Troubleshooting

- Kubelet won't come up post-join: `journalctl -u kubelet -f`, then
  `crictl ps -a` / `crictl logs <id>`. `crictl` isn't installed by
  `common-setup.sh` — grab it first:
  ```bash
  VER=v1.31.1
  curl -fsSL -o crictl.tar.gz \
    https://github.com/kubernetes-sigs/cri-tools/releases/download/${VER}/crictl-${VER}-linux-amd64.tar.gz
  sudo tar zxf crictl.tar.gz -C /usr/local/bin && rm crictl.tar.gz
  sudo crictl config --set runtime-endpoint=unix:///var/run/containerd/containerd.sock
  ```
- kube-vip crashlooping (HA mode only) — which mount is wrong depends
  on which node:
  - **First control plane**, `Forbidden` errors creating the
    leader-election Lease: needs `super-admin.conf`, not `admin.conf`
    (the kubeadm ≥1.29 RBAC-bootstrap race — `admin.conf`'s RBAC isn't
    fully reconciled until *after* the control plane is up, but kube-vip
    needs cluster-admin immediately).
  - **Additional control planes**, `no configuration has been provided`
    with `Completed` (exit 0, not a crash) and a **0-byte, 644** file at
    `/etc/kubernetes/super-admin.conf`: `kubeadm join` never populates
    that file — it needs `admin.conf` directly instead. (A real
    `kubeadm`-written kubeconfig is always `600`; `644` is your tell
    that nothing ever wrote to it.)
- `kubeadm init`/`join` half-failed and you need a clean retry:
  `sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d ~/.kube/config`,
  then re-run. If it was a control-plane join that partially succeeded,
  `kubectl delete node <name>` from a healthy control plane afterward.
- etcd quorum lost (majority of control-plane nodes down, HA mode):
  the API server becomes read-only or fully unavailable. Bring back at
  least enough nodes to reach a majority again — there's no way around
  needing one.
- Join token expired (>24h old): `kubeadm token create --print-join-command`
  regenerates it, no need to re-init.
- Certificate key expired (>2h old, HA mode): re-run
  `sudo kubeadm init phase upload-certs --upload-certs` on any healthy
  control-plane node to mint a new one.

## License

MIT — see [LICENSE](LICENSE).
