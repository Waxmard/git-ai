"""Parse a PR commit log and decide two-pass vs fallback.

Reads git log output (produced with ``--format='%s%n%b%x1e'``) from stdin,
writes to stdout:

    yes|no                     # first line: use two-pass prompt?
    <draft body, if two-pass>  # remaining lines, may be empty

The two-pass path drafts a conventional-commit-style changelog body that the
LLM only has to polish; the fallback path sends the raw diff instead.
"""
from __future__ import annotations

import re
import sys
from argparse import ArgumentParser
from dataclasses import dataclass

_CONVENTIONAL_TYPES = {
    "feat", "fix", "refactor", "docs", "chore",
    "ci", "test", "style", "perf", "build",
}

_SECTIONS: list[tuple[str, str]] = [
    ("Features", "feat"),
    ("Bug Fixes", "fix"),
    ("Refactors", "refactor"),
    ("Docs", "docs"),
    ("Chores", "chore"),
    ("Continuous Integration", "ci"),
    ("Tests", "test"),
    ("Style", "style"),
    ("Performance", "perf"),
    ("Build", "build"),
]

# Matches `type` or `type(scope)` or `type!` etc. — captures the leading type.
_TYPE_RE = re.compile(r"^([a-zA-Z]+)(?:\([^)]*\))?!?:\s*(.*)$")


@dataclass
class Analysis:
    two_pass: bool
    draft_body: str


def _parse_commits(log: str) -> list[tuple[str, str, list[str]]]:
    entries: list[tuple[str, str, list[str]]] = []
    for block in log.split("\x1e"):
        block = block.strip("\n")
        if not block:
            continue
        lines = block.splitlines()
        subject = lines[0]
        body = [ln for ln in lines[1:] if ln]
        m = _TYPE_RE.match(subject)
        if m:
            t = m.group(1)
            desc = m.group(2)
        else:
            t = ""
            desc = subject
        entries.append((t, desc, body))
    return entries


def analyze(log: str) -> Analysis:
    commits = _parse_commits(log)
    total = len(commits)
    conv = sum(1 for t, _, _ in commits if t in _CONVENTIONAL_TYPES)
    two_pass = total > 0 and conv * 2 >= total

    parts: list[str] = []
    if two_pass:
        for header, t in _SECTIONS:
            section: list[str] = []
            for ct, desc, body in commits:
                if ct != t:
                    continue
                section.append(f"- {desc}")
                section.extend(f"  {b}" for b in body)
            if section:
                parts.append(f"### {header}\n" + "\n".join(section) + "\n")

    return Analysis(two_pass=two_pass, draft_body="\n".join(parts))


def main(argv: list[str] | None = None) -> int:
    ArgumentParser(prog="git_ai._pr_draft").parse_args(argv)
    result = analyze(sys.stdin.read())
    sys.stdout.write("yes\n" if result.two_pass else "no\n")
    sys.stdout.write(result.draft_body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
