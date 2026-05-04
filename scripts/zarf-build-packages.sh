#!/bin/bash
# zarf-build-packages
# -------------------
# Build every Zarf package definition under 10/zarf/*/zarf.yaml. Each
# `zarf package create` run downloads its declared images, packs them as
# OCI layouts inside a single zstd-compressed tarball, and signs the
# package metadata with the cosign key at $COSIGN_KEY.
#
# Output: $OUTPUT_DIR/zarf-package-<name>-<arch>-<version>.tar.zst (one
# file per zarf.yaml).
#
# Run on a workstation/build host with network access. The Containerfile.vm
# bakes the resulting .tar.zst files into /usr/share/zarf/packages/ and
# the matching cosign.pub into /etc/zarf/cosign.pub for runtime verify.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ZARF_DIR="${ZARF_DIR:-$REPO_ROOT/10/omni/zarf}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/zarf}"
COSIGN_KEY="${COSIGN_KEY:-$ZARF_DIR/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-$ZARF_DIR/cosign.pub}"
ARCH="${ARCH:-amd64}"

require() { command -v "$1" >/dev/null || { echo "[zarf-build] need $1 in PATH" >&2; exit 2; }; }
require zarf

if [[ ! -f $COSIGN_KEY || ! -f $COSIGN_PUB ]]; then
  cat <<EOF >&2
[zarf-build] cosign keypair not found:
  expected: $COSIGN_KEY (private)
            $COSIGN_PUB (public)
Generate one with:  make zarf-keygen
The public key MUST be committed (it gets baked into the VM image so
first-boot verification has a trust anchor); the private key MUST NOT.
EOF
  exit 2
fi

mkdir -p "$OUTPUT_DIR"

shopt -s nullglob
pkg_dirs=( "$ZARF_DIR"/*/ )
shopt -u nullglob

if (( ${#pkg_dirs[@]} == 0 )); then
  echo "[zarf-build] no package directories found under $ZARF_DIR/*/" >&2
  exit 0
fi

# COSIGN_PASSWORD comes from the env (CI secret / operator prompt). If it
# is empty, zarf will read from /dev/tty -- only convenient interactively.
: "${COSIGN_PASSWORD:=}"
export COSIGN_PASSWORD

for d in "${pkg_dirs[@]}"; do
  [[ -f "$d/zarf.yaml" ]] || { echo "[zarf-build] skipping $d (no zarf.yaml)"; continue; }
  echo "[zarf-build] === creating package from $d ==="
  zarf package create "$d" \
    --output "$OUTPUT_DIR" \
    --architecture "$ARCH" \
    --signing-key "$COSIGN_KEY" \
    --signing-key-pass "$COSIGN_PASSWORD" \
    --confirm
done

echo
echo "[zarf-build] artifacts:"
ls -1sh "$OUTPUT_DIR"/zarf-package-*.tar.zst 2>/dev/null || true

echo
echo "[zarf-build] verifying signatures with $COSIGN_PUB:"
for f in "$OUTPUT_DIR"/zarf-package-*.tar.zst; do
  echo "  $f"
  zarf package verify "$f" --key "$COSIGN_PUB" >/dev/null
  echo "    OK"
done
