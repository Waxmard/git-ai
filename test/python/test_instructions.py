"""Tests for repo-local .git-ai-instructions loading and formatting."""

from __future__ import annotations

from pathlib import Path

from git_ai._instructions import (
    INSTRUCTIONS_FILENAME,
    load_repo_instructions,
)


def test_load_returns_none_when_absent(tmp_path: Path) -> None:
    assert load_repo_instructions(tmp_path) is None


def test_load_returns_none_when_empty(tmp_path: Path) -> None:
    (tmp_path / INSTRUCTIONS_FILENAME).write_text("   \n\n", encoding="utf-8")
    assert load_repo_instructions(tmp_path) is None


def test_load_strips_surrounding_whitespace(tmp_path: Path) -> None:
    (tmp_path / INSTRUCTIONS_FILENAME).write_text(
        "\n  Scopes: a, b.\ntag bump = chore.\n\n", encoding="utf-8"
    )
    assert load_repo_instructions(tmp_path) == "Scopes: a, b.\ntag bump = chore."


def test_load_returns_none_when_non_utf8(tmp_path: Path) -> None:
    # A smart-quote in latin-1 (0x92) is invalid UTF-8; must not crash.
    (tmp_path / INSTRUCTIONS_FILENAME).write_bytes(b"Scopes: don\x92t crash.")
    assert load_repo_instructions(tmp_path) is None
