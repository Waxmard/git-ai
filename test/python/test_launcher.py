"""Tests for the pip console-script launcher (_launcher.main)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest
from git_ai import _launcher


def _point_pkg_dir_at(monkeypatch: pytest.MonkeyPatch, pkg_dir: Path) -> None:
    """Make _launcher resolve its package dir to ``pkg_dir``."""
    monkeypatch.setattr(_launcher, "__file__", str(pkg_dir / "_launcher.py"))


def test_main_exits_when_bundled_cli_missing(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _point_pkg_dir_at(monkeypatch, tmp_path)  # no _sh/bin/git-ai here
    monkeypatch.setattr(os, "execvpe", _never_called)

    with pytest.raises(SystemExit) as excinfo:
        _launcher.main()

    assert excinfo.value.code == 1
    assert "bundled CLI not found" in capsys.readouterr().err


def test_main_execs_with_unconditional_pkg_dir(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    cli = tmp_path / "_sh" / "bin" / "git-ai"
    cli.parent.mkdir(parents=True)
    cli.write_text("#!/bin/bash\n")
    _point_pkg_dir_at(monkeypatch, tmp_path)

    # A stale value in the environment must not win — the launcher knows better.
    monkeypatch.setenv("GIT_AI_PKG_DIR", "/stale/leftover/path")
    monkeypatch.setattr(sys, "argv", ["git-ai", "commit", "--flag"])

    captured: dict[str, object] = {}

    def fake_execvpe(file: str, args: list[str], env: dict[str, str]) -> None:
        captured.update(file=file, args=args, env=env)

    monkeypatch.setattr(os, "execvpe", fake_execvpe)

    _launcher.main()

    assert captured["file"] == "bash"
    assert captured["args"] == ["bash", str(cli), "commit", "--flag"]
    assert captured["env"]["GIT_AI_PKG_DIR"] == str(tmp_path)  # type: ignore[index]


def _never_called(*_args: object, **_kwargs: object) -> None:
    raise AssertionError("os.execvpe should not run when the CLI is missing")
