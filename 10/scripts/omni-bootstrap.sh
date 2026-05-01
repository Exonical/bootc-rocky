#!/bin/bash
# Idempotent first-boot bootstrap for self-hosted Omni + Dex.
# - Generates a local Root CA and signs server certs for Omni and Dex with it
# - Installs the CA into the host trust store
# - Builds a CA bundle for the Omni container (so Omni trusts Dex over TLS)
# - Generates the etcd encryption key (omni.asc)
# - Writes default /etc/omni/config.yaml and /etc/dex/dex.yaml if absent
#
# Reruns are safe: every step skips when its output already exists.
set -euo pipefail

CA_DIR=/etc/pki/omni-ca
OMNI_TLS=/etc/omni/tls
DEX_TLS=/etc/dex/tls
OMNI_CONF=/etc/omni/config.yaml
DEX_CONF=/etc/dex/dex.yaml
OMNI_ASC=/etc/omni/omni.asc
CA_BUNDLE=/etc/omni/tls/ca-bundle.crt
ANCHOR=/etc/pki/ca-trust/source/anchors/omni-local-ca.crt
DAYS_CA=3650
DAYS_LEAF=825

mkdir -p "$CA_DIR" "$OMNI_TLS" "$DEX_TLS" /var/lib/omni/etcd /etc/omni /etc/dex
# Dir is traversable so anyone can read the public CA cert; the CA *key*
# is protected with 0600 below.
chmod 755 "$CA_DIR"

# Determine hostname and primary non-loopback IPv4 (best-effort, operator can override later).
HOST_NAME=$(hostname -f 2>/dev/null || hostname -s 2>/dev/null || echo omni.local)
HOST_IP=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)
HOST_IP=${HOST_IP:-127.0.0.1}

echo "[omni-bootstrap] hostname=$HOST_NAME ip=$HOST_IP"

# ---------------------------------------------------------------------------
# 1. Root CA
# ---------------------------------------------------------------------------
if [[ ! -f $CA_DIR/ca.key ]]; then
  echo "[omni-bootstrap] generating Root CA at $CA_DIR"
  openssl genrsa -out "$CA_DIR/ca.key" 4096
  openssl req -x509 -new -nodes -sha256 -days "$DAYS_CA" \
    -key "$CA_DIR/ca.key" \
    -subj "/CN=Omni Local Root CA/O=rl-bootc" \
    -out "$CA_DIR/ca.crt"
  # CA key stays root-only; it is not mounted into any container.
  chmod 600 "$CA_DIR/ca.key"
  chmod 644 "$CA_DIR/ca.crt"
fi

# Install the CA into the host trust store (idempotent).
if [[ ! -f $ANCHOR ]] || ! cmp -s "$CA_DIR/ca.crt" "$ANCHOR"; then
  cp "$CA_DIR/ca.crt" "$ANCHOR"
  update-ca-trust extract
fi

# ---------------------------------------------------------------------------
# 2. Leaf certs: Omni and Dex (signed by the CA above)
# ---------------------------------------------------------------------------
gen_leaf() {
  local outdir="$1" cn="$2"
  if [[ -f $outdir/tls.crt && -f $outdir/tls.key ]]; then
    return 0
  fi
  echo "[omni-bootstrap] issuing leaf cert for $cn -> $outdir"
  local sans="DNS:$HOST_NAME,DNS:localhost,IP:$HOST_IP,IP:127.0.0.1"
  openssl genrsa -out "$outdir/tls.key" 2048
  openssl req -new -key "$outdir/tls.key" -subj "/CN=$cn" -out "$outdir/tls.csr"
  openssl x509 -req -in "$outdir/tls.csr" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
    -days "$DAYS_LEAF" -sha256 \
    -extfile <(printf "subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\n" "$sans") \
    -out "$outdir/tls.crt"
  rm -f "$outdir/tls.csr"
  # Append CA so the file is a full chain.
  cat "$CA_DIR/ca.crt" >> "$outdir/tls.crt"
  # Mounted :ro into containers that may run as non-root (e.g. dex uid 1001).
  chmod 644 "$outdir/tls.crt" "$outdir/tls.key"
}

gen_leaf "$OMNI_TLS" "$HOST_NAME"
gen_leaf "$DEX_TLS"  "$HOST_NAME"

# ---------------------------------------------------------------------------
# 3. CA bundle for the Omni container (system bundle + our local CA)
# ---------------------------------------------------------------------------
if [[ ! -f $CA_BUNDLE ]] || [[ $CA_DIR/ca.crt -nt $CA_BUNDLE ]]; then
  echo "[omni-bootstrap] writing $CA_BUNDLE"
  {
    cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
    echo
    cat "$CA_DIR/ca.crt"
  } > "$CA_BUNDLE"
  chmod 644 "$CA_BUNDLE"
fi

# ---------------------------------------------------------------------------
# 4. Etcd encryption key (gpg-armored)
# ---------------------------------------------------------------------------
if [[ ! -f $OMNI_ASC ]]; then
  echo "[omni-bootstrap] generating GPG key for Omni etcd encryption"
  GPG_TMP=$(mktemp -d)
  # Omni (gopenpgp) requires a primary cert/sign key AND a dedicated encrypt
  # subkey. Use batch --gen-key so we get exactly that shape.
  cat > "$GPG_TMP/spec" <<SPEC
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: cert,sign
Subkey-Type: RSA
Subkey-Length: 4096
Subkey-Usage: encrypt
Name-Real: Omni etcd
Name-Email: omni@$HOST_NAME
Expire-Date: 0
%commit
SPEC
  GNUPGHOME=$GPG_TMP gpg --batch --gen-key "$GPG_TMP/spec"
  GNUPGHOME=$GPG_TMP gpg --armor --export-secret-keys > "$OMNI_ASC"
  rm -rf "$GPG_TMP"
  # Read by the Omni container; host is single-tenant.
  chmod 644 "$OMNI_ASC"
fi

# ---------------------------------------------------------------------------
# 5. Default /etc/omni/config.yaml
# ---------------------------------------------------------------------------
if [[ ! -f $OMNI_CONF ]]; then
  echo "[omni-bootstrap] writing default $OMNI_CONF"
  cat > "$OMNI_CONF" <<EOF
# Auto-generated by omni-bootstrap.service. Edit freely; this file will not
# be overwritten on subsequent boots.
account:
  id: $(uuidgen)

auth:
  initialUsers:
    - admin@$HOST_NAME
  auth0:
    enabled: false
  oidc:
    enabled: true
    providerURL: https://$HOST_NAME:5556
    clientID: omni
    clientSecret: omni-dex-secret
    scopes:
      - openid
      - profile
      - email

services:
  api:
    endpoint: 0.0.0.0:443
    advertisedURL: https://$HOST_NAME
    certFile: /etc/omni/tls/tls.crt
    keyFile:  /etc/omni/tls/tls.key
  kubernetesProxy:
    endpoint: 0.0.0.0:8100
    advertisedURL: https://$HOST_NAME:8100
    certFile: /etc/omni/tls/tls.crt
    keyFile:  /etc/omni/tls/tls.key
  machineAPI:
    advertisedURL: grpc://$HOST_NAME:8090
  siderolink:
    joinTokensMode: strict
    wireGuard:
      advertisedEndpoint: $HOST_IP:50180

storage:
  default:
    kind: etcd
    etcd:
      embedded: true
      embeddedDBPath: /var/lib/omni/etcd/
      privateKeySource: "file:///omni.asc"
  sqlite:
    path: /var/lib/omni/sqlite.db
EOF
  chmod 644 "$OMNI_CONF"
fi

# ---------------------------------------------------------------------------
# 6. Default /etc/dex/dex.yaml (admin / admin -- change in production!)
# ---------------------------------------------------------------------------
if [[ ! -f $DEX_CONF ]]; then
  echo "[omni-bootstrap] writing default $DEX_CONF (admin password: admin)"
  HASH=$(htpasswd -nbBC 12 admin admin | cut -d: -f2)
  cat > "$DEX_CONF" <<EOF
# Auto-generated by omni-bootstrap.service. Default credentials:
#   email:    admin@$HOST_NAME
#   password: admin
# CHANGE THIS BEFORE EXPOSING THIS HOST.
issuer: https://$HOST_NAME:5556
storage:
  type: memory
web:
  https: 0.0.0.0:5556
  tlsCert: /etc/dex/tls/tls.crt
  tlsKey:  /etc/dex/tls/tls.key
enablePasswordDB: true
staticClients:
  - name: Omni
    id: omni
    secret: omni-dex-secret
    redirectURIs:
      - https://$HOST_NAME/oidc/consume
staticPasswords:
  - email: admin@$HOST_NAME
    username: admin
    preferredUsername: admin
    hash: "$HASH"
EOF
  chmod 644 "$DEX_CONF"
fi

echo "[omni-bootstrap] done"
