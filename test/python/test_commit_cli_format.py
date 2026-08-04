"""Tests for the `_commit_cli.py format` / `_pr_repo_cli.py format` bridges.

These replace the deleted bash mirrors — the shell now pipes raw provider
output through these subcommands, so their stdout/exit contract is what
`bin/git-ai` depends on.
"""

from __future__ import annotations

import io
from pathlib import Path

import pytest
from git_ai import _commit_cli, _pr_repo_cli


def _run_format(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    raw: str,
    note_file: Path | None = None,
) -> tuple[str, str]:
    monkeypatch.setattr("sys.stdin", io.StringIO(raw))
    argv = ["format"]
    if note_file is not None:
        argv += ["--note-file", str(note_file)]
    assert _commit_cli.main(argv) == 0
    out = capsys.readouterr().out
    note = note_file.read_text(encoding="utf-8") if note_file is not None else ""
    return out, note


def test_format_strips_fences_marker_and_trailer(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    raw = (
        "```\n===COMMIT===\nfeat: add the picker\n\nBody line.\n\n"
        "Co-Authored-By: Someone <a@b.c>\n```"
    )
    out, _ = _run_format(monkeypatch, capsys, raw)
    assert out == "feat: add the picker\n\nBody line."


def test_format_wraps_the_body(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    long_line = " ".join(["word"] * 40)
    out, _ = _run_format(monkeypatch, capsys, f"feat: add the picker\n\n{long_line}")
    body = out.split("\n\n", 1)[1]
    assert all(len(line) <= 72 for line in body.split("\n"))
    assert len(body.split("\n")) > 1


def test_format_trims_the_subject_and_writes_the_note(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    note_file = tmp_path / "note"
    out, note = _run_format(
        monkeypatch,
        capsys,
        "feat: restructure PR body prompts around purpose sections "
        "and fix nested fence stripping",
        note_file,
    )
    assert out == "feat: restructure PR body prompts around purpose sections"
    assert note == (
        'trimmed: dropped "and fix nested fence stripping" (was 88 chars, limit 70)'
    )


def test_format_notes_an_untrimmable_subject(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    note_file = tmp_path / "note"
    subject = "feat: introduce a deterministic branch fingerprint mechanism for caching"
    out, note = _run_format(monkeypatch, capsys, subject, note_file)
    assert out == subject
    assert note == (
        "subject is 72 chars (limit 70) - no clean clause break; shorten this line"
    )


def test_format_leaves_the_note_empty_when_nothing_changed(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    note_file = tmp_path / "note"
    out, note = _run_format(monkeypatch, capsys, "feat: add thing", note_file)
    assert out == "feat: add thing"
    assert note == ""


def test_format_prints_nothing_for_an_empty_response(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The shell reports this, so it can name the provider that produced it."""
    out, _ = _run_format(monkeypatch, capsys, "   \n\n  ")
    assert out == ""


def test_pr_format_slices_the_markers(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    raw = "reasoning\n===TITLE===\nfeat: add it\n===BODY===\n## Summary\n\nText."
    monkeypatch.setattr("sys.stdin", io.StringIO(raw))
    assert _pr_repo_cli.main(["format"]) == 0
    assert capsys.readouterr().out == "feat: add it\n\n## Summary\n\nText."


def test_pr_format_fails_on_an_empty_response(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO("  \n "))
    assert _pr_repo_cli.main(["format"]) == 1
    assert "empty response" in capsys.readouterr().err
