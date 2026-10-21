#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools
SNAPSHOT_CONTROLLER_REPLICAS=${SNAPSHOT_CONTROLLER_REPLICAS:-2}

section "CRD CSI SNAPSHOT"
for crd in \
  volumesnapshotclasses.snapshot.storage.k8s.io \
  volumesnapshotcontents.snapshot.storage.k8s.io \
  volumesnapshots.snapshot.storage.k8s.io
do
  "$KUBECTL" wait --for=condition=Established \
    "customresourcedefinition/$crd" --timeout=2m
done

section "SNAPSHOT CONTROLLER"
"$KUBECTL" --namespace kube-system rollout status \
  deployment/snapshot-controller --timeout=5m
available=$(
  "$KUBECTL" --namespace kube-system get deployment snapshot-controller \
    --output=jsonpath='{.status.availableReplicas}'
)
assert_value \
  "$available" "$SNAPSHOT_CONTROLLER_REPLICAS" \
  "réplicas disponibles du snapshot-controller"
"$KUBECTL" --namespace kube-system get deployment,pods \
  --selector app.kubernetes.io/name=snapshot-controller -o wide

section "VOLUMESNAPSHOTCLASS LONGHORN"
"$KUBECTL" get volumesnapshotclass longhorn-snapshot
driver=$(
  "$KUBECTL" get volumesnapshotclass longhorn-snapshot \
    --output=jsonpath='{.driver}'
)
policy=$(
  "$KUBECTL" get volumesnapshotclass longhorn-snapshot \
    --output=jsonpath='{.deletionPolicy}'
)
snapshot_type=$(
  "$KUBECTL" get volumesnapshotclass longhorn-snapshot \
    --output=jsonpath='{.parameters.type}'
)
assert_value "$driver" driver.longhorn.io "driver de snapshot"
assert_value "$policy" Delete "politique de suppression des snapshots"
assert_value "$snapshot_type" snap "type de snapshot Longhorn"

printf '\nSnapshots CSI: OK.\n'
