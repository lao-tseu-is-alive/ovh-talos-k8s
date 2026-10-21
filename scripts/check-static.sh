#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"

work_dir=$(mktemp -d /tmp/ovh-talos-static-check.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

if python3 -c 'import yaml' >/dev/null 2>&1; then
  python_runner=(python3)
elif command -v uv >/dev/null 2>&1; then
  uv_cache_dir=${UV_CACHE_DIR:-/tmp/ovh-talos-k8s-uv-cache-$(id -u)}
  mkdir -p "$uv_cache_dir"
  chmod 0700 "$uv_cache_dir"
  python_runner=(
    uv run
    --cache-dir "$uv_cache_dir"
    --with PyYAML==6.0.3
    python
  )
else
  printf 'ERREUR: Python avec PyYAML ou uv est requis.\n' >&2
  exit 1
fi

printf 'Validation et rendu Talos...\n'
"${python_runner[@]}" scripts/render_talos.py \
  --config config.yaml \
  --output "$work_dir/talos"

printf 'Validation et rendu des add-ons...\n'
"${python_runner[@]}" scripts/render_addons.py \
  --config config.yaml \
  --output "$work_dir/addons"

for expected in \
  "$work_dir/talos/common.yaml" \
  "$work_dir/talos/generate-on-bastion.sh" \
  "$work_dir/addons/cilium-values.yaml" \
  "$work_dir/addons/install-cilium.sh" \
  "$work_dir/addons/longhorn-values.yaml" \
  "$work_dir/addons/install-longhorn.sh" \
  "$work_dir/addons/snapshot-controller.yaml" \
  "$work_dir/addons/longhorn-snapshotclass.yaml" \
  "$work_dir/addons/install-snapshot-controller.sh"
do
  test -s "$expected" || {
    printf 'ERREUR: sortie absente ou vide: %s\n' "$expected" >&2
    exit 1
  }
done

printf 'Validation syntaxique Python et Bash...\n'
PYTHONPYCACHEPREFIX="$work_dir/pycache" \
  "${python_runner[@]}" -m py_compile \
    scripts/render_talos.py scripts/render_addons.py

mapfile -t shell_scripts < <(
  find scripts -type f -name '*.sh' -print | sort
)
shell_scripts+=(
  "$work_dir/talos/generate-on-bastion.sh"
  "$work_dir/addons/install-cilium.sh"
  "$work_dir/addons/install-longhorn.sh"
  "$work_dir/addons/install-snapshot-controller.sh"
)
bash -n "${shell_scripts[@]}"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${shell_scripts[@]}"
else
  printf 'INFO: shellcheck absent, contrôle optionnel ignoré.\n'
fi

if grep -n 'groupsnapshot' \
  "$work_dir/addons/snapshot-controller.yaml" \
  "$work_dir/addons/install-snapshot-controller.sh"
then
  printf 'ERREUR: les API VolumeGroupSnapshot ne doivent pas être rendues.\n' >&2
  exit 1
fi

git diff --check
printf 'Contrôles statiques: OK.\n'
