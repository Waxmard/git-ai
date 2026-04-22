"""Render a compact diff between cached and regenerated PR text.

Runs standalone (invoked by bin/git-ai as a script) or importable as
``git_ai._pr_render.render_pr_diff``.
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
    """Render a user-facing diff between two PR texts.

    Uses prefixes so every emitted content line has the same leading width:
      ``  `` (two spaces) for context, ``~ `` for a line that replaced an
      old one, ``+ `` for a pure addition, ``- `` for a pure removal. Hunk
      headers (``@@ ... @@``) pass through verbatim.

    ANSI color is applied to change lines only when ``color`` is True.
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


def _color_enabled() -> bool:
    """Respect an explicit override; otherwise honour stdout isatty()."""
    forced = os.environ.get("GIT_AI_FORCE_COLOR")
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

    existing = Path(args.existing).read_text(encoding="utf-8")
    updated = Path(args.updated).read_text(encoding="utf-8")

    color = _color_enabled()

    # No prior PR or non-interactive stdout: emit the updated text verbatim.
    if not existing.strip() or not color:
        sys.stdout.write(updated)
        return 0

    if existing == updated:
        sys.stderr.write(
            "git-ai: regenerated PR is unchanged; no diff changes to show\n"
        )
        sys.stdout.write(updated)
        return 0

    sys.stdout.write(render_pr_diff(existing, updated, color=color))
    return 0


if __name__ == "__main__":
    sys.exit(main())
