# SPEC section 7: CI calls these targets; a test is always a Make target.
SHELL_EXTRA ?=

.PHONY: test test-lint test-unit test-boot test-artifact rootfs fetch-iso run-bios run-uefi iso-artifact-name

test: test-lint test-unit test-boot test-artifact

test-lint:
	toolbox/run --network none -- sh scripts/test-lint.sh $(SHELL_EXTRA)

test-unit:
	toolbox/run --network none -- sh -c 'echo "==> Shell unit tests (scripts/tests/*.sh)"; rc=0; for t in scripts/tests/*.sh; do [ -e "$$t" ] || continue; echo "==> Running $$t"; sh "$$t" || { echo "::error file=$$t::test suite failed"; rc=1; }; done; exit $$rc'

# ---- O01: boot tests (the 17 modes of scripts/boot-test.py) and manual boots ----

# Until B03 builds an ISO, the default ISO is v0.1.0-rc1's, fetched by URL and checked against its sha256.
ISO_URL ?= https://github.com/tuckermclean/linux-live-iso-factory/releases/download/v0.1.0-rc1/themonolith-0.1.0-rc1.iso
RC1_SHA256 ?= a96006596b13cc09fa951f54aadc0b816765d783e5d0e40895d7d0945edeb27a
ISO_SHA256 ?= $(RC1_SHA256)
EXPECTED_KERNEL ?= 6.12.80-i486-monolith
DEFAULT_ISO := output/themonolith-0.1.0-rc1.iso
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
# at its default, that ISO is fetched and checked first. Records the QEMU and OVMF versions.
test-boot: $(if $(filter $(ISO),$(DEFAULT_ISO)),fetch-iso)
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
rootfs: $(if $(filter $(ISO),$(DEFAULT_ISO)),fetch-iso)
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
