#!/bin/sh
# P04 slice 1: the dashboard generator (node spec changes 2, 3, 4; criteria P04-AC-1 .. P04-AC-5).
#   P04-AC-1  index.html and <tag>/index.html over the fixtures, newest first, the fields of change 3, verify command,
#             asset links, byte-identical reruns
#   P04-AC-2  honest marks: pass / not published / unverified, advisory clean / no data / revoked, every mark a word
#   P04-AC-3  HTML escaping, no <script element
#   P04-AC-4  nothing from another origin, one stylesheet with a dark theme, no web font
#   P04-AC-5  the dashboard leaves status/ alone; a failure leaves no page and `make dashboard-check` red
#
# Interface chosen here (the implementer writes scripts/dashboard.py, scripts/dashboard.css and the Make targets from
# this header alone):
#
#   python3 -I scripts/dashboard.py --site <dir> --data <dir> --result <file>
#       <site>   the feed's site tree (output/advisory-feed/site): holds status/<tag>.json and status/index.txt, and
#                receives index.html, <tag>/index.html and style.css. Nothing under <site>/status/ is created,
#                changed or removed.
#       <data>   the feed's data tree (output/advisory-feed/data): <data>/<tag>/bom.cdx.json (CycloneDX) per release.
#       <result> a file the run always writes last: `ok` when every page was written, `failed` otherwise.
#       Environment: GITHUB_REPOSITORY (or GH_REPO) names this repository, RC1_TAG (default v0.1.0-rc1) the
#       predecessor's release, which is read from the fixed repository tuckermclean/linux-live-iso-factory.
#       Works from any current directory. The working set is the releases of `gh release list` for this repository
#       plus RC1_TAG; the page of a tag reads <data>/<tag>/bom.cdx.json (a release without one is not an error the
#       tests cover). style.css is a copy of scripts/dashboard.css (next to dashboard.py).
#       gh is called only as (stubbed here by P04/bin/gh, flags as listed; no --jq, --template or -O):
#         gh release list     [--repo R] [--limit N] --json F          JSON array of {tagName,name,publishedAt,
#                                                                       isPrerelease,isDraft}
#         gh release view TAG [--repo R] --json F                      JSON {tagName,name,url,body,publishedAt,
#                                                                       isPrerelease,isDraft,assets:[{name,size,url,..}]}
#         gh release download TAG [--repo R] --pattern P --dir D [--clobber]   fails (exit 1) when no asset matches
#       The repository is --repo/-R, else $GH_REPO, else $GITHUB_REPOSITORY. A gh failure makes the run fail.
#       SHA256SUMS and attestation-summary.json are downloaded with `release download`; a release whose assets list
#       has no attestation-summary.json (like rc1) is not an error.
#       Exit 0 on success. On any failure: non-zero exit, <result> holds `failed`, and the site holds exactly what it
#       held before: no index.html, no <tag>/ directory, no style.css left behind (write elsewhere, then move in).
#       The output is a function of the inputs only (no clock, no hostname): two runs write the same bytes.
#   Pages (HTML, no script):
#       index.html     one table row per release, <tr>...</tr>, newest publishedAt first. A row holds a link
#                      href="<tag>/" (or "<tag>/index.html"), the date (YYYY-MM-DD of publishedAt), the word
#                      `prerelease` for a prerelease and not otherwise, the overall gate mark, the advisory status
#                      mark, and the package count (SBOM components) as the whole text of an element (>N<).
#       <tag>/index.html  tag, date, ISO SHA-256 (from SHA256SUMS), the five gate marks (SBOM, licences, CVEs,
#                      unowned, overall), scanner name and version, DB build date, the coverage counts, the gating
#                      findings, the unowned count and files, the advisory status (status, checked, advisories,
#                      clearing, grype_db_built), packages with version and licence, licence summary, one
#                      <a href="<asset url>"> per asset of the release, and the verify command (change 3).
#       A mark is an element whose whole text is its word: >pass<, >fail<, >not published<, >unverified< for gates;
#       >clean<, >revoked<, >no data< for the advisory status. Each page links the stylesheet with one
#       <link rel="stylesheet" href="style.css"> (href="../style.css" or "/style.css" from <tag>/index.html).
#   make dashboard          `make -n dashboard` runs scripts/dashboard.py on output/advisory-feed/site and
#                           output/advisory-feed/data with --result $(DASHBOARD_RESULT).
#   make dashboard-check    DASHBOARD_RESULT ?= output/advisory-feed/dashboard-result. Its recipe is the one line
#                           `toolbox/run -- <command>` (as advisory-feed-check); the command succeeds only when the
#                           result file holds `ok` (a missing file or any other content fails). The test strips the
#                           `toolbox/run -- ` prefix and runs the command, since a test cannot nest the toolbox.
set -u
unset MAKEFLAGS MAKELEVEL MFLAGS MAKEOVERRIDES GH_REPO GH_TOKEN GITHUB_TOKEN
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
FX=$ROOT/scripts/fixtures/P04
fails=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }
check() { # check <label> <command...>
	l=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$l"; else fail "$l"; fi
}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dashboard.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM
W=$TMP/P04
mkdir -p "$W/bin" "$W/cwd"
REPO=acme/monolith-fixture
PRED=tuckermclean/linux-live-iso-factory

# gh stub: serves $P04_GH_FIXTURES/gh/<owner>__<repo>/{list.json,<tag>/view.json,<tag>/<asset>}.
# P04_GH_FAIL=list makes `release list` fail; P04_GH_FAIL=view:<tag> makes `release view <tag>` fail.
cat > "$W/bin/gh" <<'E'
#!/bin/sh
echo "gh $*" >>"${P04_GH_LOG:-/dev/null}"
fx=${P04_GH_FIXTURES:?}
[ "${1:-}" = release ] || { echo "gh stub: unsupported: $*" >&2; exit 2; }
sub=${2:-}; shift 2
repo=${GH_REPO:-${GITHUB_REPOSITORY:-}}
tag=; pat=; dir=.
while [ $# -gt 0 ]; do
	case $1 in
	--repo|-R) repo=$2; shift 2 ;;
	--pattern|-p) pat=$2; shift 2 ;;
	--dir|-D) dir=$2; shift 2 ;;
	--json|--limit|-L) shift 2 ;;
	--jq|-q|--template|-t|--output|-O) echo "gh stub: unsupported flag $1" >&2; exit 2 ;;
	-*) shift ;;
	*) tag=$1; shift ;;
	esac
done
rd=$fx/gh/$(printf '%s' "$repo" | sed 's|/|__|')
[ -d "$rd" ] || { echo "gh stub: no repository '$repo'" >&2; exit 1; }
case $sub in
list)
	[ "${P04_GH_FAIL:-}" = list ] && { echo "gh stub: list failed" >&2; exit 1; }
	cat "$rd/list.json" ;;
view)
	[ "${P04_GH_FAIL:-}" = "view:$tag" ] && { echo "gh stub: view failed" >&2; exit 1; }
	[ -f "$rd/$tag/view.json" ] || { echo "gh stub: release not found" >&2; exit 1; }
	cat "$rd/$tag/view.json" ;;
download)
	[ -d "$rd/$tag" ] || { echo "gh stub: release not found" >&2; exit 1; }
	n=0
	for f in "$rd/$tag"/*; do
		b=$(basename "$f")
		[ "$b" = view.json ] && continue
		# shellcheck disable=SC2254
		case $b in $pat) mkdir -p "$dir"; cp "$f" "$dir/$b"; n=$((n+1)) ;; esac
	done
	[ $n -gt 0 ] || { echo "gh stub: no assets match '$pat'" >&2; exit 1; } ;;
*) echo "gh stub: unsupported: release $sub" >&2; exit 2 ;;
esac
E
chmod +x "$W/bin/gh"

# gen <name> [VAR=value...]: a fresh copy of the feed tree in $W/<name>/{site,data}, then the generator over it.
gen() {
	n=$1; shift
	rm -rf "${W:?}/$n"; mkdir -p "$W/$n"
	cp -R "$FX/feed/site" "$W/$n/site"
	cp -R "$FX/feed/data" "$W/$n/data"
	: > "$W/$n/gh.log"
	[ -z "${SEED:-}" ] || echo "$SEED" >"$W/$n/result"
	(cd "$W/cwd" && env PATH="$W/bin:$PATH" P04_GH_FIXTURES="$FX" P04_GH_LOG="$W/$n/gh.log" \
		GITHUB_REPOSITORY=$REPO RC1_TAG=v0.1.0-rc1 "$@" \
		python3 -I "$ROOT/scripts/dashboard.py" --site "$W/$n/site" --data "$W/$n/data" --result "$W/$n/result") \
		>"$W/$n/out.log" 2>&1
	rc=$?
}
tree() { (cd "$1" && find . | sort); }
statsum() { (cd "$1/status" 2>/dev/null && find . -type f | sort | while read -r f; do sha256sum "$f"; done); }
flat() { [ -f "$1" ] && tr '\n' ' ' <"$1"; }
# nogrep <file> <grep args>: the file exists and flattened holds no match (a missing page is not a pass)
nogrep() { f=$1; shift; [ -s "$f" ] && ! flat "$f" | grep -q "$@"; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }    # has <file> <fixed string>
hasf() { flat "$1" | grep -qF -- "$2"; }        # same across line breaks
count() { flat "$1" | grep -oF -- "$2" | wc -l | tr -d ' '; }

TAGS="v0.4.0 v0.3.0 v0.2.0 v0.1.6 v0.1.5 v0.1.0-rc1"   # newest first
# per tag: overall gate mark | advisory mark | packages | date
exp() { case $1 in
	v0.4.0)      echo "fail|clean|2|2026-11-01" ;;
	v0.3.0)      echo "pass|revoked|4|2026-10-20" ;;
	v0.2.0)      echo "pass|clean|3|2026-10-01" ;;
	v0.1.6)      echo "unverified|no data|5|2026-09-20" ;;
	v0.1.5)      echo "unverified|clean|6|2026-09-15" ;;
	v0.1.0-rc1)  echo "not published|clean|7|2026-08-21" ;;
esac; }
repo_of() { [ "$1" = v0.1.0-rc1 ] && echo $PRED || echo $REPO; }
assets_of() { case $1 in
	v0.1.0-rc1) echo "themonolith-0.1.0-rc1.iso bom.cdx.json SHA256SUMS" ;;
	*) echo "themonolith-${1#v}.iso bom.cdx.json SHA256SUMS attestation-summary.json release-inputs.json" ;;
esac; }

# ======================================================================= run over the fixtures
gen run1
S1=$W/run1/site
RC1=$rc
check "P04-AC-1: dashboard.py exits 0 over the fixtures" test "$rc" -eq 0
check "P04-AC-5: the result file holds ok after a good run" test "$(cat "$W/run1/result" 2>/dev/null)" = ok

# ======================================================================= P04-AC-1
for f in index.html style.css; do check "P04-AC-1: $f is written" test -f "$S1/$f"; done
for t in $TAGS; do check "P04-AC-1: $t/index.html is written" test -f "$S1/$t/index.html"; done

# newest first
prev=0; order=ok
for t in $TAGS; do
	p=$(flat "$S1/index.html" | awk -v n="href=\"$t/" '{print index($0, n)}')
	{ [ -n "$p" ] && [ "$p" -gt "$prev" ]; } || order=bad
	prev=${p:-0}
done
[ "$order" = ok ] && ok "P04-AC-1: the index lists every release, newest first" || fail "P04-AC-1: the index lists every release, newest first"
check "P04-AC-1: the index has one row per release" test "$(flat "$S1/index.html" | grep -o '<tr' | wc -l | tr -d ' ')" -ge 6

flat "$S1/index.html" | sed 's#</tr>#\n#g' >"$W/rows"
for t in $TAGS; do
	IFS='|' read -r overall adv pk date <<EOF
$(exp "$t")
EOF
	grep -F "href=\"$t/" "$W/rows" | head -1 >"$W/row"
	has "$W/row" "$date" && ok "P04-AC-1: the index row of $t has its date" || fail "P04-AC-1: the index row of $t has its date"
	has "$W/row" ">$pk<" && ok "P04-AC-1: the index row of $t has its package count" || fail "P04-AC-1: the index row of $t has its package count"
	has "$W/row" ">$overall<" && ok "P04-AC-2: the index row of $t has the gate mark '$overall'" || fail "P04-AC-2: the index row of $t has the gate mark '$overall'"
	has "$W/row" ">$adv<" && ok "P04-AC-2: the index row of $t has the advisory mark '$adv'" || fail "P04-AC-2: the index row of $t has the advisory mark '$adv'"
	if [ "$t" = v0.1.0-rc1 ]; then
		check "P04-AC-1: the index row of rc1 says prerelease" grep -q prerelease "$W/row"
	else
		check "P04-AC-1: the index row of $t is not marked prerelease" nogrep "$W/row" prerelease
	fi
done

for t in $TAGS; do
	P=$S1/$t/index.html; r=$(repo_of "$t"); ver=${t#v}
	hasf "$P" "$t" && ok "P04-AC-1: $t page names its tag" || fail "P04-AC-1: $t page names its tag"
	IFS='|' read -r overall adv pk date <<EOF
$(exp "$t")
EOF
	hasf "$P" "$date" && ok "P04-AC-1: $t page has its date" || fail "P04-AC-1: $t page has its date"
	hasf "$P" "gh attestation verify themonolith-$ver.iso --repo $r --signer-workflow $r/.github/workflows/build.yml" \
		&& ok "P04-AC-1: $t page has its verify command" || fail "P04-AC-1: $t page has its verify command"
	for a in $(assets_of "$t"); do
		hasf "$P" "href=\"https://github.com/$r/releases/download/$t/$a\"" \
			&& ok "P04-AC-1: $t page links $a" || fail "P04-AC-1: $t page links $a"
	done
	isosha=$(awk '/\.iso$/ {print $1}' "$FX/gh/$(echo "$r" | sed 's|/|__|')/$t/SHA256SUMS")
	hasf "$P" "$isosha" && ok "P04-AC-1: $t page shows the ISO SHA-256" || fail "P04-AC-1: $t page shows the ISO SHA-256"
done
check "P04-AC-1: rc1's verify command does not name this repository" nogrep "$S1/v0.1.0-rc1/index.html" -F "$REPO"

# the fields of change 3 on the passing release's page
P=$S1/v0.2.0/index.html
for s in 0.104.1 2026-09-30 163 17 146 29 11 busybox 1.36.0 musl 1.2.4 zlib 1.3.0.1 GPL-2.0-only MIT Zlib \
	2026-11-12T03:00:00Z 2026-11-12T01:00:00Z; do
	hasf "$P" "$s" && ok "P04-AC-1: v0.2.0 page shows '$s'" || fail "P04-AC-1: v0.2.0 page shows '$s'"
done
check "P04-AC-1: v0.2.0 page shows the scanner name" grep -qi grype "$P"
P=$S1/v0.4.0/index.html
check "P04-AC-1: v0.4.0 page shows its unowned file" grep -q 'alert(2)' "$P"
check "P04-AC-1: v0.4.0 page shows its unowned count" sh -c 'tr "\n" " " <"$1" | grep -qE ">[[:space:]]*1[[:space:]]*<"' _ "$P"

# determinism
gen run2
check "P04-AC-1: a second run exits 0" test "$rc" -eq 0
check "P04-AC-1: two runs over the same inputs write identical bytes" sh -c 'test -s "$1/index.html" && diff -r "$1" "$2"' _ "$W/run1/site" "$W/run2/site"

# ======================================================================= P04-AC-2
for t in v0.2.0 v0.3.0; do
	n=$(count "$S1/$t/index.html" ">pass<")
	[ "$n" -ge 5 ] && ok "P04-AC-2: $t page marks its five gates pass" || fail "P04-AC-2: $t page marks its five gates pass ($n)"
done
for t in v0.1.0-rc1 v0.1.5 v0.1.6; do
	case $t in v0.1.0-rc1) w="not published" ;; *) w=unverified ;; esac
	n=$(count "$S1/$t/index.html" ">$w<")
	[ "$n" -ge 5 ] && ok "P04-AC-2: $t page marks its five gates '$w'" || fail "P04-AC-2: $t page marks its five gates '$w' ($n)"
	check "P04-AC-2: $t page shows no pass mark" nogrep "$S1/$t/index.html" -F ">pass<"
	grep -F "href=\"$t/" "$W/rows" | head -1 >"$W/row"
	check "P04-AC-2: the index row of $t shows no pass mark" nogrep "$W/row" -F ">pass<"
done
check "P04-AC-2: v0.4.0 page marks its failing unowned gate fail" hasf "$S1/v0.4.0/index.html" ">fail<"
check "P04-AC-2: v0.4.0 page also marks its passing gates pass" hasf "$S1/v0.4.0/index.html" ">pass<"
# advisory status
check "P04-AC-2: v0.1.6 (no status file) page says no data" hasf "$S1/v0.1.6/index.html" ">no data<"
check "P04-AC-2: v0.1.6 (no status file) page never says clean" nogrep "$S1/v0.1.6/index.html" -F ">clean<"
grep -F 'href="v0.1.6/' "$W/rows" | head -1 >"$W/row"
check "P04-AC-2: v0.1.6's index row never says clean" nogrep "$W/row" -F ">clean<"
for t in v0.2.0 v0.4.0 v0.1.5 v0.1.0-rc1; do
	check "P04-AC-2: $t page says clean" hasf "$S1/$t/index.html" ">clean<"
done
P=$S1/v0.3.0/index.html
check "P04-AC-2: the revoked release's page says revoked" hasf "$P" ">revoked<"
check "P04-AC-2: the revoked release's page never says clean" nogrep "$P" -F ">clean<"
check "P04-AC-2: the revoked release's page lists CVE-2026-1111" hasf "$P" CVE-2026-1111
check "P04-AC-2: the revoked release's page lists CVE-2026-2222" hasf "$P" CVE-2026-2222
check "P04-AC-2: the revoked release's page shows clearing" grep -qi clearing "$P"
grep -F 'href="v0.3.0/' "$W/rows" | head -1 >"$W/row"
check "P04-AC-2: the revoked release's index row never says clean" nogrep "$W/row" -F ">clean<"

# ======================================================================= P04-AC-3
ALL=$(cd "$S1" && find . -name '*.html' | sort)
bad=0
[ "$(echo "$ALL" | wc -l | tr -d ' ')" -ge 7 ] || bad=1   # the index and six release pages exist
for f in $ALL; do flat "$S1/$f" | grep -qi '<script' && bad=1; done
[ $bad -eq 0 ] && ok "P04-AC-3: no generated page contains a <script element" || fail "P04-AC-3: no generated page contains a <script element"
bad=0
[ "$RC1" -eq 0 ] || bad=1
for f in $ALL; do flat "$S1/$f" | grep -qiE '<img|onerror=' && bad=1; done
[ $bad -eq 0 ] && ok "P04-AC-3: release metadata (the body) is never emitted as markup" || fail "P04-AC-3: release metadata (the body) is never emitted as markup"
P=$S1/v0.4.0/index.html
check "P04-AC-3: the package named <script>alert(1)</script> appears as escaped text" hasf "$P" '&lt;script&gt;alert(1)&lt;/script&gt;'
check "P04-AC-3: the summary's unowned file appears as escaped text" hasf "$P" '&lt;script&gt;alert(2)&lt;/script&gt;'
check "P04-AC-3: no raw alert(1)</script> in the page" nogrep "$P" -F "alert(1)</script>"

# ======================================================================= P04-AC-4
CSS=$S1/style.css
check "P04-AC-4: style.css is scripts/dashboard.css" cmp "$ROOT/scripts/dashboard.css" "$CSS"
check "P04-AC-4: style.css has a dark theme under @media (prefers-color-scheme: dark)" \
	grep -Eq '@media[[:space:]]*\([[:space:]]*prefers-color-scheme[[:space:]]*:[[:space:]]*dark[[:space:]]*\)' "$CSS"
check "P04-AC-4: style.css has light-theme rules outside the media query" sh -c 'sed "/@media/,\$d" "$1" | grep -Eq "(body|:root)"' _ "$CSS"
check "P04-AC-4: style.css has no url()" nogrep "$CSS" -i "url[[:space:]]*("
check "P04-AC-4: style.css has no @import" nogrep "$CSS" -i "@import"
check "P04-AC-4: style.css has no web font (@font-face)" nogrep "$CSS" -i "@font-face"
check "P04-AC-4: style.css names no URL" nogrep "$CSS" -iE "https?:|//"
check "P04-AC-4: the site has one stylesheet" test "$(cd "$S1" && find . -name '*.css' | wc -l | tr -d ' ')" -eq 1
for f in $ALL; do
	pg=$S1/$f; flat "$pg" | grep -o '<link[^>]*>' >"$W/links"
	check "P04-AC-4: $f has exactly one <link>, a stylesheet" test "$(wc -l <"$W/links" | tr -d ' ')" -eq 1
	case $f in ./index.html) okh='style.css|./style.css|/style.css' ;; *) okh='../style.css|/style.css' ;; esac
	h=$(sed -n 's/.*href="\([^"]*\)".*/\1/p' "$W/links" | head -1)
	case "|$okh|" in *"|$h|"*) ok "P04-AC-4: $f links the stylesheet of the same site ($h)" ;; *) fail "P04-AC-4: $f links the stylesheet of the same site ('$h')" ;; esac
	check "P04-AC-4: $f has rel=stylesheet" grep -q 'rel="stylesheet"' "$W/links"
	check "P04-AC-4: $f has no src attribute" nogrep "$pg" -iE "<[a-z][^>]*[[:space:]]src[[:space:]]*="
	check "P04-AC-4: $f has no <style>, @import or url()" nogrep "$pg" -iE "<style|@import|url[[:space:]]*\("
	check "P04-AC-4: $f embeds nothing (iframe, object, embed, form, source, video, audio)" \
		nogrep "$pg" -iE "<(iframe|object|embed|form|source|video|audio)"
done

# ======================================================================= P04-AC-5
check "P04-AC-5: the status/ tree is byte-identical with and without the dashboard" \
	test "$RC1" -eq 0 -a -f "$S1/index.html" -a "$(statsum "$FX/feed/site")" = "$(statsum "$W/run1/site")" -a -n "$(statsum "$W/run1/site")"
check "P04-AC-5: status/ holds no extra entry (index.txt included)" \
	test "$RC1" -eq 0 -a -f "$S1/index.html" -a "$(cd "$FX/feed/site" && find status | sort)" = "$(cd "$S1" && find status | sort)"
check "P04-AC-5: gh was only asked to list, view and download releases" \
	sh -c 'test -s "$1" && ! grep -vE "^gh release (list|view|download) " "$1" | grep -q .' _ "$W/run1/gh.log"
check "P04-AC-5: the run asked gh for something" test -s "$W/run1/gh.log"

for failure in list view:v0.2.0; do
	n=fail-$(echo "$failure" | tr ':' '-')
	rm -rf "${W:?}/$n.before"; cp -R "$FX/feed/site" "$W/$n.before"
	SEED=ok gen "$n" P04_GH_FAIL=$failure   # SEED: a stale result of an earlier good run
	check "P04-AC-5: dashboard.py fails when gh fails ($failure)" test "$RC1" -eq 0 -a "$rc" -ne 0
	check "P04-AC-5: the result file holds failed ($failure)" test "$(cat "$W/$n/result" 2>/dev/null)" = failed
	check "P04-AC-5: the site holds every status file, unchanged ($failure)" \
		test "$RC1" -eq 0 -a "$(statsum "$W/$n.before")" = "$(statsum "$W/$n/site")" -a -n "$(statsum "$W/$n/site")"
	check "P04-AC-5: no partial page, directory or stylesheet is left ($failure)" \
		test "$RC1" -eq 0 -a "$(tree "$W/$n.before")" = "$(tree "$W/$n/site")"
done

# the Make targets (make -n: a test cannot nest the toolbox)
mk() { (cd "$ROOT" && make -n "$@" 2>&1); }
mk dashboard DASHBOARD_RESULT=/x/dashboard-result >"$W/mk-dashboard"
for s in scripts/dashboard.py output/advisory-feed/site output/advisory-feed/data /x/dashboard-result; do
	check "P04-AC-5: make -n dashboard names $s" grep -qF -- "$s" "$W/mk-dashboard"
done
cmd=
for res in ok failed none; do
	r=$W/dashboard-result.$res
	case $res in none) rm -f "$r" ;; *) echo "$res" >"$r" ;; esac
	mk dashboard-check DASHBOARD_RESULT="$r" >"$W/mk-check"
	line=$(grep '^toolbox/run -- ' "$W/mk-check" | head -1)
	cmd=${line#toolbox/run -- }
	if [ -z "$line" ]; then fail "P04-AC-5: make -n dashboard-check prints a 'toolbox/run -- <command>' line ($res)"; continue; fi
	(cd "$ROOT" && eval "$cmd") >/dev/null 2>&1; c=$?
	if [ "$res" = ok ]; then
		[ $c -eq 0 ] && ok "P04-AC-5: make dashboard-check passes on a result of ok" || fail "P04-AC-5: make dashboard-check passes on a result of ok"
	else
		[ $c -ne 0 ] && ok "P04-AC-5: make dashboard-check fails on a result of $res" || fail "P04-AC-5: make dashboard-check fails on a result of $res"
	fi
done

[ "$fails" -eq 0 ] && { echo "PASS: all dashboard checks"; exit 0; }
echo "FAIL: $fails dashboard check(s) failed"
exit 1
