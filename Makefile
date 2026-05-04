PODMAN = sudo podman

IMAGE_NAME      = rocky-bootc
ROCKY_VERSION   ?= 10
PLATFORM        = linux/amd64
LABELS          ?=

.ONESHELL:

# =========================================================================
#  Base image
# =========================================================================
.PHONY: base
base:
	$(PODMAN) build \
		--platform=$(PLATFORM) \
		--security-opt=label=disable \
		--cap-add=all \
		--device /dev/fuse \
		$(LABELS) \
		-t $(IMAGE_NAME) \
		-f $(ROCKY_VERSION)/Containerfile \
		.

# Legacy alias
.PHONY: image
image: base

.PHONY: rechunk
rechunk:
	$(PODMAN) run \
		--rm --privileged \
		--security-opt=label=disable \
		-v /var/lib/containers:/var/lib/containers:z \
		quay.io/centos-bootc/centos-bootc:stream10 \
		/usr/libexec/bootc-base-imagectl rechunk \
		localhost/$(IMAGE_NAME):latest localhost/rechunked-$(IMAGE_NAME):latest && \
	$(PODMAN) tag localhost/rechunked-$(IMAGE_NAME):latest localhost/$(IMAGE_NAME):latest && \
	$(PODMAN) rmi localhost/rechunked-$(IMAGE_NAME):latest

# =========================================================================
#  Omni variant (Sidero Labs Omni + Dex + Zot)
# =========================================================================

OMNI_IMAGE_NAME ?= $(IMAGE_NAME)-omni

# Override on the command line, e.g.:
#   make omni ROCKY_VERSION=10
#   make qcow2 ROCKY_VERSION=10
#   make seed HOSTNAME=lab1 DOMAIN=example.com
#   make deploy HOSTNAME=lab1
HOSTNAME      ?= omni-lab
DOMAIN        ?= local
SSH_KEY       ?= $(HOME)/.ssh/id_ed25519.pub
PASSWORD      ?= admin:changeme
IMAGES_DIR    ?= /var/lib/libvirt/images
OUTPUT_DIR    ?= output
MEMORY        ?= 4096
VCPUS         ?= 2
DISK_SIZE     ?= 40G
OS_VARIANT    ?= rocky$(ROCKY_VERSION)
NETWORK       ?= default
IP            ?=
GATEWAY       ?=
DNS           ?= 1.1.1.1

# ---- Zarf packages -------------------------------------------------------
ZARF                ?= zarf
ZARF_DIR            = omni/zarf
ZARF_OUTPUT_DIR     = output/zarf
COSIGN_KEY          ?= $(ZARF_DIR)/cosign.key
COSIGN_PUB          ?= $(ZARF_DIR)/cosign.pub
COSIGN              ?= cosign

.PHONY: zarf-keygen
zarf-keygen:
	@if [ -f $(COSIGN_KEY) ] || [ -f $(COSIGN_PUB) ]; then \
	  echo "Refusing to overwrite existing $(COSIGN_KEY)/$(COSIGN_PUB)."; \
	  echo "Delete them by hand if you really mean to rotate."; \
	  exit 2; \
	fi
	@command -v $(COSIGN) >/dev/null || { echo "install cosign first"; exit 2; }
	cd $(ZARF_DIR) && $(COSIGN) generate-key-pair
	@echo
	@echo "Commit $(COSIGN_PUB). Do NOT commit $(COSIGN_KEY)."

.PHONY: zarf-packages
zarf-packages:
	./scripts/zarf-build-packages.sh

.PHONY: zarf-clean
zarf-clean:
	rm -rf $(ZARF_OUTPUT_DIR)

# ---- Zot registry bootstrap -----------------------------------------------
ZOT_IMAGE ?= ghcr.io/project-zot/zot-minimal-linux-amd64:v2.1.16

.PHONY: zot-refresh
zot-refresh:
	@command -v skopeo >/dev/null || { echo "install skopeo"; exit 2; }
	@command -v sha256sum >/dev/null || { echo "install coreutils"; exit 2; }
	@current=$$(awk '/^ARG ZOT_DIGEST=/{sub(/^ARG ZOT_DIGEST=/,""); print}' omni/Containerfile); \
	 upstream="sha256:$$(skopeo inspect --raw docker://$(ZOT_IMAGE) | sha256sum | awk '{print $$1}')"; \
	 echo "image:    $(ZOT_IMAGE)"; \
	 echo "current:  $$current"; \
	 echo "upstream: $$upstream"; \
	 if [ "$$current" = "$$upstream" ]; then \
	   echo "up to date"; \
	 else \
	   echo; \
	   echo "to update, edit omni/Containerfile:"; \
	   echo "  ARG ZOT_DIGEST=$$upstream"; \
	 fi

.PHONY: zarf-packages-check
zarf-packages-check:
	@test -f $(COSIGN_PUB) || { \
	  echo "missing $(COSIGN_PUB); run 'make zarf-keygen' once and commit the public key"; \
	  exit 2; }
	@n=$$(ls -1 $(ZARF_OUTPUT_DIR)/zarf-package-*.tar.zst 2>/dev/null | wc -l); \
	 if [ "$$n" -eq 0 ]; then \
	   echo "no zarf packages in $(ZARF_OUTPUT_DIR)/; run 'make zarf-packages'"; \
	   exit 3; \
	 fi
	@echo "[zarf-packages-check] OK ($$(ls -1 $(ZARF_OUTPUT_DIR)/zarf-package-*.tar.zst | wc -l) packages)"

.PHONY: omni
omni: zarf-packages-check
	$(PODMAN) build \
		--build-arg BASE_IMAGE=localhost/$(IMAGE_NAME):latest \
		-f omni/Containerfile \
		-t $(OMNI_IMAGE_NAME) .

# Legacy alias
.PHONY: image-vm
image-vm: omni

.PHONY: qcow2
qcow2: omni
	sudo rm -rf $(OUTPUT_DIR) && mkdir -p $(OUTPUT_DIR)
	$(PODMAN) run --rm --privileged \
		--security-opt=label=type:unconfined_t \
		-v $(PWD)/$(OUTPUT_DIR):/output \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		quay.io/centos-bootc/bootc-image-builder:latest \
		--type qcow2 localhost/$(OMNI_IMAGE_NAME):latest
	ls -lh $(OUTPUT_DIR)/qcow2/disk.qcow2

.PHONY: seed
seed:
	./scripts/make-seed.sh \
		--hostname $(HOSTNAME) \
		--domain   $(DOMAIN) \
		--ssh-key  $(SSH_KEY) \
		--password $(PASSWORD) \
		$(if $(IP),--ip $(IP) --gateway $(GATEWAY) --dns $(DNS)) \
		--out $(IMAGES_DIR)/$(HOSTNAME)-seed.iso

.PHONY: deploy
deploy: seed
	@test -f $(OUTPUT_DIR)/qcow2/disk.qcow2 || { \
	  echo "ERROR: $(OUTPUT_DIR)/qcow2/disk.qcow2 not found."; \
	  echo "Run 'make qcow2' once to build the golden image, then 'make deploy ...' per VM."; \
	  exit 1; }
	sudo install -o qemu -g qemu -m 0640 \
		$(OUTPUT_DIR)/qcow2/disk.qcow2 \
		$(IMAGES_DIR)/$(HOSTNAME).qcow2
	sudo qemu-img resize $(IMAGES_DIR)/$(HOSTNAME).qcow2 $(DISK_SIZE)
	ssh-keygen -R $(HOSTNAME).$(DOMAIN) 2>/dev/null || true
	sudo virt-install \
		--name $(HOSTNAME) \
		--memory $(MEMORY) --vcpus $(VCPUS) \
		--os-variant $(OS_VARIANT) \
		--disk path=$(IMAGES_DIR)/$(HOSTNAME).qcow2,format=qcow2,bus=virtio \
		--disk path=$(IMAGES_DIR)/$(HOSTNAME)-seed.iso,device=cdrom \
		--network network=$(NETWORK),model=virtio \
		--graphics none --console pty,target_type=serial \
		--import --noautoconsole
	@echo
	@echo "VM '$(HOSTNAME)' launched. Find its IP:"
	@echo "  sudo virsh domifaddr $(HOSTNAME)"

.PHONY: undeploy
undeploy:
	-sudo virsh destroy  $(HOSTNAME) 2>/dev/null
	-sudo virsh undefine $(HOSTNAME) --remove-all-storage

# =========================================================================
#  Workstation variant (GNOME + Firefox + VS Code + Python 3.12)
# =========================================================================

WORKSTATION_IMAGE_NAME ?= $(IMAGE_NAME)-workstation

.PHONY: workstation
workstation:
	$(PODMAN) build \
		--build-arg BASE_IMAGE=localhost/$(IMAGE_NAME):latest \
		-f workstation/Containerfile \
		-t $(WORKSTATION_IMAGE_NAME) .

.PHONY: workstation-qcow2
workstation-qcow2: workstation
	sudo rm -rf $(OUTPUT_DIR) && mkdir -p $(OUTPUT_DIR)
	$(PODMAN) run --rm --privileged \
		--security-opt=label=type:unconfined_t \
		-v $(PWD)/$(OUTPUT_DIR):/output \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		quay.io/centos-bootc/bootc-image-builder:latest \
		--type qcow2 localhost/$(WORKSTATION_IMAGE_NAME):latest
	ls -lh $(OUTPUT_DIR)/qcow2/disk.qcow2

# =========================================================================
#  Housekeeping
# =========================================================================
.PHONY: clean
clean:
	rm -rf $(OUTPUT_DIR)

.PHONY: help
help:
	@echo "Rocky Linux BootC Build System"
	@echo ""
	@echo "Base images (Rocky 9 or 10):"
	@echo "  make base ROCKY_VERSION=10          Build Rocky 10 base bootc image"
	@echo "  make base ROCKY_VERSION=9           Build Rocky 9 base bootc image"
	@echo "  make rechunk                        Rechunk the base image"
	@echo ""
	@echo "Omni variant (Sidero Labs Omni + Dex + Zot):"
	@echo "  make omni                           Build the Omni layered image"
	@echo "  make qcow2                          Build Omni qcow2 disk image"
	@echo "  make seed HOSTNAME=lab1             Generate cloud-init seed ISO"
	@echo "  make deploy HOSTNAME=lab1           Deploy VM with virt-install"
	@echo "  make undeploy HOSTNAME=lab1         Destroy and undefine VM"
	@echo ""
	@echo "Workstation variant (GNOME + Firefox + VS Code + Python 3.12):"
	@echo "  make workstation                    Build the workstation layered image"
	@echo "  make workstation-qcow2              Build workstation qcow2 disk image"
	@echo ""
	@echo "Zarf / Zot (Omni airgap supply chain):"
	@echo "  make zarf-keygen                    Generate cosign keypair"
	@echo "  make zarf-packages                  Build all Zarf packages"
	@echo "  make zot-refresh                    Check for Zot image updates"
	@echo ""
	@echo "Variables:"
	@echo "  ROCKY_VERSION=9|10  (default: 10)   Rocky Linux major version"
	@echo "  PLATFORM=linux/amd64 (default)      Target platform"
	@echo "  IMAGE_NAME=rocky-bootc (default)    Base image name"
