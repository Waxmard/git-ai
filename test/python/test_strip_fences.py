"""Tests for strip_fences — mirrors test/lib/strip_fences.bats."""
import pytest

from git_ai import strip_fences


def test_removes_plain_fence() -> None:
    assert strip_fences("```\nhello\n```") == "hello"


def test_removes_language_tagged_fence_bash() -> None:
    assert strip_fences("```bash\necho hi\n```") == "echo hi"


def test_removes_language_tagged_fence_sh() -> None:
    assert strip_fences("```sh\nls\n```") == "ls"


def test_passes_through_plain_text() -> None:
    assert strip_fences("plain text") == "plain text"


def test_strips_surrounding_blank_lines() -> None:
    assert strip_fences("\n\ntext\n\n") == "text"


def test_multiline_content_preserved() -> None:
    result = strip_fences("```\nline1\nline2\n```")
    assert result == "line1\nline2"


def test_no_fence_multiline_preserved() -> None:
    result = strip_fences("line1\nline2\nline3")
    assert result == "line1\nline2\nline3"


@pytest.mark.parametrize("lang", ["python", "json", "yaml", "diff"])
def test_removes_various_language_tags(lang: str) -> None:
    result = strip_fences(f"```{lang}\ncontent\n```")
    assert result == "content"
