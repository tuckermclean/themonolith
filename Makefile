# SPEC section 7: CI calls these targets; a test is always a Make target.
SHELL_EXTRA ?=
# SPEC principle 3: the one place the image registry is named.
REGISTRY ?= ghcr.io/tuckermclean/themonolith

.PHONY: take-packages sysroot-pack sysroot-unpack all build-rootfs iso iso-stage build-version verify-kernel-modules changes toolbox-publish pull-image builder-manifest registry-copy test test-lint test-unit test-revbump test-overlay test-boot test-artifact test-gates test-cve-canary test-static-rebuild attestation attest-builder grype-db-update fetch-rc1-sbom sbom-diff-rc1 rootfs fetch-iso run-bios run-uefi iso-artifact-name sync-portage seed-tree tree-exists tree-check tree-restore-offline cache-tag cache-pull cache-push ensure-dirs ensure-volume build-packages build-packages-resume extract menuconfig-busybox menuconfig-kernel regen-manifest check-updates update-versions list-packages show-failed shell clean

test: test-lint test-unit test-revbump test-overlay test-boot test-artifact test-gates test-cve-canary test-static-rebuild

test-lint:
	toolbox/run --network none -- sh scripts/test-lint.sh $(SHELL_EXTRA) $(addprefix configs/overlay/app-misc/monolith-base/files/,monolith-net monolith-router monolith monolith-time monolith-time-check monolith-persist)

test-unit:
	toolbox/run --network none -- sh -c 'echo "==> Shell unit tests (scripts/tests/*.sh)"; rc=0; for t in scripts/tests/*.sh; do [ -e "$$t" ] || continue; echo "==> Running $$t"; sh "$$t" || { echo "::error file=$$t::test suite failed"; rc=1; }; done; exit $$rc'

# pkgcheck scan of the overlay against the pinned tree (needs the network for sync-portage).
test-overlay: sync-portage
	toolbox/run -- sh scripts/overlay-qa.sh $(TREE_DIR) configs/overlay docs/overlay-qa.md

# BASE: the merge base of HEAD with origin/main if that ref exists, else with main.
BASE ?= $(shell git merge-base HEAD $$(git rev-parse --verify -q origin/main >/dev/null && echo origin/main || echo main))

# Judged by BASE's copy of the script, so a PR cannot weaken the check it is judged by.
# Only when BASE lacks the script (the PR that introduces it) the working-tree copy is used.
test-revbump:
	toolbox/run --network none -- sh -c 'echo "==> Revision bump check ($(BASE)..HEAD)"; git rev-parse --verify -q "$(BASE)^{commit}" >/dev/null || { echo "test-revbump: BASE \"$(BASE)\" is not a commit"; exit 1; }; s=$$(mktemp); if [ -n "$$(git ls-tree "$(BASE)" -- scripts/check-revbump.sh)" ]; then git show "$(BASE):scripts/check-revbump.sh" >"$$s" || { rm -f "$$s"; exit 1; }; else echo "note: $(BASE) has no scripts/check-revbump.sh; using the working-tree copy"; cp scripts/check-revbump.sh "$$s" || { rm -f "$$s"; exit 1; }; fi; sh "$$s" "$(BASE)" HEAD; rc=$$?; rm -f "$$s"; exit $$rc'

# ---- B03: the build version ----

# BUILD_EPOCH is the version label until M01. CI builds are BUILD_EPOCH-<short sha>, a tag build is the tag without its v.
# Every job of one run computes the same value; BUILD_VERSION= overrides it.
BUILD_EPOCH := $(shell grep '^ARG BUILD_EPOCH=' Dockerfile | cut -d= -f2)
BUILD_VERSION ?= $(if $(filter refs/tags/v%,$(GITHUB_REF)),$(patsubst refs/tags/v%,%,$(GITHUB_REF)),$(if $(GITHUB_SHA),$(BUILD_EPOCH)-$(shell printf %.7s '$(GITHUB_SHA)'),$(BUILD_EPOCH)))
VERSION_ENV := -e BUILD_VERSION=$(BUILD_VERSION)

# Writes BUILD_VERSION to $GITHUB_ENV, for the later steps of a job.
build-version:
	@echo "BUILD_VERSION=$(BUILD_VERSION)" >> "$${GITHUB_ENV:-/dev/stdout}"

# ---- O01: boot tests (the 17 modes of scripts/boot-test.py) and manual boots ----

# The default ISO is the one `make iso` builds. Setting ISO_URL and ISO_SHA256 (or ISO=) is the rc1 lane:
# the ISO at ISO_URL is fetched and checked against its sha256 first.
ISO_URL ?=
RC1_SHA256 ?= a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a
ISO_SHA256 ?=
EXPECTED_KERNEL ?= 6.12.80-i486-monolith
BUILT_ISO := output/themonolith-$(BUILD_VERSION).iso
DEFAULT_ISO := $(if $(ISO_URL),output/themonolith-0.1.0-rc1.iso,$(BUILT_ISO))
# What an ISO left at its default needs first: the fetch in the rc1 lane, else the build.
default_iso_dep = $(if $(filter $(ISO),$(DEFAULT_ISO)),$(if $(ISO_URL),fetch-iso,iso))
ISO ?= $(DEFAULT_ISO)
# Where fetch-iso writes the verified ISO.
ISO_OUT ?= $(DEFAULT_ISO)
ISO_ARTIFACT ?=
# MODE= runs one mode; MODES= (space-separated) limits the run to the listed modes; both empty runs all 17.
# RAM_MB, NIC_MODEL and VGA_MODEL narrow the bios, nic and vga runs to one matrix entry.
MODE ?=
MODES ?=
RAM_MB ?=
NIC_MODEL ?=
VGA_MODEL ?=
OVMF_CODE ?= $(firstword \
	$(wildcard /usr/share/OVMF/OVMF_CODE.fd) \
	$(wildcard /usr/share/edk2/ovmf/OVMF_CODE.fd) \
	$(wildcard /usr/share/edk2-ovmf/OVMF_CODE.fd))

BOOT_MODES := bios uefi toram ahci nvme usb virtio nicless nic vga fbdev-modprobe nat gui stele-acid2 clock-epoch clock-1996 persist
BOOT_UNKNOWN := $(filter-out $(BOOT_MODES),$(MODE) $(MODES))
$(if $(and $(BOOT_UNKNOWN),$(filter test test-boot,$(MAKECMDGOALS))),$(error unknown boot mode(s): $(BOOT_UNKNOWN); valid: $(BOOT_MODES)))
BOOT_WANT := $(filter $(if $(MODE),$(MODE),$(BOOT_MODES)),$(if $(MODES),$(MODES),$(BOOT_MODES)))

define nl


endef

# Each boot runs from its own copy of ISO, removed afterwards: nvme, usb and virtio attach it as a writable disk.
# $(1) mode, $(2) log name.
iso_copy = output/boot-iso-$(2).iso
copy_iso = cp '$(ISO)' '$(call iso_copy,$(1),$(2))' || echo $(1) >> output/boot-failed$(nl)
drop_iso = rm -f '$(call iso_copy,$(1),$(2))'$(nl)
# $(1) mode, $(2) extra arguments, $(3) log name. The guest needs no network except in nat mode.
boot = $(call copy_iso,$(1),$(3))toolbox/run --network none -- python3 scripts/boot-test.py --iso '$(call iso_copy,$(1),$(3))' --mode $(1) $(2) --kernel-version '$(EXPECTED_KERNEL)' --log-file output/boot-test-$(3).log || echo $(1) >> output/boot-failed$(nl)$(call drop_iso,$(1),$(3))
# nat: the guest reaches a host http.server through QEMU's 10.0.2.2, so the server runs in the same toolbox
# container as QEMU (its loopback is the guest's 10.0.2.2); the container needs no outside network.
boot_nat = $(call copy_iso,nat,nat)toolbox/run --network none -- sh -c 'mkdir -p output/natsrv && echo NAT_OK_marker > output/natsrv/probe.txt; (cd output/natsrv && exec python3 -m http.server 8000 --bind 0.0.0.0) & srv=$$!; sleep 2; python3 scripts/boot-test.py --iso "$(call iso_copy,nat,nat)" --mode nat --kernel-version "$(EXPECTED_KERNEL)" --log-file output/boot-test-nat.log; rc=$$?; kill $$srv; exit $$rc' || echo nat >> output/boot-failed$(nl)$(call drop_iso,nat,nat)

boot_runs = \
	$(if $(filter bios,$(BOOT_WANT)),$(foreach r,$(if $(RAM_MB),$(RAM_MB),64 256),$(call boot,bios,--ram-mb $(r),bios-$(r)m))) \
	$(if $(filter uefi,$(BOOT_WANT)),$(call boot,uefi,,uefi)) \
	$(if $(filter toram,$(BOOT_WANT)),$(call boot,toram,,toram)) \
	$(if $(filter ahci,$(BOOT_WANT)),$(call boot,ahci,--ram-mb 512,ahci)) \
	$(if $(filter nvme,$(BOOT_WANT)),$(call boot,nvme,--ram-mb 512,nvme)) \
	$(if $(filter usb,$(BOOT_WANT)),$(call boot,usb,--ram-mb 512,usb)) \
	$(if $(filter virtio,$(BOOT_WANT)),$(call boot,virtio,--ram-mb 512,virtio)) \
	$(if $(filter nicless,$(BOOT_WANT)),$(call boot,nicless,--ram-mb 64,nicless)) \
	$(if $(filter gui,$(BOOT_WANT)),$(call boot,gui,--ram-mb 128 --gui-screendump output/gui-screendump.ppm,gui)) \
	$(if $(filter stele-acid2,$(BOOT_WANT)),$(call boot,stele-acid2,--ram-mb 256 --gui-screendump output/stele-acid2-screendump.ppm,stele-acid2)) \
	$(if $(filter nic,$(BOOT_WANT)),$(foreach m,$(if $(NIC_MODEL),$(NIC_MODEL),pcnet rtl8139 tulip ne2k_pci ne2k_isa),$(call boot,nic,--nic-model $(m),nic-$(m)))) \
	$(if $(filter vga,$(BOOT_WANT)),$(foreach m,$(if $(VGA_MODEL),$(VGA_MODEL),cirrus),$(call boot,vga,--vga-model $(m),vga-$(m)))) \
	$(if $(filter fbdev-modprobe,$(BOOT_WANT)),$(call boot,fbdev-modprobe,,fbdev-modprobe)) \
	$(if $(filter nat,$(BOOT_WANT)),$(boot_nat)) \
	$(if $(filter clock-epoch,$(BOOT_WANT)),$(call boot,clock-epoch,,clock-epoch)) \
	$(if $(filter clock-1996,$(BOOT_WANT)),$(call boot,clock-1996,,clock-1996)) \
	$(if $(filter persist,$(BOOT_WANT)),$(call boot,persist,,persist))

# vga is rc1's expected failure (rc1 ships no cirrusfb): when the ISO's sha256 (computed once, above) is RC1_SHA256, a failing vga boot is
# reported as XFAIL and is not a failure, and a passing one is (stale expectation). Any other digest is strict; no other mode is expected to fail.
vga_xfail = $(if $(filter vga,$(BOOT_WANT)),if [ "$$(cat output/boot-iso.sha256)" = '$(RC1_SHA256)' ]; then if grep -qx vga output/boot-failed; then grep -vx vga output/boot-failed > output/boot-failed.new || true; mv output/boot-failed.new output/boot-failed; echo 'XFAIL: vga (rc1 predates the legacy fbdev Tier-2 drivers; no cirrusfb on the disc)'; else echo 'vga passed but is expected to fail on rc1: stale expectation' >&2; echo vga >> output/boot-failed; fi; fi,:)

# Boots ISO in the selected modes, keeping going past a failed boot and then listing the failed modes, with QEMU under TCG (-cpu 486, no KVM), in the toolbox. When ISO is left
# at its default, that ISO is built first (make iso), or in the rc1 lane (ISO_URL set) fetched and checked. Records the QEMU and OVMF versions.
test-boot: $(default_iso_dep)
	@echo "==> Boot tests: $(if $(BOOT_WANT),$(BOOT_WANT),none of the requested modes)"
	mkdir -p output
	rm -f output/boot-failed
	toolbox/run --network none -- sh -c 'qemu-system-i386 --version; qemu-system-x86_64 --version; dpkg-query -W qemu-system-x86 ovmf' > output/tool-versions.txt
	@sha256sum '$(ISO)' | cut -d' ' -f1 > output/boot-iso.sha256
	$(boot_runs)
	@$(vga_xfail)
	@if [ -s output/boot-failed ]; then echo "failed: $$(sort -u output/boot-failed | tr '\n' ' ')"; exit 1; fi

# Download ISO_URL to ISO_OUT and check it against ISO_SHA256; a mismatch deletes it and fails.
fetch-iso:
	toolbox/run -- sh -c 'set -eu; f="$(ISO_OUT)"; mkdir -p "$$(dirname "$$f")"; if [ -f "$$f" ] && echo "$(ISO_SHA256)  $$f" | sha256sum -c --quiet -; then echo "==> $$f matches sha256 $(ISO_SHA256)"; exit 0; fi; curl -fsSL --retry 3 -o "$$f.part" "$(ISO_URL)"; echo "$(ISO_SHA256)  $$f.part" | sha256sum -c - || { rm -f "$$f.part" "$$f"; echo "sha256 mismatch for $(ISO_URL)"; exit 1; }; mv "$$f.part" "$$f"'

# The name of the artifact the boot-test workflow's mode jobs download the ISO from (to $GITHUB_OUTPUT).
iso-artifact-name:
	@name='$(if $(ISO_ARTIFACT),$(ISO_ARTIFACT),$(if $(ISO_URL),boot-test-iso-$(GITHUB_RUN_ID)))'; \
	test -n "$$name" || { echo "need iso-artifact or iso-url"; exit 1; }; \
	echo "artifact=$$name" >> "$$GITHUB_OUTPUT"

# Manual boots (not tests): serial console, Ctrl+A X to exit.
run-bios:
	@test -f '$(ISO)' || { echo "Error: $(ISO) not found. Run 'make fetch-iso' or pass ISO=<path>."; exit 1; }
	@echo "==> Booting $(ISO) in QEMU via BIOS (Ctrl+A X to exit)"
	qemu-system-i386 -cdrom '$(ISO)' -m 64M -cpu 486 -nographic -serial mon:stdio

# OVMF is 64-bit firmware; GRUB hands off to the 32-bit kernel via EFI Handover.
# 512M minimum: UEFI firmware and the GRUB EFI heap need well over 64MB.
run-uefi:
	@test -f '$(ISO)' || { echo "Error: $(ISO) not found. Run 'make fetch-iso' or pass ISO=<path>."; exit 1; }
	@test -n '$(OVMF_CODE)' || { echo "Error: OVMF firmware not found. Install ovmf/edk2-ovmf, or set OVMF_CODE=/path/to/OVMF_CODE.fd"; exit 1; }
	@echo "==> Booting $(ISO) in QEMU via UEFI (OVMF: $(OVMF_CODE)), Ctrl+A X to exit"
	qemu-system-x86_64 -drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) -cdrom '$(ISO)' -m 512M -nographic -serial mon:stdio

# ---- O02: artifact checks ----

ARTIFACT_OUT := output
ARTIFACT_ROOTFS := $(ARTIFACT_OUT)/rootfs
ARTIFACT_ALLOWLIST := configs/attestation/dynamic-allowlist.txt
ARTIFACT_EXPECTED := configs/attestation/rc1-static-audit.expected

# Extracts /rootfs.squashfs of ISO into ARTIFACT_ROOTFS (xorriso, then unsquashfs without xattrs; both run unprivileged in the toolbox).
rootfs: $(default_iso_dep)
	toolbox/run --network none -- sh -c 'set -eu; rm -rf "$(ARTIFACT_ROOTFS)" "$(ARTIFACT_OUT)/rootfs.squashfs"; mkdir -p "$(ARTIFACT_OUT)"; xorriso -osirrox on -indev "$(ISO)" -extract /rootfs.squashfs "$(ARTIFACT_OUT)/rootfs.squashfs"; unsquashfs -no-xattrs -d "$(ARTIFACT_ROOTFS)" "$(ARTIFACT_OUT)/rootfs.squashfs" > /dev/null'

# Audits the rootfs of ISO for dynamic binaries, foreign machines, plugins, Python and the freetype chain. For rc1's ISO
# (its sha256, computed here, is RC1_SHA256) the findings without the allowlist must equal ARTIFACT_EXPECTED; for any other ISO the
# audit is --strict with the allowlist.
test-artifact: rootfs
	mkdir -p $(ARTIFACT_OUT)
	@sha256sum '$(ISO)' | cut -d' ' -f1 > $(ARTIFACT_OUT)/artifact-iso.sha256
	@if [ "$$(cat $(ARTIFACT_OUT)/artifact-iso.sha256)" = '$(RC1_SHA256)' ]; then \
		echo "==> rc1 ISO: findings must equal $(ARTIFACT_EXPECTED)"; \
		toolbox/run --network none -- env OUTPUT_DIR=$(ARTIFACT_OUT) bash scripts/static-audit.sh --no-allowlist '$(ARTIFACT_ROOTFS)' || exit 1; \
		grep '^FINDING' $(ARTIFACT_OUT)/reports/static-audit.txt | LC_ALL=C sort > $(ARTIFACT_OUT)/artifact-findings.txt; \
		sed 's/[[:space:]]*#.*//' '$(ARTIFACT_EXPECTED)' | grep -v '^[[:space:]]*$$' | LC_ALL=C sort > $(ARTIFACT_OUT)/artifact-expected.txt; \
		diff -u $(ARTIFACT_OUT)/artifact-expected.txt $(ARTIFACT_OUT)/artifact-findings.txt || { echo "test-artifact: findings differ from $(ARTIFACT_EXPECTED)"; exit 1; }; \
		echo "test-artifact: PASS (rc1 findings match)"; \
	else \
		toolbox/run --network none -- env OUTPUT_DIR=$(ARTIFACT_OUT) bash scripts/static-audit.sh --strict --allowlist '$(ARTIFACT_ALLOWLIST)' '$(ARTIFACT_ROOTFS)'; \
	fi

# ---- I03: the builder image, taken by digest ----

# rc1's builder image. Nothing here builds it or pulls it by tag.
BUILDER_DIGEST := sha256:ab04002a13794c2ad90d821b5de535a4e4df2945346bb04d8073883ea8aab3fa
BUILDER_REF := $(REGISTRY)/builder@$(BUILDER_DIGEST)
IMAGE_NAME := monolith-builder
DOCKER ?= docker

# Pulls the builder image by digest and tags it $(IMAGE_NAME); a failed pull stops here, with the reference in the message.
pull-image:
	$(DOCKER) pull $(BUILDER_REF) || { echo "pull-image: cannot pull $(BUILDER_REF)"; exit 1; }
	$(DOCKER) tag $(BUILDER_REF) $(IMAGE_NAME)
	@echo "==> Pulled $(BUILDER_REF) and tagged it $(IMAGE_NAME)"

# Builds the test toolbox from its Containerfile and pushes $(REGISTRY)/toolbox:<inputs>, which toolbox/run pulls
# before building (SPEC §6, §7). CI: toolbox-image.yml on main, with GITHUB_TOKEN; locally, log in first.
toolbox-publish:
	REGISTRY='$(REGISTRY)' toolbox/run --push

# Copies SRC (pinned by digest) to $(REGISTRY)/DST (<name>:<tag>) and checks the digest. CI: registry-copy.yml.
registry-copy:
	toolbox/run -e GITHUB_TOKEN -e GITHUB_ACTOR -- env REGISTRY='$(REGISTRY)' sh scripts/registry-copy.sh '$(SRC)' '$(DST)'

# Records what is in the builder image.
builder-manifest:
	mkdir -p output
	DOCKER='$(DOCKER)' sh scripts/builder-manifest.sh '$(BUILDER_REF)' > output/builder-manifest.txt

# B01 adds configs/portage/versions.lock; M02's build-image consumes these pins.
ifneq ($(wildcard configs/portage/versions.lock),)
# Kernel version (with revision) — read from versions.lock so targets stay in sync with the pin
KERNEL_VERSION := $(shell grep '^sys-kernel/monolith-kernel:' configs/portage/versions.lock | cut -d: -f2)

# Cross-toolchain version pins — all passed to crossdev to prevent live-ebuild (9999) selection
# musl and gcc come from crossdev.lock (managed by update-build-pins, not update-versions)
# binutils comes from versions.lock (it is a world package)
# linux-headers version is derived from the kernel version (major.minor)
CROSS_MUSL_VER     := $(shell grep '^sys-libs/musl:' configs/portage/crossdev.lock | cut -d: -f2)
CROSS_GCC_VER      := $(shell grep '^sys-devel/gcc:' configs/portage/crossdev.lock | cut -d: -f2)
CROSS_BINUTILS_VER := $(shell grep '^sys-devel/binutils:' configs/portage/versions.lock | cut -d: -f2)
CROSS_HEADERS_VER  := $(shell echo $(KERNEL_VERSION) | cut -d. -f1-2)
endif

# Intermediate image name for the pre-crossdev stage
BASE_TOOLS_IMAGE := $(IMAGE_NAME)-base-tools

# Container name used during crossdev build (fixed name allows pre-cleanup on retry)
CROSSDEV_CONTAINER := monolith-crossdev-build

# ---- I02: the pinned Gentoo tree ----

# rc1's tree: gentoo-mirror commit TREE_COMMIT, archived once as an OCI artifact (scripts/seed-tree.sh) and
# restored by digest (scripts/sync-portage.sh). docs/tree-pin.md has the evidence.
TREE_COMMIT := 6e88ed01f3e97de8710efe1c333808dfbd05bf32
TREE_FILES := 130089
TREE_DIGEST := sha256:b01bbe7a886fa869a4018a5f711e11fae8fb783b30878216b0f8f408ad2a70bd
TREE_REF := $(REGISTRY)/gentoo-tree
TREE_DIR ?= output/repos/gentoo
# Where tree-check leaves the pulled archive for tree-restore-offline.
TREE_PULL ?= output/tree-archive
TREE_FILE = gentoo-tree-$(TREE_COMMIT).tar.zst
TREE_ENV = REGISTRY=$(REGISTRY) TREE_REF=$(TREE_REF) TREE_COMMIT=$(TREE_COMMIT) TREE_DIGEST=$(TREE_DIGEST)
# With GITHUB_TOKEN set (CI), log in to the registry inside the same toolbox run; the login ends with the container.
TREE_RUN = toolbox/run -e GITHUB_TOKEN -e GITHUB_ACTOR --
tree_login = if [ -n "$${GITHUB_TOKEN:-}" ]; then echo "$$GITHUB_TOKEN" | oras login $(firstword $(subst /, ,$(REGISTRY))) -u "$${GITHUB_ACTOR:-token}" --password-stdin; fi

# Restores the pinned tree into TREE_DIR.
sync-portage:
	$(TREE_RUN) sh -c 'set -eu; $(tree_login); $(TREE_ENV) TREE_DIR=$(TREE_DIR) sh scripts/sync-portage.sh'

# One-time: archives TREE_COMMIT from gentoo-mirror into the registry. Refuses an existing tag.
seed-tree:
	$(TREE_RUN) sh -c 'set -eu; $(tree_login); $(TREE_ENV) sh scripts/seed-tree.sh $(TREE_COMMIT)'

# Writes exists=true|false to $GITHUB_OUTPUT: whether TREE_REF:TREE_COMMIT is in the registry.
tree-exists:
	$(TREE_RUN) sh -c 'set -eu; $(tree_login); command -v oras >/dev/null || { echo "tree-exists: oras is not installed"; exit 1; }; if o=$$(oras manifest fetch --descriptor $(TREE_REF):$(TREE_COMMIT) 2>&1); then r=true; else case "$$o" in *"not found"*) r=false;; *) echo "tree-exists: cannot tell whether $(TREE_REF):$(TREE_COMMIT) exists:"; echo "$$o"; exit 1;; esac; fi; echo "exists=$$r" >> "$${GITHUB_OUTPUT:-/dev/stdout}"'

# The registry's manifest digest for TREE_REF:TREE_COMMIT equals TREE_DIGEST, and the tree restored from it has
# as many files as the archive lists. Leaves the archive in TREE_PULL and the tree in TREE_DIR.
tree-check:
	$(TREE_RUN) sh -c 'set -eu; $(tree_login); \
		d=$$(oras manifest fetch --descriptor $(TREE_REF):$(TREE_COMMIT) | sed -n "s/.*\"digest\": *\"\([^\"]*\)\".*/\1/p"); \
		[ "$$d" = "$(TREE_DIGEST)" ] || { echo "tree-check: $(TREE_REF):$(TREE_COMMIT) is $$d, want $(TREE_DIGEST)"; exit 1; }; \
		rm -rf "$(TREE_PULL)" "$(TREE_DIR)"; \
		oras pull -o "$(TREE_PULL)" $(TREE_REF)@$(TREE_DIGEST); \
		$(TREE_ENV) TREE_DIR=$(TREE_DIR) sh scripts/sync-portage.sh; \
		a=$$(zstd -dc "$(TREE_PULL)/$(TREE_FILE)" | tar -tf - | grep -v "/$$" | wc -l); \
		t=$$(find "$(TREE_DIR)" ! -type d | wc -l); \
		[ "$$a" -gt 0 ] && [ "$$a" -eq "$$t" ] || { echo "tree-check: archive lists $$a files, $(TREE_DIR) has $$t"; exit 1; }; \
		[ "$$t" -eq $(TREE_FILES) ] || { echo "tree-check: $(TREE_DIR) has $$t files, pinned $(TREE_FILES)"; exit 1; }; \
		echo "tree-check: $(TREE_REF):$(TREE_COMMIT) is $(TREE_DIGEST); $$t files restored, as in the archive"'

# AC-5: with no network, extracts the archive tree-check pulled and compares the tree with its listing.
tree-restore-offline:
	test -f '$(TREE_PULL)/$(TREE_FILE)' || { echo "tree-restore-offline: no $(TREE_PULL)/$(TREE_FILE); run make tree-check first"; exit 1; }
	toolbox/run --network none -- sh -c 'set -eu; rm -rf "$(TREE_DIR)"; mkdir -p "$(TREE_DIR)"; \
		zstd -dc "$(TREE_PULL)/$(TREE_FILE)" | tar -xpf - -C "$(TREE_DIR)"; \
		zstd -dc "$(TREE_PULL)/$(TREE_FILE)" | tar -tf - | grep -v "/$$" | LC_ALL=C sort > "$(TREE_PULL)/listed"; \
		(cd "$(TREE_DIR)" && find . ! -type d | sed "s,^\./,," | LC_ALL=C sort) > "$(TREE_PULL)/found"; \
		d=$$(zstd -dc "$(TREE_PULL)/$(TREE_FILE)" | tar -df - -C "$(TREE_DIR)" 2>&1 | grep -v ": \(Uid\|Gid\) differs$$" || true); \
		[ -z "$$d" ] || { echo "$$d" | head -n 20; echo "tree-restore-offline: $(TREE_DIR) differs in content from the archive"; exit 1; }; \
		diff "$(TREE_PULL)/listed" "$(TREE_PULL)/found" || { echo "tree-restore-offline: $(TREE_DIR) differs from the archive"; exit 1; }; \
		echo "tree-restore-offline: $$(wc -l < "$(TREE_PULL)/found") files extracted offline, as in the archive"'

# ---- S01: the SBOM and the three gates ----

# rc1's bom.cdx.json, the oracle that test-gates' SBOM is compared with on rc1's ISO.
RC1_SBOM_URL ?= https://github.com/tuckermclean/linux-live-iso-factory/releases/download/v0.1.0-rc1/bom.cdx.json
RC1_SBOM_SHA256 ?= 3cfc322a0e105638452baa6900552769a6ad5bfbf3be190a9808ac98ca575887
RC1_SBOM := output/rc1-bom.cdx.json
SBOM_DIFF_LIST := configs/attestation/rc1-sbom-diff.txt
GRYPE_CACHE := output/grype-cache
ATTEST_OUT := output/attestation
# The build's sysroot (output/sysroot): when set, the unowned gate also checks the rootfs provenance against it (B01 change 12).
PACKAGE_TREE ?=
# The tag the SBOM records: ISO's file name without themonolith- and .iso.
BUILD_TAG ?= $(patsubst themonolith-%.iso,%,$(notdir $(ISO)))

# The gates run in the builder image (I03), which has syft, grype, python3 and PyYAML. configs and scripts are read-only;
# output holds the rootfs, the ISO and the reports; the Grype DB lives in GRYPE_CACHE so it survives between runs.
ATTEST_RUN = $(DOCKER) run --rm \
	-v $(CURDIR)/configs:/configs:ro -v $(CURDIR)/scripts:/scripts:ro \
	-v $(CURDIR)/output:/output -v $(CURDIR)/$(GRYPE_CACHE):/root/.cache/grype \
	-e GITHUB_SERVER_URL -e GITHUB_REPOSITORY -e GITHUB_REF -e GITHUB_SHA -e GITHUB_RUN_ID -e BUILD_EPOCH \
	$(IMAGE_NAME)
ATTEST_ARGS = --sysroot /output/rootfs --iso /output/$(notdir $(ISO)) --build-tag $(BUILD_TAG) \
	--builder-digest $(BUILDER_DIGEST) \
	--overrides /configs/attestation/cpe-overrides.yaml \
	--policy /configs/attestation/license-policy.yaml \
	--cve-policy /configs/attestation/cve-policy.yaml \
	--unowned-allowlist /configs/attestation/unowned-allowlist.yaml \
	--bootstrap-exceptions /configs/attestation/bootstrap-exceptions.txt \
	--output-dir /output/attestation $(if $(PACKAGE_TREE),--package-tree /$(PACKAGE_TREE))

# Downloads RC1_SBOM_URL to $(RC1_SBOM) and checks its sha256; a mismatch deletes it and fails.
fetch_rc1_sbom = toolbox/run -- sh -c 'set -eu; f="$(RC1_SBOM)"; mkdir -p "$$(dirname "$$f")"; if [ -f "$$f" ] && echo "$(RC1_SBOM_SHA256)  $$f" | sha256sum -c --quiet -; then echo "==> $$f matches sha256 $(RC1_SBOM_SHA256)"; exit 0; fi; curl -fsSL --retry 3 -o "$$f.part" "$(RC1_SBOM_URL)"; echo "$(RC1_SBOM_SHA256)  $$f.part" | sha256sum -c - || { rm -f "$$f.part" "$$f"; echo "sha256 mismatch for $(RC1_SBOM_URL)"; exit 1; }; mv "$$f.part" "$$f"'
# jq -S of both SBOMs without the paths of SBOM_DIFF_LIST, then diff; a difference fails and is printed.
sbom_diff = toolbox/run --network none -- sh scripts/sbom-diff.sh $(SBOM_DIFF_LIST) $(ATTEST_OUT)/bom.cdx.json $(RC1_SBOM)

fetch-rc1-sbom:
	$(fetch_rc1_sbom)

# Compares the SBOM test-gates regenerated with rc1's.
sbom-diff-rc1: fetch-rc1-sbom
	$(sbom_diff)

# Updates the Grype vulnerability database in GRYPE_CACHE.
grype-db-update: pull-image
	mkdir -p $(GRYPE_CACHE)
	@echo "==> Updating the Grype vulnerability database"
	$(ATTEST_RUN) grype db update

# SBOM, licence, CVE and unowned gates on ARTIFACT_ROOTFS (run make rootfs first). Reports in ATTEST_OUT.
attestation: rootfs pull-image grype-db-update
	@echo "==> Running the attestation pipeline (build: $(BUILD_TAG))"
	rm -rf $(ATTEST_OUT)
	mkdir -p $(ATTEST_OUT)
	$(ATTEST_RUN) /scripts/attestation.sh $(ATTEST_ARGS)

# The same, with the builder environment (Pillar 5) attested too.
attest-builder: rootfs pull-image grype-db-update
	@echo "==> Running the attestation pipeline including the builder (build: $(BUILD_TAG))"
	rm -rf $(ATTEST_OUT)
	mkdir -p $(ATTEST_OUT)
	$(ATTEST_RUN) /scripts/attestation.sh $(ATTEST_ARGS) --include-builder

# The gates on the rootfs of ISO. Any ISO: attestation.sh must exit 0. rc1's ISO (its sha256 is RC1_SHA256): the licence and
# unowned gates must pass and the CVE coverage report must record db.built; the CVE gating findings are printed (and added to
# $GITHUB_STEP_SUMMARY), not gating; then the SBOM must equal rc1's outside SBOM_DIFF_LIST.
test-gates: rootfs pull-image grype-db-update
	rm -rf $(ATTEST_OUT)
	mkdir -p $(ATTEST_OUT)
	@sha256sum '$(ISO)' | cut -d' ' -f1 > output/gates-iso.sha256
	@rc1=0; [ "$$(cat output/gates-iso.sha256)" = '$(RC1_SHA256)' ] && rc1=1; \
	$(ATTEST_RUN) /scripts/attestation.sh $(ATTEST_ARGS); arc=$$?; \
	echo "==> attestation.sh exited $$arc"; \
	flag=; [ $$rc1 = 1 ] && flag=--rc1; \
	toolbox/run --network none -e GITHUB_STEP_SUMMARY -- sh scripts/gates-verdict.sh $$flag $(ATTEST_OUT) || exit 1; \
	[ -f $(ATTEST_OUT)/bom.cdx.json ] || { echo "test-gates: attestation.sh wrote no $(ATTEST_OUT)/bom.cdx.json"; exit 1; }; \
	if [ $$rc1 = 1 ]; then $(if $(ISO_URL),$(fetch_rc1_sbom) || exit 1;,[ -f $(RC1_SBOM) ] || { echo "test-gates: rc1's ISO needs $(RC1_SBOM); run make fetch-rc1-sbom"; exit 1; };) $(sbom_diff) || exit 1; \
	else [ $$arc -eq 0 ] || exit 1; fi; \
	echo "test-gates: PASS"

# B01-AC-16: a revbump or package.use change rebuilds a cached static consumer, in the pinned builder, on the host.
test-static-rebuild: pull-image sync-portage
	DOCKER='$(DOCKER)' TREE_DIR='$(abspath $(TREE_DIR))' sh scripts/tests/static-rebuild.itest.sh

# The scanner is alive: check-cves.sh on the canary SBOM (Heartbleed) must find something.
test-cve-canary: pull-image grype-db-update
	$(ATTEST_RUN) grype db status
	@$(ATTEST_RUN) bash /scripts/run-cve-canary.sh || { \
		echo "::error::The CVE gate canary failed — see the output of make test-cve-canary above."; \
		echo "::error::This means Grype produced zero findings against a fixture SBOM pinned to"; \
		echo "::error::CVE-2014-0160 (Heartbleed), a permanent, fully-analyzed CVE. That is not"; \
		echo "::error::possible for a working scanner. Every real build's CVE PASS is suspect"; \
		echo "::error::until this is fixed — do not merge/release until it's green again."; \
		echo "::error::See docs/cve-gate.md for background and scripts/run-cve-canary.sh for the check."; \
		exit 1; }

# ---- B01: the binary package cache ----

PKGDIR ?= output/packages
# The cache tag inputs are the pins above; the CI ref policy (main pushes, tags do not pull) is in the script.
CACHE_RUN = toolbox/run -e GITHUB_TOKEN -e GITHUB_ACTOR -e GITHUB_ACTIONS -e GITHUB_REF --
CACHE_ENV = REGISTRY=$(REGISTRY) BUILDER_DIGEST=$(BUILDER_DIGEST) TREE_COMMIT=$(TREE_COMMIT) PKGDIR=$(PKGDIR)

# Prints the cache tag.
cache-tag:
	@toolbox/run --network none -- env $(CACHE_ENV) bash scripts/binpkg-store.sh tag

# Pulls the cache for the current tag into PKGDIR; a miss leaves it empty, any other failure stops here.
cache-pull:
	$(CACHE_RUN) sh -c 'set -eu; $(tree_login); $(CACHE_ENV) bash scripts/binpkg-store.sh pull; bash scripts/savedconfig-cache.sh check $(PKGDIR)'

# Prunes superseded packages, packs PKGDIR and pushes it under the current tag.
cache-push:
	$(CACHE_RUN) sh -c 'set -eu; $(tree_login); bash scripts/savedconfig-cache.sh mark $(PKGDIR) && $(CACHE_ENV) bash scripts/binpkg-store.sh prune && $(CACHE_ENV) bash scripts/binpkg-store.sh pack && $(CACHE_ENV) bash scripts/binpkg-store.sh push'

# ---- B01: the package build, in the builder image (I03) on the pinned tree (I02) ----

# JOBS and LOAD_AVG reach the container; MONOLITH_USEPKG=n is a release build (every package from source,
# PKGDIR empty at the start; see scripts/build-packages.sh).
JOBS ?= $(shell nproc)
LOAD_AVG ?= $(shell nproc)
MONOLITH_USEPKG ?= y
PARALLEL_ENV := -e JOBS=$(JOBS) -e LOAD_AVG=$(LOAD_AVG) -e MONOLITH_USEPKG=$(MONOLITH_USEPKG)
DISTFILES_DIR ?= output/distfiles
PORTAGE_LOGS_DIR ?= output/portage-logs

# configs stays writable: update-versions and menuconfig-busybox write through it (versions.lock, the busybox savedconfig).
# The kernel build writes nothing there; its resolved config is exported to output/kernel.resolved.config.
# The pinned tree replaces the predecessor's repos volume; distfiles and the other state are directories under output.
BUILD_MOUNTS := -v $(CURDIR)/configs:/configs -v $(CURDIR)/scripts:/scripts:ro \
	-v $(CURDIR)/output:/output -v $(abspath $(TREE_DIR)):/var/db/repos/gentoo \
	-v $(abspath $(DISTFILES_DIR)):/var/cache/distfiles -v $(abspath $(PORTAGE_LOGS_DIR)):/var/log/portage
BUILD_RUN = $(DOCKER) run --rm $(BUILD_MOUNTS) $(PARALLEL_ENV) $(IMAGE_NAME)
BUILD_RUN_IT = $(DOCKER) run --rm -it $(BUILD_MOUNTS) $(PARALLEL_ENV) $(IMAGE_NAME)

# Creates the output directories the build writes.
ensure-dirs:
	@mkdir -p output/packages output/logs output/sysroot $(DISTFILES_DIR) $(PORTAGE_LOGS_DIR)

# The build state is directories, not named volumes; the pinned tree must be in TREE_DIR (make sync-portage).
ensure-volume: ensure-dirs
	@test -d '$(TREE_DIR)/profiles' || { echo "ensure-volume: no pinned tree in $(TREE_DIR); run make sync-portage"; exit 1; }

# Cross-compiles every world package into PKGDIR and exports output/sysroot.
build-packages: pull-image ensure-volume
	@echo "==> Building packages ($(JOBS) parallel jobs)"
	$(BUILD_RUN) /scripts/build-packages.sh

# Resume build (skip already-built packages)
build-packages-resume: pull-image ensure-volume
	@echo "==> Resuming package build ($(JOBS) parallel jobs)"
	$(BUILD_RUN) /scripts/build-packages.sh --resume

# Install pre-built packages into the sysroot
extract: pull-image ensure-volume
	@echo "==> Installing packages from binpkgs"
	$(BUILD_RUN) /scripts/extract-packages.sh

# ---- B03: the root filesystem, the initramfs and the ISO ----

ROOTFS_RUN = $(DOCKER) run --rm -v $(CURDIR)/configs:/configs:ro -v $(CURDIR)/scripts:/scripts:ro \
	-v $(CURDIR)/rootfs:/rootfs:ro -v $(CURDIR)/output:/work/output -e OUTPUT_DIR=/work/output $(VERSION_ENV) $(IMAGE_NAME)

# Asserts the kernel modules the tier docs promise are in the sysroot of the package build.
verify-kernel-modules:
	toolbox/run --network none -- sh scripts/verify-kernel-modules.sh output/sysroot

# The package build runs as root in the builder image: hand output/packages to the runner before cache-push writes to it.
take-packages:
	$(DOCKER) run --rm -v $(CURDIR)/output:/output $(IMAGE_NAME) chown -R $(shell id -u):$(shell id -g) /output/packages

# output/sysroot as one tar (output/sysroot.tar), for the job that checks the rootfs provenance; an artifact would lose its symlinks.
sysroot-pack:
	$(DOCKER) run --rm -v $(CURDIR)/output:/output $(IMAGE_NAME) sh -c 'tar -C /output/sysroot -cf /output/sysroot.tar . && chmod a+r /output/sysroot.tar'

# The reverse, into output/sysroot.
sysroot-unpack:
	mkdir -p output/sysroot
	toolbox/run --network none -- tar --no-same-owner -C output/sysroot -xf output/sysroot.tar

# Builds the squashfs and the initramfs from output/sysroot (make build-packages first).
build-rootfs: pull-image ensure-dirs
	@echo "==> Building root filesystem"
	$(ROOTFS_RUN) /scripts/build-rootfs.sh
	@echo "==> Building initramfs"
	$(ROOTFS_RUN) /scripts/build-initrd.sh

# Assembles the bootable ISO, output/themonolith-$(BUILD_VERSION).iso, from the squashfs, the initramfs and the kernel.
iso: pull-image ensure-dirs
	@echo "==> Creating bootable ISO"
	$(ROOTFS_RUN) /scripts/build-iso.sh

# Copies the built ISO to output/iso/boot-test.iso, the name the reusable boot-test workflow downloads.
iso-stage:
	mkdir -p output/iso
	cp '$(BUILT_ISO)' output/iso/boot-test.iso

# Everything: packages, root filesystem, ISO.
all: sync-portage build-packages build-rootfs iso

# Writes build=true|false to $GITHUB_OUTPUT: whether this run builds (the full-ci label, the changed paths; scripts/changed-paths.sh).
# It runs on the runner itself: it reads the event file and needs git and jq.
changes:
	sh scripts/changed-paths.sh

# Interactive BusyBox menuconfig; saves the result to configs/portage/savedconfig/sys-apps/busybox
menuconfig-busybox: pull-image ensure-volume
	@echo "==> Running BusyBox menuconfig"
	$(BUILD_RUN_IT) i486-linux-musl-emerge --config sys-apps/busybox

# Package versions available now against the versions.lock pins
check-updates: pull-image ensure-volume
	@echo "==> Checking for package updates"
	$(BUILD_RUN) /scripts/update-versions.sh check

# Interactive kernel menuconfig, starting from the kernel savedconfig (no fallback: it must exist).
# Writes only output/kernel.config.new; review it and copy it to the savedconfig by hand.
# Drives tar/patch/make directly: portage's environment sanitization breaks the ncurses TUI.
# The container is --rm, so the scratch source tree needs no cleanup.
menuconfig-kernel: pull-image ensure-volume
	@echo "==> Running kernel menuconfig"
	$(DOCKER) run --rm -it -e TERM $(BUILD_MOUNTS) $(PARALLEL_ENV) $(IMAGE_NAME) sh -c \
	    'set -e; \
	     KVER=$(KERNEL_VERSION); KVER=$${KVER%-r*}; \
	     SAVED=/configs/portage/savedconfig/sys-kernel/monolith-kernel; \
	     PATCH=/configs/overlay/sys-kernel/monolith-kernel/files/linux-$${KVER%.*}-gcc15-std-gnu11.patch; \
	     [ -f "$$SAVED" ] || { echo "menuconfig-kernel: no kernel savedconfig at configs/portage/savedconfig/sys-kernel/monolith-kernel"; exit 1; }; \
	     SRCDIR=/tmp/kernel-menuconfig; \
	     mkdir -p "$$SRCDIR"; \
	     echo "==> Extracting linux-$${KVER}.tar.xz ..."; \
	     tar xf /var/cache/distfiles/linux-$${KVER}.tar.xz -C "$$SRCDIR" --strip-components=1; \
	     cd "$$SRCDIR"; \
	     patch -p1 < "$$PATCH"; \
	     cp "$$SAVED" .config; \
	     make ARCH=i386 CROSS_COMPILE=i486-linux-musl- olddefconfig; \
	     make ARCH=i386 CROSS_COMPILE=i486-linux-musl- menuconfig && cp .config /output/kernel.config.new && echo "==> Config saved to output/kernel.config.new"'

# Regenerates the monolith-kernel Manifest (run after changing the ebuild)
regen-manifest: pull-image ensure-volume
	$(BUILD_RUN_IT) \
	    ebuild /configs/overlay/sys-kernel/monolith-kernel/monolith-kernel-$(KERNEL_VERSION).ebuild manifest

# Regenerates versions.lock from world against the pinned tree; an atom that does not resolve fails.
update-versions: pull-image sync-portage ensure-volume
	@echo "==> Updating versions.lock"
	$(BUILD_RUN) /scripts/update-versions.sh update

# List packages in world file
list-packages:
	@echo "==> Packages in world file:"
	@grep -v '^#' configs/portage/world | grep -v '^$$' || true

# Show failed packages from last build
show-failed:
	@echo "==> Failed packages:"
	@cat output/.failed-packages 2>/dev/null || echo "(none or no build run yet)"
	@echo ""
	@echo "==> Logs available in: output/logs/"

# Drop into container shell
shell: pull-image ensure-volume
	@echo "==> Dropping into container shell"
	$(BUILD_RUN_IT) /bin/bash

# Clean output directory only
clean:
	@echo "==> Cleaning output directory"
	rm -rf output/*
