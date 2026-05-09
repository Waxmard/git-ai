"""Tests for prompt builders, response parsers, and diff helpers."""
from __future__ import annotations

import pytest

from git_ai import (
    build_commit_prompt,
    build_mr_prompt,
    derive_diff_stat,
    format_commit_log,
    parse_commit_response,
    parse_mr_response,
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
# build_commit_prompt
# ---------------------------------------------------------------------------


def test_build_commit_prompt_returns_non_empty_pair() -> None:
    system, user = build_commit_prompt(_SAMPLE_DIFF)
    assert system.strip()
    assert user.strip()


def test_build_commit_prompt_embeds_diff() -> None:
    _, user = build_commit_prompt(_SAMPLE_DIFF)
    assert "<diff>" in user
    assert "foo.py" in user
    assert "bar.md" in user


def test_build_commit_prompt_defaults_release_context() -> None:
    _, user = build_commit_prompt(_SAMPLE_DIFF)
    assert "<release_context>" in user
    assert "no release tags found" in user


def test_build_commit_prompt_respects_release_context_override() -> None:
    _, user = build_commit_prompt(
        _SAMPLE_DIFF, release_context="Release context: v1.0.0"
    )
    assert "<release_context>Release context: v1.0.0</release_context>" in user


def test_build_commit_prompt_rejects_empty_diff() -> None:
    with pytest.raises(ValueError, match="diff is empty"):
        build_commit_prompt("   \n")


# ---------------------------------------------------------------------------
# parse_commit_response
# ---------------------------------------------------------------------------


def test_parse_commit_response_strips_fences() -> None:
    assert parse_commit_response("```\nfeat: do thing\n```") == "feat: do thing"


def test_parse_commit_response_strips_whitespace() -> None:
    assert parse_commit_response("\n  feat: x  \n") == "feat: x"


def test_parse_commit_response_rejects_empty() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        parse_commit_response("")


def test_parse_commit_response_rejects_whitespace_only() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        parse_commit_response("   \n  \n")


# ---------------------------------------------------------------------------
# build_mr_prompt
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


def test_build_mr_prompt_returns_non_empty_pair() -> None:
    system, user = build_mr_prompt(diff=_SAMPLE_DIFF)
    assert system.strip()
    assert user.strip()


def test_build_mr_prompt_rejects_empty_diff() -> None:
    with pytest.raises(ValueError, match="diff is empty"):
        build_mr_prompt(diff="")


def test_build_mr_prompt_two_pass_when_mostly_conventional() -> None:
    _, user = build_mr_prompt(diff=_SAMPLE_DIFF, commit_log=_CONVENTIONAL_LOG)
    assert "<draft>" in user
    assert "<commit_log>" not in user
    assert "### Features" in user
    assert "add login" in user


def test_build_mr_prompt_fallback_when_not_conventional() -> None:
    _, user = build_mr_prompt(diff=_SAMPLE_DIFF, commit_log=_NON_CONVENTIONAL_LOG)
    assert "<commit_log>" in user
    assert "<draft>" not in user
    assert "GITAI_COMMIT" not in user
    assert "WIP: half done" in user


def test_build_mr_prompt_no_log_uses_fallback() -> None:
    _, user = build_mr_prompt(diff=_SAMPLE_DIFF)
    assert "<draft>" not in user
    assert "<commit_log>" in user


def test_build_mr_prompt_existing_pr_picks_update_prompt() -> None:
    _, user = build_mr_prompt(
        diff=_SAMPLE_DIFF,
        commit_log=_CONVENTIONAL_LOG,
        existing_pr="feat: old title\n\n### Features\n- old bullet",
    )
    assert "<existing_pr>" in user
    assert "feat: old title" in user


def test_build_mr_prompt_derives_diff_stat_when_omitted() -> None:
    _, user = build_mr_prompt(diff=_SAMPLE_DIFF)
    assert "<changed_files>" in user
    assert "foo.py" in user


def test_build_mr_prompt_uses_supplied_diff_stat() -> None:
    _, user = build_mr_prompt(diff=_SAMPLE_DIFF, diff_stat="CUSTOM-STAT")
    assert "CUSTOM-STAT" in user


def test_build_mr_prompt_defaults_release_context() -> None:
    _, user = build_mr_prompt(diff=_SAMPLE_DIFF)
    assert "no release tags found" in user


def test_build_mr_prompt_respects_release_context_override() -> None:
    _, user = build_mr_prompt(
        diff=_SAMPLE_DIFF, release_context="Release context: v2.0.0"
    )
    assert "Release context: v2.0.0" in user


# ---------------------------------------------------------------------------
# parse_mr_response
# ---------------------------------------------------------------------------


def test_parse_mr_response_strips_fences() -> None:
    raw = "```\nfeat: title\n\n### Features\n- x\n```"
    assert parse_mr_response(raw) == "feat: title\n\n### Features\n- x"


def test_parse_mr_response_rejects_empty() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        parse_mr_response("")
