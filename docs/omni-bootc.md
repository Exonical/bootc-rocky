# Self-hosted Omni on Rocky Linux bootc

This document is the canonical reference for the Omni + Dex stack layered on
top of the Rocky Linux 10 bootc base image in this repository. It covers the
full lifecycle: build, deploy, authenticate, operate, and recover.

- **Base image**: Rocky Linux 10 bootc (built from `@10/Containerfile`)
- **Layered image**: base + Quadlets + bootstrap (built from `@10/Containerfile.vm`)
- **Runtime**: systemd-managed Podman Quadlets for Omni and Dex, fronted by a
  first-boot bootstrap service that establishes a local PKI
- **Provisioning**: per-VM via NoCloud cloud-init seed ISO (no credentials in
  the image)

```
                    bootc image (rocky-bootc-vm)
                  +------------------------------+
                  |  /usr/share/containers/      |
                  |    systemd/                  |
                  |      omni.container          |
                  |      dex.container           |
                  |  /usr/libexec/               |
                  |    omni-bootstrap            |
                  |  /usr/lib/systemd/system/    |
                  |    omni-bootstrap.service    |
                  +---------------+--------------+
                                  |
                         bootc-image-builder
                                  |
                                  v
                          qcow2 disk image
                                  |
                     +------------+---------------+
                     |                            |
                 virt-install               NoCloud seed ISO
                     |                   (user-data + meta-data)
                     v                            |
                 +--------------------------------+
                 |           running VM           |
                 |                                |
                 |  systemd boot                  |
                 |    -> network-online           |
                 |    -> cloud-init               |  (admin user, SSH, hostname)
                 |    -> omni-bootstrap           |  (CA, certs, gpg, configs)
                 |    -> dex.service              |  (OIDC on :5556)
                 |    -> omni.service             |  (API/UI on :443,8090,8100,50180)
                 +--------------------------------+
```

## Repository layout

```
@/home/banglin/Documents/rl-bootc/
├── 10/
│   ├── Containerfile             # base Rocky Linux 10 bootc image
│   ├── Containerfile.vm          # layered image with Omni stack
│   ├── rockylinux-10.yaml        # bootc-base-imagectl manifest for the base
│   ├── quadlets/
│   │   ├── omni.container        # Quadlet -> omni.service
│   │   ├── dex.container         # Quadlet -> dex.service
│   │   ├── omni-config.yaml.example
│   │   └── README.md             # short operator first-boot reference
│   └── scripts/
│       ├── omni-bootstrap.service
│       └── omni-bootstrap.sh     # idempotent PKI + config generator
├── docs/
│   └── omni-bootc.md             # this file
├── output/                       # build artifacts (gitignored)
└── Makefile                      # base image build targets
```

## Host prerequisites (where you run the build)

```bash
sudo dnf install -y podman qemu-img libvirt virt-install genisoimage
sudo systemctl enable --now libvirtd virtnetworkd
sudo usermod -aG libvirt "$USER"     # log out / back in after this
```

## Build

The build has two layers plus a qcow2 conversion.

### 1. Base image (`rocky-bootc`)

```bash
make PLATFORM=linux/amd64 IMAGE_NAME=rocky-bootc VERSION_MAJOR=10
```

This uses `bootc-base-imagectl` with `@10/rockylinux-10.yaml` and produces a
local OCI image at `localhost/rocky-bootc:latest`.

### 2. Layered image (`rocky-bootc-vm`)

```bash
sudo podman build -f 10/Containerfile.vm -t rocky-bootc-vm .
```

What the layered Containerfile does:

| Step | Purpose |
| --- | --- |
| `dnf install httpd-tools cloud-init` (no weak deps) | `htpasswd` (bootstrap bcrypt), cloud-init |
| `rpm -e --nodeps dhcpcd` + userdel/groupdel | remove hard-pulled dhcpcd (NM handles networking) |
| `ln -sf ../cloud-init.target default.target.wants/` | enable cloud-init the RHEL/CentOS bootc way |
| `rm -rf /var/{cache,log,lib/{dnf,cloud,dhcpcd},tmp}/*` | satisfy bootc lint (`/var` must be empty in image) |
| `COPY 10/quadlets/*.container /usr/share/containers/systemd/` | install vendor-managed quadlets |
| `COPY omni-bootstrap.sh -> /usr/libexec/omni-bootstrap` | first-boot PKI script |
| `COPY omni-bootstrap.service -> /usr/lib/systemd/system/` + `systemctl enable` | wire the bootstrap into boot |
| `systemctl enable podman.socket` | expose rootful podman API |
| `bootc container lint --fatal-warnings` | hard-fail the build on bootc anti-patterns |

### 3. qcow2 for KVM/libvirt

```bash
sudo rm -rf output && mkdir -p output && \
sudo podman run --rm -it --privileged \
  --security-opt=label=type:unconfined_t \
  -v "$(pwd)/output:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 localhost/rocky-bootc-vm:latest
ls -lh output/qcow2/disk.qcow2
```

Supported `--type` values: `qcow2` (libvirt), `vmdk` (VMware),
`raw`, `iso` (Anaconda installer), `ami` (EC2).

## Airgap supply chain (Zarf-first, one bootstrap exception)

Every container image the VM ingests is digest-pinned and (for all but
one) cosign-signed before it ever touches the host. There are exactly
two delivery mechanisms, split by a single unavoidable constraint:

| Mechanism | What goes here | Why |
| --- | --- | --- |
| **Zot bootstrap** (Containerfile ARG) | Zot itself — 1 image | Zarf mirrors *into* a registry; Zot *is* the registry. It can't deliver itself. |
| **Zarf packages** (`10/zarf/*/zarf.yaml`) | Everything else: Omni, Dex, Talos K8s bundle, Cilium, any future workload | Uniform supply-chain story: digests, cosign signatures, SBOMs |

Both funnels end at the same place — Zot serving on `localhost:5000`.
Downstream Talos workers see one mirror endpoint regardless of which
funnel placed the image.

### Zot bootstrap

Two `ARG`s in `@10/Containerfile.vm` pin the registry image:

```dockerfile
ARG ZOT_IMAGE=ghcr.io/project-zot/zot-minimal-linux-amd64:v2.1.16
ARG ZOT_DIGEST=sha256:1330a6f5710cdbd3469faea30912615d87f5c75a4eeb6c4ea20fea815095dd09
```

Build-time: `skopeo copy docker://<image>@<digest>` into
`/usr/share/zot-preload/<repo>/`, then re-hash the on-disk manifest and
fail the build if it drifts from `ZOT_DIGEST`. The resolved ref is also
written to `/usr/share/zot-preload/BOOTSTRAP_REF` for audit.

First-boot: `airgap-image-load.service` (`Before=zot.service`) walks
the preloaded tree and imports every OCI layout into podman
containers-storage. Idempotency sentinel:
`/var/lib/containers/storage/.airgap-loaded`.

To bump Zot: `make zot-refresh` prints the current upstream digest for
the pinned tag; review the diff, edit `ARG ZOT_DIGEST=…` in the
Containerfile, rebuild.

### Zarf packages

Each logical bundle lives under `@10/zarf/<name>-<version>/zarf.yaml`.
Current packages:

- `@10/zarf/omni-control-plane-1.7.1/zarf.yaml` — Omni + Dex (host quadlet stack)
- `@10/zarf/talos-k8s-1.36.0/zarf.yaml` — Talos K8s 1.36.0 bundle
- `@10/zarf/cilium-1.19.3/zarf.yaml` — Cilium 1.19.3

Example (Cilium):

```yaml
kind: ZarfPackageConfig
metadata:
  name: cilium
  version: 1.19.3
  architecture: amd64
components:
  - name: cilium-images
    required: true
    images:
      - quay.io/cilium/cilium:v1.19.3
      - …
```

#### Build-time

```bash
make zarf-keygen        # one-time: cosign generate-key-pair under 10/zarf/
                        # commit cosign.pub; .key is gitignored
make zarf-packages      # for each 10/zarf/*/zarf.yaml run
                        #   `zarf package create … --signing-key cosign.key`
                        # Output: output/zarf/zarf-package-<name>-amd64-<ver>.tar.zst
make image-vm           # bakes binary + packages + cosign.pub into the VM
```

`make image-vm` requires `zarf-packages-check` (at least one signed
package and a committed `cosign.pub`).

#### First-boot

`zarf-package-publish.service`
(`After=zot.service Before=omni.service dex.service`):

1. `zarf package inspect <pkg> --key /etc/zarf/cosign.pub` — verifies
   cosign signature against the trust root baked into the image.
   Fails closed.
2. `zarf package mirror-resources <pkg> --registry-url=localhost:5000 …`
   — pushes every image into Zot with the upstream registry host
   stripped (mirror semantics). Idempotency sentinel:
   `/var/lib/zarf/.published`.

#### Talos worker mirror config

Identical regardless of which pipeline placed the images:

```yaml
machine:
  registries:
    mirrors:
      registry.k8s.io: { endpoints: [ "http://<omni-host>:5000" ] }
      ghcr.io:         { endpoints: [ "http://<omni-host>:5000" ] }
      quay.io:         { endpoints: [ "http://<omni-host>:5000" ] }
```

### Inventory / audit trail

A reviewer/auditor can prove byte-for-byte equality of the Zot
bootstrap on a running VM:

```bash
sudo cat /usr/share/zot-preload/BOOTSTRAP_REF
# ghcr.io/project-zot/zot-minimal-linux-amd64:v2.1.16@sha256:…
sudo cat /usr/share/zot-preload/inventory.sha256
# sha256:abc...
sudo find /usr/share/zot-preload \
     -type f \( -name index.json -o -name oci-layout -o -path '*/blobs/sha256/*' \) \
     -printf '%P\n' | LC_ALL=C sort \
   | xargs -I{} sha256sum /usr/share/zot-preload/{} | sha256sum
# must match inventory.sha256
```

For every Zarf package:

```bash
zarf package inspect /usr/share/zarf/packages/zarf-package-cilium-amd64-1.19.3.tar.zst \
  --key /etc/zarf/cosign.pub
# prints package manifest with image digests, embedded SBOMs, verified identity
```

### Adding new content

| To add | Edit | Then |
| --- | --- | --- |
| Bump the Zot registry itself | `ARG ZOT_DIGEST=…` in `@10/Containerfile.vm` (run `make zot-refresh` to find the new digest) | `make image-vm` |
| A new image *for the host stack* (Omni/Dex bump) | `@10/zarf/omni-control-plane-X.Y.Z/zarf.yaml` | `make zarf-packages && make image-vm` |
| A new image *for the downstream cluster* | `@10/zarf/<bundle>/zarf.yaml` (existing or new package dir) | `make zarf-packages && make image-vm` |

## Deploy

The qcow2 has **no credentials and no hostname baked in**. Provisioning is
per-VM via a NoCloud cloud-init seed ISO containing `user-data` and
`meta-data`. The hostname set by cloud-init is the only environment-specific
input the bootstrap needs -- from it, `omni-bootstrap.service` derives:

- CN and SANs for the Omni and Dex server certs (FQDN, `localhost`, IP, 127.0.0.1)
- `services.api.advertisedURL` in `/etc/omni/config.yaml` -> `https://<fqdn>`
- `services.machineAPI.advertisedURL`, `services.kubernetesProxy.advertisedURL`
- `auth.oidc.providerURL` -> `https://<fqdn>:5556`
- `issuer` and `staticClients[].redirectURIs` in `/etc/dex/dex.yaml`
- `staticPasswords[].email` -> `admin@<fqdn>` and `auth.initialUsers`

So there is **one golden qcow2** -- no hostname, no credentials, no env data
baked in. Each environment (`lab1.local`, `lab2.local`,
`omni.prod.example.com`, ...) is spun up by **copying that same qcow2**
byte-for-byte and attaching a different tiny (~400 KB) NoCloud seed ISO.

### Two-phase workflow

Phase 1 -- **image build** (once, per image version):

```bash
make image-vm              # Containerfile.vm -> localhost/rocky-bootc-vm:latest
make qcow2                 # -> output/qcow2/disk.qcow2   (the golden image)
```

Phase 2 -- **VM deploy** (once per environment, N times, reusing the same disk):

```bash
make deploy HOSTNAME=lab1
make deploy HOSTNAME=lab2 DOMAIN=example.com
make deploy HOSTNAME=edge-pdx DOMAIN=example.com \
            IP=192.168.50.10/24 GATEWAY=192.168.50.1 DNS=192.168.50.2

make undeploy HOSTNAME=lab1
```

Each `make deploy` call:
1. Generates `<hostname>-seed.iso` via `scripts/make-seed.sh`.
2. Copies `output/qcow2/disk.qcow2` to `<hostname>.qcow2`
   (per-VM since VMs diverge state over time, but the source is always the
   same golden image).
3. `virt-install` imports both and boots.

The only per-environment artifact is the seed ISO. Nothing in the golden
qcow2 is rebuilt between environments.

#### Variables and where they apply

Build-phase (affects the golden image):

| Var | Default | Purpose |
| --- | --- | --- |
| `VM_IMAGE_NAME` | `rocky-bootc-vm` | tag for the layered OCI image |
| `VERSION_MAJOR` | `10` | picks `$(VERSION_MAJOR)/Containerfile.vm` |
| `OUTPUT_DIR` | `output` | where `bootc-image-builder` writes the qcow2 |

Deploy-phase (affects the individual VM only):

| Var | Default | Purpose |
| --- | --- | --- |
| `HOSTNAME` | `omni-lab` | short hostname; also libvirt domain name |
| `DOMAIN` | `local` | DNS domain (FQDN = `$HOSTNAME.$DOMAIN`) |
| `SSH_KEY` | `~/.ssh/id_ed25519.pub` | public key injected via cloud-init |
| `PASSWORD` | `admin:changeme` | `user:pass` for console login |
| `IP` | (unset -> DHCP) | `a.b.c.d/prefix` for static network |
| `GATEWAY` | (unset) | required with `IP` |
| `DNS` | `1.1.1.1` | nameservers |
| `MEMORY` | `4096` | MiB of RAM |
| `VCPUS` | `2` | vcpu count |
| `DISK_SIZE` | `40G` | grown from baked-in 10 GiB per VM |
| `NETWORK` | `default` | libvirt network name |
| `IMAGES_DIR` | `/var/lib/libvirt/images` | destination for per-VM disk + seed |

### The manual path

### 1. Build the seed ISO

```bash
cat > /tmp/user-data <<EOF
#cloud-config
hostname: omni-lab
fqdn: omni-lab.local
manage_etc_hosts: true

users:
  - name: admin
    groups: [wheel]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub)

chpasswd:
  list: |
    admin:changeme
  expire: false
ssh_pwauth: true
EOF

cat > /tmp/meta-data <<EOF
instance-id: omni-lab-$(date +%s)
local-hostname: omni-lab
EOF

sudo genisoimage -output /var/lib/libvirt/images/omni-lab-seed.iso \
  -volid cidata -joliet -rock /tmp/user-data /tmp/meta-data
```

### 2. Install into libvirt

```bash
sudo install -o qemu -g qemu -m 0640 \
  output/qcow2/disk.qcow2 /var/lib/libvirt/images/omni-lab.qcow2
sudo qemu-img resize /var/lib/libvirt/images/omni-lab.qcow2 40G

sudo virt-install \
  --name omni-lab \
  --memory 4096 --vcpus 2 \
  --os-variant rocky10 \
  --disk path=/var/lib/libvirt/images/omni-lab.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/omni-lab-seed.iso,device=cdrom \
  --network network=default,model=virtio \
  --graphics none --console pty,target_type=serial \
  --import --noautoconsole
```

### 3. Wait for the stack to come up

```bash
sudo virsh domifaddr omni-lab            # find the IP
ssh admin@<ip>
cloud-init status --long                 # done, datasource NoCloud
systemctl status omni-bootstrap dex omni # all active (running|exited)
```

First-boot timing: cloud-init ~30-60s, bootstrap ~10s, dex ~5s, omni ~30s
(includes pulling `ghcr.io/siderolabs/omni` and `ghcr.io/dexidp/dex`).

## Runtime view

### Services and ports

| Service | Unit | Container | Ports | Process label |
| --- | --- | --- | --- | --- |
| Omni API/UI | `omni.service` | `ghcr.io/siderolabs/omni:v1.7.1` | `:443` tcp | `spc_t` |
| Omni machine API | " | " | `:8090` tcp | " |
| Omni k8s proxy | " | " | `:8100` tcp | " |
| SideroLink | " | " | `:50180` udp (WireGuard) | " |
| Dex OIDC | `dex.service` | `ghcr.io/dexidp/dex:v2.45.1` | `:5556` tcp | `container_t` |

### On-disk layout (persistent across reboots and `bootc upgrade`)

| Path | Owner | Purpose | Created by |
| --- | --- | --- | --- |
| `/etc/pki/omni-ca/ca.crt` | root:root 0644 | Public Root CA | bootstrap |
| `/etc/pki/omni-ca/ca.key` | root:root 0600 | CA private key | bootstrap |
| `/etc/pki/ca-trust/source/anchors/omni-local-ca.crt` | root:root 0644 | host trust anchor | bootstrap |
| `/etc/omni/config.yaml` | root:root 0644 | Omni YAML config | bootstrap |
| `/etc/omni/omni.asc` | root:root 0644 | etcd encryption key (GPG, has encrypt subkey) | bootstrap |
| `/etc/omni/tls/{tls.crt,tls.key}` | root:root 0644 | Omni server cert + key | bootstrap |
| `/etc/omni/tls/ca-bundle.crt` | root:root 0644 | system bundle + local CA (SSL_CERT_FILE) | bootstrap |
| `/etc/dex/dex.yaml` | root:root 0644 | Dex config (static admin user) | bootstrap |
| `/etc/dex/tls/{tls.crt,tls.key}` | root:root 0644 | Dex server cert + key | bootstrap |
| `/var/lib/omni/etcd/` | root:root 0755 | embedded etcd datastore | omni container |
| `/var/lib/omni/sqlite.db*` | root:root | machine/audit logs | omni container |
| `/var/lib/omni/.bootstrap-done` | root:root | sentinel (prevents re-bootstrap) | bootstrap ExecStartPost |

File modes are intentionally 0644 on mounted-into-container files because the
Dex container runs as UID 1001 inside its user namespace; the host is
single-tenant so there is no additional exposure.

## PKI design

A single local Root CA signs both the Omni and Dex leaf certs. Clients that
trust the CA (including Omni's OIDC client via `SSL_CERT_FILE`) trust both
services transparently.

```
     /etc/pki/omni-ca/ca.crt   (CN=Omni Local Root CA, 10y)
          |      signs
          +--> /etc/omni/tls/tls.crt   (CN=<fqdn>, SANs: fqdn,localhost,IP,127.0.0.1, 825d)
          +--> /etc/dex/tls/tls.crt    (CN=<fqdn>, same SANs, 825d)

     installed at /etc/pki/ca-trust/source/anchors -> host trusts automatically
     merged into /etc/omni/tls/ca-bundle.crt -> Omni container trusts via SSL_CERT_FILE
```

Everything is generated by `@10/scripts/omni-bootstrap.sh` on first boot via
`openssl` and `gpg`. The bootstrap is idempotent: any pre-existing file is
left alone. To rotate, delete the file in question and re-run
`sudo /usr/libexec/omni-bootstrap`.

The etcd encryption key is a GPG primary `cert,sign` plus an `encrypt`
subkey, created with `gpg --batch --gen-key` from a spec file. Omni's
gopenpgp dependency requires the encrypt subkey explicitly.

## Authentication flow

1. Browser hits `https://<fqdn>/`.
2. Omni's web layer redirects to Dex at `https://<fqdn>:5556/auth`.
3. Dex shows the static-password login form.
4. User enters the full email (`admin@<fqdn>`) and password (`admin`).
5. Dex signs an OIDC token, redirects to `https://<fqdn>/oidc/consume`.
6. Omni verifies the token against its configured issuer and the CA bundle.
7. Omni checks that the email is in `auth.initialUsers` in
   `/etc/omni/config.yaml`; if yes, a session is issued.
8. First login prompts for EULA acceptance (required since Omni 1.7).

Relevant config snippets (generated by bootstrap):

```yaml
# /etc/omni/config.yaml
auth:
  initialUsers: [admin@<fqdn>]
  oidc:
    enabled: true
    providerURL: https://<fqdn>:5556
    clientID: omni
    clientSecret: omni-dex-secret
    scopes: [openid, profile, email]
```

```yaml
# /etc/dex/dex.yaml
issuer: https://<fqdn>:5556
staticClients:
  - name: Omni
    id: omni
    secret: omni-dex-secret
    redirectURIs: [https://<fqdn>/oidc/consume]
staticPasswords:
  - email: admin@<fqdn>
    username: admin
    hash: "<bcrypt>"
```

## SELinux posture

SELinux is **enforcing** end-to-end.

| Subject | SELinux type | Rationale |
| --- | --- | --- |
| host processes | stock `targeted` policy | unchanged from Rocky 10 |
| dex container | `container_t` (default) + MCS | no special privileges needed |
| omni container | `spc_t` (`SecurityLabelType=spc_t`) | needs `NET_ADMIN`, `/dev/net/tun`, WireGuard UAPI unix sockets |
| bind mounts | `container_file_t` via `:Z` | per-container MCS category |

Verify on a running VM:

```bash
getenforce                                     # Enforcing
sudo podman inspect omni --format '{{.ProcessLabel}}'
# system_u:system_r:spc_t:s0:cNNN,cNNN
sudo podman inspect dex --format '{{.ProcessLabel}}'
# system_u:system_r:container_t:s0:cNNN,cNNN
sudo ausearch -m avc --start today --raw       # empty -> no denials
```

If you want tighter confinement than `spc_t`:

```bash
sudo sed -i 's/^SecurityLabelType=spc_t/# &/' /etc/containers/systemd/omni.container
sudo systemctl daemon-reload && sudo systemctl restart omni
# reproduce the workload you care about, then:
sudo ausearch -m avc --start recent | audit2allow -M omni-local
sudo semodule -i omni-local.pp
```

## Day-2 operations

### Change the default Dex password

```bash
HASH=$(htpasswd -nbBC 12 admin 'a-strong-password' | cut -d: -f2)
sudo sed -i "s|hash:.*|hash: \"$HASH\"|" /etc/dex/dex.yaml
sudo systemctl restart dex
```

### Rotate TLS leaf certs (CA unchanged)

```bash
sudo rm -f /etc/omni/tls/tls.{crt,key} /etc/dex/tls/tls.{crt,key}
sudo /usr/libexec/omni-bootstrap
sudo systemctl restart omni dex
```

### Replace the local CA with a real one

```bash
# 1. Put your full-chain cert + private key at the paths Omni/Dex expect:
sudo install -m 0644 myca-chain.pem /etc/omni/tls/tls.crt
sudo install -m 0644 myca-chain.pem /etc/dex/tls/tls.crt
sudo install -m 0644 myca.key       /etc/omni/tls/tls.key
sudo install -m 0644 myca.key       /etc/dex/tls/tls.key

# 2. If the issuer's root isn't already in the system bundle, add it:
sudo install -m 0644 real-root.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

# 3. Rebuild the Omni container's CA bundle:
{ cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; echo; cat real-root.pem; } \
  | sudo tee /etc/omni/tls/ca-bundle.crt >/dev/null

sudo systemctl restart omni dex
```

### Backup

```bash
sudo systemctl stop omni                  # quiesce etcd
sudo tar --acls --xattrs -czpf /root/omni-backup-$(date +%F).tar.gz \
  /etc/pki/omni-ca /etc/omni /etc/dex /var/lib/omni
sudo systemctl start omni
```

### Restore

```bash
sudo systemctl stop omni dex
sudo tar --acls --xattrs -xzpf /root/omni-backup-YYYY-MM-DD.tar.gz -C /
sudo touch /var/lib/omni/.bootstrap-done     # skip bootstrap
sudo systemctl start dex omni
```

### Full reset (destroy all state)

```bash
sudo systemctl stop omni dex
sudo rm -rf /etc/pki/omni-ca /etc/omni /etc/dex /var/lib/omni
sudo systemctl start omni-bootstrap          # regenerates everything
sudo systemctl start dex omni
```

### `bootc upgrade` semantics

- `/usr` is replaced wholesale. New vendor quadlets, bootstrap, and binaries
  take effect after reboot.
- `/etc` undergoes a 3-way merge; anything the bootstrap created (CA, configs,
  certs, omni.asc) is "purely local" (no counterpart in `/usr/etc`), so it's
  preserved untouched.
- `/var` is shared across deployments, so etcd and SQLite data survive.
- The `omni-bootstrap.service` gate (`ConditionPathExists=!/var/lib/omni/.bootstrap-done`)
  ensures it does **not** re-run on upgrade.
- If a new image version changes bootstrap defaults that you want applied,
  delete the file you want regenerated (or all of them for a clean rebuild)
  before rebooting.

### Override a Quadlet at runtime

Admin location wins. Copy from `/usr/share` to `/etc`, edit, reload.

```bash
sudo cp /usr/share/containers/systemd/omni.container /etc/containers/systemd/
sudo $EDITOR /etc/containers/systemd/omni.container
sudo systemctl daemon-reload
sudo systemctl restart omni
```

## Troubleshooting quick reference

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `dex[...]: permission denied /etc/dex/dex.yaml` | Config file chmod 600 + dex runs as uid 1001 | `chmod 0644 /etc/dex/dex.yaml` (or rerun bootstrap -- fixed in current script) |
| `cannot encrypt a message to key id ... because it has no valid encryption keys` | GPG key lacks encrypt subkey | regenerate via bootstrap (batch `--gen-key` produces cert/sign + encrypt) |
| `error listening on uapi socket: permission denied` | SELinux blocking WireGuard UAPI socket | `SecurityLabelType=spc_t` in `omni.container` |
| `curl: (77) error setting certificate file: /etc/pki/omni-ca/ca.crt` | CA dir is `chmod 700`, unprivileged user can't traverse | `chmod 0755 /etc/pki/omni-ca` |
| `bootc container lint --fatal-warnings` fails on `var-tmpfiles` | dnf scriptlets left dirs under `/var` | `rm -rf /var/{cache,log,lib/{dnf,...},tmp}/*` after install |
| `bootc container lint` fails on `sysusers: dhcpcd` | cloud-init Requires dhcpcd (not weak dep) | `rpm -e --nodeps dhcpcd && userdel dhcpcd && groupdel dhcpcd` |
| Redirect loop / `redirect_uri_mismatch` | Dex `redirectURIs` doesn't match Omni advertised URL | edit `/etc/dex/dex.yaml` |
| Omni logs `reconcile succeeded` but port 443 not listening | etcd startup in progress; or Omni just crashed | check `podman ps`; if stopped, `podman logs omni` |

## Security notes

- **Passwords**: Dex ships with `admin/admin`. Rotate on first login (see
  Day-2 ops). The bootstrap explicitly marks the defaults with `CHANGE THIS
  BEFORE EXPOSING THIS HOST` in `/etc/dex/dex.yaml`.
- **CA key**: `ca.key` is `chmod 0600 root:root` in a `chmod 0755` dir, on an
  xfs filesystem with default ACLs. Dir traversal is permitted (so `ca.crt`
  can be read by the admin user) but the key is root-only.
- **Encryption at rest**: Omni's etcd is encrypted at rest using the GPG
  subkey. Losing `/etc/omni/omni.asc` makes all etcd data permanently
  unreadable. Back it up somewhere other than the VM itself.
- **Firewall**: `firewalld` is installed and enabled in the image; a bundled
  `omni` firewalld service (`/usr/lib/firewalld/services/omni.xml`) is
  pre-added to the `public` zone at build time using `firewall-offline-cmd`.
  The VM boots with only these ports open:
  `22/tcp` (ssh), `443/tcp`, `5556/tcp`, `8090/tcp`, `8100/tcp`, `50180/udp`.
  Inspect with `sudo firewall-cmd --list-all` and modify the standard way
  (`firewall-cmd --zone=public --add-service=... --permanent && firewall-cmd --reload`).
- **Network model**: The Omni container uses `Network=host` so it shares the
  VM's network namespace. SideroLink WireGuard runs as a kernel interface on
  the host network namespace.

## Upstream references

- Omni self-hosted guide: https://docs.siderolabs.com/omni/self-hosted/run-omni-on-prem
- Omni YAML configuration reference: https://docs.siderolabs.com/omni/reference/omni-configuration
- Dex OIDC: https://dexidp.io/docs/
- bootc: https://containers.github.io/bootc/
- bootc-image-builder: https://osbuild.org/docs/bootc/
- Podman Quadlets: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- container-selinux policy types: https://github.com/containers/container-selinux
