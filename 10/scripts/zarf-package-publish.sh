#!/bin/bash
# zarf-package-publish
# --------------------
# At first boot, after Zot is up, walk every signed Zarf package in
# /usr/share/zarf/packages/, verify its cosign signature against the
# trust root committed at /etc/zarf/cosign.pub, and mirror the package's
# images into Zot at localhost:5000.
#
# `zarf package mirror-resources` strips the upstream registry host from
# each image path (e.g. quay.io/cilium/cilium -> localhost:5000/cilium/cilium),
# so Talos worker nodes consuming localhost:5000 as a mirror for
# registry.k8s.io / ghcr.io / quay.io pull the same bytes regardless.
#
# Idempotent: a sentinel under /var/lib/zarf gates re-runs.
set -euo pipefail

PUBKEY="${PUBKEY:-/etc/zarf/cosign.pub}"
PKG_DIR="${PKG_DIR:-/usr/share/zarf/packages}"
REGISTRY="${REGISTRY:-localhost:5000}"
SENTINEL="${SENTINEL:-/var/lib/zarf/.published}"

require() { command -v "$1" >/dev/null || { echo "[zarf-publish] need $1" >&2; exit 2; }; }
require zarf

[[ -f $PUBKEY ]] || { echo "[zarf-publish] missing trust root $PUBKEY" >&2; exit 2; }

mkdir -p "$(dirname "$SENTINEL")"

shopt -s nullglob
pkgs=( "$PKG_DIR"/zarf-package-*.tar.zst )
shopt -u nullglob

if (( ${#pkgs[@]} == 0 )); then
  echo "[zarf-publish] no packages in $PKG_DIR; nothing to do"
  exit 0
fi

# Wait for Zot to actually be serving (defence in depth; the unit also
# orders us After=zot.service).
for _ in $(seq 1 60); do
  if curl -fsS "http://$REGISTRY/v2/" >/dev/null 2>&1; then break; fi
  sleep 1
done

for pkg in "${pkgs[@]}"; do
  echo "[zarf-publish] === $pkg ==="

  # 1) Verify signature. Fails closed.
  # Newer Zarf split `inspect` into subcommands; the legacy form prints a
  # deprecation warning. Try the modern form first, fall back to legacy.
  echo "[zarf-publish] verifying cosign signature with $PUBKEY"
  if ! zarf package inspect definition "$pkg" --key "$PUBKEY" >/dev/null 2>&1; then
    zarf package inspect "$pkg" --key "$PUBKEY" >/dev/null
  fi

  # 2) Mirror images into Zot.
  echo "[zarf-publish] mirroring images into $REGISTRY"
  zarf package mirror-resources "$pkg" \
    --registry-url="$REGISTRY" \
    --registry-push-username="zarf-push" \
    --registry-push-password="zarf-push" \
    --plain-http \
    --confirm \
    --no-color \
    --key "$PUBKEY"
done

date -u +%Y-%m-%dT%H:%M:%SZ > "$SENTINEL"
echo "[zarf-publish] done; sentinel=$SENTINEL"
