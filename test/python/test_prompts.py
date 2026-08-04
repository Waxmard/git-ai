"""Tests that all prompt files are present and non-empty."""

import pytest
from git_ai._generate import _load_prompt

UPDATE_PROMPT_FILES = [
    "pr-two-pass-update.txt",
    "pr-fallback-update.txt",
    "pr-two-pass-update-incremental.txt",
    "pr-fallback-update-incremental.txt",
]

PROMPT_FILES = [
    "commit.txt",
    "pr-two-pass.txt",
    "pr-fallback.txt",
    *UPDATE_PROMPT_FILES,
]


@pytest.mark.parametrize("name", PROMPT_FILES)
def test_prompt_loads(name: str) -> None:
    text = _load_prompt(name)
    assert isinstance(text, str)
    assert len(text) > 0


@pytest.mark.parametrize("name", PROMPT_FILES)
def test_prompt_no_surrounding_whitespace(name: str) -> None:
    text = _load_prompt(name)
    assert text == text.strip()


def test_commit_prompt_mentions_conventional_commits() -> None:
    text = _load_prompt("commit.txt")
    assert "Conventional Commits" in text


def test_pr_prompts_mention_verification() -> None:
    for name in PROMPT_FILES[1:]:
        assert "## Verification" in _load_prompt(name), (
            f"{name} missing Verification section"
        )


def test_pr_prompts_forbid_type_headings() -> None:
    for name in PROMPT_FILES[1:]:
        text = _load_prompt(name)
        assert "never by conventional commit type" in text, (
            f"{name} missing structure rule"
        )


def test_all_prompts_forbid_unverifiable_claims() -> None:
    for name in PROMPT_FILES:
        text = _load_prompt(name)
        assert "never include line numbers" in text, f"{name} allows line numbers"
        assert "you have executed nothing" in text, f"{name} missing no-execution guard"


def test_commit_prompt_requires_prose_body() -> None:
    text = _load_prompt("commit.txt")
    assert "no bullets" in text
    assert "no markdown headings" in text


def test_commit_prompt_caps_body_length() -> None:
    text = _load_prompt("commit.txt")
    assert "hard ceiling" in text


def test_update_prompts_mention_existing_pr() -> None:
    for name in UPDATE_PROMPT_FILES:
        assert "existing_pr" in _load_prompt(name), f"{name} missing existing_pr tag"


@pytest.mark.parametrize("name", ["pr-two-pass-update.txt", "pr-fallback-update.txt"])
def test_branch_scope_prompts_declare_whole_branch(name: str) -> None:
    text = _load_prompt(name)
    assert "cover the whole branch as it now stands" in text
    assert "cover only the commits added since" not in text


@pytest.mark.parametrize(
    "name",
    ["pr-two-pass-update-incremental.txt", "pr-fallback-update-incremental.txt"],
)
def test_incremental_scope_prompts_forbid_dropping_unshown_work(name: str) -> None:
    text = _load_prompt(name)
    assert "cover only the commits added since <existing_pr> was written" in text
    assert "never delete, narrow, or rewrite existing content" in text
    assert "whole branch as it now stands" not in text


@pytest.mark.parametrize("name", PROMPT_FILES)
def test_commit_log_is_declared_optional_wherever_it_is_named(name: str) -> None:
    """A prompt may not assert a tag the builder omits.

    `build_mr_prompt_input` drops <commit_log> when no log is supplied, so any
    prompt naming the tag has to say it can be absent — otherwise the model is
    told a section exists that isn't there, and reads the gap as "no commits".
    """
    text = _load_prompt(name)
    if "<commit_log>" not in text:
        return
    assert (
        "present only when commit messages are available" in text
        or "(when present) <commit_log>" in text
    ), f"{name} names <commit_log> without declaring it optional"
