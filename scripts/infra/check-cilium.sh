#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools
require_executable "$HELM"
CILIUM_DEVICE=${CILIUM_DEVICE:-ens18}
EXPECTED_INGRESS_VIP=${EXPECTED_INGRESS_VIP:-192.168.50.240}

section "HELM CILIUM"
helm_status=$("$HELM" status cilium --namespace kube-system)
printf '%s\n' "$helm_status" | sed -n '1,12p'
grep -Fq 'STATUS: deployed' <<<"$helm_status" || \
  fail "la release Helm Cilium n'est pas déployée"

section "ROLLOUTS CILIUM"
"$KUBECTL" --namespace kube-system rollout status \
  daemonset/cilium --timeout=5m
"$KUBECTL" --namespace kube-system rollout status \
  daemonset/cilium-envoy --timeout=5m
"$KUBECTL" --namespace kube-system rollout status \
  deployment/cilium-operator --timeout=5m
"$KUBECTL" --namespace kube-system rollout status \
  deployment/coredns --timeout=5m
"$KUBECTL" --namespace kube-system rollout status \
  deployment/hubble-relay --timeout=5m
"$KUBECTL" --namespace kube-system rollout status \
  deployment/hubble-ui --timeout=5m

section "AGENTS CILIUM"
mapfile -t cilium_pods < <(
  "$KUBECTL" --namespace kube-system get pods \
    --selector k8s-app=cilium --output=name
)
test "${#cilium_pods[@]}" -eq "$EXPECTED_NODE_COUNT" || \
  fail "${#cilium_pods[@]} agents Cilium trouvés, $EXPECTED_NODE_COUNT attendus"

for pod in "${cilium_pods[@]}"; do
  printf '%s: ' "$pod"
  "$KUBECTL" --namespace kube-system exec "$pod" -- \
    cilium-dbg status --brief
done

section "CONFIGURATION CILIUM"
cilium_config=$(
  "$KUBECTL" --namespace kube-system get configmap cilium-config \
    --output=jsonpath='kube-proxy-replacement={.data.kube-proxy-replacement}{"\n"}enable-l2-announcements={.data.enable-l2-announcements}{"\n"}devices={.data.devices}{"\n"}'
)
printf '%s\n' "$cilium_config"
grep -Fxq 'kube-proxy-replacement=true' <<<"$cilium_config" || \
  fail "kube-proxy replacement n'est pas actif"
grep -Fxq 'enable-l2-announcements=true' <<<"$cilium_config" || \
  fail "les annonces L2 ne sont pas actives"
grep -Fxq "devices=$CILIUM_DEVICE" <<<"$cilium_config" || \
  fail "Cilium n'utilise pas l'interface $CILIUM_DEVICE"

section "VIP INGRESS ET ANNONCE L2"
"$KUBECTL" --namespace kube-system get service cilium-ingress -o wide
ingress_vip=$(
  "$KUBECTL" --namespace kube-system get service cilium-ingress \
    --output=jsonpath='{.status.loadBalancer.ingress[0].ip}'
)
test -n "$ingress_vip" || fail "le service cilium-ingress n'a pas de VIP"
assert_value "$ingress_vip" "$EXPECTED_INGRESS_VIP" "VIP ingress"

"$KUBECTL" get ciliumloadbalancerippool ingress
"$KUBECTL" get ciliuml2announcementpolicy ingress
lease=$(
  "$KUBECTL" --namespace kube-system get leases --no-headers | \
    awk '$1 == "cilium-l2announce-kube-system-cilium-ingress" {print $1}'
)
test -n "$lease" || fail "aucun lease L2 pour le service ingress"

printf '\nCilium: OK (VIP %s).\n' "$ingress_vip"
