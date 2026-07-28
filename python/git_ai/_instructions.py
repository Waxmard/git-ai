"""Repo-local guidance: the repo-root ``.git-ai-instructions`` file.

Free-form prose teaching git-ai a repo's house rules (commit scopes,
type-classification overrides). Injected verbatim into the commit and PR
prompts as a ``<repo_guidance>`` block, which the prompts treat as
authoritative over their default heuristics.
"""

from __future__ import annotations

from pathlib import Path

INSTRUCTIONS_FILENAME = ".git-ai-instructions"


def load_repo_instructions(repo_path: str | Path) -> str | None:
    """Return the repo's ``.git-ai-instructions`` contents, stripped.

    ``None`` when absent, empty, or unreadable, so callers can skip the block.
    """
    path = Path(repo_path) / INSTRUCTIONS_FILENAME
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return None
    return text or None


def format_repo_guidance(text: str | None) -> str:
    """Wrap repo guidance in a ``<repo_guidance>`` block.

    Empty/``None`` yields ``""`` so callers can splat it into a prompt
    unconditionally without emitting an empty tag.
    """
    if not text or not text.strip():
        return ""
    return f"<repo_guidance>\n{text.strip()}\n</repo_guidance>"
