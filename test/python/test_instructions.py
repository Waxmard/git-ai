"""Tests for repo-local .git-ai-instructions loading and formatting."""

from __future__ import annotations

from pathlib import Path

from git_ai._instructions import (
    INSTRUCTIONS_FILENAME,
    format_repo_guidance,
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


def test_format_wraps_in_block() -> None:
    assert (
        format_repo_guidance("tag bump = chore.")
        == "<repo_guidance>\ntag bump = chore.\n</repo_guidance>"
    )


def test_format_empty_yields_empty_string() -> None:
    assert format_repo_guidance(None) == ""
    assert format_repo_guidance("") == ""
    assert format_repo_guidance("   \n") == ""
