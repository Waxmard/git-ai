"""Tests for diff-string generate entry points and supporting helpers."""
from __future__ import annotations

import pytest

from git_ai import (
    MrDescription,
    derive_diff_stat,
    format_commit_log,
    generate_commit_message_from_diff,
    generate_mr_description,
)

_SAMPLE_DIFF = """\
diff --git a/foo.py b/foo.py
index aaa..bbb 100644
--- a/foo.py
+++ b/foo.py
@@ -1,3 +1,4 @@
 def f():
-    return 1
+    return 2
+    # trailing
diff --git a/bar.md b/bar.md
index ccc..ddd 100644
--- a/bar.md
+++ b/bar.md
@@ -1 +1,2 @@
-old
+new
+extra
"""


class _Spy:
    """Fake ``generate`` that records call args and returns a canned string."""

    def __init__(self, text: str) -> None:
        self._text = text
        self.calls: list[tuple[str, str]] = []

    def __call__(self, system_prompt: str, user_input: str) -> str:
        self.calls.append((system_prompt, user_input))
        return self._text

    @property
    def system_prompt(self) -> str:
        assert len(self.calls) == 1
        return self.calls[0][0]

    @property
    def user_input(self) -> str:
        assert len(self.calls) == 1
        return self.calls[0][1]


# ---------------------------------------------------------------------------
# format_commit_log
# ---------------------------------------------------------------------------


def test_format_commit_log_empty() -> None:
    assert format_commit_log([]) == ""


def test_format_commit_log_subjects_only() -> None:
    log = format_commit_log([("feat: a", ""), ("fix: b", "")])
    assert log == "GITAI_COMMIT feat: a\nGITAI_COMMIT fix: b\n"


def test_format_commit_log_with_bodies() -> None:
    log = format_commit_log([("feat: a", "body line 1\nbody line 2"), ("fix: b", "")])
    assert log == (
        "GITAI_COMMIT feat: a\n"
        "body line 1\n"
        "body line 2\n"
        "GITAI_COMMIT fix: b\n"
    )


# ---------------------------------------------------------------------------
# derive_diff_stat
# ---------------------------------------------------------------------------


def test_derive_diff_stat_empty_input() -> None:
    assert derive_diff_stat("") == ""


def test_derive_diff_stat_counts_per_file() -> None:
    stat = derive_diff_stat(_SAMPLE_DIFF)
    lines = stat.splitlines()
    assert any("foo.py" in line and " 3 " in line for line in lines[:-1])
    assert any("bar.md" in line and " 3 " in line for line in lines[:-1])
    assert (
        lines[-1] == " 2 files changed, 4 insertions(+), 2 deletions(-)"
    )


def test_derive_diff_stat_binary_file() -> None:
    diff = (
        "diff --git a/img.png b/img.png\n"
        "index aaa..bbb 100644\n"
        "Binary files a/img.png and b/img.png differ\n"
    )
    stat = derive_diff_stat(diff)
    assert "img.png" in stat
    assert "Bin" in stat
    assert "1 file changed" in stat


def test_derive_diff_stat_skips_header_lines() -> None:
    """+++/--- header lines are not counted as insertions/deletions."""
    diff = (
        "diff --git a/x.txt b/x.txt\n"
        "--- a/x.txt\n"
        "+++ b/x.txt\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    )
    stat = derive_diff_stat(diff)
    assert "1 insertion(+)" in stat
    assert "1 deletion(-)" in stat


# ---------------------------------------------------------------------------
# generate_commit_message_from_diff
# ---------------------------------------------------------------------------


def test_commit_from_diff_returns_stripped_text() -> None:
    gen = _Spy("feat: do thing")
    result = generate_commit_message_from_diff(_SAMPLE_DIFF, generate=gen)
    assert result == "feat: do thing"


def test_commit_from_diff_rejects_empty_diff() -> None:
    gen = _Spy("unused")
    with pytest.raises(ValueError, match="diff is empty"):
        generate_commit_message_from_diff("   \n", generate=gen)
    assert gen.calls == []


def test_commit_from_diff_raises_on_empty_generate_output() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        generate_commit_message_from_diff(_SAMPLE_DIFF, generate=lambda _s, _u: "")


def test_commit_from_diff_strips_fences() -> None:
    result = generate_commit_message_from_diff(
        _SAMPLE_DIFF, generate=lambda _s, _u: "```\nfeat: do thing\n```"
    )
    assert result == "feat: do thing"


def test_commit_from_diff_includes_release_context_and_diff() -> None:
    gen = _Spy("feat: x")
    generate_commit_message_from_diff(
        _SAMPLE_DIFF, generate=gen, release_context="Release context: v1.0.0"
    )
    assert "<release_context>Release context: v1.0.0</release_context>" in gen.user_input
    assert "<diff>" in gen.user_input
    assert "foo.py" in gen.user_input


def test_commit_from_diff_defaults_release_context() -> None:
    gen = _Spy("feat: x")
    generate_commit_message_from_diff(_SAMPLE_DIFF, generate=gen)
    assert "no release tags found" in gen.user_input


# ---------------------------------------------------------------------------
# generate_mr_description — data-mode
# ---------------------------------------------------------------------------


_CONVENTIONAL_LOG = (
    "GITAI_COMMIT feat: add login\n"
    "GITAI_COMMIT fix: correct null pointer\n"
    "GITAI_COMMIT chore: bump deps\n"
)

_NON_CONVENTIONAL_LOG = (
    "GITAI_COMMIT WIP: half done\n"
    "GITAI_COMMIT random update\n"
)


def test_mr_data_mode_returns_mrdescription() -> None:
    result = generate_mr_description(
        diff=_SAMPLE_DIFF,
        generate=lambda _s, _u: "feat: x\n\n### Features\n- x",
    )
    assert isinstance(result, MrDescription)
    assert "feat: x" in result.text
    assert result.diff is None


def test_mr_data_mode_rejects_empty_diff() -> None:
    gen = _Spy("unused")
    with pytest.raises(ValueError, match="diff is empty"):
        generate_mr_description(diff="", generate=gen)
    assert gen.calls == []


def test_mr_data_mode_raises_on_empty_generate_output() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        generate_mr_description(diff=_SAMPLE_DIFF, generate=lambda _s, _u: "")


def test_mr_rejects_both_repo_path_and_diff() -> None:
    gen = _Spy("unused")
    with pytest.raises(ValueError, match="not both"):
        generate_mr_description(".", diff=_SAMPLE_DIFF, generate=gen)
    assert gen.calls == []


def test_mr_rejects_neither_repo_path_nor_diff() -> None:
    gen = _Spy("unused")
    with pytest.raises(ValueError, match="repo_path.*or diff"):
        generate_mr_description(generate=gen)
    assert gen.calls == []


def test_mr_data_mode_two_pass_when_mostly_conventional() -> None:
    gen = _Spy("feat: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, commit_log=_CONVENTIONAL_LOG, generate=gen
    )
    # two-pass prompt uses <draft>; fallback uses <commit_log>.
    assert "<draft>" in gen.user_input
    assert "<commit_log>" not in gen.user_input
    assert "### Features" in gen.user_input
    assert "add login" in gen.user_input


def test_mr_data_mode_fallback_when_not_conventional() -> None:
    gen = _Spy("chore: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, commit_log=_NON_CONVENTIONAL_LOG, generate=gen
    )
    assert "<commit_log>" in gen.user_input
    assert "<draft>" not in gen.user_input
    # GITAI_COMMIT prefix stripped
    assert "GITAI_COMMIT" not in gen.user_input
    assert "WIP: half done" in gen.user_input


def test_mr_data_mode_no_log_uses_fallback() -> None:
    gen = _Spy("chore: x")
    generate_mr_description(diff=_SAMPLE_DIFF, generate=gen)
    assert "<draft>" not in gen.user_input
    assert "<commit_log>" in gen.user_input


def test_mr_data_mode_existing_pr_picks_update_prompt_and_renders_diff() -> None:
    gen = _Spy("feat: new title\n\n### Features\n- new bullet")
    result = generate_mr_description(
        diff=_SAMPLE_DIFF,
        commit_log=_CONVENTIONAL_LOG,
        existing_pr="feat: old title\n\n### Features\n- old bullet",
        generate=gen,
    )
    assert "<existing_pr>" in gen.user_input
    assert "feat: old title" in gen.user_input
    assert result.diff is not None
    # render_pr_diff emits `~ ` / `+ ` / `- ` markers and `@@` hunk headers.
    assert any(marker in result.diff for marker in ("~ ", "+ ", "- ", "@@"))


def test_mr_data_mode_diff_none_when_existing_pr_matches_output() -> None:
    generated = "feat: same\n\n### Features\n- same"
    result = generate_mr_description(
        diff=_SAMPLE_DIFF, existing_pr=generated, generate=lambda _s, _u: generated
    )
    assert result.text == generated
    assert result.diff is None


def test_mr_data_mode_derives_diff_stat_when_omitted() -> None:
    gen = _Spy("feat: x")
    generate_mr_description(diff=_SAMPLE_DIFF, generate=gen)
    assert "<changed_files>" in gen.user_input
    # Derived stat should mention at least one changed file from the sample diff.
    assert "foo.py" in gen.user_input


def test_mr_data_mode_uses_supplied_diff_stat() -> None:
    gen = _Spy("feat: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, diff_stat="CUSTOM-STAT", generate=gen
    )
    assert "CUSTOM-STAT" in gen.user_input


def test_mr_data_mode_defaults_release_context() -> None:
    gen = _Spy("feat: x")
    generate_mr_description(diff=_SAMPLE_DIFF, generate=gen)
    assert "no release tags found" in gen.user_input


def test_mr_data_mode_respects_release_context_override() -> None:
    gen = _Spy("feat: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, release_context="Release context: v2.0.0", generate=gen
    )
    assert "Release context: v2.0.0" in gen.user_input
