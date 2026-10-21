#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mode=checks

usage() {
  cat <<'EOF'
Usage: check-all.sh [--smoke]

Sans option, exécute uniquement les contrôles passifs du réseau du bastion,
de Talos, Kubernetes, Cilium, Longhorn et CSI Snapshot.

Avec --smoke, ajoute trois tests actifs et temporaires:
  - DNS, Service inter-nœuds et Ingress Cilium;
  - persistance et réattachement Longhorn;
  - snapshot CSI et restauration Longhorn.

Les namespaces temporaires sont supprimés après succès. En cas d'échec, ils
sont conservés pour faciliter le diagnostic.
EOF
}

case ${1:-} in
  "") ;;
  --smoke) mode=smoke ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

started_at=$(date +%s)

for check in \
  check-bastion-network.sh \
  check-talos.sh \
  check-kubernetes.sh \
  check-cilium.sh \
  check-longhorn.sh \
  check-snapshots.sh
do
  "$script_dir/$check"
done

if [[ "$mode" == smoke ]]; then
  for smoke_test in \
    smoke-network.sh \
    smoke-longhorn.sh \
    smoke-snapshot.sh
  do
    "$script_dir/$smoke_test"
  done
fi

elapsed=$(( $(date +%s) - started_at ))
printf '\n===== RÉSULTAT GLOBAL =====\n'
printf 'CI infra %s: OK en %ss.\n' "$mode" "$elapsed"
