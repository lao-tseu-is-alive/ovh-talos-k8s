#!/usr/bin/env bash
# Sauvegardes chiffrées de l'état Talos et d'etcd vers la station de travail.
set -euo pipefail

host=${BASTION_HOST:-ovh-fw-k3s}
state_dir=${STATE_DIR:-/root/ovh-talos-state}
remote_backup_dir=${REMOTE_BACKUP_DIR:-/root/ovh-talos-backups/etcd}
local_backup_dir=${LOCAL_BACKUP_DIR:-${HOME}/backups/ovh-talos}
keep=${KEEP:-7}

usage() {
  cat <<'EOF'
Usage: backup-cluster.sh [state|etcd|all]

  state  archive /root/ovh-talos-state du bastion
  etcd   snapshot etcd conservé sur le bastion et copié localement
  all    les deux (défaut)

Les copies locales sont chiffrées avec age et ne sont jamais déchiffrées par ce
script. Les KEEP dernières sauvegardes de chaque type sont conservées.

Variables:
  AGE_RECIPIENT      clé publique age (obligatoire, age1...)
  BASTION_HOST       hôte SSH (ovh-fw-k3s)
  LOCAL_BACKUP_DIR   répertoire local (~/backups/ovh-talos)
  REMOTE_BACKUP_DIR  répertoire etcd sur le bastion (/root/ovh-talos-backups/etcd)
  KEEP               nombre de sauvegardes conservées (7)
EOF
}

fail() {
  printf 'ERREUR: %s\n' "$*" >&2
  exit 1
}

# Keep only the $keep most recent files matching a glob in a local directory.
prune_local() {
  local pattern=$1
  find "$local_backup_dir" -maxdepth 1 -name "$pattern" -printf '%T@ %p\n' |
    sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- | xargs -r rm -f --
}

# Stream a remote command's output through age into a local file, removing it
# if either side of the pipeline fails.
fetch_encrypted() {
  local target=$1
  local remote_command=$2
  if ! ssh "$host" "$remote_command" |
    age --recipient "$AGE_RECIPIENT" --output "$target"; then
    rm -f "$target"
    fail "sauvegarde échouée: $target"
  fi
  chmod 0600 "$target"
  printf 'Sauvegarde locale: %s\n' "$target"
}

backup_state() {
  local target="$local_backup_dir/talos-state-$timestamp.tar.gz.age"
  fetch_encrypted "$target" \
    "tar --create --gzip --file=- --directory $(dirname "$state_dir") $(basename "$state_dir")"
  prune_local 'talos-state-*.tar.gz.age'
}

backup_etcd() {
  local remote_file="$remote_backup_dir/etcd-$timestamp.db"
  ssh "$host" bash -s -- "$state_dir" "$remote_backup_dir" "$remote_file" "$keep" <<'EOF'
set -euo pipefail
umask 077
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export TALOSCONFIG="$1/talosconfig"
mkdir -p "$2"
talosctl etcd snapshot "$3" >&2
find "$2" -maxdepth 1 -name 'etcd-*.db' -printf '%T@ %p\n' |
  sort -rn | tail -n "+$(($4 + 1))" | cut -d' ' -f2- | xargs -r rm -f --
EOF
  printf 'Snapshot bastion: %s:%s\n' "$host" "$remote_file"

  fetch_encrypted "$local_backup_dir/etcd-$timestamp.db.age" "cat '$remote_file'"
  prune_local 'etcd-*.db.age'
}

target=${1:-all}
case $target in
  state|etcd|all) ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v age >/dev/null 2>&1 || fail "age est requis (apt install age)"
[[ ${AGE_RECIPIENT:-} == age1* ]] || fail "AGE_RECIPIENT doit contenir une clé publique age"

umask 077
mkdir -p "$local_backup_dir"
timestamp=$(date +%Y%m%d-%H%M%S)

case $target in
  state) backup_state ;;
  etcd) backup_etcd ;;
  all) backup_state; backup_etcd ;;
esac
