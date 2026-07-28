"""Tests for prompt builders, response parsers, and diff helpers."""

from __future__ import annotations

import pytest
from git_ai import (
    build_commit_prompt,
    build_mr_prompt,
    derive_diff_stat,
    format_branch_context,
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


def test_format_commit_log_empty() -> None:
    assert format_commit_log([]) == ""


def test_format_commit_log_subjects_only() -> None:
    log = format_commit_log([("feat: a", ""), ("fix: b", "")])
    assert log == "GITAI_COMMIT feat: a\nGITAI_COMMIT fix: b\n"


def test_format_commit_log_with_bodies() -> None:
    log = format_commit_log([("feat: a", "body line 1\nbody line 2"), ("fix: b", "")])
    assert log == (
        "GITAI_COMMIT feat: a\nbody line 1\nbody line 2\nGITAI_COMMIT fix: b\n"
    )


def test_derive_diff_stat_empty_input() -> None:
    assert derive_diff_stat("") == ""


def test_derive_diff_stat_counts_per_file() -> None:
    stat = derive_diff_stat(_SAMPLE_DIFF)
    lines = stat.splitlines()
    assert any("foo.py" in line and " 3 " in line for line in lines[:-1])
    assert any("bar.md" in line and " 3 " in line for line in lines[:-1])
    assert lines[-1] == " 2 files changed, 4 insertions(+), 2 deletions(-)"


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


def test_build_commit_prompt_omits_branch_block_by_default() -> None:
    _, user = build_commit_prompt(_SAMPLE_DIFF)
    assert "<branch>" not in user
    assert "<branch_commits>" not in user
    assert "<branch_diffstat>" not in user


def test_build_commit_prompt_embeds_branch_context() -> None:
    _, user = build_commit_prompt(
        _SAMPLE_DIFF,
        branch_name="feat/file-notes",
        branch_commits="feat: add panel\ntest: cover panel",
        branch_diffstat="panel.tsx | 10 ++",
    )
    assert "<branch>feat/file-notes</branch>" in user
    assert (
        "<branch_commits>\nfeat: add panel\ntest: cover panel\n</branch_commits>"
        in user
    )
    assert "<branch_diffstat>\npanel.tsx | 10 ++\n</branch_diffstat>" in user
    # Branch context sits between release context and the diff.
    assert (
        user.index("<release_context>") < user.index("<branch>") < user.index("<diff>")
    )


def test_build_commit_prompt_omits_guidance_by_default() -> None:
    _, user = build_commit_prompt(_SAMPLE_DIFF)
    assert "<repo_guidance>" not in user


def test_build_commit_prompt_embeds_repo_guidance_first() -> None:
    _, user = build_commit_prompt(
        _SAMPLE_DIFF, repo_guidance="Scopes: api, web. tag bump = chore."
    )
    assert (
        "<repo_guidance>\nScopes: api, web. tag bump = chore.\n</repo_guidance>" in user
    )
    # Guidance leads, ahead of release context and the diff.
    assert (
        user.index("<repo_guidance>")
        < user.index("<release_context>")
        < user.index("<diff>")
    )


def test_build_mr_prompt_embeds_repo_guidance() -> None:
    _, user = build_mr_prompt(
        diff=_SAMPLE_DIFF,
        commit_log="feat: a\nfix: b",
        repo_guidance="tag bump = chore.",
    )
    assert "<repo_guidance>\ntag bump = chore.\n</repo_guidance>" in user
    assert user.index("<repo_guidance>") < user.index("<release_context>")


def test_build_commit_prompt_emits_only_non_empty_branch_tags() -> None:
    _, user = build_commit_prompt(
        _SAMPLE_DIFF, branch_name="dev-branch", branch_commits="  ", branch_diffstat=""
    )
    assert "<branch>dev-branch</branch>" in user
    assert "<branch_commits>" not in user
    assert "<branch_diffstat>" not in user


def test_format_branch_context_all_empty_returns_blank() -> None:
    assert format_branch_context() == ""
    assert (
        format_branch_context(branch_name="  ", branch_commits="", branch_diffstat=None)
        == ""
    )


def test_format_branch_context_strips_and_tags_each_part() -> None:
    block = format_branch_context(
        branch_name="  topic  ",
        branch_commits="  feat: x  ",
        branch_diffstat="  a | 1 +  ",
    )
    assert block == (
        "<branch>topic</branch>\n"
        "<branch_commits>\nfeat: x\n</branch_commits>\n"
        "<branch_diffstat>\na | 1 +\n</branch_diffstat>"
    )


def test_parse_commit_response_strips_fences() -> None:
    assert parse_commit_response("```\nfeat: do thing\n```") == "feat: do thing"


def test_parse_commit_response_strips_whitespace() -> None:
    assert parse_commit_response("\n  feat: x  \n") == "feat: x"


def test_parse_commit_response_unwraps_commit_marker() -> None:
    raw = "Reasoning: feat, new capability.\n===COMMIT===\nfeat: add thing\n\nBody."
    assert parse_commit_response(raw) == "feat: add thing\n\nBody."


def test_parse_commit_response_drops_preamble_without_marker() -> None:
    raw = "docs+test changes. feat, new capability.\n\nfix: preselect entries\n\nBody."
    assert parse_commit_response(raw) == "fix: preselect entries\n\nBody."


def test_parse_commit_response_passes_through_unclassifiable_text() -> None:
    assert parse_commit_response("just some text") == "just some text"


def test_parse_commit_response_rejects_empty() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        parse_commit_response("")


def test_parse_commit_response_rejects_whitespace_only() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        parse_commit_response("   \n  \n")


_CONVENTIONAL_LOG = (
    "GITAI_COMMIT feat: add login\n"
    "GITAI_COMMIT fix: correct null pointer\n"
    "GITAI_COMMIT chore: bump deps\n"
)

_NON_CONVENTIONAL_LOG = "GITAI_COMMIT WIP: half done\nGITAI_COMMIT random update\n"


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


def test_parse_mr_response_strips_fences() -> None:
    raw = "```\nfeat: title\n\n### Features\n- x\n```"
    assert parse_mr_response(raw) == "feat: title\n\n### Features\n- x"


def test_parse_mr_response_rejects_empty() -> None:
    with pytest.raises(RuntimeError, match="empty response"):
        parse_mr_response("")


def test_parse_mr_response_extracts_sentinels() -> None:
    raw = "===TITLE===\nfeat: title\n===BODY===\n### Features\n- x"
    assert parse_mr_response(raw) == "feat: title\n\n### Features\n- x"


def test_parse_mr_response_discards_preamble_outside_markers() -> None:
    raw = (
        "That title is 78 chars. Let me shorten.\n"
        "Actually, output only title and body.\n"
        "===TITLE===\nfeat: title\n===BODY===\n### Features\n- x"
    )
    assert parse_mr_response(raw) == "feat: title\n\n### Features\n- x"


def test_parse_mr_response_extracts_sentinels_inside_fence() -> None:
    raw = "```\n===TITLE===\nfeat: title\n===BODY===\n- x\n```"
    assert parse_mr_response(raw) == "feat: title\n\n- x"


def test_parse_mr_response_falls_back_without_markers() -> None:
    raw = "feat: title\n\n### Features\n- x"
    assert parse_mr_response(raw) == "feat: title\n\n### Features\n- x"


def test_parse_mr_response_falls_back_on_missing_body_marker() -> None:
    raw = "===TITLE===\nfeat: title\nno body marker here"
    assert parse_mr_response(raw) == "===TITLE===\nfeat: title\nno body marker here"
