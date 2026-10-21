#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools
require_talos_tools
EXPECTED_API_VIP=${EXPECTED_API_VIP:-192.168.50.241}

mapfile -t nodes < <(talos_node_addresses)
test "${#nodes[@]}" -eq "$EXPECTED_NODE_COUNT" || \
  fail "Talos: ${#nodes[@]} nœuds découverts, $EXPECTED_NODE_COUNT attendus"

endpoint=${TALOS_ENDPOINT:-${nodes[0]}}

section "TALOS VERSION ET MEMBRES"
"$TALOSCTL" --endpoints "$endpoint" --nodes "$endpoint" version
members=$("$TALOSCTL" --endpoints "$endpoint" --nodes "$endpoint" get members)
printf '%s\n' "$members"
grep -Fq "$EXPECTED_API_VIP" <<<"$members" || \
  fail "VIP API Talos absente des membres: $EXPECTED_API_VIP"

mapfile -t node_names < <(kubernetes_node_names)
for node_name in "${node_names[@]}"; do
  grep -Fq "$node_name" <<<"$members" || \
    fail "membre Talos absent: $node_name"
done

for node in "${nodes[@]}"; do
  section "TALOS $node"

  service=$(
    "$TALOSCTL" --endpoints "$endpoint" --nodes "$node" service etcd
  )
  printf '%s\n' "$service"
  grep -Eq 'HEALTH[[:space:]]+OK' <<<"$service" || \
    fail "etcd n'est pas sain sur $node"

  resolvers=$(
    "$TALOSCTL" --endpoints "$endpoint" --nodes "$node" get resolvers
  )
  printf '%s\n' "$resolvers"
  grep -Fq 'ResolverStatus' <<<"$resolvers" || \
    fail "aucun résolveur Talos sur $node"

  volume=$(
    "$TALOSCTL" --endpoints "$endpoint" --nodes "$node" \
      get volumestatus u-longhorn
  )
  printf '%s\n' "$volume"
  grep -Eq 'u-longhorn.*ready.*/dev/sdb' <<<"$volume" || \
    fail "volume u-longhorn non prêt sur $node"
done

printf '\nTalos: OK (%s nœuds).\n' "${#nodes[@]}"
