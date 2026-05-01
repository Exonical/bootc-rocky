#!/bin/bash
# airgap-inventory
# ----------------
# Walk /usr/share/zot-preload/ after the Containerfile preload step and
# emit a deterministic, human-readable inventory of every artifact plus
# a one-line tree hash an auditor can recompute on a running VM:
#
#   sudo find /usr/share/zot-preload -type f \
#     \( -name index.json -o -name oci-layout -o -path '*/blobs/sha256/*' \) \
#     -printf '%P\n' | LC_ALL=C sort \
#     | xargs -I{} sha256sum /usr/share/zot-preload/{} | sha256sum
#
# Outputs:
#   /usr/share/zot-preload/inventory.txt     detailed per-image + per-blob table
#   /usr/share/zot-preload/inventory.sha256  one-line root hash
#
# Runs inside Containerfile.vm AFTER the Zot bootstrap copy so layouts
# exist. Manifest-free by design -- whatever OCI layouts live under the
# tree get inventoried.
set -euo pipefail

PRELOAD="${PRELOAD:-/usr/share/zot-preload}"
INV="$PRELOAD/inventory.txt"
INV_HASH="$PRELOAD/inventory.sha256"

require() { command -v "$1" >/dev/null || { echo "[airgap-inventory] need $1" >&2; exit 2; }; }
require jq
require sha256sum
require find
require sort

[[ -d $PRELOAD ]] || { echo "[airgap-inventory] $PRELOAD missing; nothing to do" >&2; exit 0; }

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  echo "# /usr/share/zot-preload/inventory.txt"
  echo "# Generated: $generated_at"
  echo "#"
  if [[ -f $PRELOAD/BOOTSTRAP_REF ]]; then
    echo "# Bootstrap ref (Containerfile ARG at build time):"
    echo "#   $(cat "$PRELOAD/BOOTSTRAP_REF")"
    echo "#"
  fi
  echo "# Per-image summary (one row per OCI layout under $PRELOAD):"
  echo "#"
  printf '# %-72s %-72s %s\n' "REPO:TAG" "MANIFEST_DIGEST" "MEDIA_TYPE"

  # Every directory that contains an oci-layout marker is an OCI image repo.
  while IFS= read -r layout_dir; do
    repo="${layout_dir#$PRELOAD/}"
    idx="$layout_dir/index.json"
    [[ -f $idx ]] || continue
    # For each tagged manifest, emit one row.
    while IFS= read -r row; do
      tag=$(printf '%s' "$row" | jq -r '.annotations["org.opencontainers.image.ref.name"] // "<untagged>"')
      digest=$(printf '%s' "$row" | jq -r '.digest')
      media=$(printf '%s' "$row" | jq -r '.mediaType // "-"')
      printf '  %-72s %-72s %s\n' "$repo:$tag" "$digest" "$media"
    done < <(jq -c '.manifests[]?' "$idx")
  done < <(find "$PRELOAD" -type f -name oci-layout -printf '%h\n' | LC_ALL=C sort)

  echo
  echo "# Per-blob inventory (every file under $PRELOAD; sorted canonical order):"
  echo "#"
  printf '# %-66s %14s  %s\n' "BLOB_SHA256" "BYTES" "PATH"
  ( cd "$PRELOAD" && \
    find . -type f \( -name index.json -o -name oci-layout -o -path '*/blobs/sha256/*' \) \
      -printf '%P\n' \
    | LC_ALL=C sort \
    | while IFS= read -r p; do
        sz=$(stat -c '%s' "$p")
        sum=$(sha256sum "$p" | awk '{print $1}')
        printf '  %-66s %14s  %s\n' "$sum" "$sz" "$p"
      done )
} > "$INV"

# Root hash: sha256 of the sorted per-blob sha256sum stream. Any added,
# removed, or modified byte anywhere in the tree flips this single line.
( cd "$PRELOAD" && \
  find . -type f \( -name index.json -o -name oci-layout -o -path '*/blobs/sha256/*' \) \
    -printf '%P\n' \
  | LC_ALL=C sort \
  | xargs -I{} sha256sum {} ) | sha256sum | awk '{print "sha256:"$1}' > "$INV_HASH"

n_blobs=$(grep -c '^  [a-f0-9]\{64\}' "$INV" || true)
n_layouts=$(find "$PRELOAD" -type f -name oci-layout | wc -l)
root="$(cat "$INV_HASH")"
echo "[airgap-inventory] $n_layouts OCI layout(s), $n_blobs blob/index files, root=$root"
