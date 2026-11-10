#!/bin/sh
# F02-AC-2 (script part): scripts/toolbox-check.sh against a fake registry.
#
# The fake registry is a loopback python3 HTTP server (it does not dictate curl flags). Knobs the script must honour:
#   BASE                          the base commit; unset or not a commit -> non-zero, output names BASE
#   REGISTRY                      <host[:port]>/<owner>/<repo> (the Makefile passes it); the test sets 127.0.0.1:<port>/owner/repo
#   TOOLBOX_REGISTRY_SCHEME       http or https (default https); the test sets http
# The script runs from the root of a temporary git repository holding copies of toolbox/Containerfile, toolbox/selfcheck and
# scripts/toolbox-check.sh (`sh scripts/toolbox-check.sh`, as the Makefile target runs it), so no history of the checkout is needed.
# Protocol the fake speaks (brief interface 2):
#   GET /token?scope=repository:<owner>/<repo>/toolbox:pull   -> {"token":"..."} (no Authorization header may come with it)
#   HEAD|GET /v2/<owner>/<repo>/toolbox/manifests/<inputs>     -> needs `Authorization: Bearer <that token>`; 200, 404, 500 or 401
# Cases: inputs differ -> exit 0, "as expected", registry not contacted; equal + present -> exit 0; equal + 404 -> non-zero naming
# <registry>/toolbox:<inputs> and "Toolbox Image"; equal + 500 / 401 / token endpoint 500 / connection refused -> non-zero naming the
# error; BASE unset or not a commit -> non-zero. No credential: GITHUB_TOKEN and a netrc in HOME never reach the fake.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
SRVPID=
cleanup() { [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES BASE REGISTRY TOOLBOX_REGISTRY_SCHEME
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
NO_PROXY=127.0.0.1,localhost; export NO_PROXY

git_() { git -c user.email=t@example.test -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# ---- the fake registry
cat >"$TMP/server.py" <<'EOS'
import sys, json, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
portfile, logfile, modefile, repo = sys.argv[1:5]
lock = threading.Lock()
def mode():
    try:
        return open(modefile).read().strip()
    except OSError:
        return "ok"
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a):
        pass
    def reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    def handle_any(self):
        auth = self.headers.get("Authorization", "")
        acc = self.headers.get("Accept", "")
        with lock:
            with open(logfile, "a") as f:
                f.write("%s\t%s\t%s\t%s\n" % (self.command, self.path, auth, acc))
        u = urllib.parse.urlsplit(self.path)
        m = mode()
        if u.path == "/token":
            q = urllib.parse.parse_qs(u.query)
            if m == "tokenerr":
                return self.reply(500, b'{"errors":[{"code":"UNAVAILABLE"}]}')
            if q.get("scope") != ["repository:%s/toolbox:pull" % repo]:
                return self.reply(400, b'{"errors":[{"code":"DENIED"}]}')
            return self.reply(200, json.dumps({"token": "TOK-ANON"}, separators=(",", ":")).encode())
        if u.path == "/v2/%s/toolbox/manifests/%s" % (repo, u.path.rsplit("/", 1)[-1]) and "/toolbox/manifests/" in u.path:
            if m == "e500":
                return self.reply(500, b"internal server error", "text/plain")
            if m == "e401":
                return self.reply(401, b'{"errors":[{"code":"UNAUTHORIZED"}]}')
            if auth != "Bearer TOK-ANON":
                return self.reply(401, b'{"errors":[{"code":"UNAUTHORIZED"}]}')
            if m == "absent":
                return self.reply(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN"}]}')
            return self.reply(200, b'{"schemaVersion":2}', "application/vnd.oci.image.manifest.v1+json")
        return self.reply(404, b"{}")
    do_GET = do_HEAD = handle_any
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOS
: >"$TMP/log"; echo ok >"$TMP/mode"
if command -v python3 >/dev/null 2>&1; then
	python3 -I "$TMP/server.py" "$TMP/port" "$TMP/log" "$TMP/mode" owner/repo >"$TMP/server.out" 2>&1 &
	SRVPID=$!
	i=0; while [ ! -s "$TMP/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
fi
PORT=$(cat "$TMP/port" 2>/dev/null || true)
if [ -n "$PORT" ]; then ok "fake registry listening on 127.0.0.1:$PORT"; else fail "fake registry did not start: $(cat "$TMP/server.out" 2>/dev/null)"; PORT=1; fi
DEAD=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 1)

# ---- the temporary repository: c1 (older Containerfile), c2 (the real inputs), c3 (an unrelated file)
W=$TMP/work
mkdir -p "$W/toolbox" "$W/scripts" "$TMP/home"
cp "$ROOT/toolbox/Containerfile" "$ROOT/toolbox/selfcheck" "$W/toolbox/"
[ -f "$ROOT/scripts/toolbox-check.sh" ] && cp "$ROOT/scripts/toolbox-check.sh" "$W/scripts/"
(
	cd "$W" || exit 1
	git_ init -q . >/dev/null
	cp toolbox/Containerfile "$TMP/real"
	{ cat "$TMP/real"; echo '# older'; } >toolbox/Containerfile
	git_ add -A && git_ commit -q -m c1
	cp "$TMP/real" toolbox/Containerfile
	git_ add -A && git_ commit -q -m c2
	echo x >unrelated
	git_ add -A && git_ commit -q -m c3
) || { echo "FAIL: temporary repository"; exit 1; }
C1=$(git -C "$W" rev-parse HEAD~2)
C2=$(git -C "$W" rev-parse HEAD~1)
inputs=$(cd "$W/toolbox" && cat Containerfile selfcheck | sha256sum | cut -c1-12)
REG=127.0.0.1:$PORT/owner/repo
SECRET=ghs_secret_token_for_the_test
printf 'machine 127.0.0.1 login netrcuser password netrcsecret\n' >"$TMP/home/.netrc"
chmod 600 "$TMP/home/.netrc"

SCRIPT=$W/scripts/toolbox-check.sh
if [ -f "$SCRIPT" ]; then ok "scripts/toolbox-check.sh exists"; else fail "scripts/toolbox-check.sh exists"; fi

# run_check <mode> <registry> <BASE or -> : sets rc and $TMP/out; clears the request log
run_check() {
	echo "$1" >"$TMP/mode"; : >"$TMP/log"
	if [ "$3" = - ]; then b="env -u BASE"; else b="env BASE=$3"; fi
	(
		cd "$W" || exit 99
		# shellcheck disable=SC2086 # $b is a word list
		HOME="$TMP/home" GITHUB_TOKEN=$SECRET GITHUB_ACTOR=someone REGISTRY=$2 TOOLBOX_REGISTRY_SCHEME=http \
			timeout 60 $b sh scripts/toolbox-check.sh
	) >"$TMP/out" 2>&1
	rc=$?
}
script_ran() { [ -f "$SCRIPT" ] && ! grep -q "can't open\|No such file\|not found" "$TMP/out"; }
requests() { wc -l <"$TMP/log" | tr -d ' '; }

# AC-2: inputs differ from BASE -> pass, say so, do not ask the registry
run_check ok "$REG" "$C1"
[ $rc -eq 0 ] && script_ran && ok "F02-AC-2: inputs differ from BASE: exit 0" || fail "F02-AC-2: inputs differ from BASE: exit 0 (rc=$rc)"
grep -q "as expected" "$TMP/out" && ok "F02-AC-2: inputs differ: output says the build is expected" || fail "F02-AC-2: inputs differ: output says 'as expected': $(cat "$TMP/out")"
[ "$(requests)" = 0 ] && script_ran && ok "F02-AC-2: inputs differ: the registry is not contacted" || fail "F02-AC-2: inputs differ: the registry is not contacted ($(requests) requests)"

# AC-2: equal and the registry has the tag
run_check ok "$REG" "$C2"
[ $rc -eq 0 ] && script_ran && ok "F02-AC-2: equal, tag present: exit 0" || fail "F02-AC-2: equal, tag present: exit 0 (rc=$rc): $(cat "$TMP/out")"
! script_ran || grep -q "as expected" "$TMP/out" && fail "F02-AC-2: equal, tag present: does not claim the build is expected" || ok "F02-AC-2: equal, tag present: does not claim the build is expected"
tokreq=$(grep -c "^GET	/token" "$TMP/log")
manreq=$(grep -c "/toolbox/manifests/$inputs	" "$TMP/log")
[ "$tokreq" -ge 1 ] && [ "$manreq" -ge 1 ] && ok "F02-AC-2: asks for an anonymous token, then for /v2/.../toolbox/manifests/<inputs>" || fail "F02-AC-2: token ($tokreq) and manifest ($manreq) requests made"
# no credential
if grep -q "$SECRET\|netrcsecret\|netrcuser\|Basic " "$TMP/log"; then fail "F02-AC-2: no GITHUB_TOKEN, basic auth or netrc credential reaches the registry"; else [ "$manreq" -ge 1 ] && ok "F02-AC-2: no GITHUB_TOKEN, basic auth or netrc credential reaches the registry" || fail "F02-AC-2: no credential check (no requests seen)"; fi
if [ "$tokreq" -ge 1 ] && awk -F'\t' '$2 ~ /^\/token/ && $3 != "" {bad=1} END{exit bad}' "$TMP/log"; then ok "F02-AC-2: the token request carries no Authorization header"; else fail "F02-AC-2: the token request carries no Authorization header"; fi
if [ "$manreq" -ge 1 ] && awk -F'\t' '$2 ~ /manifests/ && $3 != "Bearer TOK-ANON" {bad=1} END{exit bad}' "$TMP/log"; then ok "F02-AC-2: the manifest request carries only the bearer token the token endpoint issued"; else fail "F02-AC-2: the manifest request carries only the issued bearer token"; fi
if [ "$manreq" -ge 1 ] && awk -F'\t' '$2 ~ /manifests/ && $4 !~ /manifest/ {bad=1} END{exit bad}' "$TMP/log"; then ok "F02-AC-2: the manifest request has an OCI/Docker manifest Accept header"; else fail "F02-AC-2: the manifest request has an OCI/Docker manifest Accept header"; fi

# AC-2: equal and the registry says the tag does not exist
run_check absent "$REG" "$C2"
[ $rc -ne 0 ] && script_ran && ok "F02-AC-2: equal, tag absent (404): non-zero" || fail "F02-AC-2: equal, tag absent (404): non-zero (rc=$rc)"
grep -qF "$REG/toolbox:$inputs" "$TMP/out" && ok "F02-AC-2: 404 output names <registry>/toolbox:<inputs>" || fail "F02-AC-2: 404 output names $REG/toolbox:$inputs: $(cat "$TMP/out")"
grep -q "Toolbox Image" "$TMP/out" && ok "F02-AC-2: 404 output names the Toolbox Image workflow" || fail "F02-AC-2: 404 output names the Toolbox Image workflow"

# AC-2: equal and the registry answers neither
for m in e500 e401 tokenerr; do
	case $m in e500) want=500 ;; e401) want=401 ;; tokenerr) want=500 ;; esac
	run_check $m "$REG" "$C2"
	[ $rc -ne 0 ] && script_ran && ok "F02-AC-2: registry error ($m): non-zero, not treated as present" || fail "F02-AC-2: registry error ($m): non-zero (rc=$rc)"
	grep -q "$want" "$TMP/out" && ok "F02-AC-2: registry error ($m): output names the answer ($want)" || fail "F02-AC-2: registry error ($m): output names $want: $(cat "$TMP/out")"
	! script_ran || grep -q "as expected" "$TMP/out" && fail "F02-AC-2: registry error ($m): does not claim the build is expected" || ok "F02-AC-2: registry error ($m): does not claim the build is expected"
done
run_check ok "127.0.0.1:$DEAD/owner/repo" "$C2"
[ $rc -ne 0 ] && script_ran && ok "F02-AC-2: connection refused: non-zero, not treated as present" || fail "F02-AC-2: connection refused: non-zero (rc=$rc)"
grep -qi "refused\|curl\|connect\|unreachable\|error\|fail" "$TMP/out" && ok "F02-AC-2: connection refused: output names the error" || fail "F02-AC-2: connection refused: output names the error: $(cat "$TMP/out")"

# AC-2: BASE unset or not a commit
run_check ok "$REG" -
[ $rc -ne 0 ] && script_ran && ok "F02-AC-2: BASE unset: non-zero" || fail "F02-AC-2: BASE unset: non-zero (rc=$rc)"
grep -q "BASE" "$TMP/out" && ok "F02-AC-2: BASE unset: output names BASE" || fail "F02-AC-2: BASE unset: output names BASE"
[ "$(requests)" = 0 ] && script_ran && ok "F02-AC-2: BASE unset: the registry is not contacted" || fail "F02-AC-2: BASE unset: the registry is not contacted"
run_check ok "$REG" 0123456789abcdef0123456789abcdef01234567
[ $rc -ne 0 ] && script_ran && ok "F02-AC-2: BASE not a commit: non-zero" || fail "F02-AC-2: BASE not a commit: non-zero (rc=$rc)"
grep -q "BASE\|0123456789abcdef" "$TMP/out" && ok "F02-AC-2: BASE not a commit: output names it" || fail "F02-AC-2: BASE not a commit: output names it"
[ "$(requests)" = 0 ] && script_ran && ok "F02-AC-2: BASE not a commit: the registry is not contacted" || fail "F02-AC-2: BASE not a commit: the registry is not contacted"

# AC-2: make toolbox-check runs the script with BASE (real checkout, dry run)
mk=$(cd "$ROOT" && env -u BASE make -n toolbox-check BASE=abc123 2>&1); mrc=$?
if [ $mrc -eq 0 ] && printf '%s\n' "$mk" | grep -q "scripts/toolbox-check.sh" && printf '%s\n' "$mk" | grep -q "abc123"; then
	ok "F02-AC-2: make toolbox-check runs scripts/toolbox-check.sh with BASE"
else
	fail "F02-AC-2: make toolbox-check runs scripts/toolbox-check.sh with BASE (rc=$mrc): $mk"
fi

echo "toolbox-check.test.sh: $fails failure(s)"
[ "$fails" -eq 0 ]
