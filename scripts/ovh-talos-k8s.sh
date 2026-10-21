#!/bin/bash
set -euo pipefail

local_kubeconfig="${HOME}/.kube/ovh-talos"
kubectl_bin=/usr/local/bin/kubectl-1.36.5
tunnel_socket=/tmp/ovh-talos-k8s-kubectl.sock

export KUBECONFIG="$local_kubeconfig"

kubectl_ovh() {
  "$kubectl_bin" "$@"
}

### 1. Pointer le kubeconfig local vers le tunnel

cluster_name="$(
  kubectl_ovh config view --minify \
    --output=jsonpath='{.contexts[0].context.cluster}'
)"

kubectl_ovh config set-cluster "$cluster_name" \
  --server=https://127.0.0.1:16443 \
  --tls-server-name=ovh-talos-k8s

### 2. Démarrer le tunnel

ssh -M \
  -S "$tunnel_socket" \
  -fNT \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:16443:192.168.50.241:6443 \
  ovh-fw-k3s

ssh -S "$tunnel_socket" -O check ovh-fw-k3s

### 3. Vérifier l'accès au cluster

kubectl_ovh cluster-info
kubectl_ovh get nodes -o wide
kubectl_ovh get pods -A

echo "pour fermer le tunnel :"
echo "ssh -S $tunnel_socket -O exit ovh-fw-k3s"
