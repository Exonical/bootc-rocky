#!/bin/bash
# airgap-image-load
# -----------------
# At first boot, import every OCI layout under /usr/share/zot-preload/
# into podman containers-storage. Ordered Before=zot.service so zot's
# Quadlet can start without the internet.
#
# The Containerfile populates /usr/share/zot-preload/ with a single
# digest-pinned image today (Zot itself); the script is written
# manifest-free so any future host-bootstrap image we preload here just
# works. See /usr/share/zot-preload/BOOTSTRAP_REF for the exact
# ref@digest that was baked in.
set -euo pipefail

PRELOAD="${PRELOAD:-/usr/share/zot-preload}"
SENTINEL="${SENTINEL:-/var/lib/containers/storage/.airgap-loaded}"

require() { command -v "$1" >/dev/null || { echo "[airgap-image-load] need $1" >&2; exit 2; }; }
require skopeo
require jq

[[ -d $PRELOAD ]] || { echo "[airgap-image-load] $PRELOAD missing; nothing to do"; exit 0; }
mkdir -p "$(dirname "$SENTINEL")"

# Walk the tree: every directory that has an oci-layout + index.json is
# an OCI image repo. The repo path is its location relative to $PRELOAD
# (mirrors the upstream registry path, e.g. ghcr.io/project-zot/...).
count=0
while IFS= read -r layout_dir; do
  repo="${layout_dir#$PRELOAD/}"
  idx="$layout_dir/index.json"
  [[ -f $idx ]] || continue

  # Pull every human tag recorded in the layout (we skip digest-as-tag
  # refs like sha256-abc... which exist only as audit aliases).
  mapfile -t tags < <(jq -r '
    .manifests[].annotations["org.opencontainers.image.ref.name"] // empty
    | select(startswith("sha256-") | not)' "$idx")

  for tag in "${tags[@]}"; do
    [[ -z "$tag" ]] && continue
    echo "[airgap-image-load] $repo:$tag -> containers-storage"
    skopeo copy "oci:$layout_dir:$tag" "containers-storage:$repo:$tag"
    count=$((count+1))
  done
done < <(find "$PRELOAD" -type f -name oci-layout -printf '%h\n' | LC_ALL=C sort)

date -u +%Y-%m-%dT%H:%M:%SZ > "$SENTINEL"
echo "[airgap-image-load] done ($count image(s) loaded)"
