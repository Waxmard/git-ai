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


def test_pr_prompts_mention_test_plan() -> None:
    for name in ["pr-two-pass.txt", "pr-fallback.txt"]:
        assert "Test Plan" in _load_prompt(name), f"{name} missing Test Plan section"


def test_update_prompts_mention_existing_pr() -> None:
    for name in ["pr-two-pass-update.txt", "pr-fallback-update.txt"]:
        assert "existing_pr" in _load_prompt(name), f"{name} missing existing_pr tag"
