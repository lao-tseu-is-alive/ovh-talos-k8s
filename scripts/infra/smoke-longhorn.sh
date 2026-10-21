#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools

namespace=infra-ci-longhorn
proof=longhorn-persistence-ok
assert_namespace_absent "$namespace"
mapfile -t nodes < <(kubernetes_node_names)
test "${#nodes[@]}" -ge 2 || fail "le test Longhorn requiert au moins deux nœuds"
node_one=${nodes[0]}
node_two=${nodes[1]}

section "CRÉATION DU VOLUME LONGHORN"
"$KUBECTL" apply --server-side --filename - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-volume
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: $namespace
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: $node_one
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: writer
      image: docker.io/library/busybox:1.37.0
      command: ["/bin/sh", "-c"]
      args:
        - |
          printf '%s\n' '$proof' > /data/proof.txt
          sync
          sleep 3600
      readinessProbe:
        exec:
          command: ["/bin/sh", "-c", "test -s /data/proof.txt"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-volume
YAML

"$KUBECTL" --namespace "$namespace" wait \
  --for=condition=Ready pod/writer --timeout=5m
written=$(
  "$KUBECTL" --namespace "$namespace" exec writer -- cat /data/proof.txt
)
assert_value "$written" "$proof" "donnée écrite sur $node_one"
"$KUBECTL" --namespace "$namespace" get pod writer -o wide
"$KUBECTL" --namespace "$namespace" delete pod writer \
  --wait=true --timeout=5m

section "RÉATTACHEMENT SUR $node_two"
"$KUBECTL" apply --server-side --filename - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: reader
  namespace: $namespace
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: $node_two
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: reader
      image: docker.io/library/busybox:1.37.0
      command: ["/bin/sh", "-c", "sleep 3600"]
      readinessProbe:
        exec:
          command: ["/bin/sh", "-c", "test -r /data/proof.txt"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: data
          mountPath: /data
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-volume
YAML

"$KUBECTL" --namespace "$namespace" wait \
  --for=condition=Ready pod/reader --timeout=5m
restored=$(
  "$KUBECTL" --namespace "$namespace" exec reader -- cat /data/proof.txt
)
assert_value "$restored" "$proof" "donnée relue sur $node_two"
"$KUBECTL" --namespace "$namespace" get pod reader -o wide
"$KUBECTL" --namespace "$namespace" get pvc test-volume

section "NETTOYAGE LONGHORN"
"$KUBECTL" delete namespace "$namespace" --wait=true --timeout=5m
printf 'Smoke test de persistance et réattachement Longhorn: OK.\n'
