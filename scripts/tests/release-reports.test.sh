#!/bin/sh
# P01 slice 2: the Make targets and report scripts behind the release workflows (node spec changes 3, 8, 11, AC-2(b)).
#   P01-AC-7   the file diff of rc1-diff.md: unsquashfs -lls path lists of the two ISOs' squashfs
#   P01-AC-10  the allowlist report (dynamic-allowlist.txt with its entry count)
#   P01-AC-2   (b) the Make target that runs both `gh attestation verify` commands on rc1's ISO; change 11, the
#              CycloneDX schema check
#   P01-AC-3/6 the digest chain and the package-set check are reachable as Make targets; the compare job's log
#   P01-AC-5   (static) the Make target that pushes the distfiles
#
# Interfaces chosen here (the implementer writes the scripts and recipes from this header alone):
#   sh scripts/squashfs-diff.sh <old.squashfs> <new.squashfs>
#       Runs `unsquashfs -lls <file>` on each (the last argument is the squashfs; other options are free), compares the
#       sorted PATHS (the last field of an entry; a " -> target" of a symlink is not part of the path; sizes, owners
#       and times are not compared). stdout: Markdown with a section whose heading names "added" and one that names
#       "removed", a path per line in the section it belongs to. exit 0 (a report, not a gate); non-zero on a usage
#       error or an unreadable input.
#   sh scripts/allowlist-report.sh <dynamic-allowlist.txt>
#       stdout: the file verbatim (comments and all), then a last line `# entries: <N>`, N = the lines that are neither
#       blank nor start with #. exit 0; non-zero on a usage error or an unreadable file.
#   make rc1-diff            `make -n` names scripts/rc1-diff.sh, scripts/squashfs-diff.sh, docs/rc1-diff-reasons.tsv,
#                            output/rc1-bom.cdx.json (RC1_SBOM) and rc1-diff.md.
#   make allowlist-report    `make -n` names scripts/allowlist-report.sh and configs/attestation/dynamic-allowlist.txt.
#   make release-package-set WORLD=<world> ROOTFS=<dir> AUDIT=<source-audit.tsv>   runs scripts/release-package-set.sh
#                            --world/--rootfs/--audit with those values (flags as in release-package-set.test.sh).
#   make release-digest-chain ISO=<iso> SUMS=<SHA256SUMS> BOM=<bom.cdx.json> COMPARE_LOG=<log>
#                            runs scripts/release-digest-chain.sh with the repository GITHUB_REPOSITORY (environment)
#                            and the signer workflow $GITHUB_REPOSITORY/.github/workflows/build.yml; exits as the script.
#   make check-cyclonedx BOM=<bom.cdx.json>   check-jsonschema against the vendored configs/attestation/schemas/
#                            (bom-<specVersion>.schema.json, --base-uri on that directory); exit 0 when valid, non-zero
#                            when not.
#   make push-distfiles      `make -n` names oras push, distfiles, REGISTRY and DISTFILES_DIGEST (release-inputs.json).
#   make compare ISO_A=a ISO_B=b COMPARE_LOG=<file>   as before; additionally writes the stdout of
#                            scripts/compare-isos.sh, and only that, to COMPARE_LOG (default output/compare.log); it
#                            still fails on a mismatch.
#   make verify-rc1-attestation RC1_ISO=<iso> [RC1_SHA256=<sha256>]
#                            1. fails if sha256(RC1_ISO) != RC1_SHA256 (Makefile default a9600659...eb27a);
#                            2. runs `gh attestation verify <RC1_ISO> --repo tuckermclean/linux-live-iso-factory
#                               --signer-workflow tuckermclean/linux-live-iso-factory/.github/workflows/build.yml`,
#                               which must succeed;
#                            3. runs `gh attestation verify <RC1_ISO> --repo tuckermclean/themonolith ...`, which must FAIL;
#                            exit 0 only when 2 succeeds and 3 fails. Never uses --owner. Its prerequisites must not
#                            download anything when RC1_ISO exists and matches RC1_SHA256.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
MK() { (cd "$ROOT" && env "$@"); }
GITHUB_REPOSITORY=tuckermclean/themonolith; export GITHUB_REPOSITORY

# ---------------------------------------------------------------- P01-AC-7: squashfs-diff.sh
S="$ROOT/scripts/squashfs-diff.sh"
cat > "$TMP/bin/unsquashfs" <<'E'
#!/bin/sh
# stub: the "squashfs" is the listing itself; the last argument is the file
for a; do f=$a; done
cat "$f"
E
chmod +x "$TMP/bin/unsquashfs"
cat > "$TMP/old.sq" <<'E'
drwxr-xr-x root/root                 0 2024-01-01 00:00 squashfs-root
-rwxr-xr-x root/root            100000 2024-01-01 00:00 squashfs-root/bin/busybox
lrwxrwxrwx root/root                 7 2024-01-01 00:00 squashfs-root/bin/sh -> busybox
-rw-r--r-- root/root               120 2024-01-01 00:00 squashfs-root/etc/gone-in-new
-rw-r--r-- root/root                50 2024-01-01 00:00 squashfs-root/etc/same
E
cat > "$TMP/new.sq" <<'E'
drwxr-xr-x root/root                 0 2025-06-06 12:34 squashfs-root
-rwxr-xr-x root/root            100999 2025-06-06 12:34 squashfs-root/bin/busybox
lrwxrwxrwx root/root                 7 2025-06-06 12:34 squashfs-root/bin/sh -> busybox
-rw-r--r-- root/root                50 2025-06-06 12:34 squashfs-root/etc/same
-rw-r--r-- root/root               777 2025-06-06 12:34 squashfs-root/etc/only-in-new
E
out=$(PATH="$TMP/bin:$PATH" sh "$S" "$TMP/old.sq" "$TMP/new.sq" 2>&1); rc=$?
sq_ok=0; [ "$rc" = 0 ] && sq_ok=1
if [ "$rc" = 0 ]; then ok "P01-AC-7: squashfs-diff.sh exits 0 on two listings that differ"
else fail "P01-AC-7: squashfs-diff.sh must exit 0 and report (rc=$rc: $(echo "$out" | head -2))"; fi
section() { # <path>: prints the lower-cased last heading line containing added or removed above the line naming the path
	echo "$out" | awk -v p="$1" '/[Aa]dded|[Rr]emoved/ && !index($0, "/") {s=tolower($0)} index($0, p) {print s; exit}'
}
case $(section etc/only-in-new) in *added*) ok "P01-AC-7: a path only in the new squashfs is listed under added";; *) fail "P01-AC-7: etc/only-in-new must be listed under an added section";; esac
case $(section etc/gone-in-new) in *removed*) ok "P01-AC-7: a path only in the old squashfs is listed under removed";; *) fail "P01-AC-7: etc/gone-in-new must be listed under a removed section";; esac
if [ $sq_ok = 0 ] || echo "$out" | grep -q 'etc/same' || echo "$out" | grep -q 'bin/busybox' || echo "$out" | grep -q 'bin/sh'; then
	fail "P01-AC-7: paths present in both listings (size and time differ) must not be reported"
else ok "P01-AC-7: paths present in both listings are not reported"; fi
[ $sq_ok = 1 ] && ! PATH="$TMP/bin:$PATH" sh "$S" "$TMP/old.sq" >/dev/null 2>&1 && ok "P01-AC-7: a missing argument is an error" || fail "P01-AC-7: a missing argument must be an error (with the script working)"
[ $sq_ok = 1 ] && ! PATH="$TMP/bin:$PATH" sh "$S" "$TMP/old.sq" "$TMP/missing.sq" >/dev/null 2>&1 && ok "P01-AC-7: an unreadable squashfs is an error" || fail "P01-AC-7: an unreadable squashfs must be an error (with the script working)"

# ---------------------------------------------------------------- P01-AC-10: allowlist-report.sh
S="$ROOT/scripts/allowlist-report.sh"
printf '# dynamic allowlist\n\n/usr/bin/one # #12 needs glibc\n/usr/bin/two # #13 vendor blob\n\n/usr/lib/three.so # #14 plugin\n' > "$TMP/al.txt"
out=$(sh "$S" "$TMP/al.txt" 2>&1); rc=$?
want=$(grep -v '^#' "$TMP/al.txt" | grep -vc '^[[:space:]]*$')
if [ "$rc" = 0 ] && [ "$(echo "$out" | tail -n 1)" = "# entries: $want" ]; then ok "P01-AC-10: allowlist-report ends with '# entries: $want'"
else fail "P01-AC-10: allowlist-report must exit 0 and end with '# entries: $want' (rc=$rc, last: $(echo "$out" | tail -n 1))"; fi
if [ "$(echo "$out" | head -n "$(wc -l < "$TMP/al.txt")")" = "$(cat "$TMP/al.txt")" ]; then ok "P01-AC-10: allowlist-report copies the file verbatim before the count"
else fail "P01-AC-10: allowlist-report must copy the allowlist verbatim"; fi
real="$ROOT/configs/attestation/dynamic-allowlist.txt"
want=$(grep -v '^#' "$real" | grep -vc '^[[:space:]]*$')
out=$(sh "$S" "$real" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(echo "$out" | tail -n 1)" = "# entries: $want" ]; then ok "P01-AC-10: the real allowlist is reported with its $want entries"
else fail "P01-AC-10: the real allowlist must report '# entries: $want' (rc=$rc)"; fi
[ "$rc" = 0 ] && ! sh "$S" "$TMP/missing.txt" >/dev/null 2>&1 && ok "P01-AC-10: an unreadable allowlist is an error" || fail "P01-AC-10: an unreadable allowlist must be an error (with the script working)"

# ---------------------------------------------------------------- Make targets, make -n
mkn() { (cd "$ROOT" && make -n "$@" 2>&1); }
need_all() { # <label> <make -n output> <needle>...
	l=$1; o=$2; shift 2; miss=
	for n; do echo "$o" | grep -qF -- "$n" || miss="$miss $n"; done
	if [ -z "$miss" ]; then ok "$l"; else fail "$l (not named:$miss)"; fi
}
need_all "P01-AC-7: make -n rc1-diff names rc1-diff.sh, squashfs-diff.sh, the reasons file, the rc1 SBOM and rc1-diff.md" "$(mkn rc1-diff)" \
	scripts/rc1-diff.sh scripts/squashfs-diff.sh docs/rc1-diff-reasons.tsv output/rc1-bom.cdx.json rc1-diff.md
need_all "P01-AC-10: make -n allowlist-report names allowlist-report.sh and the allowlist" "$(mkn allowlist-report)" \
	scripts/allowlist-report.sh configs/attestation/dynamic-allowlist.txt
need_all "P01-AC-11: make -n release-package-set passes --world, --rootfs and --audit" \
	"$(mkn release-package-set WORLD=/w/world ROOTFS=/r/rootfs AUDIT=/a/audit.tsv)" \
	scripts/release-package-set.sh /w/world /r/rootfs /a/audit.tsv --world --rootfs --audit
need_all "P01-AC-3: make -n release-digest-chain runs release-digest-chain.sh with its five files" \
	"$(mkn release-digest-chain ISO=/i/x.iso SUMS=/i/SUMS BOM=/i/b.json COMPARE_LOG=/i/c.log)" \
	scripts/release-digest-chain.sh /i/x.iso /i/SUMS /i/b.json /i/c.log
need_all "P01-AC-5: make -n push-distfiles runs oras push to the distfiles repository and checks DISTFILES_DIGEST" "$(mkn push-distfiles)" \
	"oras push" distfiles REGISTRY DISTFILES_DIGEST
need_all "P01-AC-2: make -n check-cyclonedx runs check-jsonschema on the vendored schemas" "$(mkn check-cyclonedx BOM=/i/b.json)" \
	check-jsonschema configs/attestation/schemas /i/b.json
need_all "P01-AC-2: make -n verify-rc1-attestation names both repositories and never --owner" "$(mkn verify-rc1-attestation RC1_ISO=/i/rc1.iso)" \
	"gh attestation verify" tuckermclean/linux-live-iso-factory tuckermclean/themonolith
vo=$(mkn verify-rc1-attestation RC1_ISO=/i/rc1.iso)
if ! echo "$vo" | grep -q 'attestation verify' || echo "$vo" | grep -q -- '--owner'; then fail "P01-AC-2: verify-rc1-attestation must not use --owner"; else ok "P01-AC-2: verify-rc1-attestation does not use --owner"; fi

# ---------------------------------------------------------------- P01-AC-6: the compare log
head -c 4096 /dev/zero | tr '\0' 'M' > "$TMP/a.iso"; cp "$TMP/a.iso" "$TMP/b.iso"
rm -f "$TMP/compare.log"
mrc=0; MK make compare ISO_A="$TMP/a.iso" ISO_B="$TMP/b.iso" COMPARE_LOG="$TMP/compare.log" >"$TMP/mk-compare.out" 2>&1 || mrc=$?
want=$(sh "$ROOT/scripts/compare-isos.sh" "$TMP/a.iso" "$TMP/b.iso" 2>/dev/null)
if [ "$mrc" = 0 ] && [ -f "$TMP/compare.log" ] && [ "$(cat "$TMP/compare.log")" = "$want" ]; then
	ok "P01-AC-6: make compare writes exactly compare-isos.sh's stdout to COMPARE_LOG"
else fail "P01-AC-6: make compare must write compare-isos.sh's stdout, and only that, to COMPARE_LOG (rc=$mrc)"; fi
cmp_ok=0; [ "$mrc" = 0 ] && cmp_ok=1
n=$(grep -cE '^[0-9a-f]{64}  ' "$TMP/compare.log" 2>/dev/null); [ "${n:-0}" = 2 ] && ok "P01-AC-6: the compare log has two digest lines" || fail "P01-AC-6: the compare log must have two '<sha256>  <path>' lines (has ${n:-0})"
printf 'X' | dd of="$TMP/b.iso" bs=1 seek=100 conv=notrunc 2>/dev/null
mrc=0; MK make compare ISO_A="$TMP/a.iso" ISO_B="$TMP/b.iso" COMPARE_LOG="$TMP/compare2.log" >/dev/null 2>&1 || mrc=$?
[ "$mrc" != 0 ] && [ $cmp_ok = 1 ] && ok "P01-AC-6: make compare still fails on a mismatch while writing the log" || fail "P01-AC-6: make compare must fail on a mismatch"

# ---------------------------------------------------------------- change 11: the CycloneDX schema check
printf '{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":[{"type":"library","name":"zlib","version":"1.3"}]}\n' > "$TMP/good-bom.json"
printf '{"bomFormat":"CycloneDX","specVersion":"1.6","version":"one","components":"none"}\n' > "$TMP/bad-bom.json"
mrc=0; MK make check-cyclonedx BOM="$TMP/good-bom.json" >"$TMP/cdx-good.out" 2>&1 || mrc=$?
cdx_ok=0; [ "$mrc" = 0 ] && cdx_ok=1
[ "$mrc" = 0 ] && ok "P01-AC-2: make check-cyclonedx accepts a valid CycloneDX 1.6 document" || fail "P01-AC-2: make check-cyclonedx must accept a valid document (rc=$mrc: $(tail -n 2 "$TMP/cdx-good.out" | tr '\n' ' '))"
mrc=0; MK make check-cyclonedx BOM="$TMP/bad-bom.json" >"$TMP/cdx-bad.out" 2>&1 || mrc=$?
[ "$mrc" != 0 ] && [ $cdx_ok = 1 ] && ok "P01-AC-2: make check-cyclonedx rejects an invalid document" || fail "P01-AC-2: make check-cyclonedx must reject a document that breaks the schema"
mrc=0; MK make check-cyclonedx BOM="$TMP/none.json" >/dev/null 2>&1 || mrc=$?
[ "$mrc" != 0 ] && [ $cdx_ok = 1 ] && ok "P01-AC-2: make check-cyclonedx fails on a missing file" || fail "P01-AC-2: make check-cyclonedx must fail on a missing file"

# ---------------------------------------------------------------- P01-AC-3 through make
cat > "$TMP/bin/gh" <<'E'
#!/bin/sh
# stub gh: logs its arguments; exit 0 when GH_MODE=pass, else 0 only for the predecessor's repository
echo "$*" >> "$GH_LOG"
case "${GH_MODE:-rc1}" in
pass) ;;
fail) exit 1 ;;
chain) case "$*" in *"--format json"*) cat "$GH_JSON";; esac ;;
rc1) case "$*" in *"--repo tuckermclean/linux-live-iso-factory"*) exit 0;; *) exit 1;; esac ;;
esac
exit 0
E
chmod +x "$TMP/bin/gh"
GH_LOG="$TMP/gh.log"; GH_JSON="$TMP/gh.json"; export GH_LOG GH_JSON
printf 'release candidate\n' > "$TMP/rel.iso"
D=$(sha256sum "$TMP/rel.iso" | cut -d' ' -f1)
printf '%s  rel.iso\n' "$D" > "$TMP/SUMS"
printf '{"bomFormat":"CycloneDX","metadata":{"component":{"name":"rel.iso","hashes":[{"alg":"SHA-256","content":"%s"}]}},"components":[]}\n' "$D" > "$TMP/bom.json"
printf '%s  a/rel.iso\n%s  b/rel.iso\ncompare-isos: the ISOs are identical\n' "$D" "$D" > "$TMP/cmp.log"
printf '[{"verificationResult":{"statement":{"subject":[{"digest":{"sha256":"%s"}}]}}}]\n' "$D" > "$TMP/gh.json"
: > "$GH_LOG"
mrc=0; MK PATH="$TMP/bin:$PATH" GH_MODE=chain make release-digest-chain ISO="$TMP/rel.iso" SUMS="$TMP/SUMS" BOM="$TMP/bom.json" COMPARE_LOG="$TMP/cmp.log" >"$TMP/dc.out" 2>&1 || mrc=$?
dc_ok=0; [ "$mrc" = 0 ] && dc_ok=1
if [ "$mrc" = 0 ] && grep -q -- '--repo tuckermclean/themonolith' "$GH_LOG" && grep -q -- '--signer-workflow tuckermclean/themonolith/.github/workflows/build.yml' "$GH_LOG"; then
	ok "P01-AC-3: make release-digest-chain verifies against GITHUB_REPOSITORY and its build.yml and passes a consistent set"
else fail "P01-AC-3: make release-digest-chain must exit 0 on a consistent set with --repo/--signer-workflow from GITHUB_REPOSITORY (rc=$mrc)"; fi
printf '%s  a/rel.iso\n%s  b/rel.iso\n' "$D" "$(printf x | sha256sum | cut -d' ' -f1)" > "$TMP/cmp.log"
mrc=0; MK PATH="$TMP/bin:$PATH" GH_MODE=chain make release-digest-chain ISO="$TMP/rel.iso" SUMS="$TMP/SUMS" BOM="$TMP/bom.json" COMPARE_LOG="$TMP/cmp.log" >/dev/null 2>&1 || mrc=$?
[ "$mrc" != 0 ] && [ $dc_ok = 1 ] && ok "P01-AC-6: make release-digest-chain fails when the compare log's second digest differs" || fail "P01-AC-6: make release-digest-chain must fail on a differing compare digest"

# ---------------------------------------------------------------- P01-AC-2 (b): verify-rc1-attestation
printf 'pretend rc1 iso\n' > "$TMP/rc1.iso"
RS=$(sha256sum "$TMP/rc1.iso" | cut -d' ' -f1)
WSF=tuckermclean/linux-live-iso-factory/.github/workflows/build.yml
run_rc1() { # <GH_MODE> [RC1_SHA256]
	: > "$GH_LOG"; mrc=0
	MK PATH="$TMP/bin:$PATH" GH_MODE=$1 make verify-rc1-attestation RC1_ISO="$TMP/rc1.iso" RC1_SHA256="${2:-$RS}" >"$TMP/rc1.out" 2>&1 || mrc=$?
}
run_rc1 rc1
rc1_ok=0; [ "$mrc" = 0 ] && rc1_ok=1
if [ "$mrc" = 0 ]; then ok "P01-AC-2: verify-rc1-attestation exits 0 when the predecessor repo verifies and this repo does not"
else fail "P01-AC-2: verify-rc1-attestation must exit 0 (rc=$mrc: $(tail -n 2 "$TMP/rc1.out" | tr '\n' ' '))"; fi
if grep -qF -- "attestation verify $TMP/rc1.iso --repo tuckermclean/linux-live-iso-factory --signer-workflow $WSF" "$GH_LOG"; then
	ok "P01-AC-2: it runs gh attestation verify <iso> --repo <predecessor> --signer-workflow <predecessor build.yml>"
else fail "P01-AC-2: gh attestation verify <iso> --repo tuckermclean/linux-live-iso-factory --signer-workflow $WSF was not run"; fi
if grep -qF -- "attestation verify $TMP/rc1.iso" "$GH_LOG" && grep -F -- "--repo tuckermclean/themonolith" "$GH_LOG" | grep -qF "$TMP/rc1.iso"; then
	ok "P01-AC-2: it also runs gh attestation verify <iso> --repo tuckermclean/themonolith"
else fail "P01-AC-2: gh attestation verify <iso> --repo tuckermclean/themonolith was not run"; fi
if [ ! -s "$GH_LOG" ] || grep -q -- '--owner' "$GH_LOG"; then fail "P01-AC-2: verify-rc1-attestation must not use --owner"; else ok "P01-AC-2: no gh call uses --owner"; fi
run_rc1 pass
[ "$mrc" != 0 ] && [ $rc1_ok = 1 ] && ok "P01-AC-2: it fails when rc1's ISO also verifies against this repository" || fail "P01-AC-2: it must fail when --repo tuckermclean/themonolith verifies"
run_rc1 fail
[ "$mrc" != 0 ] && [ $rc1_ok = 1 ] && ok "P01-AC-2: it fails when rc1's ISO does not verify against the predecessor" || fail "P01-AC-2: it must fail when the predecessor repo does not verify"
run_rc1 rc1 0000000000000000000000000000000000000000000000000000000000000000
[ "$mrc" != 0 ] && [ $rc1_ok = 1 ] && ok "P01-AC-2: it fails when the ISO is not the one with sha256 RC1_SHA256" || fail "P01-AC-2: it must fail on an ISO whose sha256 is not RC1_SHA256"

[ "$fails" -eq 0 ] || { echo "release-reports: $fails failure(s)"; exit 1; }
echo "all passed"
