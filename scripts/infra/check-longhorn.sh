#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools
require_executable "$HELM"

section "HELM LONGHORN"
helm_status=$("$HELM" status longhorn --namespace longhorn-system)
printf '%s\n' "$helm_status" | sed -n '1,12p'
grep -Fq 'STATUS: deployed' <<<"$helm_status" || \
  fail "la release Helm Longhorn n'est pas déployée"

section "ROLLOUTS LONGHORN"
"$KUBECTL" --namespace longhorn-system rollout status \
  daemonset/longhorn-manager --timeout=5m
"$KUBECTL" --namespace longhorn-system rollout status \
  daemonset/longhorn-csi-plugin --timeout=5m
"$KUBECTL" --namespace longhorn-system rollout status \
  deployment/longhorn-driver-deployer --timeout=5m
"$KUBECTL" --namespace longhorn-system rollout status \
  deployment/longhorn-global-manager --timeout=5m
"$KUBECTL" --namespace longhorn-system rollout status \
  deployment/longhorn-ui --timeout=5m

section "NOEUDS ET DISQUES LONGHORN"
longhorn_nodes=$(
  "$KUBECTL" --namespace longhorn-system get nodes.longhorn.io --no-headers
)
printf '%s\n' "$longhorn_nodes"
longhorn_node_count=$(awk 'END {print NR}' <<<"$longhorn_nodes")
assert_value \
  "$longhorn_node_count" "$EXPECTED_NODE_COUNT" "nombre de nœuds Longhorn"
bad_nodes=$(
  awk '$2 != "True" || $3 != "true" || $4 != "True" {print}' \
    <<<"$longhorn_nodes"
)
test -z "$bad_nodes" || {
  printf '%s\n' "$bad_nodes" >&2
  fail "au moins un nœud Longhorn n'est pas prêt ou planifiable"
}

section "STORAGECLASS LONGHORN"
"$KUBECTL" get storageclass longhorn
default_class=$(
  "$KUBECTL" get storageclass longhorn \
    --output=jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
)
assert_value "$default_class" true "StorageClass Longhorn par défaut"

section "VOLUMES LONGHORN"
volumes=$(
  "$KUBECTL" --namespace longhorn-system get volumes.longhorn.io \
    --no-headers 2>/dev/null || true
)
if [[ -z "$volumes" ]]; then
  printf 'Aucun volume actuellement provisionné.\n'
else
  printf '%s\n' "$volumes"
  unhealthy=$(awk '$4 == "degraded" || $4 == "faulted" {print}' <<<"$volumes")
  test -z "$unhealthy" || {
    printf '%s\n' "$unhealthy" >&2
    fail "volume Longhorn dégradé ou en panne"
  }
fi

printf '\nLonghorn: OK.\n'
