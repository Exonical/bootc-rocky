# Rocky Linux Bootable Container Images (bootc)

This project builds bootable container images for **Rocky Linux 9** and
**Rocky Linux 10** using [bootc](https://containers.github.io/bootc/).

Three image variants are provided:

| Variant | Description | Containerfile |
|---|---|---|
| **base** | Minimal bootc OS (Rocky 9 or 10) | `9/Containerfile`, `10/Containerfile` |
| **omni** | Base + [Sidero Labs Omni](https://docs.siderolabs.com/omni/) v1.7.1, Dex OIDC, Zot registry | `omni/Containerfile` |
| **workstation** | Base + GNOME desktop, Firefox, VS Code, Python 3.12 | `workstation/Containerfile` |

## Repository layout

```
├── 9/
│   ├── Containerfile             # Rocky Linux 9 base bootc image
│   └── rockylinux-9.yaml         # bootc-base-imagectl manifest
├── 10/
│   ├── Containerfile             # Rocky Linux 10 base bootc image
│   └── rockylinux-10.yaml        # bootc-base-imagectl manifest
├── omni/
│   ├── Containerfile             # Omni stack layered on base
│   ├── quadlets/                 # Systemd Quadlet units (omni, dex, zot)
│   ├── scripts/                  # Bootstrap + airgap + zarf-publish
│   ├── firewalld/                # Omni firewalld service definition
│   ├── zot/                      # Zot registry configuration
│   ├── zarf/                     # Zarf package definitions + cosign pubkey
│   └── containers/               # Podman registries.conf.d
├── workstation/
│   └── Containerfile             # GNOME workstation layered on base
├── scripts/
│   ├── zarf-build-packages.sh    # Build Zarf packages from definitions
│   └── make-seed.sh              # Generate cloud-init seed ISO
├── docs/
│   └── omni-bootc.md             # Full Omni build/deploy/operate reference
└── Makefile
```

## Prerequisites

* `make`
* `podman` (rootful, or `docker`)
* Sufficient disk space and internet connectivity

## Quick start

### Base images

```bash
# Rocky Linux 10 base
make base ROCKY_VERSION=10

# Rocky Linux 9 base
make base ROCKY_VERSION=9
```

### Omni variant (Sidero Labs Omni + Dex + Zot)

```bash
# 1. Build the base image first
make base ROCKY_VERSION=10

# 2. Build Zarf packages (requires cosign keypair; see omni/zarf/README.md)
make zarf-keygen          # one-time
make zarf-packages

# 3. Build the Omni layered image
make omni ROCKY_VERSION=10

# 4. (Optional) Build qcow2 and deploy to libvirt
make qcow2
make seed HOSTNAME=lab1 DOMAIN=example.com
make deploy HOSTNAME=lab1
```

See `docs/omni-bootc.md` and `omni/quadlets/README.md` for the full
operator reference.

### Workstation variant (GNOME desktop)

```bash
# 1. Build the base image first
make base ROCKY_VERSION=10

# 2. Build the workstation layered image
make workstation ROCKY_VERSION=10

# 3. (Optional) Build qcow2
make workstation-qcow2
```

The workstation image includes:
- GNOME desktop (minimal)
- Firefox
- Visual Studio Code
- Python 3.12

## Build variables

| Variable | Default | Description |
|---|---|---|
| `ROCKY_VERSION` | `10` | Rocky Linux major version (`9` or `10`) |
| `PLATFORM` | `linux/amd64` | Target architecture |
| `IMAGE_NAME` | `rocky-bootc` | Base image name |
| `OMNI_IMAGE_NAME` | `rocky-bootc-omni` | Omni variant image name |
| `WORKSTATION_IMAGE_NAME` | `rocky-bootc-workstation` | Workstation variant image name |

Run `make help` for a full list of targets and variables.

## Contributing

We welcome contributions and feedback!
