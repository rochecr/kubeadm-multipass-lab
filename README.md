# kubeadm-multipass-lab

Real `kubeadm` Kubernetes clusters on [Multipass](https://multipass.run/)
VMs, one `make up` away. No k3s, no kind, no pre-baked images — plain
`kubeadm init` / `kubeadm join` / certs on real VMs, the same path a
production on-prem or bare-metal cluster would take.

One Makefile, two shapes, controlled by a single variable:

- **`CP_COUNT=1`** (default) — a single control-plane node, no VIP, no
  load balancer. The simplest possible real cluster, good for anything
  that doesn't care about control-plane HA: trying out a CRD, a Helm
  chart, an admission webhook, a CNI feature, generic workload testing.
- **`CP_COUNT>1`** — a highly-available control plane, stacked etcd,
  fronted by [kube-vip](https://kube-vip.io/) (ARP mode) providing a
  floating VIP across however many control-plane nodes you ask for. Good
  for anything that specifically needs to exercise HA behavior: control-plane
  failover, etcd quorum loss, testing tooling against a realistic
  multi-master topology.

Both shapes share the exact same scripts and Makefile targets — nothing
is duplicated between them.

## Prerequisites

- [Multipass](https://multipass.run/) installed and working
  (`multipass launch ...` should already work before you touch this repo)
- `kubectl` (for `make verify` and general cluster interaction)
- Enough host resources for however many VMs you ask for — each defaults
  to 2 vCPU / 2GB RAM / 20GB disk (`CPUS`/`MEM`/`DISK`, overridable)

## Quick start

Simple, single control-plane:

```bash
make up                          # 1 control plane + 2 workers, no VIP
make kubeconfig
export KUBECONFIG=$PWD/kubeconfig
make verify
make destroy
```

HA, three control planes:

```bash
make up CP_COUNT=3 WORKER_COUNT=2
make kubeconfig
export KUBECONFIG=$PWD/kubeconfig
make verify
make destroy
```

Every value is overridable — `CP_COUNT`, `WORKER_COUNT`, `NAME_PREFIX`,
`CPUS`, `MEM`, `DISK`, `K8S_STREAM`, `POD_CIDR`, `CALICO_VERSION`,
`KUBE_VIP_VERSION`, `VIP`. `make help` prints the current effective
config and a couple of examples.

`make up` is idempotent — re-run it after a partial failure and it skips
VMs that already exist, nodes already bootstrapped, a first control
plane already initialized, and any control plane/worker already joined.
In HA mode it also auto-picks a free VIP from the first control plane's
subnet the first time it runs and caches it in `.state/vip` — override
with `make up VIP=192.168.64.200` if the auto-pick collides with
something else on your LAN.

## Layout

```
kubeadm-multipass-lab/
├── Makefile
├── scripts/
│   ├── common-setup.sh     # runs on every node
│   ├── write-kube-vip.sh   # runs on control-plane nodes, before init/join (HA only)
│   ├── init-first-cp.sh    # runs on the first control-plane node only
│   └── install-calico.sh   # runs on the first control-plane node only
├── verify.sh
└── .state/                  # gitignored: VIP + join command staging
```

## Adding a node later

Works the same in either mode — add a worker of any size, independent
of the fleet's default sizing:

```bash
make add-worker NAME=k8s-w3 ADD_MEM=4G
```

Idempotent, tracked in `.state/extra-nodes` so `make destroy` tears it
down too. `kubeadm` never auto-labels worker nodes with a role (only
control-plane nodes get one automatically) — `add-worker` sets
`node-role.kubernetes.io/worker=` for you so `kubectl get nodes` doesn't
show `ROLES=<none>`.

## Other targets

```bash
make status             # multipass list
make ssh NAME=k8s-cp1   # shell into any node
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
