"""Tests that all prompt files are present and non-empty."""

import pytest
from git_ai._generate import _load_prompt

PROMPT_FILES = [
    "commit.txt",
    "pr-two-pass.txt",
    "pr-fallback.txt",
    "pr-two-pass-update.txt",
    "pr-fallback-update.txt",
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


def test_update_prompts_mention_existing_pr() -> None:
    for name in ["pr-two-pass-update.txt", "pr-fallback-update.txt"]:
        assert "existing_pr" in _load_prompt(name), f"{name} missing existing_pr tag"
