#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_cluster_tools
require_executable curl

namespace=infra-ci-network
ingress_host=smoke.ovh-talos.internal
assert_namespace_absent "$namespace"

section "CRÉATION DU SMOKE TEST RÉSEAU"
"$KUBECTL" apply --server-side --filename - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: infra-ci-network
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke-web
  namespace: infra-ci-network
spec:
  replicas: 3
  selector:
    matchLabels:
      app: smoke-web
  template:
    metadata:
      labels:
        app: smoke-web
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app: smoke-web
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: docker.io/library/busybox:1.37.0
          command: ["/bin/sh", "-c"]
          args:
            - |
              hostname > /www/index.html
              exec httpd -f -p 8080 -h /www
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: http
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: web-root
              mountPath: /www
      volumes:
        - name: web-root
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: smoke-web
  namespace: infra-ci-network
spec:
  selector:
    app: smoke-web
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: smoke-web
  namespace: infra-ci-network
spec:
  ingressClassName: cilium
  rules:
    - host: smoke.ovh-talos.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: smoke-web
                port:
                  name: http
---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-client
  namespace: infra-ci-network
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: docker.io/library/busybox:1.37.0
      command: ["/bin/sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
YAML

"$KUBECTL" --namespace "$namespace" rollout status \
  deployment/smoke-web --timeout=5m
"$KUBECTL" --namespace "$namespace" wait \
  --for=condition=Ready pod/smoke-client --timeout=5m

section "RÉPARTITION ET DNS"
"$KUBECTL" --namespace "$namespace" get pods -o wide
scheduled_nodes=$(
  "$KUBECTL" --namespace "$namespace" get pods \
    --selector app=smoke-web \
    --output=jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | \
    sort -u | awk 'END {print NR}'
)
assert_value \
  "$scheduled_nodes" "$EXPECTED_NODE_COUNT" \
  "nombre de nœuds portant le serveur de test"

fqdn="smoke-web.$namespace.svc.cluster.local."
"$KUBECTL" --namespace "$namespace" exec smoke-client -- nslookup "$fqdn"

section "SERVICE INTER-NŒUDS"
for attempt in 1 2 3 4 5 6; do
  "$KUBECTL" --namespace "$namespace" exec smoke-client -- \
    wget -qO- "http://$fqdn"
done

section "INGRESS CILIUM"
ingress_vip=""
for attempt in $(seq 1 60); do
  ingress_vip=$(
    "$KUBECTL" --namespace "$namespace" get ingress smoke-web \
      --output=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
      2>/dev/null || true
  )
  [[ -n "$ingress_vip" ]] && break
  sleep 2
done
test -n "$ingress_vip" || fail "aucune VIP publiée sur l'Ingress de test"
"$KUBECTL" --namespace "$namespace" get ingress smoke-web -o wide
curl --fail --silent --show-error --retry 10 --retry-delay 2 \
  --resolve "$ingress_host:80:$ingress_vip" \
  "http://$ingress_host/"

section "NETTOYAGE RÉSEAU"
"$KUBECTL" delete namespace "$namespace" --wait=true --timeout=5m
printf 'Smoke test réseau, DNS, Service et Ingress: OK.\n'
