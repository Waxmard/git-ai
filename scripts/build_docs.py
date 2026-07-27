#!/usr/bin/env python3
"""Render top-level docs from templates in docs/src/.

Templates may pull shared prose in via ``{{ include:partials/<name>.md }}``
directives. A single template can render to multiple outputs (CLAUDE.md is
emitted as both CLAUDE.md and AGENTS.md so AI agents stay in lockstep).

Usage:
    build_docs.py --write    # render every template to its output(s)
    build_docs.py --check    # exit non-zero if any generated file is stale
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC = REPO_ROOT / "docs" / "src"

# template (relative to SRC) -> output paths (relative to REPO_ROOT).
# CLAUDE.md and AGENTS.md are thin per-agent headers that both include
# partials/guide-body.md, so the shared guidance stays in lockstep while each
# keeps its own audience-appropriate framing.
TEMPLATES: dict[str, list[str]] = {
    "README.md": ["README.md"],
    "CLAUDE.md": ["CLAUDE.md"],
    "AGENTS.md": ["AGENTS.md"],
    "CONTRIBUTING.md": ["CONTRIBUTING.md"],
    "python-CLAUDE.md": ["python/CLAUDE.md"],
    "python-AGENTS.md": ["python/AGENTS.md"],
    "test-CLAUDE.md": ["test/CLAUDE.md"],
    "test-AGENTS.md": ["test/AGENTS.md"],
}

INCLUDE_RE = re.compile(r"\{\{\s*include:([^\s}]+)\s*\}\}")
MAX_PASSES = 10


def _header(template: str) -> str:
    return (
        f"<!-- Generated from docs/src/{template} by scripts/build_docs.py. "
        "Run `make docs-build` to regenerate. Do not edit directly. -->\n\n"
    )


def _sub(match: re.Match[str]) -> str:
    resolved = (SRC / match.group(1)).resolve()
    if not resolved.is_relative_to(SRC.resolve()):
        raise SystemExit(f"error: include escapes docs/src/: {match.group(1)}")
    partial = resolved.read_text(encoding="utf-8")
    return partial.strip()


def render(template: str) -> str:
    """Expand a template's include directives, resolving nested includes."""
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
    return _header(template) + text


def main(argv: list[str]) -> int:
    if argv == ["--write"]:
        for template, outputs in TEMPLATES.items():
            if not (SRC / template).exists():
                print(f"skipping {template} (source not present)")
                continue
            rendered = render(template)
            for out in outputs:
                (REPO_ROOT / out).write_text(rendered, encoding="utf-8")
                print(f"wrote {out}")
        return 0

    if argv == ["--check"]:
        stale: list[str] = []
        for template, outputs in TEMPLATES.items():
            if not (SRC / template).exists():
                print(f"skipping {template} (source not present)")
                continue
            rendered = render(template)
            for out in outputs:
                path = REPO_ROOT / out
                current = path.read_text(encoding="utf-8") if path.exists() else None
                if current != rendered:
                    stale.append(out)
        if stale:
            print("Stale generated docs (run `make docs-build`):", file=sys.stderr)
            for out in stale:
                print(f"  - {out}", file=sys.stderr)
            return 1
        print("docs up to date")
        return 0

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
