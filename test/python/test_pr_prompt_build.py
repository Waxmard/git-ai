"""Tests for PR prompt selection and input assembly."""

from __future__ import annotations

import pytest
from git_ai._pr_prompt_build import build_mr_prompt_input

_DIFF = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+x\n"


def _log(*commits: str) -> str:
    """Build a GITAI_COMMIT-prefixed log from raw 'subject\\nbody' strings."""
    return "".join(f"GITAI_COMMIT {c}\n" for c in commits)


def test_single_conventional_commit_uses_two_pass() -> None:
    name, user_input = build_mr_prompt_input(
        diff=_DIFF, commit_log=_log("feat: add widget")
    )
    assert name == "pr-two-pass.txt"
    assert "### Features\n- add widget" in user_input


def test_single_conventional_commit_body_reaches_the_draft() -> None:
    log = _log("fix: stop crash\n\nThe handler dereferenced a null pointer.\n")
    _, user_input = build_mr_prompt_input(diff=_DIFF, commit_log=log)
    assert "The handler dereferenced a null pointer." in user_input


def test_single_non_conventional_commit_uses_fallback() -> None:
    name, user_input = build_mr_prompt_input(
        diff=_DIFF, commit_log=_log("remove mouse icon")
    )
    assert name == "pr-fallback.txt"
    assert "<commit_log>\nremove mouse icon" in user_input


def test_single_commit_with_existing_pr_uses_update_prompt() -> None:
    name, user_input = build_mr_prompt_input(
        diff=_DIFF,
        commit_log=_log("feat: add widget"),
        existing_pr="# Old\n\nbody",
    )
    assert name == "pr-two-pass-update.txt"
    assert "<existing_pr>\n# Old\n\nbody\n</existing_pr>" in user_input


def test_two_commits_use_two_pass() -> None:
    name, _ = build_mr_prompt_input(diff=_DIFF, commit_log=_log("feat: a", "fix: b"))
    assert name == "pr-two-pass.txt"


def test_empty_diff_is_rejected() -> None:
    with pytest.raises(ValueError, match="diff is empty"):
        build_mr_prompt_input(diff="", commit_log=_log("feat: add widget"))
