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


def test_unwraps_inline_code_span_subject() -> None:
    assert (
        strip_fences("`feat: add git-ai-instructions playbook page and root file`")
        == "feat: add git-ai-instructions playbook page and root file"
    )


def test_unwraps_subject_but_keeps_body_code_spans() -> None:
    result = strip_fences("`feat: add thing`\n\nBody uses the `foo` helper and `bar`.")
    assert result == "feat: add thing\n\nBody uses the `foo` helper and `bar`."


def test_does_not_unwrap_subject_with_internal_spans() -> None:
    # Ambiguous line (two spans) — not a clean wrapper, leave untouched.
    assert strip_fences("`a` and `b`") == "`a` and `b`"


def test_inner_fenced_block_survives() -> None:
    body = (
        "===TITLE===\nfix: thing\n===BODY===\n"
        "## Verification\n\n```bash\nnpm test\n```\n\nAll pass."
    )
    assert strip_fences(body) == body


def test_unwraps_outer_fence_around_inner_block() -> None:
    result = strip_fences("```markdown\n## Verification\n\n```bash\nnpm test\n```\n```")
    assert result == "## Verification\n\n```bash\nnpm test\n```"


def test_lone_trailing_fence_not_treated_as_wrapper() -> None:
    text = "## Verification\n\n```bash\nnpm test\n```"
    assert strip_fences(text) == text


def test_lone_leading_fence_not_treated_as_wrapper() -> None:
    text = "```bash\nnpm test\n```\n\nAll suites should pass."
    assert strip_fences(text) == text
