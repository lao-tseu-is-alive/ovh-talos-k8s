#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools
ALLOW_WORKLOADS_ON_CONTROLPLANES=${ALLOW_WORKLOADS_ON_CONTROLPLANES:-true}

section "API KUBERNETES"
readyz=$("$KUBECTL" get --raw='/readyz?verbose')
printf '%s\n' "$readyz"
grep -Fq 'readyz check passed' <<<"$readyz" || \
  fail "le serveur API Kubernetes n'est pas prêt"

section "NOEUDS"
"$KUBECTL" wait --for=condition=Ready nodes --all --timeout=2m
"$KUBECTL" get nodes -o wide
node_count=$("$KUBECTL" get nodes --no-headers | awk 'END {print NR}')
assert_value "$node_count" "$EXPECTED_NODE_COUNT" "nombre de nœuds Kubernetes"

if [[ "$ALLOW_WORKLOADS_ON_CONTROLPLANES" == true ]]; then
  taints=$(
    "$KUBECTL" get nodes \
      --output=jsonpath='{range .items[*].spec.taints[*]}{.key}{"\n"}{end}'
  )
  if grep -Fxq 'node-role.kubernetes.io/control-plane' <<<"$taints"; then
    fail "le taint NoSchedule control-plane est revenu"
  fi
fi

section "PODS NON SAINS"
pod_report=$("$KUBECTL" get pods --all-namespaces --no-headers)
bad_pods=$(
  awk '
    {
      split($3, ready, "/")
      if (($4 == "Running" && ready[1] != ready[2]) ||
          ($4 != "Running" && $4 != "Completed" && $4 != "Succeeded")) {
        print
      }
    }
  ' <<<"$pod_report"
)

if [[ -n "$bad_pods" ]]; then
  printf '%s\n' "$bad_pods" >&2
  fail "des pods ne sont ni prêts ni terminés avec succès"
fi
printf 'Aucun pod non sain.\n'

printf '\nKubernetes: OK.\n'
