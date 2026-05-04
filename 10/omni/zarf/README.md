# Zarf packages for downstream Talos/Kubernetes clusters

This directory contains [Zarf](https://docs.zarf.dev/) package definitions
for everything that runs **inside** the Talos clusters Omni provisions
(K8s components, CNIs, operators), as opposed to images consumed by the
bootc host itself (Zot, Omni, Dex), which live in `@10/airgap/images.txt`.

## Why split

Zarf is the right tool for cluster-internal workloads:

- digests pinned in the package's `zarf.yaml` and re-recorded in the
  produced `zarf-package-*.tar.zst`,
- cosign-signed at `zarf package create` time,
- SBOMs (syft) included in the package,
- one-shot mirror with `zarf package mirror-resources` against any OCI
  registry (we point it at our local Zot at `localhost:5000`),
- portable: the `.tar.zst` is the airgap delivery artifact and works on
  any host that has a `zarf` binary.

The bootc host stack (Zot, Omni, Dex) is *not* a Kubernetes workload, so
those stay in `images.txt` + `images.lock` with our custom L1 pipeline.

## Packages

| Directory | Package | Notes |
|---|---|---|
| `talos-k8s-1.36.0/` | Talos K8s 1.36.0 control-plane + node images | matches `talosctl images k8s-bundle` for v1.36.0 |
| `cilium-1.19.3/` | Cilium CNI 1.19.3 | image set from upstream `values.yaml` |

## Build

```bash
# One-time: generate a cosign keypair for signing packages.
make zarf-keygen                       # writes 10/omni/zarf/cosign.{key,pub}
                                       # cosign.pub is committed; cosign.key is NOT

# Build all packages from the definitions in 10/omni/zarf/*/zarf.yaml.
# Output: output/zarf/zarf-package-<name>-amd64-<version>.tar.zst
make zarf-packages

# Inspect a package's contents (verifies signature + lists images + SBOMs).
zarf package inspect output/zarf/zarf-package-cilium-amd64-1.19.3.tar.zst \
  --key 10/omni/zarf/cosign.pub
```

`make omni` depends on `zarf-packages`; the `.tar.zst` files are baked
into the image at `/usr/share/zarf/packages/`, alongside `cosign.pub` at
`/etc/zarf/cosign.pub`.

## First boot

`zarf-package-publish.service` runs after `airgap-image-push.service`. For
each `.tar.zst` in `/usr/share/zarf/packages/`:

1. `zarf package inspect ... --key /etc/zarf/cosign.pub` — verifies the
   cosign signature on the package metadata. Fails closed.
2. `zarf package mirror-resources ...` — extracts the OCI layouts inside
   the package and pushes them into Zot at `localhost:5000` with their
   upstream-host-stripped paths (e.g.
   `quay.io/cilium/cilium:v1.19.3` -> `localhost:5000/cilium/cilium:v1.19.3`),
   so Talos's standard registry-mirror config Just Works.

## Adding a new package

```bash
mkdir -p 10/omni/zarf/my-thing-1.2.3
cat > 10/omni/zarf/my-thing-1.2.3/zarf.yaml <<'EOF'
kind: ZarfPackageConfig
metadata:
  name: my-thing
  version: 1.2.3
  architecture: amd64
  description: ...
components:
  - name: images
    required: true
    images:
      - registry.example.com/my-thing:1.2.3
EOF
make zarf-packages   # regenerates output/zarf/*.tar.zst
make omni            # rebakes the Omni image
```
