"""Repo-local guidance: the repo-root ``.git-ai-instructions`` file.

A free-form prose file checked into a repository to teach git-ai about that
repo's conventions — commit scopes, type-classification overrides, and any
other house rules the global prompt heuristics can't know. Its contents are
injected verbatim into the commit and PR prompts inside a ``<repo_guidance>``
block; the prompts treat it as authoritative when it conflicts with their
default heuristics. Sibling to ``.git-ai-ignore`` (see :mod:`_ignore`).
"""

from __future__ import annotations

from pathlib import Path

INSTRUCTIONS_FILENAME = ".git-ai-instructions"


def load_repo_instructions(repo_path: str | Path) -> str | None:
    """Return the repo's ``.git-ai-instructions`` contents, or ``None``.

    Reads the repo-root file, strips surrounding whitespace, and returns the
    text. Returns ``None`` when the file is absent, empty, or unreadable so
    callers can skip the guidance block entirely.
    """
    path = Path(repo_path) / INSTRUCTIONS_FILENAME
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return text or None


def format_repo_guidance(text: str | None) -> str:
    """Wrap repo guidance in a ``<repo_guidance>`` block, or return ``""``.

    Empty/``None`` input yields an empty string so callers can splat it into a
    prompt unconditionally without emitting an empty tag.
    """
    if not text or not text.strip():
        return ""
    return f"<repo_guidance>\n{text.strip()}\n</repo_guidance>"
