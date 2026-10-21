#!/usr/bin/env python3
"""Validate config.yaml and render non-secret Kubernetes add-on inputs."""

from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path

import yaml

from render_talos import dump_yaml, load_and_validate


def render(config: dict, output: Path) -> None:
    cluster = config["cluster"]
    network = config["network"]
    management = config["management"]
    storage = config["storage"]
    cilium_version = str(config["versions"]["cilium"])
    longhorn_version = str(config["versions"]["longhorn"])
    snapshot_controller_version = str(
        config["versions"]["snapshot_controller"]
    )

    values = {
        "cluster": {"name": cluster["name"]},
        "ipam": {"mode": "kubernetes"},
        "kubeProxyReplacement": True,
        # Talos KubePrism provides a stable, node-local API endpoint.
        "k8sServiceHost": "localhost",
        "k8sServicePort": 7445,
        "cgroup": {
            "autoMount": {"enabled": False},
            "hostRoot": "/sys/fs/cgroup",
        },
        # Restrict the eBPF datapath and L2 announcements to the private NIC.
        "devices": network["interface"],
        "securityContext": {
            "capabilities": {
                "ciliumAgent": [
                    "CHOWN",
                    "KILL",
                    "NET_ADMIN",
                    "NET_RAW",
                    "IPC_LOCK",
                    "SYS_ADMIN",
                    "SYS_RESOURCE",
                    "DAC_OVERRIDE",
                    "FOWNER",
                    "SETGID",
                    "SETUID",
                ],
                "cleanCiliumState": [
                    "NET_ADMIN",
                    "SYS_ADMIN",
                    "SYS_RESOURCE",
                ],
            }
        },
        "operator": {"replicas": 2},
        "l2announcements": {"enabled": True},
        "k8sClientRateLimit": {"qps": 10, "burst": 20},
        "hubble": {
            "relay": {"enabled": True},
            "ui": {"enabled": True},
        },
        "ingressController": {
            "enabled": True,
            "loadbalancerMode": "shared",
            "service": {
                "type": "LoadBalancer",
                "externalTrafficPolicy": "Cluster",
                "annotations": {
                    "lbipam.cilium.io/ips": network["ingress_vip"]
                },
            },
        },
    }
    dump_yaml(output / "cilium-values.yaml", [values])

    ingress_selector = {"matchLabels": {"cilium.io/ingress": "true"}}
    ip_pool = {
        "apiVersion": "cilium.io/v2",
        "kind": "CiliumLoadBalancerIPPool",
        "metadata": {"name": "ingress"},
        "spec": {
            "blocks": [
                {
                    "start": network["ingress_vip"],
                    "stop": network["ingress_vip"],
                }
            ],
            "serviceSelector": ingress_selector,
        },
    }
    l2_policy = {
        "apiVersion": "cilium.io/v2alpha1",
        "kind": "CiliumL2AnnouncementPolicy",
        "metadata": {"name": "ingress"},
        "spec": {
            "serviceSelector": ingress_selector,
            "interfaces": [f"^{network['interface']}$"],
            "externalIPs": False,
            "loadBalancerIPs": True,
        },
    }
    dump_yaml(output / "cilium-l2.yaml", [ip_pool, l2_policy])

    tool_dir = management["bastion"]["tool_dir"]
    state_dir = management["bastion"]["state_dir"]
    install = output / "install-cilium.sh"
    install.write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail

bundle_dir=$(cd -- "$(dirname -- "${{BASH_SOURCE[0]}}")" && pwd)
kubectl={tool_dir}/kubectl
helm={tool_dir}/helm
export KUBECONFIG=${{KUBECONFIG:-{state_dir}/kubeconfig}}

test -x "$kubectl"
test -x "$helm"
test -r "$KUBECONFIG"

"$helm" upgrade --install cilium \\
  oci://quay.io/cilium/charts/cilium \\
  --version {cilium_version} \\
  --namespace kube-system \\
  --values "$bundle_dir/cilium-values.yaml" \\
  --timeout 10m

"$kubectl" --namespace kube-system rollout status daemonset/cilium --timeout=10m
"$kubectl" --namespace kube-system rollout status deployment/cilium-operator --timeout=10m
"$kubectl" --namespace kube-system rollout status daemonset/cilium-envoy --timeout=10m

if "$kubectl" get nodes \\
  --output=jsonpath='{{range .items[*].spec.taints[*]}}{{.key}}{{"\\n"}}{{end}}' | \\
  grep --quiet --line-regexp 'node-role.kubernetes.io/control-plane'; then
  "$kubectl" taint nodes --all node-role.kubernetes.io/control-plane-
fi

"$kubectl" apply --server-side --filename "$bundle_dir/cilium-l2.yaml"

"$kubectl" --namespace kube-system rollout status deployment/coredns --timeout=10m
"$kubectl" --namespace kube-system rollout status deployment/hubble-relay --timeout=10m
"$kubectl" --namespace kube-system rollout status deployment/hubble-ui --timeout=10m
""",
        encoding="utf-8",
    )
    install.chmod(install.stat().st_mode | stat.S_IXUSR)

    longhorn_namespace = {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": "longhorn-system",
            "labels": {
                "pod-security.kubernetes.io/enforce": "privileged",
            },
        },
    }
    dump_yaml(output / "longhorn-namespace.yaml", [longhorn_namespace])

    replica_count = int(storage["replica_count"])
    longhorn_values = {
        "persistence": {
            "createStorageClass": True,
            "defaultClass": True,
            "defaultClassReplicaCount": replica_count,
            "dataEngine": storage["data_engine"],
        },
        "defaultSettings": {
            "defaultDataPath": storage["mount_path"],
            "defaultReplicaCount": (
                f'{{"v1":"{replica_count}","v2":"{replica_count}"}}'
            ),
            "v1DataEngine": True,
            "v2DataEngine": False,
        },
    }
    dump_yaml(output / "longhorn-values.yaml", [longhorn_values])

    chart = storage["chart"]
    install_longhorn = output / "install-longhorn.sh"
    install_longhorn.write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail
umask 077

bundle_dir=$(cd -- "$(dirname -- "${{BASH_SOURCE[0]}}")" && pwd)
kubectl={tool_dir}/kubectl
helm={tool_dir}/helm
export KUBECONFIG=${{KUBECONFIG:-{state_dir}/kubeconfig}}

test -x "$kubectl"
test -x "$helm"
test -r "$KUBECONFIG"

work_dir=$(mktemp -d /tmp/longhorn-chart.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
chart_file="$work_dir/longhorn-{longhorn_version}.tgz"

curl --fail --location --retry 3 \\
  --output "$chart_file" \\
  {chart['url']}
printf '%s  %s\\n' '{chart['sha256']}' "$chart_file" | sha256sum --check --status

"$kubectl" apply --server-side \\
  --filename "$bundle_dir/longhorn-namespace.yaml"

"$helm" upgrade --install longhorn "$chart_file" \\
  --namespace longhorn-system \\
  --values "$bundle_dir/longhorn-values.yaml" \\
  --wait \\
  --wait-for-jobs \\
  --timeout 15m

"$kubectl" --namespace longhorn-system rollout status \\
  daemonset/longhorn-manager --timeout=10m
"$kubectl" --namespace longhorn-system rollout status \\
  deployment/longhorn-driver-deployer --timeout=10m
"$kubectl" --namespace longhorn-system rollout status \\
  deployment/longhorn-ui --timeout=10m
"$kubectl" get storageclass longhorn
"$kubectl" --namespace longhorn-system get nodes.longhorn.io
""",
        encoding="utf-8",
    )
    install_longhorn.chmod(install_longhorn.stat().st_mode | stat.S_IXUSR)

    snapshot_labels = {"app.kubernetes.io/name": "snapshot-controller"}
    snapshot_service_account = {
        "apiVersion": "v1",
        "kind": "ServiceAccount",
        "metadata": {
            "name": "snapshot-controller",
            "namespace": "kube-system",
            "labels": snapshot_labels,
        },
    }
    snapshot_cluster_role = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRole",
        "metadata": {"name": "snapshot-controller-runner"},
        "rules": [
            {
                "apiGroups": [""],
                "resources": ["persistentvolumes"],
                "verbs": ["get", "list", "watch"],
            },
            {
                "apiGroups": [""],
                "resources": ["persistentvolumeclaims"],
                "verbs": ["get", "list", "watch", "update"],
            },
            {
                "apiGroups": [""],
                "resources": ["events"],
                "verbs": ["list", "watch", "create", "update", "patch"],
            },
            {
                "apiGroups": ["snapshot.storage.k8s.io"],
                "resources": ["volumesnapshotclasses"],
                "verbs": ["get", "list", "watch"],
            },
            {
                "apiGroups": ["snapshot.storage.k8s.io"],
                "resources": ["volumesnapshotcontents"],
                "verbs": [
                    "create",
                    "get",
                    "list",
                    "watch",
                    "update",
                    "delete",
                    "patch",
                ],
            },
            {
                "apiGroups": ["snapshot.storage.k8s.io"],
                "resources": ["volumesnapshotcontents/status"],
                "verbs": ["patch"],
            },
            {
                "apiGroups": ["snapshot.storage.k8s.io"],
                "resources": ["volumesnapshots"],
                "verbs": [
                    "create",
                    "get",
                    "list",
                    "watch",
                    "update",
                    "patch",
                    "delete",
                ],
            },
            {
                "apiGroups": ["snapshot.storage.k8s.io"],
                "resources": ["volumesnapshots/status"],
                "verbs": ["update", "patch"],
            },
        ],
    }
    snapshot_cluster_role_binding = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRoleBinding",
        "metadata": {"name": "snapshot-controller-role"},
        "subjects": [
            {
                "kind": "ServiceAccount",
                "name": "snapshot-controller",
                "namespace": "kube-system",
            }
        ],
        "roleRef": {
            "kind": "ClusterRole",
            "name": "snapshot-controller-runner",
            "apiGroup": "rbac.authorization.k8s.io",
        },
    }
    snapshot_leaderelection_role = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "Role",
        "metadata": {
            "name": "snapshot-controller-leaderelection",
            "namespace": "kube-system",
        },
        "rules": [
            {
                "apiGroups": ["coordination.k8s.io"],
                "resources": ["leases"],
                "verbs": [
                    "get",
                    "watch",
                    "list",
                    "delete",
                    "update",
                    "create",
                ],
            }
        ],
    }
    snapshot_leaderelection_binding = {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "RoleBinding",
        "metadata": {
            "name": "snapshot-controller-leaderelection",
            "namespace": "kube-system",
        },
        "subjects": [
            {
                "kind": "ServiceAccount",
                "name": "snapshot-controller",
                "namespace": "kube-system",
            }
        ],
        "roleRef": {
            "kind": "Role",
            "name": "snapshot-controller-leaderelection",
            "apiGroup": "rbac.authorization.k8s.io",
        },
    }
    snapshot_controller = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": "snapshot-controller",
            "namespace": "kube-system",
            "labels": snapshot_labels,
        },
        "spec": {
            "replicas": 2,
            "minReadySeconds": 35,
            "strategy": {
                "type": "RollingUpdate",
                "rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1},
            },
            "selector": {"matchLabels": snapshot_labels},
            "template": {
                "metadata": {"labels": snapshot_labels},
                "spec": {
                    "serviceAccountName": "snapshot-controller",
                    "priorityClassName": "system-cluster-critical",
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 65532,
                        "runAsGroup": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "topologySpreadConstraints": [
                        {
                            "maxSkew": 1,
                            "topologyKey": "kubernetes.io/hostname",
                            "whenUnsatisfiable": "DoNotSchedule",
                            "labelSelector": {"matchLabels": snapshot_labels},
                        }
                    ],
                    "containers": [
                        {
                            "name": "snapshot-controller",
                            "image": (
                                "registry.k8s.io/sig-storage/"
                                "snapshot-controller:"
                                f"{snapshot_controller_version}"
                            ),
                            "args": [
                                "--v=5",
                                "--leader-election=true",
                            ],
                            "imagePullPolicy": "IfNotPresent",
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "capabilities": {"drop": ["ALL"]},
                                "readOnlyRootFilesystem": True,
                            },
                            "resources": {
                                "requests": {
                                    "cpu": "10m",
                                    "memory": "32Mi",
                                }
                            },
                        }
                    ],
                },
            },
        },
    }
    dump_yaml(
        output / "snapshot-controller.yaml",
        [
            snapshot_service_account,
            snapshot_cluster_role,
            snapshot_cluster_role_binding,
            snapshot_leaderelection_role,
            snapshot_leaderelection_binding,
            snapshot_controller,
        ],
    )

    longhorn_snapshot_class = {
        "apiVersion": "snapshot.storage.k8s.io/v1",
        "kind": "VolumeSnapshotClass",
        "metadata": {"name": "longhorn-snapshot"},
        "driver": "driver.longhorn.io",
        "deletionPolicy": "Delete",
        "parameters": {"type": "snap"},
    }
    dump_yaml(
        output / "longhorn-snapshotclass.yaml",
        [longhorn_snapshot_class],
    )

    snapshot_source = storage["snapshot_controller"]
    snapshot_source_dir = (
        "external-snapshotter-"
        f"{snapshot_controller_version.removeprefix('v')}"
    )
    install_snapshot_controller = output / "install-snapshot-controller.sh"
    install_snapshot_controller.write_text(
        f"""#!/usr/bin/env bash
set -euo pipefail
umask 077

bundle_dir=$(cd -- "$(dirname -- "${{BASH_SOURCE[0]}}")" && pwd)
kubectl={tool_dir}/kubectl
export KUBECONFIG=${{KUBECONFIG:-{state_dir}/kubeconfig}}

test -x "$kubectl"
test -r "$KUBECONFIG"

work_dir=$(mktemp -d /tmp/external-snapshotter.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
archive="$work_dir/external-snapshotter-{snapshot_controller_version}.tar.gz"

curl --fail --location --retry 3 \\
  --output "$archive" \\
  {snapshot_source['source_url']}
printf '%s  %s\\n' '{snapshot_source['sha256']}' "$archive" | \\
  sha256sum --check --status

tar --extract --gzip --file "$archive" --directory "$work_dir"
crd_dir="$work_dir/{snapshot_source_dir}/client/config/crd"

for crd in \\
  snapshot.storage.k8s.io_volumesnapshotclasses.yaml \\
  snapshot.storage.k8s.io_volumesnapshotcontents.yaml \\
  snapshot.storage.k8s.io_volumesnapshots.yaml
do
  "$kubectl" apply --server-side --filename "$crd_dir/$crd"
done

for crd in \\
  volumesnapshotclasses.snapshot.storage.k8s.io \\
  volumesnapshotcontents.snapshot.storage.k8s.io \\
  volumesnapshots.snapshot.storage.k8s.io
do
  "$kubectl" wait --for=condition=Established \\
    "customresourcedefinition/$crd" --timeout=2m
done

"$kubectl" apply --server-side \\
  --filename "$bundle_dir/snapshot-controller.yaml"
"$kubectl" apply --server-side \\
  --filename "$bundle_dir/longhorn-snapshotclass.yaml"

"$kubectl" --namespace kube-system rollout status \\
  deployment/snapshot-controller --timeout=10m
"$kubectl" get volumesnapshotclass longhorn-snapshot
""",
        encoding="utf-8",
    )
    install_snapshot_controller.chmod(
        install_snapshot_controller.stat().st_mode | stat.S_IXUSR
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("config.yaml"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        config = load_and_validate(args.config)
        management = config.get("management", {})
        tools = management.get("tools", {})
        bastion = management.get("bastion", {})
        if not tools.get("helm"):
            raise ValueError("missing management.tools.helm")
        for key in ("tool_dir", "state_dir"):
            if not bastion.get(key):
                raise ValueError(f"missing management.bastion.{key}")

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
