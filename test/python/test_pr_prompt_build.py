"""Tests for the single-commit verbatim PR short-circuit."""

from __future__ import annotations

from git_ai._pr_prompt_build import build_mr_prompt_input, verbatim_pr_text

_DIFF = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+x\n"


def _log(*commits: str) -> str:
    """Build a GITAI_COMMIT-prefixed log from raw 'subject\\nbody' strings."""
    return "".join(f"GITAI_COMMIT {c}\n" for c in commits)


def test_single_conventional_commit_is_verbatim() -> None:
    assert verbatim_pr_text(_log("feat: add widget")) == "feat: add widget"


def test_single_conventional_commit_keeps_body() -> None:
    log = _log("fix: stop crash\n\nThe handler dereferenced a null pointer.\n")
    assert (
        verbatim_pr_text(log)
        == "fix: stop crash\n\nThe handler dereferenced a null pointer."
    )


def test_single_non_conventional_commit_is_not_verbatim() -> None:
    assert verbatim_pr_text(_log("remove mouse icon")) is None


def test_single_commit_with_existing_pr_is_not_verbatim() -> None:
    # Updating an existing draft must still go through the LLM.
    log = _log("feat: add widget")
    assert verbatim_pr_text(log, existing_pr="# Old\n\nbody") is None


def test_two_commits_are_not_verbatim() -> None:
    assert verbatim_pr_text(_log("feat: a", "fix: b")) is None


def test_empty_log_is_not_verbatim() -> None:
    assert verbatim_pr_text("") is None
    assert verbatim_pr_text(None) is None


def test_build_mr_prompt_input_is_unaffected_by_single_commit() -> None:
    # The shared template selector still returns a real prompt name; the
    # verbatim short-circuit lives in the CLI layer, not here.
    name, _ = build_mr_prompt_input(diff=_DIFF, commit_log=_log("feat: add widget"))
    assert name == "pr-two-pass.txt"
