#!/bin/sh
# X01-AC-1: every `gh attestation verify` in README.md has --repo and --signer-workflow, none uses
# --owner, and commands for both repositories are present. Change 3's extras: each command is
# preceded by `sha256sum -c SHA256SUMS`, and the README links the rc1 diff report (rc1-diff.md).
# The checker is proved on generated READMEs (scratch under an X01 folder) before it runs on the
# real one. Input: README [README.md]. Offline; needs no Git history.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
README="${README:-$ROOT/README.md}"
THIS=tuckermclean/themonolith
OLD=tuckermclean/linux-live-iso-factory
FAILS=0

ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

# rv_check FILE: prints one rule code per violation (NOCMD, NOREPO, NOSIGNER, OWNER, MISMATCH,
# MISSING_THIS, MISSING_RC1, NOSUM, NODIFF). Commands are lines holding `gh attestation verify`,
# joined with the following lines while a line ends in a backslash.
rv_check() {
    awk -v this="$THIS" -v old="$OLD" '
    function flush(   n, w, i, repo, sig, hasowner, hasrepo, hassig) {
        n = split(cmd, w, /[ \t]+/)
        repo = ""; sig = ""; hasowner = 0
        for (i = 1; i <= n; i++) {
            if (w[i] == "--owner" || w[i] ~ /^--owner=/) hasowner = 1
            if (w[i] == "--repo" && i < n) repo = w[i + 1]
            else if (w[i] ~ /^--repo=/) repo = substr(w[i], 8)
            if (w[i] == "--signer-workflow" && i < n) sig = w[i + 1]
            else if (w[i] ~ /^--signer-workflow=/) sig = substr(w[i], 19)
        }
        gsub(/[`"'"'"']/, "", repo); gsub(/[`"'"'"']/, "", sig)
        ncmd++
        if (hasowner) out["OWNER"] = 1
        if (repo == "") out["NOREPO"] = 1
        if (sig == "") out["NOSIGNER"] = 1
        if (repo != "" && sig != "" && sig != repo "/.github/workflows/build.yml") out["MISMATCH"] = 1
        if (repo == this && sig == this "/.github/workflows/build.yml") haveThis = 1
        if (repo == old && sig == old "/.github/workflows/build.yml") haveOld = 1
        if (!seensum) out["NOSUM"] = 1
        seensum = 0
    }
    {
        line = $0
        if (cmd != "") {
            cont = (line ~ /\\[ \t]*$/); sub(/\\[ \t]*$/, "", line)
            cmd = cmd " " line
            if (!cont) { flush(); cmd = "" }
            next
        }
        if (line ~ /sha256sum[ \t]+-c[ \t]+SHA256SUMS/) seensum = 1
        if (line ~ /gh[ \t]+attestation[ \t]+verify/) {
            cont = (line ~ /\\[ \t]*$/); sub(/\\[ \t]*$/, "", line)
            sub(/^.*gh[ \t]+attestation[ \t]+verify/, "gh attestation verify", line)
            cmd = line
            if (!cont) { flush(); cmd = "" }
        }
        if (line ~ /rc1-diff\.md/) diff = 1
    }
    END {
        if (cmd != "") flush()
        if (ncmd == 0) out["NOCMD"] = 1
        if (!haveThis) out["MISSING_THIS"] = 1
        if (!haveOld) out["MISSING_RC1"] = 1
        if (!diff) out["NODIFF"] = 1
        for (k in out) print k
    }' "$1" | sort
}

# expect_code FILE CODE LABEL: the checker must report CODE for FILE.
expect_code() {
    if rv_check "$1" | grep -qx "$2"; then ok "$3"; else bad "$3"; fi
}
expect_clean() {
    got=$(rv_check "$1" | tr '\n' ' ')
    if [ -z "$got" ]; then ok "$2"; else bad "$2 (violations: $got)"; fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
S="$TMP/X01"
mkdir -p "$S"

gen() { # gen FILE THIS_CMD OLD_CMD [SUM]  (commands may span lines)
    {
        echo "# Verify a release"
        echo "See [rc1-diff.md](https://example.invalid/rc1-diff.md)."
        echo '```sh'
        echo "sha256sum -c SHA256SUMS"
        printf '%s\n' "$2"
        echo '```'
        echo '```sh'
        [ "${4-yes}" = no ] || echo "sha256sum -c SHA256SUMS"
        printf '%s\n' "$3"
        echo '```'
    } >"$1"
}
GT="gh attestation verify themonolith-0.2.0.iso --repo $THIS --signer-workflow $THIS/.github/workflows/build.yml"
GO="gh attestation verify rc1.iso \\
  --repo $OLD \\
  --signer-workflow $OLD/.github/workflows/build.yml"

echo "== checker self-checks (X01-AC-1)"
gen "$S/good.md" "$GT" "$GO"
expect_clean "$S/good.md" "X01-AC-1 self-check: a README with both correct commands is accepted"

gen "$S/owner.md" "gh attestation verify a.iso --owner tuckermclean" "$GO"
expect_code "$S/owner.md" OWNER "X01-AC-1 self-check: --owner alone is rejected"
expect_code "$S/owner.md" NOREPO "X01-AC-1 self-check: a command without --repo is rejected"
expect_code "$S/owner.md" NOSIGNER "X01-AC-1 self-check: --owner alone lacks --signer-workflow, rejected"

gen "$S/owner2.md" "$GT --owner tuckermclean" "$GO"
expect_code "$S/owner2.md" OWNER "X01-AC-1 self-check: --owner next to --repo is rejected"

gen "$S/nosigner.md" "gh attestation verify a.iso --repo $THIS" "$GO"
expect_code "$S/nosigner.md" NOSIGNER "X01-AC-1 self-check: a missing --signer-workflow is rejected"

gen "$S/norepo.md" "gh attestation verify a.iso --signer-workflow $THIS/.github/workflows/build.yml" "$GO"
expect_code "$S/norepo.md" NOREPO "X01-AC-1 self-check: a missing --repo is rejected"

gen "$S/nosigner-cont.md" "$GT" "gh attestation verify rc1.iso \\
  --repo $OLD"
expect_code "$S/nosigner-cont.md" NOSIGNER "X01-AC-1 self-check: a continued command missing --signer-workflow is rejected"

gen "$S/no-this.md" "$GO" "$GO"
expect_code "$S/no-this.md" MISSING_THIS "X01-AC-1 self-check: a README without this repository's command is rejected"

gen "$S/no-old.md" "$GT" "$GT"
expect_code "$S/no-old.md" MISSING_RC1 "X01-AC-1 self-check: a README without the predecessor's command is rejected"

gen "$S/mismatch.md" "$GT" "gh attestation verify rc1.iso --repo $OLD --signer-workflow $THIS/.github/workflows/build.yml"
expect_code "$S/mismatch.md" MISSING_RC1 "X01-AC-1 self-check: a predecessor repo with another repository's workflow is rejected"
expect_code "$S/mismatch.md" MISMATCH "X01-AC-1 self-check: --repo and --signer-workflow naming different repositories are rejected"

printf '# Verify a release\nSee rc1-diff.md\n' >"$S/none.md"
expect_code "$S/none.md" NOCMD "X01-AC-1 self-check: a README with no attestation command is rejected"

gen "$S/nosum.md" "$GT" "$GO" no
expect_code "$S/nosum.md" NOSUM "X01-AC-1 self-check: a block not preceded by sha256sum -c SHA256SUMS is rejected"

gen "$S/nodiff.md" "$GT" "$GO"
grep -v 'rc1-diff' "$S/nodiff.md" >"$S/nodiff2.md"
expect_code "$S/nodiff2.md" NODIFF "X01-AC-1 self-check: a README without a link to rc1-diff.md is rejected"

echo "== README.md (X01-AC-1)"
if [ ! -f "$README" ]; then
    bad "X01-AC-1: README not found at $README"
else
    got=$(rv_check "$README")
    has() { printf '%s\n' "$got" | grep -qx "$1"; }
    has NOCMD && bad "X01-AC-1: README has no gh attestation verify command" || ok "X01-AC-1: README has gh attestation verify commands"
    has NOREPO && bad "X01-AC-1: a gh attestation verify command lacks --repo" || ok "X01-AC-1: every command has --repo"
    has NOSIGNER && bad "X01-AC-1: a gh attestation verify command lacks --signer-workflow" || ok "X01-AC-1: every command has --signer-workflow"
    has OWNER && bad "X01-AC-1: a gh attestation verify command uses --owner" || ok "X01-AC-1: no command uses --owner"
    has MISMATCH && bad "X01-AC-1: a command's --signer-workflow names a different repository than its --repo" || ok "X01-AC-1: --repo and --signer-workflow agree in every command"
    has MISSING_THIS && bad "X01-AC-1: no command with --repo $THIS and --signer-workflow $THIS/.github/workflows/build.yml" || ok "X01-AC-1: command for $THIS present"
    has MISSING_RC1 && bad "X01-AC-1: no command with --repo $OLD and --signer-workflow $OLD/.github/workflows/build.yml" || ok "X01-AC-1: command for $OLD present"
    has NOSUM && bad "X01-AC-1 (change 3): a command is not preceded by sha256sum -c SHA256SUMS" || ok "X01-AC-1 (change 3): each block is preceded by sha256sum -c SHA256SUMS"
    has NODIFF && bad "X01-AC-1 (change 3): README does not link rc1-diff.md" || ok "X01-AC-1 (change 3): README links rc1-diff.md"
fi

if [ "$FAILS" -ne 0 ]; then
    echo "readme-verify: $FAILS check(s) failed"
    exit 1
fi
echo "readme-verify: all checks passed"
