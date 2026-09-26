# kubeadm-multipass-lab

Real `kubeadm` Kubernetes clusters on [Multipass](https://multipass.run/)
VMs. No k3s, no kind, no pre-baked images — plain `kubeadm init` /
`kubeadm join` / certs on real VMs, the same path a production on-prem
or bare-metal cluster would take.

**`clusters.yaml` is the single source of truth, and `provision.py` is the
only thing that acts on it.** There's no Makefile, no wrapper script —
every operation is `python3 provision.py <command> --cluster <name>`.
Each cluster declares, by name, exactly which nodes should exist and how
they're sized — not a node *count* that gets recomputed on every run
(recomputing from a count is exactly what causes silent drift: change the
count between runs and it computes a different — wrong — node list, with
nothing left over to tell you so). `provision.py` reads `clusters.yaml`,
compares it against what Multipass actually has running, and converges
one towards the other — the same desired-state-vs-actual-state model
Kubernetes controllers use.

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
python3 provision.py up --cluster quick-test        # single control-plane, per the example clusters.yaml
python3 provision.py status --cluster quick-test
python3 provision.py audit --cluster quick-test      # read-only — drift and orphan report, no side effects
python3 provision.py destroy --cluster quick-test
```

```bash
python3 provision.py up --cluster cka-lab            # HA, 3 control planes, per the example clusters.yaml
```

`--config` defaults to `clusters.yaml` in the repo root — pass
`--config path/to/other.yaml` to use a different file.

`up` is idempotent — re-run it after a partial failure and it skips VMs
that already exist, starts any that are `Stopped`, skips bootstrap steps
already done, and regenerates join tokens either way (cheap, avoids
24h/2h expiry surprises). `audit` never modifies anything — it just
reports where reality has drifted from `clusters.yaml` (missing nodes,
stopped nodes, CPU/memory/disk that doesn't match, and orphaned VMs that
exist but aren't declared). `--prune` (on `up`/`destroy`) is the only
thing that removes an orphan, and it's never automatic.

## `clusters.yaml`

Everything lives under a top-level `clusters:` map, keyed by cluster name.
Each cluster is a full declaration of what should exist — nothing is
derived from a count:

```yaml
clusters:
  cka-lab:
    image: "24.04"          # Multipass image alias
    k8s_stream: v1.35        # passed to common-setup.sh, picks the k8s apt/pkg stream

    vip:                      # omit this whole block for a single-CP cluster
      enabled: true
      address: auto           # "auto" pings .200-.210 on the first CP's subnet and
                                # caches the pick in .state/<cluster>/vip; or pin an IP
      provider: kube-vip       # only value supported right now
      version: v1.2.1

    cni:
      type: calico             # only value supported right now
      version: v3.32.1
      pod_cidr: 10.244.0.0/16

    addons:                    # optional, see ADDON_INSTALLERS below
      - name: metrics-server
        enabled: true

    defaults:                  # applied to every node below unless overridden
      cpus: 2
      memory: 2G
      disk: 20G

    control_planes:            # >= 1 required; >1 only takes effect with vip.enabled
      - name: cka-cp1
      - name: cka-cp2
      - name: cka-cp3

    workers:
      - name: cka-w1
      - name: cka-w2
      - name: cka-w3
        memory: 4G            # per-node override — everything else still inherits defaults
```

Rules `provision.py` enforces when it loads this file (`load_clusters()`):

- **Node names must be unique across the entire file**, not just within
  one cluster. This is a real limitation, not an oversight — Multipass has
  no per-cluster namespace on a single host, so `cka-w1` and `quick-test`'s
  own `w1` would collide as the same VM. Pick distinct prefixes per
  cluster (`cka-*`, `qt-*`, ...).
- Every cluster needs at least one entry under `control_planes`.
- `vip.provider` only accepts `kube-vip` and `cni.type` only accepts
  `calico` today — anything else fails fast at load time rather than
  half-provisioning something unsupported.
- A node's `cpus`/`memory`/`disk` fall back to that cluster's `defaults`
  block (itself defaulting to `2` / `2G` / `20G`) — set only what you want
  to override, per node.
- `addons` is just a list of `{name, enabled}`; `install_addons()` looks
  each enabled name up in a small built-in dict, `ADDON_INSTALLERS`, and
  runs its kubectl one-liner on the first control plane. Right now only
  `metrics-server` has an installer — `ingress-nginx` in the `quick-test`
  example will print a skip-warning until one's added.

## How `provision.py` reconciles state

Every command starts the same way: `load_clusters()` parses `clusters.yaml`
into `ClusterConfig`/`NodeSpec` objects, then `mp_list()` (`multipass list
--format=json`) is asked what actually exists. `compute_diff()` compares
the two and produces three lists:

- **`to_create`** — declared nodes with no matching Multipass VM at all.
- **`to_start`** — declared nodes that exist but aren't `Running`.
- **`orphans`** — VMs that exist and *look like* they belong to this
  cluster (a name-prefix heuristic in `_looks_like_ours()`, since
  Multipass doesn't tag VMs by cluster) but aren't declared anywhere in
  `clusters.yaml` for it.

What each command does with that diff:

- **`up`** — launches everything in `to_create`, starts everything in
  `to_start` (deleting orphans first if `--prune` is set), then always
  runs the full bootstrap pipeline in order: `bootstrap_node()` (transfers
  and runs `common-setup.sh` on every node), `detect_or_read_vip()` (only
  if `vip.enabled`), `init_first_cp()` (kubeadm init on the first control
  plane — skipped if `/etc/kubernetes/admin.conf` already exists via
  `cp_is_initialized()`), `join_control_planes()` and `join_workers()`
  (each skipped per-node via `node_has_joined()` checking
  `/etc/kubernetes/kubelet.conf`), `install_cni()`, then
  `install_addons()`. Every step is independently idempotent, so a
  half-failed `up` can just be re-run — join tokens/certificate keys are
  regenerated every time regardless (cheap, and avoids the 24h/2h expiry
  windows).
- **`destroy`** — deletes every node declared for that cluster (skipping
  ones already gone), deletes orphans too if `--prune`, then removes that
  cluster's `.state/<name>/` directory (cached VIP, staged join scripts).
- **`status`** — read-only: prints each declared node's Multipass state
  and whether it's joined the cluster.
- **`audit`** (`-a`) — fully read-only, makes no Multipass calls that
  change anything. For each declared node it prints declared vs. actual
  `cpus`/`memory`/`disk` (parsed and compared with a 5% tolerance via
  `_sizes_match()`, since Multipass can round what you asked for) and
  flags stopped nodes, then lists orphans separately. Exits `1` if
  anything drifted, `0` if everything matches — usable in a script or CI
  check.

## Layout

```
kubeadm-multipass-lab/
├── clusters.yaml           # declared state for every cluster
├── provision.py             # idempotent reconciler — reads clusters.yaml, drives multipass
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
python3 provision.py up --cluster cka-lab
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
python3 provision.py status --cluster <name>
multipass shell <node-name>                     # shell into any node directly
python3 provision.py destroy --cluster <name>   # tear down every node declared for that cluster
python3 provision.py destroy --cluster <name> --prune   # + delete undeclared/orphaned VMs for it
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

multipass stop cka-cp1   # or whichever node currently holds the VIP

# from your host
ping <VIP>                              # keeps answering, reassigned to a survivor
kubectl get nodes                       # the stopped node -> NotReady after ~40s

kubectl -n kube-system exec etcd-cka-cp2 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster
# run this against a SURVIVING node — kubectl exec proxies through that
# node's kubelet, so exec'ing into the stopped node's etcd pod will fail

multipass start cka-cp1
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
