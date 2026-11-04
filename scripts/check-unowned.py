#!/usr/bin/env python3
"""
check-unowned.py — Pillar 4: Unowned files audit for The Monolith ISO.

Reads the Syft native JSON SBOM and identifies files present on the filesystem
that are not owned by any Portage package.

Syft's native JSON contains:
  artifacts[].metadata.Files[]  — files owned by each portage package (from CONTENTS)
  files[]                       — all files found on disk by the file cataloger

The diff (disk files minus owned files) = unowned files: not tracked by Portage,
not in the SBOM, not subject to license or CVE checks.

Known-unowned files (init scripts, advisory scripts, /etc config files installed
by build-rootfs.sh) are suppressed via an allowlist of fnmatch glob patterns.

Exit codes:
  0  no unallowlisted unowned files
  1  one or more unowned files not covered by the allowlist
"""

import argparse
import fnmatch
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def load_yaml_simple(path: str) -> dict:
    try:
        import yaml
    except ImportError:
        print(
            "[check-unowned] ERROR: pyyaml is not installed.\n"
            "  Install with: pip3 install pyyaml",
            file=sys.stderr,
        )
        sys.exit(1)
    with open(path) as f:
        return yaml.safe_load(f) or {}


def entry_path(entry) -> str:
    """The glob of an allowlist entry: a plain string, or a mapping with a 'path' key."""
    return entry.get("path", "") if isinstance(entry, dict) else str(entry)


def load_allowlist(path: str) -> list:
    """Load glob patterns from the allowlist YAML (plain strings or {path, source} mappings)."""
    data = load_yaml_simple(path)
    return [entry_path(e) for e in (data.get("allowlist") or [])]


def load_allowlist_entries(path: str) -> tuple:
    """Raw allowlist and modified: entries, for --provenance."""
    data = load_yaml_simple(path)
    return (data.get("allowlist") or []), (data.get("modified") or [])


def get_file_path(file_entry: dict) -> str | None:
    """Extract the path from a Syft files[] entry, handling schema variations."""
    loc = file_entry.get("location", {})
    # Try realPath first (Syft >= 0.80), then path
    return loc.get("realPath") or loc.get("path") or loc.get("accessPath")


def get_owned_paths_from_contents(sysroot: str) -> set:
    """
    Read portage CONTENTS files directly from {sysroot}/var/db/pkg to get
    the full set of owned paths including symlinks (sym entries) and directories
    (dir entries) that Syft's portage cataloger does not capture in installedFiles.

    CONTENTS format:
      obj /path md5hash timestamp
      sym /path -> target timestamp
      dir /path
    """
    owned = set()
    pkg_db = Path(sysroot.rstrip("/")) / "var" / "db" / "pkg"
    if not pkg_db.exists():
        return owned
    for contents_file in pkg_db.glob("**/CONTENTS"):
        try:
            with open(contents_file) as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2 and parts[0] in ("obj", "sym", "dir"):
                        owned.add(parts[1])
        except (OSError, UnicodeDecodeError):
            pass
    return owned


def get_owned_paths(syft_json: dict) -> set:
    """
    Build the set of paths owned by Portage packages.
    Reads the CONTENTS file list from each portage artifact.

    Portage CONTENTS paths are target-absolute (e.g. /usr/bin/bash),
    not prefixed with the scan root. Returns them as-is.

    Syft schema variations across versions:
      metadata.installedFiles[]  — current Syft (camelCase)
      metadata.Files[]           — older Syft (PascalCase)
      metadata.files[]           — alternate older schema
    """
    owned = set()
    portage_pkg_count = 0
    for artifact in syft_json.get("artifacts", []):
        if artifact.get("type", "").lower() != "portage":
            continue
        portage_pkg_count += 1
        metadata = artifact.get("metadata") or {}
        files = (
            metadata.get("installedFiles")
            or metadata.get("Files")
            or metadata.get("files")
            or []
        )
        for f in files:
            p = f.get("path") or f.get("Path")
            if p:
                owned.add(p)

    if portage_pkg_count > 0 and not owned:
        # Dump the metadata keys of the first portage artifact so the field
        # name mismatch can be diagnosed in CI logs.
        for artifact in syft_json.get("artifacts", []):
            if artifact.get("type", "").lower() == "portage":
                meta = artifact.get("metadata") or {}
                print(
                    f"[check-unowned] WARN: portage pkg '{artifact.get('name')}' "
                    f"has metadata keys: {list(meta.keys())} — no file list found",
                    file=sys.stderr,
                )
                break

    return owned


def get_disk_files(syft_json: dict, sysroot: str) -> dict:
    """
    Build a dict of {in_system_path: file_entry} from Syft's top-level files[].

    File cataloger paths include the sysroot prefix (e.g. /output/sysroot/usr/bin/bash).
    Strip it to get the in-system path (/usr/bin/bash).
    """
    disk_files = {}
    sysroot = sysroot.rstrip("/")

    for f in syft_json.get("files", []):
        full_path = get_file_path(f)
        if not full_path:
            continue
        # Strip sysroot prefix
        if sysroot and full_path.startswith(sysroot):
            in_system = full_path[len(sysroot):]
        else:
            in_system = full_path
        if not in_system or in_system == "/":
            continue
        disk_files[in_system] = f

    return disk_files


def auto_detect_prefix(owned_paths: set, sysroot: str) -> bool:
    """
    Check whether the portage cataloger is also prefixing CONTENTS paths
    with the sysroot (it normally doesn't, but verify defensively).
    Returns True if owned paths need the same sysroot stripping as disk files.
    """
    if not owned_paths or not sysroot:
        return False
    sample = next(iter(owned_paths))
    return sample.startswith(sysroot.rstrip("/") + "/")


def is_allowlisted(path: str, patterns: list) -> bool:
    """Check if a path matches any allowlist glob pattern."""
    rel = path.lstrip("/")
    for pattern in patterns:
        if fnmatch.fnmatch(rel, pattern):
            return True
        # Also try matching the full path for patterns with leading /
        if fnmatch.fnmatch(path, pattern):
            return True
    return False


SOURCE_RE = re.compile(r"^(build-rootfs\.sh|portage|postinst:[^/\s:]+/[^\s:]+)$")


def read_contents_records(sysroot: str) -> dict:
    """
    {path: [(cpv, kind, value)]} from {sysroot}/var/db/pkg/*/*/CONTENTS; value is the
    recorded MD5 of an obj and the target of a sym. dir entries carry no value.
    """
    records = {}
    pkg_db = Path(sysroot.rstrip("/")) / "var" / "db" / "pkg"
    if not pkg_db.exists():
        return records
    for contents_file in sorted(pkg_db.glob("*/*/CONTENTS")):
        cpv = f"{contents_file.parent.parent.name}/{contents_file.parent.name}"
        with open(contents_file, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                if line.startswith("obj "):
                    m = re.match(r"^obj (.*) ([0-9a-f]{32}) \d+$", line)
                    if m:
                        records.setdefault(m.group(1), []).append((cpv, "obj", m.group(2)))
                elif line.startswith("sym "):
                    body = line[4:]
                    i = body.find(" -> ")
                    if i >= 0:
                        target = re.sub(r" \d+$", "", body[i + 4:])
                        records.setdefault(body[:i], []).append((cpv, "sym", target))
                elif line.startswith("dir "):
                    records.setdefault(line[4:].rstrip(), []).append((cpv, "dir", ""))
    return records


def read_bootstrap_exceptions(path: str) -> dict:
    exceptions = {}
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2 or not parts[0].startswith("/"):
                print(f"[check-unowned] ERROR: bad bootstrap exception line: {line}", file=sys.stderr)
                sys.exit(1)
            exceptions[parts[0]] = parts[1]
    return exceptions


def read_built_cpvs(path: str) -> set:
    built = set()
    with open(path) as f:
        header = f.readline().rstrip("\n").split("\t")
        if header[:3] != ["path", "owner", "provenance"]:
            print(f"[check-unowned] ERROR: {path} is not a source-audit report", file=sys.stderr)
            sys.exit(1)
        for line in f:
            cols = line.rstrip("\n").split("\t")
            if len(cols) >= 3 and cols[2] == "built-this-run":
                built.add(cols[1])
    return built


def file_md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_paths(tree: str) -> set:
    """Every path under the package tree, relative, no leading slash."""
    found = set()
    tree = tree.rstrip("/")
    for dp, dn, fn in os.walk(tree):
        for x in dn + fn:
            found.add(os.path.relpath(os.path.join(dp, x), tree))
    return found


def provenance_check(disk_files, sysroot, allowlist, modified, exceptions, package_tree, built):
    """
    Classify every file on disk as package, modified, bootstrap or generated, and collect
    the failures. built is the set of built-this-run cpvs, or None without --source-audit.
    Returns (rows, failures, unowned).
    """
    failures = []
    for e in list(allowlist) + list(modified):
        if not isinstance(e, dict) or not e.get("path"):
            failures.append(f"allowlist entry is not a mapping with a path: {e}")
        elif not SOURCE_RE.match(str(e.get("source") or "")):
            failures.append(f"allowlist entry without a valid source: {e['path']}")
    allowlist = [e for e in allowlist if isinstance(e, dict) and e.get("path")]
    modified = [e for e in modified if isinstance(e, dict) and e.get("path")]

    records = read_contents_records(sysroot)
    installed = sorted(
        f"{p.parent.name}/{p.name}" for p in (Path(sysroot) / "var" / "db" / "pkg").glob("*/*") if p.is_dir()
    )
    tree = tree_paths(package_tree)
    used_allow, used_mod, used_exc = set(), set(), set()
    rows, unowned = [], []
    unbuilt_reported = set()

    def built_col(cpv):
        if built is None:
            return ""
        if cpv not in built and cpv not in unbuilt_reported:
            unbuilt_reported.add(cpv)
            failures.append(f"{cpv} is owned in the rootfs but not built-this-run")
        return "built-this-run"

    def match_first(path, entries, used):
        rel = path.lstrip("/")
        hit = None
        for i, e in enumerate(entries):
            pat = e["path"]
            if fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(path, pat):
                used.add(i)
                hit = hit if hit is not None else e
        return hit

    for path in sorted(disk_files):
        real = sysroot + path
        recs = records.get(path)
        if recs is None and (path + ".bz2") in records:
            # Installed as path.bz2, decompressed by extract-packages.sh: the recorded MD5 is of the compressed bytes.
            cpv = records[path + ".bz2"][0][0]
            rows.append((path, "package", cpv, built_col(cpv)))
            continue
        if recs:
            cpv, kind, value = recs[0]
            mod = match_first(path, modified, used_mod)
            if path in exceptions:
                used_exc.add(path)
            if kind == "obj":
                if os.path.islink(real) or not os.path.isfile(real):
                    ok = False
                else:
                    ok = any(file_md5(real) == r[2] for r in recs if r[1] == "obj")
            elif kind == "sym":
                ok = os.path.islink(real) and any(os.readlink(real) == r[2] for r in recs if r[1] == "sym")
            else:
                ok = True
            if mod is not None:
                rows.append((path, "modified", str(mod.get("source") or ""), built_col(cpv)))
            elif ok:
                rows.append((path, "package", cpv, built_col(cpv)))
            else:
                what = "MD5" if kind == "obj" else "symlink target"
                failures.append(f"{path}: {what} differs from CONTENTS of {cpv} and is not under modified:")
            continue
        if path in exceptions:
            used_exc.add(path)
            rows.append((path, "bootstrap", exceptions[path], "bootstrap" if built is not None else ""))
            continue
        e = match_first(path, allowlist, used_allow)
        if e is not None:
            rows.append((path, "generated", str(e.get("source") or ""), "built-this-run" if built is not None else ""))
        else:
            unowned.append(path)

    for i, e in enumerate(allowlist):
        pat, src = e["path"], str(e.get("source") or "")
        if i not in used_allow:
            failures.append(f"stale allowlist entry (matches nothing in the rootfs): {pat}")
        if src == "build-rootfs.sh":
            for t in sorted(tree):
                tp = os.path.join(package_tree, t)
                if fnmatch.fnmatch(t, pat) and (os.path.islink(tp) or os.path.isfile(tp)):
                    failures.append(f"{t}: a build-rootfs.sh entry, but the file also exists in {package_tree}")
        elif src.startswith("postinst:"):
            pkg = src[len("postinst:"):]
            cpvs = [c for c in installed if re.match(re.escape(pkg) + r"-\d", c)]
            if not cpvs:
                failures.append(f"{pat}: postinst package {pkg} is not installed in the rootfs")
            elif built is not None and not any(c in built for c in cpvs):
                failures.append(f"{pat}: postinst package {pkg} is not built-this-run")
            if not any(fnmatch.fnmatch(t, pat) for t in tree):
                failures.append(f"{pat}: postinst path is missing from {package_tree}")
    for i, e in enumerate(modified):
        if i not in used_mod:
            failures.append(f"stale modified: entry (matches no owned file in the rootfs): {e['path']}")
    for p in sorted(set(exceptions) - used_exc):
        failures.append(f"stale bootstrap exception (matches no file in the rootfs): {p}")
    return rows, failures, unowned


def main():
    parser = argparse.ArgumentParser(
        description="Audit filesystem files against Portage package ownership.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --syft-json attestation/sbom.syft.json \\
           --sysroot /output/sysroot \\
           --output  attestation/unowned-report.json \\
           --allowlist config/unowned-allowlist.yaml

Exit codes:
  0  no unallowlisted unowned files
  1  unowned files found
        """,
    )
    parser.add_argument("--syft-json",  required=True, metavar="PATH", help="Syft native JSON SBOM")
    parser.add_argument("--sysroot",    required=True, metavar="PATH", help="Sysroot prefix to strip from file paths")
    parser.add_argument("--output",     required=True, metavar="PATH", help="JSON report output path")
    parser.add_argument("--allowlist",  metavar="PATH", help="YAML file with glob patterns for known-unowned files")
    parser.add_argument("--provenance", action="store_true",
                        help="also check owned files' bytes and every allowlist entry's source")
    parser.add_argument("--package-tree", metavar="DIR", help="output/sysroot (with --provenance)")
    parser.add_argument("--source-audit", metavar="TSV", help="source-audit.sh report; release mode (with --provenance)")
    parser.add_argument("--bootstrap-exceptions", metavar="FILE", help="toolchain files: '<abs path> <host cpv>' lines")
    parser.add_argument("--provenance-report", metavar="TSV", help="write rootfs-provenance.tsv here")
    args = parser.parse_args()
    if args.provenance and not args.package_tree:
        parser.error("--provenance needs --package-tree")
    for opt in ("source_audit", "bootstrap_exceptions", "provenance_report", "package_tree"):
        if getattr(args, opt) and not args.provenance:
            parser.error("--" + opt.replace("_", "-") + " needs --provenance")

    syft_path = Path(args.syft_json)
    if not syft_path.exists():
        print(f"[check-unowned] ERROR: Syft JSON not found: {args.syft_json}", file=sys.stderr)
        sys.exit(1)

    allowlist = []
    if args.allowlist:
        al_path = Path(args.allowlist)
        if al_path.exists():
            allowlist = load_allowlist(args.allowlist)
        else:
            print(f"[check-unowned] ERROR: allowlist not found: {args.allowlist}", file=sys.stderr)
            sys.exit(1)

    with open(syft_path) as f:
        syft_json = json.load(f)

    schema_ver = syft_json.get("schema", {}).get("version", "unknown")
    print(f"[check-unowned] Syft schema version: {schema_ver}")

    sysroot = args.sysroot.rstrip("/")

    # Owned paths from Syft installedFiles (obj entries only — Syft limitation)
    syft_owned = get_owned_paths(syft_json)

    # Defensive: check if owned paths also carry the sysroot prefix
    if auto_detect_prefix(syft_owned, sysroot):
        print(f"[check-unowned] NOTE: portage metadata paths also include sysroot prefix; normalizing", file=sys.stderr)
        syft_owned = {p[len(sysroot):] for p in syft_owned}

    # Supplement with sym/dir entries read directly from CONTENTS files.
    # Syft's portage cataloger only records obj (regular file) entries;
    # symlinks and directories tracked by portage would appear unowned without this.
    contents_owned = get_owned_paths_from_contents(sysroot)
    owned_paths = syft_owned | contents_owned
    print(
        f"[check-unowned] Portage-owned paths: {len(owned_paths)} "
        f"(Syft obj: {len(syft_owned)}, CONTENTS sym+dir: {len(contents_owned - syft_owned)})"
    )

    disk_files = get_disk_files(syft_json, sysroot)
    print(f"[check-unowned] Files on disk (from Syft): {len(disk_files)}")

    if not disk_files:
        print(
            "[check-unowned] ERROR: no entries in Syft files[] — was file.metadata.selection=all set?",
            file=sys.stderr,
        )
        sys.exit(1)

    if not contents_owned:
        print(
            f"[check-unowned] ERROR: no Portage-owned paths read from {sysroot}/var/db/pkg — "
            "every file would be unowned or the sysroot is not a Portage root",
            file=sys.stderr,
        )
        sys.exit(1)

    unowned_all = []
    allowlisted_count = 0
    owned_count = 0
    prov_failures = []
    bootstrap_count = 0

    if args.provenance:
        entries, modified = load_allowlist_entries(args.allowlist) if args.allowlist else ([], [])
        exceptions = read_bootstrap_exceptions(args.bootstrap_exceptions) if args.bootstrap_exceptions else {}
        built = read_built_cpvs(args.source_audit) if args.source_audit else None
        rows, prov_failures, unowned_all = provenance_check(
            disk_files, sysroot, entries, modified, exceptions, args.package_tree, built
        )
        owned_count = sum(1 for r in rows if r[1] in ("package", "modified"))
        allowlisted_count = sum(1 for r in rows if r[1] == "generated")
        bootstrap_count = sum(1 for r in rows if r[1] == "bootstrap")
        if args.provenance_report:
            rp = Path(args.provenance_report)
            rp.parent.mkdir(parents=True, exist_ok=True)
            with open(rp, "w") as f:
                f.write("path\tclass\towner\tbuilt-this-run\n")
                for r in rows:
                    f.write("\t".join(r) + "\n")

    for path in ([] if args.provenance else sorted(disk_files)):
        if path in owned_paths:
            owned_count += 1
        elif (path + ".bz2") in owned_paths:
            # File was installed as path.bz2 by portage and decompressed during
            # rootfs assembly (extract-packages.sh runs bunzip2 on man pages).
            # The portage CONTENTS entry uses the original .bz2 name.
            owned_count += 1
        elif is_allowlisted(path, allowlist):
            allowlisted_count += 1
        else:
            unowned_all.append(path)

    n_unowned = len(unowned_all)
    n_total = len(disk_files)

    report = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "syft_schema": schema_ver,
        "sysroot": sysroot,
        "summary": {
            "total_files": n_total,
            "owned": owned_count,
            "allowlisted": allowlisted_count,
            "unowned": n_unowned,
        },
        "unowned_files": unowned_all,
    }
    if args.provenance:
        report["summary"]["bootstrap"] = bootstrap_count
        report["provenance_failures"] = prov_failures

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    color_pass = "\033[0;32m"
    color_fail = "\033[0;31m"
    reset = "\033[0m"
    n_bad = n_unowned + len(prov_failures)
    status = "PASS" if n_bad == 0 else "FAIL"
    color = color_pass if n_bad == 0 else color_fail

    print(
        f"\n[check-unowned] {color}{status}{reset}: "
        f"{n_total} files — {owned_count} owned, {allowlisted_count} allowlisted, {n_unowned} unowned"
    )

    if n_unowned > 0:
        print("[check-unowned] Unowned files (add to allowlist or move to an ebuild):")
        for p in unowned_all:
            print(f"  {p}")

    if prov_failures:
        print("[check-unowned] Provenance failures:")
        for p in prov_failures:
            print(f"  {p}")

    print(f"[check-unowned] Report written to {args.output}")
    sys.exit(1 if n_bad > 0 else 0)


if __name__ == "__main__":
    main()
