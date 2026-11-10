#!/bin/sh
# F02-AC-5: the toolbox image retries a failed apt download with a bounded wait through its
# /usr/local/bin/apt-retry wrapper (interface 4), and its Containerfile runs `apt-get update` and
# `apt-get install` through that wrapper.
# Runs `toolbox/run --network none -- sh scripts/tests/toolbox-apt-retry.test.sh`, as the non-root toolbox user.
# The behavioural cases run `apt-retry apt-get update` (no retry settings of this test's own) against a
# [trusted=yes] repository served on loopback by python3: 503 to the first two requests of each path, or always.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CF=$ROOT/toolbox/Containerfile
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
SRV=
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$TMP"' EXIT

# --- static: the Containerfile (comment lines are ignored) ---
code=$(grep -v '^[[:space:]]*#' "$CF")
wr=$(printf '%s\n' "$code" | grep -n '/usr/local/bin/apt-retry' | grep -E '>|install|chmod|ln ' | head -n 1 | cut -d: -f1)
upd=$(printf '%s\n' "$code" | grep -n 'apt-get.*[[:space:]]update' | head -n 1 | cut -d: -f1)
if [ -n "$wr" ] && [ -n "$upd" ] && [ "$wr" -lt "$upd" ]; then
	ok "F02-AC-5: the Containerfile writes /usr/local/bin/apt-retry before its first apt-get update"
else fail "F02-AC-5: the Containerfile writes /usr/local/bin/apt-retry before its first apt-get update (write line=${wr:-none} update line=${upd:-none})"; fi
for verb in update install; do
	all=$(printf '%s\n' "$code" | grep -E "apt-get.*[[:space:]]$verb([[:space:]]|\$|;)")
	bad=$(printf '%s\n' "$all" | grep -v 'apt-retry.*apt-get')
	if [ -n "$all" ] && [ -z "$bad" ]; then
		ok "F02-AC-5: every apt-get $verb in the Containerfile runs through apt-retry"
	else fail "F02-AC-5: every apt-get $verb in the Containerfile runs through apt-retry (found: ${all:-none})"; fi
done

# --- the running image keeps the wrapper ---
if [ -x /usr/local/bin/apt-retry ]; then
	ok "F02-AC-5: the image has an executable /usr/local/bin/apt-retry"
else fail "F02-AC-5: the image has an executable /usr/local/bin/apt-retry"; fi

# --- behaviour: apt-get update against a server that fails on purpose ---
cat >"$TMP/srv.py" <<'EOS'
import hashlib, http.server, os, sys
root, mode, log, portf, arch = sys.argv[1:6]
seen = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = self.path
        seen[p] = seen.get(p, 0) + 1
        with open(log, "a") as f:
            f.write(p + "\n")
        if mode == "always" or seen[p] <= 2:
            self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers(); return
        fn = os.path.join(root, p.lstrip("/"))
        if not os.path.isfile(fn):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        d = open(fn, "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    do_HEAD = do_GET
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portf, "w").write(str(s.server_address[1]))
s.serve_forever()
EOS
arch=$(dpkg --print-architecture)
repo=$TMP/repo; mkdir -p "$repo/dists/test/main/binary-$arch"
printf 'Package: hello\nVersion: 1\nArchitecture: %s\nMaintainer: t <t@example.test>\nDescription: t\nFilename: pool/hello.deb\nSize: 1\nSHA256: %s\n' \
	"$arch" "$(printf x | sha256sum | cut -d' ' -f1)" >"$repo/dists/test/main/binary-$arch/Packages"
size=$(wc -c <"$repo/dists/test/main/binary-$arch/Packages")
sum=$(sha256sum "$repo/dists/test/main/binary-$arch/Packages" | cut -d' ' -f1)
printf 'Origin: t\nLabel: t\nSuite: test\nCodename: test\nDate: Mon, 02 Nov 2026 00:00:00 UTC\nArchitectures: %s\nComponents: main\nSHA256:\n %s %s main/binary-%s/Packages\n' \
	"$arch" "$sum" "$size" "$arch" >"$repo/dists/test/Release"

# apt_update <mode>: sets $rc, $secs, $first (requests for the first file), $reqs
apt_update() {
	m=$1; d=$TMP/$m
	mkdir -p "$d/lists/partial" "$d/cache/archives/partial" "$d/parts"
	: >"$d/req.log"; rm -f "$d/port"
	python3 "$TMP/srv.py" "$repo" "$m" "$d/req.log" "$d/port" "$arch" 2>"$d/srv.err" &
	SRV=$!
	i=0; while [ ! -s "$d/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
	port=$(cat "$d/port" 2>/dev/null)
	echo "deb [trusted=yes] http://127.0.0.1:$port/ test main" >"$d/sources.list"
	t0=$(date +%s)
	env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY timeout 150 apt-retry apt-get update \
		-o Dir::State::Lists="$d/lists" -o Dir::Cache="$d/cache" -o Dir::Etc::SourceList="$d/sources.list" \
		-o Dir::Etc::SourceParts="$d/parts" -o Debug::NoLocking=1 >"$d/apt.out" 2>&1
	rc=$?
	secs=$(( $(date +%s) - t0 ))
	kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; SRV=
	first=$(head -n 1 "$d/req.log")
	reqs=$(grep -c . "$d/req.log")
	nfirst=0; [ -n "$first" ] && nfirst=$(grep -cxF "$first" "$d/req.log")
}

if ! command -v python3 >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
	fail "F02-AC-5: python3 and apt-get are needed for the 503 cases"
elif ! command -v apt-retry >/dev/null 2>&1; then
	fail "F02-AC-5: apt-retry is not on PATH; apt-get update succeeds when each path answers 503 twice"
	fail "F02-AC-5: apt-retry is not on PATH; apt-get update fails against an always-503 server after more than one request, within 120 s"
else
	apt_update twice
	if [ $rc = 0 ]; then
		ok "F02-AC-5: apt-get update succeeds when each path answers 503 twice (${secs}s, $reqs requests)"
	else fail "F02-AC-5: apt-get update succeeds when each path answers 503 twice (rc=$rc, first file '$first' asked $nfirst times, ${secs}s)"; sed 's/^/  | /' "$TMP/twice/apt.out" "$TMP/twice/req.log"; fi

	apt_update always
	if [ $rc != 0 ] && [ "$nfirst" -gt 1 ] && [ "$secs" -le 120 ]; then
		ok "F02-AC-5: apt-get update fails against an always-503 server, after $nfirst requests for '$first', in ${secs}s (<= 120)"
	else fail "F02-AC-5: apt-get update fails against an always-503 server, after more than one request for the first file, within 120 s (rc=$rc, first file '$first' asked $nfirst times, ${secs}s)"; sed 's/^/  | /' "$TMP/always/apt.out"; fi
fi

if [ $fails = 0 ]; then echo "toolbox-apt-retry.test.sh: all passed"; else echo "toolbox-apt-retry.test.sh: $fails failed"; exit 1; fi
