#!/usr/bin/env python3
"""Render LLM prompts from templates in prompts/src/.

Templates pull shared prose in via ``{{ include:partials/<name>.txt }}``
directives so wording that must stay in lockstep across prompts lives once.

Unlike scripts/build_docs.py, NO header comment is prepended: a generated
prompt is fed verbatim to an LLM, so any extra text would alter behavior.

Usage:
    build_prompts.py --write    # render every template to its output
    build_prompts.py --check    # exit non-zero if any generated file is stale
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC = REPO_ROOT / "prompts" / "src"
OUT = REPO_ROOT / "python" / "git_ai" / "prompts"

# commit.txt is deliberately absent — it shares no verbatim text with the PR
# prompts, so it's edited directly in python/git_ai/prompts/.
TEMPLATES: dict[str, str] = {
    "pr-two-pass.txt": "pr-two-pass.txt",
    "pr-two-pass-update.txt": "pr-two-pass-update.txt",
    "pr-fallback.txt": "pr-fallback.txt",
    "pr-fallback-update.txt": "pr-fallback-update.txt",
}

INCLUDE_RE = re.compile(r"\{\{\s*include:([^\s}]+)\s*\}\}")
MAX_PASSES = 10


def _sub(match: re.Match[str]) -> str:
    resolved = (SRC / match.group(1)).resolve()
    if not resolved.is_relative_to(SRC.resolve()):
        raise SystemExit(f"error: include escapes prompts/src/: {match.group(1)}")
    return resolved.read_text(encoding="utf-8").strip()


def render(template: str) -> str:
    text = (SRC / template).read_text(encoding="utf-8")
    for _ in range(MAX_PASSES):
        if not INCLUDE_RE.search(text):
            break
        text = INCLUDE_RE.sub(_sub, text)
    else:
        raise SystemExit(
            f"error: {template} still has includes after {MAX_PASSES} passes "
            "(circular include?)"
        )
    return text


def main(argv: list[str]) -> int:
    if argv == ["--write"]:
        for template, out in TEMPLATES.items():
            (OUT / out).write_text(render(template), encoding="utf-8")
            print(f"wrote {out}")
        return 0

    if argv == ["--check"]:
        stale: list[str] = []
        for template, out in TEMPLATES.items():
            path = OUT / out
            current = path.read_text(encoding="utf-8") if path.exists() else None
            if current != render(template):
                stale.append(out)
        if stale:
            print("Stale generated prompts (run `make prompts-build`):", file=sys.stderr)
            for out in stale:
                print(f"  - {out}", file=sys.stderr)
            return 1
        print("prompts up to date")
        return 0

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
