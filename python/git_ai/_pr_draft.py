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
    "feat",
    "fix",
    "refactor",
    "docs",
    "chore",
    "ci",
    "test",
    "style",
    "perf",
    "build",
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

# Header for the trailing block of commits that only refine code introduced
# earlier in the same branch. The prompt instructs the model to fold these into
# the section they refine rather than emit them as their own section.
_CHURN_HEADER = "Intra-branch refinements"

# Matches `type` or `type(scope)` or `type!` etc. — captures the leading type.
_TYPE_RE = re.compile(r"^([a-zA-Z]+)(?:\([^)]*\))?!?:\s*(.*)$")


@dataclass
class Analysis:
    two_pass: bool
    draft_body: str


def _parse_commits(log: str) -> list[tuple[str, str, str, list[str]]]:
    entries: list[tuple[str, str, str, list[str]]] = []
    for block in log.split("\x1e"):
        stripped = block.strip("\n")
        if not stripped:
            continue
        lines = stripped.splitlines()
        subject = lines[0]
        body = [ln for ln in lines[1:] if ln]
        m = _TYPE_RE.match(subject)
        if m:
            t = m.group(1)
            desc = m.group(2)
        else:
            t = ""
            desc = subject
        entries.append((subject, t, desc, body))
    return entries


def analyze(log: str, churn_subjects: set[str] | None = None) -> Analysis:
    """Decide two-pass vs fallback and draft a grouped changelog body.

    When ``churn_subjects`` is supplied, any commit whose subject matches is
    pulled out of its type section and listed under a trailing
    ``### Intra-branch refinements`` block, signalling the model to fold its net
    effect into the section it refines instead of emitting a standalone section.
    """
    commits = _parse_commits(log)
    total = len(commits)
    conv = sum(1 for _, t, _, _ in commits if t in _CONVENTIONAL_TYPES)
    two_pass = total > 0 and conv * 2 >= total
    churn = churn_subjects or set()

    parts: list[str] = []
    if two_pass:
        churn_bullets: list[str] = []
        for header, t in _SECTIONS:
            section: list[str] = []
            for subject, ct, desc, body in commits:
                if ct != t:
                    continue
                target = churn_bullets if subject in churn else section
                target.append(f"- {desc}")
                target.extend(f"  {b}" for b in body)
            if section:
                parts.append(f"### {header}\n" + "\n".join(section) + "\n")
        if churn_bullets:
            parts.append(f"### {_CHURN_HEADER}\n" + "\n".join(churn_bullets) + "\n")

    return Analysis(two_pass=two_pass, draft_body="\n".join(parts))


def main(argv: list[str] | None = None) -> int:
    ArgumentParser(prog="git_ai._pr_draft").parse_args(argv)
    result = analyze(sys.stdin.read())
    sys.stdout.write("yes\n" if result.two_pass else "no\n")
    sys.stdout.write(result.draft_body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
