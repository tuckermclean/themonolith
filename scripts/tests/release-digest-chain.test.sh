#!/bin/sh
# P01 slice 1: scripts/release-digest-chain.sh, the publish job's digest-chain check (node spec change 3).
#   P01-AC-3  exits 1, creating no release, when any of ISO hash, SHA256SUMS entry, SBOM component hash or
#             attestation subject digest differs.
#   P01-AC-6  the ISO's SHA-256 equals both digests in P02's compare log and the attestation subject: a fixture with
#             a third, differing digest fails. (The v0.2.0-rc1 run half is run, not encoded.)
#
# Interface under test (the implementer writes the script from this header alone):
#   sh scripts/release-digest-chain.sh <iso> <SHA256SUMS> <bom.cdx.json> <compare.log> <repo> <signer-workflow>
#     iso            the ISO to publish; its sha256 (sha256sum) is the reference digest
#     SHA256SUMS     "<sha256>  <name>" lines (sha256sum format); the entry whose name is basename(iso) must equal it
#     bom.cdx.json   CycloneDX; .metadata.component.hashes[0].content is the ISO's SHA-256
#     compare.log    P02's compare log (scripts/compare-isos.sh output): the first two lines are
#                    "<sha256>  <path>", one per build; both must equal it
#     repo, signer-workflow   passed to: gh attestation verify <iso> --repo <repo> --signer-workflow <w> --format json
#                    whose stdout is a JSON array; every .[].verificationResult.statement.subject[].digest.sha256
#                    must equal the ISO digest (and there must be at least one). gh failing (non-zero) fails the check.
#     gh is taken from PATH. The script only checks: it never calls `gh release` or any other gh subcommand.
#   exit 0 when all five digests are equal (one OK line); exit 1 when any differs or gh verify fails, naming which
#   one on stdout/stderr; exit 2 on a usage error or an unreadable input.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
S="$ROOT/scripts/release-digest-chain.sh"
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is not available in this harness"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'G'
#!/bin/sh
echo "$*" >> "$GH_LOG"
case "$1 $2" in
"attestation verify") [ -f "$GH_FAIL" ] && { echo "verification failed" >&2; exit 1; }; cat "$GH_JSON" ;;
*) exit 0 ;;
esac
G
chmod +x "$TMP/bin/gh"
GH_LOG="$TMP/gh.log"; GH_JSON="$TMP/gh.json"; GH_FAIL="$TMP/gh.fail"
export GH_LOG GH_JSON GH_FAIL

printf 'a release candidate\n' > "$TMP/monolith.iso"
GOOD=$(sha256sum "$TMP/monolith.iso" | cut -d' ' -f1)
BAD=$(printf 'other' | sha256sum | cut -d' ' -f1)
WS=tuckermclean/themonolith/.github/workflows/build.yml

# fixture builders; each takes the digest to write in that place
mk_sums() { printf '%s  other.json\n%s  monolith.iso\n' "$BAD" "$1" > "$TMP/SHA256SUMS"; }
mk_sbom() { printf '{"bomFormat":"CycloneDX","metadata":{"component":{"name":"monolith.iso","hashes":[{"alg":"SHA-256","content":"%s"}]}},"components":[]}\n' "$1" > "$TMP/bom.cdx.json"; }
mk_log()  { printf '%s  a/monolith.iso\n%s  b/monolith.iso\ncompare-isos: the ISOs are identical\n' "$1" "$2" > "$TMP/compare.log"; }
mk_att()  { printf '[{"verificationResult":{"statement":{"subject":[{"name":"monolith.iso","digest":{"sha256":"%s"}}]}}}]\n' "$1" > "$GH_JSON"; }
mk_all()  { mk_sums "${1:-$GOOD}"; mk_sbom "${2:-$GOOD}"; mk_log "${3:-$GOOD}" "${4:-$GOOD}"; mk_att "${5:-$GOOD}"; rm -f "$GH_FAIL"; }
run() {
	: > "$GH_LOG"
	out=$(PATH="$TMP/bin:$PATH" sh "$S" "$TMP/monolith.iso" "$TMP/SHA256SUMS" "$TMP/bom.cdx.json" "$TMP/compare.log" tuckermclean/themonolith "$WS" 2>&1)
	rc=$?
}
no_release() { ! grep -q '^release' "$GH_LOG"; }

mk_all; run
if [ "$rc" = 0 ] && grep -q '^attestation verify' "$GH_LOG"; then ok "P01-AC-3: a consistent fixture exits 0 and runs gh attestation verify"
else fail "P01-AC-3: consistent fixture must exit 0 via gh attestation verify (rc=$rc)"; fi
if grep -q -- '--repo tuckermclean/themonolith' "$GH_LOG" && grep -q -- "--signer-workflow $WS" "$GH_LOG" && grep -q -- '--format json' "$GH_LOG" \
	&& ! grep -q -- '--owner' "$GH_LOG"; then ok "P01-AC-3: gh is called with --repo, --signer-workflow, --format json and no --owner"
else fail "P01-AC-3: gh attestation verify must use --repo, --signer-workflow, --format json, never --owner"; fi

check_bad() { # <label> <criterion>
	if [ "$rc" = 1 ] && no_release; then ok "$2: $1 exits 1 and creates no release"
	else fail "$2: $1 must exit 1 and create no release (rc=$rc)"; fi
}
mk_all "$BAD"; run; check_bad "a SHA256SUMS entry that differs" P01-AC-3
mk_all "" "$BAD"; run; check_bad "an SBOM component hash that differs" P01-AC-3
mk_all "" "" "" "" "$BAD"; run; check_bad "an attestation subject digest that differs" P01-AC-3
# the ISO hash itself: change the ISO after the other three were written for it
mk_all; printf 'tampered\n' >> "$TMP/monolith.iso"; run; check_bad "an ISO hash that differs from the other four" P01-AC-3
printf 'a release candidate\n' > "$TMP/monolith.iso"

# P01-AC-6: the compare log's two digests
mk_all "" "" "$BAD" "$GOOD"; run; check_bad "a first compare-log digest that differs" P01-AC-6
mk_all "" "" "$GOOD" "$BAD"; run; check_bad "a second compare-log digest that differs" P01-AC-6
THIRD=$(printf 'third' | sha256sum | cut -d' ' -f1)
mk_all "" "" "$BAD" "$THIRD"; run; check_bad "a compare log with two other digests" P01-AC-6

# gh verify failing, an empty result and a SHA256SUMS without the ISO
mk_all; : > "$GH_FAIL"; run; check_bad "gh attestation verify failing" P01-AC-3
mk_all; echo '[]' > "$GH_JSON"; run; check_bad "an attestation with no subject" P01-AC-3
mk_all; printf '%s  other.json\n' "$BAD" > "$TMP/SHA256SUMS"; run; check_bad "a SHA256SUMS without the ISO entry" P01-AC-3
# two attestations, one for another digest
mk_all; printf '[{"verificationResult":{"statement":{"subject":[{"digest":{"sha256":"%s"}}]}}},{"verificationResult":{"statement":{"subject":[{"digest":{"sha256":"%s"}}]}}}]\n' "$GOOD" "$BAD" > "$GH_JSON"; run
check_bad "one of several attestation subjects differing" P01-AC-3

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
