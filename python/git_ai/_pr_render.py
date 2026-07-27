"""Render PR-update output for ``git-ai pr``.

Runs standalone (invoked by bin/git-ai as a script) or importable as
``git_ai._pr_render.render_pr_diff`` / ``summarize_pr_changes``.
"""

from __future__ import annotations

import difflib
import os
import sys
from argparse import ArgumentParser
from pathlib import Path

_GREEN = "\033[32m"
_RED = "\033[31m"
_RESET = "\033[m"


def _color(text: str, code: str, enabled: bool) -> str:
    if not enabled:
        return text
    return f"{code}{text}{_RESET}"


def render_pr_diff(existing: str, updated: str, *, color: bool) -> str:
    """Render a unified diff between two PR texts.

    Prefixes are equal-width so content stays aligned: ``  `` context, ``~ ``
    replaced line, ``+ `` pure addition, ``- `` pure removal. Hunk headers
    pass through verbatim.
    """
    a = existing.splitlines()
    b = updated.splitlines()
    raw = list(difflib.unified_diff(a, b, n=9999, lineterm=""))

    out: list[str] = []
    minus: list[str] = []
    plus: list[str] = []

    def flush() -> None:
        pairs = min(len(minus), len(plus))
        for k in range(pairs):
            out.append(_color(f"~ {plus[k]}", _GREEN, color))
        for k in range(pairs, len(minus)):
            out.append(_color(f"- {minus[k]}", _RED, color))
        for k in range(pairs, len(plus)):
            out.append(_color(f"+ {plus[k]}", _GREEN, color))
        minus.clear()
        plus.clear()

    seen_hunk = False
    for line in raw:
        if line.startswith("--- ") or line.startswith("+++ "):
            continue
        if line.startswith("@@ "):
            flush()
            seen_hunk = True
            out.append(line)
            continue
        if not seen_hunk:
            continue
        if line.startswith("-"):
            minus.append(line[1:])
        elif line.startswith("+"):
            plus.append(line[1:])
        else:
            flush()
            content = line[1:] if line.startswith(" ") else line
            out.append(f"  {content}")
    flush()

    if not out:
        return ""
    return "\n".join(out) + "\n"


_INTRO = "_intro"


def _parse_sections(text: str) -> dict[str, list[str]]:
    """Group non-blank lines by ``### Heading``, order preserved.

    Lines before the first heading (title, preamble) land in ``_INTRO``.
    """
    sections: dict[str, list[str]] = {_INTRO: []}
    current = _INTRO
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("### "):
            current = line[4:].strip()
            sections.setdefault(current, [])
            continue
        stripped = line.strip()
        if stripped:
            sections.setdefault(current, []).append(stripped)
    return sections


def summarize_pr_changes(existing: str, updated: str) -> str:
    """Return a markdown-safe summary of per-section net additions/removals.

    A bulleted list safe to prepend above the updated body — no diff prefixes
    that would break markdown when copy-pasted. Comparison is set-based, so
    reordering and duplicate lines yield no delta and ``existing != updated``
    can still summarize to empty.
    """
    if not existing.strip() or existing == updated:
        return ""

    old = _parse_sections(existing)
    new = _parse_sections(updated)

    ordered: list[str] = list(new.keys())
    ordered.extend(name for name in old if name not in new)

    parts: list[str] = []
    for name in ordered:
        old_set = set(old.get(name, []))
        new_set = set(new.get(name, []))
        added = len(new_set - old_set)
        removed = len(old_set - new_set)
        if added == 0 and removed == 0:
            continue
        delta: list[str] = []
        if added:
            delta.append(f"+{added}")
        if removed:
            delta.append(f"-{removed}")
        label = "Title / intro" if name == _INTRO else name
        parts.append(f"- {label}: {' / '.join(delta)}")

    if not parts:
        return ""
    return "**Changes since previous draft**\n\n" + "\n".join(parts) + "\n"


def _is_interactive() -> bool:
    """Honor ``GIT_AI_FORCE_INTERACTIVE`` (test hook); otherwise check isatty()."""
    forced = os.environ.get("GIT_AI_FORCE_INTERACTIVE")
    if forced == "1":
        return True
    if forced == "0":
        return False
    return sys.stdout.isatty()


def main(argv: list[str] | None = None) -> int:
    parser = ArgumentParser(prog="git_ai._pr_render")
    parser.add_argument("existing", help="Path to cached PR text")
    parser.add_argument("updated", help="Path to updated PR text")
    args = parser.parse_args(argv)

    try:
        existing = Path(args.existing).read_text(encoding="utf-8")
        updated = Path(args.updated).read_text(encoding="utf-8")

        if not existing.strip() or not _is_interactive():
            sys.stdout.write(updated)
            return 0

        if existing == updated:
            sys.stderr.write(
                "git-ai: regenerated PR is unchanged; no changes to show\n"
            )
            sys.stdout.write(updated)
            return 0

        summary = summarize_pr_changes(existing, updated)
        if summary:
            sys.stdout.write(summary + "\n---\n\n")
        sys.stdout.write(updated)
        return 0
    except (RuntimeError, ValueError, OSError) as exc:
        sys.stderr.write(f"git-ai: {exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
