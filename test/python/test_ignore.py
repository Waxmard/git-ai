"""Tests for git-ai ignore-pattern resolution."""

from __future__ import annotations

from pathlib import Path

from git_ai._ignore import (
    DEFAULT_EXCLUDES,
    IGNORE_FILENAME,
    load_ignore_patterns,
    to_pathspec_args,
)


def test_default_excludes_contains_common_lockfiles() -> None:
    assert "package-lock.json" in DEFAULT_EXCLUDES
    assert "yarn.lock" in DEFAULT_EXCLUDES
    assert "pnpm-lock.yaml" in DEFAULT_EXCLUDES
    assert "Cargo.lock" in DEFAULT_EXCLUDES
    assert "go.sum" in DEFAULT_EXCLUDES
    assert "uv.lock" in DEFAULT_EXCLUDES


def test_load_returns_defaults_when_no_ignore_file(tmp_path: Path) -> None:
    patterns = load_ignore_patterns(tmp_path)
    assert patterns == list(DEFAULT_EXCLUDES)


def test_load_appends_extra_patterns(tmp_path: Path) -> None:
    (tmp_path / IGNORE_FILENAME).write_text(
        "# comment line\n\nbuild/dist.js\nfoo/bar.lock\n",
        encoding="utf-8",
    )
    patterns = load_ignore_patterns(tmp_path)
    assert "build/dist.js" in patterns
    assert "foo/bar.lock" in patterns
    assert patterns[: len(DEFAULT_EXCLUDES)] == list(DEFAULT_EXCLUDES)


def test_load_negation_removes_default(tmp_path: Path) -> None:
    (tmp_path / IGNORE_FILENAME).write_text("!package-lock.json\n", encoding="utf-8")
    patterns = load_ignore_patterns(tmp_path)
    assert "package-lock.json" not in patterns
    assert "yarn.lock" in patterns


def test_load_negation_strips_added_pattern(tmp_path: Path) -> None:
    (tmp_path / IGNORE_FILENAME).write_text(
        "build/dist.js\n!build/dist.js\n", encoding="utf-8"
    )
    patterns = load_ignore_patterns(tmp_path)
    assert "build/dist.js" not in patterns


def test_load_dedupes(tmp_path: Path) -> None:
    (tmp_path / IGNORE_FILENAME).write_text(
        "package-lock.json\nfoo.txt\nfoo.txt\n", encoding="utf-8"
    )
    patterns = load_ignore_patterns(tmp_path)
    assert patterns.count("package-lock.json") == 1
    assert patterns.count("foo.txt") == 1


def test_load_ignores_blank_and_comment_lines(tmp_path: Path) -> None:
    (tmp_path / IGNORE_FILENAME).write_text(
        "\n  \n# only comments\n   # indented comment\nfoo.lock\n",
        encoding="utf-8",
    )
    patterns = load_ignore_patterns(tmp_path)
    assert "foo.lock" in patterns
    assert "# only comments" not in patterns


def test_to_pathspec_args_empty() -> None:
    assert to_pathspec_args(None) == []
    assert to_pathspec_args([]) == []


def test_to_pathspec_args_builds_excludes() -> None:
    args = to_pathspec_args(["package-lock.json", "yarn.lock"])
    assert args == [
        "--",
        ".",
        ":(exclude,top)package-lock.json",
        ":(exclude,top)yarn.lock",
    ]
