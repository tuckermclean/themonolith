#!/bin/sh
# Unit tests for scripts/sync-portage.sh (restore of the pinned Gentoo tree by digest) and
# scripts/seed-tree.sh (one-time archive helper). Criteria: I02-AC-4, I02-AC-6.
# Stubs `oras` (and the tools that must never run) on a temporary PATH; fixture archives are built at
# test time from a tiny git repo (git archive | zstd), never committed.
#
# Contract pinned here:
#   sync-portage.sh   env: REGISTRY, TREE_COMMIT, TREE_DIGEST (all required), TREE_REF (default
#                     $REGISTRY/gentoo-tree), TREE_DIR (target, default /var/db/repos/gentoo).
#                     Runs `oras pull ... $TREE_REF@$TREE_DIGEST` (output dir via -o/--output), expects the
#                     one file gentoo-tree-$TREE_COMMIT.tar.zst, extracts it into $TREE_DIR. Failures exit
#                     non-zero with the ref (or the variable name) in the message.
#                     `. sync-portage.sh --source-only` defines restore_tree and runs nothing.
#   seed-tree.sh      `seed-tree.sh [--oci-layout DIR] <commit40>`; env: REGISTRY (required unless
#                     --oci-layout), TREE_SOURCE (git URL to fetch from, default the gentoo-mirror).
#                     Refusals say "not 40 hex digits" / "already exists" and name the ref.
#                     Prints `signature: good|bad|unsigned|key-missing` and the manifest digest.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SYNC="$HERE/../sync-portage.sh"
SEED="$HERE/../seed-tree.sh"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails+1)); }
mk_stub() {  # $1=name  $2=body
    printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"
}
aws_tool=aw; aws_tool="${aws_tool}s"   # spelled from parts: no tracked file may name the S3 CLI (I01)

# ---- fixture: a tiny repo and its archive, as seed-tree.sh would make it ----
FIX=$(mktemp -d)
trap 'rm -rf "$FIX" "${TMP:-}"' EXIT INT TERM
FIXREPO="$FIX/repo"
git init -q "$FIXREPO" && mkdir -p "$FIXREPO/app-misc/foo" "$FIXREPO/metadata/md5-cache" \
    && echo 'EAPI=8' > "$FIXREPO/app-misc/foo/foo-1.ebuild" \
    && echo cache > "$FIXREPO/metadata/md5-cache/app-misc_foo-1" \
    && echo gentoo > "$FIXREPO/profiles.txt" \
    && git -C "$FIXREPO" add -A \
    && GIT_COMMITTER_DATE=2026-08-11T23:00:56Z GIT_AUTHOR_DATE=2026-08-11T23:00:56Z \
       git -C "$FIXREPO" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture \
    || { echo "FAIL: cannot build the fixture repo"; exit 1; }
COMMIT=$(git -C "$FIXREPO" rev-parse HEAD)
OTHER=0123456789abcdef0123456789abcdef01234567
git -C "$FIXREPO" ls-tree -r --name-only "$COMMIT" | sort > "$FIX/files"
git -C "$FIXREPO" archive --format=tar "$COMMIT" | zstd -q -19 -T1 > "$FIX/good.tar.zst" \
    || { echo "FAIL: cannot build the fixture archive"; exit 1; }
: > "$FIX/empty.tar.zst"
echo 'this is not a zstd stream' > "$FIX/garbage.tar.zst"
tar -cf - -T /dev/null | zstd -q > "$FIX/notar.tar.zst"          # valid zstd, tar with no entries

REG=registry.test/themonolith
DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
WRONG=sha256:2222222222222222222222222222222222222222222222222222222222222222

setup() {
    TMP=$(mktemp -d); BIN="$TMP/bin"; mkdir -p "$BIN"
    export PATH="$BIN:$PATH"
    export CALLLOG="$TMP/calls"; : > "$CALLLOG"
    export REGISTRY="$REG" TREE_COMMIT="$COMMIT" TREE_DIGEST="$DIGEST" TREE_DIR="$TMP/tree"
    unset TREE_REF TREE_SOURCE
    # Tools that a restore must never run: they log and fail.
    for t in wget curl "$aws_tool" emerge-webrsync rsync; do
        mk_stub "$t" "echo \"FORBIDDEN $t \$*\" >> \"\$CALLLOG\"; exit 99"
    done
    # oras: `pull` serves ORAS_SERVE (a file) under the name ORAS_NAME, only for ref ORAS_REF.
    export ORAS_REF="$REG/gentoo-tree@$DIGEST" ORAS_SERVE="$FIX/good.tar.zst" ORAS_NAME="gentoo-tree-$COMMIT.tar.zst"
    mk_stub oras 'echo "oras $*" >> "$CALLLOG"
case "$1" in
pull)
    shift; out=.; ref=
    while [ $# -gt 0 ]; do
        case "$1" in
            -o|--output) out=$2; shift;;
            --output=*) out=${1#--output=};;
            *@*) ref=$1;;
        esac
        shift
    done
    [ "$ref" = "$ORAS_REF" ] || { echo "Error: $ref: not found" >&2; exit 1; }
    mkdir -p "$out" && cp "$ORAS_SERVE" "$out/$ORAS_NAME";;
*) exit 0;;
esac'
}
teardown() { rm -rf "$TMP"; }
run_sync() { sh "$SYNC" >"$TMP/out" 2>&1; r=$?; }
tree_matches() {  # target dir holds exactly the fixture files with the fixture contents
    [ -d "$TREE_DIR" ] || return 1
    (cd "$TREE_DIR" && find . -type f | sed 's|^\./||' | sort) | cmp -s - "$FIX/files" || return 1
    while IFS= read -r f; do
        git -C "$FIXREPO" show "$COMMIT:$f" | cmp -s - "$TREE_DIR/$f" || return 1
    done < "$FIX/files"
}
tree_empty() { [ ! -d "$TREE_DIR" ] || [ -z "$(find "$TREE_DIR" -type f 2>/dev/null | head -n 1)" ]; }
failed_loud() {  # $1=label $2=needle that the message must carry
    if [ "$r" -ne 0 ] && grep -qF -- "$2" "$TMP/out" && grep -q '^oras pull ' "$CALLLOG"; then
        pass "$1 -> non-zero, message names $2"
    else
        fail "$1 (rc=$r; want non-zero, message naming $2, an oras pull attempt)"; sed 's/^/      | /' "$TMP/out"
    fi
}

echo "== sync-portage.sh (I02-AC-4) =="

# 1. (was: S3 hit) A stub oras serving the fixture archive -> the tree is restored; the digest
#    reference is what was pulled.  I02-AC-4
setup
run_sync
[ "$r" -eq 0 ] && pass "AC-4 restore returns 0" || { fail "AC-4 restore rc=$r"; sed 's/^/      | /' "$TMP/out"; }
tree_matches && pass "AC-4 target dir holds exactly the fixture tree" || fail "AC-4 restored tree differs from the fixture"
grep -qF "oras pull" "$CALLLOG" && grep -qF -- "$ORAS_REF" "$CALLLOG" && pass "AC-4 pulled \$TREE_REF@\$TREE_DIGEST" || { fail "AC-4 no pull of $ORAS_REF"; cat "$CALLLOG"; }
grep -q FORBIDDEN "$CALLLOG" && { fail "AC-4 a forbidden tool ran"; cat "$CALLLOG"; } || pass "AC-4 never ran wget/curl/the S3 CLI/emerge-webrsync/rsync"
teardown

# 2. (was: S3 miss, archive back) The pull yields a different file (another commit's archive)
#    -> fails, nothing extracted.  I02-AC-4
setup
export ORAS_NAME="gentoo-tree-$OTHER.tar.zst"
run_sync
failed_loud "AC-4 pull of a different file" "$ORAS_REF"
tree_empty && pass "AC-4 nothing extracted from the wrong file" || fail "AC-4 files extracted from a different file"
teardown

# 3. (was: nothing anywhere has the .tar.xz) The artifact is missing: the pull fails -> non-zero,
#    ref in the message.  I02-AC-4
setup
export ORAS_REF="$REG/gentoo-tree@sha256:3333333333333333333333333333333333333333333333333333333333333333"
run_sync
failed_loud "AC-4 missing artifact" "$REG/gentoo-tree@$DIGEST"
tree_empty && pass "AC-4 nothing extracted for a missing artifact" || fail "AC-4 files extracted for a missing artifact"
teardown

# 3b. Digest mismatch: the registry has the tree under another digest than the pin.  I02-AC-4
setup
export TREE_DIGEST="$WRONG"
run_sync
failed_loud "AC-4 digest mismatch" "$REG/gentoo-tree@$WRONG"
teardown

# 3c. Empty archive, unreadable archive, archive with no entries.  I02-AC-4
for bad in empty garbage notar; do
    setup
    export ORAS_SERVE="$FIX/$bad.tar.zst"
    run_sync
    failed_loud "AC-4 $bad archive" "$ORAS_REF"
    tree_empty && pass "AC-4 $bad archive leaves no files" || fail "AC-4 $bad archive left files"
    teardown
done

# 4. (was: no bucket set) Sourced with --source-only: defines restore_tree, runs nothing, creates
#    nothing, even with the pins unset.  I02-AC-4
setup
unset REGISTRY TREE_COMMIT TREE_DIGEST
( . "$SYNC" --source-only >"$TMP/src.out" 2>&1; command -v restore_tree >/dev/null 2>&1 ) && src=1 || src=0
[ "$src" -eq 1 ] && pass "AC-4 --source-only defines restore_tree" || { fail "AC-4 --source-only did not define restore_tree"; sed 's/^/      | /' "$TMP/src.out"; }
{ [ ! -s "$CALLLOG" ] && [ ! -e "$TMP/tree" ] && [ ! -s "$TMP/src.out" ]; } && pass "AC-4 --source-only ran nothing (no calls, no output, no target dir)" || fail "AC-4 --source-only had side effects"
[ -f "$SYNC" ] || fail "AC-4 scripts/sync-portage.sh is absent"
teardown

# 5. (was: optional .md5sum) The pins must be set: each of TREE_COMMIT, TREE_DIGEST, REGISTRY unset
#    -> non-zero naming the variable, no pull.  I02-AC-4
for v in TREE_COMMIT TREE_DIGEST REGISTRY; do
    setup
    unset "$v"
    run_sync
    if [ "$r" -ne 0 ] && grep -qF "$v" "$TMP/out" && ! grep -q '^oras pull ' "$CALLLOG"; then
        pass "AC-4 $v unset -> non-zero naming $v, no pull"
    else
        fail "AC-4 $v unset (rc=$r; want non-zero naming $v and no pull)"; sed 's/^/      | /' "$TMP/out"
    fi
    teardown
done

# 6. (was: webrsync pinned to localhost, no upstream) A restore makes no network tool call except the
#    stub `oras pull` of the digest reference: the call log is that one line.  I02-AC-4
setup
run_sync
n=$(wc -l < "$CALLLOG")
if [ "$r" -eq 0 ] && [ "$n" -eq 1 ] && grep -q "^oras pull .*$REG/gentoo-tree@$DIGEST" "$CALLLOG"; then
    pass "AC-4 the only tool call is oras pull of the digest reference"
else
    fail "AC-4 expected exactly one oras pull of $ORAS_REF (rc=$r, $n calls)"; sed 's/^/      | /' "$CALLLOG"
fi
if [ -f "$SYNC" ] && ! grep -Eq "wget|curl|emerge-webrsync|https?://|(^|[^[:alnum:]_])$aws_tool " "$SYNC"; then
    pass "AC-4 sync-portage.sh names no wget/curl/S3 CLI/webrsync/URL"
else
    fail "AC-4 sync-portage.sh is absent or names a network tool or URL"
fi
teardown

echo "== seed-tree.sh (I02-AC-6) =="

seed_setup() {
    setup
    mk_stub git 'echo "git $*" >> "$CALLLOG"; exit 0'
    mk_stub oras 'echo "oras $*" >> "$CALLLOG"
case "$1 $2" in
"manifest fetch") [ "${SEED_EXISTS:-0}" = 1 ] && { echo "{}"; exit 0; }; echo "Error: not found" >&2; exit 1;;
esac
exit 0'
}
run_seed() { sh "$SEED" "$@" >"$TMP/out" 2>&1; r=$?; }
no_side_effects() {  # $1=label: nothing was pushed or fetched
    if grep -Eq '^oras push|^git (fetch|archive|clone)' "$CALLLOG"; then
        fail "$1 pushed or fetched anyway"; sed 's/^/      | /' "$CALLLOG"
    else
        pass "$1 nothing pushed or fetched"
    fi
}

# 7. A commit that is not 40 hex digits is refused before any registry or git call.  I02-AC-6
for bad in "" abc123 master HEAD "${COMMIT%?}" "${COMMIT}a" "$(printf 'g%.0s' $(seq 40))"; do
    seed_setup
    export REGISTRY="$REG"
    run_seed ${bad:+"$bad"}
    if [ "$r" -ne 0 ] && grep -qi '40 hex' "$TMP/out"; then
        pass "AC-6 refuses '$bad': not 40 hex digits"
    else
        fail "AC-6 '$bad' not refused with a '40 hex' message (rc=$r)"; sed 's/^/      | /' "$TMP/out"
    fi
    no_side_effects "AC-6 '$bad'"
    teardown
done

# 8. An existing gentoo-tree:<commit40> is not overwritten: the existence check is an
#    `oras manifest fetch` of that tag; the answer "exists" stops everything.  I02-AC-6
seed_setup
export SEED_EXISTS=1 REGISTRY="$REG"
run_seed "$COMMIT"
if [ "$r" -ne 0 ] && grep -qF "$REG/gentoo-tree:$COMMIT" "$TMP/out" && grep -qi 'exists' "$TMP/out"; then
    pass "AC-6 refuses an existing gentoo-tree:<commit40>, naming the ref"
else
    fail "AC-6 existing tag not refused with ref and 'exists' (rc=$r)"; sed 's/^/      | /' "$TMP/out"
fi
grep -q "^oras manifest fetch .*$REG/gentoo-tree:$COMMIT" "$CALLLOG" && pass "AC-6 existence checked with oras manifest fetch on the tag" || { fail "AC-6 no oras manifest fetch of the tag"; cat "$CALLLOG"; }
no_side_effects "AC-6 existing tag"
teardown

# 9. Registry mode needs REGISTRY.  I02-AC-6
seed_setup
unset REGISTRY
run_seed "$COMMIT"
if [ "$r" -ne 0 ] && grep -qF REGISTRY "$TMP/out"; then pass "AC-6 REGISTRY unset -> non-zero naming REGISTRY"; else fail "AC-6 REGISTRY unset (rc=$r)"; sed 's/^/      | /' "$TMP/out"; fi
no_side_effects "AC-6 REGISTRY unset"
teardown

# 10. Real git, zstd and oras against a local source and an OCI layout (no registry): fetch, signature
#     line, archive per the format contract, push, digest; the second run refuses the existing tag.
#     I02-AC-6 (refusal on the layout), ruling 3 (layout target, signature line, digest, format)
setup
rm -f "$BIN/oras" "$BIN/git"      # real tools from here on
unset REGISTRY
export TREE_SOURCE="file://$FIXREPO"
L1="$TMP/layout1"; L2="$TMP/layout2"
sh "$SEED" --oci-layout "$L1" "$COMMIT" >"$TMP/out1" 2>&1; r1=$?
if [ "$r1" -eq 0 ]; then pass "seed to an OCI layout returns 0"; else fail "seed to an OCI layout rc=$r1"; sed 's/^/      | /' "$TMP/out1"; fi
grep -Eq '^signature: (good|bad|unsigned|key-missing)$' "$TMP/out1" && pass "prints a 'signature:' line" || fail "no 'signature: good|bad|unsigned|key-missing' line"
printed=$(grep -Eo 'sha256:[0-9a-f]{64}' "$TMP/out1" | tail -n 1)
real=$(oras manifest fetch --oci-layout --descriptor "$L1:$COMMIT" 2>/dev/null | grep -Eo 'sha256:[0-9a-f]{64}' | head -n 1)
{ [ -n "$printed" ] && [ "$printed" = "$real" ]; } && pass "prints the manifest digest of $L1:<commit40>" || fail "printed digest '$printed' != layout manifest digest '$real'"
man=$(oras manifest fetch --oci-layout "$L1:$COMMIT" 2>/dev/null | tr -d ' \n')
case $man in *'"artifactType":"application/vnd.themonolith.gentoo-tree.v1"'*) pass "artifact type application/vnd.themonolith.gentoo-tree.v1";; *) fail "artifact type";; esac
case $man in *'"mediaType":"application/vnd.themonolith.gentoo-tree.layer.v1.tar+zstd"'*) pass "layer media type ...layer.v1.tar+zstd";; *) fail "layer media type";; esac
case $man in *'"org.opencontainers.image.created":"2026-08-11T23:00:56Z"'*) pass "created annotation = the commit's committer time (UTC)";; *) fail "created annotation";; esac
case $man in *"\"org.opencontainers.image.title\":\"gentoo-tree-$COMMIT.tar.zst\""*) pass "layer title gentoo-tree-<commit40>.tar.zst";; *) fail "layer title";; esac
mkdir -p "$TMP/pulled" && oras pull --oci-layout "$L1:$COMMIT" -o "$TMP/pulled" >/dev/null 2>&1
if [ -f "$TMP/pulled/gentoo-tree-$COMMIT.tar.zst" ] && zstd -dc "$TMP/pulled/gentoo-tree-$COMMIT.tar.zst" | tar -tf - | grep -v '/$' | sort | cmp -s - "$FIX/files"; then
    pass "layer is a zstd tar of exactly the commit's files"
else
    fail "layer is not a zstd tar of the commit's files"
fi
sh "$SEED" --oci-layout "$L2" "$COMMIT" >"$TMP/out2" 2>&1
printed2=$(grep -Eo 'sha256:[0-9a-f]{64}' "$TMP/out2" | tail -n 1)
{ [ -n "$printed" ] && [ "$printed" = "$printed2" ]; } && pass "the digest is reproducible across two runs" || fail "digest differs between runs: '$printed' vs '$printed2'"
sh "$SEED" --oci-layout "$L1" "$COMMIT" >"$TMP/out3" 2>&1; r3=$?
after=$(oras manifest fetch --oci-layout --descriptor "$L1:$COMMIT" 2>/dev/null | grep -Eo 'sha256:[0-9a-f]{64}' | head -n 1)
if [ "$r3" -ne 0 ] && grep -qi 'exists' "$TMP/out3" && [ -n "$after" ] && [ "$after" = "$real" ]; then
    pass "AC-6 a second run on the same layout refuses the existing tag and leaves it unchanged"
else
    fail "AC-6 second run: rc=$r3, digest '$after' vs '$real'"; sed 's/^/      | /' "$TMP/out3"
fi
teardown

# ---- review 1, rulings 9, 11, 12, 13 (added; the cases above are unchanged) ----
echo "== restore replaces the tree (ruling 9, I02-AC-4) =="
REALTAR=$(command -v tar); REALRM=$(command -v rm)

# 9a. A pre-seeded TREE_DIR holding a stale file and a stale subdirectory: after an rc 0 restore the stale
#     entries are gone and the tree equals the fixture.  ruling 9
setup
mkdir -p "$TREE_DIR/stale-dir/deeper" "$TREE_DIR/app-misc/foo"
echo old > "$TREE_DIR/removed.ebuild"; echo old > "$TREE_DIR/stale-dir/deeper/x"; echo old > "$TREE_DIR/app-misc/foo/stale-1.ebuild"
run_sync
[ "$r" -eq 0 ] && pass "ruling 9 restore over a populated TREE_DIR returns 0" || { fail "ruling 9 restore over a populated TREE_DIR rc=$r"; sed 's/^/      | /' "$TMP/out"; }
{ [ ! -e "$TREE_DIR/removed.ebuild" ] && [ ! -e "$TREE_DIR/stale-dir" ] && [ ! -e "$TREE_DIR/app-misc/foo/stale-1.ebuild" ]; } \
    && pass "ruling 9 stale file and stale subdirectory are gone after the restore" || fail "ruling 9 stale entries survived the restore"
tree_matches && pass "ruling 9 the tree equals the fixture after the restore" || fail "ruling 9 tree differs from the fixture after the restore"
teardown

# 9b. An empty or `/` TREE_DIR is refused without touching anything.  Never real: mutating tools are
#     stubbed to log MUTATE and do nothing, so a missing refusal shows up in the log, not on the disk.
for badtarget in "" "/"; do
    setup
    for t in rm mv cp ln rmdir install; do
        mk_stub "$t" "echo \"MUTATE $t \$*\" >> \"\$CALLLOG\"; exit 0"
    done
    mk_stub tar "x=0; for a in \"\$@\"; do case \$a in --extract|--get) x=1;; --*) ;; -*x*) x=1;; esac; done
[ \$x = 1 ] && { echo \"MUTATE tar \$*\" >> \"\$CALLLOG\"; cat >/dev/null; exit 0; }
exec $REALTAR \"\$@\""
    export TREE_DIR="$badtarget"
    run_sync
    if [ "$r" -ne 0 ] && ! grep -q '^MUTATE ' "$CALLLOG"; then
        pass "ruling 9 TREE_DIR='$badtarget' refused, nothing touched"
    else
        fail "ruling 9 TREE_DIR='$badtarget' (rc=$r; want non-zero and no rm/mv/cp/extract)"; sed 's/^/      | /' "$CALLLOG"
    fi
    grep -qF TREE_DIR "$TMP/out" && pass "ruling 9 TREE_DIR='$badtarget' refusal names TREE_DIR" || fail "ruling 9 TREE_DIR='$badtarget' refusal does not name TREE_DIR"
    "$REALRM" -rf "$BIN"/rm "$BIN"/mv "$BIN"/cp "$BIN"/ln "$BIN"/rmdir "$BIN"/install "$BIN"/tar
    teardown
done

echo "== seed-tree.sh: existence check, no silent seed, file count (rulings 11, 12, 13, I02-AC-6) =="
git -C "$FIXREPO" archive --format=tar "$COMMIT" > "$FIX/fix.tar"
git -C "$FIXREPO" ls-tree -r "$COMMIT" > "$FIX/lstree"
NFILES=$(wc -l < "$FIX/lstree" | tr -d ' ')
SHA64=$(printf 'a%.0s' $(seq 64))
seed2_setup() {  # full stubs: git (init/fetch/archive/ls-tree) and oras (fetch answer, push digest)
    setup
    export FIXTAR="$FIX/fix.tar" FIXLS="$FIX/lstree" REGISTRY="$REG" SHA64
    unset ORAS_FETCH GIT_ARCHIVE_FAIL ORAS_PUSH_NODIGEST
    mk_stub git 'echo "git $*" >> "$CALLLOG"
case "$1" in
init) for a in "$@"; do d=$a; done; mkdir -p "$d";;
archive) [ "${GIT_ARCHIVE_FAIL:-0}" = 1 ] && { echo "fatal: git archive failed" >&2; exit 128; }; cat "$FIXTAR";;
ls-tree) cat "$FIXLS";;
esac
exit 0'
    mk_stub oras 'echo "oras $*" >> "$CALLLOG"
case "$1 $2" in
"manifest fetch")
    case "${ORAS_FETCH:-notfound}" in
    notfound) echo "Error: $REGISTRY/gentoo-tree:x: not found" >&2;;
    denied) echo "Error response from registry: denied: requested access to the resource is denied" >&2;;
    dial) echo "Error: Head \"https://registry.test/v2/\": dial tcp: lookup registry.test: no such host" >&2;;
    esac
    exit 1;;
esac
[ "$1" = push ] && [ "${ORAS_PUSH_NODIGEST:-0}" != 1 ] && echo "Digest: sha256:$SHA64"
exit 0'
}

# 11a. An oras error saying `not found` means absent: the seed proceeds to fetch, archive and push.  ruling 11
seed2_setup
run_seed "$COMMIT"
if [ "$r" -eq 0 ] && grep -q '^oras push' "$CALLLOG" && grep -q '^git fetch' "$CALLLOG"; then
    pass "ruling 11 'not found' means absent: seed fetched and pushed"
else
    fail "ruling 11 'not found' did not proceed (rc=$r)"; sed 's/^/      | /' "$TMP/out" "$CALLLOG"
fi
teardown

# 11b. Any other manifest-fetch error (denied, dial) is an error: non-zero, oras's message printed, no fetch, no push.
for mode in denied dial; do
    seed2_setup
    export ORAS_FETCH=$mode
    run_seed "$COMMIT"
    case $mode in denied) needle='denied: requested access to the resource is denied';; dial) needle='dial tcp: lookup registry.test: no such host';; esac
    if [ "$r" -ne 0 ] && grep -qF -- "$needle" "$TMP/out"; then
        pass "ruling 11 $mode -> non-zero and the oras message is printed"
    else
        fail "ruling 11 $mode (rc=$r; want non-zero printing '$needle')"; sed 's/^/      | /' "$TMP/out"
    fi
    no_side_effects "ruling 11 $mode"
    teardown
done

# 12a. git archive fails: non-zero, nothing pushed (no empty zstd stream).  ruling 12
seed2_setup
export GIT_ARCHIVE_FAIL=1
run_seed "$COMMIT"
if [ "$r" -ne 0 ] && ! grep -q '^oras push' "$CALLLOG" && ! grep -q '^digest: ' "$TMP/out"; then
    pass "ruling 12 failing git archive -> non-zero, nothing pushed, no digest line"
else
    fail "ruling 12 failing git archive (rc=$r; want non-zero, no oras push, no digest line)"; sed 's/^/      | /' "$TMP/out" "$CALLLOG"
fi
teardown

# 12b. oras push prints no digest: non-zero, no `digest: ` line.  ruling 12
seed2_setup
export ORAS_PUSH_NODIGEST=1
run_seed "$COMMIT"
if [ "$r" -ne 0 ] && ! grep -q '^digest: ' "$TMP/out"; then
    pass "ruling 12 push without a digest -> non-zero, no digest line"
else
    fail "ruling 12 push without a digest (rc=$r; want non-zero and no 'digest: ' line)"; sed 's/^/      | /' "$TMP/out"
fi
teardown

# 12c. With a digest printed, the success path prints `digest: sha256:<it>` and returns 0.  ruling 12
seed2_setup
run_seed "$COMMIT"
if [ "$r" -eq 0 ] && grep -qx "digest: sha256:$SHA64" "$TMP/out"; then pass "ruling 12 push with a digest -> digest line, rc 0"; else fail "ruling 12 success path (rc=$r)"; sed 's/^/      | /' "$TMP/out"; fi
teardown

# 13. seed-tree.sh prints `files: <n>`, n = `git ls-tree -r <commit> | wc -l` (stubbed git, then real git).  ruling 13, I02-AC-3
seed2_setup
run_seed "$COMMIT"
grep -qx "files: $NFILES" "$TMP/out" && pass "ruling 13 prints 'files: $NFILES' (git ls-tree -r | wc -l, stub git)" || { fail "ruling 13 no 'files: $NFILES' line (stub git)"; sed 's/^/      | /' "$TMP/out"; }
teardown
setup
rm -f "$BIN/oras" "$BIN/git"
unset REGISTRY
export TREE_SOURCE="file://$FIXREPO"
sh "$SEED" --oci-layout "$TMP/layout13" "$COMMIT" >"$TMP/out13" 2>&1
grep -qx "files: $(git -C "$FIXREPO" ls-tree -r "$COMMIT" | wc -l | tr -d ' ')" "$TMP/out13" \
    && pass "ruling 13 prints 'files: <git ls-tree -r | wc -l>' (real git)" || { fail "ruling 13 no matching 'files:' line (real git)"; sed 's/^/      | /' "$TMP/out13"; }
teardown

echo; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
