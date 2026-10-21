#!/bin/bash
# Wrapper kubectl pour le cluster ovh-talos via le tunnel SSH local 16443.
set -euo pipefail

kubeconfig="${HOME}/.kube/ovh-talos"
kubectl_bin=/usr/local/bin/kubectl-1.36.5

if ! (exec 3<>/dev/tcp/127.0.0.1/16443) 2>/dev/null; then
  echo "Tunnel absent sur 127.0.0.1:16443. Le démarrer avec :" >&2
  echo "  ssh -fNT -o ExitOnForwardFailure=yes -L 127.0.0.1:16443:192.168.50.241:6443 ovh-fw-k3s" >&2
  exit 1
fi

exec "$kubectl_bin" --kubeconfig="$kubeconfig" "$@"
