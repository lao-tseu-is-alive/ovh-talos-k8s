#!/usr/bin/env python3
"""Validate config.yaml and render non-secret Talos bootstrap inputs."""

from __future__ import annotations

import argparse
import ipaddress
import os
import stat
import sys
from pathlib import Path
from urllib.parse import urlparse

import yaml


def fail(message: str) -> None:
    raise ValueError(message)


def required(mapping: dict, key: str, path: str):
    if key not in mapping or mapping[key] in (None, ""):
        fail(f"missing {path}.{key}")
    return mapping[key]


def load_and_validate(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as stream:
        config = yaml.safe_load(stream)

    if not isinstance(config, dict):
        fail("config root must be a mapping")

    versions = required(config, "versions", "config")
    for name in (
        "talos",
        "kubernetes",
        "cilium",
        "longhorn",
        "snapshot_controller",
    ):
        required(versions, name, "versions")

    image_factory = required(config, "image_factory", "config")
    schematic = required(image_factory, "schematic_id", "image_factory")
    if len(str(schematic)) != 64:
        fail("image_factory.schematic_id must be a 64-character digest")
    required(image_factory, "installer", "image_factory")

    cluster = required(config, "cluster", "config")
    endpoint = urlparse(required(cluster, "endpoint", "cluster"))
    if endpoint.scheme != "https" or not endpoint.hostname or endpoint.port != 6443:
        fail("cluster.endpoint must be an https URL on port 6443")
    allow_controlplane_workloads = required(
        cluster, "allow_workloads_on_controlplanes", "cluster"
    )
    if not isinstance(allow_controlplane_workloads, bool):
        fail("cluster.allow_workloads_on_controlplanes must be a boolean")

    network = required(config, "network", "config")
    prefix_length = int(required(network, "prefix_length", "network"))
    gateway = ipaddress.ip_address(required(network, "gateway", "network"))
    nameservers = required(network, "nameservers", "network")
    if not isinstance(nameservers, list) or not nameservers:
        fail("network.nameservers must be a non-empty list")
    for server in nameservers:
        ipaddress.ip_address(server)

    nodes = required(cluster, "nodes", "cluster")
    if len(nodes) != 3:
        fail("cluster.nodes must contain exactly three control-plane nodes")

    node_ips: set[ipaddress._BaseAddress] = set()
    node_names: set[str] = set()
    vmids: set[int] = set()
    for index, node in enumerate(nodes):
        node_path = f"cluster.nodes[{index}]"
        if required(node, "role", node_path) != "controlplane":
            fail(f"{node_path}.role must be controlplane")
        name = str(required(node, "name", node_path))
        vmid = int(required(node, "vmid", node_path))
        ip = ipaddress.ip_address(required(node, "ip", node_path))
        required(node, "mac", node_path)
        if name in node_names or vmid in vmids or ip in node_ips:
            fail("node names, VM IDs and IP addresses must be unique")
        node_names.add(name)
        vmids.add(vmid)
        node_ips.add(ip)
        if gateway not in ipaddress.ip_network(f"{ip}/{prefix_length}", strict=False):
            fail(f"{node_path}.ip and network.gateway are not in the same subnet")

    api_vip = ipaddress.ip_address(required(cluster, "api_vip", "cluster"))
    ingress_vip = ipaddress.ip_address(required(network, "ingress_vip", "network"))
    if api_vip == ingress_vip or api_vip in node_ips or ingress_vip in node_ips:
        fail("API VIP, ingress VIP and node IPs must be distinct")

    proxmox_vm = required(required(config, "proxmox", "config"), "vm", "proxmox")
    system_disk = required(proxmox_vm, "system_disk", "proxmox.vm")
    longhorn_disk = required(proxmox_vm, "longhorn_disk", "proxmox.vm")
    if required(system_disk, "talos_device", "proxmox.vm.system_disk") == required(
        longhorn_disk, "talos_device", "proxmox.vm.longhorn_disk"
    ):
        fail("system and Longhorn disks must use different devices")

    storage = required(config, "storage", "config")
    if required(storage, "provider", "storage") != "longhorn":
        fail("storage.provider must be longhorn")
    required(storage, "volume_name", "storage")
    mount_path = str(required(storage, "mount_path", "storage"))
    if not mount_path.startswith("/var/mnt/"):
        fail("storage.mount_path must be below /var/mnt")
    replica_count = int(required(storage, "replica_count", "storage"))
    if replica_count < 1 or replica_count > len(nodes):
        fail("storage.replica_count must be between 1 and the node count")
    if required(storage, "data_engine", "storage") != "v1":
        fail("storage.data_engine must be v1 for this Talos deployment")
    chart = required(storage, "chart", "storage")
    chart_url = urlparse(required(chart, "url", "storage.chart"))
    if chart_url.scheme != "https" or not chart_url.netloc:
        fail("storage.chart.url must be an https URL")
    chart_sha256 = str(required(chart, "sha256", "storage.chart"))
    if len(chart_sha256) != 64 or any(
        character not in "0123456789abcdef" for character in chart_sha256
    ):
        fail("storage.chart.sha256 must be a lowercase SHA-256 digest")

    snapshot_controller = required(
        storage, "snapshot_controller", "storage"
    )
    snapshot_source_url = urlparse(
        required(
            snapshot_controller,
            "source_url",
            "storage.snapshot_controller",
        )
    )
    if snapshot_source_url.scheme != "https" or not snapshot_source_url.netloc:
        fail("storage.snapshot_controller.source_url must be an https URL")
    snapshot_sha256 = str(
        required(
            snapshot_controller,
            "sha256",
            "storage.snapshot_controller",
        )
    )
    if len(snapshot_sha256) != 64 or any(
        character not in "0123456789abcdef" for character in snapshot_sha256
    ):
        fail(
            "storage.snapshot_controller.sha256 must be a lowercase SHA-256 digest"
        )

    return config


def dump_yaml(path: Path, documents: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as stream:
        yaml.safe_dump_all(documents, stream, sort_keys=False, explicit_start=True)


def render(config: dict, output: Path) -> None:
    cluster = config["cluster"]
    network = config["network"]
    vm = config["proxmox"]["vm"]
    storage = config["storage"]

    endpoint_host = urlparse(cluster["endpoint"]).hostname
    resolver = {
        "apiVersion": "v1alpha1",
        "kind": "ResolverConfig",
        "nameservers": [{"address": server} for server in network["nameservers"]],
    }
    static_api_host = {
        "apiVersion": "v1alpha1",
        "kind": "StaticHostConfig",
        "name": cluster["api_vip"],
        "hostnames": [endpoint_host],
    }
    kube_network = {
        "apiVersion": "v1alpha1",
        "kind": "KubeNetworkConfig",
        "podSubnets": [cluster["pod_subnet"]],
        "serviceSubnets": [cluster["service_subnet"]],
    }
    no_flannel = {
        "apiVersion": "v1alpha1",
        "kind": "KubeFlannelCNIConfig",
        "$patch": "delete",
    }
    no_kube_proxy = {
        "apiVersion": "v1alpha1",
        "kind": "KubeProxyConfig",
        "enabled": False,
    }
    remove_controlplane_taint = {
        "apiVersion": "v1alpha1",
        "kind": "KubeNodeConfig",
        "taints": {
            "node-role.kubernetes.io/control-plane": {"$patch": "delete"}
        },
    }
    longhorn_volume = {
        "apiVersion": "v1alpha1",
        "kind": "UserVolumeConfig",
        "name": storage["volume_name"],
        "provisioning": {
            "diskSelector": {
                "match": (
                    "disk.dev_path == "
                    f"'{vm['longhorn_disk']['talos_device']}'"
                )
            },
            "grow": False,
            "minSize": f"{vm['longhorn_disk']['size_gib'] - 1}GiB",
            "maxSize": f"{vm['longhorn_disk']['size_gib']}GiB",
        },
        "filesystem": {"type": "xfs"},
    }
    common_documents = [
        resolver,
        static_api_host,
        kube_network,
        no_flannel,
        no_kube_proxy,
        longhorn_volume,
    ]
    dump_yaml(output / "common.yaml", common_documents)

    for node in cluster["nodes"]:
        remove_generated_hostname = {
            "apiVersion": "v1alpha1",
            "kind": "HostnameConfig",
            "$patch": "delete",
        }
        hostname = {
            "apiVersion": "v1alpha1",
            "kind": "HostnameConfig",
            "hostname": node["name"],
        }
        link = {
            "apiVersion": "v1alpha1",
            "kind": "LinkConfig",
            "name": network["interface"],
            "up": True,
            "addresses": [
                {"address": f"{node['ip']}/{network['prefix_length']}"}
            ],
            "routes": [{"gateway": network["gateway"]}],
        }
        api_vip = {
            "apiVersion": "v1alpha1",
            "kind": "Layer2VIPConfig",
            "name": cluster["api_vip"],
            "link": network["interface"],
        }
        node_documents = [remove_generated_hostname, hostname, link, api_vip]
        if cluster["allow_workloads_on_controlplanes"]:
            node_documents.append(remove_controlplane_taint)

        dump_yaml(output / f"node-{node['vmid']}.yaml", node_documents)

    bootstrap = output / "generate-on-bastion.sh"
    node_args = " ".join(
        f"{node['vmid']}:{node['ip']}" for node in cluster["nodes"]
    )
    sans = ",".join([endpoint_host, cluster["api_vip"]])
    bootstrap.write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail
umask 077

bundle_dir=$(cd -- "$(dirname -- "${{BASH_SOURCE[0]}}")" && pwd)
state_dir=${{1:-/root/ovh-talos-state}}
mkdir -p "$state_dir"
chmod 0700 "$state_dir"

if [[ ! -f "$state_dir/secrets.yaml" ]]; then
  talosctl gen secrets --talos-version {config['versions']['talos']} \\
    --output-file "$state_dir/secrets.yaml"
fi

talosctl gen config {cluster['name']} {cluster['endpoint']} \\
  --talos-version {config['versions']['talos']} \\
  --kubernetes-version {config['versions']['kubernetes']} \\
  --install-disk {vm['system_disk']['talos_device']} \\
  --install-image {config['image_factory']['installer']} \\
  --additional-sans {sans} \\
  --with-secrets "$state_dir/secrets.yaml" \\
  --config-patch "@$bundle_dir/common.yaml" \\
  --output "$state_dir/base" \\
  --with-docs=false --with-examples=false --force

for entry in {node_args}; do
  vmid=${{entry%%:*}}
  ip=${{entry#*:}}
  talosctl machineconfig patch "$state_dir/base/controlplane.yaml" \\
    --patch "@$bundle_dir/node-${{vmid}}.yaml" \\
    --output "$state_dir/controlplane-${{vmid}}.yaml"
  talosctl validate --config "$state_dir/controlplane-${{vmid}}.yaml" \\
    --mode metal --strict
done

cp "$state_dir/base/talosconfig" "$state_dir/talosconfig"
TALOSCONFIG="$state_dir/talosconfig" talosctl config endpoint {' '.join(str(node['ip']) for node in cluster['nodes'])}
TALOSCONFIG="$state_dir/talosconfig" talosctl config node {cluster['nodes'][0]['ip']}

printf 'Generated and validated Talos state in %s\\n' "$state_dir"
""",
        encoding="utf-8",
    )
    bootstrap.chmod(bootstrap.stat().st_mode | stat.S_IXUSR)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("config.yaml"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        config = load_and_validate(args.config)
        args.output.mkdir(parents=True, exist_ok=True)
        os.chmod(args.output, 0o700)
        render(config, args.output)
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"validated {args.config} and rendered {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
