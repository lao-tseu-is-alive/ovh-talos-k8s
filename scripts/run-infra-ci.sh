#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=""
host=${BASTION_HOST:-ovh-fw-k3s}

usage() {
  cat <<'EOF'
Usage: run-infra-ci.sh [--smoke] [utilisateur@bastion]

Transmet temporairement scripts/infra au bastion et exécute les contrôles.
Le bundle temporaire est supprimé du bastion à la fin.

Variables utiles:
  BASTION_HOST   hôte SSH par défaut (ovh-fw-k3s)

Les variables de configuration des contrôles documentées dans README.md sont
transmises au shell distant lorsqu'elles sont définies localement.

Exemples:
  scripts/run-infra-ci.sh
  scripts/run-infra-ci.sh --smoke
  scripts/run-infra-ci.sh --smoke root@nouveau-bastion
EOF
}

while (($#)); do
  case $1 in
    --smoke)
      mode=--smoke
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -* )
      usage >&2
      exit 2
      ;;
    *)
      host=$1
      ;;
  esac
  shift
done

command -v ssh >/dev/null 2>&1 || {
  printf 'ERREUR: ssh est requis.\n' >&2
  exit 1
}
command -v tar >/dev/null 2>&1 || {
  printf 'ERREUR: tar est requis.\n' >&2
  exit 1
}

remote_exports=""
for variable in \
  KUBECONFIG \
  TALOSCONFIG \
  KUBECTL \
  HELM \
  TALOSCTL \
  EXPECTED_NODE_COUNT \
  ALLOW_WORKLOADS_ON_CONTROLPLANES \
  CILIUM_DEVICE \
  EXPECTED_API_VIP \
  EXPECTED_INGRESS_VIP \
  SNAPSHOT_CONTROLLER_REPLICAS \
  BASTION_EXTERNAL_INTERFACE \
  BASTION_INTERNAL_INTERFACE \
  FORWARDING_FILE \
  INFRA_CI_PATH
do
  if [[ -v $variable ]]; then
    printf -v quoted_value '%q' "${!variable}"
    remote_exports+="export $variable=$quoted_value"$'\n'
  fi
done

printf 'Exécution de la CI infra sur %s...\n' "$host"
tar --create --file=- --directory "$repo_dir/scripts" infra | \
  ssh "$host" "
    set -euo pipefail
    $remote_exports
    work_dir=\$(mktemp -d /tmp/ovh-talos-infra-ci.XXXXXX)
    trap 'rm -rf \"\$work_dir\"' EXIT
    tar --extract --file=- --directory \"\$work_dir\"
    chmod -R u+rx,go-rwx \"\$work_dir/infra\"
    \"\$work_dir/infra/check-all.sh\" $mode
  "
