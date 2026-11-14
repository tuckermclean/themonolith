#!/usr/bin/env python3
"""The release dashboard: static pages for the advisory feed's Pages site (P04).

  dashboard.py --site DIR --data DIR --result FILE

Reads release metadata through gh, the feed's SBOMs (DATA/<tag>/bom.cdx.json) and status files
(SITE/status/<tag>.json); writes SITE/index.html, SITE/<tag>/index.html and SITE/style.css. Nothing under
SITE/status/ is touched. The pages are staged beside the site and moved in only when all are written; FILE
holds `ok` or `failed` afterwards. Standard library only; every text from outside goes through html.escape.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from html import escape

PRED_REPO = "tuckermclean/linux-live-iso-factory"
GATES = (("sbom_check", "SBOM"), ("license_check", "Licences"), ("cve_check", "CVEs"),
         ("unowned_check", "Unowned files"), ("overall", "Overall"))
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")


def gh(*args):
    r = subprocess.run(["gh", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise RuntimeError("gh %s failed: %s" % (" ".join(args[:2]), r.stderr.strip()))
    return r.stdout


def gh_json(*args):
    return json.loads(gh(*args))


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def collect(repo, tag, work):
    """One release: metadata, ISO checksum, gate summary (or why there is none), SBOM-independent facts."""
    view = gh_json("release", "view", tag, "--repo", repo, "--json",
                   "tagName,name,url,body,publishedAt,isPrerelease,isDraft,assets")
    names = [a.get("name") for a in view.get("assets") or []]
    d = os.path.join(work, tag)
    os.makedirs(d)
    sums = {}
    if "SHA256SUMS" in names:
        gh("release", "download", tag, "--repo", repo, "--pattern", "SHA256SUMS", "--dir", d, "--clobber")
        with open(os.path.join(d, "SHA256SUMS"), encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.split()
                if len(p) == 2:
                    sums[p[1].lstrip("*")] = p[0].lower()
    # gates: "not published" (no summary), "unverified" (unreadable or not the signed one), else its own marks
    summary, state = None, "not published"
    if "attestation-summary.json" in names:
        gh("release", "download", tag, "--repo", repo, "--pattern", "attestation-summary.json",
           "--dir", d, "--clobber")
        p = os.path.join(d, "attestation-summary.json")
        state = "unverified"
        s = read_json(p)
        if isinstance(s, dict) and sums.get("attestation-summary.json") == sha256(p):
            summary, state = s, "verified"
    iso = next((h for n, h in sorted(sums.items()) if n.endswith(".iso")), None)
    return {"tag": tag, "repo": repo, "view": view, "summary": summary, "state": state, "iso": iso}


def sbom_packages(data, tag):
    doc = read_json(os.path.join(data, tag, "bom.cdx.json"))
    pk = []
    for c in (doc or {}).get("components") or [] if isinstance(doc, dict) else []:
        if not isinstance(c, dict):
            continue
        lic = []
        for e in c.get("licenses") or []:
            if isinstance(e, dict):
                x = e.get("license") or {}
                v = x.get("id") or x.get("name") or e.get("expression")
                if v:
                    lic.append(str(v))
        pk.append((str(c.get("name", "")), str(c.get("version", "")), ", ".join(lic) or "unknown"))
    return sorted(pk) if doc is not None else None


def gate_marks(rel):
    s = rel["summary"]
    out = {}
    for key, _ in GATES:
        v = s.get(key) if s else None
        out[key] = v if v in ("pass", "fail") else ("unverified" if s else rel["state"])
    return out


def mark(word, kind=""):
    return '<span class="mark %s">%s</span>' % (escape(kind or word.replace(" ", "-")), escape(word))


def advisory(site, tag):
    st = read_json(os.path.join(site, "status", tag + ".json"))
    if not isinstance(st, dict) or st.get("status") not in ("clean", "revoked"):
        return None
    return st


def verify_cmd(rel):
    r, ver = rel["repo"], rel["tag"].lstrip("v")
    return "gh attestation verify themonolith-%s.iso --repo %s --signer-workflow %s/.github/workflows/build.yml" % (ver, r, r)


def page(title, css, body):
    return ('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>%s</title>\n'
            '<link rel="stylesheet" href="%s">\n</head>\n<body>\n%s</body>\n</html>\n' % (escape(title), css, body))


def row(*cells):
    return "<tr>" + "".join("<%s>%s</%s>" % (t, c, t) for t, c in cells) + "</tr>\n"


def td(x):
    return ("td", x)


def release_page(rel, site, data):
    v, s, tag = rel["view"], rel["summary"], rel["tag"]
    marks, adv, pk = gate_marks(rel), advisory(site, tag), sbom_packages(data, tag)
    h = ["<h1>%s</h1>\n" % escape(tag), '<p><a href="../">All releases</a></p>\n']
    h.append("<table>\n")
    h.append(row(("th", "Published"), td(escape((v.get("publishedAt") or "")[:10]))))
    h.append(row(("th", "Release"), td('<a href="%s">%s</a>' % (escape(v.get("url") or "", True), escape(v.get("name") or tag)))))
    if v.get("isPrerelease"):
        h.append(row(("th", "Kind"), td(mark("prerelease"))))
    h.append(row(("th", "ISO SHA-256"), td("<code>%s</code>" % escape(rel["iso"] or "unknown"))))
    h.append("</table>\n<h2>Verify</h2>\n<pre>%s</pre>\n" % escape(verify_cmd(rel)))
    h.append("<h2>Gates at release</h2>\n<table>\n")
    for key, label in GATES:
        h.append(row(("th", label), td(mark(marks[key]))))
    h.append("</table>\n")
    if rel["state"] == "not published":
        h.append("<p>This release published no gate summary.</p>\n")
    elif rel["state"] == "unverified":
        h.append("<p>The gate summary could not be checked against SHA256SUMS.</p>\n")
    if s:
        sc, db, cv = s.get("cve_scanner") or {}, s.get("cve_db") or {}, s.get("cve_coverage") or {}
        h.append("<h2>CVE scan</h2>\n<table>\n")
        h.append(row(("th", "Scanner"), td(escape("%s %s" % (sc.get("name", ""), sc.get("version", ""))))))
        h.append(row(("th", "Database built"), td(escape(str(db.get("built", ""))))))
        for k in sorted(cv):
            h.append(row(("th", escape(k.replace("_", " ").replace("clean", "without findings"))), td(escape(str(cv[k])))))
        h.append("</table>\n")
        if s.get("cve_failures"):
            h.append("<h3>Gating findings</h3>\n<ul>\n%s</ul>\n" % "".join("<li>%s</li>\n" % escape(str(x)) for x in s["cve_failures"]))
        if s.get("license_failures"):
            h.append("<h3>Licence failures</h3>\n<ul>\n%s</ul>\n" % "".join("<li>%s</li>\n" % escape(str(x)) for x in s["license_failures"]))
        h.append("<h2>Unowned files</h2>\n<p>Count: <span>%s</span></p>\n" % escape(str(s.get("unowned_count", 0))))
        if s.get("unowned_files"):
            h.append("<ul>\n%s</ul>\n" % "".join("<li><code>%s</code></li>\n" % escape(str(x)) for x in s["unowned_files"]))
    h.append("<h2>Advisory status</h2>\n<table>\n")
    if adv:
        h.append(row(("th", "Status"), td(mark(adv["status"]))))
        h.append(row(("th", "Checked"), td(escape(str(adv.get("checked", ""))))))
        h.append(row(("th", "Advisories"), td(escape(", ".join(map(str, adv.get("advisories") or [])) or "none"))))
        if adv["status"] == "revoked" and adv.get("clearing"):
            h.append(row(("th", "Clearing"), td(mark("clearing"))))
        h.append(row(("th", "Vulnerability database built"), td(escape(str(adv.get("grype_db_built", ""))))))
    else:
        h.append(row(("th", "Status"), td(mark("no data"))))
    h.append("</table>\n<h2>Assets</h2>\n<ul>\n")
    for a in v.get("assets") or []:
        h.append('<li><a href="%s">%s</a></li>\n' % (escape(a.get("url") or "", True), escape(a.get("name") or "")))
    h.append("</ul>\n<h2>Packages</h2>\n")
    if pk is None:
        h.append("<p>No SBOM is available for this release.</p>\n")
    else:
        count = {}
        for _, _, lic in pk:
            count[lic] = count.get(lic, 0) + 1
        h.append("<h3>Licences</h3>\n<table>\n")
        h.append(row(("th", "Licence"), ("th", "Packages")))
        for lic in sorted(count):
            h.append(row(td(escape(lic)), td(str(count[lic]))))
        h.append("</table>\n<h3>All packages</h3>\n<table>\n")
        h.append(row(("th", "Name"), ("th", "Version"), ("th", "Licence")))
        for n, ver, lic in pk:
            h.append(row(td(escape(n)), td(escape(ver)), td(escape(lic))))
        h.append("</table>\n")
    return page(tag, "../style.css", "".join(h))


def index_page(rels, site, data):
    h = ["<h1>Releases</h1>\n<table>\n", row(*[("th", t) for t in ("Release", "Published", "Kind", "Gates", "Advisory", "Packages")])]
    for rel in rels:
        v, tag = rel["view"], rel["tag"]
        adv, pk = advisory(site, tag), sbom_packages(data, tag)
        h.append(row(td('<a href="%s/">%s</a>' % (escape(tag, True), escape(tag))),
                     td(escape((v.get("publishedAt") or "")[:10])),
                     td(escape("prerelease") if v.get("isPrerelease") else ""),
                     td(mark(gate_marks(rel)["overall"])),
                     td(mark(adv["status"] if adv else "no data")),
                     td(str(len(pk)) if pk is not None else "")))
    h.append("</table>\n")
    return page("Releases", "style.css", "".join(h))


def build(args, stage, work):
    repo = os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY")
    if not repo:
        raise RuntimeError("GITHUB_REPOSITORY is not set")
    rc1 = os.environ.get("RC1_TAG") or "v0.1.0-rc1"
    todo = [(rc1, PRED_REPO)]
    for r in gh_json("release", "list", "--repo", repo, "--limit", "1000", "--json",
                     "tagName,name,publishedAt,isPrerelease,isDraft"):
        if not r.get("isDraft") and r["tagName"] != rc1:
            todo.append((r["tagName"], repo))
    rels = []
    for tag, r in todo:
        if not TAG_RE.match(tag) or tag in ("status", "style.css", "index.html"):
            raise RuntimeError("unusable tag %r" % tag)
        rels.append(collect(r, tag, work))
    rels.sort(key=lambda x: (x["view"].get("publishedAt") or "", x["tag"]), reverse=True)
    out = {"index.html": index_page(rels, args.site, args.data)}
    for rel in rels:
        out[rel["tag"] + "/index.html"] = release_page(rel, args.site, args.data)
    for name, text in out.items():
        os.makedirs(os.path.dirname(os.path.join(stage, name)), exist_ok=True)
        with open(os.path.join(stage, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    shutil.copyfile(os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard.css"),
                    os.path.join(stage, "style.css"))


def install(stage, site):
    """Move the staged pages into the site; put everything back if a move fails."""
    names = sorted(os.listdir(stage))
    aside = os.path.join(stage, "..aside")
    os.mkdir(aside)
    moved, parked = [], []
    try:
        for n in names:
            dst = os.path.join(site, n)
            if os.path.lexists(dst):
                os.rename(dst, os.path.join(aside, n))
                parked.append(n)
            os.rename(os.path.join(stage, n), dst)
            moved.append(n)
    except BaseException:
        for n in moved:
            p = os.path.join(site, n)
            shutil.rmtree(p) if os.path.isdir(p) else os.unlink(p)
        for n in parked:
            os.rename(os.path.join(aside, n), os.path.join(site, n))
        raise


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--result", required=True)
    args = ap.parse_args()
    args.site, args.data = os.path.abspath(args.site), os.path.abspath(args.data)
    status = "failed"
    tmp = None
    try:
        tmp = tempfile.mkdtemp(prefix=".dashboard.", dir=os.path.dirname(args.site))
        stage = os.path.join(tmp, "stage")
        os.mkdir(stage)
        build(args, stage, os.path.join(tmp, "work"))
        install(stage, args.site)
        status = "ok"
    except Exception as e:
        print("dashboard.py: %s" % e, file=sys.stderr)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
        with open(args.result, "w") as f:
            f.write(status + "\n")
    return 0 if status == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
