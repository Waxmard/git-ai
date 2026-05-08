"""Tests for diff-size hard-fail guard in prompt builders."""

from __future__ import annotations

import pytest

from git_ai import build_commit_prompt, build_mr_prompt


def _huge_diff(file_path: str, byte_target: int) -> str:
    line = "+" + ("x" * 79) + "\n"  # 81 bytes
    body_lines = byte_target // len(line) + 1
    return (
        f"diff --git a/{file_path} b/{file_path}\n"
        "index aaa..bbb 100644\n"
        f"--- a/{file_path}\n"
        f"+++ b/{file_path}\n"
        f"@@ -0,0 +1,{body_lines} @@\n" + (line * body_lines)
    )


def test_commit_size_guard_aborts_with_top_files(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GIT_AI_MAX_DIFF_BYTES", "5000")
    diff = _huge_diff("package-lock.json", 6000)
    with pytest.raises(RuntimeError) as excinfo:
        build_commit_prompt(diff)
    msg = str(excinfo.value)
    assert "exceeds limit" in msg
    assert "Largest changed files" in msg
    assert "package-lock.json" in msg
    assert ".git-ai-ignore" in msg


def test_commit_size_guard_disabled_with_zero(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GIT_AI_MAX_DIFF_BYTES", "0")
    diff = _huge_diff("foo.txt", 6000)
    system, user = build_commit_prompt(diff)
    assert system
    assert "foo.txt" in user


def test_commit_size_guard_invalid_value_uses_default(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("GIT_AI_MAX_DIFF_BYTES", "not-a-number")
    # default is 900_000; small diff should pass through
    diff = _huge_diff("foo.txt", 1000)
    system, user = build_commit_prompt(diff)
    assert system
    assert "foo.txt" in user


def test_mr_size_guard_aborts(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GIT_AI_MAX_DIFF_BYTES", "5000")
    diff = _huge_diff("dist/bundle.js", 6000)
    with pytest.raises(RuntimeError) as excinfo:
        build_mr_prompt(diff=diff)
    assert "dist/bundle.js" in str(excinfo.value)
