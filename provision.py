#!/usr/bin/env python3
"""
provision.py — idempotent reconciler for kubeadm-on-Multipass clusters
declared in clusters.yaml.

Design: clusters.yaml is the single source of truth for which nodes
should exist and how they're sized. This script diffs that declared
state against what Multipass actually has running and converges one
towards the other — the same "desired state vs actual state" model
Kubernetes controllers use, deliberately.

Commands:
    provision.py up      --cluster NAME [--prune]
    provision.py destroy --cluster NAME [--prune]
    provision.py status  --cluster NAME
    provision.py audit   --cluster NAME      (alias: -a)   # read-only, no side effects

Requires: PyYAML (`pip install pyyaml`), the `multipass` CLI, and
`kubectl`/`ssh` are NOT required on the host — everything runs through
`multipass exec`.

NOTE on `multipass info --format=json`: the exact field names
(cpu_count, memory_total, disk_total, ...) can vary a little across
Multipass versions. The drift check below is best-effort and degrades
gracefully (reports "unknown" rather than crashing) if a field isn't
where expected — run `multipass info <node> --format=json` yourself
once if the CPU/memory drift columns look wrong, and adjust
`_parse_info()` to match your installed version.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

try:
    import yaml
except ImportError:
    sys.exit("!! PyYAML is required: pip install pyyaml")

REPO_ROOT = Path(__file__).resolve().parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
STATE_ROOT = REPO_ROOT / ".state"


# --- data model --------------------------------------------------------------

@dataclass
class NodeSpec:
    name: str
    role: str  # "control-plane" | "worker"
    cpus: str
    memory: str
    disk: str


@dataclass
class VipConfig:
    enabled: bool = False
    address: str = "auto"
    provider: str = "kube-vip"
    version: str = "v1.2.1"


@dataclass
class CniConfig:
    type: str = "calico"
    version: str = "v3.32.1"
    pod_cidr: str = "10.244.0.0/16"


@dataclass
class ClusterConfig:
    name: str
    image: str
    k8s_stream: str
    vip: VipConfig
    cni: CniConfig
    addons: list[dict]
    nodes: list[NodeSpec]

    @property
    def control_planes(self) -> list[NodeSpec]:
        return [n for n in self.nodes if n.role == "control-plane"]

    @property
    def workers(self) -> list[NodeSpec]:
        return [n for n in self.nodes if n.role == "worker"]

    @property
    def first_cp(self) -> NodeSpec:
        return self.control_planes[0]

    @property
    def state_dir(self) -> Path:
        d = STATE_ROOT / self.name
        d.mkdir(parents=True, exist_ok=True)
        return d


# --- config loading -----------------------------------------------------------

def load_clusters(config_path: Path) -> dict[str, ClusterConfig]:
    raw = yaml.safe_load(config_path.read_text())
    clusters_raw = raw.get("clusters", {})

    clusters: dict[str, ClusterConfig] = {}
    seen_node_names: dict[str, str] = {}  # node name -> cluster name, for uniqueness check

    for cluster_name, spec in clusters_raw.items():
        defaults = spec.get("defaults", {})
        default_cpus = str(defaults.get("cpus", 2))
        default_mem = str(defaults.get("memory", "2G"))
        default_disk = str(defaults.get("disk", "20G"))

        nodes: list[NodeSpec] = []
        for role, key in (("control-plane", "control_planes"), ("worker", "workers")):
            for entry in spec.get(key, []):
                name = entry["name"]
                if name in seen_node_names:
                    sys.exit(
                        f"!! node name '{name}' is declared in both "
                        f"'{seen_node_names[name]}' and '{cluster_name}' — "
                        f"node names must be unique across the whole file "
                        f"(Multipass has no per-cluster namespacing on a single host)"
                    )
                seen_node_names[name] = cluster_name
                nodes.append(NodeSpec(
                    name=name,
                    role=role,
                    cpus=str(entry.get("cpus", default_cpus)),
                    memory=str(entry.get("memory", default_mem)),
                    disk=str(entry.get("disk", default_disk)),
                ))

        vip_raw = spec.get("vip") or {}
        vip = VipConfig(
            enabled=bool(vip_raw.get("enabled", False)),
            address=str(vip_raw.get("address", "auto")),
            provider=str(vip_raw.get("provider", "kube-vip")),
            version=str(vip_raw.get("version", "v1.2.1")),
        )
        if vip.provider != "kube-vip":
            sys.exit(f"!! vip.provider '{vip.provider}' not supported yet — only 'kube-vip'")

        cni_raw = spec.get("cni") or {}
        cni = CniConfig(
            type=str(cni_raw.get("type", "calico")),
            version=str(cni_raw.get("version", "v3.32.1")),
            pod_cidr=str(cni_raw.get("pod_cidr", "10.244.0.0/16")),
        )
        if cni.type != "calico":
            sys.exit(f"!! cni.type '{cni.type}' not supported yet — only 'calico'")

        if len(nodes) == 0 or len([n for n in nodes if n.role == "control-plane"]) == 0:
            sys.exit(f"!! cluster '{cluster_name}' needs at least one control_planes entry")

        clusters[cluster_name] = ClusterConfig(
            name=cluster_name,
            image=str(spec.get("image", "24.04")),
            k8s_stream=str(spec.get("k8s_stream", "v1.34")),
            vip=vip,
            cni=cni,
            addons=spec.get("addons", []) or [],
            nodes=nodes,
        )

    return clusters


# --- multipass CLI wrapper -----------------------------------------------------

def mp(*args: str, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    cmd = ["multipass", *args]
    return subprocess.run(cmd, check=check, text=True,
                           capture_output=capture)


def mp_list() -> dict[str, dict]:
    """Returns {node_name: {"state": ..., "ipv4": [...], "release": ...}}."""
    result = mp("list", "--format=json", capture=True)
    data = json.loads(result.stdout)
    return {item["name"]: item for item in data.get("list", [])}


def mp_info(name: str) -> Optional[dict]:
    """Best-effort info fetch. Returns None if the node doesn't exist."""
    result = mp("info", name, "--format=json", check=False, capture=True)
    if result.returncode != 0:
        return None
    data = json.loads(result.stdout)
    return data.get("info", {}).get(name)


def _parse_size(s) -> Optional[int]:
    """Parse '2G' / '512M' / a raw byte count (int or numeric string) into
    bytes. Returns None if unparseable."""
    if s is None:
        return None
    s = str(s).strip()
    try:
        return int(s)  # already raw bytes
    except ValueError:
        pass
    units = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
    if s and s[-1].upper() in units:
        try:
            return int(float(s[:-1]) * units[s[-1].upper()])
        except ValueError:
            return None
    return None


def _human_size(n: Optional[int]) -> str:
    if n is None:
        return "?"
    for unit, factor in (("G", 1024**3), ("M", 1024**2)):
        if n >= factor:
            val = n / factor
            return f"{val:.0f}{unit}" if val == int(val) else f"{val:.1f}{unit}"
    return f"{n}B"


def _parse_info(info: dict) -> dict:
    """Best-effort normalization of `multipass info --format=json` fields.
    Field names/types have varied across Multipass releases — this degrades
    to None rather than raising if something's not where expected. Sizes
    are normalized to bytes (int) so they can actually be compared against
    the declared '2G'-style strings from clusters.yaml."""
    def g(*keys):
        for k in keys:
            if k in info:
                return info[k]
        return None

    return {
        "cpus": g("cpu_count"),
        "memory_total": _parse_size(g("memory_total")),
        "disk_total": _parse_size(g("disk_total")),
        "state": g("state"),
    }


def mp_launch(node: NodeSpec, image: str):
    print(f">>> launching {node.name} ({image}, {node.cpus} vCPU, {node.memory}, {node.disk})")
    mp("launch", image, "--name", node.name,
       "--cpus", node.cpus, "--memory", node.memory, "--disk", node.disk)
    mp("exec", node.name, "--", "cloud-init", "status", "--wait", check=False)


def mp_start(node_name: str):
    print(f">>> starting {node_name}")
    mp("start", node_name)


def mp_delete(node_name: str):
    print(f">>> deleting {node_name}")
    mp("delete", "--purge", node_name)


def mp_transfer(local_path: Path, node_name: str, remote_path: str):
    mp("transfer", str(local_path), f"{node_name}:{remote_path}")


def mp_exec(node_name: str, remote_cmd: list[str], env: Optional[dict] = None, check: bool = True):
    prefix = ["sudo"]
    if env:
        # one `env` call with all VAR=val pairs, not repeated per variable
        prefix += ["env"] + [f"{k}={v}" for k, v in env.items()]
    cmd = ["exec", node_name, "--"] + prefix + remote_cmd
    return mp(*cmd, check=check)


def node_has_joined(node_name: str) -> bool:
    result = mp("exec", node_name, "--", "test", "-f", "/etc/kubernetes/kubelet.conf",
                check=False)
    return result.returncode == 0


def cp_is_initialized(node_name: str) -> bool:
    result = mp("exec", node_name, "--", "test", "-f", "/etc/kubernetes/admin.conf",
                check=False)
    return result.returncode == 0


# --- diff / audit ---------------------------------------------------------------

def compute_diff(cluster: ClusterConfig, actual: dict[str, dict]):
    declared_names = {n.name for n in cluster.nodes}
    to_create = [n for n in cluster.nodes if n.name not in actual]
    to_start = [n for n in cluster.nodes if n.name in actual and actual[n.name]["state"] != "Running"]
    orphans = sorted(name for name in actual if name not in declared_names
                      and _looks_like_ours(name, cluster))
    return to_create, to_start, orphans


def _looks_like_ours(name: str, cluster: ClusterConfig) -> bool:
    """Heuristic so `audit`/`--prune` on one cluster doesn't flag every other
    VM on the box as an orphan. Matches on a shared prefix with declared
    node names — not perfect, but this script has no other way to know
    which cluster a stray VM 'belongs' to, since Multipass itself doesn't
    tag them. Adjust if your naming convention differs."""
    declared = [n.name for n in cluster.nodes]
    if not declared:
        return False
    # common prefix trick: strip trailing digits/role suffix, compare stems
    import re
    stems = {re.sub(r"(cp|w)\d*$", "", n) for n in declared}
    return any(name.startswith(stem) for stem in stems if stem)


def _sizes_match(declared_str: str, actual_bytes: Optional[int], tolerance: float = 0.05) -> bool:
    """Multipass can round what you asked for slightly, so compare with a
    small tolerance rather than requiring an exact byte match."""
    declared_bytes = _parse_size(declared_str)
    if declared_bytes is None or actual_bytes is None:
        return True  # can't compare -> don't report false drift
    return abs(actual_bytes - declared_bytes) <= declared_bytes * tolerance


def audit(cluster: ClusterConfig) -> int:
    actual = mp_list()
    print(f"cluster: {cluster.name}\n")
    # fixed-width columns with an explicit gap, so overflowing content never
    # visually glues into the next column
    row = "{:<12}  {:<18}  {:<30}  {}"
    print(row.format("NODE", "DECLARADO", "REAL", "ESTADO"))
    drift = False

    for node in cluster.nodes:
        declared = f"{node.cpus}cpu/{node.memory}/{node.disk}"
        if node.name not in actual:
            print(row.format(node.name, declared, "-", "FALTA (no existe)"))
            drift = True
            continue

        info = mp_info(node.name) or {}
        parsed = _parse_info(info)
        state = actual[node.name]["state"]
        cpus_disp = parsed["cpus"] if parsed["cpus"] is not None else "?"
        mem_disp = _human_size(parsed["memory_total"])
        disk_disp = _human_size(parsed["disk_total"])
        real = f"{cpus_disp}cpu/{mem_disp}/{disk_disp}, {state}"

        problems = []
        if state != "Running":
            problems.append("stopped (se esperaba running)")
        if parsed["cpus"] is not None and str(parsed["cpus"]) != str(node.cpus):
            problems.append("drift: cpu")
        if not _sizes_match(node.memory, parsed["memory_total"]):
            problems.append("drift: memory")
        if not _sizes_match(node.disk, parsed["disk_total"]):
            problems.append("drift: disk")

        if problems:
            drift = True
        status = "ok" if not problems else " / ".join(problems)
        print(row.format(node.name, declared, real, status))

    _, _, orphans = compute_diff(cluster, actual)
    print("\nnodos huérfanos (existen en Multipass, no declarados aquí):")
    if orphans:
        drift = True
        for o in orphans:
            print(f"  {o}   {actual[o]['state']}   -- no está en clusters.yaml, usá --prune para eliminarlo")
    else:
        print("  (ninguno)")

    return 1 if drift else 0


# --- bootstrap steps (mirrors the Makefile's targets) ---------------------------

def bootstrap_node(node: NodeSpec, cluster: ClusterConfig):
    print(f">>> bootstrapping {node.name}")
    mp_transfer(SCRIPTS_DIR / "common-setup.sh", node.name, "/tmp/common-setup.sh")
    mp_exec(node.name, ["bash", "/tmp/common-setup.sh"], env={"K8S_STREAM": cluster.k8s_stream})


def detect_or_read_vip(cluster: ClusterConfig) -> Optional[str]:
    if not cluster.vip.enabled:
        return None
    vip_file = cluster.state_dir / "vip"
    if cluster.vip.address != "auto":
        vip_file.write_text(cluster.vip.address)
        return cluster.vip.address
    if vip_file.exists():
        return vip_file.read_text().strip()

    info = mp_info(cluster.first_cp.name) or {}
    # multipass list carries ipv4 more reliably than info across versions
    actual = mp_list()
    ipv4_list = actual.get(cluster.first_cp.name, {}).get("ipv4", [])
    if not ipv4_list:
        sys.exit(f"!! could not read {cluster.first_cp.name}'s IP to auto-pick a VIP")
    subnet = ".".join(ipv4_list[0].split(".")[:3])
    import subprocess as sp
    for host in range(200, 211):
        candidate = f"{subnet}.{host}"
        ping = sp.run(["ping", "-c1", "-W1", candidate], capture_output=True)
        if ping.returncode != 0:
            vip_file.write_text(candidate)
            print(f">>> auto-picked VIP {candidate} (override in clusters.yaml if this collides with your LAN)")
            return candidate
    sys.exit(f"!! could not auto-pick a free VIP in {subnet}.0/24 — set vip.address explicitly")


def write_kube_vip(node: NodeSpec, cluster: ClusterConfig, vip: str, is_first_cp: bool):
    mp_transfer(SCRIPTS_DIR / "write-kube-vip.sh", node.name, "/tmp/write-kube-vip.sh")
    env = {
        "VIP": vip,
        "KUBE_VIP_VERSION": cluster.vip.version,
    }
    if not is_first_cp:
        env["KUBECONFIG_SRC"] = "/etc/kubernetes/admin.conf"
    mp_exec(node.name, ["bash", "/tmp/write-kube-vip.sh"], env=env)


def init_first_cp(cluster: ClusterConfig, vip: Optional[str]):
    node = cluster.first_cp
    if cp_is_initialized(node.name):
        print(f">>> {node.name} already initialized, skipping kubeadm init "
              f"(join commands are regenerated below regardless — cheap, avoids expiry issues)")
    if cluster.vip.enabled:
        write_kube_vip(node, cluster, vip, is_first_cp=True)

    mp_transfer(SCRIPTS_DIR / "init-first-cp.sh", node.name, "/tmp/init-first-cp.sh")
    env = {
        "CP_COUNT": str(len(cluster.control_planes)),
        "POD_CIDR": cluster.cni.pod_cidr,
        "NODE_NAME": node.name,
    }
    if cluster.vip.enabled:
        env["VIP"] = vip
    mp_exec(node.name, ["bash", "/tmp/init-first-cp.sh"], env=env)

    # pull join commands to this cluster's own state dir
    join_worker = cluster.state_dir / "kubeadm-join-worker.sh"
    mp("transfer", f"{node.name}:/tmp/kubeadm-join-worker.sh", str(join_worker))
    if len(cluster.control_planes) > 1:
        join_cp = cluster.state_dir / "kubeadm-join-cp.sh"
        mp("transfer", f"{node.name}:/tmp/kubeadm-join-cp.sh", str(join_cp))


def join_control_planes(cluster: ClusterConfig, vip: Optional[str]):
    others = cluster.control_planes[1:]
    if not others:
        return
    join_cp_file = cluster.state_dir / "kubeadm-join-cp.sh"
    if not join_cp_file.exists():
        sys.exit("!! join-cp script missing — did init_first_cp run first?")
    for node in others:
        write_kube_vip(node, cluster, vip, is_first_cp=False)
        if node_has_joined(node.name):
            print(f">>> {node.name} already joined, skipping")
            continue
        print(f">>> joining {node.name} as control-plane")
        mp_transfer(join_cp_file, node.name, "/tmp/kubeadm-join-cp.sh")
        mp_exec(node.name, ["bash", "/tmp/kubeadm-join-cp.sh"])


def join_workers(cluster: ClusterConfig):
    join_worker_file = cluster.state_dir / "kubeadm-join-worker.sh"
    if not join_worker_file.exists():
        sys.exit("!! join-worker script missing — did init_first_cp run first?")
    for node in cluster.workers:
        if node_has_joined(node.name):
            print(f">>> {node.name} already joined, skipping")
        else:
            print(f">>> joining {node.name} as worker")
            mp_transfer(join_worker_file, node.name, "/tmp/kubeadm-join-worker.sh")
            mp_exec(node.name, ["bash", "/tmp/kubeadm-join-worker.sh"])
        mp_exec(cluster.first_cp.name,
                ["kubectl", "--kubeconfig=/etc/kubernetes/admin.conf",
                 "label", "node", node.name,
                 "node-role.kubernetes.io/worker=", "--overwrite"],
                check=False)


def install_cni(cluster: ClusterConfig):
    node = cluster.first_cp
    print(f">>> installing CNI ({cluster.cni.type} {cluster.cni.version})")
    mp_transfer(SCRIPTS_DIR / "install-calico.sh", node.name, "/tmp/install-calico.sh")
    mp_exec(node.name, ["bash", "/tmp/install-calico.sh"],
            env={"CALICO_VERSION": cluster.cni.version, "POD_CIDR": cluster.cni.pod_cidr})


# minimal built-in addon registry — each entry is a kubectl one-liner run on
# the first control plane. Extend this dict as you add more.
ADDON_INSTALLERS = {
    "metrics-server": (
        "kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f "
        "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    ),
}


def install_addons(cluster: ClusterConfig):
    node = cluster.first_cp
    for addon in cluster.addons:
        name = addon.get("name")
        if not addon.get("enabled", False):
            continue
        installer = ADDON_INSTALLERS.get(name)
        if not installer:
            print(f"!! addon '{name}' has no registered installer yet — skipping "
                  f"(known: {', '.join(ADDON_INSTALLERS)})")
            continue
        print(f">>> installing addon: {name}")
        mp_exec(node.name, installer.split())


# --- top-level commands ----------------------------------------------------------

def cmd_status(cluster: ClusterConfig):
    actual = mp_list()
    print(f"cluster: {cluster.name}")
    for node in cluster.nodes:
        state = actual.get(node.name, {}).get("state", "MISSING")
        joined = node_has_joined(node.name) if node.name in actual and state == "Running" else "?"
        print(f"  {node.name:<12} {node.role:<15} {state:<10} joined={joined}")


def cmd_up(cluster: ClusterConfig, prune: bool):
    actual = mp_list()
    to_create, to_start, orphans = compute_diff(cluster, actual)

    for node in to_create:
        mp_launch(node, cluster.image)
    for node in to_start:
        mp_start(node.name)
        mp("exec", node.name, "--", "cloud-init", "status", "--wait", check=False)

    if prune and orphans:
        for name in orphans:
            mp_delete(name)

    for node in cluster.nodes:
        bootstrap_node(node, cluster)

    vip = detect_or_read_vip(cluster)
    init_first_cp(cluster, vip)
    if cluster.vip.enabled:
        join_control_planes(cluster, vip)
    join_workers(cluster)
    install_cni(cluster)
    install_addons(cluster)

    print(f"\n>>> cluster '{cluster.name}' converged to desired state.")
    if cluster.vip.enabled:
        print(f">>> VIP: {vip}")
    print(">>> pull a kubeconfig with:")
    print(f"    multipass exec {cluster.first_cp.name} -- sudo cat /etc/kubernetes/admin.conf "
          f"> {cluster.name}.kubeconfig")


def cmd_destroy(cluster: ClusterConfig, prune: bool):
    actual = mp_list()
    for node in cluster.nodes:
        if node.name in actual:
            mp_delete(node.name)
        else:
            print(f">>> {node.name} not found, skipping")
    if prune:
        _, _, orphans = compute_diff(cluster, actual)
        for name in orphans:
            mp_delete(name)
    import shutil
    shutil.rmtree(cluster.state_dir, ignore_errors=True)
    print(f">>> cluster '{cluster.name}' destroyed")


# --- CLI ---------------------------------------------------------------------------

def main():
    # A plain positional `command` (not argparse subparsers) so --cluster/
    # --prune/--config work regardless of whether they're typed before or
    # after the command — `provision.py up --cluster x` and
    # `provision.py --cluster x up` both work.
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=["up", "destroy", "status", "audit", "a"])
    parser.add_argument("--config", default=str(REPO_ROOT / "clusters.yaml"))
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--prune", action="store_true",
                         help="also remove nodes that exist in Multipass but aren't declared")

    args = parser.parse_args()

    clusters = load_clusters(Path(args.config))
    if args.cluster not in clusters:
        sys.exit(f"!! cluster '{args.cluster}' not found in {args.config} "
                  f"(known: {', '.join(clusters)})")
    cluster = clusters[args.cluster]

    if args.command == "status":
        cmd_status(cluster)
    elif args.command in ("audit", "a"):
        sys.exit(audit(cluster))
    elif args.command == "up":
        cmd_up(cluster, prune=args.prune)
    elif args.command == "destroy":
        cmd_destroy(cluster, prune=args.prune)


if __name__ == "__main__":
    main()
