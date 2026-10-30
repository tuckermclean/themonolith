#!/usr/bin/env python3
"""Check docs/migration.tsv, the file-level migration ledger.

    scripts/check-migration.py [--node <ID> | --all]

Always: one row per predecessor file, and the rows rebuild the predecessor's git tree at b9f533b
(mode, path and blob of every file), so a missing, extra or altered row fails without fetching the
predecessor. Each row names a node of docs/graph.yaml (or `-`), a disposition and a destination.
Wherever a port or port+fix destination exists, its mode (from the git index, else the file) equals
the row's; a `port` row that no later node changes must also hold the row's blob.

--node <ID>: run when that node lands. Every port or port+fix row of the node is at its destination
             with the row's mode, and every `port` row of the node holds the row's blob.
--all:       every port or port+fix row is at its final path (the last move in `then`, else `dest`)
             with the row's mode.

Standard library only; prints PROBLEMS <n> and exits non-zero when n > 0.
"""
import hashlib
import os
import re
import subprocess
import sys

TREE = "d12a8f4243ff1fbb755d387001bdca3fb685747c"
DISPOSITIONS = {"port", "port+fix", "replace", "drop"}
ROOT = os.environ.get("MONOLITH_ROOT") or subprocess.run(
    ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True,
    cwd=os.path.dirname(os.path.abspath(__file__))).stdout.strip()
LEDGER = os.environ.get("MONOLITH_MIGRATION", os.path.join(ROOT, "docs", "migration.tsv"))

problems = []


def problem(msg):
    problems.append(msg)
    print("PROBLEM", msg)


def index_modes():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-s", "-z"], capture_output=True, check=True).stdout
    modes = {}
    for entry in out.split(b"\0"):
        if entry:
            meta, path = entry.split(b"\t", 1)
            modes[path.decode()] = meta.split()[0].decode()
    return modes


def file_mode(rel, modes):
    if rel in modes:
        return modes[rel]
    full = os.path.join(ROOT, rel)
    if os.path.islink(full):
        return "120000"
    return "100755" if os.access(full, os.X_OK) else "100644"


def git_blob(path):
    data = open(path, "rb").read()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def tree_hash(files):
    root = {}
    for path, mode, blob in files:
        parts = path.split("/")
        d = root
        for p in parts[:-1]:
            d = d.setdefault(p, {})
            if not isinstance(d, dict):
                return None
        d[parts[-1]] = (mode, blob)

    def build(d):
        entries = []
        for name, v in d.items():
            if isinstance(v, dict):
                entries.append((name + "/", b"40000 " + name.encode() + b"\0" + bytes.fromhex(build(v))))
            else:
                entries.append((name, v[0].encode() + b" " + name.encode() + b"\0" + bytes.fromhex(v[1])))
        body = b"".join(e for _, e in sorted(entries, key=lambda x: x[0].encode()))
        return hashlib.sha1(b"tree %d\0" % len(body) + body).hexdigest()

    return build(root)


def final_path(row):
    path = row["dest"]
    for t in row["then"]:
        if ":" in t:
            path = t.split(":", 1)[1]
    return path


def main(argv):
    node = argv[argv.index("--node") + 1] if "--node" in argv else None
    want_all = "--all" in argv
    graph = open(os.path.join(ROOT, "docs", "graph.yaml")).read()
    nodes = set(re.findall(r"\bid: ([A-Z]\d\d)\b", graph))
    if node and node not in nodes:
        problem(f"--node {node}: not in docs/graph.yaml")

    rows, seen = [], set()
    for n, line in enumerate(open(LEDGER, encoding="utf-8"), 1):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) != 7:
            problem(f"line {n}: {len(f)} fields, want 7")
            continue
        path, mode, blob, owner, disp, dest, then = f
        row = {"path": path, "mode": mode, "blob": blob, "node": owner, "disp": disp, "dest": dest,
               "then": [] if then == "-" else then.split(), "line": n}
        if path in seen:
            problem(f"line {n}: {path} listed twice")
        seen.add(path)
        if mode not in ("100644", "100755", "120000"):
            problem(f"line {n}: mode {mode}")
        if not re.fullmatch(r"[0-9a-f]{40}", blob):
            problem(f"line {n}: blob {blob!r}")
        if disp not in DISPOSITIONS:
            problem(f"line {n}: disposition {disp!r}")
        if owner != "-" and owner not in nodes:
            problem(f"line {n}: node {owner} not in docs/graph.yaml")
        if owner == "-" and disp != "drop" and not (disp == "port" and dest == path):
            problem(f"line {n}: only a drop, or a file already here unchanged, has no node")
        if (dest == "-") != (disp in ("drop", "replace")):
            problem(f"line {n}: {disp} with dest {dest!r}")
        for t in row["then"]:
            if t.split(":", 1)[0] not in nodes:
                problem(f"line {n}: then {t!r} names no node")
        rows.append(row)

    got = tree_hash([(r["path"], r["mode"], r["blob"]) for r in rows])
    if got != TREE:
        problem(f"rows rebuild tree {got}, want {TREE}: a predecessor file is missing, extra or altered")

    modes = index_modes()
    for r in rows:
        if r["disp"] not in ("port", "port+fix"):
            continue
        n = r["line"]
        mine = node is not None and r["node"] == node
        for rel in dict.fromkeys((r["dest"], final_path(r))):
            full = os.path.join(ROOT, rel)
            if os.path.lexists(full) and file_mode(rel, modes) != r["mode"]:
                problem(f"line {n}: {rel} has mode {file_mode(rel, modes)}, want {r['mode']}")
        dest = os.path.join(ROOT, r["dest"])
        if os.path.isfile(dest) and r["disp"] == "port" and (not r["then"] or mine) \
                and git_blob(dest) != r["blob"]:
            problem(f"line {n}: {r['dest']} differs from {r['path']} at b9f533b; "
                    "a changed port is port+fix, or names the node that changes it")
        if mine and not os.path.lexists(dest):
            problem(f"line {n}: {node} has not ported {r['path']} to {r['dest']}")
        if want_all and not os.path.lexists(os.path.join(ROOT, final_path(r))):
            problem(f"line {n}: {final_path(r)} missing")

    print(f"migration: {len(rows)} rows, tree {'ok' if got == TREE else 'MISMATCH'}")
    print(f"PROBLEMS {len(problems)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
