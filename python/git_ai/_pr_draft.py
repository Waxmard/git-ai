"""Draft a conventional-commit changelog body from a GITAI_COMMIT-prefixed log."""

from __future__ import annotations

import re

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


_PREFIX = "GITAI_COMMIT "


def _parse_commits(log: str) -> list[tuple[str, str, str, list[str]]]:
    entries: list[tuple[str, str, str, list[str]]] = []
    for line in log.splitlines():
        if line.startswith(_PREFIX):
            subject = line[len(_PREFIX) :]
            m = _TYPE_RE.match(subject)
            t, desc = (m.group(1), m.group(2)) if m else ("", subject)
            entries.append((subject, t, desc, []))
        elif entries and line:
            entries[-1][3].append(line)
    return entries


def draft_body(log: str, churn_subjects: set[str] | None = None) -> str:
    """Draft a grouped changelog body.

    When ``churn_subjects`` is supplied, any commit whose subject matches is
    pulled out of its type section and listed under a trailing
    ``### Intra-branch refinements`` block, signalling the model to fold its net
    effect into the section it refines instead of emitting a standalone section.
    """
    commits = _parse_commits(log)
    churn = churn_subjects or set()

    parts: list[str] = []
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

    return "\n".join(parts)
