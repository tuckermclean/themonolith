"""Role guard for The Monolith's coding agents. Adapted from strange-company's .claude/hooks/guard.py.

Invoked as a PreToolUse hook from the role subagents in .claude/agents/:

    python3 -I "$CLAUDE_PROJECT_DIR/.claude/hooks/guard.py" <tester|implementer|reviewer>

and, for every session in this repository, from .claude/settings.json with the role `session`:
agents never merge, approve or change repository settings on GitHub. The owner merges.

It reads the hook JSON on stdin and exits 2 (with the reason on stderr) to block a call. It is a
guardrail for cooperative agents, not enforcement; review is the enforcement. Development tooling:
it ships in no image and never reaches the disc.
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import sys

# Where tests and their fixtures live (the predecessor's layout, SPEC §7).
TEST_PATHS = ["scripts/tests/**", "scripts/fixtures/**", "**/fixtures/**", "**/testdata/**"]
# Never edited by a role agent: the owner or the orchestrating session owns these.
ROLE_FORBIDDEN = ["SPEC.md", "MYTH.md", "AGENTS.md", "CLAUDE.md", "LICENSE", "docs/graph.yaml",
                  "nodes/**", "docs/study/**", "docs/reviews/**", ".claude/**", "toolbox/**"]
HISTORY_REWRITE = re.compile(r"\bgit\s+(push|rebase|filter-branch|filter-repo)\b|"
                             r"\bgit\s+reset\s+--hard\b|\bgit\s+commit\b[^|;&]*--amend\b|"
                             r"--no-verify\b")
# Agents open PRs; only the owner approves and merges.
GH_FORBIDDEN = re.compile(r"\bgh\s+(pr\s+(merge|review)|repo\s+(edit|delete|rename|archive)|"
                          r"release\s+(create|delete|edit)|secret|variable|ruleset)\b|"
                          r"\bgh\s+api\b[^|;&]*(/merge\b|/reviews\b|/protection\b|/rulesets\b|"
                          r"mergePullRequest|addPullRequestReview|enablePullRequestAutoMerge)")
# Shell writes into ROLE_FORBIDDEN paths. Heuristic: redirect targets and the operands of file-writing commands.
REDIRECT = re.compile(r"(?<![<>&\d])\d*>>?\|?\s*([^\s;&|<>()]+)")
WRITE_CMDS = re.compile(r"^(?:sudo\s+)?(?:env\s+(?:\S+=\S*\s+)*)?(cp|mv|tee|rm|rmdir|touch|mkdir|ln|install|"
                        r"truncate|chmod|chown|dd|rsync|unzip|tar|patch)\b")
SED_INPLACE = re.compile(r"^(?:sudo\s+)?sed\b.*\s-[a-zA-Z]*i")
GIT_WRITES = re.compile(r"^git\s+(?:-C\s+\S+\s+)?(checkout|restore|apply|am|cherry-pick|revert|mv|rm|"
                        r"update-index|stash)\b")
PY_WRITE = re.compile(r"""open\(\s*['"]([^'"]+)['"]\s*,\s*['"][wax]|Path\(\s*['"]([^'"]+)['"]\s*\)\s*\."""
                      r"""(write_text|write_bytes|unlink|rename|replace|touch|mkdir)""")


def match(path: str, patterns: list[str]) -> bool:
    for p in patterns:
        if fnmatch.fnmatchcase(path, p):
            return True
        if p.startswith("**/") and fnmatch.fnmatchcase(path, p[3:]):
            return True
    return False


def deny(reason: str) -> None:
    sys.stderr.write(f"monolith-guard: {reason}\n")
    sys.exit(2)


def rel(root: str, path: str) -> str:
    return os.path.relpath(os.path.abspath(os.path.join(root, path)), root).replace(os.sep, "/")


def staged(root: str) -> list[tuple[int, int, str]]:
    out = subprocess.run(["git", "-C", root, "diff", "--cached", "--numstat"],
                         capture_output=True, text=True, check=False).stdout
    rows = []
    for line in out.splitlines():
        a, d, p = line.split("\t", 2)
        rows.append((int(a) if a != "-" else 0, int(d) if d != "-" else 0, p))
    return rows


def forbidden_shell_write(cmd: str, root: str) -> str | None:
    """Return a ROLE_FORBIDDEN path the command appears to write, or None."""
    def bad(token: str) -> bool:
        token = token.strip("'\"")
        if not token or token.startswith("-") or token.startswith("/dev/"):
            return False
        path = rel(root, token)
        if path.startswith("../"):
            return False
        # A whole directory (`rm -rf nodes`, `cp -t .claude/ x`) counts as writing below it.
        return match(path, ROLE_FORBIDDEN) or match(path.rstrip("/") + "/x", ROLE_FORBIDDEN)

    for target in REDIRECT.findall(cmd):
        if bad(target):
            return target
    for m in PY_WRITE.finditer(cmd):
        target = m.group(1) or m.group(2)
        if bad(target):
            return target
    for simple in re.split(r"&&|\|\||[;|\n]", cmd):
        simple = simple.strip().lstrip("(").strip()
        if WRITE_CMDS.match(simple) or SED_INPLACE.match(simple) or GIT_WRITES.match(simple):
            for token in simple.split()[1:]:
                if bad(token):
                    return token
    return None


def check_commit(role: str, root: str) -> None:
    rows = staged(root)
    for _added, _deleted, path in rows:
        if match(path, ROLE_FORBIDDEN):
            deny(f"{role} may not commit {path} (owner- or orchestrator-owned path)")
    if role == "tester":
        for _added, _deleted, path in rows:
            if not match(path, TEST_PATHS):
                deny(f"a RED commit may change only test paths {TEST_PATHS}; {path} is not one")
    if role == "implementer":
        for _added, deleted, path in rows:
            if match(path, TEST_PATHS) and deleted > 0:
                deny(f"implementer may not modify existing test file {path} after RED. "
                     "Report a test/spec conflict instead.")


def main() -> None:
    role = sys.argv[1] if len(sys.argv) > 1 else ""
    if role not in ("tester", "implementer", "reviewer", "session"):
        deny(f"unknown role {role!r}")
    ev = json.load(sys.stdin)
    root = os.environ.get("CLAUDE_PROJECT_DIR") or ev.get("cwd") or os.getcwd()
    tool, ti = ev.get("tool_name", ""), ev.get("tool_input") or {}

    if role == "session":
        if tool == "Bash" and GH_FORBIDDEN.search(ti.get("command", "")):
            deny("agents never merge, approve or change repository settings on GitHub; the owner does")
        return

    if tool in ("Edit", "Write", "NotebookEdit"):
        if role == "reviewer":
            deny("the reviewer does not modify files")
        path = rel(root, ti.get("file_path") or ti.get("notebook_path") or "")
        if path.startswith("../"):
            deny(f"{path} is outside the repository")
        if match(path, ROLE_FORBIDDEN):
            deny(f"{role} may not edit {path} (owner- or orchestrator-owned path)")
        if role == "tester" and not match(path, TEST_PATHS):
            deny(f"tester may edit only test paths {TEST_PATHS}; {path} is not one")
        if role == "implementer" and match(path, TEST_PATHS) and os.path.exists(os.path.join(root, path)):
            deny(f"implementer may not edit existing test file {path}; tests are fixed at RED. "
                 "If the test is wrong, stop and report TEST_SPEC_CONFLICT.")
        return

    if tool == "Bash":
        cmd = ti.get("command", "")
        if re.search(r"(^|[\s;&|(])gh\s", cmd):
            deny("role agents do not use gh; the orchestrator opens PRs")
        if HISTORY_REWRITE.search(cmd):
            deny("role agents do not push or rewrite history; the orchestrator pushes")
        if role == "reviewer" and re.search(r"\bgit\s+(commit|add|checkout\s+-b|switch\s+-c|stash)\b", cmd):
            deny("the reviewer does not change the repository")
        if role in ("tester", "implementer"):
            hit = forbidden_shell_write(cmd, root)
            if hit:
                deny(f"{role} may not write {hit} through the shell (owner- or orchestrator-owned path)")
        if re.search(r"\bgit\s+commit\b", cmd):
            # The guard inspects the index before the command runs, so staging must already be done.
            if re.search(r"\bgit\s+commit\b[^|;&]*(\s-[a-zA-Z]*a[a-zA-Z]*\b|--all\b)", cmd) or re.search(r"\bgit\s+(add|rm|mv)\b", cmd):
                deny("stage with `git add` in a separate command, then run `git commit` without -a")
            check_commit(role, root)


if __name__ == "__main__":
    main()
