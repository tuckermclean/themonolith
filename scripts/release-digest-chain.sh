#!/bin/sh
# The publish job's digest chain: ISO, SHA256SUMS entry, SBOM component hash, both compare-log digests and the
# attestation subject digests must all be equal. Only checks; creates no release.
# Usage: release-digest-chain.sh <iso> <SHA256SUMS> <bom.cdx.json> <compare.log> <repo> <signer-workflow>
set -u
[ $# -eq 6 ] || { echo "usage: $0 <iso> <SHA256SUMS> <bom.cdx.json> <compare.log> <repo> <signer-workflow>" >&2; exit 2; }
iso=$1 sums=$2 bom=$3 log=$4 repo=$5 wf=$6
for f in "$iso" "$sums" "$bom" "$log"; do [ -r "$f" ] || { echo "release-digest-chain: cannot read $f" >&2; exit 2; }; done
want=$(sha256sum "$iso" | cut -d' ' -f1) || exit 2
rc=0
bad() { echo "release-digest-chain: $1 differs from the ISO digest $want" >&2; rc=1; }
name=$(basename "$iso")
got=$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f); if (f == n) {print $1; exit}}' "$sums")
[ "$got" = "$want" ] || bad "SHA256SUMS entry for $name (${got:-absent})"
got=$(jq -r '.metadata.component.hashes[0].content // empty' "$bom") || exit 2
[ "$got" = "$want" ] || bad "SBOM component hash (${got:-absent})"
digs=$(grep -E '^[0-9a-f]{64}  ' "$log" | cut -d' ' -f1)
if [ -z "$digs" ] || [ "$(printf '%s\n' "$digs" | wc -l | tr -d ' ')" -ne 2 ]; then
	echo "release-digest-chain: compare log $log does not hold exactly two digest lines" >&2; rc=1
else
	for got in $digs; do [ "$got" = "$want" ] || bad "compare log digest ($got)"; done
fi
json=$(gh attestation verify "$iso" --repo "$repo" --signer-workflow "$wf" --format json) \
	|| { echo "release-digest-chain: gh attestation verify failed" >&2; exit 1; }
subs=$(printf '%s\n' "$json" | jq -r '.[].verificationResult.statement.subject[].digest.sha256') || { echo "release-digest-chain: unreadable attestation JSON" >&2; exit 1; }
if [ -z "$subs" ]; then echo "release-digest-chain: attestation has no subject" >&2; rc=1
else
	for s in $subs; do [ "$s" = "$want" ] || bad "attestation subject digest ($s)"; done
fi
[ "$rc" = 0 ] && echo "release-digest-chain: OK, all digests equal $want"
exit $rc
