PODMAN = sudo podman

IMAGE_NAME = rocky-bootc
VERSION_MAJOR = 10
PLATFORM = linux/amd64
LABELS ?=

.ONESHELL:
.PHONY: all
all: rechunk

.PHONY: image
image:
	$(PODMAN) build \
		--platform=$(PLATFORM) \
		--security-opt=label=disable \
		--cap-add=all \
		--device /dev/fuse \
		--iidfile /tmp/image-id \
		$(LABELS) \
		-t $(IMAGE_NAME) \
		-f $(VERSION_MAJOR)/Containerfile \
		.

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

# -------------------------------------------------------------------------
# Omni stack: layered VM image, qcow2, cloud-init seed, virt-install deploy.
# Override on the command line, e.g.:
#   make qcow2
#   make seed HOSTNAME=lab1 DOMAIN=example.com
#   make seed HOSTNAME=lab2 IP=192.168.122.50/24 GATEWAY=192.168.122.1
#   make deploy HOSTNAME=lab1
# -------------------------------------------------------------------------

VM_IMAGE_NAME ?= $(IMAGE_NAME)-vm
HOSTNAME      ?= omni-lab
DOMAIN        ?= local
SSH_KEY       ?= $(HOME)/.ssh/id_ed25519.pub
PASSWORD      ?= admin:changeme
IMAGES_DIR    ?= /var/lib/libvirt/images
OUTPUT_DIR    ?= output
MEMORY        ?= 4096
VCPUS         ?= 2
DISK_SIZE     ?= 40G
OS_VARIANT    ?= rocky10
NETWORK       ?= default
# Optional static network:
IP            ?=
GATEWAY       ?=
DNS           ?= 1.1.1.1

# ---- Zarf packages (everything except the Zot bootstrap) ---------------
# Omni, Dex, and every image consumed by downstream Talos clusters Omni
# provisions are delivered as cosign-signed Zarf packages. Only Zot
# itself is loaded via the Containerfile ARG (see below).
# See 10/zarf/README.md for the full rationale.

ZARF                ?= zarf
ZARF_DIR            = $(VERSION_MAJOR)/zarf
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

# ---- Zot registry bootstrap (the one image we can't Zarf) --------------
# Zot itself is loaded by digest into podman containers-storage at first
# boot so zot.service can start offline. The digest lives in
# 10/Containerfile.vm as ARG ZOT_DIGEST; `make zot-refresh` prints the
# current upstream digest so you can update the ARG in a reviewable diff.

ZOT_IMAGE ?= ghcr.io/project-zot/zot-minimal-linux-amd64:v2.1.16

.PHONY: zot-refresh
zot-refresh:
	@command -v skopeo >/dev/null || { echo "install skopeo"; exit 2; }
	@command -v sha256sum >/dev/null || { echo "install coreutils"; exit 2; }
	@current=$$(awk '/^ARG ZOT_DIGEST=/{sub(/^ARG ZOT_DIGEST=/,""); print}' $(VERSION_MAJOR)/Containerfile.vm); \
	 upstream="sha256:$$(skopeo inspect --raw docker://$(ZOT_IMAGE) | sha256sum | awk '{print $$1}')"; \
	 echo "image:    $(ZOT_IMAGE)"; \
	 echo "current:  $$current"; \
	 echo "upstream: $$upstream"; \
	 if [ "$$current" = "$$upstream" ]; then \
	   echo "up to date"; \
	 else \
	   echo; \
	   echo "to update, edit 10/Containerfile.vm:"; \
	   echo "  ARG ZOT_DIGEST=$$upstream"; \
	 fi

.PHONY: zarf-packages-check
# Cheap gate: confirm at least one Zarf package artifact is present and
# that the cosign public key has been committed (build needs it baked in).
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

.PHONY: image-vm
image-vm: zarf-packages-check
	$(PODMAN) build \
		-f $(VERSION_MAJOR)/Containerfile.vm \
		-t $(VM_IMAGE_NAME) .

.PHONY: qcow2
qcow2: image-vm
	sudo rm -rf $(OUTPUT_DIR) && mkdir -p $(OUTPUT_DIR)
	$(PODMAN) run --rm --privileged \
		--security-opt=label=type:unconfined_t \
		-v $(PWD)/$(OUTPUT_DIR):/output \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		quay.io/centos-bootc/bootc-image-builder:latest \
		--type qcow2 localhost/$(VM_IMAGE_NAME):latest
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
