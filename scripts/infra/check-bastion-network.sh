#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools
require_executable sysctl
require_executable iptables-save

BASTION_EXTERNAL_INTERFACE=${BASTION_EXTERNAL_INTERFACE:-ens18}
BASTION_INTERNAL_INTERFACE=${BASTION_INTERNAL_INTERFACE:-ens19}
FORWARDING_FILE=${FORWARDING_FILE:-/etc/sysctl.d/99-ovh-fw-k3s-forward.conf}

section "FORWARDING IPV4 DU BASTION"
forwarding=$(sysctl -n net.ipv4.ip_forward)
assert_value "$forwarding" 1 "net.ipv4.ip_forward"
require_file "$FORWARDING_FILE"
grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
  "$FORWARDING_FILE" || fail "forwarding absent de $FORWARDING_FILE"
printf 'Forwarding actif et persistant dans %s.\n' "$FORWARDING_FILE"

section "POLITIQUE FORWARD"
forward_policy=$(iptables-save | awk '$1 == "-P" && $2 == "FORWARD" {print $3}')
assert_value "$forward_policy" ACCEPT "politique FORWARD"
printf 'FORWARD=%s, interface interne=%s, interface externe=%s\n' \
  "$forward_policy" "$BASTION_INTERNAL_INTERFACE" "$BASTION_EXTERNAL_INTERFACE"

section "RÈGLES SNAT DES NŒUDS"
nat_rules=$(iptables-save --table nat)
mapfile -t nodes < <(talos_node_addresses)
test "${#nodes[@]}" -eq "$EXPECTED_NODE_COUNT" || \
  fail "${#nodes[@]} IP de nœuds trouvées, $EXPECTED_NODE_COUNT attendues"

for node in "${nodes[@]}"; do
  if ! grep -Eq -- "-s ${node}/32.*-o ${BASTION_EXTERNAL_INTERFACE}.*-j SNAT" \
    <<<"$nat_rules"; then
    fail "règle SNAT absente pour $node via $BASTION_EXTERNAL_INTERFACE"
  fi
  printf '%s: SNAT présent\n' "$node"
done

printf '\nRoutage et SNAT du bastion: OK.\n'
