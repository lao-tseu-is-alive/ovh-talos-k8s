#!/usr/bin/env bash

# Shared defaults for checks executed on the management bastion.
PATH=${INFRA_CI_PATH:-/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin}
KUBECTL=${KUBECTL:-/usr/local/bin/kubectl}
HELM=${HELM:-/usr/local/bin/helm}
TALOSCTL=${TALOSCTL:-talosctl}
KUBECONFIG=${KUBECONFIG:-/root/ovh-talos-state/kubeconfig}
TALOSCONFIG=${TALOSCONFIG:-/root/ovh-talos-state/talosconfig}
EXPECTED_NODE_COUNT=${EXPECTED_NODE_COUNT:-3}

export KUBECONFIG TALOSCONFIG PATH

section() {
  printf '\n===== %s =====\n' "$1"
}

fail() {
  printf 'ERREUR: %s\n' "$*" >&2
  exit 1
}

require_executable() {
  command -v "$1" >/dev/null 2>&1 || fail "exécutable introuvable: $1"
}

require_file() {
  test -r "$1" || fail "fichier illisible: $1"
}

require_cluster_tools() {
  require_executable "$KUBECTL"
  require_file "$KUBECONFIG"
}

require_talos_tools() {
  require_executable "$TALOSCTL"
  require_file "$TALOSCONFIG"
}

kubernetes_node_names() {
  "$KUBECTL" get nodes \
    --output=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

talos_node_addresses() {
  "$KUBECTL" get nodes \
    --output=jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' | sort
}

assert_namespace_absent() {
  local namespace=$1

  if "$KUBECTL" get namespace "$namespace" >/dev/null 2>&1; then
    fail "le namespace temporaire $namespace existe déjà; inspectez-le avant de le supprimer"
  fi
}

assert_value() {
  local actual=$1
  local expected=$2
  local label=$3

  test "$actual" = "$expected" || \
    fail "$label: attendu '$expected', obtenu '$actual'"
}
