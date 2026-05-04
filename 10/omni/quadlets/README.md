# Omni 1.7.1 + Dex on Rocky Linux bootc (operator quickstart)

This image runs [Sidero Labs Omni](https://docs.siderolabs.com/omni/) v1.7.1
on-prem behind a Dex OIDC provider. A first-boot bootstrap service generates
a local Root CA, signs server certs for both Omni and Dex with it, installs
the CA into the host's trust store, and writes sensible default configuration
so the stack comes up unattended.

> For the full project reference (architecture, build, deploy, PKI design,
> SELinux, day-2 operations, troubleshooting) see `docs/omni-bootc.md`.

## Components

| Unit                       | Source                                                    | Generated location                              |
| -------------------------- | --------------------------------------------------------- | ----------------------------------------------- |
| `omni-bootstrap.service`   | `/usr/libexec/omni-bootstrap` (one-shot, idempotent)      | `/var/lib/omni/.bootstrap-done`                 |
| `dex.service`              | `/usr/share/containers/systemd/dex.container`             | systemd-generator at boot                       |
| `omni.service`             | `/usr/share/containers/systemd/omni.container`            | systemd-generator at boot                       |

## What the bootstrap creates

| Path                                  | Contents                                                  |
| ------------------------------------- | --------------------------------------------------------- |
| `/etc/pki/omni-ca/ca.{crt,key}`       | 4096-bit Root CA, 10-year validity                        |
| `/etc/pki/ca-trust/source/anchors/`   | CA copy + `update-ca-trust extract` so the host trusts it |
| `/etc/omni/tls/tls.{crt,key}`         | Server cert chain for Omni (signed by the CA)             |
| `/etc/omni/tls/ca-bundle.crt`         | System bundle + local CA, mounted into the Omni container |
| `/etc/dex/tls/tls.{crt,key}`          | Server cert chain for Dex (signed by the CA)              |
| `/etc/omni/omni.asc`                  | GPG-armored etcd encryption key                           |
| `/etc/omni/config.yaml`               | Default Omni config (OIDC -> Dex, embedded etcd, SQLite)  |
| `/etc/dex/dex.yaml`                   | Default Dex config; admin user `admin@<host>` / `admin`   |

All leaf certs include SANs for the host's FQDN, `localhost`, primary IPv4,
and `127.0.0.1`. Bootstrap is idempotent: existing files are never overwritten,
so operator edits survive reboots.

## First boot

```text
boot
  -> network-online.target
  -> omni-bootstrap.service   (CA, certs, configs, gpg key)
  -> dex.service              (Dex on :5556 with cert from local CA)
  -> omni.service             (Omni on :443/:8090/:8100, OIDC -> Dex)
```

After the first boot completes:

1. Browse to `https://<vm-ip>/`.
2. Accept the Omni EULA on first login.
3. Authenticate with `admin@<hostname>` / `admin` (Dex static password).
4. **Change the password** in `/etc/dex/dex.yaml` (re-hash with `htpasswd -BnC 12 admin`) and `systemctl restart dex omni`.

## Trusting the local CA from your workstation

Copy `/etc/pki/omni-ca/ca.crt` from the VM to your laptop and import it into
your browser / OS trust store. Without that, browsers will warn on the
self-signed leaf cert.

```bash
scp <user>@<vm>:/etc/pki/omni-ca/ca.crt omni-local-ca.crt
# Linux (system trust):
sudo cp omni-local-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract
# macOS:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain omni-local-ca.crt
```

## SELinux

The image runs with SELinux in **enforcing** mode; nothing is disabled.

- **Dex** runs as the default `container_t` with per-container MCS categories.
  Its config and TLS directories are bind-mounted with `:Z` so they're
  relabeled to `container_file_t` with matching MCS categories.
- **Omni** runs as `spc_t` (super-privileged container), set via
  `SecurityLabelType=spc_t` in `@/usr/share/containers/systemd/omni.container`.
  This is the container-selinux policy's designated type for workloads that
  legitimately need broad kernel-facing permissions (WireGuard UAPI sockets,
  `/dev/net/tun`, `NET_ADMIN`). SELinux stays engaged -- processes are still
  labeled and audited -- but the type is granted the permissions Omni needs.

Verify in a running VM:

```bash
getenforce                                   # Enforcing
sudo podman inspect omni --format '{{.ProcessLabel}}'
#   -> system_u:system_r:spc_t:s0:cNNN,cNNN
sudo podman inspect dex  --format '{{.ProcessLabel}}'
#   -> system_u:system_r:container_t:s0:cNNN,cNNN
sudo ausearch -m avc --start today --raw    # should be empty
```

If you want tighter confinement for Omni (custom policy instead of `spc_t`),
the workflow is:

```bash
# Temporarily switch Omni to default container_t to observe denials.
sudo sed -i 's/^SecurityLabelType=spc_t/# &/' /etc/containers/systemd/omni.container
sudo systemctl daemon-reload && sudo systemctl restart omni
# Wait for it to crash, then:
sudo ausearch -m avc -ts recent | audit2allow -M omni-local
sudo semodule -i omni-local.pp
# Restore spc_t line once the custom module fully covers the denials, or keep
# container_t if audit2allow's output is complete and minimal.
```

## Customizing

- **Use real (Let's Encrypt / corporate CA) certs**: drop them at
  `/etc/omni/tls/tls.{crt,key}` and `/etc/dex/tls/tls.{crt,key}` *before*
  first boot (e.g., via `bootc-image-builder` `--config` user files), or replace
  them after first boot and `systemctl restart omni dex`.
- **Different hostname / IP**: edit `/etc/omni/config.yaml` and
  `/etc/dex/dex.yaml`, then `systemctl restart omni dex`.
- **Force re-bootstrap from a clean slate**:
  ```bash
  sudo systemctl stop omni dex
  sudo rm -rf /etc/pki/omni-ca /etc/omni /etc/dex /var/lib/omni
  sudo systemctl start omni-bootstrap
  sudo systemctl start dex omni
  ```
- **Pin a different Omni version**: edit `Image=` in
  `10/quadlets/omni.container` and rebuild.
- **Override a unit at runtime**: copy from `/usr/share/containers/systemd/`
  to `/etc/containers/systemd/` and edit; admin location wins. Then
  `systemctl daemon-reload`.

## Firewall

`firewalld` is installed and enabled in the image. A bundled `omni` service
definition (`/usr/lib/firewalld/services/omni.xml`) is pre-added to the
`public` zone at build time via `firewall-offline-cmd`, so the VM boots into
a locked-down state with only these ports open:

| Port    | Proto | Service                     |
| ------- | ----- | --------------------------- |
| 22      | tcp   | ssh (default)               |
| 443     | tcp   | Omni UI/API                 |
| 5556    | tcp   | Dex OIDC                    |
| 8090    | tcp   | Talos machine API           |
| 8100    | tcp   | Kubernetes proxy            |
| 50180   | udp   | SideroLink WireGuard        |

Inspect or adjust at runtime:

```bash
sudo firewall-cmd --list-all
sudo firewall-cmd --info-service=omni
# add/remove services:
sudo firewall-cmd --zone=public --add-service=<name> --permanent
sudo firewall-cmd --reload
```
