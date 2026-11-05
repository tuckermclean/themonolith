#!/bin/sh
# Tests for toolbox/run's image selection (pull, build, push) against a fake container engine.
#   sh toolbox/run.test.sh            (on the host, or inside the toolbox)
set -u
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); sed 's/^/  | /' "$tmp/log"; }

# The fake engine logs each call. FAKE_HAVE=1: the local image exists. FAKE_PULL=1: the pull works.
cat >"$tmp/engine" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case $1 in
image) [ "${FAKE_HAVE:-0}" = 1 ] ;;
pull) [ "${FAKE_PULL:-0}" = 1 ] ;;
login) cat >/dev/null ;;
esac
EOF
chmod +x "$tmp/engine"
inputs=$(cd toolbox && cat Containerfile selfcheck | sha256sum | cut -c1-12)
reg=$(sed -n 's/^REGISTRY[[:space:]]*?=[[:space:]]*//p' Makefile | head -n 1)

go() {
	: >"$tmp/log"
	env -u REGISTRY -u TOOLBOX -u GITHUB_ACTIONS -u GITHUB_TOKEN -u MONOLITH_TOOLBOX_PULL \
		MONOLITH_ENGINE="$tmp/engine" FAKE_LOG="$tmp/log" XDG_RUNTIME_DIR="$tmp" "$@" >/dev/null 2>&1
}
has() { grep -qE "$1" "$tmp/log"; }

go FAKE_PULL=1 toolbox/run -- true
if has "^pull -q $reg/toolbox:$inputs\$" && has "^tag $reg/toolbox:$inputs localhost/monolith-toolbox:$inputs\$" \
	&& ! has '^build' && has "^run .* localhost/monolith-toolbox:$inputs true\$"; then
	pass "no local image: pulls \${REGISTRY}/toolbox:<inputs> from the Makefile's REGISTRY, tags it, runs"
else fail "pull path"; fi

go FAKE_PULL=0 toolbox/run -- true
if has '^pull' && has "^build -t localhost/monolith-toolbox:$inputs " && has '^run '; then
	pass "the pull fails: builds from the Containerfile"
else fail "pull fallback"; fi

go FAKE_PULL=1 MONOLITH_TOOLBOX_PULL=0 toolbox/run -- true
if ! has '^pull' && has '^build -t' && has '^run '; then pass "MONOLITH_TOOLBOX_PULL=0 builds without pulling"
else fail "MONOLITH_TOOLBOX_PULL=0"; fi

go FAKE_HAVE=1 FAKE_PULL=1 toolbox/run -- true
if ! has '^pull' && ! has '^build' && has '^run '; then pass "a local image with these inputs is used as it is"
else fail "local image"; fi

go FAKE_PULL=1 REGISTRY=example.test/other toolbox/run -- true
if has "^pull -q example.test/other/toolbox:$inputs\$"; then pass "REGISTRY in the environment overrides the Makefile"
else fail "REGISTRY override"; fi

go FAKE_HAVE=1 FAKE_PULL=1 toolbox/run --build -- true
if ! has '^pull' && has '^build -t' && has '^run '; then pass "--build builds even with a local image, and never pulls"
else fail "--build"; fi

go FAKE_PULL=1 GITHUB_ACTIONS=true GITHUB_TOKEN=t GITHUB_ACTOR=a toolbox/run --push
host=${reg%%/*}
if ! has '^pull' && has '^build -t' && has "^login $host -u a --password-stdin\$" \
	&& has "^tag localhost/monolith-toolbox:$inputs $reg/toolbox:$inputs\$" && has "^push $reg/toolbox:$inputs\$" && ! has '^run '; then
	pass "--push in CI: builds from source, logs in with GITHUB_TOKEN, pushes \${REGISTRY}/toolbox:<inputs>"
else fail "--push in CI"; fi

go FAKE_PULL=1 toolbox/run --push
if ! has '^login' && has "^push $reg/toolbox:$inputs\$"; then pass "--push outside CI uses the existing login"
else fail "--push outside CI"; fi

if [ $fails = 0 ]; then echo "toolbox/run.test.sh: all passed"; else echo "toolbox/run.test.sh: $fails failed"; exit 1; fi
